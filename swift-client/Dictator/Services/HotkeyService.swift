import Cocoa
import Carbon.HIToolbox
import Foundation
import Darwin

enum TypingActivity: Equatable {
    case text(String)
    case deleteBackward
    /// Return / Enter / ⌘Return — submits in chat boxes and terminals.
    case newline
    /// ⇧Return / ⌥Return — a line break inside a multi-line composer.
    case softNewline
    /// ⌘V: the pasted text is on the general pasteboard.
    case paste
    case caretOrSelectionChanged
}

/// A signal from the one event tap that the user just interacted with
/// whatever's focused on this Mac — feeds `FocusClaimDetector`,
/// which debounces/throttles it into an Edge→Core focus claim. It is
/// deliberately narrow (see `HotkeyService.handleEvent`), since a wrong claim
/// retargets a whole transcription to the wrong machine.
enum FocusActivityKind {
    case click
    case keystroke
}

/// Simple fixed-window rate limiter for `DICTATOR_HOTKEY_TRACE` trace lines,
/// so a busy event tap (e.g. mouse movement across a Universal Control
/// boundary) can never flood hotkey.log or add latency to the tap callback.
/// The clock is injected so tests can drive windows deterministically
/// without sleeping.
final class HotkeyTraceLimiter {
    enum Decision: Equatable {
        case allowed
        case dropped
        /// Allowed, but a prior window silently dropped `count` lines — report
        /// that once, alongside this line, as the window resets.
        case allowedWithDroppedReport(_ count: Int)
    }

    private let limit: Int
    private let windowSeconds: TimeInterval
    private let clock: () -> TimeInterval

    private var windowStart: TimeInterval
    private var countInWindow = 0
    private var droppedInWindow = 0
    // `allow()` is called directly on the CGEvent tap thread (see
    // `HotkeyService.trace`), not only from the serial `traceQueue`, so its
    // mutable state needs its own lock.
    private let lock = NSLock()

    init(limit: Int = 50, windowSeconds: TimeInterval = 1.0, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.limit = limit
        self.windowSeconds = windowSeconds
        self.clock = clock
        self.windowStart = clock()
    }

    func allow() -> Decision {
        lock.lock()
        defer { lock.unlock() }

        let now = clock()
        if now - windowStart >= windowSeconds {
            let dropped = droppedInWindow
            windowStart = now
            droppedInWindow = 0
            if dropped > 0 {
                // The report itself is a second line written to disk, so it
                // spends a second slot of this window's budget alongside the
                // line that triggered it — otherwise a window that keeps
                // reporting drops could write 2x its nominal limit.
                countInWindow = 2
                return .allowedWithDroppedReport(dropped)
            }
            countInWindow = 1
            return .allowed
        }

        guard countInWindow < limit else {
            droppedInWindow += 1
            return .dropped
        }
        countInWindow += 1
        return .allowed
    }
}

/// Last pointer position seen by the event tap, in Core Graphics global
/// coordinates (top-left origin of the primary display). Querying the
/// cursor (`NSEvent.mouseLocation`, `CGEvent(source:)`) from this app lags
/// one screen crossing behind — the process's cached cursor only refreshes
/// on a window-server round trip — so the indicator reads the tap's own
/// last event location instead (see `IndicatorWindowController`).
final class PointerLocationTracker: @unchecked Sendable {
    static let shared = PointerLocationTracker()
    private let lock = NSLock()
    private var location: CGPoint?

    func update(_ point: CGPoint) {
        lock.lock(); location = point; lock.unlock()
    }

    var current: CGPoint? {
        lock.lock(); defer { lock.unlock() }
        return location
    }
}

/// Throttles the pointer-presence heartbeat `HotkeyService` derives from
/// `mouseMoved` (Universal Control initiator/target fix — see
/// `EdgeMessage.pointerPresence` and `FocusClaimRegistry.FocusClaimKind`):
/// `mouseMoved` can fire hundreds of times a second while the pointer is
/// moving, but the Core only needs a heartbeat a few times a second to know
/// "the pointer is still on this Mac." `leftMouseDown` bypasses this
/// entirely (see `HotkeyService.handleEvent`) — a fresh click is exactly the
/// moment presence matters most and must never be delayed behind a pending
/// interval. The clock is injected, mirroring `HotkeyTraceLimiter`, so tests
/// can drive it deterministically without sleeping.
final class PointerPresenceThrottle {
    private let interval: TimeInterval
    private let clock: () -> TimeInterval
    private var lastFiredAt: TimeInterval = -.infinity

    init(interval: TimeInterval = 0.5, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.interval = interval
        self.clock = clock
    }

    /// True if a heartbeat should fire now — and records that it did, so the
    /// next call within `interval` returns false.
    func allow() -> Bool {
        let now = clock()
        guard now - lastFiredAt >= interval else { return false }
        lastFiredAt = now
        return true
    }
}

/// Global hotkey listener using CGEvent tap.
/// Replaces Hammerspoon init.lua — listens for Right Option press/release
/// and Esc cancellation.
final class HotkeyService {
    // Carbon keycodes matching Hammerspoon
    private static let escKeyCode: CGKeyCode = 53
    private static let tabKeyCode: CGKeyCode = 48
    // Mirrors PasteService.vkAnsiV — needed here only to recognize a real
    // (non-synthetic) ⌘V as focus activity; see classifyFocusKeystroke.
    private static let ansiVKeyCode: CGKeyCode = 9
    // NX_DEVICERALTKEYMASK: the physical Right Option key, used for trace lines.
    private static let rightOptionFlag = CGEventFlags(rawValue: 0x40)
    private static let rightOptionKeyCode: CGKeyCode = 61

    /// True while the Workspace launch shortcut recorder is listening, so pressing the
    /// dictation key to record a shortcut does not start a real dictation.
    /// Set and read on the main thread only.
    nonisolated(unsafe) static var isRecordingWorkspaceShortcut = false

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var protectsBackgroundLifetime = false
    private(set) var isPressed = false

    /// The keys that start dictation and run a command. Read from the
    /// settings when the tap starts, and again when the user changes them.
    var triggers = AppSettings.shared.hotkeyTriggers
    /// The keys behind the current press, for the character-chord latch.
    private var activeTrigger: KeyCombo?
    /// Regular (non-modifier) trigger keys that are down.
    private var heldTriggerKeys = Set<CGKeyCode>()
    /// Trigger keys held back from the app in front, so their key-up is too.
    private var swallowedTriggerKeys = Set<CGKeyCode>()
    /// When the key went down, for the character-chord window.
    private var pressedAt = Date.distantPast
    /// Set when a press was dropped as a character chord, until the key is
    /// let go, so the still-held key cannot start a session.
    private var chordSuppressed = false {
        didSet {
            if chordSuppressed { startChordLatchTimer() } else { chordLatchTimer?.invalidate(); chordLatchTimer = nil }
        }
    }
    /// Physical state of a key, for clearing the chord latch if its key-up
    /// never arrived (Universal Control can lose or redirect it). Injectable.
    var chordLatchKeyIsDown: (CGKeyCode) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: $0) }
    private var chordLatchTimer: Timer?

    /// Clears the chord latch when the dictation key is no longer physically
    /// down. Only clears the latch; never sends a stop.
    func releaseChordLatchIfKeyUp() {
        guard chordSuppressed, !(activeTrigger ?? triggers.dictation).keyCodes.allSatisfy(chordLatchKeyIsDown) else { return }
        chordSuppressed = false
    }

    private func startChordLatchTimer() {
        chordLatchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.releaseChordLatchIfKeyUp() }
        chordLatchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    var now: () -> Date = Date.init

    /// Universal Control can deliver the key-up flagsChanged to the other
    /// Mac (or drop it) when the pointer crosses machines mid-hold, leaving
    /// this Mac believing the key is still down forever. While pressed, poll
    /// the physical HID modifier state and synthesize a release if the key
    /// is no longer physically held. Injectable so tests can drive it with a
    /// fake probe and a short interval, without a live CGEvent tap.
    var modifierStateProbe: () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) }
    var watchdogInterval: TimeInterval = 0.25
    private var modifierWatchdogTimer: Timer?
    /// Require two consecutive "not held" polls before firing — the first
    /// poll can land before a slow flagsChanged→HID-state propagation has
    /// caught up, which would otherwise false-trigger a synthesized stop
    /// right after a genuine press.
    private var modifierWatchdogMissCount = 0

    /// Set by the view model while a session can still be aborted after
    /// the key was released (transcription in flight), so Esc keeps
    /// working beyond the push-to-talk hold.
    var cancelEligible = false

    var onStart: (() -> Void)?
    var onStop: ((HotkeyUpReason) -> Void)?
    var onCancel: (() -> Void)?
    /// The press turned out to be a typed character. Separate from
    /// `onCancel` (Esc) because the owner must only drop a session that this
    /// press started, never one already recording or transcribing.
    var onCharacterChord: (() -> Void)?
    /// The Commands keys were held at some point during the press. Fires once
    /// per press, after `onStart` when they were down from the start, so the
    /// Core hears about the press first.
    var onVoiceCommandMode: (() -> Void)?
    /// True from a press where the Commands keys joined, until the key is released.
    private(set) var voiceCommandMode = false
    /// Sampled before onStart can show any Dictator UI. Injected in tests.
    var frontmostAppBundleID: () -> String? = {
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
    private(set) var commandAppBundleID: String?

    /// Any keyDown that may have changed the typed buffer or caret — drives
    /// typed-prompt capture. Cheap.
    var onTypingActivity: ((TypingActivity) -> Void)?

    /// A real (non-synthetic) left click on this Mac — lets typed-prompt
    /// capture notice a chat message sent with the mouse (the Send button).
    var onMouseDown: (() -> Void)?

    /// A click or an editing keystroke on this Mac — see `FocusActivityKind`.
    /// Fired from the tap thread; the closure must stay cheap (no AX work
    /// here — `FocusClaimDetector` hops to its own queue before probing).
    var onFocusActivity: ((_ kind: FocusActivityKind) -> Void)?

    /// The pointer (mouseMoved, throttled — or leftMouseDown, immediate) is
    /// present on this Mac — see `PointerPresenceThrottle` and
    /// `EdgeMessage.pointerPresence`. Fired from the tap thread; unlike
    /// `onFocusActivity` this never does AX work and needs no queue hop —
    /// firing it is just a throttle check plus a cheap closure call.
    var onPointerPresence: (() -> Void)?
    /// The pointer just crossed onto a different display of this Mac (or
    /// arrived on this Mac at all). Unlike `onPointerPresence` this is not
    /// throttled — it fires at most once per actual display change, decided
    /// on the tap thread with a cheap `CGGetDisplaysWithPoint` lookup — so
    /// the indicator can follow the pointer between screens as promptly as
    /// it follows it between Macs (where the first event on the other Mac
    /// always passes the presence throttle). Fired from the tap thread.
    var onPointerDisplayChanged: (() -> Void)?
    private var lastPointerDisplay: CGDirectDisplayID?
    /// Injectable so tests can swap in a fake clock without sleeping;
    /// mirrors `modifierStateProbe`/`watchdogInterval` below.
    var pointerPresenceThrottle = PointerPresenceThrottle()

    /// The permission checks and requests, injectable so tests never touch
    /// the real privacy settings.
    struct PermissionAccess {
        var accessibilityGranted: () -> Bool
        var inputMonitoringGranted: () -> Bool
        var requestAccessibility: () -> Void
        var requestInputMonitoring: () -> Void

        static let live = PermissionAccess(
            accessibilityGranted: { HotkeyService.isAccessibilityGranted },
            inputMonitoringGranted: { HotkeyService.isInputMonitoringGranted },
            requestAccessibility: { HotkeyService.requestAccessibilityPrompt() },
            requestInputMonitoring: { HotkeyService.requestInputMonitoringPrompt() })
    }

    var permissions = PermissionAccess.live

    /// When true, the first `start()` in this process that fails for lack of
    /// a permission asks for it once (`requestMissingPermissions`). Later
    /// failures, retries and the health monitor never ask: asking again is
    /// for a deliberate step, like a button in a welcome or Settings. Set it
    /// false before setup to leave all asking to such a step.
    nonisolated(unsafe) static var promptsForMissingPermissionsOnFirstStart = true
    /// Set once the first-start request has been made.
    nonisolated(unsafe) static var firstStartRequestUsed = false

    /// Asks macOS for whichever of Input Monitoring and Accessibility is
    /// missing, and nothing when both are granted. For a user's action.
    /// Returns what it asked for.
    @discardableResult
    static func requestMissingPermissions(_ access: PermissionAccess = .live) -> (inputMonitoring: Bool, accessibility: Bool) {
        let askInput = !access.inputMonitoringGranted()
        let askAccessibility = !access.accessibilityGranted()
        guard askInput || askAccessibility else { return (false, false) }
        recordDiagnostics("asking for permission inputMonitoring=\(askInput) accessibility=\(askAccessibility)")
        if askInput { access.requestInputMonitoring() }
        if askAccessibility { access.requestAccessibility() }
        return (askInput, askAccessibility)
    }

    /// Failed starts in a row; back to 0 after a good start. Keeps the
    /// 5-second health monitor from writing the same failure forever.
    private(set) var consecutiveStartFailures = 0

    /// Log the 1st, 2nd, 4th, 8th… failure in a row, not every one.
    static func shouldLogStartFailure(_ count: Int) -> Bool {
        count > 0 && count & (count - 1) == 0
    }

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPrompt() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var isInputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    static func requestInputMonitoringPrompt() {
        _ = CGRequestListenEventAccess()
    }

    /// How the listener is actually receiving events. Recorded so a degraded
    /// start is never silent again — see `diagnosticsPath`.
    enum Mode: String {
        case intercept       // active tap: global, can swallow events
        case listenOnly      // passive tap: global, cannot swallow events
        case nseventGlobal   // AppKit monitors: needs Accessibility to see other apps
        case none
    }

    private(set) var mode: Mode = .none

    /// Diagnostics record of what the listener negotiated at launch. The hotkey
    /// failing is otherwise invisible — the app looks healthy while push-to-talk
    /// is dead outside its own window.
    ///
    /// Under XCTest the default is a temporary file, so test runs never write
    /// lines into the real log in `~/Library/Logs/Dictator`.
    static var diagnosticsPath: URL = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("dictator-tests-\(ProcessInfo.processInfo.processIdentifier)/hotkey.log")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Dictator/hotkey.log")
    }()
    private static let diagnosticsRotationSize: Int64 = 1_000_000
    private static let diagnosticsLock = NSLock()

    static func recordDiagnostics(_ line: String) {
        let url = diagnosticsPath
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }

        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }

        let rotatedURL = url.appendingPathExtension("1")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let currentSize = (attributes[.size] as? NSNumber)?.int64Value,
           currentSize + Int64(data.count) > diagnosticsRotationSize {
            try? FileManager.default.removeItem(at: rotatedURL)
            try? FileManager.default.moveItem(at: url, to: rotatedURL)
        }

        // A single POSIX write() opened O_APPEND keeps each entry intact while
        // the lock also makes rotation safe against other diagnostics callers.
        let fd = url.path.withCString { open($0, O_WRONLY | O_APPEND | O_CREAT, 0o644) }
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    // MARK: - Tap trace (DICTATOR_HOTKEY_TRACE)

    /// Whether raw-event tracing is on. Read once at first use — this is a
    /// diagnostics switch for Universal Control experiments across machines,
    /// not something that needs to react to a live defaults change.
    ///
    /// Enable it either way:
    ///   - env var: `DICTATOR_HOTKEY_TRACE=1` (only reaches a debug launch)
    ///   - defaults, since LaunchServices launches don't inherit shell env:
    ///     `defaults write dev.noamlitt.dictator hotkeyTrace -bool true`
    static let isTraceEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment["DICTATOR_HOTKEY_TRACE"]
        if env == "1" || env?.lowercased() == "true" { return true }
        return UserDefaults.standard.bool(forKey: "hotkeyTrace")
    }()

    /// Serial queue so trace writes never block the event tap callback.
    private static let traceQueue = DispatchQueue(
        label: "dev.noamlitt.dictation.hotkey-trace", qos: .utility
    )

    private static let traceLimiter = HotkeyTraceLimiter()

    static func shouldTrace(type: String, keyCode: CGKeyCode) -> Bool {
        type != "keyDown" || tracedKeyCodes.contains(keyCode)
    }

    /// Formats one trace line. Factored out so the flag/HID parsing is
    /// testable without a live CGEvent tap.
    static func traceLine(
        type: String, keyCode: CGKeyCode, flags: CGEventFlags, pressed: Bool,
        hidDevAlt: Bool, hidAlt: Bool, src: Int64
    ) -> String {
        let rightOption = flags.contains(rightOptionFlag)
            || (keyCode == rightOptionKeyCode && flags.contains(.maskAlternate))
        return "trace type=\(type) keyCode=\(keyCode) flags=0x\(String(flags.rawValue, radix: 16)) "
            + "rightOption=\(rightOption ? 1 : 0) pressed=\(pressed ? 1 : 0) "
            + "hidRightOption=\((hidDevAlt || hidAlt) ? 1 : 0) hidDevAlt=\(hidDevAlt ? 1 : 0) "
            + "hidAlt=\(hidAlt ? 1 : 0) src=\(src)"
    }

    /// Appends a trace line for one flagsChanged, special keyDown, or
    /// leftMouseDown event. Ordinary keyDown events are intentionally omitted
    /// so tracing cannot become a typing transcript.
    /// rate-limited to at most 50/s. The limiter itself is consulted here, on
    /// the event tap thread (it's cheap and `HotkeyTraceLimiter` is
    /// lock-protected) — only a decision we're actually going to act on gets
    /// dispatched onto `traceQueue`, so a flood of events can't build an
    /// unbounded backlog of closures there. File I/O itself still never runs
    /// on the tap thread synchronously.
    private static let tracedKeyCodes: Set<CGKeyCode> = [rightOptionKeyCode, escKeyCode, tabKeyCode]

    private static func trace(type: String, keyCode: CGKeyCode, flags: CGEventFlags, pressed: Bool, event: CGEvent) {
        guard isTraceEnabled, shouldTrace(type: type, keyCode: keyCode) else { return }
        let hidState = CGEventSource.flagsState(.hidSystemState)
        let hidDevAlt = hidState.contains(rightOptionFlag)
        let hidAlt = hidState.contains(.maskAlternate)
        let src = event.getIntegerValueField(.eventSourceUnixProcessID)
        let line = traceLine(
            type: type, keyCode: keyCode, flags: flags, pressed: pressed,
            hidDevAlt: hidDevAlt, hidAlt: hidAlt, src: src
        )
        switch traceLimiter.allow() {
        case .allowed:
            traceQueue.async { recordDiagnostics(line) }
        case .dropped:
            break
        case .allowedWithDroppedReport(let dropped):
            traceQueue.async {
                recordDiagnostics("trace dropped=\(dropped)")
                recordDiagnostics(line)
            }
        }
    }

    /// Starts the listener. Never asks for permissions itself, except the
    /// one first-start request (`promptsForMissingPermissionsOnFirstStart`).
    func start() throws {
        try start(mayRequestPermissions: true)
    }

    private func start(mayRequestPermissions: Bool) throws {
        triggers = AppSettings.shared.hotkeyTriggers
        guard eventTap == nil, globalMonitor == nil, localMonitor == nil else { return }

        // leftMouseDown is trace-only (see DICTATOR_HOTKEY_TRACE) plus the
        // pointer-presence hook below; mouseMoved is pointer-presence only
        // (never traced — it would flood the 50/s trace limiter and starve
        // the events that actually matter for diagnostics). Neither is ever
        // swallowed, and neither changes `isPressed`.
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue)

        let accessibility = permissions.accessibilityGranted()
        let inputMonitoring = permissions.inputMonitoringGranted()
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        var createdTap: CFMachPort?

        func makeTap(_ options: CGEventTapOptions) -> CFMachPort? {
            CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                eventsOfInterest: eventMask, callback: hotkeyCallback, userInfo: userInfo
            )
        }

        // Tier 1 — active tap. Needs Accessibility. Global, and the only tier
        // that can swallow an event (a voice-launch pause's Esc).
        if accessibility {
            createdTap = makeTap(.defaultTap)
            if createdTap != nil {
                mode = .intercept
            }
        }

        // Tier 2 — passive tap. Needs only Input Monitoring (kTCCServiceListenEvent),
        // not Accessibility. A .listenOnly tap on .cgSessionEventTap still observes
        // the whole session, so push-to-talk keeps working everywhere; only
        // swallowing events is lost. This tier must be tried before the AppKit
        // fallback: skipping it is what left the app foreground-only whenever
        // Accessibility was unavailable.
        if createdTap == nil, inputMonitoring {
            createdTap = makeTap(.listenOnly)
            if createdTap != nil {
                mode = .listenOnly
            }
        }

        if let tap = createdTap {
            eventTap = tap
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            finishStart(accessibility: accessibility, inputMonitoring: inputMonitoring)
            return
        }

        // Tier 3 — AppKit monitors. AppKit documents that key events reach a
        // global monitor only when the process is trusted for Accessibility;
        // without it the global monitor is installed but silently never fires
        // while the local monitor keeps working, i.e. the hotkey responds only
        // while our own window is focused. So this tier is worth taking only
        // when Accessibility is granted and tapCreate still refused.
        if accessibility {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .mouseMoved]
            ) { [weak self] event in
                guard let cgEvent = event.cgEvent else { return }
                _ = self?.handleEvent(cgEvent)
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .mouseMoved]
            ) { [weak self] event in
                if let cgEvent = event.cgEvent, self?.handleEvent(cgEvent) == true {
                    return nil // consumed (an Esc a voice-launch pause owns)
                }
                return event
            }

            if globalMonitor != nil, localMonitor != nil {
                mode = .nseventGlobal
                finishStart(accessibility: accessibility, inputMonitoring: inputMonitoring)
                return
            }
            removeEventMonitors()
        }

        // Nothing global is possible. Report the grant that actually unblocks
        // push-to-talk. Asking for it is a separate, deliberate step
        // (`requestMissingPermissions`), apart from the one first-start
        // request: a health check retrying every few seconds must never keep
        // calling the system's permission requests.
        mode = .none
        let error: HotkeyError = inputMonitoring ? .accessibilityNotGranted : .inputMonitoringNotGranted
        consecutiveStartFailures += 1
        if Self.shouldLogStartFailure(consecutiveStartFailures) {
            Self.recordDiagnostics(
                "start FAILED mode=none accessibility=\(accessibility) "
                + "inputMonitoring=\(inputMonitoring) reason=\(error) failuresInARow=\(consecutiveStartFailures) "
                + "bundle=\(Bundle.main.bundlePath)"
            )
        }
        if mayRequestPermissions, Self.promptsForMissingPermissionsOnFirstStart, !Self.firstStartRequestUsed {
            Self.firstStartRequestUsed = true
            Self.requestMissingPermissions(permissions)
        }
        throw error
    }

    private func finishStart(accessibility: Bool, inputMonitoring: Bool) {
        protectBackgroundLifetime()
        NSLog("[Dictation] hotkey listener started, mode=%@", mode.rawValue)
        Self.recordDiagnostics(
            "start ok mode=\(mode.rawValue) accessibility=\(accessibility) "
            + "inputMonitoring=\(inputMonitoring) "
            + "bundle=\(Bundle.main.bundlePath)"
        )
        if Self.isTraceEnabled {
            Self.recordDiagnostics("trace enabled mode=\(mode.rawValue)")
        }
        consecutiveStartFailures = 0
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        mode = .none
        isPressed = false
        commandAppBundleID = nil
        stopModifierWatchdog()
        removeEventMonitors()
        if protectsBackgroundLifetime {
            ProcessInfo.processInfo.enableAutomaticTermination("Global hotkey listener active")
            ProcessInfo.processInfo.enableSuddenTermination()
            protectsBackgroundLifetime = false
        }
    }

    /// Repairs a tap invalidated by sleep, fast-user switching, or a transient
    /// WindowServer/TCC reset. These failures otherwise leave the menu-bar app
    /// looking idle while the push-to-talk key silently does nothing.
    @discardableResult
    func ensureHealthy() throws -> Bool {
        if let tap = eventTap {
            if CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) {
                return false
            }

            cancelPressedSessionAfterListenerLoss()
            if CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) {
                    Self.recordDiagnostics("hotkey tap re-enabled by watchdog mode=\(mode.rawValue)")
                    return true
                }
            }
        } else if globalMonitor != nil, localMonitor != nil {
            return false
        }

        // Only the first of a run of failed rebuilds is logged (the failure
        // itself is logged on a widening schedule by `start`).
        if consecutiveStartFailures == 0 { Self.recordDiagnostics("hotkey listener unhealthy; rebuilding") }
        stop()
        try start(mayRequestPermissions: false)
        Self.recordDiagnostics("hotkey listener recovered mode=\(mode.rawValue)")
        return true
    }

    /// A lost tap may also lose the matching Right Option key-up, but the
    /// audio captured so far up to this point is still valid — unlike an Esc
    /// cancel, this isn't the user asking to discard the take. Stop the
    /// session (as if the key had been released) rather than cancelling it.
    fileprivate func cancelPressedSessionAfterListenerLoss() {
        guard isPressed else { return }
        endPress()
        Self.recordDiagnostics("hotkey listener interrupted during hold; stopping capture")
        onStop?(.listenerLoss)
    }

    // MARK: - Modifier watchdog (Universal Control key-up loss)

    /// Starts polling `modifierStateProbe` every `watchdogInterval` while the
    /// key is believed held. Internal (not private) so tests can drive it
    /// directly with a fake probe, without a live CGEvent tap.
    func startModifierWatchdog() {
        modifierWatchdogTimer?.invalidate()
        modifierWatchdogMissCount = 0
        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.pollModifierWatchdog()
        }
        modifierWatchdogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops polling. Called on every path that clears `isPressed` — normal
    /// release, Esc cancel, `stop()`, and listener loss — so the timer never
    /// outlives the hold it was watching.
    func stopModifierWatchdog() {
        modifierWatchdogTimer?.invalidate()
        modifierWatchdogTimer = nil
        modifierWatchdogMissCount = 0
        heldTriggerKeys.removeAll() // a lost key-up must not read as held on the next press
    }

    private func pollModifierWatchdog() {
        guard isPressed else {
            stopModifierWatchdog()
            return
        }

        let flags = modifierStateProbe()
        let rightHeld = triggers.isHeldPhysically(flags: flags, keyIsDown: chordLatchKeyIsDown)
        if rightHeld {
            modifierWatchdogMissCount = 0
            return
        }

        // Require two consecutive "not held" reads before acting: the first
        // poll can land before a slow flagsChanged→HID-state propagation has
        // caught up, and firing on that alone would false-trigger right after
        // a genuine press.
        modifierWatchdogMissCount += 1
        guard modifierWatchdogMissCount >= 2 else { return }

        endPress()
        Self.recordDiagnostics("hotkey watchdog: modifier released without key-up; synthesizing stop")
        onStop?(.modifierWatchdog)
    }

    /// Test-only: feeds one event through the same path as the live tap.
    @discardableResult
    func handleEventForTesting(_ event: CGEvent) -> Bool { handleEvent(event) }

    /// Test-only: simulates a key press without a live CGEvent tap, so
    /// `HotkeyWatchdogTests` can drive the watchdog directly.
    func simulatePressForTesting() {
        isPressed = true
    }

    private func removeEventMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func protectBackgroundLifetime() {
        guard !protectsBackgroundLifetime else { return }
        ProcessInfo.processInfo.disableAutomaticTermination("Global hotkey listener active")
        ProcessInfo.processInfo.disableSuddenTermination()
        protectsBackgroundLifetime = true
    }

    /// Set when a Right-Option press was ignored because a shortcut was being
    /// recorded. The press stays ignored until Right Option is released, so letting
    /// go of the other keys first cannot start a dictation.
    private(set) var waitingForDictationKeyRelease = false
    /// Whether the dictation key is physically down. Replaceable so tests can drop a release.
    lazy var dictationKeyIsDown: () -> Bool = { [unowned self] in
        let isDown: (CGKeyCode) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: $0) }
        return triggers.dictation.keyCodes.allSatisfy(isDown) || triggers.commands.keyCodes.allSatisfy(isDown)
    }
    private var releaseWatchdog: Timer?

    private func setWaitingForRelease(_ waiting: Bool) {
        waitingForDictationKeyRelease = waiting
        releaseWatchdog?.invalidate()
        releaseWatchdog = nil
        guard waiting else { return }
        // The release may never reach this Mac (Universal Control), so look at the keyboard itself.
        releaseWatchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.clearLatchIfKeyIsUp() }
    }

    private var lastSampledDictationKeyDown = false

    /// Samples the physical dictation key. Clears the latch when the key is up, or when it went
    /// from up to down since the last sample (a down edge proves the earlier release happened).
    /// Never sends a stop. Runs for every event the tap sees, and on the watchdog timer.
    func clearLatchIfKeyIsUp() {
        let was = lastSampledDictationKeyDown, now = dictationKeyIsDown()
        lastSampledDictationKeyDown = now
        if waitingForDictationKeyRelease && !Self.isRecordingWorkspaceShortcut && !(was && now) { setWaitingForRelease(false) }
    }

    /// Ends the current press: clears its state and stops the release watchdog.
    private func endPress() {
        isPressed = false
        voiceCommandMode = false
        commandAppBundleID = nil
        stopModifierWatchdog()
    }

    /// The push-to-talk state machine for one flagsChanged event.
    func applyModifierState(rightHeld: Bool, shiftHeld: Bool) {
        clearLatchIfKeyIsUp()
        if !rightHeld { chordSuppressed = false }
        if rightHeld && !isPressed && !chordSuppressed {
            if Self.isRecordingWorkspaceShortcut || waitingForDictationKeyRelease {
                if !waitingForDictationKeyRelease { setWaitingForRelease(true) }
            } else {
                isPressed = true
                voiceCommandMode = false
                pressedAt = now()
                commandAppBundleID = frontmostAppBundleID()
                onStart?()
                startModifierWatchdog()
            }
        } else if !rightHeld {
            if waitingForDictationKeyRelease { setWaitingForRelease(false) }
            if isPressed {
                endPress()
                onStop?(.key)
            }
        }
        if isPressed && shiftHeld && !voiceCommandMode {
            voiceCommandMode = true
            onVoiceCommandMode?()
            commandAppBundleID = nil
        }
    }

    /// Checks both triggers against the keys that are down.
    private func evaluateTriggers(flags: CGEventFlags, eventKeyCode: CGKeyCode) {
        let commandHeld = triggers.commands.isHeld(flags: flags, eventKeyCode: eventKeyCode, regularKeys: heldTriggerKeys)
        let dictationHeld = triggers.dictation.isHeld(flags: flags, eventKeyCode: eventKeyCode, regularKeys: heldTriggerKeys)
        if commandHeld { activeTrigger = triggers.commands } else if dictationHeld { activeTrigger = triggers.dictation }
        applyModifierState(rightHeld: dictationHeld || commandHeld, shiftHeld: commandHeld)
    }

    /// A key down or up for a regular key that is part of a trigger, such as
    /// F13. Returns true when the event was the trigger's, so it should not
    /// reach the app in front or count as typing.
    private func handleTriggerKey(_ event: CGEvent, keyCode: CGKeyCode) -> Bool {
        guard !Self.isRecordingWorkspaceShortcut, !PasteService.isSyntheticEvent(event) else { return false }
        if event.type == .keyUp {
            heldTriggerKeys.remove(keyCode)
            guard swallowedTriggerKeys.remove(keyCode) != nil else { return false }
            evaluateTriggers(flags: event.flags, eventKeyCode: keyCode)
            return true
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return swallowedTriggerKeys.contains(keyCode) }
        guard triggers.startsWith(regularKey: keyCode, flags: event.flags) else { return false }
        heldTriggerKeys.insert(keyCode)
        swallowedTriggerKeys.insert(keyCode)
        evaluateTriggers(flags: event.flags, eventKeyCode: keyCode)
        return true
    }

    /// Returns true if the event should be swallowed (consumed): an Esc owned
    /// by a voice-launch pause, or a regular key that is part of a dictation or
    /// command trigger, such as F13. leftMouseDown is trace-only (see
    /// DICTATOR_HOTKEY_TRACE below) plus the pointer-presence hook further down;
    /// mouseMoved is pointer-presence only. Neither is ever consumed, and neither
    /// changes `isPressed`.
    fileprivate func handleEvent(_ event: CGEvent) -> Bool {
        let type = event.type
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        var consumed = false
        clearLatchIfKeyIsUp()   // before anything else, for every event type the tap sees
        releaseChordLatchIfKeyUp() // a lost key-up must not leave the next hold ignored

        if type == .keyDown, keyCode == Self.escKeyCode, !PasteService.isSyntheticEvent(event),
           VoiceLaunchEscapeWatch.fire() { // a "Sending in 3 s" pause, if one is showing
            // That pause owns this Esc: keep it from also reaching the app in
            // front (it could close the chat the message is waiting in). Only
            // the active tap and the local monitor can hold an event back;
            // in the other modes it still passes through.
            consumed = true
        }

        if type == .flagsChanged {
            // Evaluate the Right-Option hold on every flagsChanged, not only
            // events whose keycode field reads 61. A release event's keycode is
            // not always reliable; gating stop on keyCode == 61 could miss the
            // release and leave push-to-talk stuck recording forever. The 0x40
            // device bit is the source of truth; the generic Option mask is a
            // fallback for keyboards that don't report 0x40 (trusted only on the
            // right-Option keycode so left Option can't trigger a false start).
            evaluateTriggers(flags: event.flags, eventKeyCode: keyCode)
        } else if type == .keyDown || type == .keyUp, triggers.regularKeys.contains(keyCode),
                  handleTriggerKey(event, keyCode: keyCode) {
            consumed = true
        } else if type == .keyDown, DictationChord.isCharacterChord(
            dictationHeld: isPressed, secondsSincePress: now().timeIntervalSince(pressedAt),
            pressedKeyCode: keyCode, trigger: activeTrigger ?? triggers.dictation, isSynthetic: PasteService.isSyntheticEvent(event)
        ) {
            // The dictation key was only the first half of a typed character
            // (Right Option on a Hebrew, Polish or German layout). Drop the
            // session quietly and let the key through.
            endPress()
            chordSuppressed = true
            Self.recordDiagnostics("hotkey: another key during the hold; treated as a typed character, session dropped")
            onCharacterChord?()
            if onTypingActivity != nil, let activity = classifyTypingActivity(keyCode: keyCode, flags: event.flags, event: event) {
                onTypingActivity?(activity)
            }
        } else if type == .keyDown && keyCode == Self.escKeyCode && (isPressed || cancelEligible) {
            endPress()
            onCancel?()
        } else if type == .keyDown && keyCode == Self.tabKeyCode {
            onTypingActivity?(.caretOrSelectionChanged)
        } else if type == .keyDown, onTypingActivity != nil, !PasteService.isSyntheticEvent(event) {
            // Any other keystroke may have changed the buffer/caret.
            if let activity = classifyTypingActivity(keyCode: keyCode, flags: event.flags, event: event) {
                onTypingActivity?(activity)
            }
        }
        // leftMouseDown and mouseMoved fall through here untouched: no
        // branch above matches either, so neither is ever swallowed and
        // neither mutates state.

        switch type {
        case .flagsChanged:
            Self.trace(type: "flagsChanged", keyCode: keyCode, flags: event.flags, pressed: isPressed, event: event)
        case .keyDown:
            Self.trace(type: "keyDown", keyCode: keyCode, flags: event.flags, pressed: isPressed, event: event)
        case .leftMouseDown:
            Self.trace(type: "leftMouseDown", keyCode: keyCode, flags: event.flags, pressed: isPressed, event: event)
        default:
            break
        }

        // Focus-claim activity hook, placed after everything above so it
        // never changes hotkey/tab/typing behavior. A click or an editing
        // keystroke on this Mac is evidence the user is now
        // working here; FocusClaimDetector debounces/throttles this into an
        // Edge→Core focus claim. Our own synthetic ⌘V (PasteService pasting
        // a transcription) must never look like local activity, or a paste
        // would claim focus right back for the machine that just gave it
        // up — so it's excluded up front, before either branch below.
        // flagsChanged never reaches here.
        if !PasteService.isSyntheticEvent(event) {
            switch type {
            case .leftMouseDown:
                onFocusActivity?(.click)
            case .keyDown:
                if isFocusKeystroke(keyCode: keyCode, flags: event.flags) {
                    onFocusActivity?(.keystroke)
                }
            default:
                break
            }
        }

        // Pointer-presence hook (Universal Control initiator/target fix —
        // see `EdgeMessage.pointerPresence`): only the Mac that currently
        // owns the on-screen pointer ever receives mouseMoved/leftMouseDown
        // from its own tap, unlike a keyDown, which Universal Control can
        // deliver to both Macs' taps for the same physical keystroke (see
        // the focus-claim hook above). That makes this the one unambiguous
        // "the user is on this Mac" signal. leftMouseDown fires immediately
        // (a click is exactly the moment presence matters most);
        // `mouseMoved` is throttled — it can fire hundreds of times a
        // second while the pointer is moving, and every firing is a
        // WebSocket message to the Core.
        switch type {
        case .leftMouseDown:
            PointerLocationTracker.shared.update(event.location)
            onPointerPresence?()
            if !PasteService.isSyntheticEvent(event) { onMouseDown?() }
        case .mouseMoved:
            if pointerPresenceThrottle.allow() {
                onPointerPresence?()
            }
            notePointerDisplay(at: event.location)
        default:
            break
        }

        return consumed
    }

    /// See `onPointerDisplayChanged`. `CGGetDisplaysWithPoint` is a plain
    /// Core Graphics call, safe off the main thread, and the event location
    /// is already in the same global top-left coordinate space it expects.
    private func notePointerDisplay(at point: CGPoint) {
        PointerLocationTracker.shared.update(point)
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else { return }
        guard display != lastPointerDisplay else { return }
        lastPointerDisplay = display
        onPointerDisplayChanged?()
    }

    /// True if this keyDown is evidence of typing into a field, for the
    /// focus-claim hook above. Excludes the push-to-talk hotkey and Esc
    /// (never text input), and any Command/Control shortcut chord —
    /// except ⌘V, which (from a real, non-synthetic source — already
    /// filtered by the caller) is exactly the user pasting into a field.
    private func isFocusKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        if triggers.keyCodes.contains(keyCode) || keyCode == Self.escKeyCode { return false }

        let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl]
        guard !flags.intersection(shortcutModifiers).isEmpty else { return true }

        let isRealCmdV = keyCode == Self.ansiVKeyCode && flags.contains(.maskCommand)
        return isRealCmdV
    }

    private func classifyTypingActivity(keyCode: CGKeyCode, flags: CGEventFlags, event: CGEvent) -> TypingActivity? {
        let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl]
        let isReturn = Int(keyCode) == kVK_Return || Int(keyCode) == kVK_ANSI_KeypadEnter
        if flags.contains(.maskCommand), Int(keyCode) == kVK_ANSI_V, !flags.contains(.maskControl) {
            return .paste
        }
        if isReturn, flags.contains(.maskCommand) {
            return .newline // ⌘Return sends in many chat apps
        }
        if !flags.intersection(shortcutModifiers).isEmpty {
            return .caretOrSelectionChanged
        }

        switch Int(keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            return .deleteBackward
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags.contains(.maskShift) || flags.contains(.maskAlternate) {
                return .softNewline
            }
            return .newline
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Escape:
            return .caretOrSelectionChanged
        default:
            break
        }

        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }

        let string = String(utf16CodeUnits: buffer, count: length)
        guard !string.isEmpty else { return nil }
        if let scalar = string.unicodeScalars.first, scalar.value < 0x20 {
            return nil
        }
        return .text(string)
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // The matching key-up may have been lost, so cancel a live hold before
        // re-enabling the tap.
        if let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue() as HotkeyService? {
            service.cancelPressedSessionAfterListenerLoss()
            if let tap = service.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
    let consumed = service.handleEvent(event)

    return consumed ? nil : Unmanaged.passUnretained(event)
}

enum HotkeyError: Error, LocalizedError {
    case accessibilityNotGranted
    case inputMonitoringNotGranted
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            "Dictator needs Accessibility to type your words. Allow it in System Settings › Privacy & Security › Accessibility, then quit and reopen Dictator."
        case .inputMonitoringNotGranted:
            "Dictator needs Input Monitoring to notice your dictation key. Allow it in System Settings › Privacy & Security › Input Monitoring, then quit and reopen Dictator."
        case .tapCreationFailed:
            "Dictator couldn’t start watching for your dictation key. Allow Input Monitoring, then quit and reopen Dictator."
        }
    }
}
