import Foundation
import SwiftUI

/// Bridges a locally-attached Edge to `CoreHost` without `CoreHost` needing
/// to depend on `EdgeRuntime`'s device-bound internals (mic/hotkey/paste).
/// `EdgeRuntime` conforms to this (see `EdgeRuntime.swift`) for the
/// production path; `CoreHostTests` attaches a fake channel instead so the
/// broker's effect execution is testable without a live mic or hotkey.
@MainActor
protocol LocalEdgeChannel: AnyObject {
    var edgeId: EdgeID { get }
    func deliver(_ message: CoreMessage)
}

/// Owns a `SessionBroker` and executes its effects: sends frames to a local
/// edge or over a `CoreServer`, runs transcription, schedules/cancels the
/// watchdog, and records history. Every install runs one of these — the only
/// difference between standalone, Core, and Edge (from this class's point of
/// view) is whether `startListening` was ever called.
@MainActor
@Observable
final class CoreHost {
    private let coreId: String
    /// `(sessionId, text, durationSeconds, inferenceMs, destination, initiator)`
    /// — the initiator is the Edge whose hotkey started the session, recorded
    /// as the entry's `originEdgeId`.
    private let recordHistoryEntry: (SessionID, String, Double, Int?, InsertDestination?, EdgeID) async throws -> Void

    /// Persists a received take before transcription starts, retries
    /// transient failures with backoff, and chunks recordings too long for
    /// the inference server. Wraps the `transcribe` closure passed into
    /// `init` — `CoreHost` never calls it directly.
    private let durableTranscriber: DurableTranscriber

    private let broker: SessionBroker
    private var server: CoreServer?
    private var localEdge: LocalEdgeChannel?

    /// The Core's own (local) history/dictionary/settings store —
    /// answers `.repoRequest`s from remote edges via `repoServer` and is
    /// the source of `.repoChanged` broadcasts to them (see
    /// `broadcastRepoChanged`). Settable, not just constructor-injected:
    /// `DictatorViewModel` constructs this host before its `ModelContainer`
    /// exists (see `DictatorViewModel.modelContainer`'s `didSet`), so it
    /// starts over an in-memory placeholder bundle and gets swapped onto
    /// the real on-disk one once persistence actually becomes available.
    /// Swapping rebuilds `repoServer` against the new bundle.
    var repositories: Repositories {
        didSet { rebuildRepoServer() }
    }
    var onCorrection: ((CorrectionReport) async throws -> CorrectionOutcome)?
    private var repoServer: RepoServer

    /// Test-only seam standing in for `server?.send`/`server?.broadcast`:
    /// `CoreHostTests` never starts a real `CoreServer`/socket, so
    /// `handleRepoRequest`'s response and `broadcastRepoChanged` route
    /// through these when set instead. Never set outside `DictatorTests`.
    var remoteEdgeSendOverride: ((CoreMessage, EdgeID) -> Void)?
    var remoteBroadcastOverride: ((CoreMessage) -> Void)?

    private var transcriptionTasks: [SessionID: Task<Void, Never>] = [:]
    private var watchdogTasks: [SessionID: Task<Void, Never>] = [:]
    private var countdownTasks: [SessionID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pressSettleTasks: [PressID: Task<Void, Never>] = [:]
    @ObservationIgnored private var releaseGraceTasks: [SessionID: Task<Void, Never>] = [:]

    /// The last 50 terminal outcomes this Core has broadcast,
    /// oldest first — lets a mic owner that disconnected right after
    /// uploading (so it never saw the idle broadcast) ask, on reconnect,
    /// whether its still-`uploaded` checkpoint actually succeeded, instead
    /// of only finding out by re-transcribing it (duplicate history/paste).
    /// Kept here rather than in the pure `SessionBroker` — it's purely an
    /// answer to a later, independent query, not part of the state machine
    /// itself. A ring buffer (not persisted, not unbounded) because this is
    /// a best-effort reconciliation, not a durability guarantee — the
    /// checkpoint file itself is the durable record; this just avoids
    /// needlessly re-processing one whose outcome the Core still remembers.
    private var recentSessionOutcomes: [(sessionId: SessionID, outcome: SessionOutcome)] = []
    private static let sessionOutcomeHistoryLimit = 50

    /// Serial FIFO chain of effect-batch execution: each
    /// `apply()` call's effects run inside one link of this chain, in
    /// order, with `.recordHistory` awaited before later effects in the
    /// same batch (e.g. the `sessionState(idle)` sends that follow it) run.
    /// Batches never interleave — each link awaits the previous one before
    /// starting. `drain()` lets a teardown path wait for everything queued
    /// so far to finish.
    private var effectChain: Task<Void, Never>?

    /// Test-only override so `CoreHostTests` doesn't wait out the real
    /// `EdgeProtocol.maxSessionDuration` (120s) to see the watchdog fire.
    var watchdogDurationOverride: TimeInterval?
    /// Test seam: when set, the "about to end" warning fires after this long.
    /// Left nil, the warning is skipped while `watchdogDurationOverride` is
    /// set (a shortened watchdog would otherwise start it at once).
    var countdownDelayOverride: TimeInterval?

    /// Test-only override so `CoreHostTests` doesn't wait out the real
    /// `SessionBroker.releaseGrace` (0.25s) to see it fire.
    var releaseGraceOverride: TimeInterval?

    var session: SessionSnapshot? { broker.session }
    func takeCommandAppBundleID(sessionId: SessionID) -> String? {
        broker.takeCommandAppBundleID(sessionId: sessionId)
    }

    /// Set by the view model: turns the words of a shortcut-mode dictation
    /// (as spoken, before clean-up) into what to type or open. Never called
    /// for a plain dictation.
    var resolveVoiceCommand: ((_ sessionId: SessionID, _ transcript: String) async -> VoiceCommandResolution)?
    /// Teach: the words in a recording as spoken, through the same speech
    /// path dictation uses, with no clean-up, paste or history. Set by the app.
    var transcribeRaw: ((_ header: AudioTakeHeader, _ audio: Data) async throws -> String)?
    /// Shortcuts: dictionary replacements and optional AI clean-up of given
    /// text, on this Mac (the main Mac). Set by `DictatorViewModel`.
    var cleanUpText: ((_ text: String, _ useAI: Bool) async throws -> String)?
    private(set) var listeningAddress: String?
    private(set) var connectedEdges: [BrokerEdgeInfo] = [] {
        didSet {
            if connectedEdges != oldValue { onEdgesChanged?(connectedEdges) }
        }
    }
    /// Fires when a Mac connects, disconnects or reports new capabilities
    /// (`SetupDirectory` keeps the setup picture from it).
    var onEdgesChanged: (([BrokerEdgeInfo]) -> Void)?

    /// The setup picture (`SetupDirectory`); sent to every remote Edge now
    /// and to each one that connects later.
    var setupSnapshot: SetupSnapshot? {
        didSet {
            guard let setupSnapshot, setupSnapshot != oldValue else { return }
            server?.broadcast(.setup(setupSnapshot))
        }
    }
    var listenerWarning: String?
    /// Fires when the listener failed after starting (its address couldn't be
    /// bound yet, for instance), so the app can try again later.
    var onListenerFailed: (() -> Void)?

    var micOwnerPreference: EdgeID? {
        get { broker.micOwnerPreference }
        set { apply(.micOwnerChanged(newValue)) }
    }

    /// Core-owned hands-free preference (tap-to-start/tap-to-stop instead of
    /// hold-to-talk), mirrored from `AppSettings.hotkeyHandsFree` by
    /// `DictatorViewModel.applyHandsFree()`. Broadcast directly here rather
    /// than through `SessionBroker` — it's independent of any active
    /// session (an idle Edge still needs to know which mode its own hotkey
    /// tap should speak) and can change at any time, not just around a
    /// session boundary.
    var handsFree: Bool = false {
        didSet {
            guard oldValue != handsFree else { return }
            let message = CoreMessage.config(handsFree: handsFree)
            for edgeId in broker.edges.keys {
                sendToEdge(edgeId, message)
            }
        }
    }

    /// Called on the Core the moment a dictation session starts (key down on
    /// any Mac), before recording has produced anything. Must not block.
    var onSessionStarted: (() -> Void)?
    var onSessionFinished: ((SessionID) -> Void)?
    var onHeardText: ((SessionID, String) -> Void)?

    init(
        coreId: String,
        repositories: Repositories,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeSessionID: @escaping () -> SessionID = { UUID().uuidString },
        transcribe: @escaping (AudioTakeHeader, Data) async throws -> (text: String, inferenceMs: Int?),
        recordHistory: @escaping (SessionID, String, Double, Int?, InsertDestination?, EdgeID) async throws -> Void,
        checkpointStore: RecordingCheckpointStore = RecordingCheckpointStore(),
        transcribeWithRawText: ((AudioTakeHeader, Data) async throws -> (text: String, inferenceMs: Int?, rawText: String?))? = nil
    ) {
        self.coreId = coreId
        self.recordHistoryEntry = recordHistory
        self.durableTranscriber = DurableTranscriber(store: checkpointStore, transcribeWithRawText: transcribeWithRawText ?? { header, data in
            let result = try await transcribe(header, data)
            return (result.text, result.inferenceMs, nil)
        })
        self.broker = SessionBroker(coreId: coreId, clock: clock, makeSessionID: makeSessionID)
        self.repositories = repositories
        self.repoServer = RepoServer(repositories: repositories)
        rebuildRepoServer()
    }

    /// Rebuilds `repoServer` against whatever `repositories` currently is —
    /// called from `repositories`'s `didSet` and once, redundantly but
    /// harmlessly, from `init` above (a `didSet` never fires during its own
    /// property's initialization).
    ///
    /// Wires no `onChange`: a repository's one `onChange` slot belongs to
    /// `RepositoryHub` alone. A remote edge's mutation lands in this same
    /// `repositories` bundle; `DictatorViewModel` observes
    /// `RepositoryHub`'s per-domain versions (which bump from that same
    /// write, since Core role's `repositoryHub.current` is this
    /// `repositories` instance) and calls `broadcastRepoChanged` itself —
    /// one notification source.
    private func rebuildRepoServer() {
        repoServer = RepoServer(repositories: repositories)
    }

    // MARK: - Local edge

    /// Production entry point: wires `runtime.send`/`sendAudio` onto the
    /// broker and attaches it as the local edge with its current
    /// capabilities. Call again (e.g. when a mic appears) to re-apply
    /// updated capabilities — `attachLocal` below re-applies
    /// `.edgeConnected` idempotently.
    func attachLocalEdge(_ runtime: EdgeRuntime) {
        attachLocal(runtime, caps: runtime.capabilities(), name: runtime.edgeName)
        runtime.send = { [weak self] message in
            self?.apply(.message(message, from: runtime.edgeId))
        }
        runtime.localSession = { [weak self] in self?.broker.session }
        runtime.sendAudio = { [weak self] header, data in
            guard let self else { return }
            self.apply(.message(.audioTake(header), from: runtime.edgeId))
            self.apply(.audio(data, from: runtime.edgeId))
        }
        // Mic permission granted / health recovery after attach
        // must refresh the broker's view of this edge's capabilities, not
        // just `EdgeRuntime`'s own state.
        runtime.onCapabilitiesChanged = { [weak self] caps in
            self?.apply(.message(.capabilities(caps), from: runtime.edgeId))
        }
    }

    /// Lower-level seam used directly by `CoreHostTests` with a fake
    /// `LocalEdgeChannel`; `attachLocalEdge(_:)` above is the production
    /// entry point that also wires an `EdgeRuntime`'s `send`/`sendAudio`.
    func attachLocal(_ channel: LocalEdgeChannel, caps: EdgeCapabilities, name: String? = nil) {
        localEdge = channel
        // Uses the local edge's display name — `runtime.edgeName` from
        // `attachLocalEdge` above — rather than its UUID `edgeId`, which is
        // what every other connected-edges UI (`ConnectionDetailsView`, the
        // recovery list's "machine" column) expects to show. `name` defaults
        // to `channel.edgeId` only for the fake-channel seam `CoreHostTests`
        // uses, which has no display name.
        apply(.edgeConnected(BrokerEdgeInfo(id: channel.edgeId, name: name ?? channel.edgeId, caps: caps)))
        // The local edge must learn the current mode
        // immediately on attach — it won't see a `config` broadcast that
        // predates it, same reasoning as `handleEdgeConnected`'s
        // `sessionState` catch-up for a mid-session join.
        channel.deliver(.config(handsFree: handsFree))
    }

    func detachLocalEdge() {
        guard let localEdge else { return }
        // The runtime is no longer attached to this broker: its chords must
        // take the remote path.
        (localEdge as? EdgeRuntime)?.localSession = nil
        apply(.edgeDisconnected(localEdge.edgeId))
        self.localEdge = nil
    }

    // MARK: - Remote listener (Core role)

    /// Revoke transport access before updating the setup listing. With no
    /// listener, persist the replacement for the next time listening starts.
    func revokeAccess(for id: EdgeID) throws {
        guard !isEdgeIdReserved(id) else { return }
        if let server { try server.revokeAccess(for: id) }
        else { _ = try LocalSecret.rotateSharedToken() }
        apply(.edgeDisconnected(id))
    }

    func startListening(bindHost: String, token: String) throws {
        stopListening()
        // A remote peer must not be able to self-assert the
        // local Edge's id and corrupt the broker's local-edge bookkeeping.
        let server = CoreServer(
            coreId: coreId, token: token, bindHost: bindHost,
            isEdgeIdReserved: { [weak self] id in self?.isEdgeIdReserved(id) ?? false }
        )
        // Every callback below is generation-guarded: a
        // `CoreServer` instance whose callbacks fire after `stopListening()`
        // has moved on (or after a newer `startListening()` replaced it) is
        // no longer `self.server`, so its late callbacks are dropped instead
        // of resurrecting ghost edges or corrupting the broker's state for
        // whatever server currently owns the listener.
        server.onEdgeConnected = { [weak self, weak server] info in
            guard let self, let server, self.server === server else { return }
            self.apply(.edgeConnected(info))
            // Sent after `CoreServer` has already written `welcome` to this
            // edge (this callback only fires once that has happened) — the
            // remote Edge learns the current mode right behind the
            // handshake, same as a fresh local attach above.
            self.sendToEdge(info.id, .config(handsFree: self.handsFree))
            if let setup = self.setupSnapshot {
                self.sendToEdge(info.id, .setup(setup))
            }
        }
        server.onEdgeDisconnected = { [weak self, weak server] id in
            guard let self, let server, self.server === server else { return }
            self.apply(.edgeDisconnected(id))
        }
        server.onMessage = { [weak self, weak server] message, id in
            guard let self, let server, self.server === server else { return }
            // A repo request is not part of the dictation session state
            // machine — answer it directly against `repoServer` instead of
            // routing it through `SessionBroker`/`apply` (which just
            // no-ops on it, see `SessionBroker.apply`'s `.repoRequest` case).
            if case .repoRequest(let requestId, let request) = message {
                self.handleRepoRequest(id: requestId, request: request, from: id)
                return
            }
            self.apply(.message(message, from: id))
        }
        server.onAudio = { [weak self, weak server] data, id in
            guard let self, let server, self.server === server else { return }
            self.apply(.audio(data, from: id))
        }
        server.onTranscribeRequest = { [weak self, weak server] requestId, header, data, id in
            guard let self, let server, self.server === server else { return }
            self.handleTranscribeRequest(requestId: requestId, header: header, audio: data, from: id)
        }
        server.onHealthChanged = { [weak self, weak server] healthy, message in
            guard let self, let server, self.server === server else { return }
            self.handleListenerHealth(healthy: healthy, message: message)
        }
        server.coreName = coreName
        server.acceptNewMacs(until: acceptingNewMacsUntil)
        server.onPairRequest = { [weak self, weak server] request in
            guard let self, let server, self.server === server else { return }
            self.pendingJoin = request
        }
        server.onPairEnded = { [weak self, weak server] id in
            guard let self, let server, self.server === server else { return }
            if self.pendingJoin?.id == id { self.pendingJoin = nil }
        }
        try server.start()
        self.server = server
        listeningAddress = "\(bindHost):\(EdgeProtocol.corePort)"
    }

    /// The listener is only really up once it reports ready. A failure clears
    /// `listeningAddress` so the app doesn't think it is listening and knows to retry.
    func handleListenerHealth(healthy: Bool, message: String?) {
        listenerWarning = healthy ? nil : message
        guard !healthy else { return }
        listeningAddress = nil
        onListenerFailed?()
    }

    func stopListening() {
        guard let server else { return }
        // `CoreServer.stop()` deliberately does not fire `onEdgeDisconnected`
        // for the edges it tears down, so an active remote session would
        // otherwise be left hanging with no one to tell the broker its mic
        // owner/initiator/target is gone. Apply it ourselves for every
        // remote edge we knew about before tearing the listener down.
        let remoteIds = broker.edges.keys.filter { $0 != localEdge?.edgeId }
        // Nil `self.server` before tearing the old one down and applying the
        // disconnects below: any callback the old server fires
        // during/after `stop()` — synchronously or later — immediately fails
        // its `self.server === server` identity check and is dropped, so it
        // can never race the `.edgeDisconnected`s we're about to apply.
        self.server = nil
        listeningAddress = nil
        server.stop()
        for id in remoteIds { apply(.edgeDisconnected(id)) }
    }

    deinit {
        for task in pressSettleTasks.values { task.cancel() }
        for task in releaseGraceTasks.values { task.cancel() }
    }

    // MARK: - Identity

    /// Stable per-install identity for the Core role, generated once and
    /// kept in UserDefaults under `coreId`. Deliberately independent of any
    /// local Edge's id — passing `EdgeRuntime.edgeId` as `coreId` would let
    /// a remote peer that self-asserts that same id corrupt the broker's
    /// local-edge bookkeeping.
    static func persistentCoreId() -> String {
        let key = "coreId"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: key)
        return created
    }

    /// Edge ids a remote peer must never be allowed to claim via `hello`.
    /// Currently just the locally-attached edge, if any — a remote `hello`
    /// bearing this id would otherwise let `CoreServer` replace the local
    /// edge's broker entry, and losing that connection later would remove
    /// it even though `localEdge` is still very much attached.
    var reservedEdgeIds: Set<EdgeID> {
        guard let localEdge else { return [] }
        return [localEdge.edgeId]
    }

    /// Predicate form of `reservedEdgeIds`, handed to `CoreServer` in
    /// `startListening` so a remote peer can never claim the local edge's id.
    func isEdgeIdReserved(_ id: EdgeID) -> Bool {
        reservedEdgeIds.contains(id)
    }

    // MARK: - Broker plumbing

    /// The low-level `BrokerInput` seam: production callers above always
    /// route through it, and `CoreHostTests` calls it directly with a fake
    /// local edge to drive the broker without any real transport.
    @discardableResult
    func apply(_ input: BrokerInput) -> [BrokerEffect] {
        // Answered directly against `recentSessionOutcomes`,
        // same reasoning as `.repoRequest` above `handleRepoRequest` —
        // not part of the dictation session state machine, so it bypasses
        // the broker entirely rather than round-tripping through a no-op
        // case there.
        if case .message(.sessionOutcomeQuery(let sessionIds), from: let from) = input {
            handleSessionOutcomeQuery(sessionIds: sessionIds, from: from)
            return []
        }
        if case .message(.cleanupResult(let requestId, let output, let error), from: _) = input {
            finishCleanup(requestId: requestId, output: output, error: error)
            return []
        }
        if case .message(.textCleanupRequest(let requestId, let text, let useAI), from: let from) = input {
            handleTextCleanupRequest(requestId: requestId, text: text, useAI: useAI, from: from)
            return []
        }
        if case .message(.speechResult(let requestId, let text, let error), from: _) = input {
            finishSpeech(requestId: requestId, text: text, error: error)
            return []
        }
        if case .message(let message, from: let from) = input, handleWorkspaceMessage(message, from: from) {
            return []
        }
        if case .message(.modelPullProgress(let requestId, let progress), from: _) = input {
            pullObservers[requestId]?(progress)
            if progress.done || progress.error != nil { pullObservers[requestId] = nil }
            return []
        }
        // The broker itself is pure and synchronous — `session` reflects
        // this input immediately, before any of its effects have actually
        // run. Only *executing* the effects (sends, history writes) is
        // queued below.
        let hadSession = broker.session != nil
        let effects = broker.apply(input)
        if !hadSession, broker.session != nil { onSessionStarted?() }
        connectedEdges = Array(broker.edges.values)
        enqueue(effects)
        return effects
    }

    /// Chains this batch's execution onto `effectChain` so batches run FIFO
    /// with no interleaving: the new link awaits the previous
    /// one, then runs `effects` in order on the main actor, `await`ing
    /// `.recordHistory` before moving on to whatever in the same batch
    /// follows it (typically the `sessionState(idle)` sends).
    ///
    /// Captures `self` strongly, not weakly: `CoreHost` outlives its own
    /// effect chain in practice, and `[weak self]` here interacts badly
    /// with awaiting another task's `.value` from a `@MainActor` context —
    /// empirically it never resumes (a Swift concurrency runtime quirk, not
    /// a logic bug). Each link still completes and is released once
    /// `effectChain` moves on, so this isn't a lasting retain cycle.
    private func enqueue(_ effects: [BrokerEffect]) {
        let previous = effectChain
        effectChain = Task { @MainActor in
            _ = await previous?.value
            // History precedes the terminal broadcasts in this batch. If it
            // fails, every peer must keep its recording, including a peer that
            // later asks for the outcome after reconnecting.
            var historyFailures: [SessionID: String] = [:]
            for effect in effects {
                var delivery = effect
                if case .send(let edge, .sessionState(var update)) = effect,
                   update.state == .idle, let failure = historyFailures[update.sessionId] {
                    update.outcome = .failed(message: failure)
                    delivery = .send(edge, .sessionState(update))
                }
                do {
                    try await self.executeAsync(delivery)
                } catch {
                    if case .recordHistory(let sessionID, _, _, _, _, _) = effect {
                        let alert = DictationAlert(
                            title: "Your text couldn’t be saved to history",
                            detail: "Your text arrived, but Dictator couldn’t save it. The recording is kept in History & Privacy so you can try again.",
                            action: .history)
                        historyFailures[sessionID] = alert.encoded
                        self.durableTranscriber.markCheckpointFailed(sessionId: sessionID, message: alert.title)
                    }
                }
            }
        }
    }

    /// Awaits the effect chain up to everything queued so far. Exposed for
    /// teardown paths (e.g. quitting, or switching role) that must not
    /// proceed until any in-flight history write has actually landed.
    func drain() async {
        _ = await effectChain?.value
    }

    private func executeAsync(_ effect: BrokerEffect) async throws {
        switch effect {
        case .send(let edgeId, let message):
            sendToEdge(edgeId, message)
            // The success path (`.pasted`/`.clipboardOnly`) is
            // already covered by `.recordHistory` below discarding the
            // checkpoint once the history write lands — but `.cancelled`
            // (Esc during processing) and `.empty` end without ever going
            // through `.recordHistory`, so without this they'd leak
            // `core-<session>` until the 14-day age prune. This is where
            // the broker tells every connected edge the session's terminal
            // outcome, so it's also where the Core last has a clean shot at
            // that outcome — discard for anything except `.failed` (kept
            // for "retry from the menu"); a repeat call for the same
            // session (once per connected edge — `broadcastSessionState`
            // fans this `.send` out to all of them) is a safe no-op.
            if case .sessionState(let update) = message, update.state == .idle, let outcome = update.outcome {
                discardCoreCheckpointUnlessFailed(sessionId: update.sessionId, outcome: outcome)
                recordSessionOutcome(sessionId: update.sessionId, outcome: outcome)
            }
        case .transcribe(let sessionId, let header, let data):
            // Deliberately not awaited: transcription runs as its own
            // detached task so a later `hotkeyCancel` in this same chain
            // (its `.cancelTranscription` effect) can still reach it instead
            // of queuing behind it.
            startTranscription(sessionId: sessionId, header: header, data: data)
        case .cancelTranscription(let sessionId):
            transcriptionTasks[sessionId]?.cancel()
            transcriptionTasks[sessionId] = nil
        case .scheduleWatchdog(let sessionId, let duration):
            // Also not awaited, for the same reason: the watchdog fires
            // independently and must not block this chain while it waits.
            scheduleWatchdog(sessionId: sessionId, duration: watchdogDurationOverride ?? duration)
        case .cancelWatchdog(let sessionId):
            watchdogTasks[sessionId]?.cancel()
            watchdogTasks[sessionId] = nil
        case .scheduleCountdown(let sessionId, let delay):
            if let delay = countdownDelayOverride ?? (watchdogDurationOverride == nil ? delay : nil) {
                scheduleCountdown(sessionId: sessionId, delay: delay)
            }
        case .cancelCountdown(let sessionId):
            countdownTasks[sessionId]?.cancel()
            countdownTasks[sessionId] = nil
        case .schedulePressSettle(let id, let duration):
            schedulePressSettle(id: id, duration: duration)
        case .cancelPressSettle(let id):
            pressSettleTasks[id]?.cancel()
            pressSettleTasks[id] = nil
        case .scheduleReleaseGrace(let sessionId, let duration):
            // Also not awaited, same reason as the watchdog above: it fires
            // independently and must not block this chain while it waits.
            scheduleReleaseGrace(sessionId: sessionId, duration: releaseGraceOverride ?? duration)
        case .cancelReleaseGrace(let sessionId):
            releaseGraceTasks[sessionId]?.cancel()
            releaseGraceTasks[sessionId] = nil
        case .recordHistory(let sessionId, let text, let durationSeconds, let inferenceMs, let destination, let initiator):
            // Awaited: later effects in this same batch (the `idle` sends
            // that follow a successful insert) must not go out until the
            // history entry has actually been recorded.
            try await recordHistoryEntry(sessionId, text, durationSeconds, inferenceMs, destination, initiator)
            // The take made it all the way to a recorded history
            // entry — the Core's retained copy is no longer needed
            // for recovery.
            durableTranscriber.discardCheckpoint(sessionId: sessionId)
        case .log(let message):
            NSLog("[Core] %@", message)
        }
    }

    enum CheckpointFate: Equatable { case keep, discardCoreCopy, discardBoth }

    /// What happens to a session's checkpoints at each terminal
    /// outcome. `.failed` stays for "retry from the menu". A user's cancel, a
    /// take with no audio and a delivered dictation need nothing kept. The
    /// rest (`.micLost`/`.initiatorLost`/`.targetLost`/`.watchdog`) lost the
    /// words on the way: `EdgeRuntime`'s `applyCheckpointCleanup` keeps the
    /// mic owner's copy for those, so only the Core's duplicate may go.
    static func checkpointFate(for outcome: SessionOutcome) -> CheckpointFate {
        switch outcome {
        case .failed: .keep
        case .pasted, .clipboardOnly, .empty: .discardBoth
        case .cancelled(let reason):
            switch reason {
            case .user, .noAudio: .discardBoth
            case .micLost, .initiatorLost, .targetLost, .watchdog: .discardCoreCopy
            }
        }
    }

    private func discardCoreCheckpointUnlessFailed(sessionId: SessionID, outcome: SessionOutcome) {
        switch Self.checkpointFate(for: outcome) {
        case .keep: break
        case .discardCoreCopy: durableTranscriber.discardCoreCopy(sessionId: sessionId)
        case .discardBoth: durableTranscriber.discardCheckpoint(sessionId: sessionId)
        }
    }

    /// Records a session's terminal outcome into the ring
    /// buffer, oldest-evicted-first. Idempotent per session — the effect
    /// this is called from (`.send` broadcasting `sessionState(idle,
    /// outcome:)`) fans out to every connected edge, so this would
    /// otherwise be called once per edge for the same outcome; an existing
    /// entry for `sessionId` is replaced rather than duplicated.
    private func recordSessionOutcome(sessionId: SessionID, outcome: SessionOutcome) {
        onSessionFinished?(sessionId)
        recentSessionOutcomes.removeAll { $0.sessionId == sessionId }
        recentSessionOutcomes.append((sessionId, outcome))
        if recentSessionOutcomes.count > Self.sessionOutcomeHistoryLimit {
            recentSessionOutcomes.removeFirst(recentSessionOutcomes.count - Self.sessionOutcomeHistoryLimit)
        }
    }

    /// Answers an `EdgeMessage.sessionOutcomeQuery` with
    /// whichever of `sessionIds` this Core still remembers the outcome of —
    /// an id with no match (still in flight, or aged out of the ring
    /// buffer) is simply omitted; the asking Edge leaves that checkpoint
    /// alone rather than treating "no answer" as "safe to delete."
    private func handleSessionOutcomeQuery(sessionIds: [SessionID], from edgeId: EdgeID) {
        let wanted = Set(sessionIds)
        var outcomes: [SessionID: SessionOutcome] = [:]
        for entry in recentSessionOutcomes where wanted.contains(entry.sessionId) {
            outcomes[entry.sessionId] = entry.outcome
        }
        sendToEdge(edgeId, .sessionOutcomes(outcomes))
    }

    private func sendToEdge(_ edgeId: EdgeID, _ message: CoreMessage) {
        if let localEdge, localEdge.edgeId == edgeId {
            localEdge.deliver(message)
        } else {
            sendToRemoteEdge(message, edgeId)
        }
    }

    // MARK: - New Macs joining (Add a Mac)

    /// This Mac's name, shown to a Mac that's joining.
    var coreName = ""
    /// While set and in the future, Macs may ask to join (Add a Mac is open).
    private(set) var acceptingNewMacsUntil: Date?
    /// A Mac asking to join, waiting for the user to compare codes.
    private(set) var pendingJoin: CoreServer.PairRequest?
    @ObservationIgnored private let advertiser = SetupAdvertiser()

    /// Opens (or, with nil, closes) the window in which other Macs may ask
    /// to join, and announces this Mac on the local network meanwhile.
    func acceptNewMacs(for duration: TimeInterval?) {
        acceptingNewMacsUntil = duration.map { Date().addingTimeInterval($0) }
        server?.acceptNewMacs(until: acceptingNewMacsUntil)
        if duration != nil, let address = TailscaleInterface.currentAddress() {
            advertiser.start(name: coreName, tailscaleIP: address)
        } else {
            advertiser.stop()
            if let pendingJoin { server?.answerPairRequest(pendingJoin.id, approve: false) }
            pendingJoin = nil
        }
    }

    func answerJoin(approve: Bool) {
        guard let pendingJoin else { return }
        server?.answerPairRequest(pendingJoin.id, approve: approve)
        self.pendingJoin = nil
    }

    // MARK: - Work on another Mac (cleanup, model downloads)

    private var cleanupWaiters: [String: CheckedContinuation<String, Error>] = [:]
    private var speechWaiters: [String: CheckedContinuation<String, Error>] = [:]

    /// Turns `audio` (float32 LE PCM) into text with `model` on a Mac in
    /// the setup — this Mac's own engine directly, another Mac's over its
    /// connection.
    func runSpeech(on edgeId: EdgeID, model: String, audio: Data, sampleRate: Int, languages: [String], vocabulary: [String],
                   timeout: TimeInterval = 90) async throws -> String {
        if edgeId == localEdge?.edgeId {
            let samples = audio.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return try await LocalSpeechService.shared.transcribe(model, samples: samples, languages: languages, vocabulary: vocabulary)
        }
        guard broker.edges[edgeId] != nil, let server else { throw RemoteWorkError.notConnected }
        let job = SpeechJob(requestId: UUID().uuidString, model: model, languages: languages, vocabulary: vocabulary,
                            sampleRate: sampleRate, byteCount: audio.count)
        return try await withCheckedThrowingContinuation { continuation in
            speechWaiters[job.requestId] = continuation
            server.send(.speechRequest(job), to: edgeId)
            server.sendBinary(audio, to: edgeId)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finishSpeech(requestId: job.requestId, text: nil, error: nil, timedOut: true)
            }
        }
    }

    private func finishSpeech(requestId: String, text: String?, error: String?, timedOut: Bool = false) {
        guard let waiter = speechWaiters.removeValue(forKey: requestId) else { return }
        if let text {
            waiter.resume(returning: text)
        } else if timedOut {
            waiter.resume(throwing: RemoteWorkError.timedOut)
        } else {
            waiter.resume(throwing: RemoteWorkError.failed(error ?? "The recording wasn’t turned into text."))
        }
    }
    private var pullObservers: [String: (ModelPullProgress) -> Void] = [:]

    enum RemoteWorkError: Error, LocalizedError {
        case notConnected
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: "That Mac isn’t connected."
            case .timedOut: "That Mac didn’t answer in time."
            case .failed(let message): message
            }
        }
    }

    /// Runs a cleanup on another Mac's Ollama (or this Mac's, through the
    /// local edge) and returns the model's output.
    func runCleanup(on edgeId: EdgeID, job: CleanupJob, timeout: TimeInterval = 25) async throws -> String {
        guard broker.edges[edgeId] != nil else { throw RemoteWorkError.notConnected }
        let requestId = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            cleanupWaiters[requestId] = continuation
            sendToEdge(edgeId, .cleanupRequest(requestId: requestId, job: job))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finishCleanup(requestId: requestId, output: nil, error: nil, timedOut: true)
            }
        }
    }

    private func finishCleanup(requestId: String, output: String?, error: String?, timedOut: Bool = false) {
        guard let waiter = cleanupWaiters.removeValue(forKey: requestId) else { return }
        if let output {
            waiter.resume(returning: output)
        } else if timedOut {
            waiter.resume(throwing: RemoteWorkError.timedOut)
        } else {
            waiter.resume(throwing: RemoteWorkError.failed(error ?? "The cleanup didn’t run."))
        }
    }

    /// Starts a model download on another Mac (or this one); `onProgress`
    /// is called on the main actor until it's done or fails.
    func pullModel(on edgeId: EdgeID, model: String, onProgress: @escaping (ModelPullProgress) -> Void) throws {
        guard broker.edges[edgeId] != nil else { throw RemoteWorkError.notConnected }
        let requestId = UUID().uuidString
        pullObservers[requestId] = onProgress
        sendToEdge(edgeId, .modelPull(requestId: requestId, model: model))
    }

    // MARK: - Repo requests

    /// Answers a `.repoRequest` from a remote edge directly against
    /// `repoServer`, bypassing `SessionBroker`/`apply` entirely, and sends
    /// the matching `.repoResponse` straight back to that edge. Factored
    /// out of `server.onMessage` (rather than inlined) so `CoreHostTests`
    /// can drive it directly — with `remoteEdgeSendOverride` standing in
    /// for a live `CoreServer` — without a real socket.
    func handleRepoRequest(id: String, request: RepoRequest, from edgeId: EdgeID) {
        Task { [weak self] in
            guard let self else { return }
            self.repoServer.onCorrection = self.onCorrection
            let result = await self.repoServer.handle(request)
            self.sendToRemoteEdge(.repoResponse(requestId: id, result: result), edgeId)
        }
    }

    /// Teach on this Mac: the same function a remote Mac's request uses.
    func transcribeForTeach(header: AudioTakeHeader, audio: Data) async throws -> String {
        guard let transcribeRaw else { throw RemoteWorkError.failed("This Mac can’t turn speech into text right now.") }
        return try await transcribeRaw(header, audio)
    }

    /// Shortcuts on this Mac: dictionary replacements, then (when `useAI`)
    /// the chosen clean-up model. The same function a remote Mac's request uses.
    func cleanUpTextForShortcuts(_ text: String, useAI: Bool) async throws -> String {
        guard let cleanUpText else { throw RemoteWorkError.failed("This Mac can’t clean up text right now.") }
        return try await cleanUpText(text, useAI)
    }

    /// Answers a connected Mac's request to clean up text. Nothing is saved.
    func handleTextCleanupRequest(requestId: String, text: String, useAI: Bool, from edgeId: EdgeID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let cleaned = try await self.cleanUpTextForShortcuts(text, useAI: useAI)
                self.sendToRemoteEdge(.textCleanupResult(requestId: requestId, text: cleaned, error: nil), edgeId)
            } catch {
                self.sendToRemoteEdge(.textCleanupResult(requestId: requestId, text: nil, error: error.localizedDescription), edgeId)
            }
        }
    }

    /// Answers a connected Mac's Teach recording. The audio is kept nowhere.
    func handleTranscribeRequest(requestId: String, header: AudioTakeHeader, audio: Data, from edgeId: EdgeID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.transcribeForTeach(header: header, audio: audio)
                self.sendToRemoteEdge(.transcribeResult(requestId: requestId, text: text, error: nil), edgeId)
            } catch {
                self.sendToRemoteEdge(.transcribeResult(requestId: requestId, text: nil, error: error.localizedDescription), edgeId)
            }
        }
    }

    /// Sends `.repoChanged(change)` to every remote edge. The local edge
    /// (if attached) doesn't need it: its own UI reads this same local
    /// bundle directly through `RepositoryHub`, which already observes it.
    /// Called by `DictatorViewModel` whenever the local bundle changes (a
    /// remote edge's mutation landed via `handleRepoRequest` above, this
    /// Core's own dictation, or a local Settings edit) — see its
    /// repository wiring.
    func broadcastRepoChanged(_ change: RepoChange) {
        if let remoteBroadcastOverride {
            remoteBroadcastOverride(.repoChanged(change))
        } else {
            server?.broadcast(.repoChanged(change))
        }
    }

    // MARK: - Workspace launch across Macs

    /// One Mac's answer to `workspaceCapture` or `workspaceRun`; nil when it didn't answer in time.
    enum WorkspaceAnswer: Equatable {
        case capture(macID: String?, layout: WorkspaceSavedLayout?, error: String?)
        case run(summary: String, failure: String?, counts: WorkspaceRunCounts?)
    }
    private var workspaceWaiters: [String: CheckedContinuation<WorkspaceAnswer?, Never>] = [:]
    /// The Mac this host runs on, as the broker knows it (nil before it attaches).
    var localEdgeID: EdgeID? { localEdge?.edgeId }

    /// Returns true when `message` belongs to Workspace launch and was handled here.
    private func handleWorkspaceMessage(_ message: EdgeMessage, from edgeId: EdgeID) -> Bool {
        switch message {
        case .workspaceCaptureResult(let requestId, let macID, let layout, let error):
            finishWorkspace(requestId, .capture(macID: macID, layout: layout, error: error))
        case .workspaceRunResult(let requestId, let summary, let failure, let counts):
            finishWorkspace(requestId, .run(summary: summary, failure: failure, counts: counts))
        case .workspaceRememberAll(let requestId):
            Task { @MainActor in
                let result = await self.rememberWorkspaceEverywhere()
                self.sendToEdge(edgeId, .workspaceRemembered(requestId: requestId, layouts: result.layouts, unanswered: result.unanswered, busy: result.busy))
            }
        case .workspaceRunAll(let requestId, let routineID, let undo, let operationID):
            Task { @MainActor in
                let reports = await self.runWorkspaceRoutine(routineID, undo: undo, operationID: operationID, except: edgeId)
                self.sendToEdge(edgeId, .workspaceRunReport(requestId: requestId, reports: reports))
            }
        default:
            return false
        }
        return true
    }

    /// Asks every connected Mac, this one included, to remember where its
    /// windows are. Macs that fail or don't answer within `timeout` are named.
    func rememberWorkspaceEverywhere(timeout: TimeInterval = 8) async -> (layouts: [String: WorkspaceSavedLayout], unanswered: [String], busy: [String]) {
        let edges = Array(broker.edges.values)
        var layouts: [String: WorkspaceSavedLayout] = [:], unanswered: [String] = [], busy: [String] = []
        let answers = await askEdges(edges, timeout: timeout) { .workspaceCapture(requestId: $0) }
        for (edge, answer) in answers {
            if case .capture(_, _, let error)? = answer, error == WorkspaceLaunchController.captureBusyMessage {
                busy.append(edge.name)
            } else if case .capture(let macID?, let layout?, _)? = answer {
                layouts[macID] = layout
            } else { unanswered.append(edge.name) }
        }
        return (layouts, unanswered.sorted(), busy.sorted())
    }

    /// Asks every connected Mac except `except` to run (or undo) a routine on
    /// its own windows. Macs with nothing to do for it answer with an empty
    /// line and are left out of the reports.
    func runWorkspaceRoutine(_ routineID: String, undo: Bool, operationID: String? = nil, except: EdgeID?, timeout: TimeInterval = VoiceLaunchReadiness.workspaceRunBudget) async -> [WorkspaceRunReport] {
        let edges = broker.edges.values.filter { $0.id != except }
        let from = except.flatMap { broker.edges[$0]?.name } ?? coreName
        let answers = await askEdges(Array(edges), timeout: timeout) { .workspaceRun(requestId: $0, routineID: routineID, undo: undo, from: from, operationID: operationID) }
        return answers.compactMap { edge, answer in
            switch answer {
            case .run(let summary, let failure, let counts)?: summary.isEmpty && failure == nil ? nil : WorkspaceRunReport(macName: edge.name, summary: summary, failure: failure, counts: counts)
            default: WorkspaceRunReport(macName: edge.name, summary: "didn't answer in time.", failure: "didn't answer in time.")
            }
        }.sorted { $0.macName < $1.macName }
    }

    private func askEdges(_ edges: [BrokerEdgeInfo], timeout: TimeInterval,
                          _ message: @escaping (String) -> CoreMessage) async -> [(BrokerEdgeInfo, WorkspaceAnswer?)] {
        await withTaskGroup(of: (BrokerEdgeInfo, WorkspaceAnswer?).self) { group in
            for edge in edges {
                group.addTask { @MainActor in (edge, await self.askEdge(edge.id, timeout: timeout, message)) }
            }
            var results: [(BrokerEdgeInfo, WorkspaceAnswer?)] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    private func askEdge(_ edgeId: EdgeID, timeout: TimeInterval, _ message: (String) -> CoreMessage) async -> WorkspaceAnswer? {
        let requestId = UUID().uuidString
        return await withCheckedContinuation { continuation in
            workspaceWaiters[requestId] = continuation
            sendToEdge(edgeId, message(requestId))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finishWorkspace(requestId, nil)
            }
        }
    }

    private func finishWorkspace(_ requestId: String, _ answer: WorkspaceAnswer?) {
        workspaceWaiters.removeValue(forKey: requestId)?.resume(returning: answer)
    }

    private func sendToRemoteEdge(_ message: CoreMessage, _ edgeId: EdgeID) {
        if let remoteEdgeSendOverride {
            remoteEdgeSendOverride(message, edgeId)
        } else {
            server?.send(message, to: edgeId)
        }
    }

    private func startTranscription(sessionId: SessionID, header: AudioTakeHeader, data: Data) {
        // Persisted before the transcription task even
        // starts — synchronous, so a crash the instant after this returns
        // still has the audio on disk. `edgeName` is best-effort (the mic
        // owner's display name, for the recovery UI's "machine" column).
        let edgeName = connectedEdges.first(where: { $0.id == session?.micOwner })?.name ?? session?.micOwner ?? "unknown"
        durableTranscriber.persistReceivedTake(sessionId: sessionId, header: header, data: data, edgeName: edgeName)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.durableTranscriber.transcribe(sessionId: sessionId, header: header, data: data)
                self.transcriptionTasks[sessionId] = nil
                guard !Task.isCancelled, self.broker.session?.id == sessionId else { return }
                self.onHeardText?(sessionId, result.rawText ?? result.text)
                var text = result.text
                if let resolve = self.resolveVoiceCommand, self.broker.session?.id == sessionId, self.broker.session?.voiceCommandMode == true,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let resolved = await resolve(sessionId, text)
                    guard !Task.isCancelled else { return }
                    text = resolved.text
                    if let plan = resolved.plan {
                        self.broker.attachLaunch(plan, sessionId: sessionId)
                    } else {
                        self.broker.attachVoiceCommand(VoiceCommandDelivery(text: resolved.text, notice: resolved.notice, nearMiss: resolved.nearMiss), sessionId: sessionId)
                    }
                }
                self.apply(.transcriptionFinished(sessionId, text: text, inferenceMs: result.inferenceMs, error: nil))
            } catch {
                self.transcriptionTasks[sessionId] = nil
                // A cancelled transcribe (Esc during processing, or a
                // listener/edge going away) already sent the broker to idle
                // via `.cancelTranscription` — reporting it as a failure
                // here would resurrect a session that no longer exists.
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return
                }
                // The checkpoint was kept (marked `.failed` by
                // `durableTranscriber.transcribe`) — tell the user so.
                let message = error is DictationFailure
                    ? error.localizedDescription
                    : "\(error.localizedDescription) What you said is kept in History & Privacy, to turn into text later."
                self.apply(.transcriptionFinished(sessionId, text: nil, inferenceMs: nil, error: message))
            }
        }
        transcriptionTasks[sessionId] = task
    }

    private func scheduleWatchdog(sessionId: SessionID, duration: TimeInterval) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            self.watchdogTasks[sessionId] = nil
            self.apply(.watchdogFired(sessionId))
        }
        watchdogTasks[sessionId] = task
    }

    private func scheduleCountdown(sessionId: SessionID, delay: TimeInterval) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.countdownTasks[sessionId] = nil
            self.apply(.countdownFired(sessionId))
        }
        countdownTasks[sessionId] = task
    }

    /// Mirrors `scheduleWatchdog` above, on the much shorter
    /// `SessionBroker.releaseGrace` fuse: a cancellable `Task` per session,
    /// delivering `.releaseGraceFired` back into `apply` if it isn't
    /// cancelled first (a re-press within the window emits
    /// `.cancelReleaseGrace`, same shape as `.cancelWatchdog`).
    private func scheduleReleaseGrace(sessionId: SessionID, duration: TimeInterval) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            self.releaseGraceTasks[sessionId] = nil
            self.apply(.releaseGraceFired(sessionId))
        }
        releaseGraceTasks[sessionId] = task
    }

    private func schedulePressSettle(id: PressID, duration: TimeInterval) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            self.pressSettleTasks[id] = nil
            self.apply(.pressSettled(id))
        }
        pressSettleTasks[id] = task
    }

    // MARK: - Test-only seams

    /// Lets `CoreHostTests` populate the ring buffer directly
    /// (to test eviction past `sessionOutcomeHistoryLimit`) without driving
    /// 51 full session flows.
    func recordSessionOutcomeForTesting(sessionId: SessionID, outcome: SessionOutcome) {
        recordSessionOutcome(sessionId: sessionId, outcome: outcome)
    }

    var recentSessionOutcomeCountForTesting: Int { recentSessionOutcomes.count }
}
