import SwiftData
import XCTest
@testable import Dictator

/// Dictator's actions inside the Shortcuts app (Dictate, Clean up text, Run
/// a Voice launch shortcut). Synthetic only: the speech path, clean-up model,
/// microphone and the `shortcuts` program are all mocked.
@MainActor
final class ShortcutsIntentsTests: XCTestCase {
    private var savedServices: ShortcutsBridgeServices?

    override func setUp() {
        super.setUp()
        savedServices = ShortcutsBridge.services
        ShortcutsBridge.services = nil
    }

    override func tearDown() {
        ShortcutsBridge.services = savedServices
        super.tearDown()
    }

    func testBuildDoesNotAdvertiseUnavailableDictatorActions() {
        // Covers the three public actions and provider together: disabling only
        // the provider still leaves each discoverable action in the library.
        XCTAssertEqual(DictateIntent.isDiscoverable, DictatorAppIntentsBuild.enabled)
        XCTAssertEqual(CleanUpTextIntent.isDiscoverable, DictatorAppIntentsBuild.enabled)
        XCTAssertEqual(RunVoiceLaunchShortcutIntent.isDiscoverable, DictatorAppIntentsBuild.enabled)
        XCTAssertEqual(DictatorShortcutsProvider.appShortcuts.count, DictatorAppIntentsBuild.enabled ? 3 : 0)
        XCTAssertTrue(DictatorAppIntentsBuild.unavailableMessage.contains("unavailable in this build"))
    }

    // MARK: Fixtures

    private func voiceCommand(_ id: String, _ name: String, _ pattern: String, enabled: Bool = true,
                          steps: [VoiceStep] = [VoiceStep(kind: .typeText, text: "hi")]) -> VoiceCommand {
        VoiceCommand(id: id, name: name, pattern: pattern, steps: steps, enabled: enabled)
    }

    private func config() -> VoiceLaunchConfig {
        var config = VoiceLaunchConfig()
        config.commands = [
            voiceCommand("remind", "Add a reminder", "Remind {task}"),
            voiceCommand("lights", "Lights", "Lights on"),
            voiceCommand("off", "Old one", "Legacy {x}", enabled: false),
        ]
        return config
    }

    private final class Calls {
        var finished: [(String, Bool)] = []
        var saved: [HistoryRecordDTO] = []
        var plans: [VoiceLaunchPlan] = []
    }

    private func services(
        config: VoiceLaunchConfig? = nil, heard: ShortcutsHeard = ShortcutsHeard(text: "  um remind me  ", seconds: 2.5),
        listenError: Error? = nil, cleanupAllowed: Bool = true, cleanupAvailable: Bool = true,
        finish: ((String, Bool) throws -> String)? = nil, calls: Calls = Calls(),
        run: @escaping (VoiceLaunchPlan, @escaping (VoiceShortcutAnswer) -> Void) async -> VoiceLaunchExecutor.Result = { _, _ in .done }
    ) -> ShortcutsBridgeServices {
        let cfg = config ?? self.config()
        return ShortcutsBridgeServices(
            config: { cfg },
            listen: { if let listenError { throw listenError }; return heard },
            finish: { text, useAI in
                calls.finished.append((text, useAI))
                if let finish { return try finish(text, useAI) }
                return useAI ? "Cleaned: \(text)" : text
            },
            cleanupAllowed: { cleanupAllowed },
            cleanupAvailable: { cleanupAvailable },
            saveHistory: { calls.saved.append($0) },
            originEdgeId: { "edge-1" },
            runPlan: { plan, answered in
                calls.plans.append(plan)
                return await run(plan, answered)
            })
    }

    // MARK: Listing and entity

    func testListingShowsEnabledVoiceCommandsWithTheirOpeningWords() {
        let list = ShortcutsBridge.voiceCommands(in: config())
        XCTAssertEqual(list.map(\.id), ["remind", "lights"])
        XCTAssertEqual(list.map(\.name), ["Add a reminder", "Lights"])
        XCTAssertEqual(list.map(\.opens), ["Remind", "Lights on"])
        XCTAssertTrue(ShortcutsBridge.voiceCommands(in: .empty).isEmpty)
    }

    func testSearchMatchesTheTitleAndTheOpeningWords() {
        XCTAssertEqual(ShortcutsBridge.voiceCommands(matching: "REMINDER", in: config()).map(\.id), ["remind"])
        XCTAssertEqual(ShortcutsBridge.voiceCommands(matching: "lights on", in: config()).map(\.id), ["lights"])
        XCTAssertEqual(ShortcutsBridge.voiceCommands(matching: "  ", in: config()).count, 2)
        XCTAssertTrue(ShortcutsBridge.voiceCommands(matching: "zzz", in: config()).isEmpty)
    }

    func testEntityShowsTheTitleAndWhatToSay() {
        let entity = VoiceShortcutEntity(ShortcutsVoiceCommand(id: "remind", name: "Add a reminder", opens: "Remind"))
        XCTAssertEqual(entity.id, "remind")
        XCTAssertEqual(String(localized: entity.displayRepresentation.title), "Add a reminder")
        XCTAssertNotNil(entity.displayRepresentation.subtitle)
        let bare = VoiceShortcutEntity(ShortcutsVoiceCommand(id: "x", name: "Only title", opens: ""))
        XCTAssertNil(bare.displayRepresentation.subtitle)
    }

    func testEntityQueryFindsNothingForAnUnknownIdentifier() async throws {
        let found = try await VoiceShortcutQuery().entities(for: ["no-such-shortcut-\(UUID().uuidString)"])
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: Parameter resolution

    func testTheSentenceIsTheOpeningWordsThenTheWords() {
        let remind = voiceCommand("remind", "Add a reminder", "Remind {task}")
        XCTAssertEqual(ShortcutsBridge.sentence(for: remind, words: "call Dana at 5"), "Remind call Dana at 5")
        XCTAssertEqual(ShortcutsBridge.sentence(for: remind, words: "  call Dana \n"), "Remind call Dana")
        XCTAssertEqual(ShortcutsBridge.sentence(for: remind, words: nil), "Remind")
        XCTAssertEqual(ShortcutsBridge.sentence(for: remind, words: ""), "Remind")
        let two = voiceCommand("l", "Lights", "Lights on")
        XCTAssertEqual(ShortcutsBridge.sentence(for: two, words: nil), "Lights on")
        let hebrew = voiceCommand("h", "תזכורת", "תזכיר לי {task}")
        XCTAssertEqual(ShortcutsBridge.sentence(for: hebrew, words: "להתקשר לדנה"), "תזכיר לי להתקשר לדנה")
    }

    // MARK: Run a Voice launch shortcut

    func testRunBuildsTheSentencePlansItAndReturnsTheMainWords() async throws {
        let calls = Calls()
        ShortcutsBridge.services = services(calls: calls)
        let result = try await ShortcutsBridge.run(commandId: "remind", words: "call Dana at 5")
        XCTAssertEqual(calls.plans.count, 1)
        let plan = try XCTUnwrap(calls.plans.first)
        XCTAssertEqual(plan.commandId, "remind")
        XCTAssertEqual(plan.slots.first { $0.name == "task" }?.value, "call Dana at 5")
        XCTAssertEqual(result, plan.mainText)
        XCTAssertEqual(result, "call Dana at 5")
    }

    func testRunReturnsTheLastAnswerWhenAShortcutGaveOne() async throws {
        ShortcutsBridge.services = services(run: { _, answered in
            answered(VoiceShortcutAnswer(text: "first", keys: [:]))
            answered(VoiceShortcutAnswer(text: "Booked for 5 pm", keys: [:]))
            return .done
        })
        let result = try await ShortcutsBridge.run(commandId: "remind", words: "call Dana")
        XCTAssertEqual(result, "Booked for 5 pm")
    }

    func testAnEmptyAnswerFallsBackToTheMainWords() async throws {
        ShortcutsBridge.services = services(run: { _, answered in
            answered(VoiceShortcutAnswer(text: "", keys: [:]))
            return .done
        })
        let result = try await ShortcutsBridge.run(commandId: "remind", words: "call Dana")
        XCTAssertEqual(result, "call Dana")
    }

    func testRunOnlyEverRunsTheChosenVoiceCommand() async throws {
        // "Lights on" would match the second shortcut too if both were tried.
        var config = self.config()
        config.commands.append(voiceCommand("also", "Also remind", "Remind me {task}"))
        let calls = Calls()
        ShortcutsBridge.services = services(config: config, calls: calls)
        _ = try await ShortcutsBridge.run(commandId: "remind", words: "me to stretch")
        XCTAssertEqual(calls.plans.first?.commandId, "remind")
    }

    func testRunKeepsTheCancelPauseAndAnAnswerComesThroughTheRealExecutor() async throws {
        // A shortcut whose steps are a pause, then an Apple Shortcut. The real
        // executor runs; only the pause countdown and `shortcuts` are mocked.
        var config = VoiceLaunchConfig()
        config.commands = [voiceCommand("ask", "Ask", "Ask {q}", steps: [
            VoiceStep(kind: .confirm, text: "Asking: {q}", seconds: 3),
            VoiceStep(kind: .runAppleShortcut, text: "{q}", shortcutName: "Lookup"),
        ])]
        var paused = 0
        var ranProcess = 0
        func make(confirm: Bool) -> VoiceLaunchServices {
            VoiceLaunchServices(
                confirm: { _, tick in paused += 1; tick(3); return confirm },
                setClipboard: { _ in }, pressKey: { _ in true }, frontmostBundleId: { nil },
                runProcess: { _, args, _ in
                    ranProcess += 1
                    if let index = args.firstIndex(of: "--output-path") { try? "It is 21 degrees".write(toFile: args[index + 1], atomically: true, encoding: .utf8) }
                    return VoiceLaunchProcessResult(status: 0, timedOut: false)
                },
                session: URLSession(configuration: .ephemeral), now: { Date(timeIntervalSince1970: 0) }, macName: { "Test Mac" })
        }

        ShortcutsBridge.services = services(config: config, run: { plan, answered in
            await VoiceLaunchExecutor.run(plan, services: make(confirm: true), answered: answered)
        })
        let answer = try await ShortcutsBridge.run(commandId: "ask", words: "weather")
        XCTAssertEqual(paused, 1, "the pause before an acting step still applies")
        XCTAssertEqual(ranProcess, 1)
        XCTAssertEqual(answer, "It is 21 degrees")

        ShortcutsBridge.services = services(config: config, run: { plan, answered in
            await VoiceLaunchExecutor.run(plan, services: make(confirm: false), answered: answered)
        })
        do {
            _ = try await ShortcutsBridge.run(commandId: "ask", words: "weather")
            XCTFail("a cancelled pause stops the action")
        } catch let error as ShortcutsBridgeError {
            XCTAssertTrue(error.message.contains("Cancelled"), error.message)
        }
        XCTAssertEqual(ranProcess, 1, "nothing ran after the cancel")
    }

    func testRunSaysPlainlyWhyItStopped() async {
        ShortcutsBridge.services = services(run: { _, _ in
            .stopped(DictationAlert(title: "Couldn’t run “Lookup”", detail: "This Mac doesn’t have the Shortcut."))
        })
        await assertFails("Couldn’t run “Lookup”. This Mac doesn’t have the Shortcut.") {
            _ = try await ShortcutsBridge.run(commandId: "remind", words: "x")
        }
    }

    func testNoMatchShowsASentenceNotThePattern() {
        let voiceCommand = VoiceCommand(name: "Message", pattern: "WhatsApp {person:People} {message}", steps: [])
        var config = VoiceLaunchConfig.empty
        config.lists = [VoiceList(name: "People", fields: [], entries: [VoiceListEntry(names: ["Dana"])])]
        XCTAssertEqual(ShortcutsBridge.noMatch(.noneMatched, voiceCommand: voiceCommand, config: config).message,
                       "Those words don’t fit “Message”. For example: WhatsApp Dana running late")
    }

    func testRunFailureMessages() async {
        ShortcutsBridge.services = services()
        await assertFails("That command isn’t in Dictator any more. Choose it again in the Shortcuts action.") {
            _ = try await ShortcutsBridge.run(commandId: "gone", words: nil)
        }
        await assertFails("“Old one” is turned off in Dictator › Commands.") {
            _ = try await ShortcutsBridge.run(commandId: "off", words: "x")
        }
        await assertFails("Those words don’t fit “Lights”. For example: Lights on") {
            _ = try await ShortcutsBridge.run(commandId: "lights", words: "in the kitchen")
        }
    }

    // MARK: Dictate

    func testDictateReturnsTheCleanedTextAndSavesItMarkedAsShortcuts() async throws {
        let calls = Calls()
        ShortcutsBridge.services = services(calls: calls)
        let text = try await ShortcutsBridge.dictate(cleanUp: true)
        XCTAssertEqual(text, "Cleaned: um remind me")
        XCTAssertEqual(calls.finished.count, 1)
        XCTAssertEqual(calls.finished.first?.0, "um remind me")
        XCTAssertEqual(calls.finished.first?.1, true)
        let record = try XCTUnwrap(calls.saved.first)
        XCTAssertEqual(calls.saved.count, 1)
        XCTAssertEqual(record.text, "Cleaned: um remind me")
        XCTAssertEqual(record.heardText, "um remind me")
        XCTAssertEqual(record.source, "shortcuts")
        XCTAssertEqual(record.attribution.captureSource, CaptureSource.shortcuts.rawValue)
        XCTAssertEqual(record.modality, "voice")
        XCTAssertEqual(record.durationSeconds, 2.5)
        XCTAssertEqual(record.originEdgeId, "edge-1")
    }

    func testDictateWithCleanUpOffKeepsTheWordsAsSpoken() async throws {
        let calls = Calls()
        ShortcutsBridge.services = services(calls: calls)
        let text = try await ShortcutsBridge.dictate(cleanUp: false)
        XCTAssertEqual(text, "um remind me")
        XCTAssertEqual(calls.finished.first?.1, false, "dictionary replacements still apply, the AI model does not")
    }

    func testDictateHonoursTheExactSetting() async throws {
        let calls = Calls()
        ShortcutsBridge.services = services(cleanupAllowed: false, calls: calls)
        _ = try await ShortcutsBridge.dictate(cleanUp: true)
        XCTAssertEqual(calls.finished.first?.1, false)
    }

    func testDictateHeardNothingSavesNothing() async {
        let calls = Calls()
        ShortcutsBridge.services = services(heard: ShortcutsHeard(text: "   ", seconds: 1), calls: calls)
        await assertFails("Dictator didn’t hear anything. Check your microphone and try again.") {
            _ = try await ShortcutsBridge.dictate(cleanUp: true)
        }
        XCTAssertTrue(calls.saved.isEmpty)
        XCTAssertTrue(calls.finished.isEmpty)
    }

    func testDictateStopsWithTheReasonWhenTheSpeechPathIsUnreachable() async {
        let calls = Calls()
        ShortcutsBridge.services = services(listenError: ShortcutsBridgeError("This Mac isn’t connected to your main Mac right now."), calls: calls)
        await assertFails("This Mac isn’t connected to your main Mac right now.") {
            _ = try await ShortcutsBridge.dictate(cleanUp: true)
        }
        XCTAssertTrue(calls.saved.isEmpty)
    }

    func testDictateWhenCleanUpFailsReportsItAndSavesNothing() async {
        let calls = Calls()
        ShortcutsBridge.services = services(finish: { _, _ in throw ShortcutsBridgeError("The main Mac didn’t answer in time.") }, calls: calls)
        await assertFails("The main Mac didn’t answer in time.") {
            _ = try await ShortcutsBridge.dictate(cleanUp: true)
        }
        XCTAssertTrue(calls.saved.isEmpty)
    }

    // MARK: Clean up text

    func testCleanUpReturnsTheCleanedText() async throws {
        let calls = Calls()
        ShortcutsBridge.services = services(calls: calls)
        let text = try await ShortcutsBridge.cleanUp("so um call dana")
        XCTAssertEqual(text, "Cleaned: so um call dana")
        XCTAssertEqual(calls.finished.first?.1, true)
        XCTAssertTrue(calls.saved.isEmpty, "clean-up saves nothing")
    }

    func testCleanUpSaysWhenThereIsNoTextOrNoModel() async {
        ShortcutsBridge.services = services()
        await assertFails("There is no text to clean up.") { _ = try await ShortcutsBridge.cleanUp("  \n") }
        ShortcutsBridge.services = services(cleanupAvailable: false)
        await assertFails("No AI model is chosen for clean-up. Choose one in Dictator › Settings › Your Macs, then try again.") {
            _ = try await ShortcutsBridge.cleanUp("hello")
        }
    }

    func testTheCleanUpActionSaysItUsesAnAIModel() {
        let description = String(localized: CleanUpTextIntent.description.descriptionText)
        XCTAssertTrue(description.contains("AI model"), description)
    }

    // MARK: Failure messages

    func testEveryActionSaysPlainlyWhenDictatorIsNotReady() async {
        ShortcutsBridge.services = nil
        let message = "Dictator isn’t ready yet. Open Dictator and try again."
        await assertFails(message) { _ = try await ShortcutsBridge.dictate(cleanUp: true) }
        await assertFails(message) { _ = try await ShortcutsBridge.cleanUp("x") }
        await assertFails(message) { _ = try await ShortcutsBridge.run(commandId: "a", words: nil) }
    }

    func testAlertsBecomeOneSentenceAndErrorsKeepTheirWords() {
        let alert = DictationAlert(title: "Your speech couldn’t be turned into text", detail: "The speech server didn’t answer.", action: .macs)
        XCTAssertEqual(ShortcutsBridge.plain(DictationFailure(alert)),
                       "Your speech couldn’t be turned into text. The speech server didn’t answer.")
        XCTAssertEqual(ShortcutsBridge.plain(CoreHost.RemoteWorkError.failed("No answer.")), ShortcutsBridge.plain(message: CoreHost.RemoteWorkError.failed("No answer.").localizedDescription))
        XCTAssertEqual(ShortcutsBridge.plain(message: "One line"), "One line")
        XCTAssertEqual(String(localized: ShortcutsBridgeError("Plain words.").localizedStringResource), "Plain words.")
    }

    private func assertFails(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected “\(message)”", file: file, line: line)
        } catch let error as ShortcutsBridgeError {
            XCTAssertEqual(error.message, message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: History source

    func testAShortcutsDictationIsStoredWithItsSourceAndReplicatesLikeAnyRow() async throws {
        let saved = (AppSettings.shared.persistHistory, AppSettings.shared.surfacePolicy)
        addTeardownBlock {
            AppSettings.shared.persistHistory = saved.0
        }
        AppSettings.shared.persistHistory = true
        let schema = Repositories.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let repositories = Repositories.make(container: container)

        try await repositories.history.record(ShortcutsBridge.historyRecord(text: "Remind me to stretch", seconds: 3, originEdgeId: "edge-1"))
        let rows = try await repositories.historySync.pendingSync(limit: 10, excluding: [])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.source, "shortcuts")
        XCTAssertEqual(row.captureSource, "shortcuts")
        XCTAssertEqual(row.modality, "voice")
        XCTAssertEqual(row.text, "Remind me to stretch")
        // The wire form has only optional fields: an older Mac decodes it and
        // reads an unknown source as text it does not recognise.
        let decoded = try JSONDecoder().decode(DictationEntryDTO.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(decoded.source, "shortcuts")
    }

    func testTheNewCaptureSourceReadsAsDictationFromShortcuts() {
        XCTAssertEqual(CaptureSource(rawValue: "shortcuts"), .shortcuts)
        XCTAssertEqual(CaptureSource.shortcuts.title, "Dictation (from Shortcuts)")
        XCTAssertTrue(CaptureSource.shortcuts.isExact)
    }

    // MARK: The recording (Teach's path, with a longer limit)

    @MainActor private final class FakeRecorder: VoiceTeachRecording {
        var teachLevelObserver: ((Float) -> Void)?
        func beginTeachRecording() -> Bool { true }
        func endTeachRecording() -> CapturedAudio? {
            CapturedAudio(data: Data(count: 16_000 * 4), durationSeconds: 1, sampleRate: 16_000, frameCount: 16_000)
        }
        func cancelTeachRecording() {}
    }

    func testARecordingUsesTheTwoMinuteLimitAndReportsItsBadgeState() async throws {
        let service = VoiceTeachService()
        let recorder = FakeRecorder()
        service.recorder = recorder
        service.transcribe = { _ in "hello there" }
        let session = VoiceTeachSession(service: service, takeCount: 1)
        session.endpointer.maxSeconds = 120
        var now: TimeInterval = 0
        session.clock = { now }
        var phases: [VoiceTeachSession.Phase] = []
        var ticks: [(Float, Double?, Int)] = []
        session.onPhase = { phases.append($0) }
        session.onTick = { ticks.append(($0, $1, $2)) }

        let take = Task { await session.record() }
        for _ in 0..<50 where recorder.teachLevelObserver == nil { await Task.yield() }
        now = 0; recorder.teachLevelObserver?(0.3)
        now = 30; recorder.teachLevelObserver?(0.3)         // past Teach's 6 s limit: still recording
        XCTAssertEqual(session.phase, .recording)
        now = 31; recorder.teachLevelObserver?(0.0)
        now = 32; recorder.teachLevelObserver?(0.0)         // 1 s of quiet: the countdown shows
        XCTAssertEqual(session.phase, .recording)
        XCTAssertNotNil(ticks.last?.1)
        XCTAssertEqual(ticks.first?.2, 120)
        now = 33.1; recorder.teachLevelObserver?(0.0)       // 2 s of quiet ends it
        await take.value

        XCTAssertEqual(session.transcripts, ["hello there"])
        XCTAssertEqual(session.lastAudioSeconds, 1)
        XCTAssertEqual(phases, [.recording, .transcribing, .ready])
    }

    // MARK: Protocol

    func testTextCleanupMessagesRoundTripAndOlderPeersIgnoreThem() throws {
        let request = EdgeMessage.textCleanupRequest(requestId: "r1", text: "so um hello", useAI: true)
        XCTAssertEqual(try EdgeProtocolCodec.decodeEdgeMessage(try EdgeProtocolCodec.encode(request)), request)
        for result in [CoreMessage.textCleanupResult(requestId: "r1", text: "Hello.", error: nil),
                       CoreMessage.textCleanupResult(requestId: "r1", text: nil, error: "no model")] {
            XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(try EdgeProtocolCodec.encode(result)), result)
        }
        XCTAssertEqual(EdgeProtocol.version, 2, "new optional messages must not bump the version")
        XCTAssertEqual(EdgeMessage.textCleanupRequest(requestId: "r", text: "", useAI: false).type, "text.cleanup.request")
    }

    func testTheMainMacAnswersAConnectedMacsCleanUpRequest() async {
        let schema = Repositories.schema
        let container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let host = CoreHost(
            coreId: "core-1", repositories: Repositories.make(container: container), clock: { 0 }, makeSessionID: { "s1" },
            transcribe: { _, _ in ("", nil) }, recordHistory: { _, _, _, _, _, _ in },
            checkpointStore: RecordingCheckpointStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ShortcutsIntentsTests-\(UUID().uuidString)", isDirectory: true)))
        host.cleanUpText = { text, useAI in useAI ? text.uppercased() : text }

        let answered = expectation(description: "answered")
        answered.expectedFulfillmentCount = 2
        var replies: [CoreMessage] = []
        host.remoteEdgeSendOverride = { message, _ in replies.append(message); answered.fulfill() }
        host.apply(.message(.textCleanupRequest(requestId: "a", text: "hello", useAI: true), from: "remote"))
        host.apply(.message(.textCleanupRequest(requestId: "b", text: "hello", useAI: false), from: "remote"))
        await fulfillment(of: [answered], timeout: 2)
        XCTAssertTrue(replies.contains(.textCleanupResult(requestId: "a", text: "HELLO", error: nil)))
        XCTAssertTrue(replies.contains(.textCleanupResult(requestId: "b", text: "hello", error: nil)))

        host.cleanUpText = nil
        let failed = expectation(description: "failed")
        host.remoteEdgeSendOverride = { message, _ in
            if case .textCleanupResult("c", nil, let error?) = message, !error.isEmpty { failed.fulfill() }
        }
        host.apply(.message(.textCleanupRequest(requestId: "c", text: "hello", useAI: true), from: "remote"))
        await fulfillment(of: [failed], timeout: 2)
    }
}
