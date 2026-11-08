import XCTest
@testable import Dictator

final class HardeningTests: XCTestCase {
    private var secretsDirectory: URL!

    override func setUp() {
        super.setUp()
        secretsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        LocalSecret.directoryOverrideForTesting = secretsDirectory
        MockURLProtocol.seen = []
    }

    override func tearDown() {
        LocalSecret.directoryOverrideForTesting = nil
        try? FileManager.default.removeItem(at: secretsDirectory)
        MockURLProtocol.handler = nil
        MockURLProtocol.seen = []
        super.tearDown()
    }

    func testSpeechRedirectPolicyRejectsCrossHostRedirects() throws {
        let original = URL(string: "https://configured.example.test/transcribe")!
        let redirected = URL(string: "https://other.example.test/collect")!
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: original,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirected.absoluteString]
            )
        )
        let task = URLSession.shared.dataTask(with: original)
        let callback = expectation(description: "redirect callback")

        var redirectRequest = URLRequest(url: redirected)
        redirectRequest.setValue("Bearer synthetic-key", forHTTPHeaderField: "Authorization")
        SpeechRedirectPolicy().urlSession(
            .shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirectRequest
        ) { request in
            XCTAssertNil(request)
            callback.fulfill()
        }

        wait(for: [callback], timeout: 1)
    }

    func testDestinationProbeForceKillsTermResistantProcess() {
        let started = Date()
        let output = DestinationSnapshot.boundedProcessOutputForTesting(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: 0.1
        )

        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testCorruptHistoryStoreIsPreservedAndRecovered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Dictator-HardeningTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let dictatorDirectory = root.appendingPathComponent("Dictator", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dictatorDirectory,
            withIntermediateDirectories: true
        )
        let storeURL = dictatorDirectory.appendingPathComponent("Dictator.store")
        try Data("not-a-sqlite-store".utf8).write(to: storeURL)

        let result = PersistenceLoader.load(applicationSupport: root)

        XCTAssertNotNil(result.container)
        XCTAssertNotNil(result.warning)
        let recoveryRoot = dictatorDirectory.appendingPathComponent("StoreRecovery")
        let preserved = try FileManager.default.subpathsOfDirectory(atPath: recoveryRoot.path)
        XCTAssertTrue(preserved.contains { $0.hasSuffix("Dictator.store") })
    }

    func testServiceEndpointsAcceptSupportedHTTPBases() throws {
        let values = [
            "http://mac-mini:7878",
            "http://the-office:7878",
            "http://127.0.0.1:7879",
            "http://[::1]:7879",
            "https://dictation.example.test/base/path",
        ]

        for value in values {
            XCTAssertNoThrow(
                try ServiceEndpoint.validated(value, label: "Test URL"),
                value
            )
        }
    }

    func testServiceEndpointsRejectUnsafeOrMalformedValues() {
        let values = [
            "",
            "mac-mini:7878",
            "http://",
            "http://bad host:7878",
            "ftp://mac-mini:7878",
            "file:///tmp/socket",
            "http://user:secret@mac-mini:7878",
            "http://mac-mini:7878?mode=unsafe",
            "http://mac-mini:7878#fragment",
            "http://mac-mini:0",
            "http://mac-mini:65536",
            "http://mac-mini:",
            "http://mac-mini:999999999999999999999999",
        ]

        for value in values {
            XCTAssertThrowsError(
                try ServiceEndpoint.validated(value, label: "Test URL"),
                value
            )
        }
    }

    func testSpeechEndpointsAllowOnlyEncryptedOrLocalAndTailscaleHTTP() {
        for value in [
            "http://100.101.102.103:7878", "http://100.64.0.0", "http://100.127.255.255",
            "http://127.0.0.1", "http://127.255.0.2", "http://localhost", "http://LOCALHOST.",
            "http://[::1]", "http://[fd7a:115c:a1e0::1]", "http://[FD7A:115C:A1E0:ffff::abcd]",
            "http://mac.tail123.ts.net", "http://MAC.TS.NET.", "http://[::ffff:100.101.102.103]",
            "https://public.example", "https://192.168.1.2", "https://100.128.0.1",
        ] {
            XCTAssertNoThrow(try SpeechEndpoint.validated(value), value)
        }
        for value in [
            "http://100.63.255.255", "http://100.128.0.1", "http://100.64.0.1.evil.example",
            "http://100.999.0.1", "http://192.168.1.2", "http://mini", "http://localhost.evil.example",
            "http://mac.ts.net.evil.example", "http://evilts.net", "http://ts.net", "http://[::]",
            "http://[fd7a:115c:a1e1::1]", "http://[fd7a:115d:a1e0::1]", "http://[2001:db8::1]",
            "http://[::ffff:100.128.0.1]", "http://127.1", "http://2130706433",
        ] {
            XCTAssertThrowsError(try SpeechEndpoint.validated(value), value)
        }
    }

    func testWarmRequestReadsKeyWithoutGeneratingIt() throws {
        let address = "https://speech.example.invalid:7878"
        let before = try XCTUnwrap(TranscriptionService.warmRequest(serverURL: address, refineLevel: .exact))
        XCTAssertNil(before.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretsDirectory.path))
        try LocalSecret.saveSpeechServerKey("synthetic-key")
        let after = try XCTUnwrap(TranscriptionService.warmRequest(serverURL: address, refineLevel: .exact))
        XCTAssertEqual(after.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        XCTAssertEqual(after.value(forHTTPHeaderField: "X-Refine-Level"), "exact")
        XCTAssertNil(TranscriptionService.warmRequest(serverURL: "http://public.example", refineLevel: .exact))
    }

    private func mockedSpeechService(status: Int) -> TranscriptionService {
        MockURLProtocol.handler = { _, _ in (status, Data("synthetic words".utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return TranscriptionService(session: URLSession(configuration: configuration))
    }

    private func transcribe(_ service: TranscriptionService, address: String = "https://speech.example.invalid:7878") async throws -> TranscriptionResult {
        try await service.transcribe(
            audio: CapturedAudio(data: Data(repeating: 0, count: 640), durationSeconds: 0.01, sampleRate: 16000, frameCount: 160),
            serverURL: address, refineLevel: .exact, dictionary: []
        )
    }

    func testTranscribeAddsKeyAndStillAcceptsOlderServer() async throws {
        let service = mockedSpeechService(status: 200)
        let first = try await transcribe(service)
        XCTAssertEqual(first.text, "synthetic words")
        XCTAssertNil(MockURLProtocol.seen.last?.0.value(forHTTPHeaderField: "Authorization"))
        try LocalSecret.saveSpeechServerKey("synthetic-key")
        let second = try await transcribe(service)
        XCTAssertEqual(second.text, "synthetic words")
        XCTAssertEqual(MockURLProtocol.seen.last?.0.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
    }

    func testSpeech401HasDistinctErrorAndPlainAlert() async throws {
        do {
            _ = try await transcribe(mockedSpeechService(status: 401))
            XCTFail("Must fail")
        } catch TranscriptionError.authenticationRequired {
            let alert = try XCTUnwrap(DictationAlert.speechConfigurationFailure(TranscriptionError.authenticationRequired))
            XCTAssertEqual(alert.action, .advanced)
            XCTAssertTrue(alert.detail.contains("Settings › Advanced"))
            XCTAssertTrue(alert.detail.contains("recording is kept"))
            XCTAssertEqual(DictationAlert.decode(failure: DictationFailure(alert).localizedDescription), alert)
        }
    }

    func testSavedUnsafeAddressFailsBeforeSendingAudioOrHealthRequest() async throws {
        let address = "http://100.64.0.1.evil.example"
        let service = mockedSpeechService(status: 200)
        do {
            _ = try await transcribe(service, address: address)
            XCTFail("Must fail")
        } catch is SpeechEndpointError { }
        do {
            try await TranscriptionService.checkReachable(serverURL: address, timeout: 1)
            XCTFail("Must fail")
        } catch is SpeechEndpointError { }
        do {
            _ = try await TranscriptionService.healthData(at: URL(string: address + "/health")!)
            XCTFail("Must fail")
        } catch is SpeechEndpointError { }
        XCTAssertTrue(MockURLProtocol.seen.isEmpty)
        let alert = try XCTUnwrap(DictationAlert.speechConfigurationFailure(SpeechEndpointError.unencrypted))
        XCTAssertTrue(alert.detail.contains("https://"))
        XCTAssertEqual(alert.action, .advanced)
    }

    @MainActor func testReplicatedRowCannotOverflowTheStats() {
        var row = DictationEntryDTO(
            id: UUID(), timestamp: Date(), text: "hi", durationSeconds: 1, inferenceMs: nil, wordCount: 1,
            modality: "voice", source: "dictator", destinationAppBundleId: nil, destinationAppName: nil,
            destinationURL: nil, insertionMethod: nil
        )
        XCTAssertNil(RepoServer.validateEntry(row))
        row.wordCount = Int.max
        XCTAssertNotNil(RepoServer.validateEntry(row))

        let stats = DictationStats()
        stats.record(wordCount: Int.max, durationSeconds: 1)
        stats.record(wordCount: Int.max, durationSeconds: 1)
        XCTAssertEqual(stats.totalWords, Int.max)
    }

    func testSelectionFromAnotherAppCannotCrashTheInsertionCheck() {
        XCTAssertNil(CaretLocator.expectedValue(after: "hi", replacing: NSRange(location: -1, length: 0), in: "world"))
        XCTAssertNil(CaretLocator.expectedValue(after: "hi", replacing: NSRange(location: 0, length: -1), in: "world"))
        XCTAssertNil(CaretLocator.expectedValue(after: "hi", replacing: NSRange(location: 9, length: 0), in: "world"))
        XCTAssertEqual(CaretLocator.expectedValue(after: "hi ", replacing: NSRange(location: 0, length: 0), in: "world"), "hi world")
        XCTAssertEqual(CaretLocator.expectedValue(after: "X", replacing: NSRange(location: 3, length: 99), in: "world"), "worX")
    }

    func testFallbackResamplerSurvivesTheShortestTakes() {
        XCTAssertTrue(AudioCaptureService.linearResampleTo16kHz([], from: 48_000).isEmpty)
        XCTAssertTrue(AudioCaptureService.linearResampleTo16kHz([0.5], from: 48_000).isEmpty)
        XCTAssertEqual(AudioCaptureService.linearResampleTo16kHz([0.5, 0.25, 0, 0.25, 0.5, 0.25], from: 48_000).count, 2 * 4)
    }

    func testAWindowTooNarrowToMeasureStillGetsWords() {
        let screen = WorkspaceRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertFalse(WorkspaceWords.placement(WorkspaceRect(x: 0, y: 0, width: 1e-30, height: 900), on: screen).isEmpty)
    }

    @MainActor func testQuitWaitsForADictationAndNotForever() async {
        var checks = 0
        let ended = await QuitGuard.waitUntilIdle(isBusy: { checks += 1; return checks < 4 }, limit: 10, poll: 1, sleep: { _ in })
        XCTAssertTrue(ended)
        XCTAssertEqual(checks, 4)
        let stuck = await QuitGuard.waitUntilIdle(isBusy: { true }, limit: 3, poll: 1, sleep: { _ in })
        XCTAssertFalse(stuck, "a stuck session must not block quitting for good")
    }

    @MainActor func testQuitOnlyWaitsWhileBusy() {
        let quitGuard = QuitGuard()
        XCTAssertEqual(quitGuard.shouldTerminate(isBusy: { false }, finished: {}), .terminateNow)
        XCTAssertEqual(quitGuard.shouldTerminate(isBusy: { true }, finished: {}), .terminateLater)
        XCTAssertEqual(quitGuard.shouldTerminate(isBusy: { true }, finished: {}), .terminateLater, "a second request joins the first")
    }

    @MainActor func testACopiedKeyIsConcealedAndLeavesTheClipboard() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dictator-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        LocalSecret.copyToClipboard("synthetic-key", on: pasteboard, lifetime: 0.05)
        XCTAssertEqual(pasteboard.string(forType: .string), "synthetic-key")
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    @MainActor func testAKeyIsNotTakenBackAfterSomethingElseWasCopied() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dictator-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        LocalSecret.copyToClipboard("synthetic-key", on: pasteboard, lifetime: 0.05)
        pasteboard.clearContents()
        pasteboard.setString("the user's own text", forType: .string)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's own text")
    }
}
