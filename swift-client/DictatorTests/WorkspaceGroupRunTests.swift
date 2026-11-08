import XCTest
@testable import Dictator

@MainActor
final class WorkspaceGroupRunTests: XCTestCase {
    private final class Hotkeys: WorkspaceHotkeyRegistering {
        var onTrigger: ((String) -> Void)?
        var onCommandTrigger: ((String) -> Void)?
        func register(_ definitions: [WorkspaceRoutine], commands: [VoiceCommand]) -> WorkspaceHotkeyRegistry.Registration { .init() }
        func clear() {}
    }

    private final class Adapter: WorkspaceLaunchAdapter {
        var isAccessibilityGranted = true
        var frontmostBundleID: String? = "outside"
        var runningBundleIDs: Set<String> = ["browser", "outside"]
        var hidden: Set<String> = []
        var hideFailures: Set<String> = []
        var showFailures: Set<String> = []
        var windows: [WorkspaceWindow] = []
        var displays = [WorkspaceDisplay(id: "main", visibleFrame: .init(width: 1200, height: 900), isMain: true)]
        var events: [String] = []
        var retained: [Set<String>] = []
        var launches = 0
        var captureFails = false
        var extraWindowsOnLaunch = 0
        var createWindows = true
        var onShow: ((String) -> Void)?
        var ownWindow = true
        func opensOwnWindow(bundleID: String) -> Bool { ownWindow }
        var failedMoves: Set<String> = []
        var capturedApps: [Set<String>] = []
        var capturedWindowApps: [Set<String>] = []
        var onCapture: ((Int) -> Void)?
        var rehide: ((String) async throws -> Void)?
        var canRehide: ((String) -> Bool)?
        func canRehideApp(bundleID: String) -> Bool { canRehide?(bundleID) ?? true }
        var afterMove: (() async -> Void)?
        func requestPermission() { XCTFail("Tests never ask for machine permissions") }
        func isAppRunning(bundleID: String) -> Bool { runningBundleIDs.contains(bundleID) }
        func isAppInstalled(bundleID: String) -> Bool { true }
        func installedBrowsers() async -> [WorkspaceBrowserInfo] { [.init(bundleID: "browser", name: "Browser")] }
        func openApp(bundleID: String, timeout: TimeInterval) async throws -> Bool {
            events.append("open:\(bundleID)"); runningBundleIDs.insert(bundleID); return true
        }
        func waitForFirstWindow(bundleID: String, timeout: TimeInterval) async throws -> Bool { true }
        func openTabs(bundleID: String, profileDirectory: String?, urls: [String], timeout: TimeInterval) async throws -> Bool {
            events.append("tabs"); launches += 1; runningBundleIDs.insert(bundleID)
            if createWindows {
                for index in 0...extraWindowsOnLaunch {
                    windows.append(.init(id: "tab-\(launches)-\(index)", bundleID: bundleID,
                        frame: .init(x: 80, y: 70, width: 400, height: 350), displayID: "main"))
                }
            }
            return true
        }
        func capture(lastActivatedAt: [String: Date], excluding: Set<String>, preferredFrontmostBundleID: String?,
                     windowBundleIDs: Set<String>, applicationBundleIDs: Set<String>) async throws -> WorkspaceSnapshot {
            events.append("capture"); capturedApps.append(applicationBundleIDs)
            capturedWindowApps.append(windowBundleIDs)
            onCapture?(capturedApps.count)
            if captureFails { throw WorkspaceLaunchError.unavailable("Synthetic capture failure") }
            return .init(displays: displays,
                windows: windows.filter { windowBundleIDs.contains($0.bundleID) && !hidden.contains($0.bundleID) },
                applications: runningBundleIDs.intersection(applicationBundleIDs).subtracting(excluding).sorted().map {
                    .init(bundleID: $0, name: $0, isHidden: hidden.contains($0))
                })
        }
        func showApp(bundleID: String) throws -> Bool {
            events.append("show:\(bundleID)")
            onShow?(bundleID)
            if showFailures.contains(bundleID) { throw WorkspaceLaunchError.unavailable("Synthetic show failure") }
            return hidden.remove(bundleID) != nil
        }
        func rehideApp(bundleID: String) async throws {
            events.append("rehide:\(bundleID)")
            if let rehide { try await rehide(bundleID); return }
            guard frontmostBundleID != bundleID else { throw WorkspaceLaunchError.unavailable("Still frontmost") }
            hidden.insert(bundleID)
        }
        func hideApp(bundleID: String) throws -> Bool {
            events.append("hide:\(bundleID)")
            if hideFailures.contains(bundleID) || frontmostBundleID == bundleID { throw WorkspaceLaunchError.unavailable("Synthetic hide failure") }
            return hidden.insert(bundleID).inserted
        }
        func unhideApp(bundleID: String) throws { events.append("unhide:\(bundleID)"); hidden.remove(bundleID) }
        func makeAppFrontmost(bundleID: String, deadline: TimeInterval) async throws {
            events.append("focus:\(bundleID)"); frontmostBundleID = bundleID
        }
        func raiseWindow(id: String, deadline: TimeInterval) async throws { events.append("raise:\(id)") }
        func moveWindow(id: String, to frame: WorkspaceRect) async throws {
            events.append("move:\(id)")
            if failedMoves.contains(id) { throw WorkspaceLaunchError.unavailable("Synthetic move failure") }
            guard let index = windows.firstIndex(where: { $0.id == id }) else { throw NativeResetError.windowNotFound(id) }
            windows[index].frame = frame
            await afterMove?()
        }
        /// macOS nudges a parked window: nil lands exactly where it was sent.
        var parkLands: ((WorkspaceRect) -> WorkspaceRect)?
        var parkFails = true
        func parkWindow(id: String, at frame: WorkspaceRect) async throws -> WorkspaceRect {
            events.append("park:\(id)")
            if parkFails && failedMoves.contains(id) { throw WorkspaceLaunchError.unavailable("Synthetic move failure") }
            guard let index = windows.firstIndex(where: { $0.id == id }) else { throw NativeResetError.windowNotFound(id) }
            let landed = parkLands?(frame) ?? frame
            windows[index].frame = landed
            await afterMove?()
            return landed
        }
        func retainWindows(ids: Set<String>) { retained.append(ids) }
    }

    private func tab(_ id: String, position: WorkspacePosition? = nil) -> WorkspaceTabSet {
        .init(id: id, macID: "mini", macName: "Mini", browserBundleID: "browser", browserName: "Browser",
              urls: ["https://example.com"], monitor: position.map { _ in .generic(.main) }, position: position)
    }
    private func group(_ id: String, app: String = "browser", tabs: Bool = true) -> WorkspaceRoutine {
        .init(id: id, name: id, actions: tabs ? [.openingTabs([tab(id)])] : [.placing([
            .init(bundleID: app, appName: app, macID: "mini", macName: "Mini", position: .leftHalf)
        ])], showOnly: true)
    }
    private func store() -> WorkspaceParkedStore {
        WorkspaceParkedStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("parked.json"))
    }
    private func controller(_ adapter: Adapter, store: WorkspaceParkedStore? = nil) -> WorkspaceLaunchController {
        let controller = WorkspaceLaunchController(adapter: adapter, macID: { "mini" }, hotkeys: Hotkeys(), parkedStore: store ?? self.store())
        controller.diagnostics = { _ in }; controller.macName = { "Mini" }
        return controller
    }
    private func open(_ routine: WorkspaceRoutine, adapter: Adapter, tracker: WorkspaceTabWindowTracker = .init(),
                      routines: [WorkspaceRoutine]? = nil) async -> WorkspaceTabRun {
        await WorkspaceLaunchExecutor.openTabSets(in: routine, macID: "mini", aliases: [], macName: "Mini", adapter: adapter,
            deadline: adapter.monotonicTime + 5, tracker: tracker, routines: routines)
    }
    private func undo(_ controller: WorkspaceLaunchController) async {
        controller.restoreLastReset()
        while controller.isBusy { await Task.yield() }
    }

    func testReuseReopenPlacementAndSeparateWindowsForSameBrowser() async throws {
        let adapter = Adapter()
        let value = WorkspaceRoutine(id: "tabs", name: "Tabs", actions: [.openingTabs([tab("one", position: .leftHalf), tab("two")])])
        let first = await open(value, adapter: adapter)
        XCTAssertEqual(first.windowsOpened, 2)
        XCTAssertEqual(first.tracker.windowIDs.count, 2)
        XCTAssertEqual(first.moved.count, 1)
        XCTAssertEqual(first.moved.first?.frame.x, 80)
        let second = await open(value, adapter: adapter, tracker: first.tracker)
        XCTAssertEqual(adapter.launches, 2)
        XCTAssertEqual(second.windowsReused, 2)
        XCTAssertEqual(second.tabsOpened, 0)
        XCTAssertTrue(second.failedBrowsers.isEmpty)
        let closed = try XCTUnwrap(second.tracker.window(forSet: "one"))
        adapter.windows.removeAll { $0.id == closed.windowID }
        let reopened = await open(value, adapter: adapter, tracker: second.tracker)
        XCTAssertEqual(adapter.launches, 3)
        XCTAssertEqual(reopened.windowsReused, 1)
        XCTAssertEqual(reopened.tabsOpened, 1)
    }

    func testSeveralNewWindowsTracksNoneAndNeverMovesExistingPersonalWindow() async {
        let adapter = Adapter(); adapter.extraWindowsOnLaunch = 2
        adapter.windows = [.init(id: "personal", bundleID: "browser", frame: .init(width: 600, height: 500))]
        let routine = WorkspaceRoutine(id: "one", name: "One", actions: [.openingTabs([tab("one", position: .leftHalf)])])
        let result = await open(routine, adapter: adapter)
        XCTAssertTrue(result.tracker.windowIDs.isEmpty)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.tabsOpened, 1)
        XCTAssertFalse(adapter.events.contains { $0.hasPrefix("move:") })
        XCTAssertEqual(result.notes, ["Browser opened, but Dictator couldn't tell which window was its own, so it wasn't placed."])
    }

    func testPersonalWindowBeforePollAndSecondWindowDuringConfirmationTracksNeither() async {
        let adapter = Adapter(); adapter.createWindows = false
        adapter.onCapture = { count in
            if count == 2 || count == 3 {
                adapter.windows.append(.init(id: count == 2 ? "personal" : "launched", bundleID: "browser",
                                            frame: .init(width: 300, height: 400)))
            }
        }
        let routine = WorkspaceRoutine(id: "one", name: "One", actions: [.openingTabs([tab("one", position: .leftHalf)])])
        let result = await open(routine, adapter: adapter)
        XCTAssertEqual(adapter.capturedApps.count, 3)
        XCTAssertEqual(result.tabsOpened, 1)
        XCTAssertTrue(result.tracker.windowIDs.isEmpty)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.notes, ["Browser opened, but Dictator couldn't tell which window was its own, so it wasn't placed."])
    }

    func testEditedBrowserReturnsOldParkedWindowToHomeBeforeForgetting() async throws {
        let adapter = Adapter()
        let home = WorkspaceRect(x: 30, y: 40, width: 400, height: 350)
        let parked = try XCTUnwrap(WorkspaceParking.frame(for: home, displays: adapter.displays))
        adapter.windows = [.init(id: "old", bundleID: "old-browser", frame: parked)]
        var tracker = WorkspaceTabWindowTracker()
        tracker.record(.init(setID: "one", routineID: "one", windowID: "old", bundleID: "old-browser", home: home,
                             signature: ["old-browser", "", "https://old.example"]))
        let routine = WorkspaceRoutine(id: "one", name: "One", actions: [.openingTabs([tab("one", position: .rightHalf)])])
        let result = await open(routine, adapter: adapter, tracker: tracker)
        XCTAssertEqual(adapter.capturedWindowApps.first, ["old-browser"])
        XCTAssertEqual(adapter.windows.first { $0.id == "old" }?.frame, home)
        XCTAssertEqual(result.moved.first { $0.id == "old" }?.frame, home)
        XCTAssertEqual(result.tracker.window(forSet: "one")?.bundleID, "browser")
        XCTAssertEqual(result.tracker.window(forSet: "one")?.windowID, "tab-1-0")
    }

    func testEditedSetKeepsOldHandleWhenReturningFailsOrWindowIsMissing() async throws {
        for missing in [false, true] {
            let adapter = Adapter()
            let home = WorkspaceRect(x: 40, y: 50, width: 400, height: 350)
            let parked = try XCTUnwrap(WorkspaceParking.frame(for: home, displays: adapter.displays))
            if !missing { adapter.windows = [.init(id: "old", bundleID: "browser", frame: parked)] }
            adapter.failedMoves = ["old"]
            var tracker = WorkspaceTabWindowTracker()
            tracker.record(.init(setID: "one", routineID: "one", windowID: "old", bundleID: "browser", home: home,
                                 signature: ["browser", "", "https://old.example"]))
            let result = await open(group("one"), adapter: adapter, tracker: tracker)
            XCTAssertEqual(result.tracker.window(forSet: "one")?.windowID, "old")
            XCTAssertEqual(result.tracker.window(forSet: "one")?.home, home)
            XCTAssertEqual(result.tabsOpened, 1)
            XCTAssertEqual(result.moved.first?.frame, missing ? nil : home)
        }
    }

    func testWithoutAccessibilityNeverCapturesMovesOrReuses() async {
        let adapter = Adapter(); adapter.isAccessibilityGranted = false
        var tracker = WorkspaceTabWindowTracker()
        tracker.record(.init(setID: "one", routineID: "one", windowID: "old", bundleID: "browser"))
        let result = await open(group("one"), adapter: adapter, tracker: tracker)
        XCTAssertEqual(result.tabsOpened, 1)
        XCTAssertEqual(result.windowsReused, 0)
        XCTAssertFalse(adapter.events.contains("capture"))
        XCTAssertFalse(adapter.events.contains { $0.hasPrefix("move:") })
    }

    func testMissingWindowIsANoteAndSuccessfulTabsStillCount() async {
        let adapter = Adapter(); adapter.createWindows = false
        var routine = group("one")
        routine.actions[0].tabSets?[0].monitor = .generic(.main)
        routine.actions[0].tabSets?[0].position = .leftHalf
        let result = await open(routine, adapter: adapter)
        XCTAssertEqual(result.tabsOpened, 1)
        XCTAssertEqual(result.notes, ["Browser opened, but Dictator couldn't find its window, so it wasn't placed."])
        XCTAssertTrue(result.tracker.windowIDs.isEmpty)
    }

    func testFocusThenHideIgnoresIdleCheckAndHideFailureKeepsRecovery() async {
        let adapter = Adapter(); adapter.hideFailures = ["bad"]
        let snapshot = WorkspaceSnapshot(applications: ["outside", "bad", "already"].map {
            .init(bundleID: $0, isHidden: $0 == "already")
        })
        let plan = WorkspacePlan(operations: [.focusApp(bundleID: "browser"), .hideOtherApp(bundleID: "bad"),
            .hideOtherApp(bundleID: "outside"), .hideOtherApp(bundleID: "already")])
        let result = await WorkspaceLaunchExecutor.applyCooperatively(plan, snapshot: snapshot, adapter: adapter,
            isAppStillIdle: { _ in XCTFail("Group hiding is independent of idle time"); return false })
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.recovery.hiddenBundleIDs, ["outside"])
        XCTAssertTrue(result.notes.contains { $0.contains("bad couldn't be hidden") })
        XCTAssertEqual(adapter.events, ["focus:browser", "hide:bad", "hide:outside"])
        _ = await WorkspaceLaunchExecutor.restoreCooperatively(result.recovery, adapter: adapter)
        XCTAssertFalse(adapter.hidden.contains("outside"))
    }

    func testGroupRunShowsBeforeCaptureHidesAfterMoveAndUndoRehides() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(); adapter.runningBundleIDs.insert("editor"); adapter.hidden = ["editor"]
        adapter.windows = [.init(id: "editor", bundleID: "editor", frame: .init(width: 300, height: 400))]
        let controller = controller(adapter)
        XCTAssertTrue(controller.saveRoutine(group("edit", app: "editor", tabs: false)))
        try await controller.runAwaiting(routineID: "edit")
        let show = try XCTUnwrap(adapter.events.firstIndex(of: "show:editor"))
        let capture = try XCTUnwrap(adapter.events.firstIndex(of: "capture"))
        let move = try XCTUnwrap(adapter.events.firstIndex(of: "move:editor"))
        let hide = try XCTUnwrap(adapter.events.firstIndex(of: "hide:outside"))
        XCTAssertLessThan(show, capture); XCTAssertLessThan(move, hide)
        XCTAssertTrue(controller.status.contains("Hid 2 other apps."))
        XCTAssertTrue(controller.canRestore)
        XCTAssertTrue(controller.undoSummary?.contains("apps and windows") == true)
        await undo(controller)
        XCTAssertTrue(adapter.hidden.contains("editor"))
        XCTAssertFalse(adapter.hidden.contains("outside"))
        XCTAssertEqual(adapter.windows[0].frame.width, 300)
    }

    func testGroupsSwapBothWaysParkOnlyTrackedWindowsExcludeThemFromPlaceAndRemember() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        let personalFrame = WorkspaceRect(x: 20, y: 30, width: 300, height: 400)
        adapter.windows = [.init(id: "personal", bundleID: "browser", frame: personalFrame)]
        let a = group("a"), b = group("b")
        XCTAssertTrue(controller.saveRoutine(a)); XCTAssertTrue(controller.saveRoutine(b))
        try await controller.runAwaiting(routineID: "a")
        try await controller.runAwaiting(routineID: "b")
        XCTAssertEqual(controller.parkedWindowCount, 1)
        XCTAssertEqual(disk.load().count, 1)
        let aID = "tab-1-0", bID = "tab-2-0"
        XCTAssertEqual(adapter.windows.first { $0.id == "personal" }?.frame, personalFrame)
        XCTAssertTrue(adapter.retained.last?.isSuperset(of: [aID, bID]) == true)
        XCTAssertTrue(WorkspaceParking.isParked(try XCTUnwrap(adapter.windows.first { $0.id == aID }).frame, displays: adapter.displays))
        let remembered = try await controller.captureLayout().layout
        XCTAssertEqual(remembered.windows.count, 2, "Personal and current group only")
        var placedB = b
        placedB.actions.append(.placing([.init(bundleID: "browser", appName: "Browser", macID: "mini", macName: "Mini", position: .rightHalf)]))
        XCTAssertTrue(controller.saveRoutine(placedB))
        adapter.events = []
        try await controller.runAwaiting(routineID: "b")
        XCTAssertFalse(adapter.events.contains("move:\(aID)"), "Place must not touch the other group's window")
        try await controller.runAwaiting(routineID: "a")
        XCTAssertEqual(adapter.launches, 2)
        XCTAssertFalse(WorkspaceParking.isParked(try XCTUnwrap(adapter.windows.first { $0.id == aID }).frame, displays: adapter.displays))
        XCTAssertTrue(WorkspaceParking.isParked(try XCTUnwrap(adapter.windows.first { $0.id == bID }).frame, displays: adapter.displays))
        XCTAssertEqual(controller.parkedWindowCount, 1)
        XCTAssertTrue(adapter.retained.allSatisfy { !$0.isEmpty })
        await undo(controller)
        XCTAssertEqual(controller.parkedWindowCount, 0)
        XCTAssertTrue(disk.load().isEmpty)
        // Place may move personal windows; parking may never move them to the corner.
        XCTAssertFalse(WorkspaceParking.isParked(try XCTUnwrap(adapter.windows.first { $0.id == "personal" }).frame, displays: adapter.displays))
    }

    func testEditingAddressesOpensANewWindowAndBringsTheOldOneHome() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter)
        XCTAssertTrue(controller.saveRoutine(group("one")))
        XCTAssertTrue(controller.saveRoutine(group("two")))
        try await controller.runAwaiting(routineID: "one")
        try await controller.runAwaiting(routineID: "two")
        XCTAssertEqual(controller.parkedWindowCount, 1)
        var edited = group("one")
        edited.actions[0].tabSets?[0].urls = ["https://edited.example"]
        XCTAssertTrue(controller.saveRoutine(edited))
        try await controller.runAwaiting(routineID: "one")
        XCTAssertEqual(adapter.launches, 3, "New addresses need a new window, not the old pages")
        XCTAssertFalse(WorkspaceParking.isParked(try XCTUnwrap(adapter.windows.first { $0.id == "tab-1-0" }).frame, displays: adapter.displays),
                       "The old window is nobody's now, so it can't stay parked")
    }

    func testAPlacedWindowThatIsOffScreenByItselfIsStillPlaced() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter)
        adapter.runningBundleIDs = ["editor"]
        adapter.windows = [.init(id: "lost", bundleID: "editor", frame: .init(x: 5000, y: 5000, width: 300, height: 300))]
        var routine = group("rescue", app: "editor", tabs: false)
        routine.showOnly = nil
        XCTAssertTrue(controller.saveRoutine(routine))
        try await controller.runAwaiting(routineID: "rescue")
        XCTAssertFalse(WorkspaceParking.isParked(try XCTUnwrap(adapter.windows.first).frame, displays: adapter.displays),
                       "Only Dictator's own windows are skipped: Place apps can still rescue a person's")
    }

    func testABrowserThatAddsATabCostsNoWaitAndNoNote() async {
        let adapter = Adapter(); adapter.createWindows = false; adapter.ownWindow = false
        let started = ProcessInfo.processInfo.systemUptime
        let routine = group("tabs")
        let result = await WorkspaceLaunchExecutor.openTabSets(in: routine, macID: "mini", aliases: [], macName: "Mini",
                                                              adapter: adapter, deadline: adapter.monotonicTime + 50)
        XCTAssertEqual(result.tabsOpened, 1)
        XCTAssertTrue(result.notes.isEmpty, "Nobody asked for a place, so a missing window isn't news")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1, "Nothing to wait for")
    }

    func testAHiddenBrowserShowsToBringItsWindowBackWithoutShowOnly() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter)
        var routine = group("plain")
        routine.showOnly = nil
        XCTAssertTrue(controller.saveRoutine(routine))
        try await controller.runAwaiting(routineID: "plain")
        adapter.hidden = ["browser"]
        try await controller.runAwaiting(routineID: "plain")
        XCTAssertEqual(adapter.launches, 1, "Its window is still open")
        XCTAssertTrue(adapter.events.contains("show:browser"))
    }

    func testAParkedWindowNudgedByMacOSStillCountsAndCanComeBack() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        // Measured on macOS 27: the top edge stays about 32 points on screen.
        adapter.parkLands = { var frame = $0; frame.y -= 31; return frame }
        var one = group("one"), two = group("two")
        one.actions[0].tabSets?[0].id = "one-set"
        two.actions[0].tabSets?[0].id = "two-set"
        XCTAssertTrue(controller.saveRoutine(one))
        XCTAssertTrue(controller.saveRoutine(two))
        try await controller.runAwaiting(routineID: "one")
        let home = try XCTUnwrap(adapter.windows.first).frame
        try await controller.runAwaiting(routineID: "two")
        XCTAssertEqual(controller.parkedWindowCount, 1, "Close to the corner is good enough")
        let saved1 = try XCTUnwrap(disk.load().first)
        XCTAssertEqual(saved1.parkedAt?.y, adapter.windows.first?.frame.y, "The record has to hold where it really landed, for crash rescue")
        await controller.returnParkedWindows()
        XCTAssertEqual(adapter.windows.first?.frame, home)
        XCTAssertEqual(controller.parkedWindowCount, 0)
    }

    func testAWindowMacOSKeepsOnScreenGoesBackAndIsNotCountedAsParked() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        adapter.parkLands = { _ in .init(x: 700, y: 500, width: 400, height: 350) }
        var one = group("one"), two = group("two")
        one.actions[0].tabSets?[0].id = "one-set"
        two.actions[0].tabSets?[0].id = "two-set"
        XCTAssertTrue(controller.saveRoutine(one))
        XCTAssertTrue(controller.saveRoutine(two))
        try await controller.runAwaiting(routineID: "one")
        let home = try XCTUnwrap(adapter.windows.first).frame
        try await controller.runAwaiting(routineID: "two")
        XCTAssertEqual(adapter.windows.first?.frame, home, "Half parked helps nobody")
        XCTAssertEqual(controller.parkedWindowCount, 0)
        XCTAssertTrue(disk.load().isEmpty)
        XCTAssertTrue(controller.status.contains("stayed showing because macOS"))
    }

    func testMacOSPushingAParkedWindowBackDoesNotCostItsHome() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        var one = group("one"), two = group("two")
        one.actions[0].tabSets?[0].id = "one-set"
        two.actions[0].tabSets?[0].id = "two-set"
        let three = group("three", app: "editor", tabs: false)
        adapter.runningBundleIDs.insert("editor")
        adapter.windows.append(.init(id: "editor-window", bundleID: "editor", frame: .init(x: 10, y: 10, width: 500, height: 400), displayID: "main"))
        XCTAssertTrue(controller.saveRoutine(one)); XCTAssertTrue(controller.saveRoutine(two)); XCTAssertTrue(controller.saveRoutine(three))
        try await controller.runAwaiting(routineID: "one")
        let home = try XCTUnwrap(adapter.windows.first { $0.id == "tab-1-0" }).frame
        try await controller.runAwaiting(routineID: "two")
        XCTAssertEqual(controller.parkedWindowCount, 1)
        try await controller.runAwaiting(routineID: "three")
        XCTAssertTrue(adapter.hidden.contains("browser"))
        // Measured on macOS 27: showing a hidden app puts its parked window back in view.
        let pushed = WorkspaceRect(x: 700, y: 500, width: 400, height: 350)
        adapter.onShow = { id in
            guard id == "browser", let index = adapter.windows.firstIndex(where: { $0.id == "tab-1-0" }) else { return }
            adapter.windows[index].frame = pushed
        }
        try await controller.runAwaiting(routineID: "two")
        let parkedAgain = try XCTUnwrap(adapter.windows.first { $0.id == "tab-1-0" }).frame
        XCTAssertTrue(WorkspaceParking.isParked(parkedAgain, displays: adapter.displays), "The group still has to hide it")
        await controller.returnParkedWindows()
        XCTAssertEqual(adapter.windows.first { $0.id == "tab-1-0" }?.frame, home, "The spot macOS picked isn't where it belongs")
        XCTAssertEqual(controller.parkedWindowCount, 0)
    }

    /// Runs one, two and three, leaving one's window parked in a hidden browser.
    private func parkedThenHidden(_ controller: WorkspaceLaunchController, _ adapter: Adapter) async throws -> WorkspaceRect {
        var one = group("one"), two = group("two")
        one.actions[0].tabSets?[0].id = "one-set"
        two.actions[0].tabSets?[0].id = "two-set"
        adapter.runningBundleIDs.insert("editor")
        adapter.windows.append(.init(id: "editor-window", bundleID: "editor", frame: .init(x: 10, y: 10, width: 500, height: 400), displayID: "main"))
        XCTAssertTrue(controller.saveRoutine(one)); XCTAssertTrue(controller.saveRoutine(two))
        XCTAssertTrue(controller.saveRoutine(group("three", app: "editor", tabs: false)))
        try await controller.runAwaiting(routineID: "one")
        let home = try XCTUnwrap(adapter.windows.first { $0.id == "tab-1-0" }).frame
        try await controller.runAwaiting(routineID: "two")
        try await controller.runAwaiting(routineID: "three")
        XCTAssertEqual(controller.parkedWindowCount, 1)
        return home
    }

    func testBringBackFindsAWindowMacOSPushedBackInView() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, store: store())
        let home = try await parkedThenHidden(controller, adapter)
        // A person clicks the browser in the Dock.
        adapter.hidden = []
        let index = try XCTUnwrap(adapter.windows.firstIndex { $0.id == "tab-1-0" })
        adapter.windows[index].frame = .init(x: 700, y: 500, width: 400, height: 350)
        await controller.returnParkedWindows()
        XCTAssertEqual(adapter.windows[index].frame, home, "It's in view, but it's still not where it belongs")
        XCTAssertEqual(controller.parkedWindowCount, 0)
    }

    func testRunningItsOwnRoutineBringsAPushedBackWindowHome() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter, store: store())
        let home = try await parkedThenHidden(controller, adapter)
        adapter.onShow = { id in
            guard id == "browser", let index = adapter.windows.firstIndex(where: { $0.id == "tab-1-0" }) else { return }
            adapter.windows[index].frame = .init(x: 700, y: 500, width: 400, height: 350)
        }
        try await controller.runAwaiting(routineID: "one")
        XCTAssertEqual(adapter.windows.first { $0.id == "tab-1-0" }?.frame, home)
        XCTAssertEqual(adapter.launches, 2, "Its window is still open")
    }

    func testAWindowMacOSHappensToPutBackAtHomeIsNoLongerParked() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        let home = try await parkedThenHidden(controller, adapter)
        adapter.onShow = { id in
            guard id == "browser", let index = adapter.windows.firstIndex(where: { $0.id == "tab-1-0" }) else { return }
            adapter.windows[index].frame = home
        }
        try await controller.runAwaiting(routineID: "one")
        let otherWindows = adapter.windows.filter { $0.id == "tab-2-0" }
        XCTAssertEqual(adapter.windows.first { $0.id == "tab-1-0" }?.frame, home)
        XCTAssertTrue(otherWindows.allSatisfy { WorkspaceParking.isParked($0.frame, displays: adapter.displays) }, "Group one parks group two")
        XCTAssertEqual(controller.parkedWindowCount, 1, "Only group two's window is parked now")
    }

    func testAFailedRollbackKeepsTheWayHome() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        var one = group("one"), two = group("two")
        one.actions[0].tabSets?[0].id = "one-set"
        two.actions[0].tabSets?[0].id = "two-set"
        XCTAssertTrue(controller.saveRoutine(one)); XCTAssertTrue(controller.saveRoutine(two))
        try await controller.runAwaiting(routineID: "one")
        let home = try XCTUnwrap(adapter.windows.first).frame
        adapter.parkLands = { _ in .init(x: 700, y: 500, width: 400, height: 350) }
        adapter.failedMoves = ["tab-1-0"]
        adapter.parkFails = false
        try await controller.runAwaiting(routineID: "two")
        XCTAssertEqual(controller.parkedWindowCount, 1, "It's away from home, so it still has to count")
        XCTAssertEqual(disk.load().first?.home, home)
        adapter.failedMoves = []
        await controller.returnParkedWindows()
        XCTAssertEqual(adapter.windows.first?.frame, home)
    }

    func testNoRunningGroupAppLeavesScreenShowingAndUndoSurvivesShowThenCaptureFailure() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(); adapter.runningBundleIDs = ["outside"]
        let controller = controller(adapter)
        var closed = group("closed", app: "editor", tabs: false)
        closed.actions[0].openMissingApps = false
        XCTAssertTrue(controller.saveRoutine(closed))
        try await controller.runAwaiting(routineID: "closed")
        XCTAssertFalse(adapter.events.contains("hide:outside"))
        XCTAssertTrue(controller.status.contains("None of this routine's apps are open"))
        adapter.runningBundleIDs.insert("editor"); adapter.hidden = ["editor"]; adapter.captureFails = true
        do { try await controller.runAwaiting(routineID: "closed"); XCTFail("Capture fails") } catch {}
        XCTAssertTrue(controller.canRestore)
        adapter.captureFails = false
        await undo(controller)
        XCTAssertTrue(adapter.hidden.contains("editor"))
    }

    func testBringBackRequestedDuringRunRunsAfterwardsAndClampsMissingScreen() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        XCTAssertTrue(controller.saveRoutine(group("a"))); XCTAssertTrue(controller.saveRoutine(group("b")))
        try await controller.runAwaiting(routineID: "a")
        var requested = false
        adapter.afterMove = {
            guard !requested else { return }; requested = true
            await controller.returnParkedWindows()
        }
        try await controller.runAwaiting(routineID: "b")
        adapter.afterMove = nil
        for _ in 0..<1000 where controller.parkedWindowCount > 0 || controller.isBusy { await Task.yield() }
        XCTAssertTrue(requested)
        XCTAssertEqual(controller.parkedWindowCount, 0)
        XCTAssertTrue(disk.load().isEmpty)
    }

    func testCrashRescueWaitsForPermissionAndMovesAtMostOneWindowPerRecord() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        settings.workspaceLaunchJSON = WorkspaceLaunchConfig.empty.encoded()!
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store()
        let parked = try XCTUnwrap(WorkspaceParking.frame(for: .init(width: 300, height: 400), displays: adapter.displays))
        adapter.windows = [.init(id: "recover", bundleID: "browser", frame: parked),
            .init(id: "extra", bundleID: "browser", frame: parked), .init(id: "untouched", bundleID: "outside", frame: parked)]
        disk.save([.init(bundleID: "browser", home: .init(x: -4000, y: -4000, width: 300, height: 400))])
        adapter.isAccessibilityGranted = false
        let controller = controller(adapter, store: disk)
        controller.start()
        await Task.yield()
        XCTAssertFalse(disk.load().isEmpty)
        XCTAssertTrue(adapter.events.isEmpty)
        adapter.isAccessibilityGranted = true; controller.refreshPermission()
        for _ in 0..<1000 where !disk.load().isEmpty || controller.isBusy { await Task.yield() }
        XCTAssertTrue(disk.load().isEmpty)
        XCTAssertEqual(adapter.capturedApps.first, ["browser"])
        XCTAssertEqual(adapter.windows[0].frame.x, 0)
        XCTAssertEqual(adapter.windows[0].frame.y, 0)
        XCTAssertEqual(adapter.windows[1].frame, parked)
        XCTAssertEqual(adapter.events.filter { $0.hasPrefix("move:") }, ["move:recover"])
        XCTAssertEqual(adapter.windows[2].frame, parked)
    }

    func testUndoRestoresShownHiddenAndParkedWindows() async {
        let adapter = Adapter()
        let original = WorkspaceWindow(id: "w", bundleID: "browser", frame: .init(x: 50, y: 60, width: 400, height: 350))
        adapter.windows = [original]; adapter.hidden = ["outside"]
        let result = await WorkspaceLaunchExecutor.restoreCooperatively(.init(windows: [original], hiddenBundleIDs: ["outside"], shownBundleIDs: ["browser"]), adapter: adapter)
        XCTAssertTrue(result.recovery.isEmpty)
        XCTAssertEqual(adapter.events, ["move:w", "unhide:outside", "rehide:browser"])
    }

    func testBringBackClampsHomeAfterItsDisplayIsActuallyRemoved() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        let external = WorkspaceDisplay(id: "external", visibleFrame: .init(x: 1200, width: 1600, height: 1000), stableUUID: "external")
        adapter.displays.append(external)
        var a = group("a")
        a.actions[0].tabSets?[0].monitor = .specific(id: "external", name: "External")
        a.actions[0].tabSets?[0].position = .rightHalf
        XCTAssertTrue(controller.saveRoutine(a)); XCTAssertTrue(controller.saveRoutine(group("b")))
        try await controller.runAwaiting(routineID: "a")
        XCTAssertGreaterThan(try XCTUnwrap(adapter.windows.first).frame.x, 1200)
        try await controller.runAwaiting(routineID: "b")
        XCTAssertEqual(controller.parkedWindowCount, 1)
        // A failed attempt to retire an edited set must keep the old handle,
        // including when its home display disappears before Bring back.
        a.actions[0].tabSets?[0].urls = ["https://edited.example"]
        XCTAssertTrue(controller.saveRoutine(a))
        adapter.failedMoves = ["tab-1-0"]
        try await controller.runAwaiting(routineID: "a")
        adapter.failedMoves = []
        adapter.displays.removeAll { $0.id == "external" }
        await controller.returnParkedWindows()
        let frame = try XCTUnwrap(adapter.windows.first { $0.id == "tab-1-0" }).frame
        XCTAssertTrue(WorkspaceGeometry.hasReachableTitlebar(frame, on: adapter.displays.map(\.visibleFrame)))
        XCTAssertGreaterThanOrEqual(frame.x, 0)
        XCTAssertLessThanOrEqual(frame.x + frame.width, 1200)
        XCTAssertEqual(controller.parkedWindowCount, 0)
        XCTAssertTrue(disk.load().isEmpty)
    }

    func testStoreRefusalParksNothingAndAddsOneNote() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocker = folder.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let disk = WorkspaceParkedStore(url: blocker.appendingPathComponent("parked.json"))
        let adapter = Adapter(), controller = controller(adapter, store: disk)
        let a = WorkspaceRoutine(id: "a", name: "A", actions: [.openingTabs([tab("a1"), tab("a2")])], showOnly: true)
        XCTAssertTrue(controller.saveRoutine(a)); XCTAssertTrue(controller.saveRoutine(group("b")))
        try await controller.runAwaiting(routineID: "a")
        let homes = adapter.windows
        adapter.events = []
        try await controller.runAwaiting(routineID: "b")
        XCTAssertEqual(controller.parkedWindowCount, 0)
        XCTAssertFalse(adapter.events.contains { $0.hasPrefix("move:") })
        XCTAssertEqual(Array(adapter.windows.prefix(2)), homes)
        let note = "A browser window stayed showing because Dictator couldn't save its place."
        XCTAssertEqual(controller.status.components(separatedBy: note).count - 1, 1)
    }

    func testGroupWithOnlyMinimizedWindowAndFailedBringBackHidesNothing() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter)
        adapter.runningBundleIDs = ["editor", "outside"]
        adapter.windows = [.init(id: "minimized", bundleID: "editor", frame: .init(width: 300, height: 400), isMinimized: true)]
        // The adapter's default minimized-window operation refuses the request.
        XCTAssertTrue(controller.saveRoutine(group("edit", app: "editor", tabs: false)))
        try await controller.runAwaiting(routineID: "edit")
        XCTAssertFalse(adapter.events.contains("hide:outside"))
        XCTAssertTrue(controller.status.contains("None of this routine's apps are open, so nothing was hidden."))
    }

    func testGroupWhoseOnlyWindowBelongsToAnotherGroupHidesAndParksNothing() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter)
        XCTAssertTrue(controller.saveRoutine(group("a")))
        XCTAssertTrue(controller.saveRoutine(group("b", tabs: false)))
        try await controller.runAwaiting(routineID: "a")
        let windows = adapter.windows
        adapter.hidden = []
        adapter.frontmostBundleID = "outside"
        adapter.events = []
        try await controller.runAwaiting(routineID: "b")
        XCTAssertEqual(adapter.windows, windows)
        XCTAssertFalse(adapter.events.contains { $0.hasPrefix("hide:") || $0.hasPrefix("move:") })
        XCTAssertEqual(controller.parkedWindowCount, 0)
        XCTAssertTrue(controller.status.contains("None of this routine's apps are open, so nothing was hidden."))
    }

    func testPendingCrashRecordWaitsForSlowBrowserAndPreservesSavedMetadata() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        settings.workspaceLaunchJSON = WorkspaceLaunchConfig.empty.encoded()!
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        var time = Date(timeIntervalSinceReferenceDate: 100000)
        controller.now = { time }
        let home = WorkspaceRect(x: 30, y: 40, width: 300, height: 400)
        let record = WorkspaceParkedRecord(bundleID: "browser", home: home, savedAt: time,
                                          parkedAt: .init(x: 9000, y: 9000))
        disk.save([record])
        adapter.isAccessibilityGranted = false
        controller.start()
        adapter.isAccessibilityGranted = true
        await controller.returnParkedWindows()
        XCTAssertEqual(disk.load(), [record])
        time.addTimeInterval(23 * 60 * 60)
        await controller.returnParkedWindows()
        XCTAssertEqual(disk.load(), [record])
        adapter.windows = [.init(id: "late", bundleID: "browser", frame: .init(x: 9000, y: 9000, width: 300, height: 400))]
        await controller.returnParkedWindows()
        XCTAssertEqual(adapter.windows[0].frame, home)
        XCTAssertTrue(disk.load().isEmpty)
    }

    func testUnmatchedCrashRecordsExpireAt24HoursAndLegacyRecordsExpireImmediately() async {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        settings.workspaceLaunchJSON = WorkspaceLaunchConfig.empty.encoded()!
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        var time = Date(timeIntervalSinceReferenceDate: 100000)
        controller.now = { time }
        disk.save([.init(bundleID: "browser", home: .init(width: 300, height: 400), savedAt: time),
                   .init(bundleID: "browser", home: .init(width: 300, height: 400))])
        adapter.isAccessibilityGranted = false
        controller.start()
        adapter.isAccessibilityGranted = true
        await controller.returnParkedWindows()
        XCTAssertEqual(disk.load().count, 1, "A fresh unmatched record waits; the undated one expires")
        time.addTimeInterval(86400)
        await controller.returnParkedWindows()
        XCTAssertTrue(disk.load().isEmpty)
        XCTAssertFalse(adapter.events.contains { $0.hasPrefix("move:") })
    }

    func testCrashRescueMatchesClosestOnceAndLeavesPersonalUnreachableWindowUntouched() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        settings.workspaceLaunchJSON = WorkspaceLaunchConfig.empty.encoded()!
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        let home = WorkspaceRect(x: 30, y: 40, width: 300, height: 400)
        let personal = WorkspaceRect(x: -9000, y: -9000, width: 500, height: 400)
        let corner = try XCTUnwrap(WorkspaceParking.frame(for: home, displays: adapter.displays))
        var near = corner; near.x += 30
        adapter.windows = [.init(id: "personal", bundleID: "browser", frame: personal),
                           .init(id: "near", bundleID: "browser", frame: near),
                           .init(id: "closest", bundleID: "browser", frame: corner)]
        disk.save([.init(bundleID: "browser", home: home, savedAt: Date(), parkedAt: .init(x: corner.x, y: corner.y))])
        adapter.isAccessibilityGranted = false
        controller.start()
        adapter.isAccessibilityGranted = true
        await controller.returnParkedWindows()
        XCTAssertEqual(adapter.events.filter { $0.hasPrefix("move:") }, ["move:closest"])
        XCTAssertEqual(adapter.windows[0].frame, personal)
        XCTAssertEqual(adapter.windows[1].frame, near)
        XCTAssertEqual(adapter.windows[2].frame, home)
        XCTAssertTrue(disk.load().isEmpty)
    }

    func testCrashRescueLeavesAPersonalOffScreenWindowAloneWhenTheParkedOneIsGone() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        settings.workspaceLaunchJSON = WorkspaceLaunchConfig.empty.encoded()!
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), disk = store(), controller = controller(adapter, store: disk)
        let home = WorkspaceRect(x: 30, y: 40, width: 300, height: 400)
        let personal = WorkspaceRect(x: -9000, y: -9000, width: 500, height: 400)
        let corner = try XCTUnwrap(WorkspaceParking.frame(for: home, displays: adapter.displays))
        adapter.windows = [.init(id: "personal", bundleID: "browser", frame: personal)]
        disk.save([.init(bundleID: "browser", home: home, savedAt: Date(), parkedAt: .init(x: corner.x, y: corner.y))])
        adapter.isAccessibilityGranted = false
        controller.start()
        adapter.isAccessibilityGranted = true
        await controller.returnParkedWindows()
        XCTAssertEqual(adapter.windows[0].frame, personal, "Being off-screen in the same app doesn't make it Dictator's")
        XCTAssertTrue(adapter.events.filter { $0.hasPrefix("move:") }.isEmpty)
        XCTAssertFalse(disk.load().isEmpty, "The real window may still come back with the browser")
    }

    private final class Process: WorkspaceRunningApplication {
        var processIdentifier: pid_t = 42
        var bundleIdentifier: String? = "synthetic.browser"
        var launchDate: Date? = Date(timeIntervalSinceReferenceDate: 1)
        var isTerminated = false
        var isHidden = true
        var hides = 0
        func unhide() -> Bool { isHidden = false; return true }
        func hide() -> Bool { hides += 1; isHidden = true; return true }
    }

    /// macOS 27: both calls return false and the state changes a moment later.
    private final class LateProcess: WorkspaceRunningApplication {
        var processIdentifier: pid_t = 43
        var bundleIdentifier: String? = "synthetic.late"
        var launchDate: Date? = Date(timeIntervalSinceReferenceDate: 1)
        var isTerminated = false
        var isHidden = true
        var stuck = false
        private func settle(_ hidden: Bool) {
            guard !stuck else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                self.isHidden = hidden
            }
        }
        func unhide() -> Bool { settle(false); return false }
        func hide() -> Bool { settle(true); return false }
    }

    func testAFalseReturnFromMacOSIsNotAFailureWhenTheAppChanges() async throws {
        let app = LateProcess()
        let native = NativeWorkspaceLaunchAdapter(runningApplications: { _ in [app] }, runningApplication: { _ in app })
        let wasHidden = try await native.showApp(bundleID: "synthetic.late")
        XCTAssertTrue(wasHidden)
        XCTAssertFalse(app.isHidden, "The call returned false, but the app did show")
        try await native.rehideApp(bundleID: "synthetic.late")
        XCTAssertTrue(app.isHidden, "The call returned false, but the app did hide")
    }

    func testAnAppThatReallyWontChangeIsStillAFailure() async {
        let app = LateProcess()
        app.stuck = true
        let native = NativeWorkspaceLaunchAdapter(runningApplications: { _ in [app] }, runningApplication: { _ in app })
        do {
            _ = try await native.showApp(bundleID: "synthetic.late")
            XCTFail("An app that stays hidden has to be reported")
        } catch {}
    }

    func testUndoAfterRestartNeverHidesReplacementAndReportsNoFailure() async throws {
        let old = Process(), replacement = Process()
        replacement.launchDate = Date(timeIntervalSinceReferenceDate: 2)
        replacement.isHidden = false
        var current = old
        let native = NativeWorkspaceLaunchAdapter(runningApplications: { _ in [current] }, runningApplication: { _ in current })
        let wasHidden = try await native.showApp(bundleID: "synthetic.browser")
        XCTAssertTrue(wasHidden)
        current = replacement // Same PID, different launch: retained identity must win.
        let adapter = Adapter()
        adapter.rehide = { try await native.rehideApp(bundleID: $0) }
        adapter.canRehide = { native.canRehideApp(bundleID: $0) }
        adapter.frontmostBundleID = "synthetic.browser"
        let result = await WorkspaceLaunchExecutor.restoreCooperatively(.init(shownBundleIDs: ["synthetic.browser"]), adapter: adapter)
        XCTAssertTrue(adapter.events.isEmpty, "Undo does not switch focus away from a replacement process")
        XCTAssertEqual(old.hides, 0)
        XCTAssertEqual(replacement.hides, 0)
        XCTAssertFalse(replacement.isHidden)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(result.recovery.isEmpty)
    }

    func testGroupUndoUsesAppInFrontBeforeRunInsteadOfSortedFallback() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = Adapter(), controller = controller(adapter)
        adapter.runningBundleIDs = ["a-fallback", "z-original", "editor"]
        adapter.frontmostBundleID = "z-original"; adapter.hidden = ["editor"]
        adapter.windows = [.init(id: "editor", bundleID: "editor", frame: .init(width: 300, height: 400))]
        XCTAssertTrue(controller.saveRoutine(group("edit", app: "editor", tabs: false)))
        try await controller.runAwaiting(routineID: "edit")
        adapter.events = []
        await undo(controller)
        XCTAssertTrue(adapter.events.contains("focus:z-original"))
        XCTAssertFalse(adapter.events.contains("focus:a-fallback"))
        XCTAssertTrue(adapter.hidden.contains("editor"))
    }

    func testQuitRestoresBeforeReplyAndBoundsAStuckRestoration() async {
        var restored = false
        await QuitGuard.returnWindowsBeforeQuit({ restored = true })
        XCTAssertTrue(restored)
        let started = ProcessInfo.processInfo.systemUptime
        await QuitGuard.returnWindowsBeforeQuit({ try? await Task.sleep(for: .seconds(60)) }, limit: 0.02)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        restored = false
        var replied = false
        let guarder = QuitGuard(diagnostics: { _ in })
        let reply = guarder.shouldTerminate(isBusy: { false }, hasParkedWindows: { true },
            returnParkedWindows: { restored = true }, finished: { replied = true })
        XCTAssertEqual(reply, .terminateLater)
        while !replied { await Task.yield() }
        XCTAssertTrue(restored)
    }
}
