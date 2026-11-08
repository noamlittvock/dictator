import Foundation

// Core-side session state machine for cross-machine dictation handoff.
//
// Pure and synchronous: no timers, no networking, no async. A host (the
// CoreServer/CoreConnection layer) feeds `BrokerInput`s in and executes the
// returned `BrokerEffect`s — sending frames, scheduling/cancelling the
// watchdog, kicking off transcription, writing history. That split is what
// makes every handoff case unit-testable with fake edges and an
// injected clock; see DictatorTests/SessionBrokerTests.swift.

/// What the broker knows about a connected Edge — enough to pick a mic owner
/// and to know who's reachable when broadcasting.
struct BrokerEdgeInfo: Equatable {
    var id: EdgeID
    var name: String
    var caps: EdgeCapabilities
}

typealias PressID = Int

enum BrokerInput: Equatable {
    case pressSettled(PressID)
    case edgeConnected(BrokerEdgeInfo)
    case edgeDisconnected(EdgeID)
    /// `hello`/`ping` never reach the broker in practice (the transport layer
    /// answers them); if one does, it's a no-op here rather than an error.
    case message(EdgeMessage, from: EdgeID)
    /// The binary frame that followed an `audio.take` header.
    case audio(Data, from: EdgeID)
    /// `text == nil && error == nil` never happens — a finished transcription
    /// always has a result or a reason it doesn't.
    case transcriptionFinished(SessionID, text: String?, inferenceMs: Int?, error: String?)
    case watchdogFired(SessionID)
    /// Fired by the host `EdgeProtocol.countdownLead` before the watchdog
    /// (see `BrokerEffect.scheduleCountdown`).
    case countdownFired(SessionID)
    /// Fired by the host after `SessionBroker.releaseGrace` elapses with no
    /// edge still holding the hotkey down (see `heldEdges` on `Session` and
    /// `BrokerEffect.scheduleReleaseGrace`).
    case releaseGraceFired(SessionID)
    /// User preference from settings. `nil` = "whoever initiates, if it has a mic."
    case micOwnerChanged(EdgeID?)
}

enum BrokerEffect: Equatable {
    case schedulePressSettle(PressID, TimeInterval)
    case cancelPressSettle(PressID)
    case send(EdgeID, CoreMessage)
    case transcribe(SessionID, AudioTakeHeader, Data)
    case cancelTranscription(SessionID)
    case scheduleWatchdog(SessionID, TimeInterval)
    case cancelWatchdog(SessionID)
    /// Arms a one-shot timer for the "recording is about to end" warning:
    /// the delay is the time until the countdown starts. If it elapses
    /// uncancelled the host delivers `.countdownFired(SessionID)`.
    case scheduleCountdown(SessionID, TimeInterval)
    case cancelCountdown(SessionID)
    /// Arms a one-shot timer: if it elapses without being cancelled, the host
    /// delivers `.releaseGraceFired(SessionID)` back into `apply`. Started
    /// when the last held edge releases, so a Universal Control pointer
    /// crossing mid-hold (which delivers a synthetic key-up on the Mac the
    /// pointer just left) has a moment to be corrected by the real edge's
    /// hold — either a re-press within the grace window, or simply the fact
    /// that the other Mac never released at all.
    case scheduleReleaseGrace(SessionID, TimeInterval)
    case cancelReleaseGrace(SessionID)
    case recordHistory(sessionId: SessionID, text: String, durationSeconds: Double, inferenceMs: Int?, destination: InsertDestination?, initiator: EdgeID)
    case log(String)
}

struct SessionSnapshot: Equatable {
    var id: SessionID
    var phase: SessionPhase
    var initiator: EdgeID
    var micOwner: EdgeID
    var target: EdgeID?
    /// Tap-to-start/tap-to-stop rather than hold-to-talk — see
    /// `EdgeMessage.hotkeyToggle`.
    var handsFree: Bool = false
    /// Started with Right Shift held (voice shortcuts).
    var voiceCommandMode: Bool = false
    var commandAppBundleID: String? = nil
    var destinationBundleID: String? = nil
}

final class SessionBroker {
    /// Internal session state — a superset of `SessionSnapshot` that also
    /// tracks the in-flight audio header and the pieces needed for the
    /// eventual history record, which the public snapshot has no use for.
    private struct Session {
        var id: SessionID
        var initiator: EdgeID
        var micOwner: EdgeID
        var target: EdgeID?
        var phase: SessionPhase
        /// Macs that reported this press, including later hold joins and duplicate toggles.
        var pressers: Set<EdgeID> = []
        /// Edges whose last hotkey event was `hotkeyDown` — i.e. edges that,
        /// as far as this broker knows, are still physically holding the
        /// key. Only meaningful in `.recording`; a real-world finding is
        /// what makes this a set rather than a single edge: with one
        /// keyboard shared over Universal Control, a press can be seen by
        /// both Macs' event taps, and the Mac the pointer just left gets a
        /// synthetic key-up while the key is still physically held. Ending
        /// the session on "any edge released" would stop dictation the
        /// moment the pointer crosses. Instead recording only actually stops
        /// once this set is empty (see `scheduleReleaseGraceIfNeeded`).
        var heldEdges: Set<EdgeID> = []
        /// True while a `.scheduleReleaseGrace` is outstanding (armed the
        /// instant `heldEdges` last became empty). A `hotkeyDown` before it
        /// fires cancels it; `releaseGraceFired` only stops capture if this
        /// is still true for a still-empty `heldEdges` when it arrives.
        var releaseGracePending = false
        /// True for a session started by `hotkeyToggle` (tap-to-start,
        /// tap-to-stop) rather than `hotkeyDown` (hold-to-talk). A
        /// hands-free session never populates `heldEdges` — release means
        /// nothing in this mode — and only a second `hotkeyToggle`, at
        /// least `toggleDebounce` after `startedAt`, stops it.
        var handsFree = false
        /// Capture stopped at the time limit; audio still follows the normal path.
        var recordingLimitReached = false
        /// `clock()` when the time limit will stop this recording; set once
        /// the countdown has started, so a Mac that becomes the target
        /// mid-countdown can be told how long is left.
        var countdownEndsAt: TimeInterval?
        /// Receipt time when recording starts; fences target claims and toggle debounce.
        var startedAt: TimeInterval = 0
        /// When a tap stopped this hands-free recording. One tap reaches both
        /// Macs over Universal Control, so the second copy arrives just after
        /// recording stopped and must not read as a press during processing.
        var tapStoppedAt: TimeInterval?
        /// Set by `shortcutMode`; the words are matched against voice shortcuts.
        var voiceCommandMode = false
        var commandApps: [EdgeID: String] = [:]
        /// What to do with the words, attached by the host once matched.
        var voiceCommand: VoiceCommandDelivery?
        /// Set by `attachLaunch` when the words matched a voice launch shortcut.
        var launch: VoiceLaunchPlan?
        var pendingAudioHeader: AudioTakeHeader?
        /// Once true, the audio has been handed to `transcribe` — an
        /// `edgeDisconnected(micOwner)` after this point no longer aborts
        /// the session (the transcription is already running independently).
        var transcribeEmitted = false
        var audioDurationSeconds: Double?
        var text: String?
        var inferenceMs: Int?
    }

    /// How long the Core waits for `insert.result` after sending `insert`
    /// before giving up on the target and ending the session as failed
    /// (mirrors the recording watchdog's shape but on a much shorter fuse;
    /// a paste is either near-instant or something is badly wrong).
    static let insertTimeout: TimeInterval = 20

    /// Capture has stopped, but the recorder still needs to send its audio.
    /// Recognition has its own per-source deadlines once that audio arrives.
    static let audioUploadTimeout: TimeInterval = 30

    private static let audioUploadFailure = DictationAlert(
        title: "The recording didn’t arrive",
        detail: "Try again. Any recording kept on the Mac with the microphone is in History & Privacy.",
        action: .history).encoded

    /// A workflow can legitimately wait much longer than a paste. Allow its
    /// configured steps to finish before declaring the target unresponsive.
    private static func insertionTimeout(for plan: VoiceLaunchPlan?) -> TimeInterval {
        guard let plan else { return insertTimeout }
        return plan.steps.reduce(insertTimeout) { total, step in
            switch step.kind {
            case .confirm: return total + (step.seconds ?? VoiceStep.defaultConfirmSeconds)
            case .waitForTextField: return total + (step.seconds ?? VoiceStep.defaultWaitSeconds)
            case .runAppleShortcut: return total + (step.timeoutSeconds ?? VoiceStep.defaultShortcutTimeout)
            case .runWorkspace: return total + VoiceLaunchReadiness.workspaceRunBudget
            case .runInTerminal where step.background == true:
                return total + (step.timeoutSeconds ?? VoiceStep.defaultBackgroundTimeout) + 1
            // Web requests and foreground-app waits allow ten seconds each.
            case .webhook, .openApp, .openLink: return total + 10
            default: return total + 1
            }
        }
    }

    /// How long recording keeps going after the last held edge releases
    /// before capture actually stops (the live-Universal-Control finding:
    /// the Mac the pointer just left sees a synthetic key-up while the key
    /// is still physically held on the Mac the pointer crossed to, and that
    /// Mac's real key-up follows shortly after). Short enough that a
    /// deliberate release still feels instant.
    static let releaseGrace: TimeInterval = 0.25

    /// How soon a second `hotkeyToggle` may actually stop a hands-free
    /// session, measured from `startedAt`. Absorbs the live-tested
    /// Universal-Control finding that both Macs' event taps see the same
    /// physical tap within a few ms when one keyboard is shared — without
    /// this, the duplicate copy of the same tap would immediately stop the
    /// session it just started.
    static let toggleDebounce: TimeInterval = 0.5

    private let coreId: String
    private let clock: () -> TimeInterval
    private let makeSessionID: () -> SessionID

    let focusClaims: FocusClaimRegistry

    private(set) var micOwnerPreference: EdgeID?
    private(set) var edges: [EdgeID: BrokerEdgeInfo] = [:]
    private var current: Session?

    private struct PendingPress {
        var id: PressID
        var first: EdgeID
        var handsFree: Bool
        var pressers: Set<EdgeID>
        var released: Set<EdgeID> = []
        var voiceCommandMode = false
        var commandApps: [EdgeID: String] = [:]
    }

    static let pressSettle: TimeInterval = 0.15
    static let busyNoticeInterval: TimeInterval = 2
    private var nextPressID: PressID = 0
    private var pendingPress: PendingPress?
    private var busyNotices: [EdgeID: TimeInterval] = [:]

    var session: SessionSnapshot? {
        guard let current else { return nil }
        return SessionSnapshot(id: current.id, phase: current.phase, initiator: current.initiator, micOwner: current.micOwner, target: current.target, handsFree: current.handsFree, voiceCommandMode: current.voiceCommandMode, commandAppBundleID: current.commandApps[current.initiator],
                               destinationBundleID: current.target.flatMap { focusClaims.appBundleID(for: $0) })
    }

    /// Matching consumes this transient context. It never reaches history or logs.
    func takeCommandAppBundleID(sessionId: SessionID) -> String? {
        guard var s = current, s.id == sessionId else { return nil }
        let app = s.commandApps[s.initiator]
        s.commandApps.removeAll()
        current = s
        return app
    }

    init(coreId: String, clock: @escaping () -> TimeInterval, makeSessionID: @escaping () -> SessionID = { UUID().uuidString }) {
        self.coreId = coreId
        self.clock = clock
        self.makeSessionID = makeSessionID
        self.focusClaims = FocusClaimRegistry()
    }

    func apply(_ input: BrokerInput) -> [BrokerEffect] {
        switch input {
        case .pressSettled(let id):
            guard let pending = pendingPress, pending.id == id else { return [] }
            return startPendingPress(pending)
        case .edgeConnected(let info):
            return handleEdgeConnected(info)
        case .edgeDisconnected(let id):
            return handleEdgeDisconnected(id)
        case .message(let message, from: let from):
            return handleMessage(message, from: from)
        case .audio(let data, from: let from):
            return handleAudio(data, from: from)
        case .transcriptionFinished(let sessionId, text: let text, inferenceMs: let inferenceMs, error: let error):
            return handleTranscriptionFinished(sessionId, text: text, inferenceMs: inferenceMs, error: error)
        case .watchdogFired(let sessionId):
            return handleWatchdogFired(sessionId)
        case .countdownFired(let sessionId):
            return handleCountdownFired(sessionId)
        case .releaseGraceFired(let sessionId):
            return handleReleaseGraceFired(sessionId)
        case .micOwnerChanged(let id):
            micOwnerPreference = id
            return []
        }
    }

    // MARK: - Edge lifecycle

    private func handleEdgeConnected(_ info: BrokerEdgeInfo) -> [BrokerEffect] {
        edges[info.id] = info
        // A reconnecting edge (or one that just joined mid-session) needs to
        // be brought up to date immediately — it won't see the broadcast
        // that started the session.
        guard let current else { return [] }
        return [.send(info.id, .sessionState(sessionStateUpdate(for: current, outcome: nil)))]
    }

    private func handleEdgeDisconnected(_ id: EdgeID) -> [BrokerEffect] {
        edges.removeValue(forKey: id)
        focusClaims.remove(edge: id)
        busyNotices[id] = nil
        if var pending = pendingPress {
            pending.pressers.remove(id)
            pending.released.remove(id)
            if pending.pressers.isEmpty {
                pendingPress = nil
                return [.cancelPressSettle(pending.id)]
            }
            pendingPress = pending
        }
        guard let s = current else { return [] }

        switch s.phase {
        case .recording:
            var next = s
            next.heldEdges.remove(id)
            if id == s.micOwner {
                // No mic, no session — and there's no one left to send captureCancel to.
                return endSession(next, outcome: .cancelled(.micLost))
            }
            if id == s.initiator {
                return endSession(next, outcome: .cancelled(.initiatorLost), extra: [.send(s.micOwner, .captureCancel(sessionId: s.id))])
            }
            current = next
            // Neither the mic owner nor the initiator dropped — those rules
            // take precedence when they apply. But if `id` was the last
            // held edge, this is exactly the same "nobody's holding it any
            // more" situation as a `hotkeyUp` emptying the set (e.g. the
            // only holder disconnected mid-hold) and goes through the same
            // grace path rather than stopping immediately.
            guard next.heldEdges.isEmpty else { return [] }
            return scheduleReleaseGraceIfNeeded(next)
        case .processing:
            // If transcription already has the audio, it runs to completion
            // independent of the mic owner's connection.
            if id == s.micOwner && !s.transcribeEmitted {
                return endSession(s, outcome: .cancelled(.micLost))
            }
            return []
        case .inserting:
            if id == s.target {
                return endSession(s, outcome: .cancelled(.targetLost))
            }
            return []
        case .idle:
            return []
        }
    }

    // MARK: - Edge messages

    private func handleMessage(_ message: EdgeMessage, from: EdgeID) -> [BrokerEffect] {
        switch message {
        case .hello, .ping, .pairingTokenSaved:
            return []
        case .capabilities(let caps):
            // Keep the registry current so mic-owner selection never uses a
            // snapshot from hello time (a mic can appear or fail later).
            guard var info = edges[from] else { return [] }
            info.caps = caps
            edges[from] = info
            return []
        case .hotkeyDown:
            return handleHotkeyDown(from: from)
        case .hotkeyUp:
            return handleHotkeyUp(from: from)
        case .hotkeyToggle:
            return handleHotkeyToggle(from: from)
        case .voiceCommandMode(let appBundleId):
            return handleVoiceCommandMode(from: from, appBundleId: appBundleId)
        case .pressAbandoned:
            return handlePressAbandoned(from: from)
        case .hotkeyCancel:
            return handleHotkeyCancel(from: from)
        case .focusClaim(let appBundleId):
            focusClaims.record(edge: from, appBundleId: appBundleId, at: clock())
            return followPointerWithTarget()
        case .pointerPresence:
            // See `FocusClaimRegistry.FocusClaimKind`: unlike `.focusClaim`,
            // Universal Control never duplicates the mouseMoved/leftMouseDown
            // this is derived from across edges, so it's recorded with
            // `.pointer` priority. Session targets also require a claim
            // received since recording started.
            focusClaims.record(edge: from, appBundleId: nil, at: clock(), kind: .pointer)
            return followPointerWithTarget()
        case .level(let rms):
            return handleLevel(rms, from: from)
        case .audioTake(let header):
            return handleAudioTake(header, from: from)
        case .captureFailed(let sessionId, let message):
            guard let session = current, session.id == sessionId, session.micOwner == from,
                  session.phase == .recording || session.phase == .processing && !session.transcribeEmitted else { return [] }
            return endSession(session, outcome: .failed(message: String(message.prefix(500))))
        case .insertResult(let sessionId, let outcome, let destination):
            return handleInsertResult(sessionId: sessionId, outcome: outcome, destination: destination, from: from)
        case .repoRequest:
            // Not a session-flow message — `CoreHost` answers these
            // directly against `RepoServer`.
            return []
        case .sessionOutcomeQuery:
            // Not a session-flow message either — `CoreHost`
            // answers this directly against its own outcome ring buffer
            // (see `apply(_:)`'s interception before this ever reaches here).
            return []
        case .cleanupResult, .modelPullProgress, .pairRequest, .speechResult, .transcribeRequest, .textCleanupRequest,
             .workspaceRememberAll, .workspaceCaptureResult, .workspaceRunAll, .workspaceRunResult:
            // Answers to Core requests, handled by `CoreHost` before the broker.
            return []
        }
    }

    /// Only duplicate presses prove that the keyboard is shared. A conflicting
    /// claim or a missing local mic gets a short window to collect that proof.
    private func beginPress(from H: EdgeID, handsFree: Bool) -> [BrokerEffect] {
        guard edges[H] != nil else { return [.log("press from \(H) ignored: edge not connected")] }
        if var pending = pendingPress {
            guard pending.handsFree == handsFree else {
                return [.log("press from \(H) ignored: different pending gesture")]
            }
            guard !pending.pressers.contains(H) else {
                // Pressed again before the press settled: the key is down now.
                pending.released.remove(H)
                pendingPress = pending
                return [.log("press from \(H) ignored: already pending")]
            }
            pending.pressers.insert(H)
            pendingPress = pending
            return [.cancelPressSettle(pending.id)] + startPendingPress(pending)
        }
        let claimant = focusClaims.freshest(connected: Set(edges.keys))
        let preferredHasMic = micOwnerPreference.flatMap { edges[$0]?.caps.hasMic } == true
        let needsMicEvidence = edges[H]?.caps.hasMic != true && !preferredHasMic
            && edges.values.contains { $0.id != H && $0.caps.hasMic }
        if (claimant != nil && claimant != H) || needsMicEvidence {
            nextPressID += 1
            pendingPress = PendingPress(id: nextPressID, first: H, handsFree: handsFree, pressers: [H])
            return [.schedulePressSettle(nextPressID, Self.pressSettle)]
        }
        return startSession(initiator: H, pressers: [H], handsFree: handsFree)
    }

    private func startPendingPress(_ pending: PendingPress) -> [BrokerEffect] {
        pendingPress = nil
        let pressers = pending.pressers.intersection(Set(edges.keys))
        guard !pressers.isEmpty else { return [] }
        let first = pressers.contains(pending.first) ? pending.first : pressers.sorted()[0]
        let initiator = focusClaims.freshest(connected: pressers) ?? first
        if pressers.count == 1 {
            // A lone press locates this person more reliably than an old claim.
            focusClaims.record(edge: first, appBundleId: nil, at: clock(), kind: .pointer)
        }
        var effects = startSession(initiator: initiator, pressers: pressers,
                                   handsFree: pending.handsFree, voiceCommandMode: pending.voiceCommandMode, commandApps: pending.commandApps)
        for edge in pending.released.sorted() where pressers.contains(edge) && current != nil {
            effects += handleHotkeyUp(from: edge)
        }
        return effects
    }

    private func startSession(initiator: EdgeID, pressers: Set<EdgeID>, handsFree: Bool,
                              voiceCommandMode: Bool = false, commandApps: [EdgeID: String] = [:]) -> [BrokerEffect] {
        guard let m = selectMicOwner(initiator: initiator, pressers: pressers) else {
            let message = edges.values.contains { $0.caps.hasMic }
                ? DictationAlert.microphoneOnAnotherMac().encoded : "No connected edge has a microphone."
            let gesture = handsFree ? "hotkeyToggle" : "hotkeyDown"
            // Every presser is waiting on an answer. One left unanswered would
            // assume the main Mac went quiet and record on its own.
            return pressers.sorted().map { .send($0, .error(code: "noMic", message: message)) }
                + [.log("\(gesture) from \(initiator): no edge with a microphone is available")]
        }
        let sessionId = makeSessionID()
        var s = Session(id: sessionId, initiator: initiator, micOwner: m, target: initiator, phase: .recording)
        s.pressers = pressers
        s.heldEdges = handsFree ? [] : pressers
        s.handsFree = handsFree
        s.startedAt = clock()
        s.voiceCommandMode = voiceCommandMode
        s.commandApps = commandApps
        current = s
        // Roles must arrive before the command to start capture.
        return broadcastSessionState(s)
            + [.send(m, .captureStart(sessionId: sessionId))]
            + [.scheduleWatchdog(sessionId, EdgeProtocol.maxSessionDuration)]
            + [.scheduleCountdown(sessionId, EdgeProtocol.maxSessionDuration - EdgeProtocol.countdownLead)]
    }

    private func busyPress(from edge: EdgeID, log: String) -> [BrokerEffect] {
        var effects: [BrokerEffect] = [.log(log)]
        let time = clock()
        if busyNotices[edge].map({ time - $0 >= Self.busyNoticeInterval }) ?? true {
            busyNotices[edge] = time
            effects.append(.send(edge, .error(code: "sessionBusy", message: DictationAlert.dictationStillFinishing().encoded)))
        }
        return effects
    }

    private func handleHotkeyDown(from H: EdgeID) -> [BrokerEffect] {
        guard edges[H] != nil else { return [.log("press from \(H) ignored: edge not connected")] }
        guard let s = current else { return beginPress(from: H, handsFree: false) }
        switch s.phase {
        case .recording:
            guard !s.handsFree else {
                return busyPress(from: H, log: "hotkeyDown from \(H) ignored: hands-free session already active")
            }
            return joinHold(from: H, s)
        case .processing, .inserting, .idle:
            return busyPress(from: H, log: "hotkeyDown from \(H) ignored: session already active")
        }
    }

    /// A `hotkeyDown` from an edge that's already part of (or joining) the
    /// current hold. If a release grace was pending — the set had emptied
    /// and was waiting out `releaseGrace` before stopping — this re-press
    /// cancels it, exactly like the physical key never actually came up.
    private func joinHold(from H: EdgeID, _ s: Session) -> [BrokerEffect] {
        var next = s
        next.pressers.insert(H)
        next.heldEdges.insert(H)
        var effects: [BrokerEffect] = []
        if next.releaseGracePending {
            next.releaseGracePending = false
            effects.append(.cancelReleaseGrace(next.id))
        }
        current = next
        effects.append(.log("hotkeyDown from \(H) joined the hold for session \(next.id)"))
        return effects
    }

    private func handleHotkeyUp(from E: EdgeID) -> [BrokerEffect] {
        if var pending = pendingPress, pending.pressers.contains(E) {
            pending.released.insert(E)
            pendingPress = pending
            return []
        }
        guard let s = current, s.phase == .recording else {
            return [.log("hotkeyUp from \(E) ignored: no recording session")]
        }
        // A release means nothing in hands-free mode — the session only
        // stops on a second `hotkeyToggle`. This also covers the modifier
        // watchdog and listener-loss `hotkeyUp` reasons: a synthesized "stop"
        // from a lost key-up would otherwise end a session tap-to-start never
        // asked it to hold in the first place.
        guard !s.handsFree else {
            return [.log("hotkeyUp from \(E) ignored: hands-free session, release means nothing")]
        }
        var next = s
        if next.heldEdges.remove(E) == nil {
            // E was never seen holding — either its own `hotkeyDown` never
            // reached us, or (the Universal Control finding) it only ever
            // saw the synthetic key-up half of a press whose real down
            // landed on the other Mac. Not a release of anything this
            // broker is tracking as held, unless nothing is held any more
            // (e.g. the sole holder already disconnected) — then the grace
            // still needs to be running, same as any other emptying of the set.
            guard next.heldEdges.isEmpty else {
                return [.log("hotkeyUp from \(E) ignored: not currently held")]
            }
            current = next
            return scheduleReleaseGraceIfNeeded(next)
        }
        guard next.heldEdges.isEmpty else {
            current = next
            return [.log("release from \(E) ignored, still held by \(next.heldEdges.sorted().joined(separator: ", "))")]
        }
        current = next
        return scheduleReleaseGraceIfNeeded(next)
    }

    /// Arms `.scheduleReleaseGrace` the moment `heldEdges` empties while
    /// still recording — idempotent, so a redundant "nothing's held" signal
    /// (e.g. a stray `hotkeyUp` after the sole holder already disconnected)
    /// never restarts a grace that's already ticking.
    private func scheduleReleaseGraceIfNeeded(_ s: Session) -> [BrokerEffect] {
        guard !s.releaseGracePending else { return [] }
        var next = s
        next.releaseGracePending = true
        current = next
        return [.scheduleReleaseGrace(next.id, SessionBroker.releaseGrace)]
    }

    /// The release grace elapsed with nobody re-pressing. Only actually
    /// stops capture if the session is still `.recording`, matches, and
    /// `heldEdges` is still empty — a new holder joining (or the session
    /// ending some other way) in the meantime makes this a no-op.
    private func handleReleaseGraceFired(_ sessionId: SessionID) -> [BrokerEffect] {
        guard let s = current, s.id == sessionId, s.phase == .recording, s.releaseGracePending, s.heldEdges.isEmpty else { return [] }
        return transitionToProcessing(s) + [.log("release grace fired for session \(sessionId): stopping capture")]
    }

    /// Duplicate toggles during debounce join the evidence for a shared keyboard.
    private func handleHotkeyToggle(from E: EdgeID) -> [BrokerEffect] {
        guard edges[E] != nil else { return [.log("press from \(E) ignored: edge not connected")] }
        guard let s = current else { return beginPress(from: E, handsFree: true) }
        switch s.phase {
        case .recording:
            guard s.handsFree else {
                return busyPress(from: E, log: "hotkeyToggle from \(E) ignored: hold-to-talk session already active")
            }
            guard clock() - s.startedAt >= SessionBroker.toggleDebounce else {
                var next = s
                next.pressers.insert(E)
                current = next
                return [.log("hotkeyToggle from \(E) ignored: duplicate tap absorbed")]
            }
            var next = s
            next.tapStoppedAt = clock()
            return transitionToProcessing(next) + [.log("hotkeyToggle from \(E): stopping hands-free capture")]
        case .processing, .inserting, .idle:
            if let stopped = s.tapStoppedAt, clock() - stopped < SessionBroker.toggleDebounce {
                return [.log("hotkeyToggle from \(E) ignored: duplicate of the tap that stopped recording")]
            }
            return busyPress(from: E, log: "hotkeyToggle from \(E) ignored: session already active")
        }
    }

    /// Marks the recording session as shortcut mode and tells every Mac, so
    /// the indicator changes on whichever one is the target. Only while
    /// recording, or remembered from a presser while the press settles.
    /// A late copy after recording changes nothing.
    private func handleVoiceCommandMode(from E: EdgeID, appBundleId: String?) -> [BrokerEffect] {
        if var pending = pendingPress, pending.pressers.contains(E) {
            pending.voiceCommandMode = true
            if let appBundleId { pending.commandApps[E] = appBundleId }
            pendingPress = pending
            return []
        }
        guard var s = current, s.phase == .recording, s.pressers.contains(E) else {
            return [.log("shortcutMode from \(E) ignored: no recording session")]
        }
        if let appBundleId, s.commandApps[E] == nil { s.commandApps[E] = appBundleId }
        if s.voiceCommandMode { current = s; return [] }
        s.voiceCommandMode = true
        current = s
        return [.log("session \(s.id) is in shortcut mode")] + broadcastSessionState(s)
    }

    /// Called by the host, before `transcriptionFinished`, with what the
    /// words matched. The insert then goes out as `insert.shortcut`.
    func attachVoiceCommand(_ delivery: VoiceCommandDelivery, sessionId: SessionID) {
        guard var s = current, s.id == sessionId, s.phase == .processing else { return }
        s.voiceCommand = delivery
        current = s
    }

    /// Called by the host, before `transcriptionFinished`, when the words
    /// matched a voice launch shortcut. The insert then goes out as `insert.launch`.
    func attachLaunch(_ plan: VoiceLaunchPlan, sessionId: SessionID) {
        guard var s = current, s.id == sessionId, s.phase == .processing else { return }
        s.launch = plan
        current = s
    }

    private func handlePressAbandoned(from: EdgeID) -> [BrokerEffect] {
        guard let pending = pendingPress, pending.pressers.contains(from) else {
            return [.log("pressAbandoned from \(from) ignored: no press settling")]
        }
        pendingPress = nil
        return [.cancelPressSettle(pending.id), .log("press from \(from) abandoned: it was a typed character")]
    }

    private func handleHotkeyCancel(from: EdgeID) -> [BrokerEffect] {
        if let pending = pendingPress, pending.pressers.contains(from) {
            pendingPress = nil
            return [.cancelPressSettle(pending.id)]
        }
        guard let s = current else { return [] }
        switch s.phase {
        case .recording:
            return endSession(s, outcome: .cancelled(.user), extra: [.send(s.micOwner, .captureCancel(sessionId: s.id))])
        case .processing:
            return endSession(s, outcome: .cancelled(.user), extra: [.cancelTranscription(s.id)])
        case .inserting:
            // Once `insert` is in flight the target's own PasteService call
            // has already started (or is about to); there's nothing left to
            // take back. The insertion watchdog (see `insertTimeout`) is the
            // only way out of a target that never replies — Esc is a
            // documented no-op here.
            return []
        case .idle:
            return []
        }
    }

    private func handleLevel(_ rms: Float, from: EdgeID) -> [BrokerEffect] {
        guard let s = current, s.phase == .recording, from == s.micOwner, let target = s.target, target != from else { return [] }
        return [.send(target, .level(rms: rms))]
    }

    /// Keep the indicator on the same target final insertion would choose.
    /// New pointer evidence wins; keystroke evidence is limited to pressers.
    private func followPointerWithTarget() -> [BrokerEffect] {
        guard var s = current, s.phase == .recording || s.phase == .processing else { return [] }
        let fresh = resolveInsertionTarget(for: s)
        guard fresh != s.target else { return [] }
        s.target = fresh
        current = s
        var effects = broadcastSessionState(s)
        // The warning is already showing: the Mac that just became the
        // target needs it too, with what is left.
        if s.phase == .recording, let ends = s.countdownEndsAt, let fresh {
            let left = max(1, Int((ends - clock()).rounded(.up)))
            effects.append(.send(fresh, .sessionCountdown(sessionId: s.id, secondsLeft: left)))
        }
        return effects
    }

    private func handleAudioTake(_ header: AudioTakeHeader, from: EdgeID) -> [BrokerEffect] {
        guard let s = current, s.phase == .processing, !s.transcribeEmitted,
              from == s.micOwner, header.sessionId == s.id else {
            return [.log("audioTake ignored from \(from): no matching processing session")]
        }
        // Unlike the routing checks above, a header that matches the right
        // session/edge but doesn't semantically add up is M lying (or badly
        // broken) about the take it's about to send — there is no binary
        // frame worth waiting for, so end the session now instead of
        // leaving it stuck in `.processing` forever.
        guard isSemanticallyValidAudioTakeHeader(header) else {
            return endSession(s, outcome: .failed(message: Self.audioUploadFailure))
                + [.log("audioTake ignored from \(from): invalid header")]
        }
        var next = s
        next.pendingAudioHeader = header
        current = next
        return []
    }

    /// `audio.take` is otherwise-trusted metadata from M — sanity-check it
    /// before relying on it downstream (feeding the inference server,
    /// aggregate duration stats). `byteCount == frameCount * 4` because the
    /// binary frame that follows is 16 kHz float32 PCM (4 bytes/frame).
    private func isSemanticallyValidAudioTakeHeader(_ header: AudioTakeHeader) -> Bool {
        guard header.byteCount >= 0, header.byteCount <= EdgeProtocol.maxBinaryFrameBytes else { return false }
        guard header.frameCount >= 0, header.frameCount <= EdgeProtocol.maxBinaryFrameBytes / 4,
              header.byteCount == header.frameCount * 4 else { return false }
        guard header.sampleRate == 16_000 else { return false }
        guard header.durationSeconds.isFinite,
              (0...(EdgeProtocol.maxSessionDuration + 5)).contains(header.durationSeconds) else { return false }
        return true
    }

    // MARK: - Binary audio frame

    private func handleAudio(_ data: Data, from: EdgeID) -> [BrokerEffect] {
        guard let s = current, s.phase == .processing, from == s.micOwner, let header = s.pendingAudioHeader else {
            return [.log("audio frame ignored from \(from): no pending audio.take header")]
        }
        guard header.byteCount == data.count else {
            return endSession(s, outcome: .failed(message: Self.audioUploadFailure))
                + [.log("audio frame ignored from \(from): size mismatch (header \(header.byteCount) bytes, got \(data.count))")]
        }
        // Mirrors today's `stopCapture() == nil` path — nothing to transcribe.
        if header.frameCount == 0 || data.isEmpty {
            return endSession(s, outcome: .cancelled(.noAudio))
        }
        var next = s
        next.pendingAudioHeader = nil
        next.transcribeEmitted = true
        next.audioDurationSeconds = header.durationSeconds
        current = next
        return [.cancelWatchdog(s.id), .transcribe(s.id, header, data)]
    }

    // MARK: - Transcription result

    private func handleTranscriptionFinished(_ sessionId: SessionID, text: String?, inferenceMs: Int?, error: String?) -> [BrokerEffect] {
        guard let s = current, s.phase == .processing, s.id == sessionId else { return [] }

        if let error {
            return endSession(s, outcome: .failed(message: error))
        }
        // Whitespace-only text is treated the same as an empty transcription:
        // pasting whitespace is never useful. A shortcut that matched with
        // nothing said after its name still opens its destination, so an empty
        // remainder is not "nothing heard".
        let opensVoiceCommand = s.launch != nil
        guard let text, opensVoiceCommand || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return endSession(s, outcome: .empty)
        }

        guard let target = resolveInsertionTarget(for: s) else {
            // The only fallback once no focus claim survives is the
            // initiator, and it's gone too — there's nowhere to insert.
            // End idle instead of wedging the Core in `.inserting` forever.
            return endSession(s, outcome: .cancelled(.initiatorLost))
        }
        var next = s
        next.phase = .inserting
        next.target = target
        next.text = text
        next.inferenceMs = inferenceMs
        current = next
        // `sessionState(inserting, target)` goes out to every edge before
        // the target is told to `insert`, so it (and everyone else) knows
        // its role before any command tied to that role arrives.
        var delivery = s.voiceCommand
        delivery?.text = text
        let insert: CoreMessage = s.launch.map { .launchInsert(sessionId: s.id, plan: $0) }
            ?? delivery.map { .voiceCommandInsert(sessionId: s.id, delivery: $0) }
            ?? .insert(sessionId: s.id, text: text)
        return broadcastSessionState(next)
            + [.send(target, insert)]
            + [.scheduleWatchdog(s.id, Self.insertionTimeout(for: s.launch))]
    }

    /// Both the live indicator and final insertion use evidence received during
    /// this session. Only pressers can redirect via ambiguous keystroke claims.
    private func resolveInsertionTarget(for s: Session) -> EdgeID? {
        focusClaims.freshest(connected: Set(edges.keys), since: s.startedAt, keystrokeEdges: s.pressers)
            ?? (edges[s.initiator] != nil ? s.initiator : nil)
    }

    private func handleInsertResult(sessionId: SessionID, outcome: SessionOutcome, destination: InsertDestination?, from: EdgeID) -> [BrokerEffect] {
        guard let s = current, s.phase == .inserting, s.id == sessionId, from == s.target else {
            return [.log("insertResult ignored from \(from): not the current insertion target")]
        }
        let history = BrokerEffect.recordHistory(
            sessionId: s.id,
            text: s.text ?? "",
            durationSeconds: s.audioDurationSeconds ?? 0,
            inferenceMs: s.inferenceMs,
            destination: destination,
            initiator: s.initiator
        )
        // A shortcut said with nothing after its name has no words to keep.
        let hasWords = !(s.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasWords ? [history] : []) + endSession(s, outcome: outcome)
    }

    // MARK: - Watchdog

    private func handleWatchdogFired(_ sessionId: SessionID) -> [BrokerEffect] {
        guard let s = current, s.id == sessionId else { return [] }
        switch s.phase {
        case .recording:
            var stopped = s
            stopped.recordingLimitReached = true
            return transitionToProcessing(stopped) + [.log("watchdog fired for session \(sessionId)")]
        case .inserting:
            // The target never sent `insert.result` — give up rather than
            // wedge the session in `.inserting` forever.
            return endSession(s, outcome: .failed(message: "The Mac you’re using didn’t confirm that it typed your text."))
                + [.log("insertion watchdog fired for session \(sessionId)")]
        case .processing:
            guard !s.transcribeEmitted else { return [] }
            return endSession(s, outcome: .failed(message: Self.audioUploadFailure))
                + [.log("audio upload watchdog fired for session \(sessionId)")]
        case .idle:
            return []
        }
    }

    /// The recording is `countdownLead` seconds from the time limit: tell
    /// the Mac showing the badge and the one the key was pressed on. The
    /// Macs count down on their own; a new `sessionState` clears it.
    private func handleCountdownFired(_ sessionId: SessionID) -> [BrokerEffect] {
        guard var s = current, s.id == sessionId, s.phase == .recording else { return [] }
        s.countdownEndsAt = clock() + EdgeProtocol.countdownLead
        current = s
        let seconds = Int(EdgeProtocol.countdownLead)
        return countdownAudience(s).map { .send($0, .sessionCountdown(sessionId: s.id, secondsLeft: seconds)) }
    }

    private func countdownAudience(_ s: Session) -> [EdgeID] {
        var ids = Set([s.initiator])
        if let target = s.target { ids.insert(target) }
        return ids.filter { edges[$0] != nil }.sorted()
    }

    // MARK: - Shared transitions

    /// A matching `watchdogFired` (120 s, regardless of the held set) and a
    /// `releaseGraceFired` (once `heldEdges` has genuinely emptied out) both
    /// stop capture the same way; the watchdog also marks the time limit.
    /// `heldEdges`/`releaseGracePending` are no longer meaningful once
    /// capture has stopped, so this clears them too.
    private func transitionToProcessing(_ s: Session) -> [BrokerEffect] {
        var next = s
        next.phase = .processing
        next.heldEdges = []
        next.releaseGracePending = false
        current = next
        return [.send(s.micOwner, .captureStop(sessionId: s.id)), .cancelWatchdog(s.id), .cancelCountdown(s.id)]
            + broadcastSessionState(next) + [.scheduleWatchdog(s.id, Self.audioUploadTimeout)]
    }

    /// Ends `s`, clears the active session, and broadcasts `idle` + `outcome`
    /// to the edges still connected. `extra` effects (e.g. a captureCancel to
    /// the mic owner) go out first; any watchdog armed for `s.phase` is
    /// cancelled right after, followed by `.cancelReleaseGrace` if a release
    /// grace was outstanding — a session can end (mic/initiator/target lost,
    /// `hotkeyCancel`, …) while still waiting one out, and there's no reason
    /// to leave that timer running for a session that's already gone.
    private func endSession(_ s: Session, outcome: SessionOutcome, extra: [BrokerEffect] = []) -> [BrokerEffect] {
        var effects = extra
        // A watchdog can be pending in either `.recording` (the 120 s
        // capture cap) or `.inserting` (the `insertTimeout` fuse) — cancel
        // whichever one might be armed so ending the session never leaves a
        // stale timer to fire later (it would be a no-op against the
        // now-nil `current`, but there's no reason to leak it).
        if s.phase == .recording || s.phase == .inserting || (s.phase == .processing && !s.transcribeEmitted) {
            effects.append(.cancelWatchdog(s.id))
        }
        if s.phase == .recording {
            effects.append(.cancelCountdown(s.id))
        }
        if s.releaseGracePending {
            effects.append(.cancelReleaseGrace(s.id))
        }
        current = nil
        var idleSession = s
        idleSession.phase = .idle
        idleSession.heldEdges = []
        idleSession.releaseGracePending = false
        return effects + broadcastSessionState(idleSession, outcome: outcome)
    }

    // MARK: - Mic owner selection

    /// Only an explicit preference or a reported press permits remote recording.
    private func selectMicOwner(initiator: EdgeID, pressers: Set<EdgeID>) -> EdgeID? {
        if let preferred = micOwnerPreference, let info = edges[preferred], info.caps.hasMic {
            return preferred
        }
        if let initiatorInfo = edges[initiator], initiatorInfo.caps.hasMic {
            return initiator
        }
        return pressers.filter { edges[$0]?.caps.hasMic == true }.sorted().first
    }

    // MARK: - Broadcast helpers

    private func sessionStateUpdate(for s: Session, outcome: SessionOutcome?) -> SessionStateUpdate {
        SessionStateUpdate(sessionId: s.id, state: s.phase, initiator: s.initiator, micOwner: s.micOwner, target: s.target, outcome: outcome, voiceCommandMode: s.voiceCommandMode ? true : nil, recordingLimitReached: s.recordingLimitReached ? true : nil)
    }

    /// Sorted by id so tests (and any host) see a deterministic fan-out order.
    private func broadcastSessionState(_ s: Session, outcome: SessionOutcome? = nil) -> [BrokerEffect] {
        let update = sessionStateUpdate(for: s, outcome: outcome)
        return edges.keys.sorted().map { .send($0, .sessionState(update)) }
    }
}
