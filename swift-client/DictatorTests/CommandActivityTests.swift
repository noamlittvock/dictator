import XCTest
@testable import Dictator

final class CommandActivityTests: XCTestCase {
    @MainActor
    private func temporary(_ body: (CommandActivity, URL, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let oldDiagnostics = HotkeyService.diagnosticsPath
        HotkeyService.diagnosticsPath = folder.appendingPathComponent("diagnostics.log")
        defer {
            HotkeyService.diagnosticsPath = oldDiagnostics
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appendingPathComponent("recent-commands.json")
        let activity = CommandActivity(fileURL: file)
        try await body(activity, file, folder)
        await activity.flush()
    }

    private func plan(_ steps: [VoiceStep] = [], missing: String? = nil) -> VoiceLaunchPlan {
        VoiceLaunchPlan(commandId: "fixture-id", commandName: "Fixture command",
                        slots: [VoicePlanSlot(name: "slot-secret", value: "slot-value-secret", fields: ["detail": "field-secret"])],
                        steps: steps, mainText: "main-text-secret", missingDetail: missing)
    }

    private func services(confirm: Bool = true, press: Bool = true) -> VoiceLaunchServices {
        VoiceLaunchServices(confirm: { _, _ in confirm }, setClipboard: { _ in }, pressKey: { _ in press },
                            frontmostBundleId: { nil }, runProcess: { _, _, _ in nil },
                            session: URLSession(configuration: .ephemeral), now: { Date() }, macName: { "mac-name-secret" })
    }

    @MainActor
    func testCompletedRunHasOnlyThePermittedFields() async throws {
        try await temporary { activity, file, _ in
            let before = Date()
            let result = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .confirm, text: "step-secret", seconds: 0)]),
                                                       services: services(), trigger: .keyboard, activity: activity)
            guard case .done = result else { return XCTFail("Expected completion") }
            await activity.flush()
            let data = try Data(contentsOf: file)
            let record = try XCTUnwrap(activity.records.first)
            XCTAssertEqual(activity.records.count, 1)
            XCTAssertEqual(record.commandId, "fixture-id")
            XCTAssertEqual(record.commandName, "Fixture command")
            XCTAssertEqual(record.trigger, .keyboard)
            XCTAssertEqual(record.outcome, .done)
            XCTAssertNil(record.failureTitle)
            XCTAssertGreaterThanOrEqual(record.time, before)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            XCTAssertEqual(Set(json[0].keys), ["id", "time", "commandId", "commandName", "trigger", "outcome"])
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
        }
    }

    @MainActor
    func testPreflightFailureIsRecordedOnceWithoutItsSpokenDetail() async throws {
        try await temporary { activity, file, _ in
            var stepsRun = 0
            var svc = services()
            svc.pressKey = { _ in stepsRun += 1; return true }
            let result = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .pressKey, key: "tab")], missing: "person-secret has no phone number"),
                                                       services: svc, activity: activity)
            guard case .stopped = result else { return XCTFail("Expected failure") }
            XCTAssertEqual(stepsRun, 0)
            XCTAssertEqual(activity.records.count, 1)
            XCTAssertEqual(activity.records.first?.outcome, .failed)
            XCTAssertEqual(activity.records.first?.trigger, .voice)
            XCTAssertEqual(activity.records.first?.failureTitle, "The command could not finish")
            await activity.flush()
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("secret"))
        }
    }

    @MainActor
    func testCancelStopsTheChainAndRecordsStopped() async throws {
        try await temporary { activity, _, _ in
            var keys = 0
            var svc = services(confirm: false)
            svc.pressKey = { _ in keys += 1; return true }
            let result = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .confirm, seconds: 0), VoiceStep(kind: .pressKey, key: "tab")]),
                                                       services: svc, activity: activity)
            guard case .cancelled = result else { return XCTFail("Expected cancellation") }
            XCTAssertEqual(keys, 0)
            XCTAssertEqual(activity.records.count, 1)
            XCTAssertEqual(activity.records.first?.outcome, .stopped)
            XCTAssertNil(activity.records.first?.failureTitle)
        }
    }

    @MainActor
    func testStepFailureStopsTheChainAndKeepsOnlyAFixedTitle() async throws {
        try await temporary { activity, _, _ in
            var keys = 0
            var svc = services()
            svc.pressKey = { _ in keys += 1; return false }
            let result = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .pressKey, key: "tab"), VoiceStep(kind: .pressKey, key: "tab")]),
                                                       services: svc, trigger: .otherApp, activity: activity)
            guard case .stopped = result else { return XCTFail("Expected failure") }
            XCTAssertEqual(keys, 1)
            XCTAssertEqual(activity.records.count, 1)
            XCTAssertEqual(activity.records.first?.failureTitle, "Dictator couldn’t press the key")
            XCTAssertEqual(activity.records.first?.trigger, .otherApp)
        }
    }

    @MainActor
    func testMissingAndAmbiguousAppNamesAreNeverSaved() async throws {
        try await temporary { activity, file, folder in
            for names in [[], ["app-secret", "app-secret"]] as [[String]] {
                var svc = services()
                svc.installedApps = { names.map { VoiceInstalledApp(name: $0, url: folder.appendingPathComponent("Fixture.app")) } }
                _ = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .openApp, text: "app-secret")]), services: svc, activity: activity)
            }
            XCTAssertEqual(activity.records.count, 2)
            XCTAssertTrue(activity.records.allSatisfy { $0.outcome == .failed && $0.failureTitle == "The command could not finish" })
            await activity.flush()
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("secret"))
        }
    }

    func testUntrustedTitlesAlwaysBecomeFixedPlainText() {
        let titles = [
            "No command called “spoken-secret”", "No routine called “spoken-secret” on mac-secret",
            "More than one app is called “spoken-secret”: app-secret",
            "Couldn’t open app-secret on mac-secret", "app-secret isn’t in front",
            "Couldn’t find a place to type in app-secret", "That folder isn’t on mac-secret",
            "Couldn’t reach host-secret", "Couldn’t add to “file-secret”",
            "This Mac doesn’t have the Shortcut “spoken-secret”", "arbitrary-service-secret",
            DictationAlert.voiceCommandTie(heard: "spoken-secret", names: ["command-secret"]).title
        ]
        for title in titles {
            XCTAssertEqual(CommandActivityRecord.safeFailureTitle(title), "The command could not finish")
        }
        XCTAssertEqual(CommandActivityRecord.safeFailureTitle("Dictator needs Accessibility access"), "Dictator needs Accessibility access")
    }

    @MainActor
    func testWorkspaceServiceErrorsAreNotSavedVerbatim() async throws {
        try await temporary { activity, _, _ in
            var svc = services()
            svc.workspaceRoutines = { [WorkspaceRoutine(id: "routine", name: "routine-secret")] }
            svc.runWorkspace = { _ in throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "service-secret"]) }
            _ = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .runWorkspace, text: "routine-secret")]), services: svc, activity: activity)
            XCTAssertEqual(activity.records.first?.outcome, .failed)
            XCTAssertEqual(activity.records.first?.failureTitle, "The command could not finish")
        }
    }

    @MainActor
    func testLatestFiftyAreRetainedAcrossReloadAndClearRemovesTheFile() async throws {
        try await temporary { activity, file, _ in
            for index in 0..<60 {
                var p = plan()
                p.commandId = "fixture-\(index)"
                let run = await activity.begin(p)
                activity.finish(run, plan: p, trigger: .voice, result: .done)
            }
            await activity.flush()
            let reloaded = CommandActivity(fileURL: file)
            await reloaded.load()
            XCTAssertEqual(reloaded.records.map(\.commandId), (10..<60).reversed().map { "fixture-\($0)" })
            XCTAssertNil(reloaded.lastPlan, "A relaunch cannot restore the in-memory plan")
            activity.clear()
            await activity.flush()
            XCTAssertTrue(activity.records.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @MainActor
    func testCorruptFileIsIgnoredAndNextRunRepairsIt() async throws {
        try await temporary { activity, file, _ in
            try Data("not json".utf8).write(to: file)
            await activity.load()
            XCTAssertTrue(activity.records.isEmpty)
            _ = await VoiceLaunchExecutor.run(plan(), services: services(), activity: activity)
            await activity.flush()
            let records = try JSONDecoder().decode([CommandActivityRecord].self, from: Data(contentsOf: file))
            XCTAssertEqual(records.count, 1)
        }
    }

    @MainActor
    func testHistoryOffAndPauseDoNotWriteIncludingChangesDuringARun() async throws {
        try await temporary { _, file, _ in
            var saving = false
            var paused = false
            let activity = CommandActivity(fileURL: file, saveAllowed: { saving }, paused: { paused })
            _ = await VoiceLaunchExecutor.run(plan(), services: services(), activity: activity)
            let offRun = await activity.begin(plan())
            saving = true
            activity.finish(offRun, plan: plan(), trigger: .voice, result: .done)
            paused = true
            _ = await VoiceLaunchExecutor.run(plan(), services: services(), activity: activity)
            XCTAssertNil(activity.lastPlan)
            XCTAssertFalse(activity.canRunAgain)
            paused = false
            let interrupted = await activity.begin(plan())
            activity.pause()
            activity.finish(interrupted, plan: plan(), trigger: .voice, result: .done)
            let disabled = await activity.begin(plan())
            saving = false
            activity.finish(disabled, plan: plan(), trigger: .voice, result: .done)
            await activity.flush()
            XCTAssertTrue(activity.records.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @MainActor
    func testRunAgainReusesTheWordsAndPauseButPersistsNeither() async throws {
        try await temporary { activity, file, _ in
            var pauses: [Double] = []
            var pasted: [String] = []
            var svc = services()
            svc.confirm = { seconds, _ in pauses.append(seconds); return true }
            svc.pasteText = { text, _ in pasted.append(text); return .pasted }
            let p = plan([VoiceStep(kind: .confirm, text: "summary-secret", seconds: 2), VoiceStep(kind: .typeText, text: "typed-secret")])
            _ = await VoiceLaunchExecutor.run(p, services: svc, activity: activity)
            XCTAssertEqual(activity.lastPlan, p)
            let result = await activity.runAgain(services: svc)
            guard case .done? = result else { return XCTFail("Expected replay") }
            XCTAssertEqual(pauses, [2, 2])
            XCTAssertEqual(pasted, ["typed-secret", "typed-secret"])
            XCTAssertEqual(activity.records.map(\.trigger), [.runAgain, .voice])
            await activity.flush()
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("secret"))
            activity.pause()
            XCTAssertNil(activity.lastPlan)
            let afterPause = await activity.runAgain(services: svc)
            XCTAssertNil(afterPause)
            XCTAssertEqual(pauses.count, 2)
        }
    }

    @MainActor
    func testClearInvalidatesARunInProgress() async throws {
        try await temporary { activity, file, _ in
            let run = await activity.begin(plan())
            activity.clear()
            activity.finish(run, plan: plan(), trigger: .voice, result: .done)
            await activity.flush()
            XCTAssertTrue(activity.records.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @MainActor
    func testUnmatchedWordsCannotCreateAnActivityRecord() async throws {
        try await temporary { activity, _, _ in
            guard case .noMatch = VoiceLaunchEngine.plan(for: "unmatched-secret", in: .empty) else { return XCTFail("Expected no plan") }
            XCTAssertTrue(activity.records.isEmpty)
            XCTAssertNil(activity.lastPlan)
            // An unknown stored kind cannot reach the executor: every
            // representable kind is supported, preserving older config decoding.
            XCTAssertEqual(VoiceLaunchExecutor.supportedKinds, Set(VoiceStep.Kind.allCases))
        }
    }
}
