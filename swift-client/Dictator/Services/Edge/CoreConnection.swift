import Foundation

/// Edge-side WebSocket client that connects out to the Dictator Core.
///
/// `ws://` only, no TLS: Tailscale/WireGuard already authenticates and
/// encrypts the tunnel this runs over, so a second TLS layer here would only
/// add certificate management without adding security — see the matching
/// note on `CoreServer`.
final class CoreConnection: NSObject {
    private static let backoffSteps: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    private let url: URL
    private let edgeId: EdgeID
    private let name: String
    private var token: String
    private let credentialAddress: String
    /// If set, `welcome.coreId` must match this exactly or the connection is
    /// torn down and not retried automatically — see `isPinnedMismatch`.
    private var expectedCoreId: String?

    private let queue = DispatchQueue(label: "dev.noamlitt.dictator.core-connection")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    private var shouldRun = false
    private var handshakeComplete = false
    private var reconnectAttempt = 0
    private var lastActivity = Date.distantPast {
        didSet { lastActivityShared = lastActivity }
    }
    private var _lastActivityShared = Date.distantPast
    /// When this connection last heard from (or successfully opened a socket
    /// to) the Core — read by the coordinator's liveness check, from any
    /// thread.
    private(set) var lastActivityShared: Date {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastActivityShared }
        set { stateLock.lock(); _lastActivityShared = newValue; stateLock.unlock() }
    }
    /// Bumped on every `connect()`/`disconnect()`/reconnect attempt so a
    /// stale socket's delegate or receive callbacks can't act on state that
    /// belongs to a newer (or no longer running) attempt.
    private var generation = 0
    /// Reset at the start of every connection attempt; set the first time
    /// this attempt reports a drop. Guards `onDisconnected` against firing
    /// twice when a delegate close/error callback and a receive-loop error
    /// both observe the same underlying failure.
    private var didFireDisconnectForCurrentAttempt = false

    private var reconnectWorkItem: DispatchWorkItem?
    private var pingWorkItem: DispatchWorkItem?
    private var watchdogWorkItem: DispatchWorkItem?

    private let stateLock = NSLock()
    private var _isConnected = false
    private(set) var isConnected: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isConnected }
        set { stateLock.lock(); _isConnected = newValue; stateLock.unlock() }
    }
    private var _capabilities: EdgeCapabilities
    /// The capabilities `hello` (and, after a change, a follow-up `caps`
    /// frame) advertise. Guarded by `stateLock` — unlike the old
    /// `() -> EdgeCapabilities` closure, `updateCapabilities` can be called
    /// from any thread and never reaches back into `EdgeRuntime` itself;
    /// callers snapshot a value and hand it over.
    private var capabilities: EdgeCapabilities {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _capabilities }
        set { stateLock.lock(); _capabilities = newValue; stateLock.unlock() }
    }
    /// True once a `welcome` arrived with a `coreId` that didn't match
    /// `expectedCoreId`. The one `onDisconnected` for that drop already
    /// carries "core identity changed" as its reason; this flag is for
    /// callers that want to distinguish "stopped, pinning mismatch" from an
    /// ordinary drop without string-matching the reason.
    private(set) var isPinnedMismatch = false
    static let pairingRequiredMessage = "This Mac can no longer connect to the main Mac. Open Settings › Your Macs › Add a Mac on the main Mac and add this Mac again. History already on this Mac stays here."
    static let credentialSaveFailedMessage = "This Mac couldn’t save its new connection details. Check access to Dictator’s files, then open Settings › Your Macs › Add a Mac on the main Mac and add this Mac again. History already on this Mac stays here."
    private var _requiresPairing = false
    private(set) var requiresPairing: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _requiresPairing }
        set { stateLock.lock(); _requiresPairing = newValue; stateLock.unlock() }
    }

    var onConnected: ((_ coreId: String, _ micOwner: EdgeID?) -> Void)?
    var onDisconnected: ((String?) -> Void)?
    var onMessage: ((CoreMessage) -> Void)?

    /// `RepoTransport` backing for `CoreSyncClient` while this Edge is
    /// connected — `repo.request`/`repo.response` ride the same
    /// `EdgeMessage`/`CoreMessage` wire path as everything else, correlated
    /// by requestId. `@MainActor`, unlike the rest of this class (which runs
    /// on `queue`): `RepoTransport` itself is `@MainActor`, and this is only
    /// ever touched from the main-thread callbacks below (`handleIncoming`,
    /// `failPendingRepoRequests`), never from `queue` — see the
    /// `RepoTransport` conformance near the bottom of this file.
    /// `repo.changed` frames are forwarded through `onMessage` like every
    /// other frame; the coordinator hands them to the sync engine.
    @MainActor private var repoCorrelator = RepoRequestCorrelator()
    @MainActor private var transcribeWaiters: [String: CheckedContinuation<String, Error>] = [:]
    @MainActor private var cleanupTextWaiters: [String: CheckedContinuation<String, Error>] = [:]
    @MainActor fileprivate var workspaceWaiters: [String: CheckedContinuation<CoreMessage, Error>] = [:]

    /// Test-only seam: invoked on `queue`, right after `sendAudio`'s header
    /// frame finishes sending and before the identity guard that decides
    /// whether the paired binary frame goes out. Lets tests force the "a
    /// reconnect landed between the header and the binary send" race
    /// deterministically rather than relying on real network timing. Never
    /// set outside `DictatorTests`.
    var testHookAfterHeaderSent: (() -> Void)?

    init(
        url: URL,
        edgeId: EdgeID,
        name: String,
        token: String,
        capabilities: EdgeCapabilities,
        expectedCoreId: String? = nil,
        credentialAddress: String? = nil
    ) {
        self.url = url
        self.edgeId = edgeId
        self.name = name
        self.token = token
        self.credentialAddress = credentialAddress ?? (url.host ?? "") + (url.port.map { ":\($0)" } ?? "")
        self._capabilities = capabilities
        self.expectedCoreId = expectedCoreId
        super.init()
    }

    /// Test-only: swaps in a `RepoRequestCorrelator` with a shorter timeout
    /// so `CoreServerLoopbackTests` doesn't have to wait out the real 10s
    /// default to exercise the "Core never replied" path. Must be called
    /// before any `send(_ request: RepoRequest)` whose timeout it's meant
    /// to shorten. Never called outside `DictatorTests`.
    @MainActor
    func setRepoRequestTimeoutForTesting(_ timeout: TimeInterval) {
        repoCorrelator = RepoRequestCorrelator(timeout: timeout)
    }

    // MARK: - Public API

    /// Idempotent: a second call while already running is a no-op. Starts
    /// (or resumes) the reconnect loop with backoff 1, 2, 4, 8, 16, 30, 30…s.
    func connect() {
        queue.async { [weak self] in
            guard let self, !self.shouldRun, !self.requiresPairing else { return }
            self.shouldRun = true
            self.isPinnedMismatch = false
            self.reconnectAttempt = 0
            self.openSocket()
        }
    }

    /// Stops the reconnect loop and tears down any live socket. Does not
    /// fire `onDisconnected` — this is a deliberate, caller-initiated stop.
    func disconnect() {
        queue.async { [weak self] in
            guard let self, self.shouldRun else { return }
            self.shouldRun = false
            self.generation += 1
            self.cancelTimers()
            self.handshakeComplete = false
            self.isConnected = false
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
            // Break the URLSession <-> delegate retain cycle explicitly
            // rather than waiting for a future `openSocket()` that may
            // never come.
            self.session?.invalidateAndCancel()
            self.session = nil
            self.failPendingRepoRequests()
        }
    }

    /// Queues `message` for the main Mac. Returns false, and sends nothing,
    /// when there is no live handshaken socket right now. A send that is
    /// accepted here can still fail (the socket dropped before the queued
    /// write ran, or the write itself errored): `onFailure` then runs on the
    /// main thread, so the caller can tell the user instead of the frame vanishing.
    @discardableResult
    func send(_ message: EdgeMessage, onFailure: (() -> Void)? = nil) -> Bool {
        guard isConnected else { return false }
        queue.async { [weak self] in
            guard let self, self.handshakeComplete, let task = self.task else {
                Self.report(onFailure)
                return
            }
            self.sendRaw(message, on: task, onFailure: onFailure)
        }
        return true
    }

    private static func report(_ onFailure: (() -> Void)?) {
        guard let onFailure else { return }
        DispatchQueue.main.async(execute: onFailure)
    }

    /// How long without hearing anything from the main Mac before a new
    /// dictation stops trusting the link. One ping goes out every
    /// `pingInterval` and the pong comes back in milliseconds, so silence
    /// longer than 1.5 intervals means a ping has already gone unanswered,
    /// while the full drop (2 intervals) hasn't been declared yet.
    static let staleAfter: TimeInterval = EdgeProtocol.pingInterval * 1.5

    /// Pure rule behind `isLive`, split out so it can be tested.
    static func isLive(connected: Bool, lastActivity: Date, now: Date, staleAfter: TimeInterval = CoreConnection.staleAfter) -> Bool {
        connected && now.timeIntervalSince(lastActivity) <= staleAfter
    }

    /// True when the socket is up and the main Mac has answered recently.
    var isLive: Bool {
        Self.isLive(connected: isConnected, lastActivity: lastActivityShared, now: Date())
    }

    /// Declares the link dead now, rather than waiting for the keepalive to
    /// notice: fires `onDisconnected` and starts reconnecting as for any drop.
    func dropAsUnreachable() {
        queue.async { [weak self] in
            self?.handleDrop(reason: "no answer from main Mac")
        }
    }

    /// Updates the capabilities `hello` will advertise on the next connect
    /// and, if a handshake is already up, sends a `caps` frame immediately
    /// so the Core's mic-owner choice never relies on a stale snapshot. Safe
    /// to call from any thread/actor.
    func updateCapabilities(_ caps: EdgeCapabilities) {
        capabilities = caps
        queue.async { [weak self] in
            guard let self, self.handshakeComplete, self.isConnected, let task = self.task else { return }
            self.sendRaw(.capabilities(caps), on: task)
        }
    }

    /// Sends the header as a text frame, waits for it to be accepted by the
    /// socket, then sends exactly one binary frame — matching the ordering
    /// the Core's receive loop requires. The task is captured once, up
    /// front, for both sends: if a reconnect replaces `self.task` while the
    /// header send is still in flight, the binary frame is dropped rather
    /// than landing headerless on a brand-new socket.
    /// Returns false, and sends nothing, when the socket isn't up.
    /// `onFailure` runs on the main thread if the header or the audio can't
    /// be written (see `send`).
    @discardableResult
    func sendAudio(header: AudioTakeHeader, data: Data, onFailure: (() -> Void)? = nil) -> Bool {
        guard isConnected else { return false }
        sendFramed(.audioTake(header), data: data, onFailure: onFailure)
        return true
    }

    private func sendFramed(_ message: EdgeMessage, data: Data, onFailure: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, let capturedTask = self.task else { Self.report(onFailure); return }
            guard let headerData = try? EdgeProtocolCodec.encode(message),
                  let headerText = String(data: headerData, encoding: .utf8) else { Self.report(onFailure); return }
            capturedTask.send(.string(headerText)) { [weak self] error in
                guard error == nil else { Self.report(onFailure); return }
                self?.queue.async {
                    guard let self else { Self.report(onFailure); return }
                    self.testHookAfterHeaderSent?()
                    guard self.task === capturedTask else {
                        HotkeyService.recordDiagnostics("edge: dropping audio frame, socket replaced after its header was sent")
                        Self.report(onFailure)
                        return
                    }
                    capturedTask.send(.data(data)) { error in
                        if error != nil { Self.report(onFailure) }
                    }
                }
            }
        }
    }

    /// Test-only: gives `testHookAfterHeaderSent` a safe way (already on
    /// `queue` when called from there) to make `sendAudio`'s identity guard
    /// fail, simulating a reconnect landing between the header and binary
    /// sends without needing to win a real network race.
    func sendPingNowForTesting() {
        if let task { sendRaw(.ping, on: task) }
    }

    func forceTaskReplacementForTesting() {
        task = nil
    }

    // MARK: - Connection lifecycle (all on `queue`)

    private func openSocket() {
        guard shouldRun else { return }
        generation += 1
        let myGeneration = generation
        handshakeComplete = false
        didFireDisconnectForCurrentAttempt = false
        lastActivity = Date()

        // A fresh `URLSession` per attempt: the session retains its delegate
        // (us), so leaving a stale, unused session around after a replaced
        // task is a retain cycle. Invalidating the old one here — not only
        // in `disconnect()` — means every reconnect takes its old session
        // down with it.
        session?.invalidateAndCancel()
        let newSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = newSession

        let newTask = newSession.webSocketTask(with: url)
        newTask.maximumMessageSize = EdgeProtocol.maxBinaryFrameBytes
        task = newTask
        newTask.resume()
        receiveNext(task: newTask, generation: myGeneration)
    }

    private func sendHello() {
        guard shouldRun, let task else { return }
        sendRaw(.hello(edgeId: edgeId, name: name, token: token, caps: capabilities), on: task)
    }

    /// Protocol text frames must ride as WebSocket *text* frames (`.string`),
    /// matching the Core, which sends with `NWProtocolWebSocket.Metadata(opcode: .text)`
    /// — only the raw audio payload after an `audio.take` header is `.data`.
    private func sendRaw(_ message: EdgeMessage, on task: URLSessionWebSocketTask, onFailure: (() -> Void)? = nil) {
        guard let data = try? EdgeProtocolCodec.encode(message),
              let text = String(data: data, encoding: .utf8) else { Self.report(onFailure); return }
        task.send(.string(text)) { error in
            if error != nil { Self.report(onFailure) }
        }
    }

    private func receiveNext(task: URLSessionWebSocketTask, generation myGeneration: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.generation == myGeneration, self.task === task else { return }
                switch result {
                case .failure(let error):
                    self.handleDrop(reason: error.localizedDescription)
                case .success(let message):
                    self.lastActivity = Date()
                    self.handleIncoming(message)
                    self.receiveNext(task: task, generation: myGeneration)
                }
            }
        }
    }

    /// Set by a `speech.request`; the next binary frame of that size is its audio.
    private var pendingSpeechJob: SpeechJob?
    /// A recording to transcribe on this Mac (Settings › Your Macs chose
    /// one of its speech models).
    var onSpeechJob: ((SpeechJob, Data) -> Void)?

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        if case .data(let raw) = message, let job = pendingSpeechJob {
            pendingSpeechJob = nil
            if handshakeComplete, raw.count == job.byteCount {
                DispatchQueue.main.async { self.onSpeechJob?(job, raw) }
                return
            }
        }
        // The Core always sends protocol frames as WebSocket text; URLSession
        // surfaces those as `.string`, so accept that as well as `.data`
        // rather than assuming one representation.
        let data: Data
        switch message {
        case .data(let raw):
            data = raw
        case .string(let text):
            guard let raw = text.data(using: .utf8) else { return }
            data = raw
        @unknown default:
            return
        }
        let decoded: CoreMessage
        do {
            decoded = try EdgeProtocolCodec.decodeCoreMessage(data)
        } catch EdgeProtocolError.unsupportedVersion(let theirs) where !handshakeComplete {
            // The main Mac speaks another protocol version, so even its
            // welcome (or its refusal of our hello) can't be read.
            handleDrop(reason: ProtocolMismatch(peerVersion: theirs).reason)
            return
        } catch {
            return
        }

        if case .error(let code, _) = decoded, code == "auth" {
            stopForPairing(reason: Self.pairingRequiredMessage)
            return
        }

        if !handshakeComplete {
            guard case .welcome(let coreId, let micOwner, let protocolVersion) = decoded else {
                handleDrop(reason: "core did not send welcome")
                return
            }
            guard protocolVersion == EdgeProtocol.version else {
                handleDrop(reason: ProtocolMismatch(peerVersion: protocolVersion).reason)
                return
            }
            if let expectedCoreId, coreId != expectedCoreId {
                isPinnedMismatch = true
                // Report the drop like any other, but never reconnect on
                // our own — this Core is not the one we're pinned to.
                handleDrop(reason: "core identity changed", allowReconnect: false)
                shouldRun = false
                return
            }
            handshakeComplete = true
            reconnectAttempt = 0
            isConnected = true
            schedulePing()
            scheduleWatchdog()
            DispatchQueue.main.async { self.onConnected?(coreId, micOwner) }
            return
        }

        if case .pairingTokenRotated(let rotationId, let replacement) = decoded {
            do {
                try PairingCredentialStore.save(token: replacement, forCore: credentialAddress)
                token = replacement
                if let task { sendRaw(.pairingTokenSaved(rotationId: rotationId), on: task) }
            } catch {
                stopForPairing(reason: Self.credentialSaveFailedMessage)
            }
            return
        }

        if case .speechRequest(let job) = decoded {
            pendingSpeechJob = job
            return
        }
        // A pong can land between a job and its audio, so it stays pending
        // until the audio arrives or another job replaces it.

        DispatchQueue.main.async {
            // Every frame is forwarded to `onMessage` (EdgeRuntime ignores
            // the repo ones — see its own `handle(_:)`) so this stays the
            // single place that decides what's "just noise" downstream.
            self.onMessage?(decoded)
            // Already on the main thread (this whole block is
            // `DispatchQueue.main.async`), which is what backs `MainActor`
            // on Apple platforms — `assumeIsolated` documents that instead
            // of re-hopping through a `Task`.
            if case .transcribeResult(let requestId, let text, let error) = decoded {
                MainActor.assumeIsolated { self.finishTranscribe(requestId: requestId, text: text, error: error) }
            }
            if case .textCleanupResult(let requestId, let text, let error) = decoded {
                MainActor.assumeIsolated { self.finishCleanupText(requestId: requestId, text: text, error: error) }
            }
            switch decoded {
            case .workspaceRemembered(let requestId, _, _, _), .workspaceRunReport(let requestId, _):
                MainActor.assumeIsolated { self.finishWorkspace(requestId: requestId, .success(decoded)) }
            default: break
            }
            if case .repoResponse(let requestId, let result) = decoded {
                MainActor.assumeIsolated {
                    self.repoCorrelator.complete(requestId: requestId, result: result)
                }
            }
        }
    }

    private func stopForPairing(reason: String) {
        requiresPairing = true
        handleDrop(reason: reason, allowReconnect: false)
        shouldRun = false
    }

    /// Tears the current socket down and reports the drop exactly once. A
    /// delegate `didClose`/`didCompleteWithError` callback and a receive-loop
    /// failure can both observe the same underlying drop; only the first one
    /// to reach here does anything, courtesy of
    /// `didFireDisconnectForCurrentAttempt`.
    private func handleDrop(reason: String?, allowReconnect: Bool = true) {
        guard shouldRun, !didFireDisconnectForCurrentAttempt else { return }
        didFireDisconnectForCurrentAttempt = true
        cancelTimers()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        handshakeComplete = false
        isConnected = false
        // Reason only (never the token or any payload): this is the one place
        // an Edge can say why its Core is "unreachable".
        HotkeyService.recordDiagnostics("edge: dropped (\(reason ?? "no reason")) attempt=\(reconnectAttempt) url=\(url.absoluteString)")
        DispatchQueue.main.async { self.onDisconnected?(reason) }
        failPendingRepoRequests()
        if allowReconnect {
            scheduleReconnect()
        }
    }

    /// Fails every request still waiting on `repoCorrelator` — called
    /// from both a transport drop (`handleDrop`) and an explicit
    /// `disconnect()`, since either way nothing will ever complete them and
    /// a caller `await`ing `RepoTransport.send(_:)` shouldn't have to wait
    /// out the full timeout to find that out.
    private func failPendingRepoRequests() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.repoCorrelator.failAll(with: RepositoryError.unavailable("Lost the connection to your main Mac."))
                for id in Array(self.transcribeWaiters.keys) { self.finishTranscribe(requestId: id, text: nil, error: "The main Mac isn’t connected.") }
                for id in Array(self.cleanupTextWaiters.keys) { self.finishCleanupText(requestId: id, text: nil, error: "The main Mac isn’t connected.") }
                for id in Array(self.workspaceWaiters.keys) { self.finishWorkspace(requestId: id, .failure(RepositoryError.unavailable("The main Mac isn’t connected."))) }
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        let delay = Self.backoffSteps[min(reconnectAttempt, Self.backoffSteps.count - 1)]
        reconnectAttempt += 1
        let myGeneration = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun, self.generation == myGeneration else { return }
            self.openSocket()
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func schedulePing() {
        pingWorkItem?.cancel()
        let myGeneration = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == myGeneration, self.shouldRun else { return }
            self.send(.ping)
            self.schedulePing()
        }
        pingWorkItem = item
        queue.asyncAfter(deadline: .now() + EdgeProtocol.pingInterval, execute: item)
    }

    /// If nothing at all (pong or otherwise) has arrived within 2x the ping
    /// interval, the connection is considered dropped even though the
    /// socket itself hasn't told us yet.
    private func scheduleWatchdog() {
        watchdogWorkItem?.cancel()
        let myGeneration = generation
        let staleAfter = EdgeProtocol.pingInterval * 2
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == myGeneration, self.shouldRun else { return }
            if Date().timeIntervalSince(self.lastActivity) >= staleAfter {
                self.handleDrop(reason: "keepalive timeout")
            } else {
                self.scheduleWatchdog()
            }
        }
        watchdogWorkItem = item
        queue.asyncAfter(deadline: .now() + staleAfter, execute: item)
    }

    private func cancelTimers() {
        pingWorkItem?.cancel(); pingWorkItem = nil
        watchdogWorkItem?.cancel(); watchdogWorkItem = nil
        reconnectWorkItem?.cancel(); reconnectWorkItem = nil
    }
}

// MARK: - URLSessionWebSocketDelegate

extension CoreConnection: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        queue.async { [weak self] in
            guard let self, self.task === webSocketTask else { return }
            self.sendHello()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "closed(\(closeCode.rawValue))"
        queue.async { [weak self] in
            guard let self, self.task === webSocketTask else { return }
            self.handleDrop(reason: reasonString)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        queue.async { [weak self] in
            guard let self, self.task === task else { return }
            self.handleDrop(reason: error.localizedDescription)
        }
    }
}

// MARK: - Teach

extension CoreConnection {
    /// Asks the Core to turn a recording (float32 16 kHz PCM) into the words
    /// as spoken, through the same speech path dictation uses. Nothing is
    /// pasted or saved. Throws with a plain reason.
    @MainActor
    func transcribe(audio: Data, sampleRate: Int, durationSeconds: Double, timeout: TimeInterval = 60) async throws -> String {
        guard isConnected else { throw RepositoryError.unavailable("The main Mac isn’t connected.") }
        let requestId = UUID().uuidString
        let header = AudioTakeHeader(sessionId: "teach", sampleRate: sampleRate, frameCount: audio.count / 4,
                                     durationSeconds: durationSeconds, byteCount: audio.count)
        return try await withCheckedThrowingContinuation { continuation in
            transcribeWaiters[requestId] = continuation
            sendFramed(.transcribeRequest(requestId: requestId, header: header), data: audio)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finishTranscribe(requestId: requestId, text: nil, error: "The main Mac didn’t answer in time.")
            }
        }
    }

    /// Asks the Core to apply the dictionary and (when `useAI`) its clean-up
    /// model to `text`. Nothing is saved. Throws with a plain reason.
    @MainActor
    func cleanUpText(_ text: String, useAI: Bool, timeout: TimeInterval = 60) async throws -> String {
        guard isConnected else { throw RepositoryError.unavailable("The main Mac isn’t connected.") }
        let requestId = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            cleanupTextWaiters[requestId] = continuation
            send(.textCleanupRequest(requestId: requestId, text: text, useAI: useAI))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finishCleanupText(requestId: requestId, text: nil, error: "The main Mac didn’t answer in time.")
            }
        }
    }

    @MainActor
    fileprivate func finishCleanupText(requestId: String, text: String?, error: String?) {
        guard let waiter = cleanupTextWaiters.removeValue(forKey: requestId) else { return }
        if let text { waiter.resume(returning: text) }
        else { waiter.resume(throwing: RepositoryError.unavailable(error ?? "The text wasn’t cleaned up.")) }
    }

    @MainActor
    fileprivate func finishTranscribe(requestId: String, text: String?, error: String?) {
        guard let waiter = transcribeWaiters.removeValue(forKey: requestId) else { return }
        if let text { waiter.resume(returning: text) }
        else { waiter.resume(throwing: RepositoryError.unavailable(error ?? "The recording wasn’t turned into text.")) }
    }
}

// MARK: - Workspace launch across Macs

extension CoreConnection {
    /// Asks the main Mac to have every connected Mac (this one included)
    /// remember where its windows are.
    @MainActor
    func rememberWorkspaceEverywhere(timeout: TimeInterval = 15) async throws -> (layouts: [String: WorkspaceSavedLayout], unanswered: [String], busy: [String]) {
        let answer = try await askWorkspace(timeout: timeout) { .workspaceRememberAll(requestId: $0) }
        guard case .workspaceRemembered(_, let layouts, let unanswered, let busy) = answer else { throw RepositoryError.unavailable("The main Mac gave an unexpected answer.") }
        return (layouts, unanswered, busy ?? [])
    }

    /// Asks the main Mac to have every other connected Mac run (or undo) a routine.
    @MainActor
    func runWorkspaceRoutineElsewhere(_ routineID: String, undo: Bool, operationID: String? = nil, timeout: TimeInterval = VoiceLaunchReadiness.workspaceRunBudget) async throws -> [WorkspaceRunReport] {
        let answer = try await askWorkspace(timeout: timeout) { .workspaceRunAll(requestId: $0, routineID: routineID, undo: undo, operationID: operationID) }
        guard case .workspaceRunReport(_, let reports) = answer else { throw RepositoryError.unavailable("The main Mac gave an unexpected answer.") }
        return reports
    }

    @MainActor
    private func askWorkspace(timeout: TimeInterval, _ message: (String) -> EdgeMessage) async throws -> CoreMessage {
        guard isConnected else { throw RepositoryError.unavailable("The main Mac isn’t connected.") }
        let requestId = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            workspaceWaiters[requestId] = continuation
            send(message(requestId))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finishWorkspace(requestId: requestId, .failure(RepositoryError.unavailable("The main Mac didn’t answer in time.")))
            }
        }
    }

    @MainActor
    fileprivate func finishWorkspace(requestId: String, _ result: Result<CoreMessage, Error>) {
        workspaceWaiters.removeValue(forKey: requestId)?.resume(with: result)
    }
}

// MARK: - RepoTransport

extension CoreConnection: RepoTransport {
    /// Sends `request` over the same `EdgeMessage.repoRequest` path as
    /// every other frame and awaits the matching `repo.response` via
    /// `repoCorrelator` — see `handleIncoming` above for where the reply
    /// resolves it, and `failPendingRepoRequests` for how a lost connection
    /// fails it early instead of waiting out the full timeout.
    @MainActor
    func send(_ request: RepoRequest) async throws -> RepoResult {
        guard isConnected else {
            throw RepositoryError.unavailable("Lost the connection to your main Mac.")
        }
        let (id, task) = repoCorrelator.begin()
        send(.repoRequest(id: id, request: request))
        return try await task.value
    }
}

// MARK: - Version mismatch

/// Which Mac has the older Dictator when the two disagree on the protocol
/// version. Carried as the drop reason, so the app can say which Mac to update.
enum ProtocolMismatch: Equatable {
    case mainMacOlder
    case thisMacOlder

    static let mainMacOlderReason = "protocol version: main Mac is older"
    static let thisMacOlderReason = "protocol version: this Mac is older"

    init(peerVersion: Int, ownVersion: Int = EdgeProtocol.version) {
        self = peerVersion < ownVersion ? .mainMacOlder : .thisMacOlder
    }

    init?(reason: String?) {
        switch reason {
        case Self.mainMacOlderReason: self = .mainMacOlder
        case Self.thisMacOlderReason: self = .thisMacOlder
        default: return nil
        }
    }

    var reason: String {
        self == .mainMacOlder ? Self.mainMacOlderReason : Self.thisMacOlderReason
    }

    /// What Settings says when the main Mac can't be used until one Mac is updated.
    func updateMessage(mainMacName: String) -> String {
        let place = self == .mainMacOlder ? mainMacName : "this Mac"
        return "Update Dictator on \(place). Dictation works on this Mac on its own until then."
    }
}
