import Foundation

// Edge ↔ Core wire protocol, v1.
//
// One WebSocket per Edge, Edge connects to Core. Every message is a JSON text
// frame shaped `{"v":1,"t":"<type>","id":"<uuid>", ...payload}`. Audio travels
// as one binary frame that immediately follows an `audio.take` header frame
// (the header carries the byte count so the receiver can pair them). All
// types live here so both ends compile the same definitions and the codec
// round-trips are covered by EdgeProtocolTests.

/// Stable per-install identity of an Edge (a UUID string, generated once and
/// kept in UserDefaults). The Core keys its edge registry by it.
typealias EdgeID = String

typealias SessionID = String

enum EdgeProtocol {
    /// v2: local-first replication (`historyManifest`/`historyFetch`/
    /// `historyUpsert`, `HistoryRecordDTO` off the wire, surface policy in
    /// `CoreSettingsDTO`). A v1 peer is refused at `welcome`.
    static let version = 2
    static let maxTextFrameBytes = 256 * 1_024
    /// 120 s at 16 kHz float32 is 7.7 MB; leave headroom.
    static let maxBinaryFrameBytes = 16 * 1_024 * 1_024
    static let maxEdges = 8
    /// A connection that has not sent `hello` within this window is dropped.
    static let helloTimeout: TimeInterval = 2
    /// Edge → Core keepalive interval; piggy-backs on the 5 s runtime-health timer.
    static let pingInterval: TimeInterval = 5
    /// Core → Edge liveness: an authenticated Edge that has sent nothing
    /// (not even a ping) for this long is dropped, so a machine that went
    /// to sleep or lost its network never lingers as a "connected" ghost
    /// (and its reconnect is never confused with a duplicate).
    static let edgeIdleTimeout: TimeInterval = 30
    /// Longest hold before the Core force-stops capture (the server rejects
    /// longer audio anyway).
    static let maxSessionDuration: TimeInterval = 120
    /// How long before `maxSessionDuration` the Core warns the Macs showing
    /// the dictation (`CoreMessage.sessionCountdown`).
    static let countdownLead: TimeInterval = 10
    /// Core listener port. 7878 is the speech server.
    static let corePort: UInt16 = 7880
}

// MARK: - Shared payload types

struct EdgeCapabilities: Codable, Equatable {
    var hasMic: Bool
    var inputDeviceUID: String
    var accessibility: Bool
    var inputMonitoring: Bool
    /// `HotkeyService.Mode.rawValue` (intercept / listenOnly / nseventGlobal / none).
    var hotkeyMode: String
    /// What kind of Mac this is and how much memory it has (Settings ›
    /// Your Macs). Optional, so an older peer simply omits it.
    var machine: MachineProfile? = nil
    /// Models Ollama has installed on this Mac. Optional, as above.
    var localModels: [String]? = nil
    /// Speech-to-text models installed in Dictator on this Mac
    /// (`LocalSpeechService` ids). Optional, as above.
    var speechModels: [String]? = nil
    /// This Mac can run Apple's speech recognition (macOS 26+).
    var appleSpeech: Bool? = nil
    /// Actual local login registration; nil for older peers.
    var startup: StartupReport? = nil
}

/// A recording the Core asks another Mac to turn into text with one of
/// its speech models; exactly one binary frame of `byteCount` bytes
/// (float32 LE PCM) follows the `speech.request` frame.
struct SpeechJob: Codable, Equatable {
    var requestId: String
    var model: String
    var languages: [String]
    var vocabulary: [String]
    var sampleRate: Int
    var byteCount: Int
}

enum HotkeyUpReason: String, Codable, Equatable {
    case key
    case modifierWatchdog
    case listenerLoss
}

enum SessionPhase: String, Codable, Equatable {
    case idle
    case recording
    case processing
    case inserting
}

enum CancelReason: String, Codable, Equatable {
    case user
    case micLost
    case initiatorLost
    case targetLost
    case watchdog
    case noAudio
}

/// Mirrors `PasteService.Outcome` plus the ways a session can end without an
/// insertion. Encoded flat: `{"kind":"clipboardOnly","reason":"…","needsAccessibility":true}`.
enum SessionOutcome: Codable, Equatable {
    case pasted
    case clipboardOnly(reason: String, needsAccessibility: Bool)
    case cancelled(CancelReason)
    case failed(message: String)
    case empty

    private enum CodingKeys: String, CodingKey {
        case kind, reason, needsAccessibility, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "pasted":
            self = .pasted
        case "clipboardOnly":
            self = .clipboardOnly(
                reason: try container.decode(String.self, forKey: .reason),
                needsAccessibility: try container.decodeIfPresent(Bool.self, forKey: .needsAccessibility) ?? false
            )
        case "cancelled":
            self = .cancelled(try container.decode(CancelReason.self, forKey: .reason))
        case "failed":
            self = .failed(message: try container.decode(String.self, forKey: .message))
        case "empty":
            self = .empty
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown outcome kind \(other)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pasted:
            try container.encode("pasted", forKey: .kind)
        case .clipboardOnly(let reason, let needsAccessibility):
            try container.encode("clipboardOnly", forKey: .kind)
            try container.encode(reason, forKey: .reason)
            try container.encode(needsAccessibility, forKey: .needsAccessibility)
        case .cancelled(let reason):
            try container.encode("cancelled", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .failed(let message):
            try container.encode("failed", forKey: .kind)
            try container.encode(message, forKey: .message)
        case .empty:
            try container.encode("empty", forKey: .kind)
        }
    }
}

/// What the target Edge saw when it inserted — recorded into history by the Core.
struct InsertDestination: Codable, Equatable {
    var bundleId: String?
    var appName: String?
    var url: String?
    var insertionMethod: String
    /// Prompt attribution resolved on the Edge that pasted (which AI tool,
    /// which remote machine). Optional, so an older peer simply omits it.
    var toolId: String? = nil
    var remoteHost: String? = nil
    var surfaceLabel: String? = nil
    var workingDirectory: String? = nil
    var webHost: String? = nil
    /// Hotkey release to the text landing, measured on the Edge that
    /// pasted. Optional, so an older peer omits it.
    var releaseToInsertMs: Int? = nil
}

/// Header frame that precedes the single binary audio frame.
struct AudioTakeHeader: Codable, Equatable {
    var sessionId: SessionID
    /// Always 16000 today (`CapturedAudio.sampleRate`).
    var sampleRate: Int
    var frameCount: Int
    var durationSeconds: Double
    /// Byte length of the binary frame that follows (float32 LE PCM).
    var byteCount: Int
}

struct SessionStateUpdate: Codable, Equatable {
    var sessionId: SessionID
    var state: SessionPhase
    var initiator: EdgeID
    var micOwner: EdgeID?
    var target: EdgeID?
    var outcome: SessionOutcome?
    /// True once the Core has this recording in voice launch mode, so the
    /// Mac showing the indicator can say so, whichever Mac has the keyboard.
    /// Optional on the wire: an older Core never sends it.
    var voiceCommandMode: Bool? = nil
    /// Capture reached its time limit; transcription and insertion continue.
    /// Missing on older peers. The initiator shows one notice per session.
    var recordingLimitReached: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case sessionId, state, initiator, micOwner, target, outcome, recordingLimitReached
        case voiceCommandMode = "shortcutMode"
    }

}

// MARK: - Edge → Core

enum EdgeMessage: Equatable {
    case hello(edgeId: EdgeID, name: String, token: String, caps: EdgeCapabilities)
    /// Sent whenever the Edge's capabilities change after hello (a mic
    /// appearing or failing, a TCC grant landing) so the Core's mic-owner
    /// choice never relies on a stale snapshot.
    case capabilities(EdgeCapabilities)
    case ping
    case hotkeyDown
    case hotkeyUp(reason: HotkeyUpReason)
    /// Hands-free mode: the user tapped the hotkey. The Core decides whether
    /// that starts or stops a session (every Mac sharing a keyboard sees the
    /// same tap, so the decision must not be made on the Edge).
    case hotkeyToggle
    case hotkeyCancel
    /// The user is dictating in shortcut mode (Right Shift held with Right ⌥),
    /// sent right after `hotkeyDown`/`hotkeyToggle` or when Right Shift joins
    /// the hold. A new message type, so an older Core ignores it.
    case voiceCommandMode(appBundleId: String? = nil)
    /// The press turned out to be a typed character. Unlike `hotkeyCancel` this
    /// can only drop a press still settling, never a recording already running.
    case pressAbandoned
    case focusClaim(appBundleId: String?)
    /// A throttled heartbeat sent while this Edge's pointer is present —
    /// `mouseMoved` (rate-limited) or `leftMouseDown` (immediate). Unlike
    /// `focusClaim`, Universal Control never duplicates the events this is
    /// derived from: only the Mac that currently owns the on-screen pointer
    /// ever receives `mouseMoved`/`leftMouseDown` from its own tap (a
    /// keyDown, by contrast, can be seen by both Macs' taps — see
    /// `FocusClaimRegistry`). That makes this the one unambiguous "the user
    /// is on this Mac" signal, and the Core lets it dominate a
    /// keystroke-derived `focusClaim` when resolving the initiator or the
    /// insertion target.
    case pointerPresence
    case level(rms: Float)
    /// Followed by exactly one binary frame of `header.byteCount` bytes.
    case audioTake(AudioTakeHeader)
    /// This session could not acquire or retain this Mac's microphone.
    /// New message type: older peers ignore it without a protocol break.
    case captureFailed(sessionId: SessionID, message: String)
    case insertResult(sessionId: SessionID, outcome: SessionOutcome, destination: InsertDestination?)
    /// History/dictionary/settings access against whichever machine's
    /// SwiftData store is authoritative. `id` correlates the eventual
    /// `CoreMessage.repoResponse`; it's a payload field of its own (wire key
    /// `requestId`) because the envelope already has an unrelated `id`.
    case repoRequest(id: String, request: RepoRequest)
    /// Asks the Core whether any of these sessions (this Edge's own `uploaded`
    /// recording checkpoints — see
    /// `EdgeRuntime.queryOutcomesForUploadedCheckpoints`) reached a terminal
    /// outcome that this Edge missed because it disconnected right after handing
    /// off the audio frame. Answered with `CoreMessage.sessionOutcomes`.
    case sessionOutcomeQuery(sessionIds: [SessionID])
    /// Answer to `CoreMessage.cleanupRequest`: the model's output, or why
    /// it couldn't run.
    case cleanupResult(requestId: String, output: String?, error: String?)
    /// Progress of a `CoreMessage.modelPull` on this Mac.
    case modelPullProgress(requestId: String, progress: ModelPullProgress)
    /// First frame from a Mac that wants to join and has no token yet —
    /// only accepted while the Core is taking new Macs (Add a Mac is open).
    /// Answered with `CoreMessage.pairCode`, then `pairApproved` once the
    /// user confirms the code on the Core, or `pairDenied`.
    case pairRequest(edgeId: EdgeID, name: String, caps: EdgeCapabilities)
    /// Saved the replacement credential; never echoes the secret.
    case pairingTokenSaved(rotationId: String)
    /// Answer to `CoreMessage.speechRequest`.
    case speechResult(requestId: String, text: String?, error: String?)
    /// Teach: asks the Core to turn the recording in the one binary frame
    /// that follows (`header.byteCount` bytes, float32 LE PCM) into the
    /// words as spoken, through the same speech path dictation uses (its
    /// speech sources in order, the same hints), with no clean-up, no paste
    /// and no history; the audio is dropped afterwards. Answered with
    /// `CoreMessage.transcribeResult`. `header.sessionId` carries nothing
    /// but a label. A new message type, so an older Core ignores it.
    case transcribeRequest(requestId: String, header: AudioTakeHeader)
    /// Shortcuts (Dictate, Clean up text): asks the Core to apply the
    /// dictionary's replacements to `text` and, when `useAI` is true, to
    /// clean it up with the clean-up model chosen in Your Macs. Answered with
    /// `CoreMessage.textCleanupResult`. Nothing is saved. A new message
    /// type, so an older Core ignores it.
    case textCleanupRequest(requestId: String, text: String, useAI: Bool)
    /// Workspace launch: asks the Core to have every connected Mac (this one
    /// included) remember where its windows are. Answered with
    /// `CoreMessage.workspaceRemembered`. A new message type, so an older
    /// Core ignores it.
    case workspaceRememberAll(requestId: String)
    /// Answer to `CoreMessage.workspaceCapture`: this Mac's layout keyed by
    /// its `WorkspaceMacIdentity`, or why there is none.
    case workspaceCaptureResult(requestId: String, macID: String?, layout: WorkspaceSavedLayout?, error: String?)
    /// Workspace launch: asks the Core to have every other connected Mac run
    /// (or, with `undo`, reverse) a routine on its own windows. Answered with
    /// `CoreMessage.workspaceRunReport`. A new message type, as above.
    /// `operationID` names the run an Undo belongs to (optional: older
    /// Macs send none and are matched by routine and Mac instead).
    case workspaceRunAll(requestId: String, routineID: String, undo: Bool, operationID: String? = nil)
    /// Answer to `CoreMessage.workspaceRun`: what happened, in one line;
    /// empty when the routine has nothing for this Mac.
    case workspaceRunResult(requestId: String, summary: String, failure: String? = nil, counts: WorkspaceRunCounts? = nil)

    var type: String {
        switch self {
        case .hello: "hello"
        case .capabilities: "caps"
        case .ping: "ping"
        case .hotkeyDown: "hotkey.down"
        case .hotkeyUp: "hotkey.up"
        case .hotkeyToggle: "hotkey.toggle"
        case .hotkeyCancel: "hotkey.cancel"
        case .voiceCommandMode: "shortcut.mode"
        case .pressAbandoned: "press.abandon"
        case .focusClaim: "focus.claim"
        case .pointerPresence: "pointer.presence"
        case .level: "level"
        case .audioTake: "audio.take"
        case .captureFailed: "capture.failed"
        case .insertResult: "insert.result"
        case .repoRequest: "repo.request"
        case .sessionOutcomeQuery: "session.outcomes.query"
        case .cleanupResult: "cleanup.result"
        case .modelPullProgress: "model.pull.progress"
        case .pairRequest: "pair.request"
        case .pairingTokenSaved: "pair.token.saved"
        case .speechResult: "speech.result"
        case .transcribeRequest: "transcribe.request"
        case .textCleanupRequest: "text.cleanup.request"
        case .workspaceRememberAll: "workspace.remember.all"
        case .workspaceCaptureResult: "workspace.capture.result"
        case .workspaceRunAll: "workspace.run.all"
        case .workspaceRunResult: "workspace.run.result"
        }
    }
}

// MARK: - Core → Edge

enum CoreMessage: Equatable {
    case welcome(coreId: String, micOwner: EdgeID?, protocolVersion: Int)
    /// Core-owned behaviour every Edge must follow; sent after welcome and
    /// whenever it changes. `handsFree`: tap-to-start/tap-to-stop instead of
    /// hold-to-talk.
    case config(handsFree: Bool)
    case pong
    case captureStart(sessionId: SessionID)
    case captureStop(sessionId: SessionID)
    case captureCancel(sessionId: SessionID)
    case insert(sessionId: SessionID, text: String)
    /// A shortcut-mode dictation's result, for the Mac the words would land
    /// on: open a link, an app or a coding assistant, or (no shortcut matched)
    /// paste as usual with a notice. The target answers with `insertResult`.
    /// A new message type, so an older Mac ignores it.
    case voiceCommandInsert(sessionId: SessionID, delivery: VoiceCommandDelivery)
    /// A shortcut-mode dictation that matched a voice launch shortcut: the
    /// resolved plan (every step rendered and encoded) for the Mac the words
    /// would land on. The target runs the steps in order and answers with
    /// `insertResult`. A new message type, so an older Mac ignores it.
    case launchInsert(sessionId: SessionID, plan: VoiceLaunchPlan)
    case sessionState(SessionStateUpdate)
    /// Relayed mic level for the initiator's waveform.
    case level(rms: Float)
    case error(code: String, message: String)
    /// Reply to an `EdgeMessage.repoRequest` with the same `requestId`.
    case repoResponse(requestId: String, result: RepoResult)
    /// Broadcast to every connected Edge after a repo mutation lands, so
    /// a UI showing this Core's data knows to re-fetch.
    case repoChanged(RepoChange)
    /// Reply to `EdgeMessage.sessionOutcomeQuery` — only the
    /// ids the Core actually still remembers (its ring buffer of the last
    /// 50 terminal outcomes, see `CoreHost`) are present; an id the asking
    /// Edge queried but doesn't appear here simply means the Core has no
    /// record either way (still in flight, or aged out of the buffer), and
    /// the Edge leaves that checkpoint alone.
    case sessionOutcomes([SessionID: SessionOutcome])
    /// The Core's picture of every Mac in the setup and where speech to
    /// text and cleanup run; sent on connect and whenever it changes. An
    /// older Edge ignores the unknown type.
    case setup(SetupSnapshot)
    /// Run a cleanup on this Mac's Ollama (Settings › Your Macs chose it
    /// for cleanup); answered with `EdgeMessage.cleanupResult`.
    case cleanupRequest(requestId: String, job: CleanupJob)
    /// Download a model with this Mac's Ollama; progress comes back as
    /// `EdgeMessage.modelPullProgress`.
    case modelPull(requestId: String, model: String)
    /// The code both Macs show while a join waits for the user's OK.
    case pairCode(code: String, coreName: String)
    /// The user confirmed the code: the joining Mac gets the pairing token
    /// and reconnects with a normal `hello`.
    case pairApproved(token: String)
    /// Optional message: older peers ignore it without a protocol bump.
    case pairingTokenRotated(rotationId: String, token: String)
    case pairDenied(reason: String)
    /// Turn the recording in the binary frame that follows into text.
    case speechRequest(SpeechJob)
    /// Answer to `EdgeMessage.transcribeRequest`: the words, or why not.
    /// A new message type, so an older Edge ignores it.
    case transcribeResult(requestId: String, text: String?, error: String?)
    /// Answer to `EdgeMessage.textCleanupRequest`: the text, or why not.
    /// A new message type, so an older Edge ignores it.
    case textCleanupResult(requestId: String, text: String?, error: String?)
    /// The recording will be stopped by the time limit in `secondsLeft`
    /// seconds; sent to the Mac showing the badge and to the one the key was
    /// pressed on. Cleared by the next `sessionState` that isn't recording.
    /// A new message type, so an older Edge ignores it.
    case sessionCountdown(sessionId: SessionID, secondsLeft: Int)
    /// Remember where this Mac's windows are; answered with
    /// `EdgeMessage.workspaceCaptureResult`. A new message type, so an
    /// older Edge ignores it.
    case workspaceCapture(requestId: String)
    /// Answer to `EdgeMessage.workspaceRememberAll`: each Mac's layout keyed
    /// by its `WorkspaceMacIdentity`, and the names of Macs that didn't answer.
    case workspaceRemembered(requestId: String, layouts: [String: WorkspaceSavedLayout], unanswered: [String], busy: [String]? = nil)
    /// Run (or, with `undo`, reverse) a routine on this Mac's own windows,
    /// asked from the Mac called `from`; answered with `EdgeMessage.workspaceRunResult`.
    case workspaceRun(requestId: String, routineID: String, undo: Bool, from: String, operationID: String? = nil)
    /// Answer to `EdgeMessage.workspaceRunAll`: one line per Mac that ran it.
    case workspaceRunReport(requestId: String, reports: [WorkspaceRunReport])

    var type: String {
        switch self {
        case .welcome: "welcome"
        case .config: "config"
        case .pong: "pong"
        case .captureStart: "capture.start"
        case .captureStop: "capture.stop"
        case .captureCancel: "capture.cancel"
        case .insert: "insert"
        case .voiceCommandInsert: "insert.shortcut"
        case .launchInsert: "insert.launch"
        case .sessionState: "session.state"
        case .level: "level"
        case .error: "error"
        case .repoResponse: "repo.response"
        case .repoChanged: "repo.changed"
        case .sessionOutcomes: "session.outcomes"
        case .setup: "setup"
        case .cleanupRequest: "cleanup.request"
        case .modelPull: "model.pull"
        case .pairCode: "pair.code"
        case .pairApproved: "pair.approved"
        case .pairingTokenRotated: "pair.token.rotated"
        case .pairDenied: "pair.denied"
        case .speechRequest: "speech.request"
        case .transcribeResult: "transcribe.result"
        case .textCleanupResult: "text.cleanup.result"
        case .sessionCountdown: "session.countdown"
        case .workspaceCapture: "workspace.capture"
        case .workspaceRemembered: "workspace.remembered"
        case .workspaceRun: "workspace.run"
        case .workspaceRunReport: "workspace.run.report"
        }
    }
}

// MARK: - Codec

enum EdgeProtocolError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case unknownType(String)
    case frameTooLarge(Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): "Unsupported protocol version \(v)."
        case .unknownType(let t): "Unknown message type \(t)."
        case .frameTooLarge(let n): "Frame of \(n) bytes exceeds the protocol limit."
        case .malformed(let why): "Malformed message: \(why)."
        }
    }
}

/// Envelope `{v, t, id}` merged with the payload's own keys. Payload structs
/// encode into the same encoder so their keys land flat beside `t`.
enum EdgeProtocolCodec {
    private struct Envelope: Codable {
        var v: Int
        var t: String
        var id: String
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private static let decoder = JSONDecoder()

    // Payloads. Names mirror the wire keys.
    private struct HelloPayload: Codable { var edgeId: EdgeID; var name: String; var token: String; var caps: EdgeCapabilities }
    private struct CapabilitiesPayload: Codable { var caps: EdgeCapabilities }
    private struct HotkeyUpPayload: Codable { var reason: HotkeyUpReason }
    private struct FocusClaimPayload: Codable { var appBundleId: String? }
    private struct LevelPayload: Codable { var rms: Float }
    private struct InsertResultPayload: Codable { var sessionId: SessionID; var outcome: SessionOutcome; var destination: InsertDestination? }
    private struct WelcomePayload: Codable { var coreId: String; var micOwner: EdgeID?; var `protocol`: Int }
    private struct ConfigPayload: Codable { var handsFree: Bool }
    private struct SessionIDPayload: Codable { var sessionId: SessionID }
    private struct CaptureFailedPayload: Codable { var sessionId: SessionID; var message: String }
    private struct SessionCountdownPayload: Codable { var sessionId: SessionID; var secondsLeft: Int }
    private struct InsertPayload: Codable { var sessionId: SessionID; var text: String }
    private struct VoiceCommandInsertPayload: Codable { var sessionId: SessionID; var delivery: VoiceCommandDelivery }
    private struct LaunchInsertPayload: Codable { var sessionId: SessionID; var plan: VoiceLaunchPlan }
    private struct ErrorPayload: Codable { var code: String; var message: String }
    // `requestId`, not `id`: the envelope already owns that key.
    private struct RepoRequestPayload: Codable { var requestId: String; var request: RepoRequest }
    private struct RepoResponsePayload: Codable { var requestId: String; var result: RepoResult }
    private struct RepoChangedPayload: Codable { var change: RepoChange }
    private struct SessionOutcomeQueryPayload: Codable { var sessionIds: [SessionID] }
    private struct SessionOutcomesPayload: Codable { var outcomes: [SessionID: SessionOutcome] }
    private struct SetupPayload: Codable { var setup: SetupSnapshot }
    private struct CleanupRequestPayload: Codable { var requestId: String; var job: CleanupJob }
    private struct CleanupResultPayload: Codable { var requestId: String; var output: String?; var error: String? }
    private struct ModelPullPayload: Codable { var requestId: String; var model: String }
    private struct ModelPullProgressPayload: Codable { var requestId: String; var progress: ModelPullProgress }
    private struct PairRequestPayload: Codable { var edgeId: EdgeID; var name: String; var caps: EdgeCapabilities }
    private struct PairCodePayload: Codable { var code: String; var coreName: String }
    private struct TokenRotationPayload: Codable { var rotationId: String; var token: String }
    private struct TokenSavedPayload: Codable { var rotationId: String }
    private struct PairApprovedPayload: Codable { var token: String }
    private struct PairDeniedPayload: Codable { var reason: String }
    private struct SpeechRequestPayload: Codable { var job: SpeechJob }
    private struct SpeechResultPayload: Codable { var requestId: String; var text: String?; var error: String? }
    private struct TranscribeRequestPayload: Codable { var requestId: String; var header: AudioTakeHeader }
    private struct TranscribeResultPayload: Codable { var requestId: String; var text: String?; var error: String? }
    private struct TextCleanupRequestPayload: Codable { var requestId: String; var text: String; var useAI: Bool }
    private struct TextCleanupResultPayload: Codable { var requestId: String; var text: String?; var error: String? }
    private struct WorkspaceRequestPayload: Codable { var requestId: String }
    private struct WorkspaceCaptureResultPayload: Codable { var requestId: String; var macID: String?; var layout: WorkspaceSavedLayout?; var error: String? }
    private struct WorkspaceRunAllPayload: Codable { var requestId: String; var routineID: String; var undo: Bool; var operationID: String? }
    private struct WorkspaceRunResultPayload: Codable { var requestId: String; var summary: String; var failure: String?; var counts: WorkspaceRunCounts? }
    private struct WorkspaceRememberedPayload: Codable { var requestId: String; var layouts: [String: WorkspaceSavedLayout]; var unanswered: [String]; var busy: [String]? }
    private struct WorkspaceRunPayload: Codable { var requestId: String; var routineID: String; var undo: Bool; var from: String; var operationID: String? }
    private struct WorkspaceRunReportPayload: Codable { var requestId: String; var reports: [WorkspaceRunReport] }
    private struct VoiceCommandModePayload: Codable { var appBundleId: String? }
    private struct Empty: Codable {}

    // MARK: encode

    static func encode(_ message: EdgeMessage, id: String = UUID().uuidString) throws -> Data {
        switch message {
        case .hello(let edgeId, let name, let token, let caps):
            return try encode(type: message.type, id: id, HelloPayload(edgeId: edgeId, name: name, token: token, caps: caps))
        case .capabilities(let caps):
            return try encode(type: message.type, id: id, CapabilitiesPayload(caps: caps))
        case .ping, .hotkeyDown, .hotkeyToggle, .hotkeyCancel, .pressAbandoned, .pointerPresence:
            return try encode(type: message.type, id: id, Empty())
        case .voiceCommandMode(let appBundleId):
            return try encode(type: message.type, id: id, VoiceCommandModePayload(appBundleId: appBundleId))
        case .hotkeyUp(let reason):
            return try encode(type: message.type, id: id, HotkeyUpPayload(reason: reason))
        case .focusClaim(let bundle):
            return try encode(type: message.type, id: id, FocusClaimPayload(appBundleId: bundle))
        case .level(let rms):
            return try encode(type: message.type, id: id, LevelPayload(rms: rms))
        case .audioTake(let header):
            return try encode(type: message.type, id: id, header)
        case .captureFailed(let sessionId, let reason):
            return try encode(type: message.type, id: id, CaptureFailedPayload(sessionId: sessionId, message: reason))
        case .insertResult(let sessionId, let outcome, let destination):
            return try encode(type: message.type, id: id, InsertResultPayload(sessionId: sessionId, outcome: outcome, destination: destination))
        case .repoRequest(let requestId, let request):
            return try encode(type: message.type, id: id, RepoRequestPayload(requestId: requestId, request: request))
        case .sessionOutcomeQuery(let sessionIds):
            return try encode(type: message.type, id: id, SessionOutcomeQueryPayload(sessionIds: sessionIds))
        case .cleanupResult(let requestId, let output, let error):
            return try encode(type: message.type, id: id, CleanupResultPayload(requestId: requestId, output: output, error: error))
        case .modelPullProgress(let requestId, let progress):
            return try encode(type: message.type, id: id, ModelPullProgressPayload(requestId: requestId, progress: progress))
        case .pairingTokenSaved(let rotationId):
            return try encode(type: message.type, id: id, TokenSavedPayload(rotationId: rotationId))
        case .pairRequest(let edgeId, let name, let caps):
            return try encode(type: message.type, id: id, PairRequestPayload(edgeId: edgeId, name: name, caps: caps))
        case .speechResult(let requestId, let text, let error):
            return try encode(type: message.type, id: id, SpeechResultPayload(requestId: requestId, text: text, error: error))
        case .transcribeRequest(let requestId, let header):
            return try encode(type: message.type, id: id, TranscribeRequestPayload(requestId: requestId, header: header))
        case .textCleanupRequest(let requestId, let text, let useAI):
            return try encode(type: message.type, id: id, TextCleanupRequestPayload(requestId: requestId, text: text, useAI: useAI))
        case .workspaceRememberAll(let requestId):
            return try encode(type: message.type, id: id, WorkspaceRequestPayload(requestId: requestId))
        case .workspaceCaptureResult(let requestId, let macID, let layout, let error):
            return try encode(type: message.type, id: id, WorkspaceCaptureResultPayload(requestId: requestId, macID: macID, layout: layout, error: error))
        case .workspaceRunAll(let requestId, let routineID, let undo, let operationID):
            return try encode(type: message.type, id: id, WorkspaceRunAllPayload(requestId: requestId, routineID: routineID, undo: undo, operationID: operationID))
        case .workspaceRunResult(let requestId, let summary, let failure, let counts):
            return try encode(type: message.type, id: id, WorkspaceRunResultPayload(requestId: requestId, summary: summary, failure: failure, counts: counts))
        }
    }

    static func encode(_ message: CoreMessage, id: String = UUID().uuidString) throws -> Data {
        switch message {
        case .welcome(let coreId, let micOwner, let version):
            return try encode(type: message.type, id: id, WelcomePayload(coreId: coreId, micOwner: micOwner, protocol: version))
        case .config(let handsFree):
            return try encode(type: message.type, id: id, ConfigPayload(handsFree: handsFree))
        case .pong:
            return try encode(type: message.type, id: id, Empty())
        case .captureStart(let s), .captureStop(let s), .captureCancel(let s):
            return try encode(type: message.type, id: id, SessionIDPayload(sessionId: s))
        case .insert(let s, let text):
            return try encode(type: message.type, id: id, InsertPayload(sessionId: s, text: text))
        case .voiceCommandInsert(let s, let delivery):
            return try encode(type: message.type, id: id, VoiceCommandInsertPayload(sessionId: s, delivery: delivery))
        case .launchInsert(let s, let plan):
            return try encode(type: message.type, id: id, LaunchInsertPayload(sessionId: s, plan: plan))
        case .sessionState(let update):
            return try encode(type: message.type, id: id, update)
        case .level(let rms):
            return try encode(type: message.type, id: id, LevelPayload(rms: rms))
        case .error(let code, let text):
            return try encode(type: message.type, id: id, ErrorPayload(code: code, message: text))
        case .repoResponse(let requestId, let result):
            return try encode(type: message.type, id: id, RepoResponsePayload(requestId: requestId, result: result))
        case .repoChanged(let change):
            return try encode(type: message.type, id: id, RepoChangedPayload(change: change))
        case .sessionOutcomes(let outcomes):
            return try encode(type: message.type, id: id, SessionOutcomesPayload(outcomes: outcomes))
        case .setup(let setup):
            return try encode(type: message.type, id: id, SetupPayload(setup: setup))
        case .cleanupRequest(let requestId, let job):
            return try encode(type: message.type, id: id, CleanupRequestPayload(requestId: requestId, job: job))
        case .modelPull(let requestId, let model):
            return try encode(type: message.type, id: id, ModelPullPayload(requestId: requestId, model: model))
        case .pairCode(let code, let coreName):
            return try encode(type: message.type, id: id, PairCodePayload(code: code, coreName: coreName))
        case .pairingTokenRotated(let rotationId, let token):
            return try encode(type: message.type, id: id, TokenRotationPayload(rotationId: rotationId, token: token))
        case .pairApproved(let token):
            return try encode(type: message.type, id: id, PairApprovedPayload(token: token))
        case .pairDenied(let reason):
            return try encode(type: message.type, id: id, PairDeniedPayload(reason: reason))
        case .speechRequest(let job):
            return try encode(type: message.type, id: id, SpeechRequestPayload(job: job))
        case .transcribeResult(let requestId, let text, let error):
            return try encode(type: message.type, id: id, TranscribeResultPayload(requestId: requestId, text: text, error: error))
        case .textCleanupResult(let requestId, let text, let error):
            return try encode(type: message.type, id: id, TextCleanupResultPayload(requestId: requestId, text: text, error: error))
        case .sessionCountdown(let s, let secondsLeft):
            return try encode(type: message.type, id: id, SessionCountdownPayload(sessionId: s, secondsLeft: secondsLeft))
        case .workspaceCapture(let requestId):
            return try encode(type: message.type, id: id, WorkspaceRequestPayload(requestId: requestId))
        case .workspaceRemembered(let requestId, let layouts, let unanswered, let busy):
            return try encode(type: message.type, id: id, WorkspaceRememberedPayload(requestId: requestId, layouts: layouts, unanswered: unanswered, busy: busy))
        case .workspaceRun(let requestId, let routineID, let undo, let from, let operationID):
            return try encode(type: message.type, id: id, WorkspaceRunPayload(requestId: requestId, routineID: routineID, undo: undo, from: from, operationID: operationID))
        case .workspaceRunReport(let requestId, let reports):
            return try encode(type: message.type, id: id, WorkspaceRunReportPayload(requestId: requestId, reports: reports))
        }
    }

    private struct Framed<P: Encodable>: Encodable {
        let envelope: Envelope
        let payload: P
        func encode(to encoder: Encoder) throws {
            try envelope.encode(to: encoder)
            try payload.encode(to: encoder)
        }
    }

    private static func encode<P: Encodable>(type: String, id: String, _ payload: P) throws -> Data {
        let data = try encoder.encode(Framed(envelope: Envelope(v: EdgeProtocol.version, t: type, id: id), payload: payload))
        guard data.count <= EdgeProtocol.maxTextFrameBytes else {
            throw EdgeProtocolError.frameTooLarge(data.count)
        }
        return data
    }

    // MARK: decode

    private static func envelope(of data: Data) throws -> Envelope {
        guard data.count <= EdgeProtocol.maxTextFrameBytes else {
            throw EdgeProtocolError.frameTooLarge(data.count)
        }
        let env: Envelope
        do {
            env = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw EdgeProtocolError.malformed(error.localizedDescription)
        }
        guard env.v == EdgeProtocol.version else {
            throw EdgeProtocolError.unsupportedVersion(env.v)
        }
        return env
    }

    private static func payload<P: Decodable>(_: P.Type, from data: Data) throws -> P {
        do {
            return try decoder.decode(P.self, from: data)
        } catch {
            throw EdgeProtocolError.malformed(error.localizedDescription)
        }
    }

    static func decodeEdgeMessage(_ data: Data) throws -> EdgeMessage {
        let env = try envelope(of: data)
        switch env.t {
        case "hello":
            let p = try payload(HelloPayload.self, from: data)
            return .hello(edgeId: p.edgeId, name: p.name, token: p.token, caps: p.caps)
        case "caps": return .capabilities(try payload(CapabilitiesPayload.self, from: data).caps)
        case "ping": return .ping
        case "hotkey.down": return .hotkeyDown
        case "hotkey.up": return .hotkeyUp(reason: try payload(HotkeyUpPayload.self, from: data).reason)
        case "hotkey.toggle": return .hotkeyToggle
        case "hotkey.cancel": return .hotkeyCancel
        case "shortcut.mode": return .voiceCommandMode(appBundleId: try payload(VoiceCommandModePayload.self, from: data).appBundleId)
        case "press.abandon": return .pressAbandoned
        case "focus.claim": return .focusClaim(appBundleId: try payload(FocusClaimPayload.self, from: data).appBundleId)
        case "pointer.presence": return .pointerPresence
        case "level": return .level(rms: try payload(LevelPayload.self, from: data).rms)
        case "audio.take": return .audioTake(try payload(AudioTakeHeader.self, from: data))
        case "capture.failed":
            let p = try payload(CaptureFailedPayload.self, from: data)
            return .captureFailed(sessionId: p.sessionId, message: p.message)
        case "insert.result":
            let p = try payload(InsertResultPayload.self, from: data)
            return .insertResult(sessionId: p.sessionId, outcome: p.outcome, destination: p.destination)
        case "repo.request":
            let p = try payload(RepoRequestPayload.self, from: data)
            return .repoRequest(id: p.requestId, request: p.request)
        case "session.outcomes.query":
            return .sessionOutcomeQuery(sessionIds: try payload(SessionOutcomeQueryPayload.self, from: data).sessionIds)
        case "cleanup.result":
            let p = try payload(CleanupResultPayload.self, from: data)
            return .cleanupResult(requestId: p.requestId, output: p.output, error: p.error)
        case "model.pull.progress":
            let p = try payload(ModelPullProgressPayload.self, from: data)
            return .modelPullProgress(requestId: p.requestId, progress: p.progress)
        case "pair.token.saved":
            return .pairingTokenSaved(rotationId: try payload(TokenSavedPayload.self, from: data).rotationId)
        case "pair.request":
            let p = try payload(PairRequestPayload.self, from: data)
            return .pairRequest(edgeId: p.edgeId, name: p.name, caps: p.caps)
        case "speech.result":
            let p = try payload(SpeechResultPayload.self, from: data)
            return .speechResult(requestId: p.requestId, text: p.text, error: p.error)
        case "transcribe.request":
            let p = try payload(TranscribeRequestPayload.self, from: data)
            return .transcribeRequest(requestId: p.requestId, header: p.header)
        case "text.cleanup.request":
            let p = try payload(TextCleanupRequestPayload.self, from: data)
            return .textCleanupRequest(requestId: p.requestId, text: p.text, useAI: p.useAI)
        case "workspace.remember.all":
            return .workspaceRememberAll(requestId: try payload(WorkspaceRequestPayload.self, from: data).requestId)
        case "workspace.capture.result":
            let p = try payload(WorkspaceCaptureResultPayload.self, from: data)
            return .workspaceCaptureResult(requestId: p.requestId, macID: p.macID, layout: p.layout, error: p.error)
        case "workspace.run.all":
            let p = try payload(WorkspaceRunAllPayload.self, from: data)
            return .workspaceRunAll(requestId: p.requestId, routineID: p.routineID, undo: p.undo, operationID: p.operationID)
        case "workspace.run.result":
            let p = try payload(WorkspaceRunResultPayload.self, from: data)
            return .workspaceRunResult(requestId: p.requestId, summary: p.summary, failure: p.failure, counts: p.counts)
        case let other:
            throw EdgeProtocolError.unknownType(other)
        }
    }

    static func decodeCoreMessage(_ data: Data) throws -> CoreMessage {
        let env = try envelope(of: data)
        switch env.t {
        case "welcome":
            let p = try payload(WelcomePayload.self, from: data)
            return .welcome(coreId: p.coreId, micOwner: p.micOwner, protocolVersion: p.protocol)
        case "config": return .config(handsFree: try payload(ConfigPayload.self, from: data).handsFree)
        case "pong": return .pong
        case "capture.start": return .captureStart(sessionId: try payload(SessionIDPayload.self, from: data).sessionId)
        case "capture.stop": return .captureStop(sessionId: try payload(SessionIDPayload.self, from: data).sessionId)
        case "capture.cancel": return .captureCancel(sessionId: try payload(SessionIDPayload.self, from: data).sessionId)
        case "insert":
            let p = try payload(InsertPayload.self, from: data)
            return .insert(sessionId: p.sessionId, text: p.text)
        case "insert.shortcut":
            let p = try payload(VoiceCommandInsertPayload.self, from: data)
            return .voiceCommandInsert(sessionId: p.sessionId, delivery: p.delivery)
        case "insert.launch":
            let p = try payload(LaunchInsertPayload.self, from: data)
            return .launchInsert(sessionId: p.sessionId, plan: p.plan)
        case "session.state": return .sessionState(try payload(SessionStateUpdate.self, from: data))
        case "level": return .level(rms: try payload(LevelPayload.self, from: data).rms)
        case "error":
            let p = try payload(ErrorPayload.self, from: data)
            return .error(code: p.code, message: p.message)
        case "repo.response":
            let p = try payload(RepoResponsePayload.self, from: data)
            return .repoResponse(requestId: p.requestId, result: p.result)
        case "repo.changed":
            return .repoChanged(try payload(RepoChangedPayload.self, from: data).change)
        case "session.outcomes":
            return .sessionOutcomes(try payload(SessionOutcomesPayload.self, from: data).outcomes)
        case "setup":
            return .setup(try payload(SetupPayload.self, from: data).setup)
        case "cleanup.request":
            let p = try payload(CleanupRequestPayload.self, from: data)
            return .cleanupRequest(requestId: p.requestId, job: p.job)
        case "model.pull":
            let p = try payload(ModelPullPayload.self, from: data)
            return .modelPull(requestId: p.requestId, model: p.model)
        case "pair.code":
            let p = try payload(PairCodePayload.self, from: data)
            return .pairCode(code: p.code, coreName: p.coreName)
        case "pair.token.rotated":
            let p = try payload(TokenRotationPayload.self, from: data)
            return .pairingTokenRotated(rotationId: p.rotationId, token: p.token)
        case "pair.approved":
            return .pairApproved(token: try payload(PairApprovedPayload.self, from: data).token)
        case "pair.denied":
            return .pairDenied(reason: try payload(PairDeniedPayload.self, from: data).reason)
        case "speech.request":
            return .speechRequest(try payload(SpeechRequestPayload.self, from: data).job)
        case "transcribe.result":
            let p = try payload(TranscribeResultPayload.self, from: data)
            return .transcribeResult(requestId: p.requestId, text: p.text, error: p.error)
        case "text.cleanup.result":
            let p = try payload(TextCleanupResultPayload.self, from: data)
            return .textCleanupResult(requestId: p.requestId, text: p.text, error: p.error)
        case "session.countdown":
            let p = try payload(SessionCountdownPayload.self, from: data)
            return .sessionCountdown(sessionId: p.sessionId, secondsLeft: p.secondsLeft)
        case "workspace.capture":
            return .workspaceCapture(requestId: try payload(WorkspaceRequestPayload.self, from: data).requestId)
        case "workspace.remembered":
            let p = try payload(WorkspaceRememberedPayload.self, from: data)
            return .workspaceRemembered(requestId: p.requestId, layouts: p.layouts, unanswered: p.unanswered, busy: p.busy)
        case "workspace.run":
            let p = try payload(WorkspaceRunPayload.self, from: data)
            return .workspaceRun(requestId: p.requestId, routineID: p.routineID, undo: p.undo, from: p.from, operationID: p.operationID)
        case "workspace.run.report":
            let p = try payload(WorkspaceRunReportPayload.self, from: data)
            return .workspaceRunReport(requestId: p.requestId, reports: p.reports)
        case let other:
            throw EdgeProtocolError.unknownType(other)
        }
    }

    /// Peeks the `t` of a frame without fully decoding it (for logging and
    /// for the hello gate on a fresh connection).
    static func messageType(of data: Data) -> String? {
        try? envelope(of: data).t
    }
}
