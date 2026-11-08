import XCTest
@testable import Dictator

final class WorkspaceWindowGroupTests: XCTestCase {
    private let home = WorkspaceRect(x: 100, y: 80, width: 800, height: 600)
    private func display(_ x: Double = 0, _ y: Double = 0, _ width: Double = 1440, _ height: Double = 900) -> WorkspaceDisplay {
        .init(id: "\(x),\(y)", visibleFrame: .init(x: x, y: y, width: width, height: height), isMain: x == 0 && y == 0)
    }
    private func tabs(_ id: String = "tabs", mac: String = "mini", browser: String = "chrome") -> WorkspaceTabSet {
        .init(id: id, macID: mac, macName: "Studio", browserBundleID: browser, browserName: "Chrome",
              urls: ["https://example.com", "https://example.org", "https://example.net"])
    }
    private func group(_ apps: [String] = ["editor"], keep: [String]? = nil) -> WorkspaceRoutine {
        .init(id: "routine", name: "Work", actions: [.init(id: "place", kind: .arrangeWindows, bundleIDs: apps)],
              showOnly: true, keepVisible: keep)
    }
    private func focus(_ routine: WorkspaceRoutine, running: Set<String>, hidden: Set<String> = [],
                       protected: Set<String> = [], front: String? = nil) -> WorkspaceFocusPlan {
        WorkspacePlanner.focusPlan(routine: routine, macID: "mini", aliases: [], running: running,
                                   hidden: hidden, protected: protected, frontmost: front)
    }

    func testParkingUsesMeasuredUnionCornerAndPreservesSizeAcrossLayouts() throws {
        let layouts = [[display()], [display(), display(-1920, 0, 1920, 1080)],
                       [display(), display(0, -1200, 1920, 1200)],
                       [display(-3000, -2000, 1200, 900), display(-1800, -1100, 1000, 700)],
                       [display(), display(1440, 900, 2560, 1440)]]
        for screens in layouts {
            for width in [50.0, 800, 4000] {
                for height in [50.0, 600, 3000] {
                    let original = WorkspaceRect(x: -30, y: 40, width: width, height: height)
                    let parked = try XCTUnwrap(WorkspaceParking.frame(for: original, displays: screens))
                    XCTAssertEqual(parked.x, screens.map { $0.visibleFrame.x + $0.visibleFrame.width }.max()! - 1)
                    XCTAssertEqual(parked.y, screens.map { $0.visibleFrame.y + $0.visibleFrame.height }.max()! - 1)
                    XCTAssertEqual(parked.width, width)
                    XCTAssertEqual(parked.height, height)
                    XCTAssertTrue(WorkspaceParking.isParked(parked, displays: screens))
                    XCTAssertFalse(WorkspaceGeometry.hasReachableTitlebar(parked, on: screens.map(\.visibleFrame)))
                }
            }
        }
    }

    func testParkingIgnoresUnusableScreensAndUsesTitlebarReachability() throws {
        let invalid = WorkspaceDisplay(id: "invalid", visibleFrame: .init(x: .nan, width: 100, height: 100))
        for screens in [[], [invalid]] {
            XCTAssertNil(WorkspaceParking.frame(for: home, displays: screens))
            XCTAssertFalse(WorkspaceParking.isParked(home, displays: screens))
        }
        XCTAssertNil(WorkspaceParking.frame(for: .init(), displays: [display()]))
        XCTAssertEqual(WorkspaceParking.frame(for: home, displays: [invalid, display()]),
                       .init(x: 1439, y: 899, width: 800, height: 600))
        for frame in [home, .init(x: -790, y: 100, width: 800, height: 600),
                      .init(x: 0, y: -600, width: 800, height: 600)] {
            XCTAssertEqual(WorkspaceParking.isParked(frame, displays: [display()]),
                           !WorkspaceGeometry.hasReachableTitlebar(frame, on: [display().visibleFrame]))
        }
    }

    func testTrackerPrunesDeletedSetsRoutinesAndClosedWindowsButKeepsUnknownIDs() {
        let routine = WorkspaceRoutine(id: "one", name: "One", actions: [.openingTabs([tabs("a"), tabs("b"), tabs("c")])])
        var tracker = WorkspaceTabWindowTracker()
        for id in ["c", "a", "b", "deleted"] {
            tracker.record(.init(setID: id, routineID: "one", windowID: "w-" + id, bundleID: "chrome", home: home))
        }
        tracker.record(.init(setID: "gone", routineID: "removed", windowID: "gone", bundleID: "chrome", home: nil))
        tracker.prune(liveWindowIDs: nil, routines: [routine])
        XCTAssertEqual(tracker.windowIDs, ["w-a", "w-b", "w-c"])
        XCTAssertEqual(tracker.others(than: "two", in: ["chrome"]).map(\.setID), ["a", "b", "c"])
        XCTAssertTrue(tracker.others(than: "one", in: ["chrome"]).isEmpty)
        XCTAssertTrue(tracker.others(than: "two", in: ["safari"]).isEmpty)
        tracker.prune(liveWindowIDs: ["w-b"], routines: [routine])
        XCTAssertEqual(tracker.windowIDs, ["w-b"])
        tracker.record(.init(setID: "b", routineID: "one", windowID: "replacement", bundleID: "chrome", home: nil))
        XCTAssertEqual(tracker.window(forSet: "b")?.windowID, "replacement")
        tracker.forget(setID: "b")
        XCTAssertTrue(tracker.windowIDs.isEmpty)
        tracker.record(.init(setID: "a", routineID: "different-owner", windowID: "w-a", bundleID: "chrome", home: nil))
        tracker.prune(liveWindowIDs: nil, routines: [routine])
        XCTAssertTrue(tracker.windowIDs.isEmpty, "A reused set id must not preserve a different routine's window")
    }

    func testGroupAppsAreLocalInStepOrderWithKeepVisibleLastAndNoDuplicates() {
        let local = WorkspaceAction.placing([.init(bundleID: "editor", appName: "Editor", macID: "setup-mini", macName: "Mini"),
                                             .init(bundleID: "remote", appName: "Remote", macID: "book", macName: "Book")])
        let remembered = WorkspaceSavedLayout(macName: "Mini", capturedAt: Date(), screens: [], windows: [
            .init(bundleID: "terminal", appName: "Terminal", screenID: "screen", place: .init(width: 1, height: 1))])
        let routine = WorkspaceRoutine(name: "Work", actions: [
            .openingTabs([tabs(), tabs("remote", mac: "book", browser: "safari")]), local,
            .init(kind: .centerLastWindow, bundleIDs: ["excluded-center"]),
            .init(kind: .hideIdleApps, bundleIDs: ["excluded-hide"]),
            .remembering(["setup-mini": remembered]),
            .init(kind: .arrangeWindows, bundleIDs: ["editor", "notes"])
        ], showOnly: true, keepVisible: ["music", "chrome", "notes"])
        XCTAssertEqual(routine.groupApps(macID: "hardware-mini", aliases: ["setup-mini", "mini"]),
                       ["chrome", "editor", "terminal", "notes", "music"])
        XCTAssertTrue(routine.showsOnlyItsWindows(macID: "hardware-mini", aliases: ["setup-mini"]))
    }

    func testGroupNeedsLocalWorkBeyondKeepVisibleAndShowOnlyMustBeOn() {
        var routine = WorkspaceRoutine(name: "Remote", actions: [.openingTabs([tabs(mac: "book")])], showOnly: true, keepVisible: ["music"])
        XCTAssertEqual(routine.groupApps(macID: "mini", aliases: []), ["music"])
        XCTAssertFalse(routine.showsOnlyItsWindows(macID: "mini", aliases: []))
        XCTAssertEqual(focus(routine, running: ["music", "other"]), WorkspaceFocusPlan())
        XCTAssertTrue(routine.showsOnlyItsWindows(macID: nil, aliases: ["book"]))
        routine.showOnly = false
        XCTAssertFalse(routine.showsOnlyItsWindows(macID: "book", aliases: []))
        for action in [WorkspaceAction(kind: .centerLastWindow, bundleIDs: ["editor"]),
                       WorkspaceAction(kind: .hideIdleApps, bundleIDs: ["editor"])] {
            XCTAssertFalse(WorkspaceRoutine(name: "Other", actions: [action], showOnly: true, keepVisible: ["editor"])
                .showsOnlyItsWindows(macID: "mini", aliases: []))
        }
    }

    func testFocusExcludesGroupProtectedHiddenAndNonrunningAppsAndSorts() {
        let plan = focus(group(["editor", "chrome"], keep: ["music"]),
                         running: ["editor", "chrome", "music", "z", "a", "protected", "hidden"],
                         hidden: ["hidden"], protected: ["protected"], front: "chrome")
        XCTAssertEqual(plan, WorkspaceFocusPlan(groupApps: ["editor", "chrome", "music"], appsToHide: ["a", "z"], focusApp: "chrome"))
    }

    func testFocusMovesAwayFromOutsideFrontAppAndNeverLeavesScreenEmpty() {
        XCTAssertEqual(focus(group(["closed", "editor"]), running: ["editor", "outside"], front: "outside"),
                       WorkspaceFocusPlan(groupApps: ["closed", "editor"], appsToHide: ["outside"], focusApp: "editor"))
        XCTAssertNil(focus(group(), running: ["editor"], front: "editor").focusApp)
        XCTAssertEqual(focus(group(), running: ["outside"], front: "outside"),
                       WorkspaceFocusPlan(groupApps: ["editor"], notes: ["None of this routine's apps are open, so nothing was hidden."]))
        XCTAssertEqual(focus(group(keep: ["music"]), running: ["outside", "music"], front: "outside").focusApp, "music")
        var ordinary = group()
        ordinary.showOnly = nil
        XCTAssertEqual(focus(ordinary, running: ["editor", "outside"]), WorkspaceFocusPlan())
    }

    func testPlannerAppendsFocusThenHideAfterMovesAndAddsOnePreviewNote() {
        let routine = group()
        let snapshot = WorkspaceSnapshot(displays: [display()], windows: [.init(id: "window", bundleID: "editor", frame: home)])
        let focusPlan = focus(routine, running: ["editor", "a", "b", "c"], front: "a")
        let ordinary = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [])
        let plan = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [], preview: true, focusPlan: focusPlan)
        XCTAssertEqual(plan.operations, ordinary.operations + [.focusApp(bundleID: "editor"), .hideOtherApp(bundleID: "a"),
                                                              .hideOtherApp(bundleID: "b"), .hideOtherApp(bundleID: "c")])
        XCTAssertEqual(plan.notes.filter { $0 == "Will hide 3 other apps." }.count, 1)
        let one = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [], preview: true,
                                       focusPlan: focus(routine, running: ["editor", "other"]))
        XCTAssertTrue(one.notes.contains("Will hide 1 other app."))
        let run = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [], focusPlan: focusPlan)
        XCTAssertFalse(run.notes.contains { $0.hasPrefix("Will hide") })
        let empty = WorkspacePlanner.plan(routine: routine, snapshot: .init(), protectedBundleIDs: [],
                                         focusPlan: focus(routine, running: ["outside"]))
        XCTAssertTrue(empty.operations.isEmpty)
        XCTAssertTrue(empty.notes.contains("None of this routine's apps are open, so nothing was hidden."))
        var disabled = routine
        disabled.enabled = false
        XCTAssertTrue(WorkspacePlanner.plan(routine: disabled, snapshot: snapshot, protectedBundleIDs: [], focusPlan: focusPlan).operations.isEmpty)
    }

    func testKeepVisibleValidationBoundsAndBlankIDs() {
        for ids in [[], (0..<100).map { "app\($0)" }, [String(repeating: "a", count: 255)]] {
            XCTAssertTrue(WorkspaceLaunchConfig(routines: [group(keep: ids)]).validate().isEmpty)
        }
        for ids in [Array(repeating: "app", count: 101), [""], [" \n\t"], [String(repeating: "a", count: 256)]] {
            XCTAssertEqual(WorkspaceLaunchConfig(routines: [group(keep: ids)]).validate(), ["Choose at most 100 apps to keep showing"])
        }
    }

    func testTabPlacementRequiresBothValidFieldsAndKeepsOpenTabsError() {
        var set = tabs()
        let invalid: [(WorkspaceMonitorChoice?, WorkspacePosition?)] = [(.generic(.main), nil), (nil, .leftHalf),
            (.specific(id: "", name: "Screen"), .full), (.specific(id: "screen", name: ""), .full)]
        for (monitor, position) in invalid {
            set.monitor = monitor; set.position = position
            XCTAssertFalse(set.isValid)
            XCTAssertEqual(WorkspaceLaunchConfig(routines: [.init(name: "Tabs", actions: [.openingTabs([set])])]).validate(),
                           ["Each Open tabs step needs 1–20 windows with valid web addresses"])
        }
        for monitor in [WorkspaceMonitorChoice.generic(.underPointer), .specific(id: "screen", name: "Desk")] {
            set.monitor = monitor; set.position = .leftHalf
            XCTAssertTrue(set.isValid)
        }
    }

    func testOldRoutinesAndTabSetsDecodeWithoutNewFields() throws {
        let json = #"{"version":1,"routines":[{"id":"old","name":"Desk","enabled":true,"actions":[{"id":"step","kind":"arrangeWindows","bundleIDs":["chrome"],"display":"main","layout":"halves","idleMinutes":180,"tabSets":[{"id":"tabs","macID":"mini","macName":"Studio","browserBundleID":"chrome","browserName":"Chrome","urls":["https://example.com"]}]}]}]}"#
        let config = try XCTUnwrap(WorkspaceLaunchConfig.decode(json))
        XCTAssertNil(config.routines[0].showOnly)
        XCTAssertNil(config.routines[0].keepVisible)
        XCTAssertNil(config.routines[0].actions[0].tabSets?[0].monitor)
        XCTAssertNil(config.routines[0].actions[0].tabSets?[0].position)
        XCTAssertEqual(WorkspaceLaunchConfig.decodeForEditing(json), config)
    }

    func testNewFieldsRoundTripAndSurviveEditingIncludingHotkeyRepair() throws {
        var set = tabs()
        set.monitor = .specific(id: "screen", name: "Desk"); set.position = .leftHalf
        var routine = WorkspaceRoutine(name: "Work", actions: [.openingTabs([set])], showOnly: true, keepVisible: ["music"])
        let config = WorkspaceLaunchConfig(routines: [routine])
        let json = try XCTUnwrap(config.encoded())
        XCTAssertEqual(WorkspaceLaunchConfig.decode(json), config)
        XCTAssertEqual(WorkspaceLaunchConfig.decodeForEditing(json), config)
        routine.hotkey = .init(keyCode: 0, modifiers: 0)
        let legacyJSON = String(decoding: try JSONEncoder().encode(WorkspaceLaunchConfig(routines: [routine])), as: UTF8.self)
        let repaired = try XCTUnwrap(WorkspaceLaunchConfig.decodeForEditing(legacyJSON)).routines[0]
        XCTAssertNil(repaired.hotkey)
        XCTAssertFalse(repaired.enabled)
        XCTAssertEqual(repaired.showOnly, true)
        XCTAssertEqual(repaired.keepVisible, ["music"])
        XCTAssertEqual(repaired.actions[0].tabSets, [set])
    }

    func testWordsDescribePlacementGroupAndBringBackWithoutChangingOrdinaryCopy() {
        var set = tabs()
        set.profile = .init(directory: "Profile 1", name: "Work")
        XCTAssertEqual(WorkspaceTabWords.preview(set), "Chrome (Work) will open 3 tabs on Studio.")
        set.monitor = .generic(.main); set.position = .leftHalf
        XCTAssertEqual(WorkspaceTabWords.preview(set), "Chrome (Work) will open 3 tabs on Studio, left half.")
        XCTAssertEqual(WorkspaceTabWords.bringBack(1), "Bring back 1 window")
        XCTAssertEqual(WorkspaceTabWords.bringBack(2), "Bring back 2 windows")
        let routine = group()
        XCTAssertTrue(WorkspaceWords.describe(routine, macID: "mini", appName: { $0 }).hasSuffix("then hide other apps"))
        XCTAssertTrue(WorkspaceWords.summary(routine, macID: "mini", appName: { $0 }).hasSuffix("then hide other apps."))
        var ordinary = routine; ordinary.showOnly = nil
        XCTAssertEqual(WorkspaceWords.summary(ordinary, macID: "mini", appName: { $0 }),
                       WorkspaceWords.describe(ordinary.actions[0], macID: "mini", appName: { $0 }) + ".")
        let blocked = WorkspaceTabWords.blocked(set, browsers: [.init(bundleID: "chrome", name: "Chrome")], macName: "Studio", preview: false)
        XCTAssertNotNil(blocked)
        XCTAssertFalse(blocked?.contains("Work") == true, "Failure lines can be logged and must not name a profile")
    }

    func testGroupTabOnlyRoutineRequiresCaptureAndOwnsUndoOnlyWhereLocal() {
        let routine = WorkspaceRoutine(name: "Work", actions: [.openingTabs([tabs()])], showOnly: true)
        XCTAssertTrue(routine.hasWindowSteps)
        XCTAssertFalse(routine.onlyOpensTabs)
        XCTAssertFalse(routine.onlyOpensTabs(macID: "mini", aliases: []))
        XCTAssertFalse(routine.onlyOpensTabs(macID: nil, aliases: ["mini"]))
        XCTAssertTrue(routine.onlyOpensTabs(macID: "book", aliases: []))
    }

    func testParkedStorePersistsPrivateRecordsReplacesAndRemovesFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkspaceParkedStore(url: folder.appendingPathComponent("nested/parked.json"))
        XCTAssertEqual(store.load(), [])
        let records = [WorkspaceParkedRecord(bundleID: "chrome", home: home), .init(bundleID: "editor", home: home)]
        store.save(records)
        XCTAssertEqual(store.load(), records)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [[String: Any]])
        XCTAssertEqual(Set(object[0].keys), ["bundleID", "home"])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)
        store.save([records[1]])
        XCTAssertEqual(store.load(), [records[1]])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path), ["parked.json"])
        store.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertEqual(store.load(), [])
    }

    func testParkedStoreCorruptReadsAreEmptyAndFailedEncodingPreservesRecovery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkspaceParkedStore(url: folder.appendingPathComponent("parked.json"))
        for text in ["broken", "{}", "[{}]", "[{\"bundleID\":\"chrome\"}]"] {
            try Data(text.utf8).write(to: store.url)
            XCTAssertEqual(store.load(), [])
        }
        let records = [WorkspaceParkedRecord(bundleID: "chrome", home: home)]
        store.save(records)
        store.save([.init(bundleID: "chrome", home: .init(x: .nan, width: 800, height: 600))])
        XCTAssertEqual(store.load(), records)
    }
    func testFocusRequiresUsableOwnAppAndNeverUsesKeepVisibleAlone() {
        let routine = group(["editor", "browser"], keep: ["music"])
        let empty = WorkspacePlanner.focusPlan(routine: routine, macID: "mini", aliases: [],
            running: ["editor", "browser", "music", "outside"], hidden: [], protected: [], frontmost: "editor", usable: ["music"])
        XCTAssertTrue(empty.appsToHide.isEmpty)
        XCTAssertNil(empty.focusApp)
        XCTAssertEqual(empty.notes, ["None of this routine's apps are open, so nothing was hidden."])
        let available = WorkspacePlanner.focusPlan(routine: routine, macID: "mini", aliases: [],
            running: ["editor", "browser", "outside"], hidden: [], protected: [], frontmost: "editor", usable: ["browser"])
        XCTAssertEqual(available.focusApp, "browser")
        XCTAssertEqual(available.appsToHide, ["outside"])
        let tabsWillOpen = WorkspaceRoutine(name: "Tabs", actions: [.openingTabs([tabs()])], showOnly: true)
        let preview = WorkspacePlanner.focusPlan(routine: tabsWillOpen, macID: "mini", aliases: [],
            running: ["outside"], hidden: [], protected: [], frontmost: "outside", usable: ["chrome"])
        XCTAssertEqual(preview.focusApp, "chrome", "Preview counts the browser that is about to open")
        XCTAssertEqual(preview.appsToHide, ["outside"])
    }

    func testParkedRecordsDecodeOldFieldsAndRoundTripRecoveryMetadata() throws {
        let old = try JSONDecoder().decode([WorkspaceParkedRecord].self, from: Data(#"[{"bundleID":"chrome","home":{"x":10,"y":20,"width":300,"height":400}}]"#.utf8))
        XCTAssertNil(old[0].savedAt)
        XCTAssertNil(old[0].parkedAt)
        let records = [WorkspaceParkedRecord(bundleID: "chrome", home: home,
            savedAt: Date(timeIntervalSinceReferenceDate: 100), parkedAt: .init(x: 1439, y: 899))]
        XCTAssertEqual(try JSONDecoder().decode([WorkspaceParkedRecord].self, from: JSONEncoder().encode(records)), records)
    }

    func testStoreReportsFolderEncodingAndRenameFailuresAndCleansTemporaryFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocker = folder.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        XCTAssertFalse(WorkspaceParkedStore(url: blocker.appendingPathComponent("parked.json")).save([.init(bundleID: "chrome", home: home)]))
        let target = folder.appendingPathComponent("parked.json")
        let store = WorkspaceParkedStore(url: target)
        XCTAssertTrue(store.save([.init(bundleID: "chrome", home: home)]))
        XCTAssertFalse(store.save([.init(bundleID: "chrome", home: .init(x: .nan, width: 300, height: 400))]))
        XCTAssertEqual(store.load().count, 1)
        XCTAssertTrue(store.save([]))
        XCTAssertTrue(store.save([]), "Already absent is a successful empty save")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertFalse(store.save([.init(bundleID: "chrome", home: home)]), "Renaming a file over a directory fails")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["blocker", "parked.json"])
    }

    func testStoreReportsRemovalFailureAndKeepsTheRecord() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceParkedStore(url: folder.appendingPathComponent("parked.json"))
        let records = [WorkspaceParkedRecord(bundleID: "chrome", home: home)]
        XCTAssertTrue(store.save(records))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        XCTAssertFalse(store.save([]))
        XCTAssertEqual(store.load(), records)
    }

}
