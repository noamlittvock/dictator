import XCTest
@testable import Dictator

final class VoiceLaunchRobustnessTests: XCTestCase {
    private func services(front: String? = nil, trusted: Bool = true, mac: String = "Test Mac",
                          sleep: @escaping (Duration) async -> Void = { _ in },
                          frontProvider: (() -> String?)? = nil,
                          paste: @escaping (String, String?) async -> PasteService.Outcome = { _, _ in .pasted },
                          installed: @escaping (String) -> Bool = { _ in false }) -> VoiceLaunchServices {
        VoiceLaunchServices(confirm: { _, _ in true }, setClipboard: { _ in }, pressKey: { _ in true },
            frontmostBundleId: { frontProvider?() ?? front }, runProcess: { _, _, _ in nil },
            session: URLSession(configuration: .ephemeral), now: { Date(timeIntervalSince1970: 0) },
            macName: { mac }, isAccessibilityTrusted: { trusted }, sleep: sleep, pasteText: paste, appInstalled: installed)
    }

    private func plan(_ steps: [VoiceStep]) -> VoiceLaunchPlan {
        VoiceLaunchPlan(commandId: "test", commandName: "Test", slots: [], steps: steps, mainText: "spoken words")
    }

    @MainActor
    func testTypeTextDoesNotPasteIntoDifferentFrontmostApp() async {
        var pasted = false
        let services = services(front: "other.app", paste: { _, _ in pasted = true; return .pasted })
        do {
            try await VoiceLaunchExecutor.typeText(VoiceStep(kind: .typeText, text: "hello"),
                context: .init(appBundleId: "expected.app", appName: "Expected"), services: services)
            XCTFail("expected front-app failure")
        } catch let failure as VoiceLaunchExecutor.Failure {
            XCTAssertEqual(failure.alert.title, "Expected isn’t in front")
            XCTAssertEqual(failure.alert.detail, "Nothing was typed. Your words are on the clipboard.")
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertFalse(pasted)
    }

    @MainActor
    func testTypeTextPastesWhenChainAppIsFrontmost() async throws {
        var pasted: String?
        var expectedBundleID: String?
        let services = services(front: "expected.app", paste: { text, expected in
            pasted = text
            expectedBundleID = expected
            return .pasted
        })
        try await VoiceLaunchExecutor.typeText(VoiceStep(kind: .typeText, text: "hello"),
            context: .init(appBundleId: "expected.app", appName: "Expected"), services: services)
        XCTAssertEqual(pasted, "hello")
        XCTAssertEqual(expectedBundleID, "expected.app")
    }

    @MainActor
    func testTypeTextFailsWhenThePasteSeesAnotherAppInFront() async {
        // PasteService checks the expected app right before ⌘V and refuses.
        var expectedBundleID: String?
        let services = services(frontProvider: { "expected.app" }, paste: { _, expected in
            expectedBundleID = expected
            return .clipboardOnly("Expected isn’t in front. Nothing was typed.", needsAccessibility: false)
        })
        do {
            try await VoiceLaunchExecutor.typeText(VoiceStep(kind: .typeText, text: "hello"),
                context: .init(appBundleId: "expected.app", appName: "Expected"), services: services)
            XCTFail("expected clipboard-only failure")
        } catch let failure as VoiceLaunchExecutor.Failure {
            XCTAssertEqual(failure.alert.title, "Your words are on the clipboard")
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(expectedBundleID, "expected.app")
    }

    @MainActor
    func testFocusChangeAfterACompletedPasteIsNotAFailure() async throws {
        var front: String? = "expected.app"
        let services = services(frontProvider: { front }, paste: { _, _ in
            front = "other.app"
            return .pasted
        })
        try await VoiceLaunchExecutor.typeText(VoiceStep(kind: .typeText, text: "hello"),
            context: .init(appBundleId: "expected.app", appName: "Expected"), services: services)
    }

    @MainActor
    func testTypeTextStopsBeforePasteWithoutAccessibility() async {
        var pasted = false
        do {
            try await VoiceLaunchExecutor.typeText(VoiceStep(kind: .typeText, text: "hello"), context: .init(),
                services: services(trusted: false, paste: { _, _ in pasted = true; return .pasted }))
            XCTFail("expected permission failure")
        } catch let failure as VoiceLaunchExecutor.Failure {
            XCTAssertEqual(failure.alert.title, "Dictator needs Accessibility access")
            XCTAssertEqual(failure.alert.detail, "Turn it on in System Settings › Privacy & Security › Accessibility. Your words are on the clipboard.")
            XCTAssertEqual(failure.alert.action, .accessibilityPrivacy)
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertFalse(pasted)
    }

    @MainActor
    func testAccessibilityReadinessFailureIsImmediateAndActionable() async {
        do {
            try await VoiceLaunchExecutor.requireAccessibility(services(trusted: false))
            XCTFail("expected permission failure")
        } catch let failure as VoiceLaunchExecutor.Failure {
            XCTAssertEqual(failure.alert.action, .accessibilityPrivacy)
        } catch { XCTFail("unexpected error: \(error)") }
    }

    @MainActor
    func testOpenedAppWaitFinishesWhenFrontmostChanges() async throws {
        var front: String? = nil
        var sleeps = 0
        let services = VoiceLaunchServices(confirm: { _, _ in true }, setClipboard: { _ in }, pressKey: { _ in true },
            frontmostBundleId: { front }, runProcess: { _, _, _ in nil }, session: URLSession(configuration: .ephemeral),
            now: { Date() }, macName: { "Test Mac" }, sleep: { _ in sleeps += 1; front = "target.app" })
        try await VoiceLaunchExecutor.waitForFrontmost(context: .init(appBundleId: "target.app", appName: "Target"), services: services)
        XCTAssertEqual(sleeps, 1)
    }

    @MainActor
    func testOpenedAppWaitFailsAfterTenInjectedSeconds() async {
        var sleeps = 0
        let services = VoiceLaunchServices(confirm: { _, _ in true }, setClipboard: { _ in }, pressKey: { _ in true },
            frontmostBundleId: { "other.app" }, runProcess: { _, _, _ in nil }, session: URLSession(configuration: .ephemeral),
            now: { Date() }, sleep: { _ in sleeps += 1 })
        do {
            try await VoiceLaunchExecutor.waitForFrontmost(context: .init(appBundleId: "target.app", appName: "Target"), services: services)
            XCTFail("expected timeout")
        } catch let failure as VoiceLaunchExecutor.Failure {
            XCTAssertEqual(failure.alert.title, "Target didn’t come to the front")
            XCTAssertEqual(failure.alert.detail, "Your words are on the clipboard.")
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(sleeps, 40)
    }

    @MainActor
    func testAccessibilityIsCheckedBeforeWaitingForOpenedApp() async {
        var sleeps = 0
        let services = services(front: "other.app", trusted: false, sleep: { _ in sleeps += 1 })
        do {
            try await VoiceLaunchExecutor.waitForOpenedAppIfNeeded(
                next: VoiceStep(kind: .typeText, text: "hello"),
                context: .init(appBundleId: "target.app", appName: "Target"), services: services)
            XCTFail("expected permission failure")
        } catch let failure as VoiceLaunchExecutor.Failure {
            XCTAssertEqual(failure.alert.title, "Dictator needs Accessibility access")
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(sleeps, 0)
    }

    @MainActor
    func testAppNotFoundNamesAppAndThisMac() {
        let alert = VoiceLaunchExecutor.appNotFound("com.example.NoSuchThing", services: services())
        XCTAssertEqual(alert.title, "NoSuchThing isn’t on Test Mac")
        XCTAssertEqual(alert.detail, "Install it on this Mac, or run the command from a Mac that has it. Your words are on the clipboard.")
    }

    @MainActor
    func testAnInstalledAppThatFailsToOpenIsNotCalledMissing() {
        let alert = VoiceLaunchExecutor.appDidNotOpen("Notes", services: services())
        XCTAssertEqual(alert.title, "Couldn’t open Notes on Test Mac")
        XCTAssertTrue(alert.detail.contains("Your words are on the clipboard."))
        XCTAssertFalse(alert.detail.contains("Install"))
    }

    @MainActor
    func testFolderNotFoundNamesThisMac() {
        let alert = VoiceLaunchExecutor.folderNotFound("/gone", macName: "Test Mac")
        XCTAssertEqual(alert.title, "That folder isn’t on Test Mac")
        XCTAssertTrue(alert.detail.contains("Your words are on the clipboard."))
    }

    @MainActor
    func testReadinessReportsMissingAppOnThisMac() {
        let p = plan([VoiceStep(kind: .openApp, bundleId: "com.example.Missing")])
        let problems = VoiceLaunchReadiness.problems(for: p, services: services(), appInstalled: { _ in false }, folderExists: { _ in true })
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("Test Mac"))
    }

    @MainActor
    func testReadinessReportsMissingFolder() {
        let p = plan([VoiceStep(kind: .runInTerminal, folder: "/gone")])
        let problems = VoiceLaunchReadiness.problems(for: p, services: services(), appInstalled: { $0 == "com.apple.Terminal" }, folderExists: { _ in false })
        XCTAssertTrue(problems.contains { $0.contains("folder") && $0.contains("Test Mac") })
    }

    /// A background command opens no terminal, so a missing one isn't a problem.
    @MainActor
    func testReadinessDoesNotNeedATerminalForABackgroundCommand() {
        let p = plan([VoiceStep(kind: .runInTerminal, folder: "/here", command: "true", background: true)])
        let problems = VoiceLaunchReadiness.problems(for: p, services: services(), appInstalled: { _ in false }, folderExists: { _ in true })
        XCTAssertEqual(problems.filter { $0.lowercased().contains("terminal") }, [])
    }

    @MainActor
    func testReadinessSkipsDeferredFolderUntilShortcutAnswerExists() {
        let deferred = VoiceDeferred(slots: [], templates: ["folder": "{answer_folder}"], cleanUpSlot: nil, said: "")
        let p = plan([VoiceStep(kind: .runInTerminal, folder: "", deferred: deferred)])
        let problems = VoiceLaunchReadiness.problems(for: p, services: services(), appInstalled: { $0 == "com.apple.Terminal" }, folderExists: { _ in false })
        XCTAssertFalse(problems.contains { $0.localizedCaseInsensitiveContains("folder") })
    }

    @MainActor
    func testReadinessChecksADeferredStepsFixedFolder() {
        // Only the argument waits on an answer; the folder is known and missing.
        let deferred = VoiceDeferred(slots: [], templates: ["folder": "/missing", "argument": "{answer_summary}"], cleanUpSlot: nil, said: "")
        let p = plan([VoiceStep(kind: .runInTerminal, folder: "", argument: "", deferred: deferred)])
        let problems = VoiceLaunchReadiness.problems(for: p, services: services(), appInstalled: { $0 == "com.apple.Terminal" }, folderExists: { _ in false })
        XCTAssertTrue(problems.contains { $0.contains("folder") && $0.contains("Test Mac") })
    }

    @MainActor
    func testReadinessReportsMissingAccessibility() {
        let p = plan([VoiceStep(kind: .pressKey, key: "return")])
        let problems = VoiceLaunchReadiness.problems(for: p, services: services(trusted: false), appInstalled: { _ in true }, folderExists: { _ in true })
        XCTAssertTrue(problems.contains { $0.contains("Accessibility") && $0.contains("Test Mac") })
    }

    func testTerminalResolutionChoosesFirstInstalledBundleId() {
        let app = HostApp(id: "terminal", name: "Terminal", kind: .terminal, bundleIDs: ["first", "second"], runsScripts: true)
        XCTAssertEqual(VoiceLaunchReadiness.terminalBundle(for: app) { $0 == "second" }, "second")
    }

    func testTerminalResolutionReturnsNilWhenNotInstalled() {
        let app = HostApp(id: "iterm", name: "iTerm", kind: .terminal, bundleIDs: ["one"], runsScripts: true)
        XCTAssertNil(VoiceLaunchReadiness.terminalBundle(for: app) { _ in false })
    }

    func testTerminalResolutionRejectsAppsThatDoNotRunScripts() {
        let app = HostApp(id: "other", name: "Other", kind: .terminal, bundleIDs: ["one"], runsScripts: false)
        XCTAssertNil(VoiceLaunchReadiness.terminalBundle(for: app) { _ in true })
    }

    func testHostAppDecodesRunsScriptsWhenPresent() throws {
        let data = #"{"id":"iterm","name":"iTerm","kind":"terminal","bundle_ids":["bundle"],"runs_scripts":true}"#.data(using: .utf8)!
        XCTAssertTrue(try JSONDecoder().decode(HostApp.self, from: data).runsScripts)
    }

    func testHostAppDefaultsRunsScriptsToFalseWhenMissing() throws {
        let data = #"{"id":"kitty","name":"kitty","kind":"terminal","bundle_ids":["bundle"]}"#.data(using: .utf8)!
        XCTAssertFalse(try JSONDecoder().decode(HostApp.self, from: data).runsScripts)
    }
}


extension VoiceLaunchRobustnessTests {
    @MainActor
    func testAppNameResolvesOnlyInInjectedTargetInventory() async {
        let app = VoiceInstalledApp(name: "ChatGPT", url: URL(fileURLWithPath: "/synthetic/ChatGPT.app"), bundleID: "test.chat")
        var opened: [URL] = []
        var svc = services()
        svc.installedApps = { [app] }
        svc.openNamedApp = { opened.append($0); return true }
        guard case .done = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .openApp, text: "chat gpt.")]), services: svc) else { return XCTFail() }
        XCTAssertEqual(opened, [app.url])
    }

    @MainActor
    func testAppNameFailuresKeepWordsAndNeverOpenOrContinue() async {
        for names in [[], ["ChatGPT", "Chat GPT (Beta)"]] as [[String]] {
            var clipboard = ""
            var continued = false
            var svc = services()
            svc.setClipboard = { clipboard = $0 }
            svc.installedApps = { names.map { VoiceInstalledApp(name: $0, url: URL(fileURLWithPath: "/synthetic/\($0).app")) } }
            svc.openNamedApp = { _ in XCTFail("Must refuse"); return false }
            svc.pasteText = { _, _ in continued = true; return .pasted }
            let result = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .openApp, text: "chat gpt."), VoiceStep(kind: .typeText, text: "later")]), services: svc)
            guard case .stopped(let alert) = result else { return XCTFail() }
            XCTAssertEqual(alert.title, names.isEmpty ? "No app called “chat gpt.” on Test Mac" : "More than one app is called “chat gpt.”: ChatGPT, Chat GPT (Beta)")
            XCTAssertEqual(alert.detail, "Your words are on the clipboard.")
            XCTAssertEqual(clipboard, "spoken words")
            XCTAssertFalse(continued)
        }
    }

    @MainActor
    func testWorkspaceIsAwaitedBeforeLaterStepsAndFailureStopsThem() async {
        for fail in [false, true] {
            var events: [String] = []
            var clipboard = ""
            var svc = services()
            svc.workspaceRoutines = { [WorkspaceRoutine(id: "writing", name: "Wríting (Desk)", actions: [])] }
            svc.runWorkspace = { id in
                XCTAssertEqual(id, "writing")
                events.append("workspace started")
                await Task.yield()
                events.append("workspace finished")
                if fail { throw WorkspaceLaunchError.unavailable("Synthetic workspace failure") }
            }
            svc.setClipboard = { clipboard = $0 }
            svc.pasteText = { _, _ in events.append("typed"); return .pasted }
            let result = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .runWorkspace, text: "writing."), VoiceStep(kind: .typeText, text: "later")]), services: svc)
            if fail {
                guard case .stopped(let alert) = result else { return XCTFail() }
                XCTAssertEqual(alert.title, "Synthetic workspace failure")
                XCTAssertEqual(events, ["workspace started", "workspace finished"])
                XCTAssertEqual(clipboard, "spoken words")
            } else {
                guard case .done = result else { return XCTFail() }
                XCTAssertEqual(events, ["workspace started", "workspace finished", "typed"])
            }
        }
    }

    @MainActor
    func testWorkspaceNamesRefuseMissingAndAmbiguousMatches() async {
        for names in [[], ["Writing", "Wríting (Beta)"]] as [[String]] {
            var svc = services()
            svc.workspaceRoutines = { names.map { WorkspaceRoutine(name: $0, actions: []) } }
            svc.runWorkspace = { _ in XCTFail("Must refuse") }
            let result = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .runWorkspace, text: "writing")]), services: svc)
            guard case .stopped(let alert) = result else { return XCTFail() }
            XCTAssertEqual(alert.title, names.isEmpty ? "No routine called “writing” on Test Mac" : "More than one routine is called “writing”: Writing, Wríting (Beta)")
            XCTAssertEqual(alert.detail, "Check the routine names in Workspaces. Your words are on the clipboard.")
            XCTAssertNil(alert.action)
        }
    }
}

extension VoiceLaunchRobustnessTests {
    @MainActor
    func testWorkspaceIDWinsOverOldNameAndDuplicateNames() async {
        var svc = services()
        var ran: [String] = []
        svc.workspaceRoutines = { [WorkspaceRoutine(id: "stable", name: "Renamed", actions: []), WorkspaceRoutine(id: "other", name: "Writing", actions: [])] }
        svc.runWorkspace = { ran.append($0) }
        let result = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .runWorkspace, text: "Writing", workspaceId: "stable")]), services: svc)
        guard case .done = result else { return XCTFail() }
        XCTAssertEqual(ran, ["stable"])
    }

    @MainActor
    func testMissingWorkspaceIDNeverFallsBackToNameOrContinues() async {
        var svc = services()
        var clipboard = ""
        svc.workspaceRoutines = { [WorkspaceRoutine(id: "other", name: "Writing", actions: [])] }
        svc.runWorkspace = { _ in XCTFail("Must not resolve by name") }
        svc.pasteText = { _, _ in XCTFail("Must stop the chain"); return .pasted }
        svc.setClipboard = { clipboard = $0 }
        let result = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .runWorkspace, text: "Writing", workspaceId: "missing"), VoiceStep(kind: .typeText, text: "Later")]), services: svc)
        guard case .stopped(let alert) = result else { return XCTFail() }
        XCTAssertEqual(alert.title, "No routine called “Writing” on Test Mac")
        XCTAssertNil(alert.action)
        XCTAssertEqual(alert.detail, "Check the routine names in Workspaces. Your words are on the clipboard.")
        XCTAssertEqual(clipboard, "spoken words")
    }

    @MainActor
    func testDisabledWorkspaceIDUsesExistingPlainFailure() async {
        var svc = services()
        svc.workspaceRoutines = { [WorkspaceRoutine(id: "stable", name: "Writing", enabled: false, actions: [])] }
        svc.runWorkspace = { _ in XCTFail("An off routine must not run") }
        let result = await VoiceLaunchExecutor.run(plan([VoiceStep(kind: .runWorkspace, text: "Start writing", workspaceId: "stable")]), services: svc)
        guard case .stopped(let alert) = result else { return XCTFail() }
        XCTAssertEqual(alert.title, "This routine is off. Turn it on to run it.")
    }
}
