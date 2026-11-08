import Carbon
import XCTest
@testable import Dictator

@MainActor
final class WorkspaceLaunchDesktopTests: XCTestCase {
    private let ctrlOptCmd = WorkspaceHotkey.control | WorkspaceHotkey.option | WorkspaceHotkey.command

    // MARK: Shortcut display

    func testModifierGlyphsUseTheStandardOrder() {
        XCTAssertEqual(WorkspaceHotkeyFormat.modifierGlyphs(ctrlOptCmd | WorkspaceHotkey.shift), "⌃⌥⇧⌘")
        XCTAssertEqual(WorkspaceHotkeyFormat.modifierGlyphs(WorkspaceHotkey.command), "⌘")
    }

    func testKeyNamesForCommonKeyCodesAreNeverGeneric() {
        XCTAssertEqual(WorkspaceHotkeyFormat.staticKeyName(15), "R")
        XCTAssertEqual(WorkspaceHotkeyFormat.staticKeyName(49), "Space")
        XCTAssertEqual(WorkspaceHotkeyFormat.staticKeyName(53), "Esc")
        XCTAssertEqual(WorkspaceHotkeyFormat.staticKeyName(122), "F1")
        XCTAssertEqual(WorkspaceHotkeyFormat.staticKeyName(123), "←")
        XCTAssertEqual(WorkspaceHotkeyFormat.staticKeyName(36), "Return")
        for code in UInt32(0)..<127 { XCTAssertNotEqual(WorkspaceHotkeyFormat.staticKeyName(code), "Key") }
    }

    func testHotkeyDisplayCombinesGlyphsAndKeyName() {
        let key = WorkspaceHotkey(keyCode: 15, modifiers: ctrlOptCmd)
        XCTAssertEqual(WorkspaceHotkeyFormat.display(key, keyName: WorkspaceHotkeyFormat.staticKeyName), "⌃⌥⌘R")
        XCTAssertFalse(WorkspaceHotkeyFormat.display(key).isEmpty)
    }

    // MARK: Conflicts

    private func routine(_ name: String, id: String, key: WorkspaceHotkey?) -> WorkspaceRoutine {
        WorkspaceRoutine(id: id, name: name, hotkey: key, actions: [WorkspaceAction(kind: .centerLastWindow)])
    }

    func testSameShortcutOnAnotherRoutineIsReportedByName() {
        let key = WorkspaceHotkey(keyCode: 15, modifiers: ctrlOptCmd)
        let routines = [routine("Morning", id: "a", key: key), routine("Evening", id: "b", key: nil)]
        XCTAssertEqual(WorkspaceHotkeyConflict.problem(for: key, routineID: "b", routines: routines, triggers: .standard),
                       "“Morning” already uses this shortcut.")
        XCTAssertNil(WorkspaceHotkeyConflict.problem(for: key, routineID: "a", routines: routines, triggers: .standard), "A routine does not conflict with itself")
    }

    func testDictationKeyAndRightOptionAloneAreRefused() {
        let message = "That key starts dictation. Choose a different shortcut."
        XCTAssertEqual(WorkspaceHotkeyConflict.problem(for: WorkspaceHotkey(keyCode: 96, modifiers: ctrlOptCmd), routineID: nil, routines: [], triggers: HotkeyTriggers(dictation: KeyCombo(DictationKey(keyCode: 96)))), message)
        XCTAssertEqual(WorkspaceHotkeyConflict.problem(for: WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.option), routineID: nil, routines: [], triggers: .standard), message)
        XCTAssertEqual(WorkspaceHotkeyConflict.problem(for: WorkspaceHotkey(keyCode: 61, modifiers: WorkspaceHotkey.option), routineID: nil, routines: [], triggers: .standard), message)
        XCTAssertNil(WorkspaceHotkeyConflict.problem(for: WorkspaceHotkey(keyCode: 15, modifiers: ctrlOptCmd), routineID: nil, routines: [], triggers: .standard))
    }

    func testForceQuitModifierOnlyAndWeakShortcutsAreRefused() {
        XCTAssertEqual(WorkspaceHotkeyConflict.problem(for: WorkspaceHotkey(keyCode: 53, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.option), routineID: nil, routines: [], triggers: .standard),
                       WorkspaceHotkeyConflict.forceQuitMessage)
        XCTAssertNotNil(WorkspaceHotkeyConflict.problem(for: WorkspaceHotkey(keyCode: 56, modifiers: ctrlOptCmd), routineID: nil, routines: [], triggers: .standard))
        XCTAssertNotNil(WorkspaceHotkeyConflict.problem(for: WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.shift), routineID: nil, routines: [], triggers: .standard))
    }

    func testCommonMacShortcutsAreRefused() {
        let lock = WorkspaceHotkey(keyCode: 12, modifiers: WorkspaceHotkey.control | WorkspaceHotkey.command)
        XCTAssertTrue(lock.isValid, "Stored routines stay valid; the recorder is what refuses these")
        XCTAssertTrue(WorkspaceHotkeyConflict.problem(for: lock, routineID: nil, routines: [], triggers: .standard)?.contains("locks your screen") == true)
    }

    func testRegistrationFailureIsExplainedPerRoutine() {
        XCTAssertEqual(WorkspaceHotkeyConflict.registrationMessage(status: OSStatus(eventHotKeyExistsErr)), "Another app already uses this shortcut")
        XCTAssertEqual(WorkspaceHotkeyConflict.registrationMessage(status: OSStatus(eventHotKeyInvalidErr)), "macOS does not accept this shortcut")
        XCTAssertEqual(WorkspaceHotkeyConflict.registrationMessage(status: -1), "macOS couldn't turn on this shortcut")
    }

    // MARK: Skipped windows

    func testSkipLinesArePlainAndStable() {
        let lines = WorkspaceSkip.lines([
            WorkspaceSkip(bundleID: "m", appName: "Mail", reason: .slowToRespond),
            WorkspaceSkip(bundleID: "s", appName: "Safari", reason: .otherSpace, count: 2),
            WorkspaceSkip(bundleID: "s", appName: "Safari", reason: .fullScreen, count: 1),
            WorkspaceSkip(bundleID: "n", appName: "Notes", reason: .minimized, count: 3),
            WorkspaceSkip(bundleID: "z", appName: "Zero", reason: .otherSpace, count: 0)])
        XCTAssertEqual(lines, ["Mail was too slow to answer — try again.", "Skipped 3 minimized Notes windows.",
                               "2 Safari windows are on another desktop, so they weren't moved. Switch to that desktop and run this again. Skipped 1 full-screen Safari window."])
        XCTAssertNil(WorkspaceSkip.summary([]))
    }

    func testOtherDesktopWindowsAreInferredFromCountsOnly() {
        let windows = [WorkspaceCGWindow(pid: 7, layer: 0, width: 900, height: 700), WorkspaceCGWindow(pid: 7, layer: 0, width: 900, height: 700),
                       WorkspaceCGWindow(pid: 7, layer: 0, width: 900, height: 700), WorkspaceCGWindow(pid: 7, layer: 25, width: 900, height: 24),
                       WorkspaceCGWindow(pid: 7, layer: 0, width: 10, height: 10), WorkspaceCGWindow(pid: 8, layer: 0, width: 400, height: 300)]
        let counts = WorkspaceSkipDetector.layerZeroCounts(windows)
        XCTAssertEqual(counts[7], 3)
        XCTAssertEqual(counts[8], 1)
        XCTAssertEqual(WorkspaceSkipDetector.otherSpaceCount(allDesktopsCount: 3, accessibilityCount: 1), 2)
        XCTAssertEqual(WorkspaceSkipDetector.otherSpaceCount(allDesktopsCount: 1, accessibilityCount: 2), 0)
    }

    private final class SkippingAdapter: WorkspaceLaunchAdapter {
        var isAccessibilityGranted = true
        func requestPermission() {}
        func capture(lastActivatedAt: [String: Date], excluding: Set<String>, preferredFrontmostBundleID: String?, windowBundleIDs: Set<String>, applicationBundleIDs: Set<String>) throws -> WorkspaceSnapshot {
            WorkspaceSnapshot(displays: [WorkspaceDisplay(id: "d", visibleFrame: WorkspaceRect(x: 0, y: 0, width: 1000, height: 800), isMain: true)],
                              skipped: [WorkspaceSkip(bundleID: "s", appName: "Safari", reason: .otherSpace, count: 2),
                                        WorkspaceSkip(bundleID: "m", appName: "Mail", reason: .slowToRespond)])
        }
        func moveWindow(id: String, to frame: WorkspaceRect) throws {}
        func hideApp(bundleID: String) throws -> Bool { false }
        func unhideApp(bundleID: String) throws {}
        func retainWindows(ids: Set<String>) {}
    }

    private func waitUntilIdle(_ controller: WorkspaceLaunchController) async {
        for _ in 0..<200 where controller.isBusy || controller.status.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testRunningWithoutATargetReportsNoChangesAndTheReason() async throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        for (action, previewReason, reason) in [
            (WorkspaceAction(kind: .centerLastWindow), "Dictator can't find the window you're using to center.", "Dictator couldn't find the window you're using to center."),
            (WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["absent"]), "A selected app is not open on this Mac.", "A selected app is not open on this Mac.")
        ] {
            let routine = WorkspaceRoutine(id: "empty", name: "No target", actions: [action])
            settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [routine]).encoded())
            let adapter = FrameAdapter([])
            let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "test-mac" })
            controller.macName = { "Test Mac" }
            controller.preview(routineID: routine.id)
            await waitUntilIdle(controller)
            XCTAssertTrue(controller.previewLines.contains(previewReason))
            controller.run(routineID: routine.id)
            await waitUntilIdle(controller)
            XCTAssertEqual(controller.status, "Test Mac: no changes were made.\n\(reason)")
            XCTAssertTrue(adapter.windows.isEmpty)
            XCTAssertFalse(controller.canRestore)
        }
    }

    func testPreviewAndResultReportSkippedWindowsFromAMockedAdapter() async throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let routine = WorkspaceRoutine(id: "r", name: "Desk", actions: [WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["s"])])
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [routine]).encoded())
        let controller = WorkspaceLaunchController(adapter: SkippingAdapter(), settings: settings, macID: { "test-mac" })
        controller.preview(routineID: "r")
        await waitUntilIdle(controller)
        XCTAssertTrue(controller.previewLines.contains("2 Safari windows are on another desktop, so they won't move. Switch to that desktop and run this again."))
        XCTAssertFalse(controller.previewLines.contains("Mail is too slow to answer — try again."))
        controller.run(routineID: "r")
        await waitUntilIdle(controller)
        XCTAssertTrue(controller.status.contains("2 Safari windows are on another desktop, so they weren't moved. Switch to that desktop and run this again."), controller.status)
        XCTAssertFalse(controller.status.contains("Mail was too slow to answer — try again."), controller.status)
        XCTAssertTrue(controller.status.contains("no changes were made."), controller.status)
        XCTAssertEqual(controller.status.components(separatedBy: "2 Safari windows are on another desktop, so they weren't moved. Switch to that desktop and run this again.").count, 2)
    }

    // MARK: Screens

    private func screen(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, main: Bool = false, builtIn: Bool? = nil) -> WorkspaceDisplay {
        WorkspaceDisplay(id: id, name: id, visibleFrame: WorkspaceRect(x: x, y: y, width: w, height: h), isMain: main, isBuiltIn: builtIn)
    }

    private func pick(_ choice: WorkspaceDisplayChoice, _ displays: [WorkspaceDisplay], pointer: WorkspacePoint? = nil) -> (String?, String?) {
        let result = WorkspaceDisplayResolver.resolve(choice, displays: displays, pointer: pointer)
        return (result.display?.id, result.note)
    }

    func testOneScreenUsesItAndExplainsWhyForLeftAndRight() {
        let only = [screen("laptop", 0, 25, 1440, 875, main: true, builtIn: true)]
        XCTAssertEqual(pick(.left, only).0, "laptop")
        XCTAssertEqual(pick(.left, only).1, "This Mac has one screen, so ‘Left screen’ used it.")
        XCTAssertEqual(pick(.right, only).1, "This Mac has one screen, so ‘Right screen’ used it.")
        XCTAssertNil(pick(.main, only).1)
        XCTAssertNil(pick(.builtIn, only).1)
    }

    func testTwoSideBySideScreensPickByHorizontalCentre() {
        let desk = [screen("big", 1440, 0, 2560, 1400), screen("laptop", 0, 25, 1440, 875, main: true)]
        XCTAssertEqual(pick(.left, desk).0, "laptop")
        XCTAssertEqual(pick(.right, desk).0, "big")
        XCTAssertNil(pick(.right, desk).1)
        XCTAssertEqual(pick(.top, desk).0, "laptop", "Side by side has no top; the main screen is used")
        XCTAssertNotNil(pick(.top, desk).1)
    }

    func testStackedScreensFallBackToMainForLeftAndRightButTopBottomWork() {
        let stacked = [screen("upper", 0, -1080, 1920, 1055), screen("lower", 0, 25, 1440, 875, main: true)]
        XCTAssertEqual(pick(.left, stacked).0, "lower")
        XCTAssertEqual(pick(.right, stacked).1, "These screens are stacked, so ‘Right screen’ used the main screen.")
        XCTAssertEqual(pick(.top, stacked).0, "upper")
        XCTAssertEqual(pick(.bottom, stacked).0, "lower")
        XCTAssertNil(pick(.top, stacked).1)
    }

    func testThreeScreensPickTheOutsideOnes() {
        let three = [screen("mid", 0, 0, 1440, 900, main: true), screen("far-left", -1920, 0, 1920, 1080), screen("far-right", 1440, 0, 1920, 1080)]
        XCTAssertEqual(pick(.left, three).0, "far-left")
        XCTAssertEqual(pick(.right, three).0, "far-right")
        XCTAssertEqual(pick(.main, three).0, "mid")
        XCTAssertEqual(pick(.largest, three).0, "far-left", "Equal sizes: first by id, deterministic")
        XCTAssertEqual(pick(.largest, [screen("a", 0, 0, 100, 100, main: true), screen("b", 100, 0, 200, 100)]).0, "b")
    }

    func testBuiltInAndPointerChoices() {
        let desk = [screen("big", 1440, 0, 2560, 1400), screen("laptop", 0, 25, 1440, 875, main: true, builtIn: true)]
        XCTAssertEqual(pick(.builtIn, desk).0, "laptop")
        XCTAssertEqual(pick(.underPointer, desk, pointer: WorkspacePoint(x: 2000, y: 500)).0, "big")
        XCTAssertEqual(pick(.underPointer, desk, pointer: WorkspacePoint(x: 100, y: 5)).0, "laptop", "Pointer in the menu bar is nearest the laptop")
        let unknown = [screen("a", 0, 0, 100, 100, main: true), screen("b", 100, 0, 100, 100)]
        XCTAssertEqual(pick(.builtIn, unknown).0, "a")
        XCTAssertEqual(pick(.builtIn, unknown).1, "No built-in screen was found, so ‘Built-in screen’ used the main screen.")
        XCTAssertNotNil(pick(.underPointer, unknown, pointer: nil).1)
        XCTAssertNil(pick(.main, []).0)
    }

    func testPerMacOverrideBeatsTheRoutineScreenOnlyOnThatMac() {
        let desk = [screen("big", 1440, 0, 2560, 1400), screen("laptop", 0, 25, 1440, 875, main: true, builtIn: true)]
        let action = WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["app"], display: .right, displayOverrides: ["mac-laptop": .builtIn])
        func screenID(_ mac: String?) -> String? { WorkspaceDisplayResolver.resolve(action: action, macID: mac, displays: desk, pointer: nil).display?.id }
        XCTAssertEqual(screenID("mac-laptop"), "laptop")
        XCTAssertEqual(screenID("mac-desk"), "big")
        XCTAssertEqual(screenID(nil), "big")
    }

    func testPlannerAppliesOverrideAndNotesSingleScreenOnce() {
        let only = screen("laptop", 0, 0, 1000, 800, main: true)
        let action = WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["app"], display: .left)
        let center = WorkspaceAction(kind: .centerLastWindow, display: .left)
        let windows = [WorkspaceWindow(id: "w", bundleID: "app", frame: WorkspaceRect(x: 5, y: 5, width: 100, height: 100))]
        let snapshot = WorkspaceSnapshot(displays: [only], windows: windows, frontmostWindowID: "w")
        let plan = WorkspacePlanner.plan(routine: WorkspaceRoutine(name: "R", actions: [action, center]), snapshot: snapshot, protectedBundleIDs: [], macID: "m")
        XCTAssertEqual(plan.operations.count, 2)
        XCTAssertEqual(plan.notes.filter { $0.contains("one screen") }.count, 1)
        let overridden = WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["app"], display: .left, displayOverrides: ["m": .main])
        let quiet = WorkspacePlanner.plan(routine: WorkspaceRoutine(name: "R", actions: [overridden]), snapshot: snapshot, protectedBundleIDs: [], macID: "m")
        XCTAssertTrue(quiet.notes.isEmpty)
    }

    func testPlanIncludesSkippedWindowLinesAfterSnapshotNotes() {
        let snapshot = WorkspaceSnapshot(displays: [screen("d", 0, 0, 100, 100, main: true)], notes: ["Existing note."],
                                         skipped: [WorkspaceSkip(bundleID: "s", appName: "Safari", reason: .otherSpace)])
        let plan = WorkspacePlanner.plan(routine: WorkspaceRoutine(name: "R", actions: [WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["s"])]), snapshot: snapshot, protectedBundleIDs: [])
        XCTAssertEqual(Array(plan.notes.prefix(2)), ["Existing note.", "Safari is on another desktop, so it wasn't moved. Switch to that desktop and run this again."])
    }

    // MARK: Compatibility

    func testRoutinesSavedByEarlierBuildsStillDecode() throws {
        let old = #"{"version":1,"routines":[{"id":"r","name":"Old","enabled":true,"actions":[{"id":"a","kind":"arrangeWindows","bundleIDs":["x"],"display":"left","layout":"halves","idleMinutes":180}]}]}"#
        let config = try XCTUnwrap(WorkspaceLaunchConfig.decode(old))
        XCTAssertNil(config.routines[0].actions[0].displayOverrides)
        XCTAssertEqual(config.routines[0].actions[0].display, .left)
        let again = try XCTUnwrap(config.encoded())
        XCTAssertFalse(again.contains("displayOverrides"), "Unchanged routines stay byte-compatible with earlier builds")
    }

    func testRoutinesWithScreenChoicesRoundTripAndOnlyAddAnOptionalKey() throws {
        let action = WorkspaceAction(id: "a", kind: .arrangeWindows, bundleIDs: ["x"], display: .right, displayOverrides: ["mac-1": .builtIn, "mac-2": .underPointer])
        let config = WorkspaceLaunchConfig(routines: [WorkspaceRoutine(id: "r", name: "New", actions: [action])])
        let json = try XCTUnwrap(config.encoded())
        XCTAssertEqual(WorkspaceLaunchConfig.decode(json), config)
        // An earlier build reads the same JSON with only the fields it knows.
        struct EarlierAction: Decodable { var id: String; var kind: WorkspaceActionKind; var bundleIDs: [String]; var display: WorkspaceDisplayTarget; var layout: WorkspaceLayout; var idleMinutes: Int }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let actions = try XCTUnwrap((object["routines"] as? [[String: Any]])?.first?["actions"])
        let decoded = try JSONDecoder().decode([EarlierAction].self, from: JSONSerialization.data(withJSONObject: actions))
        XCTAssertEqual(decoded.first?.display, .right)
    }

    func testSnapshotsWithoutTheNewFieldsDecode() throws {
        let old = #"{"capturedAt":0,"displays":[{"id":"d","name":"D","visibleFrame":{"x":0,"y":0,"width":10,"height":10},"isMain":true}],"windows":[],"applications":[],"notes":[]}"#
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(old.utf8))
        XCTAssertNil(snapshot.skipped)
        XCTAssertNil(snapshot.pointer)
        XCTAssertNil(snapshot.displays[0].isBuiltIn)
        let full = WorkspaceSnapshot(displays: [screen("d", 0, 0, 10, 10, main: true, builtIn: true)], skipped: [WorkspaceSkip(bundleID: "b", reason: .fullScreen)], pointer: WorkspacePoint(x: 1, y: 2))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(full)), full)
    }

    func testMacIdentityIsStableAndHidesTheHardwareId() {
        XCTAssertEqual(WorkspaceMacIdentity.key(forHardware: "ABC"), WorkspaceMacIdentity.key(forHardware: "ABC"))
        XCTAssertNotEqual(WorkspaceMacIdentity.key(forHardware: "ABC"), WorkspaceMacIdentity.key(forHardware: "ABD"))
        XCTAssertFalse(WorkspaceMacIdentity.key(forHardware: "ABC").contains("ABC"))
        XCTAssertEqual(WorkspaceMacIdentity.current, WorkspaceMacIdentity.current)
    }

    // MARK: Shortcut recording and window reads

    private final class FakeRegistry: WorkspaceHotkeyRegistering {
        var onTrigger: ((String) -> Void)?
        var onCommandTrigger: ((String) -> Void)?
        var registered: [[String]] = []
        var clears = 0
        func register(_ definitions: [WorkspaceRoutine], commands: [VoiceCommand]) -> WorkspaceHotkeyRegistry.Registration {
            registered.append(definitions.filter { $0.enabled && $0.hotkey != nil }.map(\.id))
            return WorkspaceHotkeyRegistry.Registration()
        }
        func clear() { clears += 1 }
    }

    func testRecordingTurnsOffEveryRoutineShortcutAndRestoresThemOnExit() async throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved; HotkeyService.isRecordingWorkspaceShortcut = false }
        let key = WorkspaceHotkey(keyCode: 15, modifiers: ctrlOptCmd)
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [routine("Morning", id: "a", key: key)]).encoded())
        let registry = FakeRegistry()
        let controller = WorkspaceLaunchController(adapter: SkippingAdapter(), settings: settings, macID: { "m" }, hotkeys: registry)
        controller.start()
        XCTAssertEqual(registry.registered.last, ["a"])
        controller.beginShortcutRecording()
        XCTAssertTrue(controller.isRecordingShortcut)
        XCTAssertTrue(HotkeyService.isRecordingWorkspaceShortcut, "Dictation starts are suppressed while recording")
        XCTAssertEqual(registry.clears, 1)
        let count = registry.registered.count
        // A settings change mid-recording must not bring the shortcuts back.
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [routine("Morning", id: "a", key: key), routine("Late", id: "b", key: WorkspaceHotkey(keyCode: 12, modifiers: ctrlOptCmd))]).encoded())
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(registry.registered.count, count)
        controller.beginShortcutRecording()
        XCTAssertEqual(registry.clears, 1, "Starting twice is harmless")
        controller.endShortcutRecording()
        XCTAssertFalse(HotkeyService.isRecordingWorkspaceShortcut)
        XCTAssertEqual(registry.registered.last, ["a", "b"])
        let after = registry.registered.count
        controller.endShortcutRecording()
        XCTAssertEqual(registry.registered.count, after, "Ending twice is harmless")
    }

    func testALoneDictationModifierPressIsRefusedButOtherModifiersAreNot() {
        XCTAssertEqual(WorkspaceHotkeyConflict.modifierOnlyProblem(keyCode: 61, triggers: .standard), WorkspaceHotkeyConflict.dictationMessage)
        XCTAssertNil(WorkspaceHotkeyConflict.modifierOnlyProblem(keyCode: 58, triggers: .standard), "Left Option is fine")
        XCTAssertNil(WorkspaceHotkeyConflict.modifierOnlyProblem(keyCode: 15, triggers: .standard))
        XCTAssertTrue(WorkspaceHotkeyConflict.dictationModifierHeld(triggers: .standard, deviceFlags: 0x40 | 0x100))
        XCTAssertFalse(WorkspaceHotkeyConflict.dictationModifierHeld(triggers: .standard, deviceFlags: 0x20))
        XCTAssertFalse(WorkspaceHotkeyConflict.dictationModifierHeld(triggers: HotkeyTriggers(dictation: KeyCombo(DictationKey(keyCode: 96))), deviceFlags: 0x40))
    }

    func testOnlyOrdinaryAccessibilityWindowsAreComparedWithTheWindowServer() {
        let standard = WorkspaceAXWindowFacts(role: "AXWindow", subrole: "AXStandardWindow", width: 800, height: 600)
        let dialog = WorkspaceAXWindowFacts(role: "AXWindow", subrole: "AXDialog", width: 400, height: 200)
        let desktop = WorkspaceAXWindowFacts(role: "AXScrollArea", subrole: nil, width: 1440, height: 900)
        let palette = WorkspaceAXWindowFacts(role: "AXWindow", subrole: "AXFloatingWindow", width: 300, height: 300)
        let tiny = WorkspaceAXWindowFacts(role: "AXWindow", subrole: "AXStandardWindow", width: 20, height: 20)
        XCTAssertEqual(WorkspaceSkipDetector.ordinaryAXCount([standard, dialog, desktop, palette, tiny]), 2)
        // Finder: one real window here, a desktop element, and two real windows elsewhere.
        let ax = WorkspaceSkipDetector.ordinaryAXCount([standard, desktop])
        XCTAssertEqual(WorkspaceSkipDetector.otherSpaceCount(allDesktopsCount: 3, accessibilityCount: ax), 2)
        XCTAssertEqual(WorkspaceSkipDetector.otherSpaceCount(allDesktopsCount: 3, accessibilityCount: 2), 1, "Counting the desktop element would hide one")
    }

    func testSlowAppIsReportedOnceHoweverManyReadsTimeOut() {
        var collector = WorkspaceSkipCollector()
        for _ in 0..<5 { collector.add(bundleID: "mail", appName: "Mail", reason: .slowToRespond) }
        collector.add(bundleID: "safari", appName: "Safari", reason: .otherSpace, count: 1)
        collector.add(bundleID: "safari", appName: "Safari", reason: .otherSpace, count: 2)
        collector.add(bundleID: "safari", appName: "Safari", reason: .fullScreen, count: 0)
        XCTAssertEqual(collector.skips, [WorkspaceSkip(bundleID: "mail", appName: "Mail", reason: .slowToRespond, count: 1),
                                         WorkspaceSkip(bundleID: "safari", appName: "Safari", reason: .otherSpace, count: 3)])
        XCTAssertEqual(WorkspaceSkip.lines(collector.skips), ["Mail was too slow to answer — try again.", "3 Safari windows are on another desktop, so they weren't moved. Switch to that desktop and run this again."])
    }

    // MARK: Dictation suppression and fact-gathering limits

    func testDictationStaysSuppressedUntilTheDictationKeyIsReleased() {
        defer { HotkeyService.isRecordingWorkspaceShortcut = false }
        let service = HotkeyService()
        service.dictationKeyIsDown = { true }
        var starts = 0, stops = 0
        service.onStart = { starts += 1 }
        service.onStop = { _ in stops += 1 }
        HotkeyService.isRecordingWorkspaceShortcut = true
        service.applyModifierState(rightHeld: true, shiftHeld: false)       // Right ⌥ down while recording
        XCTAssertEqual(starts, 0)
        HotkeyService.isRecordingWorkspaceShortcut = false                    // R pressed: recording ends
        service.applyModifierState(rightHeld: true, shiftHeld: false)       // ⌘ released first; Right ⌥ still held
        XCTAssertEqual(starts, 0, "Still held from the recording")
        XCTAssertTrue(service.waitingForDictationKeyRelease)
        service.applyModifierState(rightHeld: false, shiftHeld: false)      // Right ⌥ released
        XCTAssertFalse(service.waitingForDictationKeyRelease)
        XCTAssertEqual(stops, 0, "Nothing was started, so nothing stops")
        service.applyModifierState(rightHeld: true, shiftHeld: false)       // a fresh press dictates again
        XCTAssertEqual(starts, 1)
        service.applyModifierState(rightHeld: false, shiftHeld: false)
        XCTAssertEqual(stops, 1)
    }

    func testGatheringFactsStopsOnTimeoutDeadlineOrTooManyElements() {
        let ok = WorkspaceAXWindowFacts(role: "AXWindow", subrole: "AXStandardWindow", width: 800, height: 600)
        var reads = 0
        let timeout = WorkspaceSkipDetector.gatherFacts(count: 10, maxElements: 60, deadlineReached: { false }) { index in
            reads += 1
            return (ok, index == 2)
        }
        XCTAssertFalse(timeout.complete)
        XCTAssertEqual(reads, 3, "Stops reading at the first timeout")
        var now = 0
        let late = WorkspaceSkipDetector.gatherFacts(count: 10, maxElements: 60, deadlineReached: { now += 1; return now > 4 }) { _ in (ok, false) }
        XCTAssertFalse(late.complete)
        XCTAssertEqual(late.facts.count, 4)
        var untouched = 0
        let many = WorkspaceSkipDetector.gatherFacts(count: 200, maxElements: 60, deadlineReached: { false }) { _ in untouched += 1; return (ok, false) }
        XCTAssertFalse(many.complete)
        XCTAssertEqual(untouched, 0)
        XCTAssertTrue(WorkspaceSkipDetector.gatherFacts(count: 3, maxElements: 60, deadlineReached: { false }) { _ in (ok, false) }.complete)
    }

    func testIncompleteFactsAndALateTimeoutBothReportOneSlowEntryAndNoOtherDesktopClaim() {
        var collector = WorkspaceSkipCollector()
        let ok = WorkspaceAXWindowFacts(role: "AXWindow", subrole: "AXStandardWindow", width: 800, height: 600)
        // Initial reads succeed, then the app stops answering partway (as the adapter does for any later query).
        let gathered = WorkspaceSkipDetector.gatherFacts(count: 5, maxElements: 60, deadlineReached: { false }) { index in (ok, index == 3) }
        if gathered.complete {
            collector.add(bundleID: "mail", appName: "Mail", reason: .otherSpace,
                          count: WorkspaceSkipDetector.otherSpaceCount(allDesktopsCount: 5, accessibilityCount: WorkspaceSkipDetector.ordinaryAXCount(gathered.facts)))
        } else {
            collector.add(bundleID: "mail", appName: "Mail", reason: .slowToRespond)
        }
        collector.add(bundleID: "mail", appName: "Mail", reason: .slowToRespond)  // a later settable/minimized/focused read also times out
        XCTAssertEqual(collector.skips, [WorkspaceSkip(bundleID: "mail", appName: "Mail", reason: .slowToRespond, count: 1)])
    }

    // MARK: Dropped releases and unreadable windows

    func testADroppedReleaseDoesNotBlockTheNextPress() {
        defer { HotkeyService.isRecordingWorkspaceShortcut = false }
        let service = HotkeyService()
        var down = true
        service.dictationKeyIsDown = { down }
        var starts = 0, stops = 0
        service.onStart = { starts += 1 }
        service.onStop = { _ in stops += 1 }
        HotkeyService.isRecordingWorkspaceShortcut = true
        service.applyModifierState(rightHeld: true, shiftHeld: false)
        HotkeyService.isRecordingWorkspaceShortcut = false
        XCTAssertTrue(service.waitingForDictationKeyRelease)
        down = false                                  // released, but the release went to another Mac
        service.clearLatchIfKeyIsUp()                  // the short timer notices
        XCTAssertFalse(service.waitingForDictationKeyRelease)
        XCTAssertEqual(stops, 0, "Clearing never stops a session")
        down = true
        service.applyModifierState(rightHeld: true, shiftHeld: false)
        XCTAssertEqual(starts, 1)
    }

    func testNoSubroleIsOrdinaryButMissingRoleOrSizeIsReportedAsUnreadable() {
        let ok = WorkspaceAXWindowFacts(role: "AXWindow", subrole: "AXStandardWindow", width: 800, height: 600)
        let noSubrole = WorkspaceAXWindowFacts(role: "AXWindow", subrole: nil, width: 800, height: 600)
        let dialog = WorkspaceAXWindowFacts(role: "AXWindow", subrole: "AXDialog", width: 400, height: 200)
        let noSize = WorkspaceAXWindowFacts(role: "AXWindow", subrole: "AXStandardWindow", width: 0, height: 0)
        let noRole = WorkspaceAXWindowFacts(role: nil, subrole: "AXStandardWindow", width: 800, height: 600)
        // The same function decides counting and arranging.
        XCTAssertTrue(WorkspaceSkipDetector.isOrdinaryAXWindow(noSubrole))
        XCTAssertTrue(WorkspaceSkipDetector.isArrangeEligible(noSubrole))
        XCTAssertTrue(WorkspaceSkipDetector.isOrdinaryAXWindow(dialog))
        XCTAssertFalse(WorkspaceSkipDetector.isArrangeEligible(dialog), "Dialogs are counted but not arranged")
        XCTAssertFalse(WorkspaceSkipDetector.isResolved(noSize))
        XCTAssertFalse(WorkspaceSkipDetector.isResolved(noRole))
        let clean = WorkspaceSkipDetector.gatherFacts(count: 2, maxElements: 60, deadlineReached: { false }) { index in (index == 0 ? ok : noSubrole, false) }
        XCTAssertEqual(clean.outcome, .complete)
        XCTAssertEqual(WorkspaceSkipDetector.ordinaryAXCount(clean.facts), 2)
        let result = WorkspaceSkipDetector.gatherFacts(count: 3, maxElements: 60, deadlineReached: { false }) { index in ([ok, noSize, noRole][index], false) }
        XCTAssertEqual(result.outcome, .unresolved)
        XCTAssertEqual(result.unresolvedCount, 2)
        XCTAssertEqual(WorkspaceSkipDetector.gatherFacts(count: 1, maxElements: 60, deadlineReached: { false }) { _ in (ok, true) }.outcome, .slow)
        XCTAssertEqual(WorkspaceSkip.lines([WorkspaceSkip(bundleID: "f", appName: "Foo", reason: .unreadable, count: 1)]),
                       ["Skipped 1 Foo window Dictator couldn't read."])
        XCTAssertEqual(WorkspaceSkip.lines([WorkspaceSkip(bundleID: "f", appName: "Foo", reason: .unreadable, count: 2)]),
                       ["Skipped 2 Foo windows Dictator couldn't read."])
    }

    // MARK: Key latch and consistent facts

    func testAnOrdinaryEventAfterADroppedReleaseClearsTheLatchBeforeTheNextPress() {
        defer { HotkeyService.isRecordingWorkspaceShortcut = false }
        let service = HotkeyService()
        var down = true
        service.dictationKeyIsDown = { down }
        var starts = 0
        service.onStart = { starts += 1 }
        HotkeyService.isRecordingWorkspaceShortcut = true
        service.applyModifierState(rightHeld: true, shiftHeld: false)
        HotkeyService.isRecordingWorkspaceShortcut = false
        XCTAssertTrue(service.waitingForDictationKeyRelease)
        down = false                                   // release dropped by Universal Control
        service.clearLatchIfKeyIsUp()                  // what handleEvent does first for a click or keystroke
        XCTAssertFalse(service.waitingForDictationKeyRelease)
        down = true                                    // pressed again well inside the 0.2 s timer
        service.applyModifierState(rightHeld: true, shiftHeld: false)
        XCTAssertEqual(starts, 1)
    }

    func testADownEdgeWhileLatchedIsAFreshPress() {
        defer { HotkeyService.isRecordingWorkspaceShortcut = false }
        let service = HotkeyService()
        var down = true
        service.dictationKeyIsDown = { down }
        var starts = 0
        service.onStart = { starts += 1 }
        HotkeyService.isRecordingWorkspaceShortcut = true
        service.applyModifierState(rightHeld: true, shiftHeld: false)
        down = false
        service.clearLatchIfKeyIsUp()                  // sampled up while still recording: latch stays
        XCTAssertTrue(service.waitingForDictationKeyRelease)
        HotkeyService.isRecordingWorkspaceShortcut = false
        down = true                                    // up to down: the earlier release must have happened
        service.applyModifierState(rightHeld: true, shiftHeld: false)
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(service.waitingForDictationKeyRelease)
    }

    func testFactsAreReadOnceAndReportingAndArrangingAgree() {
        let ok = WorkspaceAXWindowFacts(role: "AXWindow", subrole: "AXStandardWindow", width: 800, height: 600)
        let noSubrole = WorkspaceAXWindowFacts(role: "AXWindow", subrole: nil, width: 800, height: 600)
        let noSize = WorkspaceAXWindowFacts(role: "AXWindow", subrole: nil, width: 0, height: 0)
        let dialog = WorkspaceAXWindowFacts(role: "AXWindow", subrole: "AXDialog", width: 400, height: 200)
        var reads = 0
        let all = [ok, noSize, noSubrole, dialog]
        let result = WorkspaceSkipDetector.gatherFacts(count: 4, maxElements: 60, deadlineReached: { false }) { index in reads += 1; return (all[index], false) }
        XCTAssertEqual(reads, 4, "One read per element")
        XCTAssertEqual(result.records, all)
        XCTAssertEqual(result.unresolvedCount, 1)
        let arranged = result.records.indices.filter { WorkspaceSkipDetector.isArrangeEligible(result.records[$0]) }
        XCTAssertEqual(arranged, [0, 2])
        for record in result.records where !WorkspaceSkipDetector.isResolved(record) {
            XCTAssertFalse(WorkspaceSkipDetector.isArrangeEligible(record), "Reported as unreadable, so never arranged")
        }
        let partial = WorkspaceSkipDetector.gatherFacts(count: 4, maxElements: 60, deadlineReached: { false }) { index in (all[index], index == 2) }
        XCTAssertEqual(partial.records.count, 2, "Elements after a timeout have no record, so they are not arranged")
        XCTAssertEqual(partial.outcome, .slow)
    }

    // MARK: Remembered layouts on several Macs

    private final class DeskAdapter: WorkspaceLaunchAdapter {
        var isAccessibilityGranted: Bool { true }
        var moves: [String: WorkspaceRect] = [:]
        func requestPermission() {}
        func capture(lastActivatedAt: [String: Date], excluding: Set<String>, preferredFrontmostBundleID: String?, windowBundleIDs: Set<String>, applicationBundleIDs: Set<String>) throws -> WorkspaceSnapshot {
            WorkspaceSnapshot(displays: [WorkspaceDisplay(id: "d", visibleFrame: WorkspaceRect(x: 0, y: 0, width: 1000, height: 800), isMain: true)],
                              windows: [WorkspaceWindow(id: "w", bundleID: "s", appName: "Safari", frame: WorkspaceRect(x: 0, y: 0, width: 500, height: 800), displayID: "d")])
        }
        func moveWindow(id: String, to frame: WorkspaceRect) throws { moves[id] = frame }
        func hideApp(bundleID: String) throws -> Bool { false }
        func unhideApp(bundleID: String) throws {}
        func retainWindows(ids: Set<String>) {}
    }

    private final class FakeFleet: WorkspaceFleet {
        var otherMacNames = ["MacBook Pro"]
        var layouts: [String: WorkspaceSavedLayout] = [:]
        var busy: [String] = []
        var runs: [(String, Bool)] = []
        func rememberEverywhere() async throws -> (layouts: [String: WorkspaceSavedLayout], unanswered: [String], busy: [String]) { (layouts, ["iMac"], busy) }
        var operationIDs: [String?] = []
        var onRun: (() async -> Void)?
        var failure: String?
        func runElsewhere(routineID: String, undo: Bool, operationID: String?) async throws -> [WorkspaceRunReport] {
            runs.append((routineID, undo))
            operationIDs.append(operationID)
            await onRun?()
            return [WorkspaceRunReport(macName: "MacBook Pro", summary: failure ?? (undo ? "Windows are back where they were." : "done, 1 change."), failure: failure)]
        }
    }

    func testRememberOnAllMacsThenRunAndUndoReachTheOtherMac() async throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = DeskAdapter(), fleet = FakeFleet()
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "mini" })
        controller.macName = { "Mac mini" }
        controller.fleet = fleet
        let book = WorkspaceSavedLayout(macName: "MacBook Pro", capturedAt: Date(), screens: [],
                                        windows: [WorkspaceSavedWindow(bundleID: "m", appName: "Mail", screenID: "x", place: WorkspaceRect(x: 0, y: 0, width: 1, height: 1))])
        fleet.layouts = ["book": book]   // the main Mac's answer left this Mac out, so it remembers itself

        let remembered = await controller.rememberLayouts(everywhere: true)
        let layouts = try XCTUnwrap(remembered)
        XCTAssertEqual(Set(layouts.keys), ["book", "mini"])
        XCTAssertEqual(layouts["mini"]?.windows.first?.place, WorkspaceRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertTrue(controller.status.contains("1 on Mac mini"), controller.status)
        XCTAssertTrue(controller.status.contains("iMac didn't answer"), controller.status)

        var routine = WorkspaceRoutine.remembering(layouts, existing: [])
        routine.id = "desk"
        XCTAssertTrue(controller.saveRoutine(routine))
        XCTAssertEqual(controller.otherMacs(in: routine), ["MacBook Pro"])

        controller.run(routineID: "desk")
        for _ in 0..<200 where controller.isBusy || fleet.runs.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(fleet.runs.first?.0, "desk")
        XCTAssertEqual(fleet.runs.first?.1, false)
        XCTAssertTrue(controller.status.contains("MacBook Pro: done, 1 change."), controller.status)
        XCTAssertTrue(controller.canRestore)

        controller.restoreLastReset()
        for _ in 0..<200 where controller.isBusy || fleet.runs.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(fleet.runs.last?.1, true)
        XCTAssertTrue(controller.status.contains("MacBook Pro: Windows are back where they were."), controller.status)
        // The Undo names the very run it belongs to.
        let runID = try XCTUnwrap(fleet.operationIDs.first ?? nil)
        XCTAssertEqual(fleet.operationIDs.last ?? nil, runID)
    }

    func testARunAskedFromAnotherMacSkipsRoutinesWithNothingRememberedHere() async throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let book = WorkspaceSavedLayout(macName: "MacBook Pro", capturedAt: Date(), screens: [],
                                        windows: [WorkspaceSavedWindow(bundleID: "m", appName: "Mail", screenID: "x", place: WorkspaceRect(x: 0, y: 0, width: 1, height: 1))])
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [WorkspaceRoutine(id: "desk", name: "Desk", actions: [.remembering(["book": book])])]).encoded())
        let controller = WorkspaceLaunchController(adapter: DeskAdapter(), settings: settings, macID: { "mini" })
        let skipped = await controller.answerRunRequest(routineID: "desk", undo: false, from: "MacBook Pro")
        XCTAssertEqual(skipped, "")
        let missing = await controller.answerRunRequest(routineID: "other", undo: false, from: "MacBook Pro")
        XCTAssertTrue(missing.contains("doesn't have this routine yet"))
        let capture = await controller.answerCaptureRequest()
        XCTAssertEqual(capture.macID, "mini")
        XCTAssertEqual(capture.layout?.windows.count, 1)
    }

    // MARK: Undo belongs to one run; idle time; small windows

    /// Windows whose frames really change, and that refuse to be narrower than `minimumWidth`
    /// (after taking the new position, as some apps do).
    private final class FrameAdapter: WorkspaceLaunchAdapter {
        var isAccessibilityGranted: Bool { true }
        var display = WorkspaceDisplay(id: "d", visibleFrame: WorkspaceRect(x: 0, y: 0, width: 1000, height: 800), isMain: true)
        var windows: [WorkspaceWindow]
        var minimumWidth: [String: Double] = [:]
        var applications: [WorkspaceApplication] = []
        init(_ windows: [WorkspaceWindow]) { self.windows = windows }
        func requestPermission() {}
        func capture(lastActivatedAt: [String: Date], excluding: Set<String>, preferredFrontmostBundleID: String?, windowBundleIDs: Set<String>, applicationBundleIDs: Set<String>) throws -> WorkspaceSnapshot {
            WorkspaceSnapshot(displays: [display], windows: windows, applications: applications)
        }
        func moveWindow(id: String, to frame: WorkspaceRect) throws {
            guard let index = windows.firstIndex(where: { $0.id == id }) else { throw NativeResetError.windowNotFound(id) }
            if let minimum = minimumWidth[id], frame.width < minimum {
                windows[index].frame.x = frame.x
                windows[index].frame.y = frame.y
                throw NativeResetError.frameMismatch("synthetic minimum width")
            }
            windows[index].frame = frame
        }
        func hideApp(bundleID: String) throws -> Bool { false }
        func unhideApp(bundleID: String) throws {}
        func retainWindows(ids: Set<String>) {}
        func frame(_ id: String) -> WorkspaceRect? { windows.first { $0.id == id }?.frame }
    }

    func testAnUndoFromAnotherMacNeverReversesANewerRunHere() async throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let remembered = WorkspaceRect(x: 100, y: 100, width: 400, height: 300)
        let elsewhere = WorkspaceRect(x: 550, y: 50, width: 300, height: 300)
        let adapter = FrameAdapter([WorkspaceWindow(id: "w", bundleID: "s", appName: "Safari", frame: remembered, displayID: "d")])
        let here = WorkspaceSavedLayout.make(snapshot: try adapter.capture(lastActivatedAt: [:], excluding: [], preferredFrontmostBundleID: nil, windowBundleIDs: [], applicationBundleIDs: []), macName: "Mac mini").layout
        let book = WorkspaceSavedLayout(macName: "MacBook Pro", capturedAt: Date(), screens: [],
                                        windows: [WorkspaceSavedWindow(bundleID: "m", appName: "Mail", screenID: "x", place: WorkspaceRect(x: 0, y: 0, width: 1, height: 1))])
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [
            WorkspaceRoutine(id: "desk", name: "Desk", actions: [.remembering(["mini": here, "book": book])]),
            WorkspaceRoutine(id: "local", name: "Side by side", actions: [WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["s"], layout: .halves)]),
        ]).encoded())
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "mini" })
        adapter.windows[0].frame = elsewhere

        // Run A, asked from the MacBook, then run B started on this Mac.
        let ranA = await controller.answerRunRequest(routineID: "desk", undo: false, from: "MacBook Pro")
        XCTAssertTrue(ranA.contains("done"), ranA)
        XCTAssertEqual(adapter.frame("w"), remembered)
        let operationA = try XCTUnwrap(controller.recoveryOrigin)
        XCTAssertEqual(operationA.fromMac, "MacBook Pro")
        controller.run(routineID: "local")
        for _ in 0..<200 where controller.isBusy || controller.recoveryOrigin == operationA { try await Task.sleep(nanoseconds: 10_000_000) }
        let tiled = WorkspaceRect(x: 0, y: 0, width: 500, height: 800)
        XCTAssertEqual(adapter.frame("w"), tiled)
        XCTAssertNil(controller.recoveryOrigin?.fromMac)
        XCTAssertNotEqual(controller.recoveryOrigin?.operationID, operationA.operationID)

        // The MacBook undoes A: B's windows must stay where B put them.
        let refused = await controller.answerRunRequest(routineID: "desk", undo: true, from: "MacBook Pro")
        XCTAssertTrue(refused.contains("Side by side ran here after your run"), refused)
        XCTAssertEqual(adapter.frame("w"), tiled)
        XCTAssertTrue(controller.canRestore, "This Mac can still undo its own run")
        XCTAssertEqual(controller.undoSummary, "Undo puts back the windows Side by side moved on this Mac.")

        // The same Mac undoing its own run still works; another Mac can't undo it.
        adapter.windows[0].frame = elsewhere
        _ = await controller.answerRunRequest(routineID: "desk", undo: false, from: "MacBook Pro")
        XCTAssertEqual(adapter.frame("w"), remembered)
        XCTAssertEqual(controller.undoSummary, "Undo puts back the windows Desk (run from MacBook Pro) moved on this Mac.")
        let stranger = await controller.answerRunRequest(routineID: "desk", undo: true, from: "iMac")
        XCTAssertTrue(stranger.contains("kept its windows as they are"), stranger)
        XCTAssertEqual(adapter.frame("w"), remembered)
        let undone = await controller.answerRunRequest(routineID: "desk", undo: true, from: "MacBook Pro")
        XCTAssertTrue(undone.contains("Windows are back where they were."), undone)
        XCTAssertEqual(adapter.frame("w"), elsewhere)
        XCTAssertNil(controller.recoveryOrigin)
        let again = await controller.answerRunRequest(routineID: "desk", undo: true, from: "MacBook Pro")
        XCTAssertEqual(again, "", "Nothing left to undo here, so this Mac is left out of the report")
    }

    /// Same Mac, same routine, two runs: an Undo for the older run (which
    /// this Mac may have missed being replaced) must not reverse the newer.
    func testAnUndoCarryingAnOperationIDOnlyReversesThatRun() async throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let remembered = WorkspaceRect(x: 100, y: 100, width: 400, height: 300)
        let elsewhere = WorkspaceRect(x: 550, y: 50, width: 300, height: 300)
        let adapter = FrameAdapter([WorkspaceWindow(id: "w", bundleID: "s", appName: "Safari", frame: remembered, displayID: "d")])
        let here = WorkspaceSavedLayout.make(snapshot: try adapter.capture(lastActivatedAt: [:], excluding: [], preferredFrontmostBundleID: nil, windowBundleIDs: [], applicationBundleIDs: []), macName: "Mac mini").layout
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [
            WorkspaceRoutine(id: "desk", name: "Desk", actions: [.remembering(["mini": here])]),
        ]).encoded())
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "mini" })

        adapter.windows[0].frame = elsewhere
        _ = await controller.answerRunRequest(routineID: "desk", undo: false, from: "MacBook Pro", operationID: "op-1")
        adapter.windows[0].frame = elsewhere
        _ = await controller.answerRunRequest(routineID: "desk", undo: false, from: "MacBook Pro", operationID: "op-2")
        XCTAssertEqual(controller.recoveryOrigin?.operationID, "op-2")

        let stale = await controller.answerRunRequest(routineID: "desk", undo: true, from: "MacBook Pro", operationID: "op-1")
        XCTAssertTrue(stale.contains("kept its windows as they are"), stale)
        XCTAssertEqual(adapter.frame("w"), remembered)

        let current = await controller.answerRunRequest(routineID: "desk", undo: true, from: "MacBook Pro", operationID: "op-2")
        XCTAssertTrue(current.contains("Windows are back where they were."), current)
        XCTAssertEqual(adapter.frame("w"), elsewhere)
    }

    func testIdleWordsSayWhenTrackingStartedAndWhenAppsCanBeHidden() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock: (Date) -> String = { "t+\(Int($0.timeIntervalSince(start) / 60))" }
        XCTAssertTrue(WorkspaceIdleWords.status(trackingSince: nil, idleMinutes: 60, now: start).contains("when this routine is on"))
        let early = WorkspaceIdleWords.status(trackingSince: start, idleMinutes: 60, now: start.addingTimeInterval(59 * 60), time: clock)
        XCTAssertEqual(early, "Noticing which apps you use since t+0. Use before then isn't known, so nothing is hidden before t+60.")
        let later = WorkspaceIdleWords.status(trackingSince: start, idleMinutes: 60, now: start.addingTimeInterval(61 * 60), time: clock)
        XCTAssertEqual(later, "Noticing which apps you use since t+0. Apps unused for 1 hour since then can be hidden.")
        XCTAssertNotNil(WorkspaceIdleWords.note(trackingSince: start, idleMinutes: 60, now: start.addingTimeInterval(59 * 60), time: clock))
        XCTAssertNil(WorkspaceIdleWords.note(trackingSince: start, idleMinutes: 60, now: start.addingTimeInterval(60 * 60), time: clock))

        // What the words promise is what the planner does: activity seen at the start counts as use then.
        let action = WorkspaceAction(kind: .hideIdleApps, bundleIDs: ["idle"], idleMinutes: 60)
        let routine = WorkspaceRoutine(name: "Hide", actions: [action])
        func plan(after minutes: Double) -> WorkspacePlan {
            WorkspacePlanner.plan(routine: routine, snapshot: WorkspaceSnapshot(capturedAt: start.addingTimeInterval(minutes * 60),
                                                                                applications: [WorkspaceApplication(bundleID: "idle", lastActivatedAt: start)]),
                                  protectedBundleIDs: [])
        }
        XCTAssertEqual(plan(after: 59).operations, [])
        XCTAssertEqual(plan(after: 61).operations, [.hideApp(bundleID: "idle")])
    }

    func testIdleTrackingRestartsWithTheControllerAndPreviewSaysSo() async throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [
            WorkspaceRoutine(id: "hide", name: "Hide", actions: [WorkspaceAction(kind: .hideIdleApps, bundleIDs: ["idle"], idleMinutes: 60)]),
        ]).encoded())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = start.addingTimeInterval(30 * 60)
        let first = WorkspaceLaunchController(adapter: FrameAdapter([]), settings: settings, macID: { "m" }, hotkeys: FakeRegistry())
        first.now = { start }
        first.start()
        XCTAssertEqual(first.trackingStartedAt, start)
        first.now = { clock }
        first.preview(routineID: "hide")
        await waitUntilIdle(first)
        let expected = WorkspaceIdleWords.note(trackingSince: start, idleMinutes: 60, now: clock)
        XCTAssertNotNil(expected)
        XCTAssertTrue(first.previewLines.contains(expected!), "\(first.previewLines)")
        clock = start.addingTimeInterval(61 * 60)
        first.preview(routineID: "hide")
        for _ in 0..<200 where first.isBusy || first.previewLines.contains(expected!) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(first.previewLines.contains { $0.hasPrefix("No app can be hidden yet") }, "\(first.previewLines)")

        // A relaunch starts counting again from its own start.
        let relaunched = WorkspaceLaunchController(adapter: FrameAdapter([]), settings: settings, macID: { "m" }, hotkeys: FakeRegistry())
        let restart = start.addingTimeInterval(50 * 60)
        relaunched.now = { restart }
        relaunched.start()
        XCTAssertEqual(relaunched.trackingStartedAt, restart)
        XCTAssertEqual(WorkspaceIdleWords.firstEligible(trackingSince: restart, idleMinutes: 60), start.addingTimeInterval(110 * 60))
    }

    func testANarrowLayoutIsWarnedAboutAndAPartialRunCanBeUndoneCompletely() async throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let originals = ["a": WorkspaceRect(x: 10, y: 10, width: 700, height: 500),
                         "b": WorkspaceRect(x: 50, y: 600, width: 800, height: 600),
                         "c": WorkspaceRect(x: 90, y: 1200, width: 600, height: 400)]
        let adapter = FrameAdapter(["a", "b", "c"].map { WorkspaceWindow(id: $0, bundleID: $0, appName: $0.uppercased(), frame: originals[$0]!, displayID: "d") })
        adapter.display = WorkspaceDisplay(id: "d", visibleFrame: WorkspaceRect(x: 0, y: 0, width: 1080, height: 1920), isMain: true)   // portrait
        adapter.minimumWidth = ["b": 500]
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [
            WorkspaceRoutine(id: "cols", name: "Columns", actions: [WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["a", "b", "c"], layout: .columns)]),
        ]).encoded())
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "m" })

        controller.preview(routineID: "cols")
        await waitUntilIdle(controller)
        XCTAssertTrue(controller.previewLines.contains { $0.hasPrefix("Windows will be narrow") }, "\(controller.previewLines)")
        XCTAssertEqual(adapter.windows.map(\.frame), ["a", "b", "c"].map { originals[$0]! }, "Preview moves nothing")

        controller.run(routineID: "cols")
        for _ in 0..<200 where controller.isBusy || !controller.status.contains("Columns") { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(controller.status.contains("stopped after 1 of 3 changes"), controller.status)
        XCTAssertTrue(controller.status.contains("wouldn't let Dictator move"), controller.status)
        XCTAssertTrue(controller.status.contains("Press Undo to put back every window that moved"), controller.status)
        XCTAssertTrue(controller.lastRunStoppedPartway)
        XCTAssertTrue(controller.canRestore)
        XCTAssertNotEqual(adapter.frame("a"), originals["a"])
        XCTAssertNotEqual(adapter.frame("b"), originals["b"], "The refused window still took its new position")
        XCTAssertEqual(adapter.frame("c"), originals["c"], "Nothing after the failure is attempted")

        controller.restoreLastReset()
        for _ in 0..<200 where controller.isBusy || controller.canRestore { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(adapter.windows.map(\.frame), ["a", "b", "c"].map { originals[$0]! }, "Undo restores every attempted window")
        XCTAssertFalse(controller.lastRunStoppedPartway)
        XCTAssertTrue(controller.status.contains("Windows are back where they were."), controller.status)
    }
}


extension WorkspaceLaunchDesktopTests {
    func testAwaitableRunWaitsForFleetAndRefusesBusyController() async throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let book = WorkspaceSavedLayout(macName: "MacBook Pro", capturedAt: Date(), screens: [],
            windows: [WorkspaceSavedWindow(bundleID: "m", appName: "Mail", screenID: "x", place: WorkspaceRect(x: 0, y: 0, width: 1, height: 1))])
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [
            WorkspaceRoutine(id: "writing", name: "Writing", actions: [.remembering(["book": book])])]).encoded())
        let controller = WorkspaceLaunchController(adapter: DeskAdapter(), settings: settings, macID: { "mini" })
        let fleet = FakeFleet()
        controller.fleet = fleet
        var entered: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        fleet.onRun = {
            await withCheckedContinuation { continuation in
                release = continuation
                entered?.resume()
                entered = nil
            }
        }
        var finished = false
        let run = Task { try await controller.runAwaiting(routineID: "writing"); finished = true }
        await withCheckedContinuation { continuation in
            if release != nil { continuation.resume() } else { entered = continuation }
        }
        XCTAssertTrue(controller.isBusy)
        XCTAssertFalse(finished, "The normal run must await the fleet response")
        do {
            try await controller.runAwaiting(routineID: "writing")
            XCTFail("Busy is a failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("busy")) }
        release?.resume()
        try await run.value
        XCTAssertTrue(finished)
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(fleet.runs.map { $0.0 }, ["writing"])
        XCTAssertNotNil(fleet.operationIDs.first ?? nil)

        fleet.onRun = nil
        fleet.failure = "Synthetic remote move failure"
        do {
            try await controller.runAwaiting(routineID: "writing")
            XCTFail("Remote failure must reach voice execution")
        } catch { XCTAssertEqual(error.localizedDescription, "MacBook Pro: Synthetic remote move failure") }
        XCTAssertFalse(controller.isBusy)
    }

    func testAwaitableRunReturnsLocalFailuresAndDisabledRoutine() async throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = FrameAdapter([WorkspaceWindow(id: "w", bundleID: "s", appName: "Safari",
            frame: WorkspaceRect(x: 0, y: 0, width: 800, height: 600), displayID: "d")])
        adapter.minimumWidth["w"] = 1200
        var routine = WorkspaceRoutine(id: "writing", name: "Writing", actions: [WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["s"])])
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [routine]).encoded())
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "m" })
        do {
            try await controller.runAwaiting(routineID: "writing")
            XCTFail("A failed move must fail the awaitable run")
        } catch { XCTAssertTrue(error.localizedDescription.contains("stopped after"), error.localizedDescription) }
        XCTAssertFalse(controller.isBusy)
        routine.enabled = false
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [routine]).encoded())
        do {
            try await controller.runAwaiting(routineID: "writing")
            XCTFail("Disabled routine must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("off")) }
    }
}

extension WorkspaceLaunchDesktopTests {
    /// All process state, time and windows are synthetic. Opening invalidates the
    /// old handle; capture must happen after readiness to get its replacement.
    private final class PlacementAdapter: WorkspaceLaunchAdapter {
        var isAccessibilityGranted = true
        var monotonicTime: TimeInterval = 0
        var running = Set<String>()
        var installed = Set<String>()
        var waitFails = Set<String>()
        var waits: [(String, TimeInterval)] = []
        var opens: [String] = []
        var moves: [String] = []
        var raised: [String] = []
        var stackReads: [Set<String>] = []
        var coverStack = false
        var stackFront: [String] = []
        var liftRefusals = Set<String>()
        func liveWindowOrder(deadline: TimeInterval) async -> [WorkspaceStackWindow] {
            var live = windows.filter { !$0.isMinimized }.map { WorkspaceStackWindow(id: $0.id, bundleID: $0.bundleID, frame: $0.frame) }
            stackReads.append(Set(live.map(\.id)))
            if coverStack { live.insert(.init(id: "cover", bundleID: "other", frame: display.visibleFrame), at: 0) }
            return stackFront.compactMap { id in live.first { $0.id == id } } + live.filter { !stackFront.contains($0.id) }
        }
        var captures = 0
        var failCaptureAt: Int?
        var requestedIDs: [Set<String>] = []
        var skips: [WorkspaceSkip] = []
        var minimizeFails = Set<String>()
        var minimizedWrites: [(String, Bool)] = []
        var retained: [Set<String>] = []
        var beforeMove: (() async -> Void)?
        var beforeCapture: (() async -> Void)?
        var events: [String] = []
        var display = WorkspaceDisplay(id: "screen", name: "Display", visibleFrame: .init(x: 100, y: -100, width: 1200, height: 900), isMain: true)
        var windows: [WorkspaceWindow] = []
        var runningBundleIDs: Set<String> { running }
        func requestPermission() {}
        func isAppRunning(bundleID: String) -> Bool { running.contains(bundleID) }
        func isAppInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
        func openApp(bundleID: String, timeout: TimeInterval) async throws -> Bool {
            opens.append(bundleID); events.append("open:" + bundleID)
            running.insert(bundleID)
            return true
        }
        func waitForFirstWindow(bundleID: String, timeout: TimeInterval) async throws -> Bool {
            waits.append((bundleID, timeout)); events.append("wait:" + bundleID)
            if waitFails.contains(bundleID) { monotonicTime += timeout; return false }
            monotonicTime += 0.1
            windows.append(.init(id: "fresh-" + bundleID, bundleID: bundleID, appName: bundleID, frame: .init(x: 120, y: 0, width: 600, height: 500), displayID: "screen"))
            return true
        }
        func capture(lastActivatedAt: [String: Date], excluding: Set<String>, preferredFrontmostBundleID: String?, windowBundleIDs: Set<String>, applicationBundleIDs: Set<String>) async throws -> WorkspaceSnapshot {
            captures += 1; requestedIDs.append(windowBundleIDs); events.append("capture")
            await beforeCapture?()
            if captures == failCaptureAt { throw NativeResetError.captureFailed("synthetic capture failure") }
            return WorkspaceSnapshot(displays: [display], windows: windows.filter { windowBundleIDs.contains($0.bundleID) },
                                     applications: running.map { .init(bundleID: $0, name: $0) },
                                     skipped: skips + windows.filter(\.isMinimized).map { .init(bundleID: $0.bundleID, appName: $0.appName, reason: .minimized) })
        }
        func moveWindow(id: String, to frame: WorkspaceRect) async throws {
            await beforeMove?()
            guard let i = windows.firstIndex(where: { $0.id == id }) else { throw NativeResetError.windowNotFound(id) }
            windows[i].frame = frame; moves.append(id); events.append("move:" + id)
        }
        func setMinimized(id: String, minimized: Bool) async throws {
            minimizedWrites.append((id, minimized)); events.append("minimized:" + id + ":" + String(minimized))
            if minimizeFails.contains(id) { throw WorkspaceLaunchError.unavailable("synthetic refusal") }
            guard let i = windows.firstIndex(where: { $0.id == id }) else { throw NativeResetError.windowNotFound(id) }
            windows[i].isMinimized = minimized
        }
        func raiseWindow(id: String, deadline: TimeInterval) async throws {
            raised.append(id)
            if liftRefusals.contains(id) { throw WorkspaceLaunchError.unavailable("synthetic lift refusal") }
            stackFront.removeAll { $0 == id }; stackFront.insert(id, at: 0)
        }
        func hideApp(bundleID: String) throws -> Bool { false }
        func unhideApp(bundleID: String) throws {}
        func retainWindows(ids: Set<String>) { retained.append(ids) }
    }

    private final class PlacementFleet: WorkspaceFleet {
        var otherMacNames = ["MacBook"]
        var workspaceMacs: [WorkspaceMacOption] = []
        var localWorkspaceMacID: String? = "setup-mini"
        var remote: WorkspaceLaunchController?
        var calls: [Bool] = []
        var operationIDs: [String?] = []
        func rememberEverywhere() async throws -> (layouts: [String: WorkspaceSavedLayout], unanswered: [String], busy: [String]) { ([:], [], []) }
        func runElsewhere(routineID: String, undo: Bool, operationID: String?) async throws -> [WorkspaceRunReport] {
            calls.append(undo); operationIDs.append(operationID)
            guard let remote else { return [] }
            let result = await remote.answerRunReport(routineID: routineID, undo: undo, from: "Mac mini", operationID: operationID)
            return [.init(macName: "MacBook", summary: result.summary, failure: result.failure, counts: result.counts)]
        }
    }

    private func savedLayout(_ name: String, apps: [String], display: WorkspaceDisplay) -> WorkspaceSavedLayout {
        WorkspaceSavedLayout(macName: name, capturedAt: Date(timeIntervalSinceReferenceDate: 0), screens: [display],
            windows: apps.enumerated().map { index, id in
                WorkspaceSavedWindow(bundleID: id, appName: id, screenID: display.id,
                    place: .init(x: Double(index % 2) * 0.5, y: 0, width: 0.5, height: 1))
            })
    }

    func testRememberScenarioAcrossMacsBringsBackFiveWindowsScopesNotesAndLogsUndo() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let mini = PlacementAdapter(), book = PlacementAdapter(), fleet = PlacementFleet()
        func window(_ id: String, _ app: String, minimized: Bool = false) -> WorkspaceWindow {
            .init(id: id, bundleID: app, appName: app, frame: .init(x: 130, y: 10, width: 500, height: 450), displayID: "screen", isMinimized: minimized)
        }
        mini.windows = [window("local", "Local")]; mini.running = ["Local"]
        book.windows = [window("c1", "ChatGPT"), window("c2", "ChatGPT"), window("c3", "ChatGPT", minimized: true),
                        window("h", "Herdr", minimized: true), window("t", "iTerm2")]
        book.running = ["ChatGPT", "Herdr", "iTerm2"]
        // Even a broad adapter response must never leak another Mac's apps.
        mini.skips = [.init(bundleID: "ChatGPT", appName: "ChatGPT", reason: .otherSpace, count: 2)]
        book.skips = [.init(bundleID: "ChatGPT", appName: "ChatGPT", reason: .otherSpace, count: 2),
                      .init(bundleID: "iTerm2", appName: "iTerm2", reason: .otherSpace)]
        let here = WorkspaceLaunchController(adapter: mini, settings: settings, macID: { "mini" })
        let there = WorkspaceLaunchController(adapter: book, settings: settings, macID: { "book" })
        here.macName = { "Mac mini" }; there.macName = { "MacBook" }; here.fleet = fleet; fleet.remote = there
        var localLog: [String] = [], remoteLog: [String] = []
        here.diagnostics = { localLog.append($0) }; there.diagnostics = { remoteLog.append($0) }
        let routine = WorkspaceRoutine(id: "scenario", name: "Agentic Workflow", actions: [.remembering([
            "mini": savedLayout("Mac mini", apps: ["Local"], display: mini.display),
            "book": savedLayout("MacBook", apps: ["ChatGPT", "ChatGPT", "ChatGPT", "Herdr", "iTerm2"], display: book.display)
        ], openMissingApps: nil)])
        XCTAssertTrue(here.saveRoutine(routine))
        let before = book.windows
        try await here.runAwaiting(routineID: routine.id)
        XCTAssertEqual(book.moves.count, 5)
        XCTAssertEqual(book.minimizedWrites.map(\.0), ["c3", "h"])
        XCTAssertEqual(book.captures, 2, "Unminimizing must be followed by a fresh capture before moves")
        XCTAssertEqual(book.events.prefix(4), ["capture", "minimized:c3:false", "minimized:h:false", "capture"])
        XCTAssertEqual(mini.requestedIDs, [["Local"]])
        XCTAssertFalse(here.status.components(separatedBy: "\nMacBook:")[0].contains("ChatGPT"))
        XCTAssertFalse(here.status.contains("isn't open"))
        XCTAssertFalse(here.status.contains("minimized"))
        XCTAssertTrue(here.hasWindowsOnAnotherDesktop(routineID: routine.id))
        let desktopNote = "2 ChatGPT windows are on another desktop, so they weren't moved. Switch to that desktop and run this again."
        XCTAssertEqual(here.status.components(separatedBy: desktopNote).count, 2)
        XCTAssertEqual(Set(here.status.components(separatedBy: "\n")).count, here.status.components(separatedBy: "\n").count)
        XCTAssertTrue(localLog.contains { $0.contains("start") && $0.contains("origin=here trigger=voice") })
        XCTAssertTrue(localLog.contains { $0.contains("target=MacBook reached=true moved=5 broughtBack=2 opened=0") })
        XCTAssertTrue(remoteLog.contains { $0.contains("origin=remote:Mac mini trigger=remote") })
        XCTAssertTrue(remoteLog.contains { $0.contains("otherSpace:ChatGPT=2,iTerm2=1") })
        here.restoreLastReset()
        await waitUntilIdle(here)
        XCTAssertEqual(book.windows, before, "Undo restores both geometry and minimized state on the owning Mac")
        XCTAssertEqual(fleet.operationIDs.first!, fleet.operationIDs.last!)
        XCTAssertTrue(remoteLog.contains { $0.contains("start") && $0.contains("undo=true") })
        XCTAssertTrue(localLog.contains { $0.contains("target=MacBook") && $0.contains("undo=true") })
        XCTAssertTrue((localLog + remoteLog).allSatisfy { $0.hasPrefix("workspace:") && !$0.contains("window title") })
    }

    func testRememberStacksAfterMinimizedRecaptureAndScopesLiftNotesWithoutFailure() async throws {
        let settings = AppSettings.shared, saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = PlacementAdapter()
        adapter.running = ["code", "chat"]
        adapter.coverStack = true
        adapter.liftRefusals = ["code"]
        adapter.windows = [
            .init(id: "code", bundleID: "code", appName: "VS Code", frame: .init(width: 500, height: 400), isMinimized: true),
            .init(id: "chat", bundleID: "chat", appName: "Chat", frame: .init(width: 500, height: 400))
        ]
        var layout = savedLayout("Mini", apps: ["code", "chat"], display: adapter.display)
        layout.windows[0].stack = 1; layout.windows[1].stack = 0
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "mini" })
        controller.macName = { "Mini" }
        var log: [String] = []; controller.diagnostics = { log.append($0) }
        let routine = WorkspaceRoutine(id: "stack-recapture", name: "Desk", actions: [.remembering(["mini": layout])])
        XCTAssertTrue(controller.saveRoutine(routine))
        try await controller.runAwaiting(routineID: routine.id)
        XCTAssertEqual(adapter.captures, 2)
        XCTAssertTrue(adapter.stackReads.allSatisfy { $0 == ["code", "chat"] })
        XCTAssertTrue(adapter.raised.contains("code"))
        XCTAssertTrue(adapter.raised.contains("chat"), "Other windows continue after a refusal")
        XCTAssertEqual(controller.status.components(separatedBy: "VS Code wouldn't come to the front.").count, 2)
        XCTAssertTrue(controller.status.hasPrefix("Mini: "))
        XCTAssertEqual(log.filter { $0.hasPrefix("workspace: stack ") }.count, 1)
        XCTAssertTrue(log.contains { $0.contains("stack passes=3 lifted=1 order=chat,code focusBack=0") })
    }

    func testVisibleWindowsCountFirstAndLegacyTilingNeverBringsBackWindows() {
        let adapter = PlacementAdapter()
        let visible = WorkspaceWindow(id: "visible", bundleID: "a", frame: .init(width: 400, height: 300))
        var minimized = visible; minimized.id = "minimized"; minimized.isMinimized = true
        let snapshot = WorkspaceSnapshot(windows: [visible, minimized])
        let layout = savedLayout("Mini", apps: ["a"], display: adapter.display)
        let remember = WorkspaceRoutine(name: "Remember", actions: [.remembering(["mini": layout])])
        XCTAssertTrue(WorkspaceLaunchExecutor.windowsToBringBack(in: remember, snapshot: snapshot, macID: "mini", aliases: []).isEmpty)
        let place = WorkspaceRoutine(name: "Place", actions: [.placing([.init(bundleID: "a", appName: "A", macID: "mini", macName: "Mini")])])
        XCTAssertTrue(WorkspaceLaunchExecutor.windowsToBringBack(in: place, snapshot: snapshot, macID: "mini", aliases: []).isEmpty)
        var second = minimized; second.id = "second"
        var extra = minimized; extra.id = "extra"
        let three = savedLayout("Mini", apps: ["a", "a", "a"], display: adapter.display)
        let repeated = WorkspaceRoutine(name: "Remember", actions: [.remembering(["mini": three]), .remembering(["mini": three])])
        XCTAssertEqual(WorkspaceLaunchExecutor.windowsToBringBack(in: repeated, snapshot: .init(windows: [visible, minimized, second, extra]), macID: "mini", aliases: []).map(\.id), ["minimized", "second"])
        let onlyMinimized = WorkspaceSnapshot(windows: [minimized])
        XCTAssertEqual(WorkspaceLaunchExecutor.windowsToBringBack(in: place, snapshot: onlyMinimized, macID: "mini", aliases: []).map(\.id), ["minimized"])
        for layout in [WorkspaceLayout.halves, .quarters] {
            let legacy = WorkspaceRoutine(name: "Legacy", actions: [.init(kind: .arrangeWindows, bundleIDs: ["a"], layout: layout)])
            XCTAssertTrue(WorkspaceLaunchExecutor.windowsToBringBack(in: legacy, snapshot: onlyMinimized, macID: "mini", aliases: []).isEmpty)
        }
    }

    func testMinimizedPreviewIsReadOnlyAndARefusalDoesNotStopOtherApps() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = PlacementAdapter()
        adapter.running = ["a", "b"]
        adapter.windows = ["a", "b"].map { .init(id: $0, bundleID: $0, appName: $0, frame: .init(width: 500, height: 400), displayID: "screen", isMinimized: true) }
        adapter.minimizeFails = ["a"]
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "mini" })
        controller.diagnostics = { _ in }
        let routine = WorkspaceRoutine(id: "refusal", name: "Place", actions: [.placing(["a", "b"].map {
            .init(bundleID: $0, appName: $0, macID: "mini", macName: "Mini")
        })])
        XCTAssertTrue(controller.saveRoutine(routine))
        controller.preview(routineID: routine.id); await waitUntilIdle(controller)
        XCTAssertTrue(adapter.minimizedWrites.isEmpty); XCTAssertTrue(adapter.opens.isEmpty)
        XCTAssertTrue(controller.previewLines.contains { $0.contains("will come back") })
        XCTAssertEqual(controller.previewPicture?.tiles.count, 2)
        XCTAssertTrue(controller.previewPicture?.tiles.allSatisfy { $0.appName.contains("will come back") } == true)
        try await controller.runAwaiting(routineID: routine.id)
        XCTAssertEqual(adapter.moves, ["b"])
        XCTAssertTrue(controller.status.contains("a wouldn't bring a minimized window back"))
        XCTAssertFalse(controller.status.contains("isn't open"))
        controller.restoreLastReset(); await waitUntilIdle(controller)
        XCTAssertTrue(adapter.windows.allSatisfy(\.isMinimized))
    }

    func testRecaptureFailureAfterUnminimizingStillHasRemoteUndoAndFailureDiagnostics() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = PlacementAdapter()
        adapter.running = ["a"]
        adapter.windows = [.init(id: "w", bundleID: "a", appName: "A", frame: .init(width: 500, height: 400), displayID: "screen", isMinimized: true)]
        adapter.failCaptureAt = 2
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "mini" })
        var log: [String] = []; controller.diagnostics = { log.append($0) }
        let routine = WorkspaceRoutine(id: "capture-failure", name: "Remember", actions: [.remembering([
            "mini": savedLayout("Mini", apps: ["a"], display: adapter.display)
        ])])
        XCTAssertTrue(controller.saveRoutine(routine))
        let result = await controller.answerRunReport(routineID: routine.id, undo: false, from: "Starter", operationID: "operation-one")
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.counts?.windowsBroughtBack, 1)
        XCTAssertTrue(controller.canRestore)
        XCTAssertTrue(adapter.moves.isEmpty)
        let undo = await controller.answerRunReport(routineID: routine.id, undo: true, from: "Starter", operationID: "operation-one")
        XCTAssertNil(undo.failure)
        XCTAssertTrue(adapter.windows[0].isMinimized)
        XCTAssertEqual(undo.counts?.windowsMinimized, 1)
        XCTAssertTrue(log.contains { $0.contains("end") && $0.contains("broughtBack=1") && $0.contains("failure=Dictator couldn't read") })
        XCTAssertEqual(log.filter { $0.contains("op=operatio") }.count, 4)
    }

    func testPreviewUsesFutureDesktopWordingForWholeAndPartialApps() {
        let adapter = PlacementAdapter()
        let layout = savedLayout("Mini", apps: ["ChatGPT"], display: adapter.display)
        for action in [WorkspaceAction.remembering(["mini": layout]), .placing([
            .init(bundleID: "ChatGPT", appName: "ChatGPT", macID: "mini", macName: "Mini")
        ])] {
            let routine = WorkspaceRoutine(name: "Desk", actions: [action])
            for (count, available, subject, verb) in [(1, false, "ChatGPT is", "it"),
                                                      (1, true, "1 ChatGPT window is", "it"),
                                                      (2, true, "2 ChatGPT windows are", "they")] {
                let snapshot = WorkspaceSnapshot(displays: [adapter.display], windows: available ? [
                    .init(id: "w", bundleID: "ChatGPT", appName: "ChatGPT", frame: .init(width: 600, height: 400), displayID: adapter.display.id)
                ] : [], applications: [.init(bundleID: "ChatGPT")], skipped: [
                    .init(bundleID: "ChatGPT", appName: "ChatGPT", reason: .otherSpace, count: count)
                ])
                let preview = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [], macID: "mini", preview: true)
                XCTAssertEqual(preview.notes, ["\(subject) on another desktop, so \(verb) won't move. Switch to that desktop and run this again."])
                let run = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [], macID: "mini")
                XCTAssertEqual(run.notes, ["\(subject) on another desktop, so \(verb) \(verb == "it" ? "wasn't" : "weren't") moved. Switch to that desktop and run this again."])
            }
        }
    }

    func testDesktopFindingBelongsToTheLatestPreviewOrRunForEachRoutine() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = PlacementAdapter()
        let routines = ["one", "two"].map {
            let action = WorkspaceAction.remembering(["mini": savedLayout("Mini", apps: ["ChatGPT"], display: adapter.display)], openMissingApps: false)
            return WorkspaceRoutine(id: $0, name: $0, actions: [action])
        }
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: routines).encoded())
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "mini" })
        XCTAssertFalse(controller.hasWindowsOnAnotherDesktop(routineID: "one"))
        adapter.skips = [.init(bundleID: "ChatGPT", appName: "ChatGPT", reason: .otherSpace)]
        controller.preview(routineID: "one")
        await waitUntilIdle(controller)
        XCTAssertTrue(controller.hasWindowsOnAnotherDesktop(routineID: "one"))
        XCTAssertFalse(controller.hasWindowsOnAnotherDesktop(routineID: "two"))
        adapter.skips = [.init(bundleID: "unrelated", reason: .otherSpace)]
        try await controller.runAwaiting(routineID: "one")
        XCTAssertFalse(controller.hasWindowsOnAnotherDesktop(routineID: "one"))
        adapter.skips = [.init(bundleID: "ChatGPT", appName: "ChatGPT", reason: .otherSpace)]
        try await controller.runAwaiting(routineID: "two")
        XCTAssertTrue(controller.hasWindowsOnAnotherDesktop(routineID: "two"))
        adapter.skips = []
        controller.preview(routineID: "two")
        await waitUntilIdle(controller)
        XCTAssertFalse(controller.hasWindowsOnAnotherDesktop(routineID: "two"))
    }

    func testClosedAppHintInPreviewAndResultOnlyWhenOpeningIsOff() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = PlacementAdapter()
        adapter.installed = ["ChatGPT"]
        adapter.waitFails = ["ChatGPT"]
        let layout = savedLayout("Mini", apps: ["ChatGPT"], display: adapter.display)
        for original in [WorkspaceAction.remembering(["mini": layout]), .placing([
            .init(bundleID: "ChatGPT", appName: "ChatGPT", macID: "mini", macName: "Mini")
        ])] {
            for choice in [nil, false, true] as [Bool?] {
                adapter.running = []; adapter.opens = []
                var action = original
                action.openMissingApps = choice
                let routine = WorkspaceRoutine(id: "closed", name: "Closed", actions: [action])
                settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [routine]).encoded())
                let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "mini" })
                controller.macName = { "Mini" }
                controller.preview(routineID: routine.id)
                await waitUntilIdle(controller)
                let previewHint = "ChatGPT isn't open, so it won't move. Turn on “Open these apps if they aren't open” to open it."
                let hint = "ChatGPT isn't open, so it wasn't moved. Turn on “Open these apps if they aren't open” to open it."
                if choice == true {
                    XCTAssertTrue(controller.previewLines.contains { $0.contains("will open") })
                    XCTAssertFalse(controller.previewLines.contains(previewHint))
                } else {
                    XCTAssertTrue(controller.previewLines.contains(previewHint))
                }
                XCTAssertTrue(adapter.opens.isEmpty, "Preview never opens an app")
                try await controller.runAwaiting(routineID: routine.id)
                if choice == true {
                    XCTAssertTrue(controller.status.contains("ChatGPT didn't show a window in time on Mini, so it wasn't placed."))
                    XCTAssertFalse(controller.status.contains("Turn on"))
                    XCTAssertEqual(adapter.opens, ["ChatGPT"])
                } else {
                    XCTAssertTrue(controller.status.contains(hint))
                    XCTAssertTrue(adapter.opens.isEmpty)
                }
            }
        }
    }

    func testAppAvailabilityUsesEvidenceAndSkipCensusNeverRepeatsNotes() {
        let adapter = PlacementAdapter()
        let layout = savedLayout("Mini", apps: ["ChatGPT", "Herdr", "Closed"], display: adapter.display)
        let skips: [WorkspaceSkip] = [
            .init(bundleID: "ChatGPT", appName: "ChatGPT", reason: .otherSpace, count: 2),
            .init(bundleID: "ChatGPT", appName: "ChatGPT", reason: .otherSpace, count: 2),
            .init(bundleID: "Herdr", appName: "Herdr", reason: .minimized),
            .init(bundleID: "unrelated", appName: "Unrelated", reason: .otherSpace)]
        let snapshot = WorkspaceSnapshot(displays: [adapter.display], applications: [.init(bundleID: "ChatGPT"), .init(bundleID: "Herdr")], skipped: skips)
        let plan = WorkspacePlanner.plan(routine: .init(name: "Remember", actions: [.remembering(["mini": layout], openMissingApps: nil)]), snapshot: snapshot, protectedBundleIDs: [], macID: "mini")
        XCTAssertEqual(plan.notes.count, 3)
        XCTAssertEqual(plan.notes.filter { $0.contains("2 ChatGPT windows are on another desktop") }.count, 1)
        XCTAssertEqual(plan.notes.filter { $0.contains("isn't open") }, ["Closed isn't open, so it wasn't moved. Turn on “Open these apps if they aren't open” to open it."])
        XCTAssertFalse(plan.notes.contains { $0.contains("Unrelated") })
        let summary = WorkspaceSkip.summary(Array(skips.prefix(3)))!
        XCTAssertEqual(summary.components(separatedBy: "2 ChatGPT windows are on another desktop").count, 2)
    }

    func testRememberOpeningUsesLocalLayoutAndLegacyAbsentChoiceIsOff() async throws {
        let adapter = PlacementAdapter()
        adapter.installed = ["a", "b", "remote"]
        let local = savedLayout("Mini", apps: ["a", "a", "b"], display: adapter.display)
        let remote = savedLayout("Book", apps: ["remote"], display: adapter.display)
        var action = WorkspaceAction.remembering(["mini": local, "book": remote])
        XCTAssertEqual(action.openMissingApps, true)
        let routine = WorkspaceRoutine(name: "Remember", actions: [action])
        let preview = WorkspacePlanner.plan(routine: routine, snapshot: .init(displays: [adapter.display]), protectedBundleIDs: [], macID: "mini", preview: true)
        XCTAssertTrue(preview.notes.contains("a will open.")); XCTAssertEqual(preview.placementTiles.count, 3)
        XCTAssertFalse(preview.notes.contains { $0.contains("remote") || $0.contains("isn't open") })
        _ = await WorkspaceLaunchExecutor.openMissing(in: routine, macID: "mini", aliases: [], macName: "Mini", adapter: adapter)
        XCTAssertEqual(adapter.opens, ["a", "b"])
        XCTAssertEqual(adapter.waits.count, 2)
        action.openMissingApps = nil
        let decoded = try JSONDecoder().decode(WorkspaceAction.self, from: JSONEncoder().encode(action))
        XCTAssertNil(decoded.openMissingApps)
        adapter.running = []; adapter.opens = []
        _ = await WorkspaceLaunchExecutor.openMissing(in: .init(name: "Legacy", actions: [decoded]), macID: "mini", aliases: [], macName: "Mini", adapter: adapter)
        XCTAssertTrue(adapter.opens.isEmpty)
        let kept = WorkspaceAction.remembering(["mini": local], id: action.id, openMissingApps: decoded.openMissingApps)
        XCTAssertNil(kept.openMissingApps)
        let off = WorkspaceAction.remembering(["mini": local], id: action.id, openMissingApps: false)
        XCTAssertEqual(WorkspaceAction.remembering(["mini": local], id: off.id, openMissingApps: off.openMissingApps).openMissingApps, false)
    }

    func testPlacementOpeningSkipsOtherMacMissingAndAlreadyRunningApps() async {
        let adapter = PlacementAdapter()
        adapter.installed = ["new", "slow", "remote"]
        adapter.running = ["running"]
        adapter.waitFails = ["slow"]
        let placements = ["new", "slow", "missing", "running"].map {
            WorkspacePlacement(bundleID: $0, appName: $0, macID: "mini", macName: "Mac mini")
        } + [WorkspacePlacement(bundleID: "remote", appName: "Remote", macID: "book", macName: "MacBook")]
        let routine = WorkspaceRoutine(name: "Work", actions: [.placing(placements)])
        let result = await WorkspaceLaunchExecutor.openMissing(in: routine, macID: "mini", aliases: [], macName: "Mac mini", adapter: adapter)
        XCTAssertEqual(adapter.opens, ["new", "slow"])
        XCTAssertEqual(result.opened, ["new", "slow"])
        XCTAssertEqual(adapter.waits.count, 2)
        XCTAssertTrue(adapter.waits.allSatisfy { $0.1 <= 8 })
        XCTAssertTrue(result.notes.contains { $0.contains("slow") && $0.contains("Mac mini") })
        XCTAssertTrue(result.notes.contains { $0.contains("missing isn't installed on Mac mini") })
        var off = routine
        off.actions[0].openMissingApps = nil
        adapter.opens = []
        _ = await WorkspaceLaunchExecutor.openMissing(in: off, macID: "mini", aliases: [], macName: "Mac mini", adapter: adapter)
        XCTAssertTrue(adapter.opens.isEmpty)
    }

    func testOpeningWaitsHaveOneOverallVoiceBudgetAndContinuePastMissingApps() async {
        let adapter = PlacementAdapter()
        adapter.installed = Set((0..<20).map { "app\($0)" })
        adapter.waitFails = adapter.installed
        let routine = WorkspaceRoutine(name: "Work", actions: [.placing((0..<20).map {
            WorkspacePlacement(bundleID: "app\($0)", appName: "App \($0)", macID: "mini", macName: "Mac mini")
        })])
        let result = await WorkspaceLaunchExecutor.openMissing(in: routine, macID: "mini", aliases: [], macName: "Mac mini", adapter: adapter)
        XCTAssertEqual(adapter.monotonicTime, VoiceLaunchReadiness.workspaceRunBudget - 10)
        XCTAssertLessThan(adapter.waits.count, 20)
        XCTAssertEqual(adapter.waits.last?.1, 2)
        XCTAssertEqual(result.notes.count, 20)
        XCTAssertTrue(adapter.waits.allSatisfy { $0.1 > 0 && $0.1 <= 8 })
    }

    func testPlacementPreviewNeverOpensAndRunRecapturesThenUndoLeavesAppsOpen() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = PlacementAdapter(), fleet = PlacementFleet()
        adapter.installed = ["cursor"]
        adapter.coverStack = true
        fleet.workspaceMacs = [.init(id: "setup-mini", name: "Mac mini", online: true), .init(id: "book", name: "MacBook", online: false)]
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "mini" })
        controller.macName = { "Mac mini" }; controller.fleet = fleet
        let routine = WorkspaceRoutine(id: "place", name: "Work", actions: [.placing([
            .init(bundleID: "cursor", appName: "Cursor", macID: "setup-mini", macName: "Mac mini", position: .rightHalf)
        ])])
        XCTAssertTrue(controller.saveRoutine(routine))
        XCTAssertEqual(controller.placementMacs.map(\.name), ["Mac mini", "MacBook"])
        XCTAssertFalse(controller.placementMacs.last!.online)
        controller.preview(routineID: routine.id)
        for _ in 0..<200 where controller.isBusy { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(adapter.opens.isEmpty)
        XCTAssertTrue(controller.previewLines.contains { $0.contains("will open") })
        XCTAssertEqual(controller.previewPicture?.tiles.first?.frame, WorkspaceRect(x: 700, y: -100, width: 600, height: 900))
        try await controller.runAwaiting(routineID: routine.id)
        XCTAssertEqual(adapter.opens, ["cursor"])
        XCTAssertEqual(adapter.events.suffix(4), ["open:cursor", "wait:cursor", "capture", "move:fresh-cursor"])
        XCTAssertEqual(adapter.moves, ["fresh-cursor"])
        XCTAssertEqual(adapter.raised, ["fresh-cursor"], "Stacking uses the window captured after opening")
        XCTAssertEqual(adapter.stackReads.last, ["fresh-cursor"])
        controller.restoreLastReset()
        for _ in 0..<200 where controller.isBusy { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(adapter.windows.first?.frame, WorkspaceRect(x: 120, y: 0, width: 600, height: 500))
        XCTAssertTrue(adapter.running.contains("cursor"))
        XCTAssertTrue(controller.status.contains("Apps opened by this run stay open."))
    }

    func testPlacementsFanOutRunLocallyOnEachMacAndUndoBothWithSameOperation() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let mini = PlacementAdapter(), book = PlacementAdapter(), fleet = PlacementFleet()
        mini.installed = ["local"]; book.installed = ["remote"]
        let here = WorkspaceLaunchController(adapter: mini, settings: settings, macID: { "mini" })
        here.macName = { "Mac mini" }; here.fleet = fleet
        let there = WorkspaceLaunchController(adapter: book, settings: settings, macID: { "book" })
        there.macName = { "MacBook" }; fleet.remote = there
        let routine = WorkspaceRoutine(id: "place", name: "Work", actions: [.placing([
            .init(bundleID: "local", appName: "Local", macID: "mini", macName: "Mac mini", position: .leftHalf),
            .init(bundleID: "remote", appName: "Remote", macID: "book", macName: "MacBook", position: .rightHalf)
        ])])
        XCTAssertTrue(here.saveRoutine(routine))
        try await here.runAwaiting(routineID: routine.id)
        XCTAssertEqual(mini.opens, ["local"])
        XCTAssertEqual(book.opens, ["remote"])
        XCTAssertEqual(mini.moves, ["fresh-local"])
        XCTAssertEqual(book.moves, ["fresh-remote"])
        XCTAssertNotNil(there.recoveryOrigin)
        here.restoreLastReset()
        for _ in 0..<200 where here.isBusy { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(fleet.calls, [false, true])
        XCTAssertEqual(fleet.operationIDs[0], fleet.operationIDs[1])
        XCTAssertEqual(mini.windows.first?.frame.x, 120)
        XCTAssertEqual(book.windows.first?.frame.x, 120)
        XCTAssertTrue(here.status.contains("Apps opened by this run stay open."))
        XCTAssertTrue(book.running.contains("remote"))
    }

    func testOfflinePlacementNamesMacAndAppAndVoiceFailsAfterLocalWorkFinishes() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = PlacementAdapter()
        adapter.running = ["local"]
        adapter.windows = [.init(id: "local-window", bundleID: "local", frame: .init(x: 120, y: 0, width: 600, height: 500))]
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "book" })
        controller.macName = { "MacBook" }
        let routine = WorkspaceRoutine(id: "place", name: "Work", actions: [.placing([
            .init(bundleID: "local", appName: "Local", macID: "book", macName: "MacBook", position: .leftHalf),
            .init(bundleID: "cursor", appName: "Cursor", macID: "mini", macName: "Mac mini", position: .rightHalf)
        ])])
        XCTAssertTrue(controller.saveRoutine(routine))
        XCTAssertEqual(controller.otherMacs(in: routine), ["Mac mini"])
        controller.preview(routineID: routine.id)
        for _ in 0..<200 where controller.isBusy { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(controller.previewLines.filter { $0.hasPrefix("On Mac mini:") }, ["On Mac mini: Cursor on Main screen, right half"])
        XCTAssertTrue(adapter.opens.isEmpty)
        do { try await controller.runAwaiting(routineID: routine.id); XCTFail("Voice must report the unreachable placement") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Mac mini wasn't reached, so Cursor wasn't placed")) }
        XCTAssertEqual(adapter.moves, ["local-window"])
        XCTAssertTrue(controller.canRestore)
        XCTAssertFalse(controller.undoSummary?.contains("Apps opened") ?? true)
    }

    func testEmptyCaptureStillReturnsDisplaysForMonitorDiscovery() async throws {
        let adapter = PlacementAdapter()
        let controller = WorkspaceLaunchController(adapter: adapter, macID: { "mini" })
        let answer = await controller.answerCaptureRequest()
        XCTAssertEqual(answer.macID, "mini")
        XCTAssertEqual(answer.layout?.screens, [adapter.display])
        XCTAssertEqual(answer.layout?.windows, [])
        XCTAssertNil(answer.error)
    }
}

extension WorkspaceLaunchDesktopTests {
    func testCaptureDuringRunOrAnotherCaptureCannotReplaceHandles() async throws {
        let settings = AppSettings.shared, saved = AppSettings.shared.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let adapter = PlacementAdapter()
        adapter.running = ["a"]
        adapter.windows = [.init(id: "w", bundleID: "a", frame: .init(width: 600, height: 500), displayID: "screen")]
        let controller = WorkspaceLaunchController(adapter: adapter, settings: settings, macID: { "mini" })
        let routine = WorkspaceRoutine(id: "busy-test", name: "Work", actions: [.placing([
            .init(bundleID: "a", appName: "A", macID: "mini", macName: "Mini", position: .rightHalf)
        ])])
        XCTAssertTrue(controller.saveRoutine(routine))
        var checked = 0
        let checkBusy: () async -> Void = {
            checked += 1
            XCTAssertTrue(controller.isBusy)
            let captures = adapter.captures, retained = adapter.retained
            let answer = await controller.answerCaptureRequest()
            XCTAssertEqual(answer.error, WorkspaceLaunchController.captureBusyMessage)
            XCTAssertNil(answer.layout)
            let remembered = await controller.rememberLayouts(everywhere: false)
            XCTAssertNil(remembered)
            XCTAssertEqual(controller.status, WorkspaceLaunchController.captureBusyMessage)
            do { _ = try await controller.captureLayout(); XCTFail("Busy capture must fail") }
            catch { XCTAssertEqual(error.localizedDescription, WorkspaceLaunchController.captureBusyMessage) }
            do { _ = try await controller.placementDisplays(); XCTFail("Busy discovery must fail") }
            catch { XCTAssertEqual(error.localizedDescription, WorkspaceLaunchController.captureBusyMessage) }
            XCTAssertEqual(adapter.captures, captures)
            XCTAssertEqual(adapter.retained, retained)
        }
        adapter.beforeMove = checkBusy
        try await controller.runAwaiting(routineID: routine.id)
        XCTAssertEqual(checked, 1)
        XCTAssertTrue(controller.canRestore)
        XCTAssertEqual(adapter.retained.last, ["w"])
        adapter.beforeMove = nil
        adapter.beforeCapture = checkBusy
        _ = try await controller.captureLayout()
        XCTAssertEqual(checked, 2)
        XCTAssertEqual(adapter.retained.last, ["w"], "Discovery preserves Undo handles")
        XCTAssertFalse(controller.isBusy)
    }

    func testRememberReportsBusyFleetMacAndDiscoveryRetries() async throws {
        let controller = WorkspaceLaunchController(adapter: DeskAdapter(), macID: { "mini" })
        let fleet = FakeFleet()
        fleet.busy = ["MacBook Pro"]
        controller.fleet = fleet
        _ = await controller.rememberLayouts(everywhere: true)
        XCTAssertTrue(controller.status.contains("MacBook Pro is busy with a routine"))
        do { _ = try await controller.placementDisplays(); XCTFail("Busy discovery must be unavailable") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not available right now")) }
        fleet.busy = []
        let discovered = try await controller.placementDisplays()
        XCTAssertTrue(discovered.isEmpty)
    }

    func testInstalledAppLoaderRunsOffMainThreadAndPreservesPickerChoices() async {
        let saved = WorkspaceAppNames.App(id: "remote", name: "Saved remote app", open: false)
        let running = WorkspaceAppNames.App(id: "running", name: "Running name", open: true)
        let installed = await VoiceInstalledApps.load(scanApps: {
            XCTAssertFalse(Thread.isMainThread)
            return [VoiceInstalledApp(name: "Installed name", url: URL(fileURLWithPath: "/synthetic/Running.app"), bundleID: "running"),
                    VoiceInstalledApp(name: "New app", url: URL(fileURLWithPath: "/synthetic/New.app"), bundleID: "new")]
        })
        let merged = WorkspaceAppNames.merging([saved, running], installed: installed)
        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged.contains(saved))
        XCTAssertTrue(merged.contains(running))
        XCTAssertEqual(merged.first { $0.id == "new" }?.open, false)
    }
}
