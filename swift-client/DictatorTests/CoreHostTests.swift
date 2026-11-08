import SwiftData
import XCTest
@testable import Dictator

/// Covers `CoreHost`'s effect-execution glue — transcription scheduling,
/// watchdog timers, local-edge delivery, and history recording —
/// complementing `SessionBrokerTests` (which covers the pure state machine
/// itself). Uses a fake `LocalEdgeChannel` throughout: `EdgeRuntime` is
/// device-bound (mic, hotkey, paste) and must never be constructed here.
@MainActor
final class CoreHostTests: XCTestCase {
    private final class FakeChannel: LocalEdgeChannel {
        let edgeId: EdgeID
        private(set) var delivered: [CoreMessage] = []
        var onDeliver: ((CoreMessage) -> Void)?

        init(edgeId: EdgeID) { self.edgeId = edgeId }

        func deliver(_ message: CoreMessage) {
            delivered.append(message)
            onDeliver?(message)
        }
    }

    private let caps = EdgeCapabilities(
        hasMic: true, inputDeviceUID: "uid-1", accessibility: true, inputMonitoring: true, hotkeyMode: "intercept"
    )

    /// Fresh in-memory `Repositories` bundle for a test — mirrors
    /// `DictatorViewModel.makeInMemoryRepositories`, but local to this file
    /// so each test gets its own isolated store rather than sharing one.
    private func makeRepositories() -> Repositories {
        let schema = Repositories.schema
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        return Repositories.make(container: container)
    }

    /// A fresh temp-directory-backed checkpoint store per call, so these
    /// tests never touch the developer's real `~/Library/Application
    /// Support/Dictator/Recovery` (and never see each other's files).
    private func makeCheckpointStore() -> RecordingCheckpointStore {
        RecordingCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreHostTests-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeHost(
        repositories: Repositories? = nil,
        transcribe: @escaping (AudioTakeHeader, Data) async throws -> (text: String, inferenceMs: Int?) = { _, _ in ("hello", 10) },
        recordHistory: @escaping (SessionID, String, Double, Int?, InsertDestination?, EdgeID) async throws -> Void = { _, _, _, _, _, _ in },
        checkpointStore: RecordingCheckpointStore? = nil
    ) -> CoreHost {
        CoreHost(
            coreId: "core-1", repositories: repositories ?? makeRepositories(), clock: { 0 }, makeSessionID: { "s1" },
            transcribe: transcribe, recordHistory: recordHistory,
            checkpointStore: checkpointStore ?? makeCheckpointStore()
        )
    }

    // frameCount/byteCount are intentionally tiny and consistent (byteCount ==
    // frameCount * 4, per the broker's semantic validation) with the 4-byte
    // `Data([1, 2, 3, 4])` these tests send as the "binary frame" below.
    private func audioTakeHeader(durationSeconds: Double = 0.1, byteCount: Int = 4) -> AudioTakeHeader {
        AudioTakeHeader(sessionId: "s1", sampleRate: 16_000, frameCount: 1, durationSeconds: durationSeconds, byteCount: byteCount)
    }

    private func isInsert(_ message: CoreMessage) -> Bool {
        if case .insert = message { return true }
        return false
    }

    private func isCaptureStop(_ message: CoreMessage) -> Bool {
        if case .captureStop = message { return true }
        return false
    }

    func testRevokingConnectedMacDisconnectsBrokerBeforeForgettingItsListing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        LocalSecret.directoryOverrideForTesting = root
        defer { LocalSecret.directoryOverrideForTesting = nil; try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.data(forKey: "setupKnownMachines")
        UserDefaults.standard.removeObject(forKey: "setupKnownMachines")
        defer { UserDefaults.standard.set(previous, forKey: "setupKnownMachines") }
        let host = makeHost()
        let directory = SetupDirectory(fetchHealth: { _ in nil })
        host.onEdgesChanged = { directory.update(edges: $0, coreEdgeId: "main") }
        host.apply(.edgeConnected(BrokerEdgeInfo(id: "laptop", name: "Laptop", caps: caps)))
        let old = try LocalSecret.sharedToken(fileName: "core-pairing.token")
        XCTAssertTrue(directory.snapshot?.machine("laptop")?.online == true)
        try host.revokeAccess(for: "laptop") // no listener needed for broker/persistence test
        XCTAssertTrue(host.connectedEdges.isEmpty)
        XCTAssertFalse(directory.snapshot?.machine("laptop")?.online == true)
        directory.forget("laptop")
        XCTAssertNil(directory.snapshot?.machine("laptop"))
        XCTAssertNotEqual(try LocalSecret.sharedToken(fileName: "core-pairing.token"), old)
    }

    func testFailedRevocationDoesNotDisconnectBrokerOrForgetListing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("blocked".utf8).write(to: root)
        LocalSecret.directoryOverrideForTesting = root
        defer { LocalSecret.directoryOverrideForTesting = nil; try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.data(forKey: "setupKnownMachines")
        UserDefaults.standard.removeObject(forKey: "setupKnownMachines")
        defer { UserDefaults.standard.set(previous, forKey: "setupKnownMachines") }
        let host = makeHost()
        let directory = SetupDirectory(fetchHealth: { _ in nil })
        host.onEdgesChanged = { directory.update(edges: $0, coreEdgeId: "main") }
        host.apply(.edgeConnected(BrokerEdgeInfo(id: "laptop", name: "Laptop", caps: caps)))
        XCTAssertThrowsError(try host.revokeAccess(for: "laptop"))
        directory.forget("laptop") // offline guard still protects the listing
        XCTAssertEqual(host.connectedEdges.map(\.id), ["laptop"])
        XCTAssertTrue(directory.snapshot?.machine("laptop")?.online == true)
    }

    // MARK: - hotkeyDown → captureStart delivered

    func testHistoryWriteFailureKeepsAudioAndReportsFailureOnReconnect() async throws {
        let store = makeCheckpointStore()
        defer { store.delete("core-s1") }
        let host = makeHost(recordHistory: { _, _, _, _, _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }, checkpointStore: store)
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        host.releaseGraceOverride = 0.01
        let stopped = expectation(description: "capture stopped")
        let inserted = expectation(description: "text delivered")
        channel.onDeliver = { message in
            if case .captureStop = message { stopped.fulfill() }
            if case .insert = message { inserted.fulfill() }
        }
        host.apply(.message(.hotkeyDown, from: "mac"))
        host.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        await fulfillment(of: [stopped], timeout: 2)
        host.apply(.message(.audioTake(audioTakeHeader()), from: "mac"))
        host.apply(.audio(Data([1, 2, 3, 4]), from: "mac"))
        await fulfillment(of: [inserted], timeout: 2)
        host.apply(.message(.insertResult(sessionId: "s1", outcome: .pasted, destination: nil), from: "mac"))
        await host.drain()

        XCTAssertNil(host.session)
        XCTAssertEqual(store.listTakes().first?.metadata.status, .failed)
        let outcome = channel.delivered.compactMap { message -> SessionOutcome? in
            if case .sessionState(let update) = message, update.state == .idle { return update.outcome }
            return nil
        }.last
        guard case .failed(let message) = outcome else { return XCTFail("The recorder must be told to retain its audio") }
        XCTAssertEqual(DictationAlert.decode(failure: message).action, .history)
        host.apply(.message(.sessionOutcomeQuery(sessionIds: ["s1"]), from: "mac"))
        await host.drain()
        XCTAssertTrue(channel.delivered.contains(.sessionOutcomes(["s1": .failed(message: message)])))
    }

    func testMissingAudioEndsSessionAndLetsNextDictationStart() async throws {
        let host = makeHost()
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        host.releaseGraceOverride = 0.01
        host.watchdogDurationOverride = 0.1
        host.apply(.message(.hotkeyDown, from: "mac"))
        host.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        try await Task.sleep(for: .milliseconds(300))
        await host.drain()

        XCTAssertNil(host.session, "A connected recorder that sends no audio must not block every later dictation")
        XCTAssertTrue(channel.delivered.contains {
            if case .sessionState(let update) = $0, case .failed = update.outcome { return update.state == .idle }
            return false
        })
        host.apply(.message(.hotkeyDown, from: "mac"))
        await host.drain()
        XCTAssertEqual(host.session?.phase, .recording)
        host.apply(.message(.hotkeyCancel, from: "mac"))
        await host.drain()
    }

    func testHotkeyDownDeliversCaptureStartToLocalChannel() async {
        let host = makeHost()
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)

        host.apply(.message(.hotkeyDown, from: "mac"))
        // Effect execution is queued: wait for this batch to
        // actually run before inspecting what the channel received.
        await host.drain()

        // `attachLocal` delivers the current hands-free `config` immediately
        // on attach (ahead of any session); sessionState(recording) is
        // delivered before captureStart within the session itself.
        let afterAttach = Array(channel.delivered.drop(while: { if case .config = $0 { return true }; return false }))
        XCTAssertTrue(afterAttach.first.map { if case .sessionState = $0 { return true }; return false } ?? false)
        XCTAssertTrue(channel.delivered.contains(.captureStart(sessionId: "s1")))
        XCTAssertEqual(host.session?.phase, .recording)
    }

    func testSessionStartCallbackFiresOncePerSessionAtKeyDown() {
        let host = makeHost()
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        var starts = 0
        host.onSessionStarted = { starts += 1 }

        host.apply(.message(.hotkeyDown, from: "mac"))
        XCTAssertEqual(starts, 1)
        host.apply(.message(.hotkeyDown, from: "mac")) // joins the running session
        XCTAssertEqual(starts, 1)
    }

    // MARK: - audio → transcribe called → insert delivered

    func testAudioTriggersTranscribeThenInsertIsDelivered() {
        let host = makeHost(transcribe: { _, _ in ("hello world", 42) })
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        host.releaseGraceOverride = 0.01

        let captureStopDelivered = expectation(description: "captureStop delivered")
        let insertReceived = expectation(description: "insert delivered")
        channel.onDeliver = { [weak self] message in
            guard let self else { return }
            if self.isCaptureStop(message) { captureStopDelivered.fulfill() }
            if self.isInsert(message) { insertReceived.fulfill() }
        }

        host.apply(.message(.hotkeyDown, from: "mac"))
        host.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        // mac is the sole holder: capture only actually stops (and can
        // accept the audio take) once the release grace fires.
        wait(for: [captureStopDelivered], timeout: 2)
        host.apply(.message(.audioTake(audioTakeHeader()), from: "mac"))
        host.apply(.audio(Data([1, 2, 3, 4]), from: "mac"))

        wait(for: [insertReceived], timeout: 2)
        XCTAssertTrue(channel.delivered.contains {
            if case .insert(let sessionId, let text) = $0 { return sessionId == "s1" && text == "hello world" }
            return false
        })
    }

    // MARK: - insertResult → recordHistory called with the text/duration

    func testInsertResultRecordsHistoryWithTextAndDuration() {
        var recordedText: String?
        var recordedDuration: Double?
        let recorded = expectation(description: "history recorded")
        let host = makeHost(
            transcribe: { _, _ in ("hi there", 17) },
            recordHistory: { _, text, duration, _, _, _ in
                recordedText = text
                recordedDuration = duration
                recorded.fulfill()
            }
        )
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        host.releaseGraceOverride = 0.01

        let captureStopDelivered = expectation(description: "captureStop delivered")
        let insertReceived = expectation(description: "insert delivered")
        channel.onDeliver = { [weak self] message in
            guard let self else { return }
            if self.isCaptureStop(message) { captureStopDelivered.fulfill() }
            if self.isInsert(message) { insertReceived.fulfill() }
        }

        host.apply(.message(.hotkeyDown, from: "mac"))
        host.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        wait(for: [captureStopDelivered], timeout: 2)
        host.apply(.message(.audioTake(audioTakeHeader(durationSeconds: 2.5)), from: "mac"))
        host.apply(.audio(Data([1, 2, 3, 4]), from: "mac"))
        wait(for: [insertReceived], timeout: 2)

        host.apply(.message(.insertResult(sessionId: "s1", outcome: .pasted, destination: nil), from: "mac"))

        wait(for: [recorded], timeout: 2)
        XCTAssertEqual(recordedText, "hi there")
        XCTAssertEqual(recordedDuration, 2.5)
        XCTAssertNil(host.session)
    }

    // MARK: - cancel during processing cancels the transcribe task; no history recorded

    func testHotkeyCancelDuringProcessingCancelsTranscribeAndSkipsHistory() {
        var historyCalls = 0
        let transcribeStarted = expectation(description: "transcribe started")
        let host = makeHost(
            transcribe: { _, _ in
                transcribeStarted.fulfill()
                try await Task.sleep(for: .seconds(5)) // cancelled long before this elapses
                return ("should not reach", nil)
            },
            recordHistory: { _, _, _, _, _, _ in historyCalls += 1 }
        )
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        host.releaseGraceOverride = 0.01

        let captureStopDelivered = expectation(description: "captureStop delivered")
        channel.onDeliver = { [weak self] message in
            guard let self, self.isCaptureStop(message) else { return }
            captureStopDelivered.fulfill()
        }

        host.apply(.message(.hotkeyDown, from: "mac"))
        host.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        wait(for: [captureStopDelivered], timeout: 2)
        host.apply(.message(.audioTake(audioTakeHeader()), from: "mac"))
        host.apply(.audio(Data([1, 2, 3, 4]), from: "mac"))
        wait(for: [transcribeStarted], timeout: 2)

        host.apply(.message(.hotkeyCancel, from: "mac"))

        // Give the cancelled `Task.sleep` a moment to unwind and confirm it
        // never resurrects the session it already ended.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(historyCalls, 0)
        XCTAssertNil(host.session)
    }

    // MARK: - Core checkpoint discard on non-recordHistory terminal outcomes

    func testCancelledDuringProcessingDiscardsCoreCheckpoint() {
        let store = makeCheckpointStore()
        let transcribeStarted = expectation(description: "transcribe started")
        let host = makeHost(
            transcribe: { _, _ in
                transcribeStarted.fulfill()
                try await Task.sleep(for: .seconds(5)) // cancelled long before this elapses
                return ("should not reach", nil)
            },
            checkpointStore: store
        )
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        host.releaseGraceOverride = 0.01

        let captureStopDelivered = expectation(description: "captureStop delivered")
        let idleDelivered = expectation(description: "idle delivered")
        channel.onDeliver = { [weak self] message in
            guard let self else { return }
            if self.isCaptureStop(message) { captureStopDelivered.fulfill() }
            if case .sessionState(let update) = message, update.state == .idle { idleDelivered.fulfill() }
        }

        host.apply(.message(.hotkeyDown, from: "mac"))
        host.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        wait(for: [captureStopDelivered], timeout: 2)
        host.apply(.message(.audioTake(audioTakeHeader()), from: "mac"))
        host.apply(.audio(Data([1, 2, 3, 4]), from: "mac"))
        wait(for: [transcribeStarted], timeout: 2)
        // Persisted before the transcription task even runs.
        XCTAssertEqual(store.listTakes().map(\.id), ["core-s1"])

        host.apply(.message(.hotkeyCancel, from: "mac")) // .cancelled(.user), no .recordHistory effect
        wait(for: [idleDelivered], timeout: 2)

        XCTAssertTrue(store.listTakes().isEmpty, "a cancelled-during-processing session must not leak core-s1")
    }

    func testEmptyTranscriptionDiscardsCoreCheckpoint() {
        let store = makeCheckpointStore()
        var historyCalls = 0
        let host = makeHost(
            transcribe: { _, _ in ("   ", nil) }, // whitespace-only → .empty outcome
            recordHistory: { _, _, _, _, _, _ in historyCalls += 1 },
            checkpointStore: store
        )
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        host.releaseGraceOverride = 0.01

        let captureStopDelivered = expectation(description: "captureStop delivered")
        let idleDelivered = expectation(description: "idle delivered")
        channel.onDeliver = { [weak self] message in
            guard let self else { return }
            if self.isCaptureStop(message) { captureStopDelivered.fulfill() }
            if case .sessionState(let update) = message, update.state == .idle { idleDelivered.fulfill() }
        }

        host.apply(.message(.hotkeyDown, from: "mac"))
        host.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        wait(for: [captureStopDelivered], timeout: 2)
        host.apply(.message(.audioTake(audioTakeHeader()), from: "mac"))
        host.apply(.audio(Data([1, 2, 3, 4]), from: "mac"))
        wait(for: [idleDelivered], timeout: 2)

        XCTAssertEqual(historyCalls, 0, "an empty transcription never records history")
        XCTAssertTrue(store.listTakes().isEmpty, "an empty-outcome session must not leak core-s1")
    }

    // MARK: - Session-outcome reconciliation query

    func testSessionOutcomeQueryAnswersWithARecordedOutcomeAndOmitsUnknownIds() {
        let host = makeHost(transcribe: { _, _ in ("hello world", 42) })
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        host.releaseGraceOverride = 0.01

        let captureStopDelivered = expectation(description: "captureStop delivered")
        let insertReceived = expectation(description: "insert delivered")
        channel.onDeliver = { [weak self] message in
            guard let self else { return }
            if self.isCaptureStop(message) { captureStopDelivered.fulfill() }
            if self.isInsert(message) { insertReceived.fulfill() }
        }
        host.apply(.message(.hotkeyDown, from: "mac"))
        host.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        wait(for: [captureStopDelivered], timeout: 2)
        host.apply(.message(.audioTake(audioTakeHeader()), from: "mac"))
        host.apply(.audio(Data([1, 2, 3, 4]), from: "mac"))
        wait(for: [insertReceived], timeout: 2)
        let idleDelivered = expectation(description: "idle delivered")
        channel.onDeliver = { message in
            if case .sessionState(let update) = message, update.state == .idle { idleDelivered.fulfill() }
        }
        host.apply(.message(.insertResult(sessionId: "s1", outcome: .pasted, destination: nil), from: "mac"))
        // The outcome is recorded into the ring buffer as part of this same
        // (asynchronous) effect-chain batch, alongside the idle broadcast —
        // wait for that broadcast so the query below can't race ahead of it.
        wait(for: [idleDelivered], timeout: 2)

        let outcomesReceived = expectation(description: "outcomes delivered")
        var received: [SessionID: SessionOutcome]?
        channel.onDeliver = { message in
            if case .sessionOutcomes(let outcomes) = message {
                received = outcomes
                outcomesReceived.fulfill()
            }
        }
        host.apply(.message(.sessionOutcomeQuery(sessionIds: ["s1", "never-happened"]), from: "mac"))
        wait(for: [outcomesReceived], timeout: 2)

        XCTAssertEqual(received, ["s1": .pasted], "only the id the Core actually remembers is answered")
    }

    func testSessionOutcomeRingBufferEvictsThePastFiftieth() {
        let host = makeHost()
        for i in 0..<55 {
            host.recordSessionOutcomeForTesting(sessionId: "s\(i)", outcome: .pasted)
        }
        XCTAssertEqual(host.recentSessionOutcomeCountForTesting, 50)

        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        let outcomesReceived = expectation(description: "outcomes delivered")
        var received: [SessionID: SessionOutcome]?
        channel.onDeliver = { message in
            if case .sessionOutcomes(let outcomes) = message {
                received = outcomes
                outcomesReceived.fulfill()
            }
        }
        host.apply(.message(.sessionOutcomeQuery(sessionIds: ["s0", "s54"]), from: "mac"))
        wait(for: [outcomesReceived], timeout: 2)

        XCTAssertNil(received?["s0"], "the oldest entry (past the 50-entry limit) must have been evicted")
        XCTAssertEqual(received?["s54"], .pasted)
    }

    // MARK: - watchdog fires after the (overridden) scheduled interval

    func testWatchdogFiresAfterOverrideDuration() {
        let host = makeHost()
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        host.watchdogDurationOverride = 0.05

        let captureStopDelivered = expectation(description: "captureStop delivered by watchdog")
        // Read the phase as capture stops. The override also shortens the
        // audio-upload watchdog armed next, so by the time `wait` returns a
        // slow machine can already have ended the session, correctly.
        var phaseAtStop: SessionPhase?
        channel.onDeliver = { [weak self, weak host] message in
            guard let self, self.isCaptureStop(message) else { return }
            phaseAtStop = host?.session?.phase
            captureStopDelivered.fulfill()
        }

        host.apply(.message(.hotkeyDown, from: "mac"))

        wait(for: [captureStopDelivered], timeout: 2)
        XCTAssertEqual(phaseAtStop, .processing)
    }

    // MARK: - release grace fires after the (overridden) scheduled interval

    /// Mirrors `testWatchdogFiresAfterOverrideDuration` above, but for
    /// `SessionBroker.releaseGrace`: `mac` is the sole holder, so its
    /// `hotkeyUp` schedules the grace rather than stopping capture directly;
    /// only once the (overridden, short) grace task actually fires and
    /// delivers `.releaseGraceFired` back into `apply` does capture stop.
    func testReleaseGraceFiresAfterOverrideDurationAndStopsCapture() {
        let host = makeHost()
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        host.releaseGraceOverride = 0.05

        let captureStopDelivered = expectation(description: "captureStop delivered by release grace")
        channel.onDeliver = { [weak self] message in
            guard let self, self.isCaptureStop(message) else { return }
            captureStopDelivered.fulfill()
        }

        host.apply(.message(.hotkeyDown, from: "mac"))
        host.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        XCTAssertEqual(host.session?.phase, .recording) // not stopped yet — waiting out the grace

        wait(for: [captureStopDelivered], timeout: 2)
        XCTAssertEqual(host.session?.phase, .processing)
    }

    // MARK: - History is awaited before the idle sessionState is delivered

    func testHistoryIsAwaitedBeforeIdleSessionStateIsDelivered() async {
        var resumeHistory: (() -> Void)?
        let historyStarted = expectation(description: "history started")
        let host = makeHost(
            transcribe: { _, _ in ("hi", 10) },
            recordHistory: { _, _, _, _, _, _ in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    resumeHistory = { continuation.resume() }
                    historyStarted.fulfill()
                }
            }
        )
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        host.releaseGraceOverride = 0.01

        let captureStopDelivered = expectation(description: "captureStop delivered")
        let insertReceived = expectation(description: "insert delivered")
        channel.onDeliver = { [weak self] message in
            guard let self else { return }
            if self.isCaptureStop(message) { captureStopDelivered.fulfill() }
            if self.isInsert(message) { insertReceived.fulfill() }
        }
        host.apply(.message(.hotkeyDown, from: "mac"))
        host.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        await fulfillment(of: [captureStopDelivered], timeout: 2)
        host.apply(.message(.audioTake(audioTakeHeader()), from: "mac"))
        host.apply(.audio(Data([1, 2, 3, 4]), from: "mac"))
        await fulfillment(of: [insertReceived], timeout: 2)

        host.apply(.message(.insertResult(sessionId: "s1", outcome: .pasted, destination: nil), from: "mac"))
        await fulfillment(of: [historyStarted], timeout: 2)

        // recordHistory is suspended on the continuation — the idle
        // sessionState that follows it in the same effect batch must not
        // have reached the channel yet.
        XCTAssertFalse(channel.delivered.contains {
            if case .sessionState(let update) = $0 { return update.state == .idle }
            return false
        })

        let idleDelivered = expectation(description: "idle delivered")
        channel.onDeliver = { message in
            if case .sessionState(let update) = message, update.state == .idle { idleDelivered.fulfill() }
        }
        resumeHistory?()

        await fulfillment(of: [idleDelivered], timeout: 2)
    }

    // MARK: - Hands-free: `handsFree` broadcasts `config` to the local channel

    func testSettingHandsFreeDeliversConfigToLocalChannel() {
        let host = makeHost()
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)
        // `attachLocal` itself delivers the current (false) value on attach.
        XCTAssertEqual(channel.delivered, [.config(handsFree: false)])

        host.handsFree = true
        XCTAssertEqual(channel.delivered, [.config(handsFree: false), .config(handsFree: true)])

        // Setting it to the same value again is a no-op — no duplicate send.
        host.handsFree = true
        XCTAssertEqual(channel.delivered, [.config(handsFree: false), .config(handsFree: true)])
    }

    // MARK: - Stale callbacks for an old/ended session are no-ops

    func testLateTranscriptionFinishedForASessionThatAlreadyEndedIsANoOp() {
        let host = makeHost(transcribe: { _, _ in ("hello", 10) })
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps)

        host.apply(.message(.hotkeyDown, from: "mac"))
        host.apply(.message(.hotkeyCancel, from: "mac")) // ends the session while recording
        XCTAssertNil(host.session)

        // A transcriptionFinished callback for that same, now-dead, session
        // id must not resurrect it — this is what protects the broker from
        // a late CoreServer/listener-generation callback, or a stale
        // transcription/watchdog task, that outlives the session it was
        // started for.
        let effects = host.apply(.transcriptionFinished("s1", text: "late", inferenceMs: nil, error: nil))
        XCTAssertEqual(effects, [])
        XCTAssertNil(host.session)
    }

    // MARK: - Repo requests from a remote edge (`handleRepoRequest`)

    /// `.repoRequest` never touches the broker/effect chain at all — a
    /// `.settingsGet` answered via `handleRepoRequest` must reflect
    /// `AppSettings.shared` (through `LocalCoreSettingsRepository`) and
    /// reach `remoteEdgeSendOverride`, standing in for a live `CoreServer`.
    func testHandleRepoRequestSettingsGetReturnsLocalAppSettingsValues() async {
        let savedRefineLevel = AppSettings.shared.refineLevel
        let savedPrompt = AppSettings.shared.customSystemPrompt
        let savedPersist = AppSettings.shared.persistHistory
        addTeardownBlock {
            AppSettings.shared.refineLevel = savedRefineLevel
            AppSettings.shared.customSystemPrompt = savedPrompt
            AppSettings.shared.persistHistory = savedPersist
        }
        AppSettings.shared.refineLevel = .medium
        AppSettings.shared.customSystemPrompt = "be terse"
        AppSettings.shared.persistHistory = true

        let host = makeHost()
        let responseReceived = expectation(description: "repoResponse sent")
        var response: (CoreMessage, EdgeID)?
        host.remoteEdgeSendOverride = { message, edgeId in
            response = (message, edgeId)
            responseReceived.fulfill()
        }

        host.handleRepoRequest(id: "req-1", request: .settingsGet, from: "remote-edge")
        await fulfillment(of: [responseReceived], timeout: 2)

        guard case .repoResponse(let requestId, let result) = response?.0,
              case .settings(let settings) = result else {
            return XCTFail("expected repoResponse(settings), got \(String(describing: response?.0))")
        }
        XCTAssertEqual(requestId, "req-1")
        XCTAssertEqual(response?.1, "remote-edge")
        XCTAssertEqual(settings.refineLevel, "medium")
        XCTAssertEqual(settings.customSystemPrompt, "be terse")
        XCTAssertEqual(settings.persistHistory, true)
    }

    /// A `.historyUpsert` from a remote edge must land in the local
    /// container (the Core's own store). `CoreHost` itself never broadcasts
    /// `repoChanged` for this — the broadcast comes from `DictatorViewModel`
    /// observing `RepositoryHub.historyVersion` (which bumps from this very
    /// write, since Core role's `repositoryHub.current` is the same bundle
    /// `CoreHost.repositories` is). This test only covers `CoreHost`'s own
    /// responsibility: routing the request to the local store and replying
    /// `.ok`.
    func testHandleRepoRequestHistoryUpsertLandsInLocalContainer() async throws {
        let repositories = makeRepositories()
        let host = makeHost(repositories: repositories)
        let responseReceived = expectation(description: "repoResponse sent")
        var response: CoreMessage?
        host.remoteEdgeSendOverride = { message, _ in
            response = message
            responseReceived.fulfill()
        }
        var broadcasts: [CoreMessage] = []
        host.remoteBroadcastOverride = { broadcasts.append($0) }

        let savedPersist = AppSettings.shared.persistHistory
        addTeardownBlock { AppSettings.shared.persistHistory = savedPersist }
        AppSettings.shared.persistHistory = true

        let entry = DictationEntryDTO(
            id: UUID(), timestamp: Date(), text: "hello from edge", durationSeconds: 1, inferenceMs: nil, wordCount: 3,
            modality: "voice", source: "dictator", destinationAppBundleId: nil, destinationAppName: nil,
            destinationURL: nil, insertionMethod: nil, originEdgeId: "remote-edge"
        )
        host.handleRepoRequest(id: "req-2", request: .historyUpsert([entry]), from: "remote-edge")
        await fulfillment(of: [responseReceived], timeout: 2)

        guard case .repoResponse(_, .ok) = response else {
            return XCTFail("expected repoResponse(.ok), got \(String(describing: response))")
        }
        // `CoreHost` itself never broadcasts on this path anymore.
        XCTAssertFalse(broadcasts.contains(.repoChanged(.history)))

        let page = try await repositories.history.page(limit: 10, before: nil)
        XCTAssertEqual(page.map(\.text), ["hello from edge"])
    }

    /// A Mac that attaches locally at startup and then connects to a remote
    /// main Mac: its chords must take the remote path afterwards.
    func testChordAfterLocalToRemoteTransitionTakesTheRemotePath() async throws {
        let host = makeHost()
        let runtime = EdgeRuntime(edgeId: "me", edgeName: "Test Mac")
        host.attachLocalEdge(runtime)
        XCTAssertNotNil(runtime.localSession)
        host.detachLocalEdge()
        XCTAssertNil(runtime.localSession, "detach must clear the local probe")

        var sent: [EdgeMessage] = []
        runtime.send = { sent.append($0) }
        runtime.wireHotkey()
        runtime.hotkeyService.onStart?()
        try await Task.sleep(nanoseconds: 50_000_000)
        runtime.hotkeyService.onCharacterChord?()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sent, [.hotkeyDown, .pressAbandoned, .hotkeyUp(reason: .key)])
    }

    // MARK: Workspace reset across Macs

    func testRememberEverywhereAsksEveryMacAndNamesTheOnesThatDontAnswer() async {
        let host = makeHost()
        let local = FakeChannel(edgeId: "mini-edge")
        let layout = WorkspaceSavedLayout(macName: "Mac mini", capturedAt: Date(timeIntervalSinceReferenceDate: 1),
                                          screens: [], windows: [WorkspaceSavedWindow(bundleID: "a", appName: "A", screenID: "1", place: WorkspaceRect(x: 0, y: 0, width: 1, height: 1))])
        local.onDeliver = { message in
            if case .workspaceCapture(let requestId) = message {
                host.apply(.message(.workspaceCaptureResult(requestId: requestId, macID: "mini", layout: layout, error: nil), from: "mini-edge"))
            }
        }
        host.attachLocal(local, caps: caps, name: "Mac mini")
        host.apply(.edgeConnected(BrokerEdgeInfo(id: "book", name: "MacBook Pro", caps: caps)))
        var asked: [EdgeID] = []
        host.remoteEdgeSendOverride = { message, edge in if case .workspaceCapture = message { asked.append(edge) } }
        let result = await host.rememberWorkspaceEverywhere(timeout: 0.3)
        XCTAssertEqual(asked, ["book"])
        XCTAssertEqual(result.layouts, ["mini": layout])
        XCTAssertEqual(result.unanswered, ["MacBook Pro"])
    }

    func testAConnectedMacsRunAllReachesTheOtherMacsAndReportsBack() async {
        let host = makeHost()
        let local = FakeChannel(edgeId: "mini-edge")
        local.onDeliver = { message in
            if case .workspaceRun(let requestId, "desk", false, "MacBook Pro", "op-1") = message {
                host.apply(.message(.workspaceRunResult(requestId: requestId, summary: "done, 2 changes."), from: "mini-edge"))
            }
        }
        host.attachLocal(local, caps: caps, name: "Mac mini")
        host.apply(.edgeConnected(BrokerEdgeInfo(id: "book", name: "MacBook Pro", caps: caps)))
        host.apply(.edgeConnected(BrokerEdgeInfo(id: "imac", name: "iMac", caps: caps)))
        let reported = expectation(description: "reported")
        host.remoteEdgeSendOverride = { message, edge in
            switch message {
            case .workspaceRun(let requestId, _, _, _, _):
                XCTAssertEqual(edge, "imac", "The Mac that asked is not asked back")
                host.apply(.message(.workspaceRunResult(requestId: requestId, summary: ""), from: edge))
            case .workspaceRunReport(_, let reports):
                XCTAssertEqual(edge, "book")
                XCTAssertEqual(reports, [WorkspaceRunReport(macName: "Mac mini", summary: "done, 2 changes.")], "A Mac with nothing to do is left out")
                reported.fulfill()
            default: break
            }
        }
        host.apply(.message(.workspaceRunAll(requestId: "r", routineID: "desk", undo: false, operationID: "op-1"), from: "book"))
        await fulfillment(of: [reported], timeout: 3)
    }
}

extension CoreHostTests {
    func testRememberFleetReportsBusyMacSeparatelyFromUnansweredMac() async {
        let host = makeHost()
        let local = FakeChannel(edgeId: "mini-edge")
        local.onDeliver = { message in
            if case .workspaceCapture(let requestId) = message {
                host.apply(.message(.workspaceCaptureResult(requestId: requestId, macID: "mini", layout: nil,
                    error: WorkspaceLaunchController.captureBusyMessage), from: "mini-edge"))
            }
        }
        host.attachLocal(local, caps: caps, name: "Mac mini")
        let result = await host.rememberWorkspaceEverywhere(timeout: 0.3)
        XCTAssertTrue(result.layouts.isEmpty)
        XCTAssertTrue(result.unanswered.isEmpty)
        XCTAssertEqual(result.busy, ["Mac mini"])
    }

    func testLongTakePublishesHeardTextOnceBeforeHistorySave() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LongHeard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0, heard: [String] = [], savedHeard: String?
        let recorded = expectation(description: "history saved")
        let host = CoreHost(coreId: "core-1", repositories: makeRepositories(), clock: { 0 }, makeSessionID: { "s1" },
            transcribe: { _, _ in XCTFail("stage-aware transcriber must be used"); return ("", nil) },
            recordHistory: { _, _, _, _, _, _ in savedHeard = heard.first; recorded.fulfill() },
            checkpointStore: RecordingCheckpointStore(directory: root),
            transcribeWithRawText: { _, _ in calls += 1; return ("final\(calls)", 1, "raw\(calls)") })
        host.onHeardText = { _, text in heard.append(text) }
        let channel = FakeChannel(edgeId: "mac")
        host.attachLocal(channel, caps: caps); host.releaseGraceOverride = 0.01
        let stopped = expectation(description: "capture stopped"), inserted = expectation(description: "inserted")
        channel.onDeliver = { [weak self] message in
            if self?.isCaptureStop(message) == true { stopped.fulfill() }
            if self?.isInsert(message) == true { inserted.fulfill() }
        }
        host.apply(.message(.hotkeyDown, from: "mac")); host.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        wait(for: [stopped], timeout: 2)
        let frames = 120 * 16_000
        let data = [Float](repeating: 0, count: frames).withUnsafeBufferPointer { Data(buffer: $0) }
        host.apply(.message(.audioTake(.init(sessionId: "s1", sampleRate: 16_000, frameCount: frames, durationSeconds: 120, byteCount: data.count)), from: "mac"))
        host.apply(.audio(data, from: "mac"))
        wait(for: [inserted], timeout: 2)
        host.apply(.message(.insertResult(sessionId: "s1", outcome: .pasted, destination: nil), from: "mac"))
        wait(for: [recorded], timeout: 2)
        XCTAssertEqual(calls, 2); XCTAssertEqual(heard, ["raw1 raw2"])
        XCTAssertEqual(savedHeard, "raw1 raw2")
    }

}
