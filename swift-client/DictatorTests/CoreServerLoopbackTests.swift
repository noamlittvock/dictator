import Network
import XCTest
@testable import Dictator

/// Loopback-only exercise of the Edge<->Core WebSocket transport: a real
/// `CoreServer` bound to 127.0.0.1 (port 0, so the OS picks a free one) and
/// real `CoreConnection`s (and, where the test needs to see raw wire bytes,
/// a bare `URLSessionWebSocketTask`) talking to it over `ws://`. No mic, no
/// hotkey — this only exercises the transport layer.
final class CoreServerLoopbackTests: XCTestCase {
    private let caps = EdgeCapabilities(
        hasMic: true, inputDeviceUID: "uid-1", accessibility: true, inputMonitoring: true, hotkeyMode: "intercept"
    )

    private var servers: [CoreServer] = []
    private var connections: [CoreConnection] = []
    private var rawTasks: [URLSessionWebSocketTask] = []
    private var rawSessions: [URLSession] = []

    private var secretRoot: URL!

    override func setUp() {
        super.setUp()
        secretRoot = FileManager.default.temporaryDirectory.appendingPathComponent("RevokeTests-\(UUID().uuidString)")
        LocalSecret.directoryOverrideForTesting = secretRoot
    }

    override func tearDown() {
        connections.forEach { $0.disconnect() }
        connections.removeAll()
        rawTasks.forEach { $0.cancel(with: .goingAway, reason: nil) }
        rawTasks.removeAll()
        rawSessions.removeAll()
        servers.forEach { $0.stop() }
        servers.removeAll()
        LocalSecret.directoryOverrideForTesting = nil
        try? FileManager.default.removeItem(at: secretRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func startServer(
        token: String = "shared-secret",
        allowPeer: @escaping (String) -> Bool = { $0.hasPrefix("127.") },
        isEdgeIdReserved: @escaping (EdgeID) -> Bool = { _ in false },
        rotateToken: @escaping () throws -> String = { try LocalSecret.rotateSharedToken() }
    ) throws -> CoreServer {
        let server = CoreServer(
            coreId: "core-1", token: token, bindHost: "127.0.0.1", port: 0,
            allowPeer: allowPeer, isEdgeIdReserved: isEdgeIdReserved, rotateToken: rotateToken
        )
        let ready = expectation(description: "server ready")
        server.onHealthChanged = { healthy, _ in
            if healthy { ready.fulfill() }
        }
        try server.start()
        wait(for: [ready], timeout: 5)
        servers.append(server)
        return server
    }

    private func url(for server: CoreServer) throws -> URL {
        let port = try XCTUnwrap(server.actualPort, "server has no actualPort yet")
        return try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)"))
    }

    private func makeEdge(
        to server: CoreServer,
        edgeId: EdgeID,
        name: String = "MacBook",
        token: String = "shared-secret",
        expectedCoreId: String? = nil
    ) throws -> CoreConnection {
        let connection = CoreConnection(
            url: try url(for: server), edgeId: edgeId, name: name, token: token,
            capabilities: caps, expectedCoreId: expectedCoreId
        )
        connections.append(connection)
        return connection
    }

    /// A bare WebSocket task, for tests that need to inspect the raw wire
    /// frames (or deliberately withhold `hello`) rather than going through
    /// `CoreConnection`.
    private func makeRawTask(to server: CoreServer) throws -> URLSessionWebSocketTask {
        let session = URLSession(configuration: .default)
        rawSessions.append(session)
        let task = session.webSocketTask(with: try url(for: server))
        rawTasks.append(task)
        task.resume()
        return task
    }

    // MARK: - Revocation

    func testRemovalRotatesBeforeNotifyingAndNeverGivesRemovedMacTheReplacement() throws {
        let old = try LocalSecret.sharedToken(fileName: "core-pairing.token")
        let server = try startServer(token: old)
        let removed = try makeRawTask(to: server)
        let kept = try makeEdge(to: server, edgeId: "kept", token: old)
        let pendingHello = try makeRawTask(to: server)
        let connected = expectation(description: "two Macs connected")
        connected.expectedFulfillmentCount = 2
        server.onEdgeConnected = { _ in connected.fulfill() }
        let hello = try EdgeProtocolCodec.encode(EdgeMessage.hello(edgeId: "removed", name: "Lost laptop", token: old, caps: caps))
        removed.send(.string(String(decoding: hello, as: UTF8.self))) { XCTAssertNil($0) }
        guard case .welcome = try nextCoreMessage(removed) else { return XCTFail("expected welcome") }
        kept.connect()
        wait(for: [connected], timeout: 5)
        let removedClosed = expectation(description: "removed socket closed without replacement")
        removed.receive { result in
            if case .success(let frame) = result, case .string(let text) = frame,
               let message = try? EdgeProtocolCodec.decodeCoreMessage(Data(text.utf8)),
               case .pairingTokenRotated = message {
                XCTFail("removed Mac received the replacement")
            }
            removedClosed.fulfill()
        }
        let saved = expectation(description: "kept Mac persisted and acknowledged")
        server.onPairingTokenSaved = { id in
            XCTAssertEqual(id, "kept")
            saved.fulfill()
        }
        try server.revokeAccess(for: "removed")
        wait(for: [saved, removedClosed], timeout: 5)
        // A socket already open at the swap still has to validate its hello
        // against the replacement. It must not receive rotation pre-auth.
        let pending = try EdgeProtocolCodec.encode(EdgeMessage.hello(edgeId: "pending", name: "Pending", token: old, caps: caps))
        pendingHello.send(.string(String(decoding: pending, as: UTF8.self))) { XCTAssertNil($0) }
        guard case .error(let code, _) = try nextCoreMessage(pendingHello) else { return XCTFail("expected auth refusal after swap") }
        XCTAssertEqual(code, "auth")
        let replacement = try LocalSecret.sharedToken(fileName: "core-pairing.token")
        XCTAssertNotEqual(old, replacement)
        let address = try XCTUnwrap(url(for: server).host) + ":" + String(try XCTUnwrap(server.actualPort))
        XCTAssertEqual(try PairingCredentialStore.token(forCore: address), replacement)
        XCTAssertEqual(server.connectedEdges.map(\.id), ["kept"])

        // A different identity also fails: this is shared-token rotation,
        // not a blocklist of the removed Mac's self-reported identity.
        let offline = try makeEdge(to: server, edgeId: "was-offline", token: old)
        let refused = expectation(description: "offline old credential refused")
        offline.onDisconnected = { reason in
            XCTAssertEqual(reason, CoreConnection.pairingRequiredMessage)
            refused.fulfill()
        }
        offline.connect()
        wait(for: [refused], timeout: 5)
        XCTAssertTrue(offline.requiresPairing)

        // The kept connection must use its replacement in memory, too.
        server.onEdgeConnected = nil
        let reconnected = expectation(description: "kept Mac reconnects with new token")
        kept.onConnected = { _, _ in reconnected.fulfill() }
        kept.dropAsUnreachable()
        wait(for: [reconnected], timeout: 5)
        XCTAssertTrue(kept.isConnected)
    }

    func testReplacementIsSavedForTheConfiguredCoreAddressOnly() throws {
        let server = try startServer()
        let address = "synthetic-main.ts.net:7880"
        try PairingCredentialStore.save(token: "other-core-secret", forCore: "other-main.ts.net")
        let edge = CoreConnection(url: try url(for: server), edgeId: "kept", name: "Laptop",
                                  token: "shared-secret", capabilities: caps, credentialAddress: address)
        connections.append(edge)
        let connected = expectation(description: "connected")
        edge.onConnected = { _, _ in connected.fulfill() }
        edge.connect()
        wait(for: [connected], timeout: 5)
        let saved = expectation(description: "credential saved")
        server.onPairingTokenSaved = { _ in saved.fulfill() }
        try server.revokeAccess(for: "offline-removed")
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(try PairingCredentialStore.token(forCore: address),
                       try LocalSecret.sharedToken(fileName: "core-pairing.token"))
        XCTAssertEqual(try PairingCredentialStore.token(forCore: "other-main.ts.net"), "other-core-secret")
    }

    func testWriteFailureLeavesConnectedMacsAndOldCredentialUsable() throws {
        let old = try LocalSecret.sharedToken(fileName: "core-pairing.token")
        let server = try startServer(token: old, rotateToken: { throw CocoaError(.fileWriteOutOfSpace) })
        let removed = try makeEdge(to: server, edgeId: "still-kept", token: old)
        let connected = expectation(description: "connected")
        server.onEdgeConnected = { _ in connected.fulfill() }
        let clientConnected = expectation(description: "client received welcome")
        removed.onConnected = { _, _ in clientConnected.fulfill() }
        removed.connect()
        wait(for: [connected, clientConnected], timeout: 5)
        XCTAssertThrowsError(try server.revokeAccess(for: "still-kept"))
        XCTAssertTrue(removed.isConnected)
        XCTAssertEqual(server.connectedEdges.map(\.id), ["still-kept"])
        XCTAssertEqual(try LocalSecret.sharedToken(fileName: "core-pairing.token"), old)
        let next = try makeEdge(to: server, edgeId: "next", token: old)
        let accepted = expectation(description: "old credential still accepted")
        server.onEdgeConnected = { _ in accepted.fulfill() }
        next.connect()
        wait(for: [accepted], timeout: 5)
    }

    func testAuthFailureExplainsRejoiningAndStopsAutomaticRetries() throws {
        let server = try startServer(token: "current")
        let edge = try makeEdge(to: server, edgeId: "revoked", token: "expired")
        let refused = expectation(description: "auth refusal")
        edge.onDisconnected = { reason in
            XCTAssertEqual(reason, CoreConnection.pairingRequiredMessage)
            refused.fulfill()
        }
        edge.connect()
        wait(for: [refused], timeout: 5)
        XCTAssertTrue(edge.requiresPairing)
        let noRetry = expectation(description: "no repeated refusal")
        noRetry.isInverted = true
        edge.onDisconnected = { _ in noRetry.fulfill() }
        edge.connect() // even repeated connect calls require fresh pairing
        edge.dropAsUnreachable() // cannot revive the stopped retry loop
        wait(for: [noRetry], timeout: 1.5)
        XCTAssertFalse(edge.isConnected)
    }

    func testRotationSaveFailureIsNotAcknowledgedAndStopsRetries() throws {
        let server = try startServer(rotateToken: { "replacement" })
        let edge = try makeEdge(to: server, edgeId: "kept")
        let connected = expectation(description: "connected")
        server.onEdgeConnected = { _ in connected.fulfill() }
        edge.connect()
        wait(for: [connected], timeout: 5)
        // A synthetic file where the credentials directory should be forces
        // persistence to fail without permissions or a real user home.
        try Data("blocked".utf8).write(to: secretRoot)
        let refused = expectation(description: "save failure explained")
        let noAck = expectation(description: "failed save never acknowledged")
        noAck.isInverted = true
        server.onPairingTokenSaved = { _ in noAck.fulfill() }
        edge.onDisconnected = { reason in
            XCTAssertEqual(reason, CoreConnection.credentialSaveFailedMessage)
            refused.fulfill()
        }
        // Mock only persistence on the server; the
        // client still uses its real credential store in the synthetic home.
        try server.revokeAccess(for: "offline-removed")
        wait(for: [refused], timeout: 5)
        XCTAssertTrue(edge.requiresPairing)
        wait(for: [noAck], timeout: 1.2)
    }

    // MARK: - Joining with a code

    private func sendPairRequest(_ task: URLSessionWebSocketTask, edgeId: EdgeID = "joining-mac") throws {
        let data = try EdgeProtocolCodec.encode(.pairRequest(edgeId: edgeId, name: "MacBook Pro", caps: caps))
        let sent = expectation(description: "pair.request sent")
        task.send(.string(String(decoding: data, as: UTF8.self))) { error in
            XCTAssertNil(error)
            sent.fulfill()
        }
        wait(for: [sent], timeout: 5)
    }

    private func nextCoreMessage(_ task: URLSessionWebSocketTask) throws -> CoreMessage? {
        var decoded: CoreMessage?
        let got = expectation(description: "frame received")
        task.receive { result in
            if case .success(let message) = result {
                switch message {
                case .string(let text): decoded = try? EdgeProtocolCodec.decodeCoreMessage(Data(text.utf8))
                case .data(let data): decoded = try? EdgeProtocolCodec.decodeCoreMessage(data)
                @unknown default: break
                }
            }
            got.fulfill()
        }
        wait(for: [got], timeout: 5)
        return decoded
    }

    func testJoinIsRefusedUnlessAddAMacIsOpen() throws {
        let server = try startServer()
        let task = try makeRawTask(to: server)
        try sendPairRequest(task)
        guard case .pairDenied = try nextCoreMessage(task) else { return XCTFail("expected pair.denied") }
    }

    func testApprovedJoinReceivesTheTokenAfterTheCodeIsShown() throws {
        let server = try startServer(token: "join-secret")
        server.acceptNewMacs(until: Date().addingTimeInterval(60))
        var request: CoreServer.PairRequest?
        let asked = expectation(description: "onPairRequest")
        server.onPairRequest = { request = $0; asked.fulfill() }

        let task = try makeRawTask(to: server)
        try sendPairRequest(task)
        guard case .pairCode(let code, _) = try nextCoreMessage(task) else { return XCTFail("expected pair.code") }
        wait(for: [asked], timeout: 5)
        XCTAssertEqual(request?.code, code)
        XCTAssertEqual(code.count, 6)
        XCTAssertEqual(request?.name, "MacBook Pro")
        XCTAssertTrue(server.connectedEdges.isEmpty, "a joining Mac isn't connected until it says hello")

        server.answerPairRequest(try XCTUnwrap(request).id, approve: true)
        guard case .pairApproved(let token) = try nextCoreMessage(task) else { return XCTFail("expected pair.approved") }
        XCTAssertEqual(token, "join-secret")
    }

    func testDeclinedJoinGetsNoToken() throws {
        let server = try startServer()
        server.acceptNewMacs(until: Date().addingTimeInterval(60))
        var request: CoreServer.PairRequest?
        let asked = expectation(description: "onPairRequest")
        server.onPairRequest = { request = $0; asked.fulfill() }
        let task = try makeRawTask(to: server)
        try sendPairRequest(task)
        _ = try nextCoreMessage(task)
        wait(for: [asked], timeout: 5)
        server.answerPairRequest(try XCTUnwrap(request).id, approve: false)
        guard case .pairDenied = try nextCoreMessage(task) else { return XCTFail("expected pair.denied") }
    }

    func testOnlyOneJoinWaitsAtATime() throws {
        let server = try startServer()
        server.acceptNewMacs(until: Date().addingTimeInterval(60))
        let first = try makeRawTask(to: server)
        try sendPairRequest(first, edgeId: "first-mac")
        guard case .pairCode = try nextCoreMessage(first) else { return XCTFail("expected pair.code") }
        let second = try makeRawTask(to: server)
        try sendPairRequest(second, edgeId: "second-mac")
        guard case .pairDenied = try nextCoreMessage(second) else { return XCTFail("expected pair.denied") }
    }

    // MARK: - Speech on another Mac

    func testSpeechRequestDeliversTheRecordingToTheEdge() throws {
        let server = try startServer()
        let connected = expectation(description: "connected")
        server.onEdgeConnected = { _ in connected.fulfill() }
        let edge = try makeEdge(to: server, edgeId: "speech-edge")
        let received = expectation(description: "speech job")
        var got: (SpeechJob, Data)?
        edge.onSpeechJob = { job, audio in got = (job, audio); received.fulfill() }
        edge.connect()
        wait(for: [connected], timeout: 5)

        let audio = Data((0..<256).map { UInt8($0) })
        let job = SpeechJob(requestId: "r1", model: "whisperkit:openai_whisper-small", languages: ["en"], vocabulary: [], sampleRate: 16000, byteCount: audio.count)
        server.send(.speechRequest(job), to: "speech-edge")
        server.sendBinary(audio, to: "speech-edge")
        wait(for: [received], timeout: 5)
        XCTAssertEqual(got?.0, job)
        XCTAssertEqual(got?.1, audio)
    }

    // MARK: - Handshake

    func testHelloWelcomeHandshakeAndOnEdgeConnected() throws {
        let server = try startServer()
        let edgeConnected = expectation(description: "onEdgeConnected")
        var connectedInfo: BrokerEdgeInfo?
        server.onEdgeConnected = { info in
            connectedInfo = info
            edgeConnected.fulfill()
        }

        let onConnected = expectation(description: "edge onConnected")
        let edge = try makeEdge(to: server, edgeId: "edge-1")
        edge.onConnected = { coreId, micOwner in
            XCTAssertEqual(coreId, "core-1")
            XCTAssertNil(micOwner)
            onConnected.fulfill()
        }
        edge.connect()

        wait(for: [edgeConnected, onConnected], timeout: 5)
        XCTAssertEqual(connectedInfo?.id, "edge-1")
        XCTAssertEqual(connectedInfo?.name, "MacBook")
        XCTAssertEqual(connectedInfo?.caps, caps)
        XCTAssertTrue(edge.isConnected)
        XCTAssertEqual(server.connectedEdges.map(\.id), ["edge-1"])
    }

    func testWrongTokenRejected() throws {
        let server = try startServer(token: "correct-token")

        // Wire-level check: the Core must actually send `error(code:"auth")`.
        let rawTask = try makeRawTask(to: server)
        let helloData = try EdgeProtocolCodec.encode(.hello(edgeId: "raw-edge", name: "Raw", token: "wrong-token", caps: caps))
        let helloText = try XCTUnwrap(String(data: helloData, encoding: .utf8))
        let sent = expectation(description: "hello sent")
        rawTask.send(.string(helloText)) { error in
            XCTAssertNil(error)
            sent.fulfill()
        }
        wait(for: [sent], timeout: 5)

        let gotAuthError = expectation(description: "error(auth) received")
        rawTask.receive { result in
            switch result {
            case .success(let message):
                let data: Data?
                switch message {
                case .data(let raw): data = raw
                case .string(let text): data = text.data(using: .utf8)
                @unknown default: data = nil
                }
                guard let data,
                      let decoded = try? EdgeProtocolCodec.decodeCoreMessage(data),
                      case .error(let code, _) = decoded
                else {
                    XCTFail("expected an error frame, got \(message)")
                    return
                }
                XCTAssertEqual(code, "auth")
            case .failure(let error):
                XCTFail("receive failed: \(error)")
            }
            gotAuthError.fulfill()
        }
        wait(for: [gotAuthError], timeout: 5)

        // Behavioral check via CoreConnection: onDisconnected fires, onEdgeConnected never does.
        var edgeConnectedFired = false
        server.onEdgeConnected = { _ in edgeConnectedFired = true }
        let disconnected = expectation(description: "onDisconnected")
        let edge = try makeEdge(to: server, edgeId: "edge-bad-token", token: "wrong-token")
        edge.onConnected = { _, _ in XCTFail("should never connect with the wrong token") }
        edge.onDisconnected = { _ in disconnected.fulfill() }
        edge.connect()
        wait(for: [disconnected], timeout: 5)
        XCTAssertTrue(edge.requiresPairing)
        edge.onDisconnected = nil // auth refusal has stopped retries
        XCTAssertFalse(edgeConnectedFired)
    }

    func testHelloTimeoutClosesConnection() throws {
        let server = try startServer()
        let rawTask = try makeRawTask(to: server)

        let closed = expectation(description: "connection closed by hello timeout")
        func poll() {
            rawTask.receive { result in
                switch result {
                case .failure:
                    closed.fulfill()
                case .success:
                    poll()
                }
            }
        }
        poll()
        wait(for: [closed], timeout: 3.5) // EdgeProtocol.helloTimeout is 2s
    }

    func testCapacityLimitRejectsNinthEdge() throws {
        let server = try startServer()
        var connectedCount = 0
        let eightConnected = expectation(description: "8 edges connected")
        eightConnected.expectedFulfillmentCount = 8
        server.onEdgeConnected = { _ in
            connectedCount += 1
            eightConnected.fulfill()
        }

        var edges: [CoreConnection] = []
        for i in 0..<8 {
            let edge = try makeEdge(to: server, edgeId: "edge-cap-\(i)")
            edge.connect()
            edges.append(edge)
        }
        wait(for: [eightConnected], timeout: 5)
        XCTAssertEqual(connectedCount, 8)

        let ninthDisconnected = expectation(description: "9th edge disconnected")
        let ninth = try makeEdge(to: server, edgeId: "edge-cap-9")
        ninth.onConnected = { _, _ in XCTFail("9th edge should be refused for capacity") }
        ninth.onDisconnected = { _ in ninthDisconnected.fulfill() }
        ninth.connect()
        wait(for: [ninthDisconnected], timeout: 5)
        XCTAssertEqual(server.connectedEdges.count, 8)
    }

    /// The 8-edge cap counts only *authenticated* connections, so on its
    /// own a peer that opens sockets and withholds `hello` could pile up
    /// unboundedly. `maxPendingConnections` (2x maxEdges)
    /// covers pending + authenticated together, and — unlike the hello
    /// timeout — rejects immediately at accept time.
    func testPendingConnectionCapClosesConnectionOverLimitAtOnce() throws {
        let server = try startServer()

        var pending: [URLSessionWebSocketTask] = []
        for _ in 0..<CoreServer.maxPendingConnections {
            pending.append(try makeRawTask(to: server))
        }
        // Let all of them actually land as accepted-but-hello-less
        // connections server-side before probing the boundary.
        Thread.sleep(forTimeInterval: 0.4)

        let closedAtOnce = expectation(description: "connection over the pending cap is closed immediately")
        let extra = try makeRawTask(to: server)
        func poll() {
            extra.receive { result in
                switch result {
                case .failure:
                    closedAtOnce.fulfill()
                case .success:
                    poll()
                }
            }
        }
        poll()
        // Tight timeout: this must not be waiting out the (2s) hello
        // timeout — it should be rejected the moment it's accepted.
        wait(for: [closedAtOnce], timeout: 1.5)
        _ = pending
    }

    // MARK: - Edge id hygiene

    func testIsValidEdgeIdShape() {
        XCTAssertTrue(CoreServer.isValidEdgeId("edge-1"))
        XCTAssertTrue(CoreServer.isValidEdgeId(String(repeating: "a", count: 64)))
        XCTAssertFalse(CoreServer.isValidEdgeId(""))
        XCTAssertFalse(CoreServer.isValidEdgeId(String(repeating: "a", count: 65)))
        XCTAssertFalse(CoreServer.isValidEdgeId("has space"))
        XCTAssertFalse(CoreServer.isValidEdgeId("slash/here"))
        XCTAssertFalse(CoreServer.isValidEdgeId("emoji🙂"))
        XCTAssertFalse(CoreServer.isValidEdgeId("under_score"))
    }

    /// Wire-level check for the malformed-shape branch: a hello
    /// with an out-of-shape `edgeId` gets `error(code:"edgeId")` and never
    /// reaches `onEdgeConnected`.
    func testMalformedEdgeIdShapeRejected() throws {
        let server = try startServer()
        var edgeConnectedFired = false
        server.onEdgeConnected = { _ in edgeConnectedFired = true }

        let code = try sendRawHelloAndReadErrorCode(to: server, edgeId: "not a valid id!")
        XCTAssertEqual(code, "edgeId")
        XCTAssertFalse(edgeConnectedFired)
    }

    /// Wire-level check for the reserved-id branch: a hello
    /// claiming an id the host has reserved (e.g. its own local Edge) gets
    /// `error(code:"edgeId")` and never reaches `onEdgeConnected`.
    func testReservedEdgeIdRejected() throws {
        let server = try startServer(isEdgeIdReserved: { $0 == "local-edge" })
        var edgeConnectedFired = false
        server.onEdgeConnected = { _ in edgeConnectedFired = true }

        let code = try sendRawHelloAndReadErrorCode(to: server, edgeId: "local-edge")
        XCTAssertEqual(code, "edgeId")
        XCTAssertFalse(edgeConnectedFired)

        // A non-reserved id from the same server still authenticates fine.
        let connected = expectation(description: "non-reserved id still connects")
        let edge = try makeEdge(to: server, edgeId: "not-reserved")
        edge.onConnected = { _, _ in connected.fulfill() }
        edge.connect()
        wait(for: [connected], timeout: 5)
    }

    /// Sends a raw `hello` with the given `edgeId` and returns the `error`
    /// frame's code the Core replies with.
    private func sendRawHelloAndReadErrorCode(to server: CoreServer, edgeId: String) throws -> String {
        let rawTask = try makeRawTask(to: server)
        let helloData = try EdgeProtocolCodec.encode(.hello(edgeId: edgeId, name: "Raw", token: "shared-secret", caps: caps))
        let helloText = try XCTUnwrap(String(data: helloData, encoding: .utf8))
        let sent = expectation(description: "hello sent")
        rawTask.send(.string(helloText)) { error in
            XCTAssertNil(error)
            sent.fulfill()
        }
        wait(for: [sent], timeout: 5)

        var receivedCode: String?
        let gotError = expectation(description: "error frame received")
        rawTask.receive { result in
            switch result {
            case .success(let message):
                let data: Data?
                switch message {
                case .data(let raw): data = raw
                case .string(let text): data = text.data(using: .utf8)
                @unknown default: data = nil
                }
                guard let data,
                      let decoded = try? EdgeProtocolCodec.decodeCoreMessage(data),
                      case .error(let code, _) = decoded
                else {
                    XCTFail("expected an error frame, got \(message)")
                    return
                }
                receivedCode = code
            case .failure(let error):
                XCTFail("receive failed: \(error)")
            }
            gotError.fulfill()
        }
        wait(for: [gotError], timeout: 5)
        return try XCTUnwrap(receivedCode)
    }

    // MARK: - Messaging

    func testProtocolPingReceivesPong() throws {
        let server = try startServer()
        let connected = expectation(description: "connected")
        let edge = try makeEdge(to: server, edgeId: "edge-ping")
        edge.onConnected = { _, _ in connected.fulfill() }
        edge.connect()
        wait(for: [connected], timeout: 5)

        let gotPong = expectation(description: "pong")
        edge.onMessage = { message in
            if case .pong = message { gotPong.fulfill() }
        }
        edge.send(.ping)
        wait(for: [gotPong], timeout: 5)
    }

    func testHotkeyDownReachesOnMessageWithCorrectEdgeID() throws {
        let server = try startServer()
        let connected = expectation(description: "connected")
        let edge = try makeEdge(to: server, edgeId: "edge-hotkey")
        edge.onConnected = { _, _ in connected.fulfill() }
        edge.connect()
        wait(for: [connected], timeout: 5)

        let received = expectation(description: "hotkeyDown received")
        server.onMessage = { message, edgeId in
            guard case .hotkeyDown = message else { return }
            XCTAssertEqual(edgeId, "edge-hotkey")
            received.fulfill()
        }
        edge.send(.hotkeyDown)
        wait(for: [received], timeout: 5)
    }

    func testAudioRoundTrip() throws {
        let server = try startServer()
        let connected = expectation(description: "connected")
        let edge = try makeEdge(to: server, edgeId: "edge-audio")
        edge.onConnected = { _, _ in connected.fulfill() }
        edge.connect()
        wait(for: [connected], timeout: 5)

        var raw = [UInt8](repeating: 0, count: 64 * 1_024)
        for i in raw.indices { raw[i] = UInt8(truncatingIfNeeded: i) }
        let payload = Data(raw)
        let header = AudioTakeHeader(sessionId: "s-audio", sampleRate: 16_000, frameCount: 32_000, durationSeconds: 2, byteCount: payload.count)

        let headerReceived = expectation(description: "audio.take header via onMessage")
        let audioReceived = expectation(description: "binary frame via onAudio")
        server.onMessage = { message, edgeId in
            guard case .audioTake(let receivedHeader) = message else { return }
            XCTAssertEqual(edgeId, "edge-audio")
            XCTAssertEqual(receivedHeader, header)
            headerReceived.fulfill()
        }
        server.onAudio = { data, edgeId in
            XCTAssertEqual(edgeId, "edge-audio")
            XCTAssertEqual(data, payload)
            audioReceived.fulfill()
        }
        edge.sendAudio(header: header, data: payload)
        wait(for: [headerReceived, audioReceived], timeout: 5)
    }

    /// The heartbeat doesn't wait its turn: a ping that lands between a header
    /// and its bytes must not cost the dictation its audio.
    func testPingBetweenHeaderAndAudioDoesNotLoseTheAudio() throws {
        let server = try startServer()
        let edge = try makeEdge(to: server, edgeId: "edge-ping")
        let connected = expectation(description: "connected")
        edge.onConnected = { _, _ in connected.fulfill() }
        edge.connect()
        wait(for: [connected], timeout: 5)

        let payload = Data([1, 2, 3, 4])
        let audioReceived = expectation(description: "binary frame survives the ping")
        server.onAudio = { data, _ in
            XCTAssertEqual(data, payload)
            audioReceived.fulfill()
        }
        edge.testHookAfterHeaderSent = { [weak edge] in edge?.sendPingNowForTesting() }
        let header = AudioTakeHeader(sessionId: "s-ping", sampleRate: 16_000, frameCount: 1, durationSeconds: 0.1, byteCount: payload.count)
        edge.sendAudio(header: header, data: payload)
        wait(for: [audioReceived], timeout: 5)
    }

    /// If the socket is replaced between the header send and the
    /// binary send, the binary frame must be dropped rather than landing,
    /// headerless, on the new socket. `testHookAfterHeaderSent` forces that
    /// race deterministically instead of trying to win it over real
    /// loopback timing.
    func testAudioBinaryFrameDroppedWhenTaskReplacedAfterHeaderSent() throws {
        let server = try startServer()
        let edge = try makeEdge(to: server, edgeId: "edge-race")
        let connected = expectation(description: "connected")
        edge.onConnected = { _, _ in connected.fulfill() }
        edge.connect()
        wait(for: [connected], timeout: 5)

        let headerReceived = expectation(description: "header still arrives")
        var audioArrived = false
        server.onMessage = { message, _ in
            guard case .audioTake = message else { return }
            headerReceived.fulfill()
        }
        server.onAudio = { _, _ in audioArrived = true }

        edge.testHookAfterHeaderSent = { [weak edge] in edge?.forceTaskReplacementForTesting() }

        let payload = Data([1, 2, 3, 4])
        let header = AudioTakeHeader(sessionId: "s-race", sampleRate: 16_000, frameCount: 1, durationSeconds: 0.1, byteCount: payload.count)
        edge.sendAudio(header: header, data: payload)
        wait(for: [headerReceived], timeout: 5)

        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(audioArrived, "binary frame must be dropped once the task is replaced after the header send")
    }

    func testSendToDeliversOnlyToTargetEdge() throws {
        let server = try startServer()
        let connectedA = expectation(description: "a connected")
        let connectedB = expectation(description: "b connected")
        let edgeA = try makeEdge(to: server, edgeId: "edge-a")
        let edgeB = try makeEdge(to: server, edgeId: "edge-b")
        edgeA.onConnected = { _, _ in connectedA.fulfill() }
        edgeB.onConnected = { _, _ in connectedB.fulfill() }
        edgeA.connect()
        edgeB.connect()
        wait(for: [connectedA, connectedB], timeout: 5)

        let gotIt = expectation(description: "a got captureStart")
        edgeA.onMessage = { message in
            guard case .captureStart(let sessionId) = message else { return }
            XCTAssertEqual(sessionId, "s-target")
            gotIt.fulfill()
        }
        edgeB.onMessage = { message in
            if case .captureStart = message { XCTFail("edge-b should not receive a targeted message") }
        }
        server.send(.captureStart(sessionId: "s-target"), to: "edge-a")
        wait(for: [gotIt], timeout: 5)
    }

    func testBroadcastReachesAllEdges() throws {
        let server = try startServer()
        let connectedA = expectation(description: "a connected")
        let connectedB = expectation(description: "b connected")
        let edgeA = try makeEdge(to: server, edgeId: "edge-broadcast-a")
        let edgeB = try makeEdge(to: server, edgeId: "edge-broadcast-b")
        edgeA.onConnected = { _, _ in connectedA.fulfill() }
        edgeB.onConnected = { _, _ in connectedB.fulfill() }
        edgeA.connect()
        edgeB.connect()
        wait(for: [connectedA, connectedB], timeout: 5)

        let gotA = expectation(description: "a got broadcast")
        let gotB = expectation(description: "b got broadcast")
        edgeA.onMessage = { message in
            if case .captureCancel = message { gotA.fulfill() }
        }
        edgeB.onMessage = { message in
            if case .captureCancel = message { gotB.fulfill() }
        }
        server.broadcast(.captureCancel(sessionId: "s-broadcast"))
        wait(for: [gotA, gotB], timeout: 5)
    }

    // MARK: - Reconnection

    func testSameEdgeIDReconnectReplacesOldConnection() throws {
        let server = try startServer()
        let firstConnected = expectation(description: "first connected")
        let first = try makeEdge(to: server, edgeId: "edge-dup")
        first.onConnected = { _, _ in firstConnected.fulfill() }
        first.connect()
        wait(for: [firstConnected], timeout: 5)

        let firstDisconnected = expectation(description: "first disconnected")
        first.onDisconnected = { _ in
            // Stop the old connection outright so it doesn't itself try to
            // reconnect and re-replace the new one a moment later.
            first.disconnect()
            firstDisconnected.fulfill()
        }
        let serverSawDisconnect = expectation(description: "server onEdgeDisconnected for edge-dup")
        let serverSawConnect = expectation(description: "server onEdgeConnected for edge-dup")
        server.onEdgeDisconnected = { edgeId in
            XCTAssertEqual(edgeId, "edge-dup")
            serverSawDisconnect.fulfill()
        }
        server.onEdgeConnected = { info in
            if info.id == "edge-dup" { serverSawConnect.fulfill() }
        }

        let secondConnected = expectation(description: "second connected")
        let second = try makeEdge(to: server, edgeId: "edge-dup")
        second.onConnected = { _, _ in secondConnected.fulfill() }
        second.connect()

        wait(for: [serverSawDisconnect, serverSawConnect, secondConnected, firstDisconnected], timeout: 5)
        XCTAssertEqual(server.connectedEdges.filter { $0.id == "edge-dup" }.count, 1)
    }

    func testClientReconnectsAfterServerRestartOnSamePort() throws {
        let serverA = try startServer(token: "restart-token")
        let port = try XCTUnwrap(serverA.actualPort)

        let initiallyConnected = expectation(description: "initially connected")
        let edge = try makeEdge(to: serverA, edgeId: "edge-restart", token: "restart-token")
        edge.onConnected = { _, _ in initiallyConnected.fulfill() }
        edge.connect()
        wait(for: [initiallyConnected], timeout: 5)

        let droppedOnStop = expectation(description: "dropped when server stops")
        edge.onDisconnected = { _ in droppedOnStop.fulfill() }
        serverA.stop()
        wait(for: [droppedOnStop], timeout: 5)
        edge.onDisconnected = nil // further failed retries against the still-down server are expected; ignore them

        let serverB = CoreServer(coreId: "core-1", token: "restart-token", bindHost: "127.0.0.1", port: port, allowPeer: { $0.hasPrefix("127.") })
        servers.append(serverB)
        let serverBReady = expectation(description: "serverB ready on same port")
        serverB.onHealthChanged = { healthy, _ in if healthy { serverBReady.fulfill() } }
        let reconnected = expectation(description: "edge reconnected to serverB")
        edge.onConnected = { _, _ in reconnected.fulfill() }

        try serverB.start()
        wait(for: [serverBReady], timeout: 5)
        wait(for: [reconnected], timeout: 5)
        XCTAssertEqual(serverB.connectedEdges.map(\.id), ["edge-restart"])
    }

    // MARK: - Capabilities

    /// `updateCapabilities` must be able to push a `caps` frame after connect without ever calling back into a
    /// capabilities closure on `CoreConnection`'s private queue (a cross-actor race). The value is stored under a
    /// lock and sent directly.
    func testUpdateCapabilitiesSendsCapsFrameAfterConnect() throws {
        let server = try startServer()
        let edge = try makeEdge(to: server, edgeId: "edge-caps")
        let connected = expectation(description: "connected")
        edge.onConnected = { _, _ in connected.fulfill() }
        edge.connect()
        wait(for: [connected], timeout: 5)

        let updated = EdgeCapabilities(
            hasMic: false, inputDeviceUID: "uid-2", accessibility: false, inputMonitoring: false, hotkeyMode: "listenOnly"
        )
        let gotCaps = expectation(description: "server received updated caps")
        server.onMessage = { message, edgeId in
            guard case .capabilities(let caps) = message else { return }
            XCTAssertEqual(edgeId, "edge-caps")
            XCTAssertEqual(caps, updated)
            gotCaps.fulfill()
        }
        edge.updateCapabilities(updated)
        wait(for: [gotCaps], timeout: 5)
    }

    // MARK: - Handshake validation (CoreConnection side)

    /// A real `CoreServer` always sends a well-formed `welcome`, so testing
    /// `CoreConnection`'s validation of a bad one needs a stand-in that
    /// crafts the frame by hand.
    private final class FakeCore {
        private let queue = DispatchQueue(label: "dev.noamlitt.dictator.fake-core-test")
        private var listener: NWListener?
        private(set) var actualPort: UInt16?
        private var connection: NWConnection?
        private let welcomeData: Data

        init(welcomeData: Data) {
            self.welcomeData = welcomeData
        }

        func start(onReady: @escaping () -> Void) throws {
            let parameters = NWParameters.tcp
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.actualPort = listener.port?.rawValue
                    onReady()
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }

        private func accept(_ connection: NWConnection) {
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.sendWelcome(on: connection)
                }
            }
            connection.start(queue: queue)
        }

        private func sendWelcome(on connection: NWConnection) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "welcome", metadata: [metadata])
            connection.send(content: welcomeData, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }

        func stop() {
            listener?.cancel()
            connection?.cancel()
        }
    }

    /// Hand-crafts a `welcome` frame with the given `coreId`/`protocol` so
    /// tests can drive `CoreConnection`'s validation paths a real
    /// `CoreServer` can't produce.
    private func encodeRawWelcome(coreId: String, protocolVersion: Int) throws -> Data {
        struct RawWelcome: Codable {
            var v: Int
            var t: String
            var id: String
            var coreId: String
            var micOwner: String?
            var `protocol`: Int
        }
        let welcome = RawWelcome(v: EdgeProtocol.version, t: "welcome", id: UUID().uuidString, coreId: coreId, micOwner: nil, protocol: protocolVersion)
        return try JSONEncoder().encode(welcome)
    }

    /// A `welcome` whose `protocolVersion` doesn't match ours
    /// must never complete the handshake — it should disconnect with
    /// reason "protocol version" instead.
    func testProtocolVersionMismatchDisconnectsWithoutCompletingHandshake() throws {
        let data = try encodeRawWelcome(coreId: "fake-core", protocolVersion: EdgeProtocol.version + 1)
        let fakeCore = FakeCore(welcomeData: data)
        let ready = expectation(description: "fake core ready")
        try fakeCore.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)
        defer { fakeCore.stop() }

        let port = try XCTUnwrap(fakeCore.actualPort)
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)"))
        let edge = CoreConnection(url: url, edgeId: "edge-badver", name: "Test", token: "irrelevant", capabilities: caps)
        connections.append(edge)

        edge.onConnected = { _, _ in XCTFail("should never complete handshake on a protocol-version mismatch") }
        let disconnected = expectation(description: "onDisconnected fired for protocol mismatch")
        edge.onDisconnected = { reason in
            // The fake main Mac is newer, so this Mac is the one to update.
            XCTAssertEqual(reason, ProtocolMismatch.thisMacOlderReason)
            disconnected.fulfill()
        }
        edge.connect()
        wait(for: [disconnected], timeout: 5)
    }

    /// Once `expectedCoreId` is pinned, a `welcome` from a different
    /// `coreId` must disconnect with reason "core identity changed", set
    /// `isPinnedMismatch`, and — critically — never auto-reconnect
    /// afterward.
    func testCoreIdentityMismatchStopsAutomaticReconnect() throws {
        let server = try startServer() // coreId is "core-1"
        let edge = try makeEdge(to: server, edgeId: "edge-pin", expectedCoreId: "some-other-core")
        edge.onConnected = { _, _ in XCTFail("handshake must not complete on a coreId mismatch") }
        let disconnected = expectation(description: "onDisconnected fired for coreId mismatch")
        edge.onDisconnected = { reason in
            XCTAssertEqual(reason, "core identity changed")
            disconnected.fulfill()
        }
        edge.connect()
        wait(for: [disconnected], timeout: 5)
        XCTAssertTrue(edge.isPinnedMismatch)

        // No automatic retry: the first backoff step is 1s, so give it a
        // beat and confirm nothing else fires.
        let noRetry = expectation(description: "no further callbacks fire")
        noRetry.isInverted = true
        edge.onDisconnected = { _ in noRetry.fulfill() }
        edge.onConnected = { _, _ in noRetry.fulfill() }
        wait(for: [noRetry], timeout: 2)
    }

    // MARK: - Repo request/response round trip

    /// A real `Edge.send(_ request: RepoRequest)` (the `RepoTransport`
    /// conformance) → `repo.request` frame → server `onMessage` → the test
    /// stands in for `CoreHost.handleRepoRequest` by replying `repo.response`
    /// itself → the Edge's `await` resolves with that result.
    func testRepoRequestRoundTripResolvesSendAwait() async throws {
        let server = try startServer()
        let edge = try makeEdge(to: server, edgeId: "edge-repo")
        let connected = expectation(description: "connected")
        edge.onConnected = { _, _ in connected.fulfill() }
        edge.connect()
        await fulfillment(of: [connected], timeout: 5)

        let dto = DictionaryEntryDTO(id: UUID(), pattern: "teh", replacement: "the", isVocabulary: false)
        server.onMessage = { [weak server] message, edgeId in
            guard case .repoRequest(let requestId, let request) = message, case .dictionaryPage = request else { return }
            XCTAssertEqual(edgeId, "edge-repo")
            server?.send(.repoResponse(requestId: requestId, result: .dictionaryPage([dto])), to: edgeId)
        }

        let result = try await edge.send(.dictionaryPage(limit: 200, afterPattern: nil))
        guard case .dictionaryPage(let entries) = result else {
            return XCTFail("expected dictionaryPage, got \(result)")
        }
        XCTAssertEqual(entries, [dto])
    }

    /// Nobody ever replies — `RepoTransport.send(_:)` must throw
    /// `RepositoryError.timeout` once `repoCorrelator`'s (overridden, short)
    /// timeout elapses, rather than hanging forever.
    func testRepoRequestTimesOutWhenNoResponseArrives() async throws {
        let server = try startServer()
        let edge = try makeEdge(to: server, edgeId: "edge-repo-timeout")
        await edge.setRepoRequestTimeoutForTesting(0.2)
        let connected = expectation(description: "connected")
        edge.onConnected = { _, _ in connected.fulfill() }
        edge.connect()
        await fulfillment(of: [connected], timeout: 5)

        server.onMessage = { _, _ in } // deliberately never answers

        do {
            _ = try await edge.send(.dictionaryPage(limit: 200, afterPattern: nil))
            XCTFail("expected RepositoryError.timeout")
        } catch RepositoryError.timeout {
            // expected
        }
    }

    /// If the connection drops out from under a pending `repoRequest`, it
    /// must fail right away with `RepositoryError.unavailable` rather than
    /// waiting out the full correlator timeout.
    func testRepoRequestFailsWithUnavailableWhenConnectionDrops() async throws {
        let server = try startServer()
        let edge = try makeEdge(to: server, edgeId: "edge-repo-drop")
        let connected = expectation(description: "connected")
        edge.onConnected = { _, _ in connected.fulfill() }
        edge.connect()
        await fulfillment(of: [connected], timeout: 5)

        server.onMessage = { _, _ in } // deliberately never answers

        async let result = edge.send(.dictionaryPage(limit: 200, afterPattern: nil))
        // Give the request a moment to actually reach the server before
        // dropping the connection out from under it.
        try await Task.sleep(nanoseconds: 200_000_000)
        edge.disconnect()

        do {
            _ = try await result
            XCTFail("expected RepositoryError.unavailable")
        } catch RepositoryError.unavailable(let message) {
            XCTAssertEqual(message, "Lost the connection to your main Mac.")
        }
    }

    // MARK: - Peer allowlist

    func testIsTailscalePeer() {
        XCTAssertTrue(CoreServer.isTailscalePeer("100.64.0.1"))
        XCTAssertTrue(CoreServer.isTailscalePeer("100.101.102.103"))
        XCTAssertTrue(CoreServer.isTailscalePeer("100.127.255.255"))
        XCTAssertFalse(CoreServer.isTailscalePeer("100.128.0.0"))
        XCTAssertFalse(CoreServer.isTailscalePeer("100.63.255.255"))
        XCTAssertFalse(CoreServer.isTailscalePeer("127.0.0.1"))
        XCTAssertFalse(CoreServer.isTailscalePeer("192.168.1.5"))
        XCTAssertFalse(CoreServer.isTailscalePeer("::1"))
    }
}
