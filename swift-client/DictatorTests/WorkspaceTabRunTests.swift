import XCTest
@testable import Dictator

@MainActor
final class WorkspaceTabRunTests: XCTestCase {
    private final class Adapter: WorkspaceLaunchAdapter {
        struct Launch {
            var bundleID: String
            var profile: String?
            var urls: [String]
            var timeout: TimeInterval
        }
        var isAccessibilityGranted = true
        // These tests are about launching; window tracking has its own tests.
        func opensOwnWindow(bundleID: String) -> Bool { false }
        var monotonicTime: TimeInterval = 0
        var browsers = [WorkspaceBrowserInfo(bundleID: "browser", name: "Browser", profiles: [
            .init(directory: "Profile 1", name: "Work")
        ])]
        var discoveries = 0
        var discoveryDelay: TimeInterval = 0
        var running: Set<String> = []
        var launches: [Launch] = []
        var waits: [TimeInterval] = []
        var events: [String] = []
        var launchDelay: TimeInterval = 0
        var waitDelay: TimeInterval = 0
        var refused: Set<String> = []
        var throwsOnLaunch = false
        var timesOutOnLaunch = false
        var moveFails = false
        var moveDelay: TimeInterval = 0
        var throwsOnWait = false
        var beforeLaunch: (() -> Void)?
        var beforeDiscovery: (() -> Void)?
        var captureFails = false
        var requestedWindows: [Set<String>] = []
        var requestedApps: [Set<String>] = []
        var moves: [String] = []
        var windows: [WorkspaceWindow] = []
        let screen = WorkspaceDisplay(id: "screen", name: "Main", visibleFrame: .init(width: 1200, height: 900), isMain: true)
        var runningBundleIDs: Set<String> { running }
        func requestPermission() { XCTFail("Synthetic tests never request permission") }
        func isAppRunning(bundleID: String) -> Bool { running.contains(bundleID) }
        func isAppInstalled(bundleID: String) -> Bool { true }
        func openApp(bundleID: String, timeout: TimeInterval) async throws -> Bool {
            events.append("app")
            running.insert(bundleID)
            return true
        }
        func installedBrowsers() async -> [WorkspaceBrowserInfo] {
            discoveries += 1
            monotonicTime += discoveryDelay
            beforeDiscovery?()
            return browsers
        }
        func openTabs(bundleID: String, profileDirectory: String?, urls: [String], timeout: TimeInterval) async throws -> Bool {
            launches.append(.init(bundleID: bundleID, profile: profileDirectory, urls: urls, timeout: timeout))
            events.append("tabs")
            beforeLaunch?()
            monotonicTime += launchDelay
            if timesOutOnLaunch { throw WorkspaceTabOpenTimedOut() }
            if throwsOnLaunch { throw WorkspaceLaunchError.unavailable("https://private.example/ Profile 1 Work") }
            if refused.contains(bundleID) { return false }
            running.insert(bundleID)
            return true
        }
        func waitForFirstWindow(bundleID: String, timeout: TimeInterval) async throws -> Bool {
            waits.append(timeout)
            events.append("wait")
            monotonicTime += waitDelay
            if throwsOnWait { throw WorkspaceLaunchError.unavailable("Synthetic wait failure") }
            return true
        }
        func capture(lastActivatedAt: [String: Date], excluding: Set<String>, preferredFrontmostBundleID: String?, windowBundleIDs: Set<String>, applicationBundleIDs: Set<String>) async throws -> WorkspaceSnapshot {
            requestedWindows.append(windowBundleIDs)
            requestedApps.append(applicationBundleIDs)
            events.append("capture")
            if captureFails { throw WorkspaceLaunchError.unavailable("Synthetic capture failure") }
            return .init(displays: [screen], windows: windows.filter { windowBundleIDs.contains($0.bundleID) },
                         applications: running.filter { applicationBundleIDs.contains($0) }.map { .init(bundleID: $0) })
        }
        func moveWindow(id: String, to frame: WorkspaceRect) async throws {
            events.append("move")
            moves.append(id)
            monotonicTime += moveDelay
            if moveFails { throw WorkspaceLaunchError.unavailable("Synthetic move failure") }
        }
        func hideApp(bundleID: String) throws -> Bool { false }
        func unhideApp(bundleID: String) throws {}
        func retainWindows(ids: Set<String>) {}
    }

    private final class Fleet: WorkspaceFleet {
        var otherMacNames = ["Book"]
        var localWorkspaceMacID: String? = "setup-mini"
        var workspaceMacs = [WorkspaceMacOption(id: "setup-book", name: "Book", online: true)]
        var layouts: [String: WorkspaceSavedLayout] = [:]
        var captureThrows = false
        var reports: [WorkspaceRunReport] = []
        var runs = 0
        var calls: [(routineID: String, undo: Bool, operationID: String?)] = []
        func rememberEverywhere() async throws -> (layouts: [String: WorkspaceSavedLayout], unanswered: [String], busy: [String]) {
            if captureThrows { throw WorkspaceLaunchError.unavailable("Synthetic fleet failure") }
            return (layouts, [], [])
        }
        func runElsewhere(routineID: String, undo: Bool, operationID: String?) async throws -> [WorkspaceRunReport] {
            runs += 1
            calls.append((routineID, undo, operationID))
            return reports
        }
    }

    private func set(_ id: String = "one", mac: String = "mini", browser: String = "browser",
                     profile: WorkspaceBrowserProfile? = nil, urls: [String] = ["https://example.com"]) -> WorkspaceTabSet {
        .init(id: id, macID: mac, macName: mac == "mini" || mac == "setup-mini" ? "Mini" : "Book",
              browserBundleID: browser, browserName: browser == "browser" ? "Browser" : browser, profile: profile, urls: urls)
    }
    private func routine(_ sets: [WorkspaceTabSet], extra: [WorkspaceAction] = []) -> WorkspaceRoutine {
        .init(id: "tabs", name: "Desk", actions: [
            .init(kind: .arrangeWindows, bundleIDs: Array(Set(sets.map(\.browserBundleID))).sorted(), tabSets: sets)
        ] + extra)
    }
    private func open(_ routine: WorkspaceRoutine, adapter: Adapter, deadline: TimeInterval = 50) async -> WorkspaceTabRun {
        await WorkspaceLaunchExecutor.openTabSets(in: routine, macID: "mini", aliases: ["setup-mini"], macName: "Mini",
                                                 adapter: adapter, deadline: deadline)
    }
    private func controller(_ adapter: Adapter, settings: AppSettings) -> WorkspaceLaunchController {
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "mini" })
        controller.macName = { "Mini" }
        controller.diagnostics = { _ in }
        return controller
    }
    private func layout(_ adapter: Adapter, name: String = "Book", browsers: [WorkspaceBrowserInfo]? = nil) -> WorkspaceSavedLayout {
        .init(macName: name, capturedAt: Date(timeIntervalSince1970: 0), screens: [adapter.screen], windows: [
            .init(bundleID: "editor", appName: "Editor", screenID: "screen", place: .init(width: 0.5, height: 1))
        ], browsers: browsers)
    }

    func testLocalSetsKeepRoutineAndTabOrderAndColdBrowserOpensTwice() async {
        let adapter = Adapter()
        adapter.launchDelay = 2
        let profile = WorkspaceBrowserProfile(directory: "Profile 1", name: "Work")
        var value = routine([set(mac: "setup-mini", profile: profile, urls: ["https://a.example", "https://b.example"]), set("remote", mac: "book")])
        value.actions += routine([set("two")]).actions
        let result = await open(value, adapter: adapter)
        XCTAssertEqual(adapter.discoveries, 1)
        XCTAssertEqual(adapter.launches.map(\.urls), [["https://a.example", "https://b.example"], ["https://example.com"]])
        XCTAssertEqual(adapter.launches.first?.profile, "Profile 1")
        XCTAssertEqual(adapter.waits, [6])
        XCTAssertEqual(result.tabsOpened, 3)
        XCTAssertEqual(result.windowsOpened, 2)
        XCTAssertEqual(result.started, ["browser"])
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testBlockedAndInvalidSetsSkipWithoutPassingUnsafeAddresses() async {
        let adapter = Adapter()
        let result = await open(routine([
            set("missing", browser: "Absent"),
            set("profile", profile: .init(directory: "Missing", name: "Personal")),
            set("invalid", urls: ["https://example.com", "--incognito"]),
            set("empty", urls: []), set("good")
        ]), adapter: adapter)
        XCTAssertEqual(adapter.launches.count, 1)
        XCTAssertEqual(result.tabsOpened, 1)
        XCTAssertEqual(result.notes.count, 3, "The two generic Browser failure notes collapse")
        XCTAssertFalse(result.notes.joined().contains("--incognito"))
        XCTAssertFalse(result.notes.joined().contains("https://"))
    }

    func testFalseAndThrownLaunchesCollapseNotesAndContinue() async {
        for throwsOnLaunch in [false, true] {
            let adapter = Adapter()
            adapter.refused = ["browser"]
            adapter.throwsOnLaunch = throwsOnLaunch
            let result = await open(routine([set(), set("two")]), adapter: adapter)
            XCTAssertEqual(adapter.launches.count, 2)
            XCTAssertEqual(result.tabsOpened, 0)
            XCTAssertTrue(result.started.isEmpty)
            XCTAssertEqual(result.notes, ["Browser couldn't open on Mini, so its tabs didn't open."])
            XCTAssertTrue(adapter.waits.isEmpty)
        }
    }

    func testDeadlineBoundsLaunchAndWaitThenNotesEveryRemainingBrowser() async {
        let adapter = Adapter()
        adapter.discoveryDelay = 1
        adapter.launchDelay = 2
        adapter.waitDelay = 1
        let result = await open(routine([set(), set("two"), set("other", browser: "Other")]), adapter: adapter, deadline: 4)
        XCTAssertEqual(adapter.launches.map(\.timeout), [3])
        XCTAssertEqual(adapter.waits, [1])
        XCTAssertEqual(result.tabsOpened, 1)
        XCTAssertEqual(result.notes.count, 2)
        XCTAssertTrue(result.notes.allSatisfy { $0.contains("didn't open in time") })
    }

    func testExpiredDeadlineAndCancellationOpenNothing() async {
        let adapter = Adapter()
        let expired = await open(routine([set()]), adapter: adapter, deadline: 0)
        XCTAssertEqual(expired.notes.count, 1)
        let task = Task { @MainActor in
            await self.open(self.routine([self.set()]), adapter: adapter)
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.notes.count, 1)
        XCTAssertTrue(adapter.launches.isEmpty)
    }

    func testCancellationBetweenSetsStopsAndSuccessfulWaitThrowKeepsCounts() async {
        let adapter = Adapter()
        adapter.throwsOnWait = true
        var task: Task<WorkspaceTabRun, Never>!
        adapter.beforeLaunch = { task.cancel() }
        task = Task { @MainActor in await self.open(self.routine([self.set(), self.set("two")]), adapter: adapter) }
        let result = await task.value
        XCTAssertEqual(result.tabsOpened, 1)
        XCTAssertEqual(adapter.launches.count, 1)
        XCTAssertEqual(result.notes.count, 1)
        let slow = Adapter()
        slow.throwsOnWait = true
        let waited = await open(routine([set()]), adapter: slow)
        XCTAssertEqual(waited.tabsOpened, 1)
        XCTAssertEqual(waited.started, ["browser"])
    }

    func testTabOnlyRemoteRunCountsTabsWithoutCaptureAppsSkipsOrUndo() async {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings)
        let fleet = Fleet()
        controller.fleet = fleet
        XCTAssertTrue(controller.saveRoutine(routine([set(mac: "setup-mini", urls: ["https://a.example", "https://b.example", "https://c.example"])])))
        let report = await controller.answerRunReport(routineID: "tabs", undo: false, from: "Book", operationID: "operation")
        XCTAssertEqual(report.summary, "opened 3 tabs.")
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.counts?.tabsOpened, 3)
        XCTAssertEqual(report.counts?.appsOpened, 1)
        XCTAssertEqual(report.counts?.skips, [:])
        // Finding its own window reads only the browser, never anything else.
        XCTAssertTrue(adapter.requestedWindows.allSatisfy { $0.isSubset(of: ["browser"]) })
        XCTAssertTrue(adapter.requestedApps.allSatisfy { $0.isSubset(of: ["browser"]) })
        XCTAssertFalse(controller.canRestore)
        XCTAssertNil(controller.undoSummary)
        let undo = await controller.answerRunReport(routineID: "tabs", undo: true, from: "Book", operationID: "operation")
        XCTAssertEqual(undo.summary, "")
    }

    func testFailedTabsReportFailureWithoutLeakingProfileOrAddressesToDiagnostics() async {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings)
        adapter.throwsOnLaunch = true
        var log: [String] = []
        controller.diagnostics = { log.append($0) }
        XCTAssertTrue(controller.saveRoutine(routine([set(profile: .init(directory: "Profile 1", name: "Secret account"))])))
        let report = await controller.answerRunReport(routineID: "tabs", undo: false, from: "Book")
        XCTAssertEqual(report.failure, "Browser couldn't open its tabs on Mini. Check this routine in Workspaces.")
        XCTAssertFalse(report.failure?.contains("Secret account") == true)
        XCTAssertTrue(report.summary.contains("Browser (Secret account)"), "Status keeps the useful profile detail")
        XCTAssertNil(report.counts?.tabsOpened)
        XCTAssertFalse(log.joined().contains("Secret account"))
        XCTAssertFalse(log.joined().contains("Profile 1"))
        XCTAssertFalse(log.joined().contains("https://"))
        do { try await controller.runAwaiting(routineID: "tabs"); XCTFail("Voice must receive failure") }
        catch {
            XCTAssertEqual(error.localizedDescription, "Browser couldn't open its tabs on Mini. Check this routine in Workspaces.")
            XCTAssertFalse(error.localizedDescription.contains("Profile 1"))
        }
    }

    func testPartialTabFailureIsOnlyANote() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings)
        XCTAssertTrue(controller.saveRoutine(routine([set(), set("missing", browser: "Missing")])))
        try await controller.runAwaiting(routineID: "tabs")
        XCTAssertTrue(controller.status.contains("opened 1 tab."))
        XCTAssertTrue(controller.status.contains("Missing isn't on Mini"))
    }

    func testTabsOpenAfterAppsBeforeCaptureAndMovedWindowsHaveUndoWording() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings)
        adapter.windows = [.init(id: "editor-window", bundleID: "editor", appName: "Editor", frame: .init(width: 300, height: 400), displayID: "screen")]
        let placement = WorkspaceAction.placing([.init(bundleID: "editor", appName: "Editor", macID: "mini", macName: "Mini")])
        XCTAssertTrue(controller.saveRoutine(routine([set()], extra: [placement])))
        try await controller.runAwaiting(routineID: "tabs")
        XCTAssertEqual(adapter.events.prefix(6), ["app", "wait", "capture", "tabs", "wait", "capture"])
        XCTAssertTrue(controller.status.contains("done, 1 change."))
        XCTAssertTrue(controller.status.contains("Opened 1 tab."))
        XCTAssertTrue(controller.canRestore)
        XCTAssertTrue(controller.undoSummary?.contains("Apps opened by this run stay open.") == true)
        XCTAssertTrue(controller.undoSummary?.contains("Tabs opened by this run stay open.") == true)
        let undo = await controller.answerRunReport(routineID: "tabs", undo: true, from: "Mini", operationID: controller.recoveryOrigin?.operationID)
        XCTAssertTrue(undo.summary.contains("Tabs opened by this run stay open."))
        XCTAssertEqual(adapter.launches.count, 1)
    }

    func testTabOnlyRoutineNeedsNoAccessibilityAndReadsNoWindows() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings)
        adapter.isAccessibilityGranted = false
        let routine = routine([set()])
        XCTAssertTrue(controller.saveRoutine(routine))
        XCTAssertTrue(controller.canRun(routine))
        controller.preview(routineID: "tabs")
        while controller.isBusy { await Task.yield() }
        XCTAssertTrue(controller.previewLines.contains("Browser will open 1 tab on Mini."))
        try await controller.runAwaiting(routineID: "tabs")
        XCTAssertEqual(adapter.launches.count, 1)
        XCTAssertTrue(adapter.requestedWindows.isEmpty, "A routine that only opens tabs must not read windows")
        XCTAssertTrue(controller.status.contains("opened 1 tab."))
    }

    func testARoutineThatMovesWindowsStillNeedsAccessibilityAndOpensNothingWithoutIt() async {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings)
        adapter.isAccessibilityGranted = false
        let placement = WorkspaceAction.placing([.init(bundleID: "editor", appName: "Editor", macID: "mini", macName: "Mini")])
        let routine = routine([set()], extra: [placement])
        XCTAssertTrue(controller.saveRoutine(routine))
        XCTAssertFalse(controller.canRun(routine))
        do {
            try await controller.runAwaiting(routineID: "tabs")
            XCTFail("The run should explain that it needs Accessibility")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Allow Dictator to move windows first"))
        }
        XCTAssertTrue(adapter.launches.isEmpty)
    }

    func testOpeningOnlyTabsKeepsTheUndoOfAnEarlierRun() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings)
        adapter.windows = [.init(id: "editor-window", bundleID: "editor", appName: "Editor", frame: .init(width: 300, height: 400), displayID: "screen")]
        adapter.running = ["editor", "browser"]
        let placement = WorkspaceAction.placing([.init(bundleID: "editor", appName: "Editor", macID: "mini", macName: "Mini")])
        let windows = WorkspaceRoutine(id: "windows", name: "Layout", actions: [placement])
        XCTAssertTrue(controller.saveRoutine(windows))
        XCTAssertTrue(controller.saveRoutine(routine([set()])))
        try await controller.runAwaiting(routineID: "windows")
        XCTAssertEqual(adapter.moves, ["editor-window"])
        XCTAssertTrue(controller.canRestore)
        let earlier = controller.recoveryOrigin
        try await controller.runAwaiting(routineID: "tabs")
        XCTAssertEqual(adapter.launches.count, 1)
        XCTAssertTrue(controller.canRestore, "Tabs moved nothing, so the earlier Undo must survive")
        XCTAssertEqual(controller.recoveryOrigin, earlier)
        XCTAssertFalse(controller.undoSummary?.contains("Tabs opened") == true, "That Undo belongs to a run with no tabs")
    }

    func testPreviewUsesLocalAvailabilityButRemoteDescriptionsAndNeverOpens() async {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings)
        XCTAssertTrue(controller.saveRoutine(routine([set(), set("missing", browser: "Missing"), set("remote", mac: "book", browser: "Elsewhere")])))
        controller.preview(routineID: "tabs")
        while controller.isBusy { await Task.yield() }
        XCTAssertTrue(controller.previewLines.contains("Browser will open 1 tab on Mini."))
        XCTAssertTrue(controller.previewLines.contains("Missing isn't on Mini, so its tabs won't open."))
        XCTAssertTrue(controller.previewLines.contains("Elsewhere will open 1 tab on Book."))
        XCTAssertFalse(controller.previewLines.joined().contains("puts the windows back"))
        XCTAssertTrue(adapter.launches.isEmpty)
    }

    func testOfflineTabsAndPlacementsHaveCombinedMessageAndNoTabOnlyUndo() async {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings), fleet = Fleet()
        controller.fleet = fleet
        let tabs = routine([set(mac: "book")])
        XCTAssertEqual(controller.otherMacs(in: tabs), ["Book"])
        XCTAssertTrue(controller.saveRoutine(tabs))
        do { try await controller.runAwaiting(routineID: "tabs"); XCTFail("Offline Mac must fail") } catch {}
        XCTAssertTrue(controller.status.contains("Book wasn't reached, so its tabs didn't open."))
        XCTAssertFalse(controller.canRestore)
        let placement = WorkspaceAction.placing([.init(bundleID: "editor", appName: "Editor", macID: "book", macName: "Book")])
        XCTAssertTrue(controller.saveRoutine(routine([set(mac: "book")], extra: [placement])))
        do { try await controller.runAwaiting(routineID: "tabs"); XCTFail("Offline Mac must fail") } catch {}
        XCTAssertTrue(controller.status.contains("Editor wasn't placed and its tabs didn't open."))
    }

    func testBrowserDiscoveryMapsHardwareKeysToEditorKeysAndKeepsNilDistinctFromEmpty() async {
        let settings = AppSettings.shared
        let adapter = Adapter(), controller = controller(adapter, settings: settings), fleet = Fleet()
        controller.fleet = fleet
        fleet.layouts = ["hardware-book": layout(adapter, browsers: [])]
        let found = await controller.availableBrowsers()
        XCTAssertEqual(found["setup-mini"], adapter.browsers)
        XCTAssertEqual(found["setup-book"], [])
        XCTAssertNil(found["hardware-book"])
        fleet.layouts["hardware-book"]?.browsers = nil
        let old = await controller.availableBrowsers()
        XCTAssertNil(old["setup-book"])
        fleet.captureThrows = true
        let failed = await controller.availableBrowsers()
        XCTAssertEqual(failed, ["setup-mini": adapter.browsers])
    }

    func testCaptureAttachesBrowsersButRememberAndSaveStripThem() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings), fleet = Fleet()
        let captured = await controller.answerCaptureRequest()
        XCTAssertEqual(captured.layout?.browsers, adapter.browsers)
        XCTAssertTrue(captured.layout?.windows.isEmpty == true)
        controller.fleet = fleet
        fleet.layouts = ["mini": layout(adapter, name: "Mini", browsers: adapter.browsers),
                         "book": layout(adapter, browsers: adapter.browsers)]
        let capturedLayouts = await controller.rememberLayouts(everywhere: true)
        let remembered = try XCTUnwrap(capturedLayouts)
        XCTAssertTrue(remembered.values.allSatisfy { $0.browsers == nil })
        let value = WorkspaceRoutine(id: "remember", name: "Remember", actions: [.remembering(fleet.layouts)])
        XCTAssertTrue(controller.saveRoutine(value))
        XCTAssertTrue(settings.workspaceLaunch.routines.first { $0.id == "remember" }!.actions[0].remembered!.values.allSatisfy { $0.browsers == nil })
    }

    private func placement(_ mac: String = "mini") -> WorkspaceAction {
        .placing([.init(bundleID: "editor", appName: "Editor", macID: mac, macName: mac == "mini" ? "Mini" : "Book")])
    }

    private func addWindow(to adapter: Adapter) {
        adapter.running = ["editor", "browser"]
        adapter.windows = [.init(id: "editor-window", bundleID: "editor", appName: "Editor",
            frame: .init(width: 300, height: 400), displayID: "screen")]
    }

    func testTabFailureJoinsOnlyBrowserNamesAndKeepsWindowFailureNotesOutOfFailure() async {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings)
        addWindow(to: adapter)
        adapter.moveFails = true
        let secret = WorkspaceBrowserProfile(directory: "Missing", name: "Secret personal account")
        let value = routine([set(profile: secret), set("absent", browser: "Chrome", profile: secret)], extra: [placement()])
        XCTAssertTrue(controller.saveRoutine(value))
        let report = await controller.answerRunReport(routineID: "tabs", undo: false, from: "Book")
        XCTAssertTrue(report.summary.contains("can't find the selected profile"))
        XCTAssertFalse(report.summary.contains(secret.name), "A summary reaches other Macs and logs")
        XCTAssertTrue(report.failure?.contains("Synthetic move failure") == true)
        XCTAssertTrue(report.failure?.contains("Browser and Chrome couldn't open its tabs on Mini") == true)
        XCTAssertFalse(report.failure?.contains(secret.name) == true)
        XCTAssertFalse(report.failure?.contains(secret.directory) == true)
    }

    func testRemoteFailureFromAnOlderPeerNeverReachesVoiceWithProfileDetails() async {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings), fleet = Fleet()
        controller.fleet = fleet
        let secret = "Secret personal account"
        fleet.reports = [.init(macName: "Book", summary: "Browser (\(secret)) couldn't open", failure: "Browser (\(secret)) couldn't open")]
        XCTAssertTrue(controller.saveRoutine(routine([set(mac: "book", profile: .init(directory: "Profile 1", name: secret))])))
        var log: [String] = []
        controller.diagnostics = { log.append($0) }
        do { try await controller.runAwaiting(routineID: "tabs"); XCTFail("Remote failure must stop voice") }
        catch {
            XCTAssertEqual(error.localizedDescription, "Browser couldn't open its tabs on Book. Check this routine in Workspaces.")
        }
        XCTAssertTrue(controller.status.contains(secret))
        XCTAssertFalse(log.joined().contains(secret))
    }

    func testTimeoutIsUncertainInNotesFailureAndVoiceAndCountsNothing() async {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings)
        adapter.timesOutOnLaunch = true
        let value = routine([set(profile: .init(directory: "Profile 1", name: "Work"))])
        let opened = await open(value, adapter: adapter)
        XCTAssertEqual(opened.notes, ["Browser (Work) was slow to open on Mini, so its tabs may still appear."])
        XCTAssertEqual(opened.tabsOpened, 0)
        XCTAssertEqual(opened.windowsOpened, 0)
        XCTAssertTrue(opened.started.isEmpty)
        XCTAssertTrue(controller.saveRoutine(value))
        let report = await controller.answerRunReport(routineID: "tabs", undo: false, from: "Book")
        XCTAssertEqual(report.failure, "Browser was slow to open on Mini, so its tabs may still appear.")
        XCTAssertNil(report.counts?.tabsOpened)
        XCTAssertEqual(report.counts?.appsOpened, 0)
        XCTAssertFalse(report.summary.contains("tabs didn't open"))
        do { try await controller.runAwaiting(routineID: "tabs"); XCTFail("Voice must receive the uncertain result") }
        catch { XCTAssertEqual(error.localizedDescription, report.failure) }
    }

    func testRemoteTimeoutStaysUncertainAndProfileFree() async {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings), fleet = Fleet()
        controller.fleet = fleet
        fleet.reports = [.init(macName: "Book", summary: "Browser (Work) was slow to open on Book, so its tabs may still appear.",
            failure: "Browser was slow to open on Book, so its tabs may still appear.")]
        XCTAssertTrue(controller.saveRoutine(routine([set(mac: "book")])))
        do { try await controller.runAwaiting(routineID: "tabs"); XCTFail("Voice must receive uncertainty") }
        catch { XCTAssertEqual(error.localizedDescription, fleet.reports[0].failure) }
    }

    func testTabPhasesRespectLastWindowStepAndCountBothPhases() async {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        for order in ["place-tabs", "tabs-place", "place-tabs-place", "tabs-place-tabs"] {
            let adapter = Adapter(), controller = controller(adapter, settings: settings)
            addWindow(to: adapter)
            adapter.running.remove("browser")
            let tabs = WorkspaceAction.openingTabs([set()])
            let secondTabs = WorkspaceAction.openingTabs([set("two")])
            let secondPlace = WorkspaceAction.placing([.init(bundleID: "editor", appName: "Editor", macID: "mini", macName: "Mini", position: .leftHalf)])
            let actions: [WorkspaceAction]
            let expected: [String]
            switch order {
            case "place-tabs": actions = [placement(), tabs]; expected = ["move", "tabs"]
            case "tabs-place": actions = [tabs, placement()]; expected = ["tabs", "move"]
            case "place-tabs-place": actions = [placement(), tabs, secondPlace]; expected = ["tabs", "move", "move"]
            default: actions = [tabs, placement(), secondTabs]; expected = ["tabs", "move", "tabs"]
            }
            XCTAssertTrue(controller.saveRoutine(.init(id: "ordered", name: "Ordered", actions: actions)))
            let report = await controller.answerRunReport(routineID: "ordered", undo: false, from: "Book")
            XCTAssertNil(report.failure, order)
            XCTAssertEqual(adapter.events.filter { $0 == "move" || $0 == "tabs" }, expected, order)
            XCTAssertEqual(report.counts?.tabsOpened, order == "tabs-place-tabs" ? 2 : 1, order)
            XCTAssertEqual(report.counts?.appsOpened, 1, "Started browsers are counted across both phases: \(order)")
            XCTAssertTrue(controller.undoSummary?.contains("Tabs opened by this run stay open.") == true, order)
        }
    }

    func testFailedMoveStopsLateTabsButKeepsEarlyCountsAndUndoWording() async {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        for early in [false, true] {
            let adapter = Adapter(), controller = controller(adapter, settings: settings)
            addWindow(to: adapter)
            adapter.moveFails = true
            let tabs = WorkspaceAction.openingTabs([set("late")])
            let actions = (early ? [WorkspaceAction.openingTabs([set("early")])] : []) + [placement(), tabs]
            XCTAssertTrue(controller.saveRoutine(.init(id: "ordered", name: "Ordered", actions: actions)))
            let report = await controller.answerRunReport(routineID: "ordered", undo: false, from: "Book")
            XCTAssertTrue(report.failure?.contains("Synthetic move failure") == true)
            XCTAssertTrue(report.summary.contains("Tabs after that step didn't open because the routine stopped."))
            XCTAssertEqual(adapter.launches.count, early ? 1 : 0)
            XCTAssertEqual(report.counts?.tabsOpened, early ? 1 : nil)
            XCTAssertEqual(controller.undoSummary?.contains("Tabs opened by this run stay open."), early)
        }
    }

    func testLateTabsUseRemainingFullRunBudgetAndFailuresCountAcrossPhases() async {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, settings: settings)
        addWindow(to: adapter)
        adapter.moveDelay = VoiceLaunchReadiness.workspaceRunBudget - 3
        let value = WorkspaceRoutine(id: "late", name: "Late", actions: [placement(), .openingTabs([set()])])
        XCTAssertTrue(controller.saveRoutine(value))
        let report = await controller.answerRunReport(routineID: "late", undo: false, from: "Book")
        XCTAssertNil(report.failure)
        XCTAssertEqual(adapter.launches.map(\.timeout), [3])
        XCTAssertEqual(report.counts?.tabsOpened, 1)
        adapter.moveDelay = 0
        adapter.refused = ["browser"]
        let failed = await controller.answerRunReport(routineID: "late", undo: false, from: "Book")
        XCTAssertEqual(failed.failure, "Browser couldn't open its tabs on Mini. Check this routine in Workspaces.")
        XCTAssertNil(failed.counts?.tabsOpened)
    }

    func testFleetUndoSurvivesTabOnlyRunsFromClickVoiceAndRemoteWithOriginalOperation() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        for trigger in ["click", "voice", "remote"] {
            let adapter = Adapter(), controller = controller(adapter, settings: settings), fleet = Fleet()
            addWindow(to: adapter)
            adapter.moveFails = true
            controller.fleet = fleet
            fleet.reports = [.init(macName: "Book", summary: "done, 1 change.")]
            XCTAssertTrue(controller.saveRoutine(.init(id: "windows", name: "Fleet layout", actions: [placement(), placement("book")])))
            XCTAssertTrue(controller.saveRoutine(routine([set(), set("remote", mac: "book")])))
            do { try await controller.runAwaiting(routineID: "windows"); XCTFail("Synthetic partial failure") } catch {}
            let original = try XCTUnwrap(fleet.calls.first?.operationID)
            let previousUndo = controller.undoSummary
            XCTAssertTrue(controller.lastRunStoppedPartway)
            XCTAssertTrue(previousUndo?.contains("Fleet layout") == true)
            XCTAssertTrue(previousUndo?.contains("Book") == true)
            adapter.moveFails = false
            switch trigger {
            case "click":
                controller.run(routineID: "tabs")
                while controller.isBusy { await Task.yield() }
            case "voice": try await controller.runAwaiting(routineID: "tabs")
            default: _ = await controller.answerRunReport(routineID: "tabs", undo: false, from: "Book", operationID: "later")
            }
            XCTAssertEqual(controller.undoSummary, previousUndo, trigger)
            XCTAssertTrue(controller.lastRunStoppedPartway, trigger)
            XCTAssertTrue(controller.lastRunReachedOtherMacs, trigger)
            XCTAssertEqual(controller.lastRunOtherMacs, ["Book"], trigger)
            XCTAssertTrue(controller.status.contains("opened 1 tab."), "Latest status describes the tab run")
            controller.restoreLastReset()
            while controller.isBusy { await Task.yield() }
            let undo = try XCTUnwrap(fleet.calls.last)
            XCTAssertTrue(undo.undo, trigger)
            XCTAssertEqual(undo.routineID, "windows", trigger)
            XCTAssertEqual(undo.operationID, original, trigger)
        }
    }

    func testOnlyLocalTabsRunWithoutAccessibilityWhenWindowsAreOnAnotherMac() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        for remote in [placement("book"), WorkspaceAction.remembering(["book": layout(Adapter())])] {
            let adapter = Adapter(), controller = controller(adapter, settings: settings)
            adapter.isAccessibilityGranted = false
            let value = routine([set(mac: "setup-mini")], extra: [remote])
            let fleet = Fleet()
            controller.fleet = fleet
            fleet.reports = [.init(macName: "Book", summary: "done.")]
            XCTAssertTrue(controller.saveRoutine(value))
            XCTAssertTrue(controller.canRun(value))
            controller.preview(routineID: "tabs")
            while controller.isBusy { await Task.yield() }
            try await controller.runAwaiting(routineID: "tabs")
            XCTAssertEqual(adapter.launches.count, 1)
            XCTAssertTrue(adapter.requestedWindows.isEmpty)
            XCTAssertTrue(adapter.requestedApps.isEmpty)
            XCTAssertTrue(controller.canRestore, "Remote window steps still own fleet Undo")
            XCTAssertTrue(controller.undoSummary?.contains("Book") == true)
        }
    }

    func testCaptureFailureStillReturnsBrowsersAndRememberKeepsErrorWithoutRememberingWindows() async throws {
        let settings = AppSettings.shared
        let adapter = Adapter(), controller = controller(adapter, settings: settings), fleet = Fleet()
        adapter.isAccessibilityGranted = false
        let reply = await controller.answerCaptureRequest()
        let discovery = try XCTUnwrap(reply.layout)
        XCTAssertEqual(discovery.browsers, adapter.browsers)
        XCTAssertTrue(discovery.windows.isEmpty)
        XCTAssertTrue(discovery.screens.isEmpty)
        XCTAssertEqual(discovery.captureError, reply.error)
        XCTAssertTrue(reply.error?.contains("Allow Dictator to move windows first") == true)
        XCTAssertTrue(adapter.requestedWindows.isEmpty)
        controller.fleet = fleet
        fleet.layouts = ["setup-book": discovery]
        let discovered = await controller.availableBrowsers()
        XCTAssertEqual(discovered["setup-book"], adapter.browsers, "Browser-only layouts reach the editor through the existing fleet reply")
        fleet.layouts = ["mini": discovery, "book": layout(adapter)]
        let remembered = await controller.rememberLayouts(everywhere: true)
        XCTAssertEqual(remembered?.keys.sorted(), ["book"])
        XCTAssertTrue(controller.status.contains("Allow Dictator to move windows first"))
        XCTAssertFalse(controller.status.contains("0 on Mini"))
        // An older relay drops captureError, but retains empty windows and
        // browsers. Remember must still never claim this Mac remembered windows.
        fleet.layouts["mini"]?.captureError = nil
        let relayed = await controller.rememberLayouts(everywhere: true)
        XCTAssertEqual(relayed?.keys.sorted(), ["book"])
        adapter.isAccessibilityGranted = true
        adapter.captureFails = true
        let failedCapture = await controller.answerCaptureRequest()
        XCTAssertEqual(failedCapture.error, "Synthetic capture failure")
        XCTAssertEqual(failedCapture.layout?.browsers, adapter.browsers)
        XCTAssertTrue(failedCapture.layout?.windows.isEmpty == true)
    }
}
