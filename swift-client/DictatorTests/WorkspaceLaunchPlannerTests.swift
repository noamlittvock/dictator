import XCTest
@testable import Dictator

final class WorkspaceLaunchPlannerTests: XCTestCase {
    private let screen = WorkspaceDisplay(id: "main", name: "Main", visibleFrame: WorkspaceRect(x: 10, y: 20, width: 1000, height: 800), isMain: true)

    func testUnavailableAppNotesUsePreviewOrResultTenseForPlacementsAndRemember() {
        let saved = WorkspaceSavedLayout(macName: "Mini", capturedAt: Date(timeIntervalSince1970: 0), screens: [screen], windows: [
            .init(bundleID: "chat", appName: "ChatGPT", screenID: screen.id, place: .init(width: 1, height: 1))
        ])
        let placement = WorkspaceAction.placing([.init(bundleID: "chat", appName: "ChatGPT", macID: "mini", macName: "Mini")])
        for original in [placement, .remembering(["mini": saved])] {
            for choice in [nil, false, true] as [Bool?] {
                var action = original
                action.openMissingApps = choice
                let routine = WorkspaceRoutine(name: "Desk", actions: [action])
                for preview in [true, false] {
                    let ending = preview ? "it won't move." : "it wasn't moved."
                    let running = WorkspaceSnapshot(displays: [screen], applications: [.init(bundleID: "chat")])
                    let plan = WorkspacePlanner.plan(routine: routine, snapshot: running, protectedBundleIDs: [], macID: "mini", preview: preview)
                    XCTAssertEqual(plan.notes, ["ChatGPT has no available window on this desktop, so \(ending)"])
                    // A captured but unmeasurable window is also evidence that the app is open.
                    let unmeasurable = WorkspaceSnapshot(displays: [screen], windows: [.init(id: "w", bundleID: "chat")])
                    XCTAssertEqual(WorkspacePlanner.plan(routine: routine, snapshot: unmeasurable, protectedBundleIDs: [], macID: "mini", preview: preview).notes, plan.notes)
                    let closed = WorkspaceSnapshot(displays: [screen])
                    let hint = choice == true ? "" : " Turn on “Open these apps if they aren't open” to open it."
                    XCTAssertEqual(WorkspaceLayoutRestorer.unavailableNote(bundleID: "chat", name: "ChatGPT", snapshot: closed, openMissingApps: choice == true, preview: preview), "ChatGPT isn't open, so \(ending)\(hint)")
                    if !preview || choice != true {
                        XCTAssertEqual(WorkspacePlanner.plan(routine: routine, snapshot: closed, protectedBundleIDs: [], macID: "mini", preview: preview).notes, ["ChatGPT isn't open, so \(ending)\(hint)"])
                    }
                }
            }
        }
    }

    func testSkippedWindowNotesUsePreviewAndResultTenseThroughBothPaths() {
        let saved = WorkspaceSavedLayout(macName: "Mini", capturedAt: Date(timeIntervalSince1970: 0), screens: [screen], windows: [
            .init(bundleID: "chat", appName: "ChatGPT", screenID: screen.id, place: .init(width: 1, height: 1))
        ])
        let cases: [(WorkspaceSkipReason, String, String)] = [
            (.slowToRespond, "ChatGPT is too slow to answer — try again.", "ChatGPT was too slow to answer — try again."),
            (.fullScreen, "Will skip 1 full-screen ChatGPT window.", "Skipped 1 full-screen ChatGPT window."),
            (.unreadable, "Will skip 1 ChatGPT window Dictator can't read.", "Skipped 1 ChatGPT window Dictator couldn't read."),
            (.minimized, "Will skip 1 minimized ChatGPT window.", "Skipped 1 minimized ChatGPT window."),
            (.fixedPosition, "Will skip 1 ChatGPT window that can't be moved.", "Skipped 1 ChatGPT window that can't be moved."),
            (.fixedSize, "Will skip 1 ChatGPT window that can't be resized.", "Skipped 1 ChatGPT window that can't be resized.")
        ]
        for action in [WorkspaceAction.remembering(["mini": saved]), .placing([.init(bundleID: "chat", appName: "ChatGPT", macID: "mini", macName: "Mini")])] {
            for (reason, previewLine, resultLine) in cases {
                for count in [1, 2] {
                    let snapshot = WorkspaceSnapshot(displays: [screen], skipped: [.init(bundleID: "chat", appName: "ChatGPT", reason: reason, count: count)])
                    for preview in [true, false] {
                        var expected = preview ? previewLine : resultLine
                        if count == 2 { expected = expected.replacingOccurrences(of: "1 ", with: "2 ").replacingOccurrences(of: "window", with: "windows") }
                        XCTAssertEqual(WorkspacePlanner.plan(routine: .init(name: "Desk", actions: [action]), snapshot: snapshot, protectedBundleIDs: [], macID: "mini", preview: preview).notes, [expected])
                    }
                }
            }
        }
    }

    func testScreenFallbackNotesUsePreviewAndResultTense() {
        let above = WorkspaceDisplay(id: "above", visibleFrame: .init(x: 10, y: -780, width: 1000, height: 800))
        let beside = WorkspaceDisplay(id: "beside", visibleFrame: .init(x: 1010, y: 20, width: 1000, height: 800))
        let cases: [(WorkspaceDisplayChoice, [WorkspaceDisplay], String, String)] = [
            (.main, [], "Dictator can't find a screen to use, so it will skip this step.", "Dictator found no screen to use, so it skipped this step."),
            (.left, [screen], "This Mac has one screen, so ‘Left screen’ will use it.", "This Mac has one screen, so ‘Left screen’ used it."),
            (.left, [screen, above], "These screens are stacked, so ‘Left screen’ will use the main screen.", "These screens are stacked, so ‘Left screen’ used the main screen."),
            (.top, [screen, beside], "These screens are side by side, so ‘Top screen’ will use the main screen.", "These screens are side by side, so ‘Top screen’ used the main screen."),
            (.builtIn, [screen], "No built-in screen is available, so ‘Built-in screen’ will use the main screen.", "No built-in screen was found, so ‘Built-in screen’ used the main screen."),
            (.underPointer, [screen], "The pointer position is not available, so ‘Screen under the pointer’ will use the main screen.", "The pointer position was not available, so ‘Screen under the pointer’ used the main screen.")
        ]
        for (choice, displays, previewLine, resultLine) in cases {
            for preview in [true, false] {
                let snapshot = WorkspaceSnapshot(displays: displays, windows: [.init(id: "w", bundleID: "chat", frame: screen.visibleFrame)])
                let expected = preview ? previewLine : resultLine
                let placing = WorkspaceAction.placing([.init(bundleID: "chat", appName: "ChatGPT", macID: "mini", macName: "Mini", monitor: .generic(choice))])
                XCTAssertEqual(WorkspacePlanner.plan(routine: .init(name: "Desk", actions: [placing]), snapshot: snapshot, protectedBundleIDs: [], macID: "mini", preview: preview).notes, ["On Mini: " + expected])
                var arrange = WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["chat"])
                arrange.displayOverrides = ["mini": choice]
                for kind in [WorkspaceActionKind.arrangeWindows, .centerLastWindow] {
                    arrange.kind = kind
                    var focused = snapshot
                    focused.frontmostWindowID = "w"
                    XCTAssertEqual(WorkspacePlanner.plan(routine: .init(name: "Desk", actions: [arrange]), snapshot: focused, protectedBundleIDs: [], macID: "mini", preview: preview).notes, [expected])
                }
            }
        }
        let missing = WorkspaceDisplay(id: "missing", name: "Studio Display", visibleFrame: screen.visibleFrame)
        let saved = WorkspaceSavedLayout(macName: "Mini", capturedAt: Date(timeIntervalSince1970: 0), screens: [missing], windows: [
            .init(bundleID: "chat", appName: "ChatGPT", screenID: missing.id, place: .init(width: 1, height: 1))
        ])
        for preview in [true, false] {
            let snapshot = WorkspaceSnapshot(displays: [screen], windows: [.init(id: "w", bundleID: "chat", frame: screen.visibleFrame)])
            let remember = WorkspaceAction.remembering(["mini": saved])
            XCTAssertEqual(WorkspacePlanner.plan(routine: .init(name: "Desk", actions: [remember]), snapshot: snapshot, protectedBundleIDs: [], macID: "mini", preview: preview).notes,
                           ["‘Studio Display’ isn't connected, so its windows \(preview ? "will go" : "went") to the main screen."])
            let placing = WorkspaceAction.placing([.init(bundleID: "chat", appName: "ChatGPT", macID: "mini", macName: "Mini", monitor: .specific(id: "missing", name: "Studio Display"))])
            XCTAssertEqual(WorkspacePlanner.plan(routine: .init(name: "Desk", actions: [placing]), snapshot: snapshot, protectedBundleIDs: [], macID: "mini", preview: preview).notes,
                           ["Studio Display isn't connected to Mini, so its main screen \(preview ? "will be used" : "was used")."])
        }
    }

    func testUnmeasurableCenterAndUnknownActivityNotesUsePreviewAndResultTense() {
        let cases: [(WorkspaceAction, WorkspaceSnapshot, String, String)] = [
            (.init(kind: .arrangeWindows, bundleIDs: ["chat"]), .init(displays: [screen], windows: [.init(id: "w", bundleID: "chat")]), "Dictator will skip some windows it can't measure.", "Dictator skipped some windows it couldn't measure."),
            (.init(kind: .centerLastWindow), .init(displays: [screen]), "Dictator can't find the window you're using to center.", "Dictator couldn't find the window you're using to center."),
            (.init(kind: .hideIdleApps, bundleIDs: ["chat"]), .init(displays: [screen], applications: [.init(bundleID: "chat", name: "ChatGPT")]), "Dictator doesn't know when you last used ChatGPT, so it won't hide.", "Dictator doesn't know when you last used ChatGPT, so it wasn't hidden.")
        ]
        for (action, snapshot, previewLine, resultLine) in cases {
            for preview in [true, false] {
                XCTAssertEqual(WorkspacePlanner.plan(routine: .init(name: "Desk", actions: [action]), snapshot: snapshot, protectedBundleIDs: [], preview: preview).notes, [preview ? previewLine : resultLine])
            }
        }
    }

    func testOldShortcutPolicyPreservesRoutinesForEditingWithoutEnablingThem() throws {
        let original = WorkspaceLaunchConfig(routines: [WorkspaceRoutine(name: "Keep my actions", hotkey: WorkspaceHotkey(keyCode: 15, modifiers: 768), actions: [WorkspaceAction(kind: .centerLastWindow)])])
        let json = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        XCTAssertNil(WorkspaceLaunchConfig.decode(json), "Wire validation remains strict")
        let editable = try XCTUnwrap(WorkspaceLaunchConfig.decodeForEditing(json))
        XCTAssertEqual(editable.routines.first?.id, original.routines.first?.id)
        XCTAssertEqual(editable.routines.first?.actions, original.routines.first?.actions)
        XCTAssertEqual(editable.routines.first?.enabled, false)
        XCTAssertNil(editable.routines.first?.hotkey)
        XCTAssertNotNil(editable.encoded())
    }

    func testRestoreClampsToTheOriginalDisplayOrFallsBackToMain() throws {
        let main = WorkspaceDisplay(id: "main", visibleFrame: WorkspaceRect(x: 0, y: 20, width: 1440, height: 880), isMain: true)
        let swapped = WorkspaceDisplay(id: "external", visibleFrame: WorkspaceRect(x: 1440, y: 0, width: 1920, height: 1080))
        let window = WorkspaceWindow(id: "w", bundleID: "app", frame: WorkspaceRect(x: -2400, y: 0, width: 2000, height: 1200), displayID: "external")
        let moved = try XCTUnwrap(WorkspaceGeometry.restorationFrame(for: window, displays: [main, swapped]))
        XCTAssertEqual(moved, WorkspaceRect(x: 1440, y: 0, width: 1920, height: 1080))
        let disconnected = try XCTUnwrap(WorkspaceGeometry.restorationFrame(for: window, displays: [main]))
        XCTAssertEqual(disconnected, WorkspaceRect(x: 0, y: 20, width: 1440, height: 880))
    }

    func testCellAlignedSizesFitButMinimumSizeOverflowDoesNot() {
        let target = WorkspaceRect(x: 100, y: 50, width: 720, height: 430)
        XCTAssertTrue(WorkspaceGeometry.isAcceptableResult(WorkspaceRect(x: 100, y: 50, width: 714, height: 416), for: target))
        XCTAssertFalse(WorkspaceGeometry.isAcceptableResult(WorkspaceRect(x: 100, y: 50, width: 900, height: 600), for: target))
        XCTAssertFalse(WorkspaceGeometry.isAcceptableResult(WorkspaceRect(x: 500, y: 50, width: 714, height: 416), for: target))
    }

    func testGeometryUsesThePrimaryDisplayOriginAndRejectsDisconnectedScreen() {
        let above = WorkspaceGeometry.accessibilityFrame(WorkspaceRect(x: -1200, y: 900, width: 1200, height: 800), primaryTop: 900)
        XCTAssertEqual(above, WorkspaceRect(x: -1200, y: -800, width: 1200, height: 800))
        let window = WorkspaceRect(x: -1100, y: -700, width: 500, height: 300)
        XCTAssertTrue(WorkspaceGeometry.hasReachableTitlebar(window, on: [above]))
        XCTAssertFalse(WorkspaceGeometry.hasReachableTitlebar(window, on: [WorkspaceRect(x: 0, y: 0, width: 1440, height: 900)]))
    }

    func testConfigValidationAndRoundTrip() throws {
        let key = WorkspaceHotkey(keyCode: 12, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.option | WorkspaceHotkey.control)
        let config = WorkspaceLaunchConfig(routines: [WorkspaceRoutine(name: "Work", hotkey: key,
            actions: [WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["com.example.app"])])])
        XCTAssertTrue(config.validate().isEmpty)
        XCTAssertEqual(WorkspaceLaunchConfig.decode(try XCTUnwrap(config.encoded())), config)
        XCTAssertNil(WorkspaceLaunchConfig.decode("{\"version\":2,\"routines\":[]}"))
        XCTAssertFalse(WorkspaceLaunchConfig(routines: [WorkspaceRoutine(name: "Shift", hotkey: WorkspaceHotkey(keyCode: 12, modifiers: WorkspaceHotkey.shift))]).validate().isEmpty)
    }

    func testArrangementsChainAndTileWithoutOverlap() {
        let windows = (1...5).map { WorkspaceWindow(id: "w\($0)", bundleID: "app", frame: WorkspaceRect(x: 0, y: 0, width: 100, height: 100)) }
        let routine = WorkspaceRoutine(name: "Arrange", actions: [
            WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["app"], display: .main, layout: .quarters),
            WorkspaceAction(kind: .centerLastWindow, display: .main)
        ])
        let plan = WorkspacePlanner.plan(routine: routine, snapshot: WorkspaceSnapshot(capturedAt: Date(timeIntervalSince1970: 1), displays: [screen], windows: windows, frontmostWindowID: "w1"), protectedBundleIDs: [])
        XCTAssertEqual(plan.operations.count, 6)
        let tiles = Array(plan.operations.prefix(5)).compactMap { if case .moveWindow(_, let rect) = $0 { return rect }; return nil }
        XCTAssertTrue(tiles.allSatisfy(\.isUsable))
        for i in tiles.indices {
            for j in tiles.indices where j > i {
                let overlapWidth = min(tiles[i].x + tiles[i].width, tiles[j].x + tiles[j].width) - max(tiles[i].x, tiles[j].x)
                let overlapHeight = min(tiles[i].y + tiles[i].height, tiles[j].y + tiles[j].height) - max(tiles[i].y, tiles[j].y)
                XCTAssertLessThanOrEqual(max(0, overlapWidth) * max(0, overlapHeight), 0.000001)
            }
        }
        guard case .moveWindow(id: "w1", let centered) = plan.operations[5] else { return XCTFail("Expected centered frontmost window") }
        XCTAssertEqual(centered.x, 10 + (1000 - 1000.0 / 3) / 2, accuracy: 0.000001)
        XCTAssertEqual(centered.y, 220, accuracy: 0.000001)
        XCTAssertEqual(centered.width, 1000.0 / 3, accuracy: 0.000001)
        XCTAssertEqual(centered.height, 400, accuracy: 0.000001)
    }

    func testMinimizedAndUnavailableDisplaysAreSkipped() {
        let routine = WorkspaceRoutine(name: "Arrange", actions: [WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["app"], display: .main)])
        let snapshot = WorkspaceSnapshot(displays: [], windows: [WorkspaceWindow(id: "w", bundleID: "app", isMinimized: true)])
        let plan = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [])
        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertFalse(plan.notes.isEmpty)
        let minimized = WorkspacePlanner.plan(routine: routine, snapshot: WorkspaceSnapshot(displays: [screen], windows: [WorkspaceWindow(id: "w", bundleID: "app", frame: WorkspaceRect(x: 0, y: 0, width: 100, height: 100), isMinimized: true)]), protectedBundleIDs: [])
        XCTAssertTrue(minimized.operations.isEmpty)
    }

    func testFixedSizeSelectedWindowIsNamedInPreviewWithoutAddingAMove() throws {
        let reason = try XCTUnwrap(WorkspaceSkipDetector.geometrySkipReason(positionSettable: true, sizeSettable: false))
        let routine = WorkspaceRoutine(name: "Desk", actions: [WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["editor", "calculator"], layout: .halves)])
        let snapshot = WorkspaceSnapshot(
            displays: [screen],
            windows: [WorkspaceWindow(id: "editable", bundleID: "editor", frame: WorkspaceRect(x: 30, y: 40, width: 600, height: 400))],
            applications: [WorkspaceApplication(bundleID: "editor"), WorkspaceApplication(bundleID: "calculator")],
            skipped: [WorkspaceSkip(bundleID: "calculator", appName: "Calculator", reason: reason)]
        )
        let plan = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [])
        XCTAssertTrue(plan.notes.contains("Skipped 1 Calculator window that can't be resized."))
        XCTAssertEqual(plan.operations.count, 1)
        guard case .moveWindow(id: "editable", _) = plan.operations[0] else {
            return XCTFail("Only the existing movable, resizable editor window may move")
        }
    }

    func testFixedPositionWindowsAreNamedAndSettableWindowsStayEligible() {
        XCTAssertNil(WorkspaceSkipDetector.geometrySkipReason(positionSettable: true, sizeSettable: true))
        XCTAssertEqual(WorkspaceSkipDetector.geometrySkipReason(positionSettable: false, sizeSettable: true), .fixedPosition)
        XCTAssertEqual(WorkspaceSkipDetector.geometrySkipReason(positionSettable: false, sizeSettable: false), .fixedPosition)
        XCTAssertEqual(WorkspaceSkip.lines([WorkspaceSkip(bundleID: "app", appName: "Example", reason: .fixedPosition, count: 2)]),
                       ["Skipped 2 Example windows that can't be moved."])
    }

    func testHideOnlyKnownIdleUnprotectedNonfrontmostApplications() {
        let now = Date(timeIntervalSince1970: 10_000)
        let apps = [
            WorkspaceApplication(bundleID: "idle", lastActivatedAt: now.addingTimeInterval(-10_000)),
            WorkspaceApplication(bundleID: "unknown"),
            WorkspaceApplication(bundleID: "protected", lastActivatedAt: now.addingTimeInterval(-10_000)),
            WorkspaceApplication(bundleID: "front", lastActivatedAt: now.addingTimeInterval(-10_000)),
        ]
        let action = WorkspaceAction(kind: .hideIdleApps, bundleIDs: apps.map(\.bundleID), idleMinutes: 60)
        let snapshot = WorkspaceSnapshot(capturedAt: now, windows: [WorkspaceWindow(id: "front-window", bundleID: "front")], applications: apps, frontmostWindowID: "front-window")
        let plan = WorkspacePlanner.plan(routine: WorkspaceRoutine(name: "Hide", actions: [action]), snapshot: snapshot, protectedBundleIDs: ["protected"])
        XCTAssertEqual(plan.operations, [.hideApp(bundleID: "idle")])
        XCTAssertEqual(plan.notes.count, 1)
    }

    // MARK: Plain words for the page

    func testPlacementNamesHalvesQuartersColumnsAndMiddle() {
        let s = WorkspaceRect(x: 10, y: 20, width: 1000, height: 800)
        func tiles(_ count: Int, _ layout: WorkspaceLayout) -> [String] {
            WorkspacePlanner.tileFrames(in: s, count: count, layout: layout).map { WorkspaceWords.placement($0, on: s) }
        }
        XCTAssertEqual(tiles(2, .halves), ["left half", "right half"])
        XCTAssertEqual(tiles(4, .quarters), ["top-left quarter", "top-right quarter", "bottom-left quarter", "bottom-right quarter"])
        XCTAssertEqual(tiles(3, .columns), ["column 1 of 3", "column 2 of 3", "column 3 of 3"])
        XCTAssertEqual(tiles(6, .quarters), ["row 1, column 1", "row 1, column 2", "row 1, column 3", "row 2, column 1", "row 2, column 2", "row 2, column 3"])
        XCTAssertEqual(tiles(1, .columns), ["full screen"])
        XCTAssertEqual(WorkspaceWords.placement(WorkspaceRect(x: 310, y: 220, width: 400, height: 400), on: s), "middle")
    }

    func testPreviewLinesNameTheAppPlaceAndScreenOnlyWhenThereAreSeveral() {
        let side = WorkspaceDisplay(id: "side", name: "LG UltraFine", visibleFrame: WorkspaceRect(x: 1010, y: 20, width: 1000, height: 800))
        let windows = [WorkspaceWindow(id: "a", bundleID: "s", appName: "Safari", frame: WorkspaceRect(x: 0, y: 0, width: 100, height: 100)),
                       WorkspaceWindow(id: "b", bundleID: "m", appName: "Mail", frame: WorkspaceRect(x: 0, y: 0, width: 100, height: 100))]
        let routine = WorkspaceRoutine(name: "Desk", actions: [WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["s", "m"], display: .right, layout: .halves)])
        let two = WorkspaceSnapshot(displays: [screen, side], windows: windows)
        let picture = WorkspacePreviewPicture.make(plan: WorkspacePlanner.plan(routine: routine, snapshot: two, protectedBundleIDs: []), snapshot: two)
        XCTAssertEqual(picture.lines, ["Safari → left half, LG UltraFine", "Mail → right half, LG UltraFine"])
        let one = WorkspaceSnapshot(displays: [screen], windows: windows)
        let single = WorkspacePreviewPicture.make(plan: WorkspacePlanner.plan(routine: routine, snapshot: one, protectedBundleIDs: []), snapshot: one)
        XCTAssertEqual(single.lines, ["Safari → left half", "Mail → right half"])
    }

    func testRoutineSummaryReadsAsOneSentence() {
        let names = ["com.apple.Safari": "Safari", "com.apple.mail": "Mail", "com.tinyspeck.slackmacgap": "Slack"]
        let routine = WorkspaceRoutine(name: "Desk", actions: [
            WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["com.apple.Safari", "com.apple.mail"], layout: .halves),
            WorkspaceAction(kind: .centerLastWindow, display: .left, displayOverrides: ["laptop": .builtIn]),
            WorkspaceAction(kind: .hideIdleApps, bundleIDs: ["com.tinyspeck.slackmacgap"], idleMinutes: 60),
        ])
        XCTAssertEqual(WorkspaceWords.summary(routine, macID: "desk", appName: { names[$0] ?? $0 }),
                       "Arrange Safari and Mail in halves on the main screen, then center the window you're using on the left screen, then hide Slack after 1 hour without use.")
        XCTAssertTrue(WorkspaceWords.summary(routine, macID: "laptop", appName: { names[$0] ?? $0 }).contains("on the built-in screen"))
    }

    func testMissingSaysWhatStillBlocksSaving() {
        XCTAssertEqual(WorkspaceWords.missing(WorkspaceRoutine(name: " ", actions: [])), ["a name", "a step"])
        XCTAssertEqual(WorkspaceWords.missing(WorkspaceStarter.sideBySide.routine()), ["the apps to use"])
        XCTAssertEqual(WorkspaceWords.missing(WorkspaceStarter.centerWindow.routine()), [])
        let two = WorkspaceRoutine(name: "Two", actions: [WorkspaceAction(kind: .centerLastWindow), WorkspaceAction(kind: .hideIdleApps)])
        XCTAssertEqual(WorkspaceWords.missing(two), ["the apps for step 2"])
        XCTAssertEqual(WorkspaceWords.list(["a", "b", "c"]), "a, b and c")
    }

    func testEveryStarterSavesOnceItsAppsAreChosen() {
        for starter in WorkspaceStarter.allCases {
            var routine = starter.routine()
            for index in routine.actions.indices where routine.actions[index].kind != .centerLastWindow { routine.actions[index].bundleIDs = ["com.apple.Safari"] }
            XCTAssertEqual(WorkspaceWords.missing(routine), [], starter.title)
            XCTAssertNotNil(WorkspaceLaunchConfig(routines: [routine]).encoded(), starter.title)
        }
    }

    // MARK: Remembered layouts

    private let laptop = WorkspaceDisplay(id: "1", name: "Built-in Retina Display", visibleFrame: WorkspaceRect(x: 0, y: 0, width: 1500, height: 1000), isMain: true, isBuiltIn: true)
    private let monitor = WorkspaceDisplay(id: "2", name: "LG UltraFine", visibleFrame: WorkspaceRect(x: 1500, y: 0, width: 2560, height: 1415), isBuiltIn: false)

    private func rememberedDesk() -> WorkspaceSavedLayout {
        let windows = [
            WorkspaceWindow(id: "s1", bundleID: "safari", appName: "Safari", frame: WorkspaceRect(x: 1500, y: 0, width: 1280, height: 1415), displayID: "2"),
            WorkspaceWindow(id: "s2", bundleID: "safari", appName: "Safari", frame: WorkspaceRect(x: 375, y: 250, width: 750, height: 500), displayID: "1"),
            WorkspaceWindow(id: "m1", bundleID: "mail", appName: "Mail", frame: WorkspaceRect(x: 2780, y: 0, width: 1280, height: 1415), displayID: "2"),
            WorkspaceWindow(id: "x", bundleID: "notes", appName: "Notes", frame: WorkspaceRect(x: 0, y: 0, width: 100, height: 100), isMinimized: true),
        ]
        let made = WorkspaceSavedLayout.make(snapshot: WorkspaceSnapshot(capturedAt: Date(timeIntervalSinceReferenceDate: 1000), displays: [laptop, monitor], windows: windows), macName: "MacBook Pro")
        XCTAssertTrue(made.notes.isEmpty)
        return made.layout
    }

    func testRememberingKeepsOpenWindowsAsPlacesOnTheirScreens() {
        let layout = rememberedDesk()
        XCTAssertEqual(layout.windows.map(\.bundleID), ["safari", "safari", "mail"], "Minimized windows are not remembered")
        XCTAssertEqual(layout.windows[0].screenID, "2")
        XCTAssertEqual(layout.windows[0].place, WorkspaceRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(layout.windows[2].place, WorkspaceRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(layout.bundleIDs, ["safari", "mail"])
        XCTAssertEqual(layout.countSummary, "3 windows in 2 apps")
        XCTAssertTrue(layout.isValid)
        XCTAssertEqual(layout.picture.tiles.count, 3)
    }

    func testRestoringMatchesWindowsBySizeAndPutsThemBack() {
        let layout = rememberedDesk()
        // Later: the windows were moved around and swapped; Mail is still open, a third Safari window appeared.
        let now = [
            WorkspaceWindow(id: "a", bundleID: "safari", appName: "Safari", frame: WorkspaceRect(x: 300, y: 300, width: 700, height: 520), displayID: "1"),
            WorkspaceWindow(id: "b", bundleID: "safari", appName: "Safari", frame: WorkspaceRect(x: 50, y: 50, width: 1300, height: 1400), displayID: "1"),
            WorkspaceWindow(id: "c", bundleID: "safari", appName: "Safari", frame: WorkspaceRect(x: 10, y: 10, width: 400, height: 300), displayID: "1"),
            WorkspaceWindow(id: "d", bundleID: "mail", appName: "Mail", frame: WorkspaceRect(x: 0, y: 25, width: 800, height: 600), displayID: "1"),
        ]
        let restore = WorkspaceLayoutRestorer.plan(layout, snapshot: WorkspaceSnapshot(displays: [laptop, monitor], windows: now))
        let moves = Dictionary(uniqueKeysWithValues: restore.moves.map { ($0.0, $0.1) })
        XCTAssertEqual(moves["b"], WorkspaceRect(x: 1500, y: 0, width: 1280, height: 1415), "The big window goes back to the big spot")
        XCTAssertEqual(moves["a"], WorkspaceRect(x: 375, y: 250, width: 750, height: 500))
        XCTAssertNil(moves["c"], "An extra window is left alone")
        XCTAssertEqual(moves["d"], WorkspaceRect(x: 2780, y: 0, width: 1280, height: 1415))
        XCTAssertEqual(restore.notes, [])
    }

    func testRestoringWithoutTheMonitorUsesTheMainScreenAndSaysWhatIsMissing() {
        let layout = rememberedDesk()
        let now = [WorkspaceWindow(id: "a", bundleID: "safari", appName: "Safari", frame: WorkspaceRect(x: 0, y: 25, width: 500, height: 500), displayID: "1")]
        let restore = WorkspaceLayoutRestorer.plan(layout, snapshot: WorkspaceSnapshot(displays: [laptop], windows: now))
        XCTAssertEqual(restore.moves.count, 1)
        XCTAssertTrue(restore.notes.contains("‘LG UltraFine’ isn't connected, so its windows went to the main screen."), "\(restore.notes)")
        XCTAssertTrue(restore.notes.contains("Safari: 1 remembered window is unavailable on this desktop."), "\(restore.notes)")
        XCTAssertTrue(restore.notes.contains("Mail isn't open, so it wasn't moved. Turn on “Open these apps if they aren't open” to open it."), "\(restore.notes)")
    }

    func testARememberedStepRestoresOnlyThisMacsLayout() {
        let layout = rememberedDesk()
        let routine = WorkspaceRoutine(name: "Desk", actions: [.remembering(["book": layout])])
        XCTAssertEqual(routine.actions[0].bundleIDs, ["safari", "mail"], "An older build can still tile these apps")
        let snapshot = WorkspaceSnapshot(displays: [laptop, monitor], windows: [
            WorkspaceWindow(id: "d", bundleID: "mail", appName: "Mail", frame: WorkspaceRect(x: 0, y: 25, width: 800, height: 600), displayID: "1")])
        let here = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [], macID: "book")
        XCTAssertEqual(here.operations, [.moveWindow(id: "d", frame: WorkspaceRect(x: 2780, y: 0, width: 1280, height: 1415))])
        let elsewhere = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [], macID: "mini")
        XCTAssertEqual(elsewhere.operations, [])
        XCTAssertTrue(elsewhere.notes.isEmpty)
        XCTAssertEqual(WorkspaceWords.summary(routine, macID: "book", appName: { $0 }), "Put 3 windows back where they were on MacBook Pro.")
    }

    func testRememberedRoutinesSaveAndBadLayoutsAreRefused() throws {
        let routine = WorkspaceRoutine.remembering(["book": rememberedDesk()], existing: [WorkspaceRoutine(name: "My layout", actions: [WorkspaceAction(kind: .centerLastWindow)])])
        XCTAssertEqual(routine.name, "My layout 2")
        let config = WorkspaceLaunchConfig(routines: [routine])
        let json = try XCTUnwrap(config.encoded())
        XCTAssertEqual(WorkspaceLaunchConfig.decode(json), config)
        XCTAssertLessThan(json.utf8.count, 2_000, "Places are rounded so routines stay small")
        var broken = rememberedDesk()
        broken.windows[0].place.width = .infinity
        XCTAssertFalse(WorkspaceLaunchConfig(routines: [WorkspaceRoutine(name: "Bad", actions: [.remembering(["book": broken])])]).validate().isEmpty)
    }
}


extension WorkspaceLaunchPlannerTests {
    func testEveryPlacementPositionOnNonZeroOriginScreen() {
        let screen = WorkspaceRect(x: -1800, y: -240, width: 1200, height: 900)
        let expected: [(WorkspacePosition, WorkspaceRect)] = [
            (.full, .init(x: -1800, y: -240, width: 1200, height: 900)),
            (.leftHalf, .init(x: -1800, y: -240, width: 600, height: 900)),
            (.rightHalf, .init(x: -1200, y: -240, width: 600, height: 900)),
            (.topHalf, .init(x: -1800, y: -240, width: 1200, height: 450)),
            (.bottomHalf, .init(x: -1800, y: 210, width: 1200, height: 450)),
            (.topLeft, .init(x: -1800, y: -240, width: 600, height: 450)),
            (.topRight, .init(x: -1200, y: -240, width: 600, height: 450)),
            (.bottomLeft, .init(x: -1800, y: 210, width: 600, height: 450)),
            (.bottomRight, .init(x: -1200, y: 210, width: 600, height: 450)),
            (.leftThird, .init(x: -1800, y: -240, width: 400, height: 900)),
            (.centerThird, .init(x: -1400, y: -240, width: 400, height: 900)),
            (.rightThird, .init(x: -1000, y: -240, width: 400, height: 900))
        ]
        XCTAssertEqual(Set(expected.map { $0.0 }), Set(WorkspacePosition.allCases))
        for (position, frame) in expected { XCTAssertEqual(position.frame(on: screen), frame, position.rawValue) }
    }

    func testPlacementsOnlyMoveNamedMacAndAppAndStackAllItsWindows() {
        let display = WorkspaceDisplay(id: "studio", name: "Studio Display", visibleFrame: .init(x: 1400, y: -100, width: 1600, height: 1000), stableUUID: "studio")
        let placements = [
            WorkspacePlacement(bundleID: "cursor", appName: "Cursor", macID: "mini", macName: "Mac mini", monitor: .specific(id: "studio", name: "Studio Display"), position: .rightHalf),
            WorkspacePlacement(bundleID: "safari", appName: "Safari", macID: "book", macName: "MacBook", position: .leftHalf)
        ]
        let routine = WorkspaceRoutine(name: "Work", actions: [.placing(placements)])
        let snapshot = WorkspaceSnapshot(displays: [screen, display], windows: [
            .init(id: "front", bundleID: "cursor", appName: "Cursor", frame: screen.visibleFrame),
            .init(id: "back", bundleID: "cursor", appName: "Cursor", frame: screen.visibleFrame),
            .init(id: "min", bundleID: "cursor", frame: screen.visibleFrame, isMinimized: true),
            .init(id: "foreign", bundleID: "safari", frame: screen.visibleFrame),
            .init(id: "untouched", bundleID: "mail", frame: screen.visibleFrame)
        ])
        let plan = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [], macID: "mini")
        let expected = WorkspaceRect(x: 2200, y: -100, width: 800, height: 1000)
        XCTAssertEqual(plan.operations, [.moveWindow(id: "front", frame: expected), .moveWindow(id: "back", frame: expected)])
        XCTAssertEqual(plan.windowStack, ["back", "front"])
        var focused = snapshot
        focused.frontmostWindowID = "back"
        XCTAssertEqual(WorkspacePlanner.plan(routine: routine, snapshot: focused, protectedBundleIDs: [], macID: "mini").windowStack, ["front", "back"])
        let elsewhere = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [], macID: "other")
        XCTAssertTrue(elsewhere.operations.isEmpty)
    }

    func testPlacementMissingMonitorFallsBackByIDAndNamesMacAndMonitor() {
        let placement = WorkspacePlacement(bundleID: "s", appName: "Safari", macID: "mini", macName: "Mac mini", monitor: .specific(id: "gone", name: "Studio Display"), position: .leftHalf)
        let snapshot = WorkspaceSnapshot(displays: [screen], windows: [.init(id: "w", bundleID: "s", frame: screen.visibleFrame)])
        let plan = WorkspacePlanner.plan(routine: .init(name: "Work", actions: [.placing([placement])]), snapshot: snapshot, protectedBundleIDs: [], macID: "mini")
        XCTAssertEqual(plan.operations, [.moveWindow(id: "w", frame: .init(x: 10, y: 20, width: 500, height: 800))])
        XCTAssertEqual(plan.notes, ["Studio Display isn't connected to Mac mini, so its main screen was used."])
        let generic = WorkspaceMonitorChoice.generic(.largest).resolve(in: snapshot, macName: "Mac mini")
        XCTAssertEqual(generic.display, screen)
    }

    func testPreviewClosedPlacementUsesSameFrameWithoutAWindowOperation() {
        let placement = WorkspacePlacement(bundleID: "c", appName: "Cursor", macID: "mini", macName: "Mac mini", position: .rightThird)
        let snapshot = WorkspaceSnapshot(displays: [screen])
        let routine = WorkspaceRoutine(name: "Work", actions: [.placing([placement])])
        let plan = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [], macID: "mini", preview: true)
        XCTAssertTrue(plan.operations.isEmpty)
        let picture = WorkspacePreviewPicture.make(plan: plan, snapshot: snapshot)
        XCTAssertEqual(picture.tiles.first?.frame, placement.position.frame(on: screen.visibleFrame))
        XCTAssertEqual(picture.tiles.first?.appName, "Cursor (will open)")
        XCTAssertTrue(plan.notes.contains { $0.contains("will open on Mac mini") })
        var closed = routine
        closed.actions[0].openMissingApps = nil
        let legacy = WorkspacePlanner.plan(routine: closed, snapshot: snapshot, protectedBundleIDs: [], macID: "mini", preview: true)
        XCTAssertTrue(legacy.placementTiles.isEmpty)
        XCTAssertEqual(legacy.notes, ["Cursor isn't open, so it won't move. Turn on “Open these apps if they aren't open” to open it."])
    }

    func testPlacementWireCompatibilityBoundsAndReasonableRoutineSize() throws {
        let placement = WorkspacePlacement(bundleID: "com.example.Cursor", appName: "Cursor", macID: "mini", macName: "Mac mini", monitor: .specific(id: "stable-monitor", name: "Studio Display"), position: .rightHalf)
        let action = WorkspaceAction.placing([placement])
        let config = WorkspaceLaunchConfig(routines: [.init(name: "Work", actions: [action])])
        let json = try XCTUnwrap(config.encoded())
        XCTAssertEqual(WorkspaceLaunchConfig.decode(json), config)
        struct OldAction: Decodable { var kind: WorkspaceActionKind; var bundleIDs: [String]; var display: WorkspaceDisplayTarget; var layout: WorkspaceLayout }
        let old = try JSONDecoder().decode(OldAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(old.kind, .arrangeWindows)
        XCTAssertEqual(old.bundleIDs, [placement.bundleID])
        let oldJSON = try JSONEncoder().encode(WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["s"]))
        let decoded = try JSONDecoder().decode(WorkspaceAction.self, from: oldJSON)
        XCTAssertNil(decoded.placements)
        XCTAssertNil(decoded.openMissingApps)
        var invalid = config
        invalid.routines[0].actions[0].placements = [placement, placement]
        XCTAssertFalse(invalid.validate().isEmpty)
        invalid = config
        invalid.routines[0].actions[0].placements![0].macName = String(repeating: "x", count: 121)
        XCTAssertNil(invalid.encoded())
        invalid = config
        invalid.routines[0].actions[0].placements![0].monitor = .specific(id: String(repeating: "x", count: 65), name: "Monitor")
        XCTAssertFalse(invalid.validate().isEmpty)
        invalid = config
        invalid.routines[0].actions[0].bundleIDs = ["wrong"]
        XCTAssertFalse(invalid.validate().isEmpty)
        invalid = config
        invalid.routines[0].actions[0] = .placing((0..<101).map { i in
            var p = placement; p.bundleID += "\(i)"; return p
        })
        XCTAssertFalse(invalid.validate().isEmpty)
        invalid.routines[0].actions[0] = .placing((0..<21).map { i in
            var p = placement; p.macID += "\(i)"; return p
        })
        XCTAssertFalse(invalid.validate().isEmpty)
        XCTAssertTrue(placement.isLocal("hardware-mini", aliases: ["mini"]))
        XCTAssertFalse(placement.isLocal("book"))
        let many = WorkspaceLaunchConfig(routines: (0..<20).map { i in
            WorkspaceRoutine(name: "Work \(i)", actions: [.placing((0..<8).map { j in
                var p = placement; p.bundleID += "\(j)"; p.macID = j % 2 == 0 ? "mini" : "book"; return p
            })])
        })
        XCTAssertLessThan(try XCTUnwrap(many.encoded()).utf8.count, 128 * 1024)
        XCTAssertTrue(WorkspaceWords.summary(config.routines[0], macID: "mini", appName: { $0 }).contains("Cursor on Mac mini, Studio Display, right half"))
    }
}

extension WorkspaceLaunchPlannerTests {
    func testLegacyNumericRememberedLayoutsKeepSameNamedMonitorsSeparate() throws {
        // Old JSON has numeric IDs and no UUID field.
        let old = Data(#"{"macName":"Mini","capturedAt":0,"screens":[{"id":"1","name":"Studio Display","visibleFrame":{"x":0,"y":0,"width":1000,"height":800},"isMain":true},{"id":"2","name":"Studio Display","visibleFrame":{"x":1000,"y":0,"width":1000,"height":800},"isMain":false}],"windows":[{"bundleID":"a","appName":"A","screenID":"1","place":{"x":0,"y":0,"width":1,"height":1}},{"bundleID":"b","appName":"B","screenID":"2","place":{"x":0,"y":0,"width":1,"height":1}}]}"#.utf8)
        let saved = try JSONDecoder().decode(WorkspaceSavedLayout.self, from: old)
        XCTAssertNil(saved.screens[0].stableUUID)
        var live = saved.screens
        live[0].stableUUID = "uuid-left"; live[1].stableUUID = "uuid-right"
        let snapshot = WorkspaceSnapshot(displays: live.reversed(), windows: [
            .init(id: "wa", bundleID: "a", frame: live[1].visibleFrame),
            .init(id: "wb", bundleID: "b", frame: live[0].visibleFrame)
        ])
        let plan = WorkspaceLayoutRestorer.plan(saved, snapshot: snapshot)
        XCTAssertTrue(plan.notes.isEmpty)
        XCTAssertEqual(plan.moves.map { $0.0 }, ["wa", "wb"])
        XCTAssertEqual(plan.moves.map { $0.1 }, live.map(\.visibleFrame))
    }

    func testPlacementUsesUUIDForSameNamedMonitorsEvenWhenNumericIDsChange() throws {
        let left = WorkspaceDisplay(id: "8", name: "Studio Display", visibleFrame: .init(width: 1000, height: 800), isMain: true, stableUUID: "uuid-left")
        let right = WorkspaceDisplay(id: "9", name: "Studio Display", visibleFrame: .init(x: 1000, width: 1000, height: 800), stableUUID: "uuid-right")
        let monitor = WorkspaceMonitorChoice.specific(id: "uuid-right", name: "Studio Display")
        let encoded = try JSONEncoder().encode(monitor)
        let restored = try JSONDecoder().decode(WorkspaceMonitorChoice.self, from: encoded)
        let resolved = restored.resolve(in: WorkspaceSnapshot(displays: [left, right]), macName: "Mini")
        XCTAssertEqual(resolved.display, right)
        XCTAssertNil(resolved.note)
        let missing = restored.resolve(in: WorkspaceSnapshot(displays: [left]), macName: "Mini")
        XCTAssertEqual(missing.display, left)
        XCTAssertEqual(missing.note, "Studio Display isn't connected to Mini, so its main screen was used.")
    }
}


extension WorkspaceLaunchPlannerTests {
    func testWindowStackOverlapRulesAndOffDesktop() {
        let rect = WorkspaceRect(width: 500, height: 500)
        func w(_ id: String, _ x: Double = 0) -> WorkspaceStackWindow { .init(id: id, bundleID: id, frame: .init(x: x, width: 500, height: 500)) }
        XCTAssertEqual(WorkspaceWindowStack.lifts(wanted: ["back", "front"], frontToBack: [w("front"), w("back")], ignoring: []), [])
        XCTAssertEqual(WorkspaceWindowStack.lifts(wanted: ["a"], frontToBack: [w("other", 500), w("a")], ignoring: []), [], "Touching edges do not overlap")
        XCTAssertEqual(WorkspaceWindowStack.lifts(wanted: ["a"], frontToBack: [w("dictator"), w("a")], ignoring: ["dictator"]), [])
        XCTAssertEqual(WorkspaceWindowStack.lifts(wanted: ["missing", "a"], frontToBack: [w("other"), w("a")], ignoring: []), ["a"])
        XCTAssertEqual(WorkspaceWindowStack.lifts(wanted: ["back", "front"], frontToBack: [w("back"), w("front")], ignoring: []), ["front"])
        XCTAssertFalse(WorkspaceWindowStack.shouldRestoreFocus(previousBundleID: "other", dictatorBundleID: "dictator", frontToBack: [w("other"), w("a")], lifted: ["a"]))
        XCTAssertTrue(WorkspaceWindowStack.shouldRestoreFocus(previousBundleID: "other", dictatorBundleID: "dictator", frontToBack: [w("other", 500), w("a")], lifted: ["a"]))
        XCTAssertTrue(WorkspaceWindowStack.shouldRestoreFocus(previousBundleID: "dictator", dictatorBundleID: "dictator", frontToBack: [w("dictator"), w("a")], lifted: ["a"]))
        XCTAssertFalse(WorkspaceWindowStack.shouldRestoreFocus(previousBundleID: nil, dictatorBundleID: "dictator", frontToBack: [], lifted: []))
        XCTAssertTrue(WorkspaceWindowStack.shouldRestoreFocus(previousBundleID: "absent", dictatorBundleID: "dictator", frontToBack: [w("a")], lifted: ["a"]))
        // App A was raised for its back window, carrying a sibling above B.
        let before = [w("b"), w("sibling"), w("a")]
        XCTAssertEqual(WorkspaceWindowStack.lifts(wanted: ["a", "b"], frontToBack: before, ignoring: []), ["a"])
        let overshot = [w("a"), w("sibling"), w("b")]
        XCTAssertEqual(WorkspaceWindowStack.lifts(wanted: ["a", "b"], frontToBack: overshot, ignoring: []), ["b"])
        XCTAssertEqual(WorkspaceWindowStack.lifts(wanted: ["a", "b"], frontToBack: [w("b"), w("a"), w("sibling")], ignoring: []), [])
        XCTAssertTrue(WorkspaceWindowStack.overlaps(rect, rect))
    }

    func testCaptureStackMatchesRoundedBoundsPIDAndFocusedFirstTies() {
        let frame = WorkspaceRect(x: 10.2, y: 20.1, width: 600.2, height: 500.2)
        let cg: [WorkspaceCGWindow] = [
            .init(pid: 7, layer: 1, width: 600, height: 500, x: 10, y: 20),
            .init(pid: 8, layer: 0, width: 600, height: 500, x: 10, y: 20),
            .init(pid: 7, layer: 0, width: 600, height: 500, x: 10, y: 20),
            .init(pid: 7, layer: 0, width: 600, height: 500, x: 10, y: 20)
        ]
        let positions = WorkspaceWindowStack.positions(candidates: [("focused", 7, frame), ("second", 7, frame), ("unmatched", 7, frame), ("other", 8, frame)], frontToBack: cg)
        XCTAssertEqual(positions, ["focused": 2, "second": 3, "other": 1])
    }

    func testRememberRecordsStackDecodesOldJSONAndDrawsBackToFront() throws {
        let snapshot = WorkspaceSnapshot(displays: [screen], windows: [
            .init(id: "front", bundleID: "a", appName: "Front", frame: screen.visibleFrame, stack: 0),
            .init(id: "back", bundleID: "b", appName: "Back", frame: screen.visibleFrame, stack: 3),
            .init(id: "unknown", bundleID: "c", appName: "Unknown", frame: screen.visibleFrame)
        ])
        let layout = WorkspaceSavedLayout.make(snapshot: snapshot, macName: "Mini").layout
        XCTAssertEqual(layout.windows.map(\.stack), [0, 3, nil])
        XCTAssertTrue(layout.isValid)
        XCTAssertEqual(layout.picture.tiles.map(\.appName), ["Unknown", "Back", "Front"])
        let old = Data(#"{"bundleID":"a","appName":"App","screenID":"main","place":{"x":0,"y":0,"width":1,"height":1}}"#.utf8)
        let saved = try JSONDecoder().decode(WorkspaceSavedWindow.self, from: old)
        XCTAssertNil(saved.stack)
        var legacy = layout; legacy.windows = [saved]
        XCTAssertTrue(legacy.isValid)
        legacy.windows[0].stack = Int.min
        XCTAssertTrue(legacy.isValid, "An optional stack position does not add a validation failure")
        legacy.windows[0].stack = nil
        XCTAssertTrue(WorkspaceLayoutRestorer.plan(legacy, snapshot: snapshot).windowStack.isEmpty)
    }

    func testRememberStacksUnmovedWindowsAndOmitsNilStack() {
        let snapshot = WorkspaceSnapshot(displays: [screen], windows: [
            .init(id: "front", bundleID: "a", frame: screen.visibleFrame, stack: 0),
            .init(id: "back", bundleID: "b", frame: screen.visibleFrame, stack: 2),
            .init(id: "unknown", bundleID: "c", frame: screen.visibleFrame)
        ])
        let layout = WorkspaceSavedLayout.make(snapshot: snapshot, macName: "Mini").layout
        let restore = WorkspaceLayoutRestorer.plan(layout, snapshot: snapshot)
        XCTAssertEqual(restore.windowStack, ["back", "front"])
        let plan = WorkspacePlanner.plan(routine: .init(name: "Desk", actions: [.remembering(["mini": layout])]), snapshot: snapshot, protectedBundleIDs: [], macID: "mini")
        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(plan.windowStack, ["back", "front"])
    }
}
