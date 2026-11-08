import AVFoundation
import Foundation
import SwiftUI

/// Owns everything on this machine that a dictation session actually
/// touches — mic, hotkey, paste, indicator, sound — and speaks only
/// `EdgeMessage`/`CoreMessage` to whoever it is wired to: a local `CoreHost`
/// (standalone or Core role) or a remote `CoreConnection` (Edge role). It has
/// no idea which one that is; `DictatorViewModel.applyRole()` decides and
/// rewires `send`/`sendAudio` accordingly.
@MainActor
@Observable
final class EdgeRuntime {
    /// Blocking runtime health for this machine's hotkey tap. A missing
    /// microphone is not part of this, because the user can choose another
    /// Mac to record in Your Macs.
    enum Health: Equatable {
        case ready
        case needsPermission(String)
    }

    private enum RuntimeComponent: Hashable {
        case audio
        case hotkey
    }

    let edgeId: EdgeID
    var edgeName: String

    /// Set by whoever connects this runtime: `CoreHost.attachLocalEdge` when
    /// standalone/Core, a `CoreConnection` when Edge.
    var send: ((EdgeMessage) -> Void)?
    var sendAudio: ((AudioTakeHeader, Data) -> Void)?

    /// Set only while this Mac is wired to a main Mac over the network:
    /// whether that link has answered recently. Nil means the session runs
    /// on this Mac, which is always reachable.
    var isMainMacLive: (() -> Bool)?
    /// Asked to switch this Mac over to running the dictation itself, because
    /// the main Mac can't be reached. After it returns, `send` reaches this
    /// Mac's own broker.
    var onMainMacUnreachable: (() -> Void)?

    /// Fired whenever `capabilities()` would return something different from
    /// the last value observed — after mic permission results, audio engine
    /// start/recovery/failure, and hotkey mode changes — so whoever is
    /// downstream (a remote `CoreConnection`, or `CoreHost` for the local
    /// edge) never relies on the capability snapshot taken at hello time.
    var onCapabilitiesChanged: ((EdgeCapabilities) -> Void)?
    /// Workspace launch, asked by the main Mac: remember this Mac's windows,
    /// or run a routine on them. Set by the app to `WorkspaceLaunchController`.
    var onWorkspaceCapture: (() async -> (macID: String?, layout: WorkspaceSavedLayout?, error: String?))?
    var onWorkspaceRun: ((_ routineID: String, _ undo: Bool, _ from: String, _ operationID: String?) async -> WorkspaceRunOutcome)?
    /// Injected only by synthetic execution/delivery tests; nil uses live services.
    var voiceLaunchServices: VoiceLaunchServices?
    /// Fired on every 5s runtime-health tick, after this runtime's own
    /// audio/hotkey recovery.
    var onHealthTick: (() -> Void)?

    /// Set by the coordinator to reflect `AppSettings.coreRole`: decides
    /// whether a denied/restricted microphone blocks this machine (only in
    /// `.standalone`, where no other Edge/Core can supply one) or merely
    /// warns (`.core`/`.edge`, where another machine might have a mic).
    var roleForHealth: CoreRole = .standalone {
        didSet {
            guard oldValue != roleForHealth else { return }
            refreshMicBlockingForRole()
        }
    }

    /// Core-owned hands-free preference, learned from `CoreMessage.config`
    /// (see `handle(_:)`). Drives whether this machine's own hotkey tap
    /// speaks `hotkeyToggle` (tap-to-start/tap-to-stop) or the classic
    /// `hotkeyDown`/`hotkeyUp` (hold-to-talk) — see `wireHotkey()`.
    private(set) var handsFree = false
    private(set) var phase: SessionPhase = .idle
    private(set) var isInitiator = false
    private(set) var isMicOwner = false
    private(set) var isTarget = false
    /// The most recent `sessionState` this runtime has seen, used to gate
    /// `insert` against a session/target this machine actually has.
    private(set) var lastSessionState: SessionStateUpdate?

    var health: Health = .ready
    /// Non-blocking: "this machine has no usable microphone right now."
    var micWarning: String?
    var onInsertedForLearning: ((SessionID, String, CaptureContext) -> Void)?
    var onNextDictationForLearning: (() -> Void)?
    var insertionWarning: String?
    var needsAccessibility = false
    var lastTranscription: String?
    /// Set only for the initiator of a session that failed — see
    /// `applyIdleOutcome`.
    var errorMessage: String?

    // Not private: `DictatorViewModel` wires these directly; they sit outside
    // the Edge↔Core protocol.
    let audioService: AudioCaptureService
    let hotkeyService: HotkeyService
    let indicator: IndicatorWindowController
    private let focusClaimDetector: FocusClaimDetector

    private var runtimeFailures: Set<RuntimeComponent> = []
    private var runtimeHealthTimer: Timer?
    /// Spaces out microphone restarts after failures (5 s doubling to a
    /// 5-minute ceiling), so a microphone that stays broken isn't retried
    /// every health tick for hours. Reset by a newly connected device or
    /// an explicit "Try again".
    private(set) var audioRetry = RetryBackoff()
    private var deviceObservers: [NSObjectProtocol] = []
    /// Clock for `audioRetry`; tests replace it.
    var now: () -> Date = Date.init
    /// Whether runtime start-up may show the system permission requests.
    /// Off until the first-run welcome has explained them; the welcome
    /// then asks for each one with `requestMicrophoneAccess()` and
    /// `HotkeyService.requestMissingPermissions()`.
    var promptsForPermissions = true
    private var micAvailable = false
    /// Non-nil only while the hotkey tap is down (Accessibility/Input
    /// Monitoring missing) — always blocking, in every role.
    private var hotkeyFailureMessage: String?
    /// Non-nil only while a denied/restricted mic permission should block
    /// this machine (`.standalone` role) — see `refreshMicBlockingForRole`.
    private var micBlockingMessage: String?
    /// Last `EdgeCapabilities` handed to `onCapabilitiesChanged`, so it only
    /// fires on an actual change.
    private var lastNotifiedCapabilities: EdgeCapabilities?
    /// Last time a relayed level was sent upstream (mic-owner-not-initiator
    /// path only) — throttled to ≤10 Hz so it never floods the wire.
    private var lastLevelSendTime: CFTimeInterval = 0
    /// When the hotkey was released for each session this Mac recorded, so
    /// the paste can report how long the text took to land.
    private var releaseTimes: [SessionID: Date] = [:]
    private var errorClearTask: Task<Void, Never>?
    /// Says on screen what went wrong with a dictation started here.
    let alerts = DictationAlertController()
    let launchProgress = VoiceLaunchProgressController()
    let nearMissNotice = VoiceNearMissNoticeController()

    /// Models Ollama has installed on this Mac (`LocalModelInventory`),
    /// nil while Ollama isn't running; reported in `capabilities()`.
    var localModels: [String]? = nil {
        didSet {
            guard localModels != oldValue else { return }
            notifyCapabilitiesChangedIfNeeded()
        }
    }

    /// Speech-to-text models installed in Dictator on this Mac.
    var speechModels: [String] = [] {
        didSet {
            guard speechModels != oldValue else { return }
            notifyCapabilitiesChangedIfNeeded()
        }
    }

    /// Transcribes a recording the Core sent with one of this Mac's speech
    /// models and answers with `speech.result`.
    func runSpeechJob(_ job: SpeechJob, audio: Data) {
        Task { @MainActor [weak self] in
            let samples = audio.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            do {
                let text = try await LocalSpeechService.shared.transcribe(job.model, samples: samples, languages: job.languages, vocabulary: job.vocabulary)
                self?.send?(.speechResult(requestId: job.requestId, text: text, error: nil))
            } catch {
                self?.send?(.speechResult(requestId: job.requestId, text: nil, error: error.localizedDescription))
            }
        }
    }

    // MARK: - Teach recording (Settings › Voice launch)

    /// Called with each mic level while a Teach take records.
    var teachLevelObserver: ((Float) -> Void)?

    private enum CaptureOwner: Equatable {
        case teach
        case dictation(SessionID)
    }
    private var captureOwner: CaptureOwner?
    var isTeachRecording: Bool { captureOwner == .teach }
    var hasDictationInProgress: Bool {
        captureOwner != nil || pendingStart != nil || (lastSessionState.map { $0.state != .idle } ?? false)
    }
    static let microphoneBusyMessage = "Another recording is using this Mac’s microphone. Finish that recording and try again."

    /// Starts a Teach take only while no other take or pending dictation owns
    /// this Mac's microphone.
    func beginTeachRecording() -> Bool {
        guard phase == .idle, pendingStart == nil, captureOwner == nil, !audioService.isCaptureActive else { return false }
        captureOwner = .teach
        audioService.startCapture()
        notifyCapabilitiesChangedIfNeeded()
        return true
    }

    /// Ends the Teach-owned take and hands back its 16 kHz mono audio, or nil
    /// if it received no buffers or Teach no longer owns it. Nothing is kept.
    func endTeachRecording() -> CapturedAudio? {
        guard isTeachRecording else { return nil }
        captureOwner = nil
        let audio = audioService.stopCapture()
        notifyCapabilitiesChangedIfNeeded()
        return audio
    }

    func cancelTeachRecording() {
        guard isTeachRecording else { return }
        captureOwner = nil
        audioService.cancelCapture()
        notifyCapabilitiesChangedIfNeeded()
    }

    /// The Core's picture of the whole setup (Settings › Your Macs). Kept
    /// on disk so a Mac whose Core is off can still draw the last one.
    private(set) var setupSnapshot: SetupSnapshot? = EdgeRuntime.loadSetupSnapshot()

    /// Core/standalone role: the snapshot is built on this Mac and handed
    /// straight in, the same way a remote Edge receives it.
    func applySetupSnapshot(_ snapshot: SetupSnapshot) {
        guard snapshot != setupSnapshot else { return }
        setupSnapshot = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.setupSnapshotKey)
        }
    }

    private static let setupSnapshotKey = "lastSetupSnapshot"

    private static func loadSetupSnapshot() -> SetupSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: setupSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(SetupSnapshot.self, from: data)
    }

    // `IndicatorWindowController` is itself `@MainActor`, and a default
    // argument expression does not inherit the enclosing (also `@MainActor`)
    // initializer's isolation — constructing it as a default parameter value
    // fails to compile. Defaults are `nil` here and built below instead,
    // inside the (properly MainActor-isolated) initializer body.
    init(
        edgeId: EdgeID? = nil,
        edgeName: String? = nil,
        audioService: AudioCaptureService? = nil,
        hotkeyService: HotkeyService? = nil,
        indicator: IndicatorWindowController? = nil,
        focusClaimDetector: FocusClaimDetector? = nil
    ) {
        self.edgeId = edgeId ?? Self.loadOrCreateEdgeID()
        let settings = AppSettings.shared
        self.edgeName = edgeName ?? (settings.edgeDisplayName.isEmpty
            ? (Host.current().localizedName ?? "This Mac")
            : settings.edgeDisplayName)
        self.audioService = audioService ?? AudioCaptureService()
        self.hotkeyService = hotkeyService ?? HotkeyService()
        self.indicator = indicator ?? IndicatorWindowController()
        self.focusClaimDetector = focusClaimDetector ?? FocusClaimDetector()
    }

    // MARK: - Lifecycle

    func setup() {
        wireHotkey()
        wireAudioLevel()
        wireFocusClaim()
        wirePointerPresence()
        indicator.prepare()
        refreshMicrophoneAccess()
        refreshHotkeyAccess()
        startRuntimeHealthMonitor()
        observeAudioDevices()
    }

    func retrySetup() {
        audioRetry.reset()
        refreshMicrophoneAccess()
        refreshHotkeyAccess()
    }

    /// The welcome's "Allow microphone" step: asks macOS once, now.
    func requestMicrophoneAccess(completion: (@MainActor (Bool) -> Void)? = nil) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.audioRetry.reset()
                    self.startAudioEngine()
                } else {
                    self.applyMicPermissionDenied()
                }
                completion?(granted)
            }
        }
    }

    /// A microphone appearing or disappearing is the moment a broken one is
    /// most likely to start working, so don't make it wait out the backoff.
    private func observeAudioDevices() {
        guard deviceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.runtimeFailures.contains(.audio) else { return }
                    self.audioRetry.reset()
                    self.recoverRuntimeIfNeeded()
                }
            })
        }
    }

    /// What the microphone problem means for the person, not Core Audio's
    /// error code (which goes to the log).
    nonisolated static func microphoneProblemText(for error: Error) -> String {
        if let error = error as? AudioCaptureError, let text = error.errorDescription {
            return text
        }
        return "This Mac’s microphone stopped working. Dictator keeps trying to reconnect it; unplugging and reconnecting the microphone, or choosing another one in Settings › General, can help."
    }

    /// Never wedges on transport loss. Called by the coordinator for a
    /// session that belongs to the main Mac's broker (the local edge isn't
    /// attached): on `CoreConnection.onDisconnected`, before re-attaching
    /// the local edge, and on `onConnected` when this runtime isn't idle
    /// (the Core sends no state to a joining/rejoining edge when it's idle,
    /// so nothing else would ever clear a stale phase). A fallback dictation
    /// running on this Mac's own broker is left alone.
    func resetSession(reason: String, connectionLost: Bool = false) {
        // A transport loss leaves a pending start for the caller to resolve once
        // the local edge is attached (`resolvePendingStartAfterDisconnect`);
        // any other reset ends it.
        if !connectionLost { clearPendingStart() }
        replayedGestureHandsFree = nil
        pendingFallbackAlert = nil
        // Session participation determines recovery guidance. The initiator
        // may use another Mac's microphone and have no local capture owner.
        var recordingInterrupted = phase == .recording
        if case .dictation = captureOwner {
            recordingInterrupted = true // processing may precede capture.stop
            // Keep an owned dictation checkpoint on transport loss. Teach
            // owns a separate take and must survive an unrelated reset.
            audioService.abandonCapture()
            captureOwner = nil
        }
        if connectionLost, recordingInterrupted, isInitiator || isMicOwner {
            SoundService.playError()
            if isMicOwner {
                alerts.show(Self.recordingKeptHereAlert)
            } else {
                let owner = lastSessionState?.micOwner
                let name = owner.flatMap { id in setupSnapshot?.machines.first { $0.id == id }?.name }
                alerts.show(Self.recordingKeptElsewhereAlert(macName: name))
            }
        }
        stopCountdown()
        indicator.hide()
        phase = .idle
        isInitiator = false
        isMicOwner = false
        isTarget = false
        lastSessionState = nil
        refreshCancelEligible()
        NSLog("[Edge] session reset: %@", reason)
    }

    // MARK: - Capabilities

    func capabilities() -> EdgeCapabilities {
        EdgeCapabilities(
            hasMic: micAvailable && !isTeachRecording,
            inputDeviceUID: audioService.activeDeviceUID,
            accessibility: HotkeyService.isAccessibilityGranted,
            inputMonitoring: HotkeyService.isInputMonitoringGranted,
            hotkeyMode: hotkeyService.mode.rawValue,
            machine: MachineProfile.current,
            localModels: localModels,
            speechModels: speechModels,
            appleSpeech: LocalSpeechService.appleAvailable,
            startup: StartupController.currentReport
        )
    }

    /// Fires `onCapabilitiesChanged` exactly when the value would
    /// actually differ from what was last reported, so a remote
    /// `CoreConnection`/local `CoreHost` never has to guess whether it's
    /// worth re-sending.
    private func notifyCapabilitiesChangedIfNeeded() {
        let caps = capabilities()
        guard caps != lastNotifiedCapabilities else { return }
        lastNotifiedCapabilities = caps
        onCapabilitiesChanged?(caps)
    }

    /// Recomputes `micBlockingMessage` for the current mic-permission state
    /// under (possibly new) `roleForHealth`. Only a denied/restricted TCC
    /// status is ever blocking, and only in `.standalone` — a missing
    /// *device* (see `startAudioEngine`'s catch) stays a non-blocking
    /// `micWarning` in every role.
    private func refreshMicBlockingForRole() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let deniedOrRestricted = status == .denied || status == .restricted
        micBlockingMessage = (deniedOrRestricted && roleForHealth == .standalone)
            ? "Dictator isn’t allowed to use the microphone."
            : nil
        recomputeHealth()
    }

    /// `health` blocks the hotkey tap entirely, so a missing tap always
    /// wins; a blocking mic-permission message (standalone only) is the only
    /// other thing allowed to hold `health` open.
    private func recomputeHealth() {
        if let hotkeyFailureMessage {
            health = .needsPermission(hotkeyFailureMessage)
        } else if let micBlockingMessage {
            health = .needsPermission(micBlockingMessage)
        } else {
            health = .ready
        }
    }

    // MARK: - Local device wiring

    /// Internal (not private) so `EdgeRuntimeTests` can drive
    /// `hotkeyService.onStart`/`onStop` directly to exercise the
    /// hands-free/hold-to-talk branch without a live CGEvent tap — mirrors
    /// how `HotkeyService.startModifierWatchdog` is exposed for the same
    /// reason. Set only while this runtime is attached to its own local
    /// broker (standalone or main Mac): reads that broker's current
    /// session synchronously. nil when connected to a remote main Mac.
    var localSession: (() -> SessionSnapshot?)?

    /// What a press knew when the key went down.
    private struct Press {
        var baselineSessionId: SessionID?
    }
    private var press: Press?
    /// What to do when a typed character turns out to be what the press was.
    enum ChordAction: Equatable {
        /// Drop the recording this very press started.
        case cancel
        /// Let go of the hold; nobody's recording is cancelled.
        case release
        case nothing
    }

    /// The simple rule: cancel only when this Mac is attached to its own
    /// local broker and that broker's session is new since the press, was
    /// started by this Mac, and is still recording. Never over a remote
    /// connection, where session-state arrives late.
    static func chordAction(
        handsFree: Bool, attachedLocally: Bool, localSession: SessionSnapshot?, edgeId: EdgeID,
        baselineSessionId: SessionID?
    ) -> ChordAction {
        if attachedLocally, let s = localSession, s.initiator == edgeId, s.id != baselineSessionId, s.phase == .recording {
            return .cancel
        }
        // Hands-free over a remote connection: send nothing. The recording
        // continues until the user taps or presses Esc.
        if handsFree { return .nothing }
        return .release
    }

    func wireHotkey() {
        hotkeyService.onStart = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.press = Press(
                    baselineSessionId: self.localSession.map { $0()?.id } ?? self.lastSessionState?.sessionId
                )
                self.startDictation(self.effectiveHandsFree ? .hotkeyToggle : .hotkeyDown)
            }
        }
        hotkeyService.onStop = { [weak self] reason in
            Task { @MainActor in
                guard let self, !self.isTeachRecording, !self.effectiveHandsFree else { return }
                // In hands-free mode a release (including a synthesized one
                // from the modifier watchdog or a lost listener) means
                // nothing — the Core only stops the session on the next
                // `hotkeyToggle`, so there's nothing to send here.
                self.pendingStart?.release()
                self.send?(.hotkeyUp(reason: reason))
            }
        }
        hotkeyService.onCancel = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isTeachRecording else { return }
                // Esc during the wait for the main Mac: the user called it off,
                // so nothing is recorded here later and no notice is shown.
                self.pendingStart?.cancel()
                self.send?(.hotkeyCancel)
            }
        }
        hotkeyService.onCharacterChord = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isTeachRecording else { return }
                // A typed character, not a dictation: a press still waiting for
                // the main Mac must never be replayed here later.
                self.pendingStart?.cancel()
                guard let press = self.press else { return }
                self.press = nil
                // The main Mac may still be settling this press, with no session
                // for the rule below to see.
                self.send?(.pressAbandoned)
                let action = Self.chordAction(
                    handsFree: self.effectiveHandsFree, attachedLocally: self.localSession != nil,
                    localSession: self.localSession?(), edgeId: self.edgeId,
                    baselineSessionId: press.baselineSessionId
                )
                switch action {
                case .cancel:
                    self.send?(.hotkeyCancel)
                case .release:
                    self.send?(.hotkeyUp(reason: .key))
                case .nothing:
                    break
                }
            }
        }
        hotkeyService.onVoiceCommandMode = { [weak self] in
            let appBundleId = self?.hotkeyService.commandAppBundleID
            Task { @MainActor in
                guard let self, !self.isTeachRecording else { return }
                self.pendingStart?.voiceCommand = true // replayed if the press falls back here
                self.pendingStart?.commandAppBundleID = appBundleId
                self.send?(.voiceCommandMode(appBundleId: appBundleId))
            }
        }
    }

    /// One key gesture that has been sent to the main Mac and not yet answered.
    /// Everything that can end the wait (the answer, the deadline, a failed
    /// send, key release, Esc, a lost connection) goes through this value, and
    /// a callback for any gesture other than the current one is ignored.
    struct PendingStart: Equatable {
        enum State: Equatable { case held, released, cancelled }
        let id: Int
        let message: EdgeMessage
        fileprivate(set) var state: State = .held
        /// Hands-free (tap, tap) or hold-to-talk: the mode this gesture started in.
        var handsFree: Bool { message == .hotkeyToggle }
        /// Voice launch was chosen (⇧ held) while the press was unanswered.
        fileprivate(set) var voiceCommand = false
        fileprivate(set) var commandAppBundleID: String? = nil

        fileprivate mutating func release() { if state == .held { state = .released } }
        fileprivate mutating func cancel() { state = .cancelled }
    }

    private(set) var pendingStart: PendingStart?
    /// After a fallback, the mode of the gesture being replayed here. It decides
    /// how the keys end that session, whatever this Mac's own setting says; the
    /// next gesture uses the setting again.
    private var replayedGestureHandsFree: (value: Bool, sawSession: Bool)?
    /// Hands-free as the keys should behave right now.
    private var effectiveHandsFree: Bool { replayedGestureHandsFree?.value ?? handsFree }
    private var nextPendingStartId = 0
    private var startAckTask: Task<Void, Never>?

    /// How long the main Mac has to answer a key press with its session state
    /// before this Mac gives up on it. A live main Mac answers in one round trip
    /// (tens of milliseconds on a tailnet, well under half a second via a
    /// relay), so 1.2 s leaves a wide margin yet tells the user almost at once
    /// when the link died just after the last pong. Starting a local capture at
    /// key-down instead isn't possible: the main Mac names the session and picks
    /// the microphone, so a second recording here could double up or be orphaned.
    var startAckTimeout: TimeInterval = 1.2
    /// Shown again if the new recording would otherwise hide it.
    private var pendingFallbackAlert: DictationAlert?

    /// Sends the key press that starts a dictation. If the main Mac has gone
    /// quiet (asleep, off the tailnet), the keepalive wouldn't notice for
    /// several more seconds and the press would vanish; instead say so now
    /// and record on this Mac, where the audio is kept on disk until it has
    /// been turned into text. A link that looked fine is double-checked: if
    /// the main Mac doesn't answer the press in time, the same fallback runs.
    func startDictation(_ message: EdgeMessage) {
        guard !isTeachRecording else {
            press = nil
            alerts.show(DictationAlert(title: "Another recording is in progress", detail: Self.microphoneBusyMessage))
            return
        }
        // A second hands-free tap while the first is unanswered means "stop".
        // Settled first: the link may have gone quiet between the two taps,
        // and that must not turn the stop into a new recording.
        // Only a still-held gesture is stopped by the tap; a cancelled or
        // released one is replaced by a fresh press below.
        if message == .hotkeyToggle, pendingStart?.state == .held {
            pendingStart?.release()
            send?(message)
            return
        }
        if phase == .idle, let isMainMacLive, !isMainMacLive() {
            clearPendingStart()
            fallBackToThisMac(message)
            return
        }
        guard phase == .idle, isMainMacLive != nil else {
            send?(message)
            return
        }
        // Armed before the send, so the send's failure callback can name it.
        clearPendingStart()
        nextPendingStartId += 1
        let gesture = PendingStart(id: nextPendingStartId, message: message)
        pendingStart = gesture
        refreshCancelEligible()
        send?(message)
        startAckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.startAckTimeout))
            guard !Task.isCancelled else { return }
            self.resolvePendingStart(id: gesture.id)
        }
    }

    /// Esc is live while a press is waiting for the main Mac (even after a
    /// hands-free tap has been released) and while a session is processing.
    private func refreshCancelEligible() {
        hotkeyService.cancelEligible = pendingStart != nil || phase == .processing
    }

    /// Whether a message from the main Mac drives a dictation session on this
    /// Mac (as opposed to settings, setup or housekeeping).
    static func isSessionMessage(_ message: CoreMessage) -> Bool {
        switch message {
        case .captureStart, .captureStop, .captureCancel, .insert, .voiceCommandInsert, .launchInsert,
             .sessionState, .level, .sessionCountdown, .error:
            return true
        default:
            return false
        }
    }

    /// Entry for every message that arrives over the network. Session messages
    /// count only while the main Mac is this Mac's active transport: after a
    /// fallback to local recording, a frame still queued from the old link must
    /// not restart capture or swap the checkpoint under the local recording.
    @discardableResult
    func handleRemote(_ message: CoreMessage) -> Bool {
        if Self.isSessionMessage(message), isMainMacLive == nil { return false }
        handle(message)
        return true
    }

    /// The main Mac answered (its session state or an error), so the press arrived.
    private func startAcknowledged() { clearPendingStart() }

    /// Ends the wait without doing anything; every exit from `pendingStart` ends here.
    private func clearPendingStart() {
        startAckTask?.cancel()
        startAckTask = nil
        pendingStart = nil
        refreshCancelEligible()
    }

    /// The wait failed (deadline, failed send, lost connection) for gesture
    /// `id`. Held: record on this Mac with the notice. Released: the press is
    /// over, so only say nothing was recorded. Cancelled: the user called it
    /// off, so nothing at all. A gesture that isn't the current one is ignored.
    private func resolvePendingStart(id: Int) {
        guard let gesture = pendingStart, gesture.id == id else { return }
        clearPendingStart()
        switch gesture.state {
        case .held: fallBackToThisMac(gesture.message, voiceCommand: gesture.voiceCommand, commandAppBundleID: gesture.commandAppBundleID)
        case .released: fallBackToThisMac(gesture.message, keyAlreadyReleased: true)
        case .cancelled: break
        }
    }

    /// The connection dropped after a start was sent but before the main Mac
    /// answered. Called once the local edge is attached, so a held press can
    /// be replayed here.
    func resolvePendingStartAfterDisconnect() {
        if let id = pendingStart?.id { resolvePendingStart(id: id) }
    }

    /// A send to the main Mac was refused or failed (the link dropped since
    /// the last check). `gesture` is the pending start current when the frame
    /// was sent. A lost start is resolved as above; a lost recording upload is
    /// explained by `remoteAudioSendFailed`.
    func remoteSendFailed(_ message: EdgeMessage, gesture: Int? = nil) {
        switch message {
        case .hotkeyDown, .hotkeyToggle:
            if let gesture { resolvePendingStart(id: gesture) }
        default:
            HotkeyService.recordDiagnostics("edge: a frame for the main Mac was not sent, link is down")
        }
    }

    /// The recording couldn't be handed to the main Mac. It stays on this
    /// Mac and can be turned into text from History & Privacy.
    func remoteAudioSendFailed() {
        alerts.show(Self.recordingKeptHereAlert)
    }

    private func fallBackToThisMac(_ message: EdgeMessage, keyAlreadyReleased: Bool = false, voiceCommand: Bool = false, commandAppBundleID: String? = nil) {
        HotkeyService.recordDiagnostics("edge: main Mac not answering, dictating on this Mac")
        onMainMacUnreachable?()
        if keyAlreadyReleased {
            // The key is already up, so there is nothing to record now.
            alerts.show(Self.cantReachMainMacMissedAlert)
            return
        }
        // The new recording's state would hide the alert; keep it for that moment.
        pendingFallbackAlert = Self.cantReachMainMacAlert
        replayedGestureHandsFree = (message == .hotkeyToggle, false)
        send?(message)
        if voiceCommand { send?(.voiceCommandMode(appBundleId: commandAppBundleID)) }
        if pendingFallbackAlert != nil { alerts.show(Self.cantReachMainMacAlert) }
    }

    static var cantReachMainMacAlert: DictationAlert {
        DictationAlert(
            title: BrandVoice.cantReach("your main Mac"),
            detail: "Recording on this Mac so nothing is lost.",
            tone: .notice
        )
    }

    static var cantReachMainMacMissedAlert: DictationAlert {
        DictationAlert(
            title: BrandVoice.cantReach("your main Mac"),
            detail: "That dictation wasn’t recorded. Try again; it will record on this Mac.",
            tone: .notice
        )
    }

    /// This Mac holds the recording, so it can offer the way to it.
    static let recordingKeptHereAlert = DictationAlert(
        title: "Lost the connection to your main Mac",
        detail: "Your recording is kept on this Mac. Open History & Privacy to turn it into text.",
        action: .history
    )

    /// Another Mac's microphone was used, so that Mac holds the recording.
    static func recordingKeptElsewhereAlert(macName: String?) -> DictationAlert {
        DictationAlert(
            title: "Lost the connection to your main Mac",
            detail: "Your recording is kept on \(macName ?? "the Mac whose microphone you used"). Open History & Privacy there to turn it into text."
        )
    }

    private func wireAudioLevel() {
        audioService.onLevel = { [weak self] level in
            guard let self else { return }
            if self.isTeachRecording { self.teachLevelObserver?(level) }
            // The indicator lives on the target (the Mac whose pointer the
            // user is on — see `SessionBroker.followPointerWithTarget`), so
            // the level meter is drawn here only while this Mac is it, and
            // relayed to the Core otherwise, which forwards it to the target.
            if self.isTarget {
                self.indicator.updateLevel(level)
            }
            if self.isMicOwner, !self.isTarget {
                self.sendLevelThrottled(level)
            }
        }
    }

    private func wireFocusClaim() {
        // Wired exactly as `FocusClaimDetector`'s header comment prescribes.
        let detector = focusClaimDetector
        hotkeyService.onFocusActivity = { [weak detector] in detector?.noteActivity($0) }
        detector.onClaim = { [weak self] bundleId in
            DispatchQueue.main.async { self?.send?(.focusClaim(appBundleId: bundleId)) }
        }
    }

    /// Unlike `wireFocusClaim`'s AX-probed, debounced path, pointer presence
    /// needs no probe and no queue hop — `HotkeyService` already throttles
    /// `mouseMoved` itself (`pointerPresenceThrottle`) and fires
    /// `leftMouseDown` immediately. Wrapped in `Task { @MainActor in }` like
    /// `wireHotkey`'s callbacks, since the tap callback isn't guaranteed to
    /// already be on the main actor. Internal (not private), mirroring
    /// `wireHotkey`, so `EdgeRuntimeTests` can drive
    /// `hotkeyService.onPointerPresence` directly without a live CGEvent tap.
    func wirePointerPresence() {
        hotkeyService.onPointerPresence = { [weak self] in
            Task { @MainActor in self?.send?(.pointerPresence) }
        }
        // This Mac's own screens: the moment the pointer lands on another
        // display, move a visible indicator there. Not routed through the
        // throttled presence heartbeat — that would make a same-Mac screen
        // change up to 0.5 s slower than a cross-Mac one.
        hotkeyService.onPointerDisplayChanged = { [weak self] in
            Task { @MainActor in
                guard let self, self.isTarget else { return }
                self.indicator.followPointer()
            }
        }
    }

    private func sendLevelThrottled(_ level: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelSendTime >= 0.1 else { return } // ≤10 Hz
        lastLevelSendTime = now
        send?(.level(rms: level))
    }

    // MARK: - Core → Edge messages

    func handle(_ message: CoreMessage) {
        switch message {
        case .welcome, .pong:
            break // handshake/keepalive noise; nothing for this runtime to do
        case .config(let handsFree):
            self.handsFree = handsFree
        case .captureStart(let sessionId):
            if captureOwner == .dictation(sessionId) { break } // replay must not reset the take
            guard captureOwner == nil, !audioService.isCaptureActive else {
                send?(.captureFailed(sessionId: sessionId, message: Self.microphoneBusyMessage))
                break
            }
            captureOwner = .dictation(sessionId)
            audioService.startCapture(sessionId: sessionId, edgeName: edgeName)
            if isInitiator {
                SoundService.playStart()
            }
            // The indicator itself is driven by the `sessionState` broadcast
            // (`handleSessionState`), on whichever Mac is the target — which
            // at this point is the initiator, and may move later.
        case .captureStop(let sessionId):
            handleCaptureStop(sessionId: sessionId)
        case .captureCancel(let sessionId):
            guard captureOwner == .dictation(sessionId) else { break }
            captureOwner = nil
            // `captureCancel` is sent to a mic owner that is not
            // the edge whose intent ended the session — e.g. the broker
            // sends it to the mic owner when the initiator disconnects
            // (`.cancelled(.initiatorLost)`, whose checkpoint must
            // survive). `cancelCapture()` would delete
            // the checkpoint outright before that outcome ever reaches this
            // machine. Finalize and keep the file instead — the by-outcome
            // cleanup in `handleSessionState`'s `applyCheckpointCleanup`
            // deletes it once the matching idle broadcast actually arrives
            // for `.cancelled(.user)`/`.cancelled(.noAudio)`, and simply
            // never arriving (a further connection loss) is exactly the
            // "keep" case already handled there.
            audioService.abandonCapture()
        case .insert(let sessionId, let text):
            handleInsert(sessionId: sessionId, text: text)
        case .voiceCommandInsert(let sessionId, let delivery):
            handleInsert(sessionId: sessionId, text: delivery.text, voiceCommand: delivery)
        case .launchInsert(let sessionId, let plan):
            handleInsert(sessionId: sessionId, text: plan.mainText, launch: plan)
        case .sessionState(let update):
            handleSessionState(update)
        case .level(let rms):
            indicator.updateLevel(rms)
        case .error(let code, let message):
            startAcknowledged()
            replayedGestureHandsFree = nil
            // A rejected press owns no session and must not cancel a later one.
            press = nil
            NSLog("[Edge] core error %@: %@", code, message)
            if code == "noMic" {
                let encoded = message.contains("\n")
                let alert = encoded ? DictationAlert.decode(failure: message) : .noMicrophone()
                micWarning = encoded ? alert.title : "None of your Macs has a microphone available."
                SoundService.playError()
                alerts.show(alert)
            } else if code == "sessionBusy" {
                var alert = DictationAlert.decode(failure: message)
                alert.tone = .notice
                alerts.show(alert)
            }
        case .repoResponse, .repoChanged:
            // Not part of the session flow this runtime drives —
            // `CoreConnection`/`DictatorViewModel` handle these directly.
            break
        case .sessionOutcomes(let outcomes):
            applySessionOutcomeReconciliation(outcomes)
        case .setup(let snapshot):
            applySetupSnapshot(snapshot)
        case .cleanupRequest(let requestId, let job):
            Task { @MainActor [weak self] in
                do {
                    let output = try await OllamaClient.chat(job)
                    self?.send?(.cleanupResult(requestId: requestId, output: output, error: nil))
                } catch {
                    self?.send?(.cleanupResult(requestId: requestId, output: nil, error: error.localizedDescription))
                }
            }
        case .pairCode, .pairApproved, .pairDenied:
            break // only sent to a Mac that's joining (`PairingClient`)
        case .pairingTokenRotated:
            break // persisted and acknowledged by CoreConnection
        case .speechRequest:
            break // arrives with its audio through `runSpeechJob`
        case .transcribeResult:
            break // answers a Teach request; `CoreConnection` completes it
        case .textCleanupResult:
            break // answers a Shortcuts clean-up request; `CoreConnection` completes it
        case .workspaceCapture(let requestId):
            Task { @MainActor [weak self] in
                guard let self else { return }
                let answer = await self.onWorkspaceCapture?() ?? (nil, nil, "Workspaces isn't ready on this Mac.")
                self.send?(.workspaceCaptureResult(requestId: requestId, macID: answer.macID, layout: answer.layout, error: answer.error))
            }
        case .workspaceRun(let requestId, let routineID, let undo, let from, let operationID):
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.onWorkspaceRun?(routineID, undo, from, operationID) ?? WorkspaceRunOutcome(summary: "Workspaces isn’t ready on this Mac.", failure: "Workspaces isn’t ready on this Mac.")
                self.send?(.workspaceRunResult(requestId: requestId, summary: outcome.summary, failure: outcome.failure, counts: outcome.counts))
            }
        case .workspaceRemembered, .workspaceRunReport:
            break // answers this Mac's own Workspace launch request; `CoreConnection` completes it
        case .sessionCountdown(let sessionId, let secondsLeft):
            startCountdown(sessionId: sessionId, secondsLeft: secondsLeft)
        case .modelPull(let requestId, let model):
            Task { @MainActor [weak self] in
                var lastSent = Date.distantPast
                let isSpeech = LocalSpeechService.engine(of: model) != nil
                do {
                    let stream = isSpeech ? LocalSpeechService.shared.install(model) : OllamaClient.pull(model)
                    for try await progress in stream {
                        // At most a few updates a second over the wire.
                        guard progress.done || Date().timeIntervalSince(lastSent) > 0.4 else { continue }
                        lastSent = Date()
                        self?.send?(.modelPullProgress(requestId: requestId, progress: progress))
                    }
                    await LocalModelInventory.shared.refresh()
                    self?.send?(.modelPullProgress(requestId: requestId, progress: ModelPullProgress(status: "success", done: true)))
                } catch {
                    self?.send?(.modelPullProgress(requestId: requestId, progress: ModelPullProgress(status: "failed", done: true, error: error.localizedDescription)))
                }
            }
        }
    }

    /// Reconciles this machine's `uploaded` recording checkpoints against
    /// outcomes the Core answered with — see
    /// `queryOutcomesForUploadedCheckpoints`. Only a definitively-safe
    /// outcome deletes the checkpoint; anything else (or simply not being
    /// in the Core's answer at all) leaves it exactly where
    /// `applyCheckpointCleanup` would have, had the idle broadcast actually
    /// reached this machine the first time.
    private func applySessionOutcomeReconciliation(_ outcomes: [SessionID: SessionOutcome]) {
        for (sessionId, outcome) in outcomes {
            switch outcome {
            case .pasted, .clipboardOnly, .empty:
                audioService.deleteCheckpoint(takeId: RecordingCheckpointStore.edgeTakeId(sessionId))
            case .cancelled(.user):
                audioService.deleteCheckpoint(takeId: RecordingCheckpointStore.edgeTakeId(sessionId))
            case .cancelled, .failed:
                break // kept — see RecoveryService
            }
        }
    }

    /// Called on (re)connect to a Core (`DictatorViewModel`'s
    /// `openEdgeConnection`'s `connection.onConnected`) — if this machine
    /// has any checkpoint still marked `.uploaded` (handed off, but this
    /// Edge never learned what happened to it — e.g. by
    /// disconnecting right after the upload, before the idle
    /// broadcast arrives), ask the Core what it remembers. A checkpoint
    /// this machine already knows the outcome of (recording/interrupted/
    /// failed/received — the last two never apply on the Edge side) has
    /// nothing to ask about.
    func queryOutcomesForUploadedCheckpoints() {
        let sessionIds = audioService.checkpointStore.listTakes()
            .filter { $0.metadata.status == .uploaded }
            .map { $0.metadata.sessionId }
        guard !sessionIds.isEmpty else { return }
        send?(.sessionOutcomeQuery(sessionIds: sessionIds))
    }

    private func handleCaptureStop(sessionId: SessionID) {
        guard captureOwner == .dictation(sessionId) else {
            send?(.captureFailed(sessionId: sessionId, message: "This Mac wasn’t recording that dictation. Please try again."))
            return
        }
        captureOwner = nil
        releaseTimes = releaseTimes.filter { Date().timeIntervalSince($0.value) < 600 }
        releaseTimes[sessionId] = Date()
        guard let captured = audioService.stopCapture() else {
            // Mirrors today's single-machine "stopCapture returned nil" path:
            // an empty take the broker turns into `.cancelled(.noAudio)`.
            NSLog("[Dictation] stopCapture returned nil — no audio buffers received (mic permission?)")
            sendAudio?(
                AudioTakeHeader(
                    sessionId: sessionId,
                    sampleRate: Int(AudioCaptureService.targetSampleRate),
                    frameCount: 0,
                    durationSeconds: 0,
                    byteCount: 0
                ),
                Data()
            )
            return
        }
        let header = AudioTakeHeader(
            sessionId: sessionId,
            sampleRate: captured.sampleRate,
            frameCount: captured.frameCount,
            durationSeconds: captured.durationSeconds,
            byteCount: captured.data.count
        )
        sendAudio?(header, captured.data)
    }

    /// Pastes, resolves the destination, reports the outcome back to the
    /// Core, and drives the local sounds/warnings.
    ///
    /// Gated on this runtime's own view of the session: an `insert` that
    /// doesn't match the session and target this machine believes it's
    /// inserting for — a stale/replay frame, or an unsolicited one from a
    /// Core this Edge never agreed to paste for — is rejected with
    /// `.failed`, which ends the Core's session instead of leaving it
    /// hanging (and instead of this machine executing its Accessibility
    /// paste authority on an unverified command).
    private func handleInsert(sessionId: SessionID, text: String, voiceCommand: VoiceCommandDelivery? = nil, launch: VoiceLaunchPlan? = nil) {
        guard let state = lastSessionState,
              state.sessionId == sessionId,
              state.target == edgeId,
              phase == .inserting else {
            NSLog("[Edge] insert for session %@ rejected: no matching inserting session/target", sessionId)
            send?(.insertResult(
                sessionId: sessionId,
                outcome: .failed(message: "This Mac got text for a dictation it wasn’t running, so it didn’t type it."),
                destination: nil
            ))
            return
        }
        if let miss = voiceCommand?.nearMiss, miss.kind == .entry {
            // A name wasn't recognized: nothing is typed. The words wait on
            // the clipboard while the user says who they meant.
            PasteService.copyToClipboard(text)
            lastTranscription = text
            releaseTimes.removeValue(forKey: sessionId)
            SoundService.playError()
            showNearMiss(miss)
            send?(.insertResult(sessionId: sessionId,
                                outcome: .clipboardOnly(reason: "Your words are on the clipboard while you choose who you meant.", needsAccessibility: false),
                                destination: nil))
            return
        }
        if launch == nil, let notice = voiceCommand?.notice {
            // A shortcut-mode miss never types into whichever app has focus.
            (voiceLaunchServices ?? .live).setClipboard(text)
            lastTranscription = text
            releaseTimes.removeValue(forKey: sessionId)
            var alert = DictationAlert.decode(failure: notice)
            alert.tone = .notice
            if let miss = voiceCommand?.nearMiss {
                showNearMiss(miss)
                send?(.insertResult(sessionId: sessionId,
                                    outcome: .clipboardOnly(reason: alert.detail, needsAccessibility: false), destination: nil))
            } else {
                // The idle outcome shows the full notice on the dictating Mac,
                // even when another Mac received the plan. Keep its recording.
                send?(.insertResult(sessionId: sessionId, outcome: .failed(message: alert.encoded), destination: nil))
            }
            return
        }
        if let launch {
            let releasedAt = releaseTimes[sessionId]
            Task { await runLaunch(launch, releasedAt: releasedAt, sessionId: sessionId, text: text) }
            return
        }
        Task { await pasteAndReport(sessionId: sessionId, text: text, voiceCommand: voiceCommand) }
    }

    /// Runs a voice launch plan the Core resolved and reports how it ended.
    private func runLaunch(_ launch: VoiceLaunchPlan, releasedAt: Date?, sessionId: SessionID, text: String) async {
        launchProgress.begin(launch)
        let result = await VoiceLaunchExecutor.run(launch, releasedAt: releasedAt, services: voiceLaunchServices) { [launchProgress] event in
            launchProgress.apply(event)
        }
        launchProgress.end()
        let outcome: SessionOutcome
        switch result {
        case .done:
            SoundService.playSuccess()
            insertionWarning = nil
            outcome = .pasted
        case .cancelled(let alert):
            alerts.show(alert)
            insertionWarning = alert.detail
            outcome = .clipboardOnly(reason: alert.detail, needsAccessibility: false)
        case .stopped(let alert):
            insertionWarning = alert.detail
            // SessionBroker relays this to the initiator; only that Mac
            // shows the failure and the microphone owner keeps the take.
            outcome = .failed(message: alert.encoded)
        }
        lastTranscription = text
        releaseTimes.removeValue(forKey: sessionId)
        send?(.insertResult(sessionId: sessionId, outcome: outcome, destination: nil))
    }

    /// Pastes the words into the focused app and reports where they went.
    private func pasteAndReport(sessionId: SessionID, text: String, voiceCommand: VoiceCommandDelivery?) async {
        // The destination probe only feeds the history record, so it
        // runs alongside the paste instead of in front of it: its
        // AppleScript leg (`tell application … get URL/tty`) has been
        // seen stalling to its full timeout in the field
        // (`destination-probe TIMEOUT executable=/usr/bin/osascript`),
        // so it must not delay the text landing. Both read the
        // frontmost app; the paste doesn't change it.
        async let destinationProbe = DestinationSnapshot.resolved(insertionMethod: "paste")
        let pasteOutcome = await Task.detached { PasteService.paste(text, joiningPrecedingText: true) }.value
        let landedMs = releaseTimes.removeValue(forKey: sessionId).map { Int(Date().timeIntervalSince($0) * 1000) }
        let destination = await destinationProbe
        if case .pasted = pasteOutcome, let context = destination.context {
            onInsertedForLearning?(sessionId, text, context)
        }

        lastTranscription = text
        let insertDestination = InsertDestination(
            bundleId: destination.appBundleId,
            appName: destination.appName,
            url: destination.url,
            insertionMethod: destination.insertionMethod,
            toolId: destination.context?.toolID,
            remoteHost: destination.context?.remoteHost,
            surfaceLabel: destination.context?.label(),
            workingDirectory: destination.context?.workingDirectory,
            webHost: destination.context?.webHost,
            releaseToInsertMs: landedMs.flatMap { (0...300_000).contains($0) ? $0 : nil }
        )

        let outcome: SessionOutcome
        if case .clipboardOnly(let reason, let needsAccessibility) = pasteOutcome {
            SoundService.playError()
            alerts.show(.clipboardOnly(reason: reason, needsAccessibility: needsAccessibility))
            insertionWarning = reason
            self.needsAccessibility = needsAccessibility
            outcome = .clipboardOnly(reason: reason, needsAccessibility: needsAccessibility)
        } else {
            SoundService.playSuccess()
            insertionWarning = nil
            self.needsAccessibility = false
            outcome = .pasted
            // Shortcut mode, but no shortcut matched: the words went in
            // as usual, and the user is told why nothing opened.
            if let notice = voiceCommand?.notice {
                var alert = DictationAlert.decode(failure: notice)
                alert.tone = .notice
                if let miss = voiceCommand?.nearMiss {
                    showNearMiss(miss)
                } else {
                    alerts.show(alert)
                }
            } else if let moment = BrandVoice.takeFirstDictationMoment() {
                alerts.show(moment)
            }
        }
        send?(.insertResult(sessionId: sessionId, outcome: outcome, destination: insertDestination))
    }

    /// The interactive notice for a near miss. Choosing a name (or another
    /// way to start a shortcut) saves it in the shared voice launch setting;
    /// for a name, the shortcut then runs with the same words.
    private func showNearMiss(_ miss: VoiceNearMiss) {
        HotkeyService.recordDiagnostics("voicelaunch: near-miss notice shown (\(miss.kind.rawValue))")
        nearMissNotice.show(
            miss,
            onEntry: { [weak self] span, entryId in self?.applyEntryFix(miss, span: span, entryId: entryId) },
            onVoiceCommand: { [weak self] commandId in self?.applyTriggerFix(miss, commandId: commandId) })
    }

    /// Returns a plain reason when the choice can't be saved.
    private func applyEntryFix(_ miss: VoiceNearMiss, span: Int, entryId: String) -> String? {
        let settings = AppSettings.shared
        switch VoiceNearMissFix.fixEntry(miss, span: span, entryId: entryId, in: settings.voiceLaunch) {
        case .failure(let problem):
            return problem.message
        case .success(let fix):
            settings.updateVoiceLaunch { $0 = fix.config }
            nearMissNotice.hide()
            guard case .plan(let plan) = fix.result else {
                alerts.show(DictationAlert(title: "Saved, but nothing ran",
                                           detail: "Those words still don’t fit a command. Your words are still on the clipboard.", tone: .notice))
                return nil
            }
            Task {
                launchProgress.begin(plan)
                let result = await VoiceLaunchExecutor.run(plan) { [launchProgress] event in launchProgress.apply(event) }
                launchProgress.end()
                switch result {
                case .done: SoundService.playSuccess()
                case .cancelled(let alert): alerts.show(alert)
                case .stopped(let alert): SoundService.playError(); alerts.show(alert)
                }
            }
            return nil
        }
    }

    private func applyTriggerFix(_ miss: VoiceNearMiss, commandId: String) -> String? {
        let settings = AppSettings.shared
        switch VoiceNearMissFix.fixTrigger(miss, commandId: commandId, in: settings.voiceLaunch) {
        case .failure(let problem): return problem.message
        case .success(let config):
            settings.updateVoiceLaunch { $0 = config }
            nearMissNotice.hide()
            alerts.show(DictationAlert(title: "Saved", detail: "Next time, “\(miss.heard)” will start that command.", tone: .notice))
            return nil
        }
    }

    // MARK: - "Recording is about to end" countdown

    private var countdownTask: Task<Void, Never>?
    private var countdownSessionId: SessionID?

    /// Counts down the last seconds before the Core's time limit stops the
    /// recording: a quiet tick as it starts and on each of the last three
    /// seconds, and "Stopping in N…" on the badge when this Mac shows it.
    /// The Core only says when it starts; a `sessionState` that is not this
    /// recording clears it (`handleSessionState`).
    private func startCountdown(sessionId: SessionID, secondsLeft: Int) {
        guard phase == .recording, lastSessionState?.sessionId == sessionId,
              isTarget || isInitiator, secondsLeft > 0 else { return }
        stopCountdown()
        countdownSessionId = sessionId
        countdownTask = Task { @MainActor [weak self] in
            var n = secondsLeft
            let first = n
            while n > 0, !Task.isCancelled {
                guard let self else { return }
                if self.isTarget { self.indicator.setCountdown(n) }
                if (n == first || n <= 3), self.isTarget || self.isInitiator { SoundService.playTick() }
                try? await Task.sleep(for: .seconds(1))
                n -= 1
            }
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownSessionId = nil
        indicator.setCountdown(nil)
    }

    private var recordingLimitNoticeSession: SessionID?

    private func handleSessionState(_ update: SessionStateUpdate) {
        if countdownTask != nil, update.state != .recording || update.sessionId != countdownSessionId {
            stopCountdown()
        }
        startAcknowledged()
        if update.state != .idle { replayedGestureHandsFree?.sawSession = true }
        else if replayedGestureHandsFree?.sawSession == true { replayedGestureHandsFree = nil }
        if update.state == .idle { pendingFallbackAlert = nil }
        if update.state == .recording, lastSessionState?.sessionId != update.sessionId { onNextDictationForLearning?() }
        lastSessionState = update
        phase = update.state
        isInitiator = update.initiator == edgeId
        isMicOwner = update.micOwner == edgeId
        if isInitiator, update.recordingLimitReached == true,
           recordingLimitNoticeSession != update.sessionId {
            recordingLimitNoticeSession = update.sessionId
            alerts.show(.recordingLimitReached)
        }
        let wasTarget = isTarget
        isTarget = update.target == edgeId
        // Keep Esc live on every machine while a session is processing (a
        // cancel can arrive from any edge — see `SessionBroker`), so an
        // in-flight transcription can still be aborted after key-up.
        refreshCancelEligible()

        // This runs for every connected edge (the broadcast isn't
        // initiator-only), gated on `isMicOwner` since only the machine that
        // actually holds the checkpoint file has anything to clean up —
        // covers cross-machine (mic owner ≠ initiator) and standalone alike.
        if update.state == .idle, let outcome = update.outcome, isMicOwner {
            applyCheckpointCleanup(sessionId: update.sessionId, outcome: outcome)
        }

        // The idle outcome (error banner, clipboard warning) still belongs
        // to the initiator — it's the Mac the user pressed the key on.
        if update.state == .idle, isInitiator, let outcome = update.outcome {
            applyIdleOutcome(outcome)
        }

        // The indicator follows `target`, which the Core moves with the
        // pointer during recording/processing (`SessionBroker.
        // followPointerWithTarget`): a Mac that just stopped being the
        // target hides it, the one that just became it shows it in the
        // phase-appropriate style. `show()`/`showProcessing()` are cheap
        // to repeat, so a same-target phase change simply re-applies.
        if wasTarget, !isTarget {
            indicator.hide()
        }
        if update.state == .recording, isInitiator {
            if let notice = pendingFallbackAlert { alerts.show(notice) } else { alerts.hide() }
        }
        guard isTarget else { return }
        switch update.state {
        case .recording:
            indicator.show(voiceLaunch: update.voiceCommandMode == true)
        case .processing, .inserting:
            indicator.showProcessing() // stays up through inserting
        case .idle:
            indicator.hide()
        }
    }

    /// Deletes this machine's recording checkpoint for `sessionId` once the
    /// outcome says the audio either safely made it into history/clipboard,
    /// or was legitimately abandoned by the user — kept on disk (for the
    /// recovery UI) for anything that might still be worth another try.
    private func applyCheckpointCleanup(sessionId: SessionID, outcome: SessionOutcome) {
        // Routed through `AudioCaptureService.deleteCheckpoint`
        // (the same serial `checkpointQueue` `finish()`/`discard()` run on)
        // rather than calling `checkpointStore.delete` directly here on the
        // main actor — see that method's doc for the race it closes.
        switch outcome {
        case .pasted, .clipboardOnly, .empty:
            audioService.deleteCheckpoint(takeId: RecordingCheckpointStore.edgeTakeId(sessionId))
        case .cancelled(let reason):
            switch reason {
            case .user, .noAudio:
                audioService.deleteCheckpoint(takeId: RecordingCheckpointStore.edgeTakeId(sessionId))
            case .micLost, .initiatorLost, .targetLost, .watchdog:
                break // kept — see RecoveryService
            }
        case .failed:
            break // kept — see RecoveryService
        }
    }

    /// Tells the user on screen when a dictation they started didn't
    /// produce text (`.pasted`/`.clipboardOnly` were already reported by
    /// the Mac that inserted, in `handleInsert`).
    private func applyIdleOutcome(_ outcome: SessionOutcome) {
        switch outcome {
        case .failed(let message):
            SoundService.playError()
            let alert = DictationAlert.decode(failure: message)
            alerts.show(alert)
            errorMessage = alert.title
            scheduleErrorClear(matching: alert.title)
        case .cancelled(let reason):
            guard let alert = DictationAlert.cancelled(reason) else { return }
            SoundService.playError()
            alerts.show(alert)
        case .empty:
            alerts.show(.nothingHeard)
        case .pasted, .clipboardOnly:
            break
        }
    }

    /// Auto-clears after 3s — but only if nothing newer has already replaced
    /// this message.
    private func scheduleErrorClear(matching message: String) {
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.errorMessage == message else { return }
            self.errorMessage = nil
        }
    }

    // MARK: - Runtime health (mic + hotkey)

    @discardableResult
    private func startAudioEngine() -> Bool {
        let started: Bool
        do {
            try audioService.startEngine(deviceUID: AppSettings.shared.audioInputDeviceUID)
            audioRetry.reset()
            runtimeFailures.remove(.audio)
            micAvailable = true
            micWarning = nil
            micBlockingMessage = nil
            recomputeHealth()
            started = true
        } catch {
            // A missing/unusable microphone device on this machine is
            // always non-blocking: another Edge (or the Core) can supply
            // one. Surface it as a warning and still let the hotkey fire
            // — the broker either uses the chosen Mac or answers
            // `noMic`. This is distinct from a denied/restricted
            // *permission*, handled below.
            runtimeFailures.insert(.audio)
            micAvailable = false
            micWarning = Self.microphoneProblemText(for: error)
            audioRetry.recordFailure(at: now())
            HotkeyService.recordDiagnostics("audio start failed error=\(error.localizedDescription)")
            started = false
        }
        notifyCapabilitiesChangedIfNeeded()
        return started
    }

    private func refreshMicrophoneAccess() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            startAudioEngine()
        case .notDetermined:
            if promptsForPermissions {
                requestMicrophoneAccess()
            } else {
                // Not asked yet: the welcome explains why before asking.
                runtimeFailures.insert(.audio)
                micAvailable = false
                micWarning = "Dictator hasn’t been allowed to use the microphone yet."
                notifyCapabilitiesChangedIfNeeded()
            }
        default:
            applyMicPermissionDenied()
        }
    }

    /// Denied/restricted mic permission: always a non-blocking `micWarning`,
    /// and — only in `.standalone`, where nothing else could ever supply a
    /// mic — also a blocking `health`.
    private func applyMicPermissionDenied() {
        runtimeFailures.insert(.audio)
        micAvailable = false
        micWarning = "Dictator isn’t allowed to use the microphone."
        refreshMicBlockingForRole()
        notifyCapabilitiesChangedIfNeeded()
    }

    private func refreshHotkeyAccess() {
        do {
            try hotkeyService.start()
            runtimeFailures.remove(.hotkey)
            hotkeyFailureMessage = nil
        } catch {
            // The hotkey tap stays blocking in every role: with no tap,
            // nothing on this machine works at all.
            runtimeFailures.insert(.hotkey)
            hotkeyFailureMessage = error.localizedDescription
        }
        recomputeHealth()
        notifyCapabilitiesChangedIfNeeded()
    }

    private func startRuntimeHealthMonitor() {
        runtimeHealthTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recoverRuntimeIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        runtimeHealthTimer = timer
    }

    private func recoverRuntimeIfNeeded() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .authorized {
            if audioRetry.shouldAttempt(at: now()) {
                recoverAudio()
            }
        } else if micStatus != .notDetermined {
            applyMicPermissionDenied()
        }

        do {
            if try hotkeyService.ensureHealthy() {
                NSLog("[Edge] hotkey listener recovered")
            }
            runtimeFailures.remove(.hotkey)
            hotkeyFailureMessage = nil
        } catch {
            runtimeFailures.insert(.hotkey)
            hotkeyFailureMessage = error.localizedDescription
        }
        recomputeHealth()
        notifyCapabilitiesChangedIfNeeded()

        onHealthTick?()
    }

    private func recoverAudio() {
        do {
            if try audioService.ensureRunning(deviceUID: AppSettings.shared.audioInputDeviceUID) {
                NSLog("[Edge] audio engine recovered")
                HotkeyService.recordDiagnostics("audio recovered after \(audioRetry.failures) failed attempts")
            }
            audioRetry.reset()
            runtimeFailures.remove(.audio)
            micAvailable = true
            micWarning = nil
            micBlockingMessage = nil
            recomputeHealth()
        } catch {
            audioRetry.recordFailure(at: now())
            HotkeyService.recordDiagnostics(
                "audio restart failed attempt=\(audioRetry.failures) "
                + "nextInSeconds=\(Int(audioRetry.currentDelay)) error=\(error.localizedDescription)"
            )
            runtimeFailures.insert(.audio)
            micAvailable = false
            micWarning = Self.microphoneProblemText(for: error)
            recomputeHealth()
        }
    }

    // MARK: - Identity

    private static func loadOrCreateEdgeID() -> EdgeID {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "edgeId"), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: "edgeId")
        return created
    }
}

// MARK: - LocalEdgeChannel

extension EdgeRuntime: LocalEdgeChannel {
    /// `CoreHost`'s local-edge effect delivery lands here — see
    /// `LocalEdgeChannel` in `CoreHost.swift`.
    func deliver(_ message: CoreMessage) {
        handle(message)
    }
}

/// Spacing between repeated recovery attempts: `base` after the first
/// failure, doubling up to `ceiling`, then staying there. A success or an
/// explicit reset makes the next attempt immediate again.
struct RetryBackoff: Equatable {
    var base: TimeInterval = 5
    var ceiling: TimeInterval = 300
    private(set) var failures = 0
    private(set) var nextAttempt: Date?

    /// The wait after the most recent failure (0 before any failure).
    var currentDelay: TimeInterval {
        guard failures > 0 else { return 0 }
        return min(ceiling, base * pow(2, Double(min(failures - 1, 30))))
    }

    func shouldAttempt(at now: Date) -> Bool {
        guard let nextAttempt else { return true }
        return now >= nextAttempt
    }

    mutating func recordFailure(at now: Date) {
        failures += 1
        nextAttempt = now.addingTimeInterval(currentDelay)
    }

    mutating func reset() {
        failures = 0
        nextAttempt = nil
    }
}
