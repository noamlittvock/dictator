import AppKit
import ApplicationServices

enum NativeResetError: LocalizedError, WorkspaceRecoveryFailure {
    case accessibilityNotGranted
    case accessibilityRestorePending
    case windowNotFound(String)
    case processTerminated(String)
    case processIdentityMismatch(String)
    case moveFailed(String)
    case frameMismatch(String)
    case appNotFound(String)
    case hideProtected(String)
    case hideFailed(String)
    case unhideFailed(String)
    case captureFailed(String)
    case displayUnavailable

    var canRetryRecovery: Bool {
        switch self {
        case .windowNotFound, .processTerminated, .processIdentityMismatch, .appNotFound: return false
        default: return true
        }
    }

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted: return "Allow Dictator in Accessibility to arrange windows."
        case .accessibilityRestorePending: return "Dictator changed a setting in an app to move its windows and couldn't change it back. Try Undo or run the routine again."
        case .windowNotFound, .processTerminated, .processIdentityMismatch, .appNotFound:
            return "A window or app closed or restarted. Run the routine again."
        case .moveFailed, .frameMismatch:
            return "An app wouldn't let Dictator move or resize one of its windows."
        case .hideProtected: return "An app is in use and was left visible."
        case .hideFailed: return "One of the chosen apps wouldn't hide."
        case .unhideFailed: return "A hidden app wouldn't come back. Click it in the Dock to show it."
        case .displayUnavailable: return "That window's spot is on a screen that isn't connected. Connect it, then try again."
        case .captureFailed: return "Dictator couldn't read some windows. Run the routine again."
        }
    }
}

/// The real AX path and synthetic contracts share the same writes, settling
/// and rollback. A successful setter need not imply an immediately fresh read.
enum WorkspaceFrameApplication {
    nonisolated static func apply(original: WorkspaceRect, target: WorkspaceRect,
                                  setSize: (WorkspaceRect) throws -> Void,
                                  setPosition: (WorkspaceRect) throws -> Void,
                                  readFrame: () throws -> WorkspaceRect,
                                  pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
                                  diagnostic: (String) -> Void = { _ in }) throws {
        func rollback() {
            // Attempt each write even if another fails; never claim rollback
            // succeeded merely because it was attempted. Undo retains its own snapshot.
            for step in 0..<3 {
                do {
                    if step == 1 { try setPosition(original) }
                    else { try setSize(original) }
                }
                catch { diagnostic("workspace: frame rollback write failed: \(error)") }
            }
        }
        do {
            var actual: WorkspaceRect?
            var readError: Error?
            @discardableResult func confirmStage(_ stage: String, required: Bool = true, accepts: (WorkspaceRect) -> Bool) throws -> Bool {
                let deadline = ProcessInfo.processInfo.systemUptime + 0.4
                for attempt in 1...6 {
                    pause(0.05)
                    let frame = try readFrame()
                    actual = frame
                    diagnostic("workspace: frame stage=\(stage) attempt=\(attempt) desired=\(target) observed=\(frame)")
                    if accepts(frame) { return true }
                    guard attempt < 6, ProcessInfo.processInfo.systemUptime < deadline else { break }
                }
                if required { throw NativeResetError.frameMismatch("Frame stage \(stage) did not settle: desired=\(target), observed=\(String(describing: actual)).") }
                diagnostic("workspace: frame stage=\(stage) remains constrained; continue with resize before final position")
                return false
            }
            // Moving a tall target-size window at its old origin can clamp its
            // height and overwrite a newer position. Move before that resize.
            // If the old size itself constrains the move across displays, a
            // bounded position wait may finish without a match: resize next,
            // then position again and require full final-frame verification.
            try setPosition(target)
            try confirmStage("initial-position", required: false) { abs($0.x - target.x) <= 4 && abs($0.y - target.y) <= 4 }
            try setSize(target)
            try confirmStage("initial-size", required: false) { observed in
                var sizeAtTargetOrigin = observed
                sizeAtTargetOrigin.x = target.x; sizeAtTargetOrigin.y = target.y
                return WorkspaceGeometry.isAcceptableResult(sizeAtTargetOrigin, for: target)
            }
            try setPosition(target)
            pause(0.05)
            for pass in 0..<2 {
                if pass == 1 {
                    // AX setters can acknowledge an asynchronously applied full
                    // frame. Batched writes may then overwrite a newer origin
                    // using the old origin captured by a resize. Reapply in
                    // separated stages, resizing only after the move settles.
                    diagnostic("workspace: frame corrective pass desired=\(target), lastObserved=\(String(describing: actual))")
                    try setPosition(target)
                    try confirmStage("position") { abs($0.x - target.x) <= 4 && abs($0.y - target.y) <= 4 }
                    try setSize(target)
                    try confirmStage("size") { observed in
                        var sizeAtTargetOrigin = observed
                        sizeAtTargetOrigin.x = target.x; sizeAtTargetOrigin.y = target.y
                        return WorkspaceGeometry.isAcceptableResult(sizeAtTargetOrigin, for: target)
                    }
                    try setPosition(target)
                    pause(0.05)
                }
                // Soft retry deadline between IPC calls, not a wall-clock
                // limit: each AX query also has its own messaging timeout.
                let deadline = ProcessInfo.processInfo.systemUptime + 0.4
                for attempt in 1...6 {
                    do {
                        let frame = try readFrame()
                        actual = frame
                        diagnostic("workspace: frame verify pass=\(pass) attempt=\(attempt) desired=\(target) observed=\(frame)")
                        if WorkspaceGeometry.isAcceptableResult(frame, for: target) { return }
                    } catch {
                        readError = error
                        diagnostic("workspace: frame read failed pass=\(pass) attempt=\(attempt): \(error)")
                    }
                    guard attempt < 6, ProcessInfo.processInfo.systemUptime < deadline else { break }
                    pause(0.05)
                }
            }
            throw NativeResetError.frameMismatch("Frame did not settle: desired=\(target), observed=\(String(describing: actual)), readError=\(String(describing: readError)).")
        } catch {
            diagnostic("workspace: frame apply failed desired=\(target): \(error)")
            rollback()
            throw error
        }
    }
}

/// Setter acknowledgements can disagree with the observed application state.
/// Only readback decides whether a temporary mode change actually occurred.
enum WorkspaceFrameAccessibilityScope {
    nonisolated static func restore(read: () -> Bool?, write: (Bool) throws -> Void,
                                    pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
                                    diagnostic: (String) -> Void) -> Bool {
        for attempt in 1...3 {
            // Always enqueue restoration after the disable/adjustment. A true
            // pre-read may precede a delayed disable and cannot cancel this duty.
            do { try write(true) }
            catch { diagnostic("workspace: frame enhancedUI restore ACK error attempt=\(attempt): \(error)") }
            pause(0.05)
            let first = read()
            pause(0.05)
            let second = read()
            diagnostic("workspace: frame enhancedUI restore attempt=\(attempt) observedFirst=\(String(describing: first)) observedSecond=\(String(describing: second))")
            if first == true, second == true { return true }
        }
        return false
    }

    nonisolated static func perform(builtInAssistiveActive: Bool, settable: Bool?,
                                    read: () -> Bool?, write: (Bool) throws -> Void,
                                    pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
                                    diagnostic: (String) -> Void, restorationPending: () -> Void,
                                    adjustment: () throws -> Void) throws {
        let original = read()
        diagnostic("workspace: frame enhancedUI original=\(String(describing: original)) settable=\(String(describing: settable)) builtInAssistiveActive=\(builtInAssistiveActive)")
        guard original == true, settable == true, !builtInAssistiveActive else { try adjustment(); return }
        do { try write(false) }
        catch { diagnostic("workspace: frame enhancedUI disable ACK error: \(error)") }
        let actual = read()
        diagnostic("workspace: frame enhancedUI afterDisableObserved=\(String(describing: actual))")
        // A first true read can be stale while a disable is queued. Keep the
        // restoration obligation for every attempted disable, regardless of ACK.
        var operationError: Error?
        if actual != nil {
            do { try adjustment() } catch { operationError = error }
        } else {
            operationError = NativeResetError.moveFailed("Enhanced UI state could not be observed after a disable attempt.")
        }
        guard restore(read: read, write: write, pause: pause, diagnostic: diagnostic) else {
            restorationPending()
            diagnostic("workspace: frame enhancedUI RESTORATION PENDING; operationError=\(String(describing: operationError))")
            throw NativeResetError.accessibilityRestorePending
        }
        diagnostic("workspace: frame enhancedUI original=true restoredObserved=true")
        if let operationError { throw operationError }
    }
}

private struct NativeAccessibilityRestoreTarget: @unchecked Sendable {
    let application: AXUIElement
    let pid: pid_t
    let launchDate: Date
    let bundleID: String
    var key: String { "\(pid):\(launchDate.timeIntervalSinceReferenceDate):\(bundleID)" }
}
private struct NativeFrameMoveOutcome: @unchecked Sendable {
    var error: Error?
    var pendingRestore: NativeAccessibilityRestoreTarget?
}

private struct WindowHandle: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let launchDate: Date?
    let bundleID: String
}

private struct DisplayLayoutInfo: Sendable {
    let id: String
    let axFrame: WorkspaceRect
}

private struct NativeCaptureApplication: Sendable {
    let processIdentifier: pid_t
    let launchDate: Date?
    let bundleIdentifier: String
    let localizedName: String
    let isHidden: Bool
}
private struct NativeCaptureResult: @unchecked Sendable {
    var windows: [WorkspaceWindow]
    var handles: [String: WindowHandle]
    var frontmostWindowID: String?
    var notes: [String]
    var skipped: [WorkspaceSkip]
}

/// The process operations used by Show/Undo, injectable without touching real apps.
@MainActor
protocol WorkspaceRunningApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String? { get }
    var launchDate: Date? { get }
    var isTerminated: Bool { get }
    var isHidden: Bool { get }
    func unhide() -> Bool
    func hide() -> Bool
}

extension NSRunningApplication: WorkspaceRunningApplication {}

@MainActor
final class NativeWorkspaceLaunchAdapter: WorkspaceLaunchAdapter {
    private nonisolated static let accessibilityQueue = DispatchQueue(label: "dev.noamlitt.dictator.workspace-accessibility", qos: .userInitiated)
    private var windowHandles: [String: WindowHandle] = [:]
    private var capturedWindowIDs: [String] = []
    private var applicationHandles: [String: NSRunningApplication] = [:]
    private var hiddenApplicationHandles: [String: NSRunningApplication] = [:]
    private struct ShownApplication {
        var app: any WorkspaceRunningApplication
        var launchDate: Date
    }
    private var shownApplicationHandles: [String: [ShownApplication]] = [:]
    private let runningApplications: (String) -> [any WorkspaceRunningApplication]
    private let runningApplication: (pid_t) -> (any WorkspaceRunningApplication)?
    private var pendingAccessibilityRestores: [String: NativeAccessibilityRestoreTarget] = [:]
    private var accessibilityRestoreTask: Task<Void, Never>?

    init(runningApplications: @escaping (String) -> [any WorkspaceRunningApplication] = {
             NSRunningApplication.runningApplications(withBundleIdentifier: $0)
         }, runningApplication: @escaping (pid_t) -> (any WorkspaceRunningApplication)? = {
             NSRunningApplication(processIdentifier: $0)
         }) {
        self.runningApplications = runningApplications
        self.runningApplication = runningApplication
    }

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func capture(
        lastActivatedAt: [String: Date],
        excluding: Set<String>,
        preferredFrontmostBundleID: String?,
        windowBundleIDs: Set<String>,
        applicationBundleIDs: Set<String>
    ) async throws -> WorkspaceSnapshot {
        guard isAccessibilityGranted else { throw NativeResetError.accessibilityNotGranted }
        try await requireRestoredAccessibilityState()
        let capturedAt = Date()
        applicationHandles.removeAll()
        hiddenApplicationHandles = hiddenApplicationHandles.filter { !$0.value.isTerminated }

        let mainDisplayID = CGMainDisplayID()
        let screens = NSScreen.screens

        // Locate primary screen (AppKit screen coordinates origin (0,0) is at bottom-left of primary screen)
        let primaryScreen = screens.first(where: { screen in
            guard let num = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
                return false
            }
            return CGDirectDisplayID(num) == mainDisplayID
        }) ?? screens.first

        let primaryTop: Double = Double(primaryScreen?.frame.maxY ?? (NSScreen.main?.frame.maxY ?? 0.0))

        var displays: [WorkspaceDisplay] = []
        var displayInfos: [DisplayLayoutInfo] = []

        for screen in screens {
            let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let isMain = (screenNumber != nil && CGDirectDisplayID(screenNumber!) == mainDisplayID)
            let displayIDString = screenNumber.map(String.init) ?? UUID().uuidString
            let displayName = screen.localizedName

            // Convert AppKit frames (Y up) to Accessibility global coordinate (Y down) using primary display top
            let vf = screen.visibleFrame
            let visibleRect = WorkspaceRect(
                x: Double(vf.origin.x),
                y: primaryTop - Double(vf.origin.y) - Double(vf.size.height),
                width: Double(vf.size.width),
                height: Double(vf.size.height)
            )

            let sf = screen.frame
            let screenRect = WorkspaceRect(
                x: Double(sf.origin.x),
                y: primaryTop - Double(sf.origin.y) - Double(sf.size.height),
                width: Double(sf.size.width),
                height: Double(sf.size.height)
            )

            displays.append(WorkspaceDisplay(
                id: displayIDString,
                name: displayName,
                visibleFrame: visibleRect,
                isMain: isMain,
                isBuiltIn: screenNumber.map { CGDisplayIsBuiltin(CGDirectDisplayID($0)) != 0 },
                stableUUID: Self.stableDisplayID(screenNumber)
            ))

            displayInfos.append(DisplayLayoutInfo(
                id: displayIDString,
                axFrame: screenRect
            ))
        }

        // Limit to 50 regular applications, skipping excluded bundle IDs
        var regularApps: [NSRunningApplication] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            guard let bundleID = app.bundleIdentifier, !excluding.contains(bundleID), app.launchDate != nil else { continue }
            regularApps.append(app)
        }

        let selectedApps = regularApps.filter { applicationBundleIDs.contains($0.bundleIdentifier ?? "") }
        let targetApps = Array(selectedApps.prefix(50))

        var applications: [WorkspaceApplication] = []
        for app in targetApps {
            let bundleID = app.bundleIdentifier!
            let appName = app.localizedName ?? bundleID
            guard applicationHandles[bundleID] == nil else { continue }
            applicationHandles[bundleID] = app
            applications.append(WorkspaceApplication(
                bundleID: bundleID,
                name: appName,
                isHidden: app.isHidden,
                lastActivatedAt: lastActivatedAt[bundleID]
            ))
        }

        let focusedApp = preferredFrontmostBundleID.flatMap { id in regularApps.first { $0.bundleIdentifier == id } }
            ?? NSWorkspace.shared.frontmostApplication
        let focusedPID = focusedApp?.processIdentifier
        let apps = targetApps.map { app in
            NativeCaptureApplication(processIdentifier: app.processIdentifier, launchDate: app.launchDate,
                bundleIdentifier: app.bundleIdentifier!, localizedName: app.localizedName ?? "App", isHidden: app.isHidden)
        }
        let retained = windowHandles
        let displayLayouts = displayInfos
        // Window counts per process across every desktop: owner, layer and size only, never names.
        let allDesktops = Self.allDesktopWindows()
        let captured: NativeCaptureResult = await withCheckedContinuation { continuation in
            Self.accessibilityQueue.async {
                continuation.resume(returning: Self.captureWindows(apps: apps, displays: displayLayouts, windowBundleIDs: windowBundleIDs,
                                                                   focusedPID: focusedPID, retained: retained, allDesktops: allDesktops))
            }
        }
        windowHandles = captured.handles
        capturedWindowIDs = captured.windows.map(\.id)
        var notes = captured.notes
        if selectedApps.count > 50 { notes.append("Only the first 50 selected apps were included in this reset.") }
        // The pointer position (not what is under it) lets a routine pick "the screen I am on".
        let mouse = NSEvent.mouseLocation
        let pointer = WorkspacePoint(x: Double(mouse.x), y: primaryTop - Double(mouse.y))
        return WorkspaceSnapshot(capturedAt: capturedAt, displays: displays, windows: captured.windows,
                                 applications: applications, frontmostWindowID: captured.frontmostWindowID, notes: notes,
                                 skipped: captured.skipped, pointer: pointer)
    }

    private nonisolated static func cgWindows(onScreenOnly: Bool) -> [WorkspaceCGWindow] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return infos.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            return WorkspaceCGWindow(pid: pid, layer: layer, width: width, height: height, x: x, y: y, windowID: "cg:\(number)")
        }
    }

    private nonisolated static func allDesktopWindows() -> [Int32: Int] {
        WorkspaceSkipDetector.layerZeroCounts(cgWindows(onScreenOnly: false))
    }

    private nonisolated static func captureWindows(apps: [NativeCaptureApplication], displays displayInfos: [DisplayLayoutInfo],
                                                   windowBundleIDs: Set<String>, focusedPID: pid_t?,
                                                   retained: [String: WindowHandle], allDesktops: [Int32: Int]) -> NativeCaptureResult {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var handles = retained
        var capturedWindows: [WorkspaceWindow] = []
        var notes: [String] = []
        var collector = WorkspaceSkipCollector()
        func skip(_ app: NativeCaptureApplication, _ reason: WorkspaceSkipReason, _ count: Int = 1) {
            collector.add(bundleID: app.bundleIdentifier, appName: app.localizedName, reason: reason, count: count)
        }
        /// Every Accessibility query goes through these, so a timeout is always reported (once per app).
        func readStatus(_ element: AXUIElement, _ attribute: String) -> (value: CFTypeRef?, timedOut: Bool) {
            var ref: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
            return (result == .success ? ref : nil, result == .cannotComplete)
        }
        func read(_ element: AXUIElement, _ attribute: String, _ app: NativeCaptureApplication) -> CFTypeRef? {
            let result = readStatus(element, attribute)
            if result.timedOut { skip(app, .slowToRespond) }
            return result.value
        }
        func isSettable(_ element: AXUIElement, _ attribute: String, _ app: NativeCaptureApplication) -> Bool? {
            var settable: DarwinBoolean = false
            let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
            guard result == .success else {
                skip(app, result == .cannotComplete ? .slowToRespond : .unreadable)
                return nil
            }
            return settable.boolValue
        }

        // Iterate visible non-hidden apps and collect up to 200 windows
        for app in apps {
            if app.isHidden || !windowBundleIDs.contains(app.bundleIdentifier) { continue }
            guard ProcessInfo.processInfo.systemUptime < deadline else { skip(app, .slowToRespond); continue }
            guard capturedWindows.count < 200 else { break }

            let pid = app.processIdentifier
            let launchDate = app.launchDate
            let bundleID = app.bundleIdentifier
            let appName = app.localizedName

            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, Float(0.05))

            guard let windowsValue = read(appElement, kAXWindowsAttribute as String, app),
                  let rawWindows = windowsValue as? [AXUIElement] else { continue }
            // Preserve each app's focused window above its other placed windows.
            let focused = read(appElement, kAXFocusedWindowAttribute as String, app)
            let windowsList: [AXUIElement]
            if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
               let front = rawWindows.first(where: { CFEqual($0, focused) }) {
                windowsList = [front] + rawWindows.filter { !CFEqual($0, front) }
            } else { windowsList = rawWindows }

            // Count only ordinary windows (role, subrole, size), so helper elements cannot hide skipped ones.
            // Bounded by the capture deadline and a per-app element budget; partial facts make no claim.
            let gathered = WorkspaceSkipDetector.gatherFacts(
                count: windowsList.count, maxElements: 60,
                deadlineReached: { ProcessInfo.processInfo.systemUptime >= deadline }
            ) { index in
                let element = windowsList[index]
                AXUIElementSetMessagingTimeout(element, Float(0.05))
                let role = readStatus(element, kAXRoleAttribute as String), subrole = readStatus(element, kAXSubroleAttribute as String)
                let sizeRead = readStatus(element, kAXSizeAttribute as String)
                var size = CGSize.zero
                if let ref = sizeRead.value, CFGetTypeID(ref) == AXValueGetTypeID() { _ = AXValueGetValue(ref as! AXValue, .cgSize, &size) }
                return (WorkspaceAXWindowFacts(role: role.value as? String, subrole: subrole.value as? String,
                                               width: Double(size.width), height: Double(size.height)),
                        role.timedOut || subrole.timedOut || sizeRead.timedOut)
            }
            if gathered.unresolvedCount > 0 { skip(app, .unreadable, gathered.unresolvedCount) }
            if gathered.outcome == .slow { skip(app, .slowToRespond) }
            if gathered.complete {
                let otherDesktop = WorkspaceSkipDetector.otherSpaceCount(allDesktopsCount: allDesktops[pid] ?? 0,
                                                                         accessibilityCount: WorkspaceSkipDetector.ordinaryAXCount(gathered.facts))
                if otherDesktop > 0 { skip(app, .otherSpace, otherDesktop) }
            }   // partial or unreadable facts make no other-desktop claim

            for (index, windowElement) in windowsList.enumerated() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { skip(app, .slowToRespond); break }
                AXUIElementSetMessagingTimeout(windowElement, Float(0.05))
                // Full-screen windows are managed by macOS Spaces.
                if (read(windowElement, "AXFullScreen", app) as? Bool) == true { skip(app, .fullScreen); continue }
                guard capturedWindows.count < 200 else { break }

                // Facts were read once, in the pass above; reporting and arranging both decide from that record.
                // A window that was never read (timeout or budget) was already reported as slow.
                guard index < gathered.records.count else { break }
                let facts = gathered.records[index]
                guard WorkspaceSkipDetector.isArrangeEligible(facts) else { continue }
                let size = CGSize(width: facts.width, height: facts.height)

                // Keep their identities for an explicit Remember/Place preparation.
                // Legacy tiling and Remember capture still exclude them.
                let minimized = (read(windowElement, kAXMinimizedAttribute as String, app) as? Bool) == true
                if minimized { skip(app, .minimized) }

                // Position and size must be settable
                guard let positionSettable = isSettable(windowElement, kAXPositionAttribute as String, app),
                      let sizeSettable = isSettable(windowElement, kAXSizeAttribute as String, app) else { continue }
                if let reason = WorkspaceSkipDetector.geometrySkipReason(positionSettable: positionSettable, sizeSettable: sizeSettable) {
                    skip(app, reason)
                    continue
                }

                guard let posRef = read(windowElement, kAXPositionAttribute as String, app), CFGetTypeID(posRef) == AXValueGetTypeID() else { continue }
                let posValue = posRef as! AXValue
                guard AXValueGetType(posValue) == .cgPoint else { continue }
                var point = CGPoint.zero
                guard AXValueGetValue(posValue, .cgPoint, &point) else { continue }

                let windowRect = WorkspaceRect(
                    x: Double(point.x),
                    y: Double(point.y),
                    width: Double(size.width),
                    height: Double(size.height)
                )

                // Assign display ID by greatest intersecting area
                var bestDisplayID: String? = nil
                var maxArea: Double = 0.0
                for display in displayInfos {
                    let interX = max(windowRect.x, display.axFrame.x)
                    let interY = max(windowRect.y, display.axFrame.y)
                    let interMaxX = min(windowRect.x + windowRect.width, display.axFrame.x + display.axFrame.width)
                    let interMaxY = min(windowRect.y + windowRect.height, display.axFrame.y + display.axFrame.height)
                    let interW = max(0.0, interMaxX - interX)
                    let interH = max(0.0, interMaxY - interY)
                    let area = interW * interH
                    if area > maxArea {
                        maxArea = area
                        bestDisplayID = display.id
                    }
                }

                // Retain handles; never rebind an existing UUID to a different window
                var matchedID: String? = nil
                for (existingID, existingHandle) in handles {
                    if existingHandle.pid == pid && existingHandle.launchDate == launchDate && CFEqual(existingHandle.element, windowElement) {
                        matchedID = existingID
                        break
                    }
                }

                let finalID = matchedID ?? UUID().uuidString
                let handle = WindowHandle(
                    element: windowElement,
                    pid: pid,
                    launchDate: launchDate,
                    bundleID: bundleID
                )
                handles[finalID] = handle

                capturedWindows.append(WorkspaceWindow(
                    id: finalID,
                    bundleID: bundleID,
                    appName: appName,
                    frame: windowRect,
                    displayID: bestDisplayID,
                    isMinimized: minimized
                ))
            }
        }

        if ProcessInfo.processInfo.systemUptime >= deadline || capturedWindows.count >= 200 {
            notes.append("There were too many windows to read in time, so Dictator skipped some. Run it again if needed.")
        }

        var frontmostWindowID: String?
        if let focusedPID {
            let element = AXUIElementCreateApplication(focusedPID)
            AXUIElementSetMessagingTimeout(element, 0.05)
            let focusedRead = readStatus(element, kAXFocusedWindowAttribute as String)
            if focusedRead.timedOut, let app = apps.first(where: { $0.processIdentifier == focusedPID }) { skip(app, .slowToRespond) }
            if let value = focusedRead.value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let focused = value as! AXUIElement
                frontmostWindowID = capturedWindows.first { window in
                    handles[window.id].map { CFEqual($0.element, focused) } == true
                }?.id
            }
        }
        let positions = WorkspaceWindowStack.positions(candidates: capturedWindows.compactMap { window in
            guard !window.isMinimized, let handle = handles[window.id] else { return nil }
            return (window.id, handle.pid, window.frame)
        }, frontToBack: cgWindows(onScreenOnly: true))
        for index in capturedWindows.indices { capturedWindows[index].stack = positions[capturedWindows[index].id] }
        return NativeCaptureResult(windows: capturedWindows, handles: handles, frontmostWindowID: frontmostWindowID, notes: notes,
                                   skipped: collector.skips)
    }

    private static func stableDisplayID(_ number: UInt32?) -> String? {
        guard let number, let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func currentDisplays() -> [WorkspaceDisplay] {
        let screens = NSScreen.screens
        let primary = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }
        let top = Double(primary?.frame.maxY ?? 0)
        return screens.map { screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let f = screen.visibleFrame
            return WorkspaceDisplay(id: number.map(String.init) ?? "unknown", name: screen.localizedName,
                                    visibleFrame: WorkspaceGeometry.accessibilityFrame(.init(x: f.minX, y: f.minY, width: f.width, height: f.height), primaryTop: top),
                                    isMain: number == CGMainDisplayID(), isBuiltIn: number.map { CGDisplayIsBuiltin($0) != 0 }, stableUUID: stableDisplayID(number))
        }
    }

    var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var runningBundleIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.activationPolicy == .regular ? $0.bundleIdentifier : nil })
    }

    func isAppRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    func isAppInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func opensOwnWindow(bundleID: String) -> Bool { WorkspaceBrowsers.opensItsOwnWindow(bundleID: bundleID) }

    func installedBrowsers() async -> [WorkspaceBrowserInfo] {
        await WorkspaceBrowsers.installed()
    }

    func openTabs(bundleID: String, profileDirectory: String?, urls: [String], timeout: TimeInterval) async throws -> Bool {
        guard timeout > 0, !Task.isCancelled,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let deadline = monotonicTime + timeout
        let request = await Task.detached(priority: .utility) {
            WorkspaceBrowsers.launchRequest(bundleID: bundleID, profileDirectory: profileDirectory, urls: urls,
                catalog: WorkspaceBrowsers.bundledCatalog, applicationSupport: WorkspaceBrowsers.applicationSupport) { url in
                    var directory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
                }
        }.value
        guard let request, !Task.isCancelled, monotonicTime < deadline else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        if case .application(let arguments) = request {
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments
        }
        return try await withCheckedThrowingContinuation { continuation in
            var pending: CheckedContinuation<Bool, Error>? = continuation
            let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
                Task { @MainActor in
                    pending?.resume(returning: app != nil && error == nil)
                    pending = nil
                }
            }
            switch request {
            case .application:
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: completion)
            case .addresses(let addresses):
                NSWorkspace.shared.open(addresses, withApplicationAt: appURL, configuration: configuration, completionHandler: completion)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0, deadline - self.monotonicTime)))
                // The outstanding system request may still open its tabs after this deadline.
                pending?.resume(throwing: WorkspaceTabOpenTimedOut())
                pending = nil
            }
        }
    }

    func openApp(bundleID: String, timeout: TimeInterval) async throws -> Bool {
        guard timeout > 0, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        return await withCheckedContinuation { continuation in
            var pending: CheckedContinuation<Bool, Never>? = continuation
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
                Task { @MainActor in
                    pending?.resume(returning: app != nil)
                    pending = nil
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                pending?.resume(returning: self.isAppRunning(bundleID: bundleID))
                pending = nil
            }
        }
    }

    func waitForFirstWindow(bundleID: String, timeout: TimeInterval) async throws -> Bool {
        let deadline = monotonicTime + max(0, timeout)
        while !Task.isCancelled, monotonicTime < deadline {
            let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
            let remaining = deadline - monotonicTime
            let ready: Bool = await withCheckedContinuation { continuation in
                Self.accessibilityQueue.async {
                    for pid in pids where ProcessInfo.processInfo.systemUptime < deadline {
                        let app = AXUIElementCreateApplication(pid)
                        AXUIElementSetMessagingTimeout(app, Float(min(0.2, remaining / 4)))
                        var value: CFTypeRef?
                        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                              let windows = value as? [AXUIElement] else { continue }
                        for window in windows.prefix(40) where ProcessInfo.processInfo.systemUptime < deadline {
                            AXUIElementSetMessagingTimeout(window, Float(min(0.2, remaining / 4)))
                            var role: CFTypeRef?, subrole: CFTypeRef?
                            guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success,
                                  role as? String == kAXWindowRole else { continue }
                            let status = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
                            if status == .success && subrole as? String == kAXStandardWindowSubrole {
                                continuation.resume(returning: true); return
                            }
                        }
                    }
                    continuation.resume(returning: false)
                }
            }
            if ready { return true }
            let pause = min(0.15, deadline - monotonicTime)
            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
        }
        return false
    }

    var dictatorBundleID: String { Bundle.main.bundleIdentifier ?? "dev.noamlitt.dictator" }

    func liveWindowOrder(deadline: TimeInterval) async -> [WorkspaceStackWindow] {
        // Validate identities before using retained AX elements, then read their
        // current bounds. Geometry may have changed since the planning capture.
        let handles = capturedWindowIDs.compactMap { id -> (String, WindowHandle)? in
            guard let handle = windowHandles[id], let launch = handle.launchDate,
                  let app = NSRunningApplication(processIdentifier: handle.pid), !app.isTerminated,
                  app.launchDate == launch, app.bundleIdentifier == handle.bundleID else { return nil }
            return (id, handle)
        }
        let live: [(window: WorkspaceCGWindow, id: String?)] = await withCheckedContinuation { continuation in
            Self.accessibilityQueue.async {
                var candidates: [(id: String, pid: Int32, frame: WorkspaceRect)] = []
                var ordered: [(String, WindowHandle)] = []
                var seenPIDs = Set<pid_t>()
                for (_, handle) in handles where seenPIDs.insert(handle.pid).inserted {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    let app = AXUIElementCreateApplication(handle.pid)
                    AXUIElementSetMessagingTimeout(app, 0.05)
                    var raw: CFTypeRef?, focused: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
                    _ = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
                    let windows = raw as? [AXUIElement] ?? []
                    let focusedFirst = windows.filter { element in focused.map { CFEqual(element, $0) } == true }
                    let axOrder = focusedFirst + windows.filter { element in !focusedFirst.contains { CFEqual($0, element) } }
                    for element in axOrder {
                        if let match = handles.first(where: { $0.1.pid == handle.pid && CFEqual($0.1.element, element) }) {
                            ordered.append(match)
                        }
                    }
                }
                for (id, handle) in ordered {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    AXUIElementSetMessagingTimeout(handle.element, 0.05)
                    var position: CFTypeRef?, size: CFTypeRef?, minimized: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(handle.element, kAXMinimizedAttribute as CFString, &minimized)
                    if (minimized as? Bool) == true { continue }
                    var point = CGPoint.zero, dimensions = CGSize.zero
                    guard AXUIElementCopyAttributeValue(handle.element, kAXPositionAttribute as CFString, &position) == .success,
                          AXUIElementCopyAttributeValue(handle.element, kAXSizeAttribute as CFString, &size) == .success,
                          let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
                          AXValueGetType(position as! AXValue) == .cgPoint, AXValueGetType(size as! AXValue) == .cgSize,
                          AXValueGetValue(position as! AXValue, .cgPoint, &point),
                          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { continue }
                    candidates.append((id, handle.pid, .init(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)))
                }
                let windows = Self.cgWindows(onScreenOnly: true).filter { $0.layer == 0 }
                let positions = WorkspaceWindowStack.positions(candidates: candidates, frontToBack: windows)
                let ids = Dictionary(uniqueKeysWithValues: positions.map { ($0.value, $0.key) })
                continuation.resume(returning: windows.enumerated().map { ($0.element, ids[$0.offset]) })
            }
        }
        return live.map { item in
            .init(id: item.id ?? item.window.windowID,
                  bundleID: NSRunningApplication(processIdentifier: item.window.pid)?.bundleIdentifier ?? "",
                  frame: item.window.frame)
        }
    }

    func makeAppFrontmost(bundleID: String, deadline: TimeInterval) async throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }),
              app.launchDate != nil else { throw NativeResetError.appNotFound(bundleID) }
        let pid = app.processIdentifier
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.accessibilityQueue.async {
                do { try Self.makeFrontmost(pid: pid, deadline: deadline); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private nonisolated static func makeFrontmost(pid: pid_t, deadline: TimeInterval) throws {
        let app = AXUIElementCreateApplication(pid)
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 0.4)
        func frontmost() -> Bool {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &value) == .success && (value as? Bool) == true
        }
        guard ProcessInfo.processInfo.systemUptime < end else { throw NativeResetError.appNotFound("") }
        AXUIElementSetMessagingTimeout(app, Float(min(0.05, end - ProcessInfo.processInfo.systemUptime)))
        if frontmost() { return }
        // The observed state wins over the setter acknowledgement.
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        while ProcessInfo.processInfo.systemUptime < end {
            if frontmost() { return }
            Thread.sleep(forTimeInterval: min(0.025, max(0, end - ProcessInfo.processInfo.systemUptime)))
        }
        throw NativeResetError.moveFailed("App didn't become frontmost")
    }

    func raiseWindow(id: String, deadline: TimeInterval) async throws {
        guard let handle = windowHandles[id], let launch = handle.launchDate,
              let app = NSRunningApplication(processIdentifier: handle.pid), !app.isTerminated,
              app.launchDate == launch, app.bundleIdentifier == handle.bundleID else {
            throw NativeResetError.windowNotFound(id)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.accessibilityQueue.async {
                do {
                    try Self.makeFrontmost(pid: handle.pid, deadline: deadline)
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeResetError.windowNotFound(id) }
                    AXUIElementSetMessagingTimeout(handle.element, Float(min(0.1, deadline - ProcessInfo.processInfo.systemUptime)))
                    guard AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString) == .success else {
                        throw NativeResetError.moveFailed("Could not raise window")
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func setMinimized(id: String, minimized: Bool) async throws {
        guard isAccessibilityGranted else { throw NativeResetError.accessibilityNotGranted }
        guard let handle = windowHandles[id], let expectedLaunch = handle.launchDate,
              let app = NSRunningApplication(processIdentifier: handle.pid), !app.isTerminated,
              app.launchDate == expectedLaunch, app.bundleIdentifier == handle.bundleID else {
            throw NativeResetError.windowNotFound(id)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.accessibilityQueue.async {
                AXUIElementSetMessagingTimeout(handle.element, 0.2)
                let status = AXUIElementSetAttributeValue(handle.element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse)
                // Readback also covers apps that acknowledge before applying.
                for _ in 0..<6 {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(handle.element, kAXMinimizedAttribute as CFString, &value) == .success,
                       (value as? Bool) == minimized { continuation.resume(); return }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continuation.resume(throwing: NativeResetError.moveFailed("Minimized state didn't settle (\(status.rawValue))"))
            }
        }
    }

    func parkWindow(id: String, at frame: WorkspaceRect) async throws -> WorkspaceRect {
        guard isAccessibilityGranted else { throw NativeResetError.accessibilityNotGranted }
        try await requireRestoredAccessibilityState()
        guard frame.isUsable else { throw NativeResetError.moveFailed("The requested size is not valid.") }
        guard let handle = windowHandles[id] else { throw NativeResetError.windowNotFound(id) }
        guard let app = NSRunningApplication(processIdentifier: handle.pid), !app.isTerminated,
              let launch = handle.launchDate, app.launchDate == launch, app.bundleIdentifier == handle.bundleID else {
            throw NativeResetError.processIdentityMismatch("Process changed for PID \(handle.pid).")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WorkspaceRect, Error>) in
            Self.accessibilityQueue.async {
                AXUIElementSetMessagingTimeout(handle.element, 0.5)
                var point = CGPoint(x: frame.x, y: frame.y)
                guard let value = AXValueCreate(.cgPoint, &point),
                      AXUIElementSetAttributeValue(handle.element, kAXPositionAttribute as CFString, value) == .success else {
                    continuation.resume(throwing: NativeResetError.moveFailed("The window wouldn't move."))
                    return
                }
                // The window server applies its limit a moment after accepting the move.
                var landed = point
                for _ in 0..<8 {
                    usleep(15_000)
                    var read: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(handle.element, kAXPositionAttribute as CFString, &read) == .success,
                          let read, CFGetTypeID(read) == AXValueGetTypeID() else { continue }
                    var now = CGPoint.zero
                    guard AXValueGetValue(read as! AXValue, .cgPoint, &now) else { continue }
                    let settled = now == landed
                    landed = now
                    if settled { break }
                }
                continuation.resume(returning: WorkspaceRect(x: landed.x, y: landed.y, width: frame.width, height: frame.height))
            }
        }
    }

    func moveWindow(id: String, to frame: WorkspaceRect) async throws {
        guard isAccessibilityGranted else { throw NativeResetError.accessibilityNotGranted }
        try await requireRestoredAccessibilityState()
        guard frame.isUsable else { throw NativeResetError.moveFailed("The requested size is not valid.") }
        guard let handle = windowHandles[id] else {
            throw NativeResetError.windowNotFound(id)
        }

        // Validate running process identity
        guard let app = NSRunningApplication(processIdentifier: handle.pid), !app.isTerminated else {
            throw NativeResetError.processTerminated("Process PID \(handle.pid) has terminated.")
        }
        guard let expectedLaunch = handle.launchDate, let actualLaunch = app.launchDate, expectedLaunch == actualLaunch else {
            throw NativeResetError.processIdentityMismatch("Process launch date changed for PID \(handle.pid).")
        }
        guard let currentBundleID = app.bundleIdentifier, currentBundleID == handle.bundleID else {
            throw NativeResetError.processIdentityMismatch("Bundle ID changed for PID \(handle.pid): expected \(handle.bundleID).")
        }

        let screens = NSScreen.screens
        let primary = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }
        let primaryTop = Double(primary?.frame.maxY ?? 0)
        let visible = screens.map { screen in
            let rect = screen.visibleFrame
            return WorkspaceGeometry.accessibilityFrame(WorkspaceRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height), primaryTop: primaryTop)
        }
        guard WorkspaceGeometry.hasReachableTitlebar(frame, on: visible) else {
            throw NativeResetError.displayUnavailable
        }

        let assistiveActive = NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
        let outcome: NativeFrameMoveOutcome = await withCheckedContinuation { continuation in
            Self.accessibilityQueue.async {
                let application = AXUIElementCreateApplication(handle.pid)
                AXUIElementSetMessagingTimeout(application, 0.5)
                var pending = false
                do {
                    var settable: DarwinBoolean = false
                    let status = AXUIElementIsAttributeSettable(application, "AXEnhancedUserInterface" as CFString, &settable)
                    NSLog("workspace: frame enhancedUI settableQuery status=%d value=%d", status.rawValue, settable.boolValue ? 1 : 0)
                    try WorkspaceFrameAccessibilityScope.perform(builtInAssistiveActive: assistiveActive,
                        settable: status == .success ? settable.boolValue : nil,
                        read: { Self.readEnhancedUI(application) }, write: { try Self.writeEnhancedUI(application, enabled: $0) },
                        diagnostic: { NSLog("%@", $0) }, restorationPending: { pending = true },
                        adjustment: { try Self.moveElement(handle.element, id: id, to: frame) })
                    continuation.resume(returning: NativeFrameMoveOutcome())
                } catch {
                    NSLog("workspace: frame move failed window=%@ bundle=%@ desired=%@ error=%@", id, handle.bundleID,
                          String(describing: frame), String(describing: error))
                    let target = pending ? handle.launchDate.map { NativeAccessibilityRestoreTarget(application: application,
                        pid: handle.pid, launchDate: $0, bundleID: handle.bundleID) } : nil
                    continuation.resume(returning: NativeFrameMoveOutcome(error: error, pendingRestore: target))
                }
            }
        }
        if let pending = outcome.pendingRestore {
            pendingAccessibilityRestores[pending.key] = pending
            scheduleAccessibilityRestoration()
        }
        if let error = outcome.error { throw error }
    }

    private nonisolated static func readEnhancedUI(_ application: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, "AXEnhancedUserInterface" as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(value as! CFBoolean)
    }

    private nonisolated static func writeEnhancedUI(_ application: AXUIElement, enabled: Bool) throws {
        let status = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
        guard status == .success else { throw NativeResetError.moveFailed("AXEnhancedUserInterface write=\(enabled), ACK error=\(status.rawValue).") }
    }

    private func retryAccessibilityRestoration() async -> Bool {
        guard isAccessibilityGranted else { return pendingAccessibilityRestores.isEmpty }
        for (key, target) in pendingAccessibilityRestores {
            // A process-local AX flag dies with its process. Never apply an
            // old restoration to another launch that reused its PID.
            guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
                  app.launchDate == target.launchDate, app.bundleIdentifier == target.bundleID else {
                pendingAccessibilityRestores.removeValue(forKey: key)
                continue
            }
            let restored = await withCheckedContinuation { continuation in
                Self.accessibilityQueue.async {
                    continuation.resume(returning: WorkspaceFrameAccessibilityScope.restore(
                        read: { Self.readEnhancedUI(target.application) },
                        write: { try Self.writeEnhancedUI(target.application, enabled: $0) }, diagnostic: { NSLog("%@", $0) }))
                }
            }
            if restored { pendingAccessibilityRestores.removeValue(forKey: key) }
        }
        return pendingAccessibilityRestores.isEmpty
    }

    private func requireRestoredAccessibilityState() async throws {
        guard !pendingAccessibilityRestores.isEmpty else { return }
        if await retryAccessibilityRestoration() { return }
        scheduleAccessibilityRestoration()
        throw NativeResetError.accessibilityRestorePending
    }

    private func scheduleAccessibilityRestoration() {
        guard accessibilityRestoreTask == nil else { return }
        accessibilityRestoreTask = Task { @MainActor [weak self] in
            for delay in [100, 500, 1000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self else { return }
                if await self.retryAccessibilityRestoration() { break }
            }
            self?.accessibilityRestoreTask = nil
        }
    }

    /// Accessibility messages can be slow. Keep them off the UI/event-tap run loop.
    private nonisolated static func moveElement(_ element: AXUIElement, id: String, to frame: WorkspaceRect) throws {
        AXUIElementSetMessagingTimeout(element, Float(0.5))
        var minimized: CFTypeRef?
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true { throw NativeResetError.moveFailed("The window is minimized.") }
        if AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? Bool) == true { throw NativeResetError.moveFailed("The window is full screen.") }
        var role: CFTypeRef?
        let validity = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if validity == .invalidUIElement { throw NativeResetError.windowNotFound(id) }
        guard validity == .success else { throw NativeResetError.moveFailed("Could not read the window.") }
        // Read original position
        var origPosRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &origPosRef) == .success,
              let origPosRef = origPosRef,
              CFGetTypeID(origPosRef) == AXValueGetTypeID() else {
            throw NativeResetError.moveFailed("Unable to read current position for window \(id).")
        }
        let origPosVal = origPosRef as! AXValue
        guard AXValueGetType(origPosVal) == .cgPoint else {
            throw NativeResetError.moveFailed("Current position value is not a CGPoint.")
        }
        var origPoint = CGPoint.zero
        guard AXValueGetValue(origPosVal, .cgPoint, &origPoint) else {
            throw NativeResetError.moveFailed("Failed to extract CGPoint from original position.")
        }

        // Read original size
        var origSizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &origSizeRef) == .success,
              let origSizeRef = origSizeRef,
              CFGetTypeID(origSizeRef) == AXValueGetTypeID() else {
            throw NativeResetError.moveFailed("Unable to read current size for window \(id).")
        }
        let origSizeVal = origSizeRef as! AXValue
        guard AXValueGetType(origSizeVal) == .cgSize else {
            throw NativeResetError.moveFailed("Current size value is not a CGSize.")
        }
        var origSize = CGSize.zero
        guard AXValueGetValue(origSizeVal, .cgSize, &origSize) else {
            throw NativeResetError.moveFailed("Failed to extract CGSize from original size.")
        }

        let original = WorkspaceRect(x: origPoint.x, y: origPoint.y, width: origSize.width, height: origSize.height)
        func write(_ attribute: CFString, frame: WorkspaceRect, size: Bool) throws {
            var point = CGPoint(x: frame.x, y: frame.y)
            var dimensions = CGSize(width: frame.width, height: frame.height)
            let value = size ? AXValueCreate(.cgSize, &dimensions) : AXValueCreate(.cgPoint, &point)
            guard let value else { throw NativeResetError.moveFailed("Unable to encode geometry for \(id).") }
            let result = AXUIElementSetAttributeValue(element, attribute, value)
            guard result == .success else {
                throw NativeResetError.moveFailed("AX setter \(attribute) error=\(result.rawValue), requested=\(frame), window=\(id).")
            }
        }
        func readFrame() throws -> WorkspaceRect {
            var position: CFTypeRef?, size: CFTypeRef?
            let positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
            let sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard positionError == .success, sizeError == .success,
                  let position, let size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
                  AXValueGetType(position as! AXValue) == .cgPoint, AXValueGetType(size as! AXValue) == .cgSize,
                  AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else {
                throw NativeResetError.moveFailed("AX frame read positionError=\(positionError.rawValue), sizeError=\(sizeError.rawValue), window=\(id).")
            }
            return WorkspaceRect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
        }
        try WorkspaceFrameApplication.apply(original: original, target: frame,
            setSize: { try write(kAXSizeAttribute as CFString, frame: $0, size: true) },
            setPosition: { try write(kAXPositionAttribute as CFString, frame: $0, size: false) },
            readFrame: readFrame,
            diagnostic: { NSLog("%@", $0) })
    }

    func restoreWindow(_ window: WorkspaceWindow) async throws {
        let screens = NSScreen.screens
        let primary = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }
        let primaryTop = Double(primary?.frame.maxY ?? 0)
        let displays = screens.enumerated().map { index, screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let r = screen.visibleFrame
            return WorkspaceDisplay(id: number.map(String.init) ?? "screen-\(index)",
                visibleFrame: WorkspaceGeometry.accessibilityFrame(WorkspaceRect(x: r.minX, y: r.minY, width: r.width, height: r.height), primaryTop: primaryTop),
                isMain: number == CGMainDisplayID())
        }
        guard let frame = WorkspaceGeometry.restorationFrame(for: window, displays: displays) else { throw NativeResetError.displayUnavailable }
        try await moveWindow(id: window.id, to: frame)
        if window.isMinimized { try await setMinimized(id: window.id, minimized: true) }
    }

    /// `hide()` and `unhide()` return false on macOS 27 even when they work, and
    /// the app changes a few milliseconds later, so only the state itself counts.
    private func settle(_ app: WorkspaceRunningApplication, hidden: Bool) async -> Bool {
        let deadline = monotonicTime + 0.5
        // Cancelled sleeps return at once, so without this check it would spin.
        while app.isHidden != hidden, !app.isTerminated, !Task.isCancelled, monotonicTime < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return app.isHidden == hidden
    }

    func hideApp(bundleID: String) async throws -> Bool {
        // Protect own application
        if let ownBundleID = Bundle.main.bundleIdentifier, ownBundleID == bundleID {
            throw NativeResetError.hideProtected("Refusing to hide own bundle ID '\(bundleID)'.")
        }
        if let currentAppBundleID = NSRunningApplication.current.bundleIdentifier, currentAppBundleID == bundleID {
            throw NativeResetError.hideProtected("Refusing to hide current running application '\(bundleID)'.")
        }

        // Protect current frontmost application
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.bundleIdentifier == bundleID {
            throw NativeResetError.hideProtected("Refusing to hide current frontmost application '\(bundleID)'.")
        }

        guard let app = applicationHandles[bundleID], !app.isTerminated,
              let launchDate = app.launchDate,
              let current = NSRunningApplication(processIdentifier: app.processIdentifier),
              current.launchDate == launchDate, current.bundleIdentifier == bundleID else {
            throw NativeResetError.appNotFound(bundleID)
        }
        // Retain the actual process object used by this run, so restoration
        // never unhides a replacement app that happens to share the bundle ID.
        guard !app.isHidden else { return false }
        _ = app.hide()
        guard await settle(app, hidden: true) else { throw NativeResetError.hideFailed("The app could not be hidden.") }
        hiddenApplicationHandles[bundleID] = app
        return true
    }

    func showApp(bundleID: String) async throws -> Bool {
        var shown = false
        for app in runningApplications(bundleID) where !app.isTerminated && app.isHidden {
            guard let launchDate = app.launchDate else { continue }
            _ = app.unhide()
            guard await settle(app, hidden: false) else { throw NativeResetError.unhideFailed("The app could not be shown.") }
            shownApplicationHandles[bundleID, default: []].removeAll { $0.app.processIdentifier == app.processIdentifier }
            shownApplicationHandles[bundleID, default: []].append(.init(app: app, launchDate: launchDate))
            shown = true
        }
        return shown
    }

    private func currentShownApplications(bundleID: String) -> [ShownApplication] {
        return (shownApplicationHandles[bundleID] ?? []).filter { handle in
            !handle.app.isTerminated && handle.app.launchDate == handle.launchDate
                && runningApplication(handle.app.processIdentifier).map { current in
                    !current.isTerminated && current.launchDate == handle.launchDate && current.bundleIdentifier == bundleID
                } == true
        }
    }

    func canRehideApp(bundleID: String) -> Bool { !currentShownApplications(bundleID: bundleID).isEmpty }

    func rehideApp(bundleID: String) async throws {
        let handles = currentShownApplications(bundleID: bundleID)
        // A replacement process has nothing to undo, even when it is in front.
        guard !handles.isEmpty else { shownApplicationHandles[bundleID] = nil; return }
        guard bundleID != dictatorBundleID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID else {
            throw NativeResetError.hideProtected("Switch to another app before hiding this app again.")
        }
        for handle in handles where !handle.app.isHidden {
            _ = handle.app.hide()
            guard await settle(handle.app, hidden: true) else { throw NativeResetError.hideFailed("The app could not be hidden again.") }
        }
        shownApplicationHandles[bundleID] = nil
    }

    func unhideApp(bundleID: String) async throws {
        guard let app = hiddenApplicationHandles[bundleID], !app.isTerminated,
              let launchDate = app.launchDate,
              let current = NSRunningApplication(processIdentifier: app.processIdentifier),
              current.launchDate == launchDate, current.bundleIdentifier == bundleID else {
            throw NativeResetError.appNotFound(bundleID)
        }
        _ = app.unhide()
        guard await settle(app, hidden: false) else { throw NativeResetError.unhideFailed("The app could not be shown.") }
        hiddenApplicationHandles.removeValue(forKey: bundleID)
    }

    func retainWindows(ids: Set<String>) {
        windowHandles = windowHandles.filter { ids.contains($0.key) }
    }
}
