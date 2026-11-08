import Foundation
import Network

/// WebSocket listener run by the Dictator Core: one `NWConnection` per Edge,
/// gated behind a `hello` handshake, fanning `EdgeMessage`s (and the audio
/// binary frame that follows an `audio.take` header) up to a host — normally
/// `SessionBroker` — and carrying `CoreMessage`s back down.
///
/// `ws://` only, no TLS: the only peers ever allowed in are Tailscale nodes
/// (100.64.0.0/10 — see `isTailscalePeer`), and Tailscale/WireGuard already
/// authenticates and encrypts that tunnel end to end. A second TLS layer on
/// top would add certificate management with no additional protection for
/// this transport, so v1 skips it.
final class CoreServer {
    private enum Health {
        case stopped
        case starting
        case ready
        case failed
    }

    /// Bookkeeping for one accepted connection, pre- or post-handshake.
    private final class EdgeConnection {
        let uuid = UUID()
        let connection: NWConnection
        var edgeId: EdgeID?
        var info: BrokerEdgeInfo?
        var authenticated = false
        /// Set by an `audio.take` header, cleared by any other text frame or
        /// once the matching binary frame has been consumed — enforces that
        /// a binary frame is only ever accepted right after its header.
        var pendingAudioHeader: AudioTakeHeader?
        /// Set with `pendingAudioHeader` by a `transcribe.request`: the next
        /// binary frame is a Teach recording to transcribe, not a session's.
        var pendingTranscribeId: String?
        var helloTimeout: DispatchWorkItem?
        /// Last frame of any kind received from this connection — the
        /// idle sweep drops authenticated edges quiet past
        /// `EdgeProtocol.edgeIdleTimeout`.
        var lastActivity = Date()
        /// Set right before disconnecting the old side of an id-replacement
        /// so a later state callback for this same connection (its own
        /// `.cancelled`, triggered by our own `connection.cancel()`) can
        /// never emit a second `onEdgeDisconnected` for the id it just lost.
        var replaced = false
        /// Set while this connection is a Mac asking to join (`pair.request`)
        /// and waiting for the user to confirm the code on this Mac.
        var pairCode: String?
        var pairTimeout: DispatchWorkItem?
        var pendingTokenRotation: String?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    /// Total tracked connections (pending handshake + authenticated) allowed
    /// at once — well above `EdgeProtocol.maxEdges` so a burst of legitimate
    /// reconnects never gets starved by the cap, but still bounded so a
    /// tailnet peer that opens sockets and withholds `hello` can't exhaust
    /// memory/timers.
    static let maxPendingConnections = EdgeProtocol.maxEdges * 2

    private let coreId: String
    /// Accessed only on queue, including hello validation and rotation.
    private var token: String
    private let rotateToken: () throws -> String
    private let bindHost: String
    private let port: UInt16
    private let allowPeer: (String) -> Bool
    /// Lets the host (`CoreHost`) veto ids it already owns out-of-band —
    /// namely its own local Edge's id — so a remote peer can't claim it.
    /// Defaults to permitting everything for callers (and tests) that don't
    /// have such a reservation.
    private let isEdgeIdReserved: (EdgeID) -> Bool

    private let queue = DispatchQueue(label: "dev.noamlitt.dictator.core-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var idleSweep: DispatchWorkItem?
    /// Test-only: shortens `EdgeProtocol.edgeIdleTimeout` and the sweep
    /// cadence so the idle drop can be observed without waiting 30 s.
    var idleTimeoutOverride: TimeInterval?
    private var health: Health = .stopped
    /// Every accepted connection, authenticated or not, keyed by its own uuid.
    private var connections: [UUID: EdgeConnection] = [:]
    /// Authenticated edges only, keyed by their protocol-level `EdgeID`.
    private var edgesByID: [EdgeID: UUID] = [:]

    var onEdgeConnected: ((BrokerEdgeInfo) -> Void)?
    var onEdgeDisconnected: ((EdgeID) -> Void)?
    /// Successful persistence acknowledged by a remaining Mac (never a token).
    var onPairingTokenSaved: ((EdgeID) -> Void)?
    /// Everything except `hello`/`ping`, which the transport answers itself.
    var onMessage: ((EdgeMessage, EdgeID) -> Void)?
    var onAudio: ((Data, EdgeID) -> Void)?
    /// A Teach recording and the id to answer it with.
    var onTranscribeRequest: ((_ requestId: String, _ header: AudioTakeHeader, _ audio: Data, _ from: EdgeID) -> Void)?
    var onHealthChanged: ((_ isHealthy: Bool, _ message: String?) -> Void)?

    /// A Mac asking to join, waiting for the user's OK (Add a Mac).
    struct PairRequest: Equatable {
        let id: UUID
        let name: String
        let code: String
    }

    /// Set while the user has Add a Mac open on this Mac; a `pair.request`
    /// at any other time is refused.
    private var acceptNewMacsUntil: Date?

    func acceptNewMacs(until date: Date?) {
        lock.lock()
        acceptNewMacsUntil = date
        lock.unlock()
    }

    private func isAcceptingNewMacs() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptNewMacsUntil.map { $0 > Date() } ?? false
    }
    /// This Mac's name, shown on the joining Mac next to the code.
    var coreName = ""
    var onPairRequest: ((PairRequest) -> Void)?
    /// The request was answered, timed out, or the joining Mac went away.
    var onPairEnded: ((UUID) -> Void)?
    /// How long a join may wait for the user's answer.
    var pairWaitTimeout: TimeInterval = 120

    private(set) var actualPort: UInt16?

    var connectedEdges: [BrokerEdgeInfo] {
        lock.lock()
        defer { lock.unlock() }
        return connections.values.compactMap(\.info)
    }

    init(
        coreId: String,
        token: String,
        bindHost: String,
        port: UInt16 = EdgeProtocol.corePort,
        allowPeer: @escaping (String) -> Bool = CoreServer.isTailscalePeer,
        isEdgeIdReserved: @escaping (EdgeID) -> Bool = { _ in false },
        rotateToken: @escaping () throws -> String = { try LocalSecret.rotateSharedToken() }
    ) {
        self.coreId = coreId
        self.token = token
        self.rotateToken = rotateToken
        self.bindHost = bindHost
        self.port = port
        self.allowPeer = allowPeer
        self.isEdgeIdReserved = isEdgeIdReserved
    }

    /// Synchronous publication on the receive queue: a hello cannot validate
    /// against the old value between saving and swapping it. No teardown or
    /// notification happens if persistence fails.
    func revokeAccess(for edgeId: EdgeID) throws {
        try queue.sync {
            let replacement = try rotateToken()
            token = replacement
            lock.lock()
            let removed = connections.values.filter { $0.edgeId == edgeId }
            lock.unlock()
            for edge in removed { disconnect(edge, reason: "removed from setup") }
            lock.lock()
            let remaining = connections.values.filter { $0.authenticated && $0.edgeId != edgeId }
            lock.unlock()
            let rotationId = UUID().uuidString
            for edge in remaining {
                edge.pendingTokenRotation = rotationId
                sendCore(.pairingTokenRotated(rotationId: rotationId, token: replacement), to: edge)
            }
        }
    }

    private func isCurrentAuthenticated(_ edge: EdgeConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connections[edge.uuid] === edge && edge.authenticated
    }

    // MARK: - Lifecycle

    func start() throws {
        stop()

        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = EdgeProtocol.maxBinaryFrameBytes
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: NWEndpoint.Port(rawValue: port)!)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.actualPort = listener.port?.rawValue
                self.setHealth(.ready)
                DispatchQueue.main.async { self.onHealthChanged?(true, nil) }
                NSLog("[Dictator] core listener ready on %@:%@", self.bindHost, "\(self.actualPort ?? 0)")
            case .failed(let error):
                self.setHealth(.failed)
                DispatchQueue.main.async { self.onHealthChanged?(false, error.localizedDescription) }
                NSLog("[Dictator] core listener failed: %@", error.localizedDescription)
            case .cancelled:
                self.setHealth(.stopped)
            default:
                break
            }
        }
        setHealth(.starting)
        self.listener = listener
        listener.start(queue: queue)
        scheduleIdleSweep()
    }

    func stop() {
        idleSweep?.cancel()
        idleSweep = nil
        listener?.cancel()
        listener = nil
        actualPort = nil

        lock.lock()
        let all = Array(connections.values)
        connections.removeAll()
        edgesByID.removeAll()
        health = .stopped
        lock.unlock()

        all.forEach { edge in
            edge.helloTimeout?.cancel()
            edge.connection.cancel()
        }
    }

    // MARK: - Idle sweep

    /// Drops every authenticated edge that has been silent longer than
    /// `EdgeProtocol.edgeIdleTimeout` (Edges ping every
    /// `EdgeProtocol.pingInterval`), then re-arms. Runs on `queue`.
    private func scheduleIdleSweep() {
        idleSweep?.cancel()
        let timeout = idleTimeoutOverride ?? EdgeProtocol.edgeIdleTimeout
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-timeout)
            self.lock.lock()
            let stale = self.connections.values.filter { $0.authenticated && $0.lastActivity < cutoff }
            self.lock.unlock()
            for edge in stale {
                HotkeyService.recordDiagnostics("core: edge idle for over \(Int(timeout))s, dropping")
                self.disconnect(edge, reason: "idle timeout")
            }
            self.scheduleIdleSweep()
        }
        idleSweep = item
        queue.asyncAfter(deadline: .now() + max(0.05, timeout / 2), execute: item)
    }

    // MARK: - Sending

    func send(_ message: CoreMessage, to edgeId: EdgeID) {
        lock.lock()
        let edge = edgesByID[edgeId].flatMap { connections[$0] }
        lock.unlock()
        guard let edge else { return }
        sendCore(message, to: edge)
    }

    /// Sends one binary frame (the audio after a `speech.request`).
    func sendBinary(_ data: Data, to edgeId: EdgeID) {
        lock.lock()
        let edge = edgesByID[edgeId].flatMap { connections[$0] }
        lock.unlock()
        guard let edge else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "core-binary", metadata: [metadata])
        edge.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func broadcast(_ message: CoreMessage) {
        lock.lock()
        let edges = connections.values.filter(\.authenticated)
        lock.unlock()
        edges.forEach { sendCore(message, to: $0) }
    }

    private func sendCore(_ message: CoreMessage, to edge: EdgeConnection) {
        do {
            let data = try EdgeProtocolCodec.encode(message)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "core-text", metadata: [metadata])
            edge.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        } catch {
            HotkeyService.recordDiagnostics("core: failed to encode \(message.type)")
            // A `.repoResponse` that fails to encode (frame too
            // large — e.g. a history/dictionary page that slipped past the
            // byte budget) must not just vanish. The Edge is waiting on
            // this `requestId` and would otherwise time out after ten
            // seconds with no idea why. Fall back to a small, always-
            // encodable error response correlated to the same request
            // instead of silently dropping it. Guarded against recursing
            // forever in the (practically impossible) case that even this
            // tiny fallback fails to encode.
            if case .repoResponse(let requestId, let result) = message, !Self.isRepoResponseTooLargeFallback(result) {
                sendCore(.repoResponse(requestId: requestId, result: .error("response too large")), to: edge)
            }
        }
    }

    private static func isRepoResponseTooLargeFallback(_ result: RepoResult) -> Bool {
        if case .error(let message) = result { return message == "response too large" }
        return false
    }

    /// Sends a rejection frame and only cancels once it's flushed, so the
    /// Edge actually sees the `error` before the socket goes away.
    private func sendAndDisconnect(_ message: CoreMessage, edge: EdgeConnection) {
        do {
            let data = try EdgeProtocolCodec.encode(message)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "core-text", metadata: [metadata])
            edge.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.disconnect(edge, reason: nil)
            })
        } catch {
            disconnect(edge, reason: nil)
        }
    }

    // MARK: - Accept

    private func accept(_ connection: NWConnection) {
        guard let host = remoteHost(of: connection), allowPeer(host) else {
            HotkeyService.recordDiagnostics("core: connection rejected, peer not allowed")
            connection.cancel()
            return
        }

        let edge = EdgeConnection(connection: connection)
        lock.lock()
        if connections.count >= Self.maxPendingConnections {
            lock.unlock()
            HotkeyService.recordDiagnostics("core: connection rejected, at pending-connection capacity")
            connection.cancel()
            return
        }
        connections[edge.uuid] = edge
        lock.unlock()

        connection.stateUpdateHandler = { [weak self, weak edge] state in
            guard let self, let edge else { return }
            switch state {
            case .failed, .cancelled:
                self.disconnect(edge, reason: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)

        let timeoutItem = DispatchWorkItem { [weak self, weak edge] in
            guard let self, let edge else { return }
            HotkeyService.recordDiagnostics("core: hello timeout, closing connection")
            self.disconnect(edge, reason: "hello timeout")
        }
        edge.helloTimeout = timeoutItem
        queue.asyncAfter(deadline: .now() + EdgeProtocol.helloTimeout, execute: timeoutItem)

        receiveLoop(edge)
    }

    /// Best-effort extraction of the remote IPv4/host string from an
    /// `NWConnection`'s endpoint, stripped of any `%iface` zone suffix.
    private func remoteHost(of connection: NWConnection) -> String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        var description = "\(host)"
        if let percentIndex = description.firstIndex(of: "%") {
            description = String(description[..<percentIndex])
        }
        return description
    }

    // MARK: - Receive

    private func receiveLoop(_ edge: EdgeConnection) {
        edge.connection.receiveMessage { [weak self, weak edge] data, context, isComplete, error in
            guard let self, let edge else { return }
            if let error {
                self.disconnect(edge, reason: error.localizedDescription)
                return
            }
            edge.lastActivity = Date()
            guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                self.receiveLoop(edge)
                return
            }
            switch metadata.opcode {
            case .close:
                self.disconnect(edge, reason: nil)
                return
            case .text:
                if let data {
                    guard data.count <= EdgeProtocol.maxTextFrameBytes else {
                        HotkeyService.recordDiagnostics("core: text frame exceeds size limit, closing")
                        self.disconnect(edge, reason: "frame too large")
                        return
                    }
                    self.handleText(data, edge: edge)
                }
            case .binary:
                if let data {
                    self.handleBinary(data, edge: edge)
                }
            default:
                break
            }
            self.receiveLoop(edge)
        }
    }

    private func handleText(_ data: Data, edge: EdgeConnection) {
        lock.lock()
        let tracked = connections[edge.uuid] === edge
        lock.unlock()
        guard tracked else { return }
        if edge.pairCode != nil {
            // A joining Mac only waits for the answer; anything else ends it.
            HotkeyService.recordDiagnostics("core: unexpected frame while a join waits, closing")
            disconnect(edge, reason: "unexpected frame during pairing")
            return
        }
        if !edge.authenticated {
            handleHello(data, edge: edge)
            return
        }

        let message: EdgeMessage
        do {
            message = try EdgeProtocolCodec.decodeEdgeMessage(data)
        } catch {
            HotkeyService.recordDiagnostics("core: malformed message from edge, dropped")
            return
        }
        guard let edgeId = edge.edgeId else { return }

        switch message {
        case .pairingTokenSaved(let rotationId):
            if edge.pendingTokenRotation == rotationId {
                edge.pendingTokenRotation = nil
                DispatchQueue.main.async { self.onPairingTokenSaved?(edgeId) }
            }
        case .hello:
            // Unexpected on an already-authenticated connection; ignore
            // rather than tearing down an otherwise healthy session.
            HotkeyService.recordDiagnostics("core: ignoring duplicate hello from authenticated edge")
        case .ping:
            // Pings and pointer updates can land between an audio header and
            // its bytes, so they leave the pending header alone. Only a new
            // header replaces it, and the bytes must match its length.
            sendCore(.pong, to: edge)
        case .transcribeRequest(let requestId, let header):
            edge.pendingAudioHeader = header
            edge.pendingTranscribeId = requestId
        case .audioTake(let header):
            edge.pendingTranscribeId = nil
            edge.pendingAudioHeader = header
            DispatchQueue.main.async {
                guard self.isCurrentAuthenticated(edge) else { return }
                self.onMessage?(message, edgeId)
            }
        default:
            DispatchQueue.main.async {
                guard self.isCurrentAuthenticated(edge) else { return }
                self.onMessage?(message, edgeId)
            }
        }
    }

    private func handleHello(_ data: Data, edge: EdgeConnection) {
        edge.helloTimeout?.cancel()
        edge.helloTimeout = nil

        let message: EdgeMessage
        do {
            message = try EdgeProtocolCodec.decodeEdgeMessage(data)
        } catch {
            HotkeyService.recordDiagnostics("core: malformed hello, rejecting")
            sendAndDisconnect(.error(code: "hello", message: "malformed hello"), edge: edge)
            return
        }
        if case .pairRequest(let edgeId, let name, _) = message {
            handlePairRequest(edgeId: edgeId, name: name, edge: edge)
            return
        }
        guard case .hello(let edgeId, let name, let helloToken, let caps) = message else {
            HotkeyService.recordDiagnostics("core: first frame was not hello, rejecting")
            sendAndDisconnect(.error(code: "hello", message: "expected hello"), edge: edge)
            return
        }
        guard LocalSecret.constantTimeEqual(helloToken, token) else {
            HotkeyService.recordDiagnostics("core: hello rejected, bad token")
            sendAndDisconnect(.error(code: "auth", message: "invalid token"), edge: edge)
            return
        }
        guard Self.isValidEdgeId(edgeId) else {
            HotkeyService.recordDiagnostics("core: hello rejected, malformed edge id")
            sendAndDisconnect(.error(code: "edgeId", message: "Edge id is invalid"), edge: edge)
            return
        }
        guard !isEdgeIdReserved(edgeId) else {
            HotkeyService.recordDiagnostics("core: hello rejected, edge id reserved")
            sendAndDisconnect(.error(code: "edgeId", message: "Edge id is reserved"), edge: edge)
            return
        }

        lock.lock()
        let replacedUUID = edgesByID[edgeId]
        let isReconnect = replacedUUID != nil
        if !isReconnect, connections.values.filter(\.authenticated).count >= EdgeProtocol.maxEdges {
            lock.unlock()
            HotkeyService.recordDiagnostics("core: hello rejected, at capacity")
            sendAndDisconnect(.error(code: "capacity", message: "core is at capacity"), edge: edge)
            return
        }
        let oldEdge = replacedUUID.flatMap { connections[$0] }
        edge.edgeId = edgeId
        edge.info = BrokerEdgeInfo(id: edgeId, name: name, caps: caps)
        edge.authenticated = true
        edgesByID[edgeId] = edge.uuid
        lock.unlock()

        if let oldEdge {
            HotkeyService.recordDiagnostics("core: edge reconnected, replacing prior connection")
            disconnect(oldEdge, reason: "replaced by reconnect")
        }

        HotkeyService.recordDiagnostics("core: edge authenticated")
        sendCore(.welcome(coreId: coreId, micOwner: nil, protocolVersion: EdgeProtocol.version), to: edge)
        if let info = edge.info {
            DispatchQueue.main.async {
                guard self.isCurrentAuthenticated(edge) else { return }
                self.onEdgeConnected?(info)
            }
        }
    }

    // MARK: - Joining (pair.request)

    private func handlePairRequest(edgeId: EdgeID, name: String, edge: EdgeConnection) {
        guard isAcceptingNewMacs() else {
            HotkeyService.recordDiagnostics("core: join refused, not taking new Macs")
            sendAndDisconnect(.pairDenied(reason: "\(coreName.isEmpty ? "The main Mac" : coreName) isn’t taking new Macs right now. Open Settings › Your Macs › Add a Mac there first."), edge: edge)
            return
        }
        guard Self.isValidEdgeId(edgeId), !isEdgeIdReserved(edgeId) else {
            sendAndDisconnect(.pairDenied(reason: "This Mac’s identity isn’t valid."), edge: edge)
            return
        }
        let trimmedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        lock.lock()
        let busy = connections.values.contains { $0.pairCode != nil }
        lock.unlock()
        guard !busy else {
            sendAndDisconnect(.pairDenied(reason: "Another Mac is joining right now. Try again in a minute."), edge: edge)
            return
        }
        let code = Self.makePairCode()
        edge.pairCode = code
        edge.edgeId = edgeId
        let timeout = DispatchWorkItem { [weak self, weak edge] in
            guard let self, let edge, edge.pairCode != nil else { return }
            HotkeyService.recordDiagnostics("core: join timed out")
            self.endPairing(edge, send: .pairDenied(reason: "Nobody confirmed the code in time. Try again."))
        }
        edge.pairTimeout = timeout
        queue.asyncAfter(deadline: .now() + pairWaitTimeout, execute: timeout)
        HotkeyService.recordDiagnostics("core: join requested, waiting for the user")
        sendCore(.pairCode(code: code, coreName: coreName), to: edge)
        let request = PairRequest(id: edge.uuid, name: trimmedName.isEmpty ? "A Mac" : trimmedName, code: code)
        DispatchQueue.main.async { self.onPairRequest?(request) }
    }

    /// The user's answer on this Mac. Approving hands the joining Mac the
    /// pairing token; it then reconnects with a normal `hello`.
    func answerPairRequest(_ id: UUID, approve: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let edge = self.connections[id]
            self.lock.unlock()
            guard let edge, edge.pairCode != nil else { return }
            HotkeyService.recordDiagnostics(approve ? "core: join approved" : "core: join declined")
            self.endPairing(edge, send: approve ? .pairApproved(token: self.token) : .pairDenied(reason: "Someone on the main Mac chose not to add this Mac."))
        }
    }

    private func endPairing(_ edge: EdgeConnection, send message: CoreMessage) {
        edge.pairCode = nil
        edge.pairTimeout?.cancel()
        edge.pairTimeout = nil
        let id = edge.uuid
        DispatchQueue.main.async { self.onPairEnded?(id) }
        sendAndDisconnect(message, edge: edge)
    }

    /// Six random digits.
    static func makePairCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0..<1_000_000, using: &generator))
    }

    private func handleBinary(_ data: Data, edge: EdgeConnection) {
        guard isCurrentAuthenticated(edge), let edgeId = edge.edgeId else {
            HotkeyService.recordDiagnostics("core: binary frame rejected, not authenticated")
            return
        }
        guard let header = edge.pendingAudioHeader, header.byteCount == data.count else {
            HotkeyService.recordDiagnostics("core: audio frame rejected, no matching audio.take header")
            return
        }
        edge.pendingAudioHeader = nil
        if let requestId = edge.pendingTranscribeId {
            edge.pendingTranscribeId = nil
            DispatchQueue.main.async {
                guard self.isCurrentAuthenticated(edge) else { return }
                self.onTranscribeRequest?(requestId, header, data, edgeId)
            }
            return
        }
        DispatchQueue.main.async {
            guard self.isCurrentAuthenticated(edge) else { return }
            self.onAudio?(data, edgeId)
        }
    }

    // MARK: - Teardown

    private func disconnect(_ edge: EdgeConnection, reason: String?) {
        lock.lock()
        let removed = connections.removeValue(forKey: edge.uuid) != nil
        if let edgeId = edge.edgeId, edgesByID[edgeId] == edge.uuid {
            edgesByID.removeValue(forKey: edgeId)
        }
        lock.unlock()
        guard removed else { return }

        edge.helloTimeout?.cancel()
        edge.connection.cancel()
        if edge.pairCode != nil {
            edge.pairCode = nil
            edge.pairTimeout?.cancel()
            let id = edge.uuid
            DispatchQueue.main.async { self.onPairEnded?(id) }
        }
        // `removed` already guarantees this runs at most once per uuid (the
        // dictionary entry is gone for any later call), but `replaced` makes
        // that explicit and survives even if teardown is ever restructured:
        // once we've reported this connection gone, never report it again —
        // in particular, the old side of an id replacement (torn down
        // explicitly in `handleHello`) must not also fire this from its own
        // subsequent `.cancelled` state update.
        if edge.authenticated, let edgeId = edge.edgeId, !edge.replaced {
            edge.replaced = true
            DispatchQueue.main.async { self.onEdgeDisconnected?(edgeId) }
        }
    }

    // MARK: - Edge id validation

    private static let edgeIdAllowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
    )

    /// 1…64 chars of `[A-Za-z0-9-]` — keeps a self-asserted `edgeId` from
    /// being used to smuggle anything (path separators, huge strings, ...)
    /// into logs, dictionary keys, or persisted state derived from it.
    static func isValidEdgeId(_ edgeId: EdgeID) -> Bool {
        guard (1...64).contains(edgeId.count) else { return false }
        return edgeId.unicodeScalars.allSatisfy { edgeIdAllowedCharacters.contains($0) }
    }

    private func setHealth(_ newValue: Health) {
        lock.lock()
        health = newValue
        lock.unlock()
    }

    // MARK: - Peer allowlist

    /// True for IPv4 addresses in Tailscale's CGNAT range, 100.64.0.0/10
    /// (100.64.0.0 – 100.127.255.255). Anything else — including IPv6,
    /// loopback, and ordinary LAN/private ranges — is rejected by default;
    /// tests override `allowPeer` to permit loopback explicitly.
    static func isTailscalePeer(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        var octets = [UInt8]()
        for part in parts {
            guard let value = UInt8(part) else { return false }
            octets.append(value)
        }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}
