import XCTest
@testable import Dictator

@MainActor
final class WorkspaceGroupEditorTests: XCTestCase {
    private let mac = WorkspaceMacOption(id: "mini", name: "Studio", online: true, isCurrent: true)
    private let browser = WorkspaceBrowserInfo(bundleID: "browser.chrome", name: "Chrome")

    private func tabDraft() -> WorkspaceTabSetDraft {
        var draft = WorkspaceTabSetDraft.newWindow(mac: mac, browsers: [browser])
        draft.addressesText = "example.com"
        return draft
    }

    func testGroupOptionDefaultsOffAndIsUnavailableWithoutSteps() {
        var routine = WorkspaceRoutine(name: "Work")
        XCTAssertFalse(WorkspaceGroupEditorLogic.isEnabled(routine))
        XCTAssertFalse(WorkspaceGroupEditorLogic.showsControls(for: routine))
        routine.actions = [WorkspaceTabSetDraft.action([tabDraft()])]
        XCTAssertTrue(WorkspaceGroupEditorLogic.showsControls(for: routine))
        XCTAssertFalse(WorkspaceGroupEditorLogic.isEnabled(routine))
        routine.actions = []
        routine.showOnly = true
        XCTAssertFalse(WorkspaceGroupEditorLogic.showsControls(for: routine))
    }

    func testTogglingGroupPreservesExceptionsAndSteps() {
        let action = WorkspaceTabSetDraft.action([tabDraft()])
        var routine = WorkspaceRoutine(name: "Work", actions: [action], keepVisible: ["app.music", "app.chat"])
        WorkspaceGroupEditorLogic.setEnabled(true, in: &routine)
        XCTAssertTrue(WorkspaceGroupEditorLogic.isEnabled(routine))
        WorkspaceGroupEditorLogic.setEnabled(false, in: &routine)
        XCTAssertFalse(WorkspaceGroupEditorLogic.isEnabled(routine))
        XCTAssertEqual(routine.keepVisible, ["app.music", "app.chat"])
        XCTAssertEqual(routine.actions, [action])
        WorkspaceGroupEditorLogic.setEnabled(true, in: &routine)
        XCTAssertEqual(routine.keepVisible, ["app.music", "app.chat"])
    }

    func testGroupHelpTakesPrecedenceOverTabOnlyHelpAndNamesOtherMacs() {
        let routine = WorkspaceRoutine(name: "Work", actions: [WorkspaceTabSetDraft.action([tabDraft()])], showOnly: true)
        let help = WorkspaceGroupEditorLogic.runHelp(routine, otherMacs: ["Travel"])
        XCTAssertTrue(help.hasPrefix("Hides other apps"))
        XCTAssertTrue(help.contains("on this Mac and Travel"))
        XCTAssertTrue(help.contains("Undo brings hidden apps back"))
        XCTAssertTrue(help.contains("doesn't close tabs"))
        XCTAssertTrue(WorkspaceGroupEditorLogic.previewHelp(routine).contains("other apps will hide"))
        XCTAssertTrue(WorkspaceGroupEditorLogic.previewHelp(routine).contains("Nothing changes yet"))
    }

    func testOrdinaryHelpDescribesReuseAndUndoWithoutPromisingTabClosure() {
        var routine = WorkspaceRoutine(name: "Work", actions: [WorkspaceTabSetDraft.action([tabDraft()])])
        let help = WorkspaceGroupEditorLogic.runHelp(routine, otherMacs: [])
        XCTAssertTrue(help.contains("if still open, or opens them again"))
        XCTAssertFalse(help.contains("Hides other apps"))
        XCTAssertFalse(help.contains("on this Mac and"))
        XCTAssertTrue(WorkspaceGroupEditorLogic.previewHelp(routine).contains("open or come back"))
        routine.actions.append(.init(kind: .centerLastWindow))
        XCTAssertTrue(WorkspaceGroupEditorLogic.runHelp(routine, otherMacs: []).hasPrefix("Runs the steps now"))
        XCTAssertTrue(WorkspaceGroupEditorLogic.previewHelp(routine).contains("where each window will go"))
    }

    func testParkedNoticeDependsOnlyOnCountEvenWithoutRoutines() {
        XCTAssertNil(WorkspaceGroupEditorLogic.parkedNotice(0))
        XCTAssertNil(WorkspaceGroupEditorLogic.parkedNotice(-1))
        XCTAssertEqual(WorkspaceGroupEditorLogic.parkedNotice(1), "1 window is out of the way")
        XCTAssertEqual(WorkspaceGroupEditorLogic.parkedNotice(2), "2 windows are out of the way")
        XCTAssertEqual(WorkspaceTabWords.bringBack(1), "Bring back 1 window")
        XCTAssertEqual(WorkspaceTabWords.bringBack(2), "Bring back 2 windows")
    }

    func testChoosingAndClearingMonitorAlwaysSetsBothPlacementFields() {
        var draft = tabDraft()
        XCTAssertNil(draft.set.monitor)
        XCTAssertNil(draft.set.position)
        draft.chooseMonitor(.specific(id: "screen", name: "Desk"))
        XCTAssertEqual(draft.set.position, .full)
        draft.choosePosition(.leftHalf)
        XCTAssertEqual(draft.set.monitor, .specific(id: "screen", name: "Desk"))
        XCTAssertEqual(draft.set.position, .leftHalf)
        draft.chooseMonitor(.generic(.main))
        XCTAssertEqual(draft.set.position, .leftHalf)
        draft.chooseMonitor(nil)
        XCTAssertNil(draft.saved.monitor)
        XCTAssertNil(draft.saved.position)
        draft.choosePosition(.rightThird)
        XCTAssertEqual(draft.set.monitor, .generic(.main))
        XCTAssertEqual(draft.set.position, .rightThird)
    }

    func testPlacementSurvivesAddressEditingBrowserChangeAndSaving() {
        var draft = tabDraft()
        draft.chooseMonitor(.specific(id: "screen", name: "Desk"))
        draft.choosePosition(.leftHalf)
        draft.addressesText = "example.org\nexample.net"
        draft.chooseBrowser(.init(bundleID: "browser.other", name: "Other"))
        let action = WorkspaceTabSetDraft.action([draft])
        let saved = action.tabSets?.first
        XCTAssertEqual(saved?.monitor, .specific(id: "screen", name: "Desk"))
        XCTAssertEqual(saved?.position, .leftHalf)
        XCTAssertEqual(saved?.urls, ["https://example.org", "https://example.net"])
        XCTAssertEqual(WorkspaceTabSetDraft.editing(action.tabSets ?? []).first?.saved, saved)
    }

    func testMacChangeDropsSpecificMonitorButKeepsPositionAndBrowserDefault() {
        var placed = tabDraft()
        let monitor = WorkspaceMonitorChoice.specific(id: "studio-screen", name: "Desk")
        placed.chooseMonitor(monitor)
        placed.choosePosition(.topLeft)
        placed.chooseMac(mac, browsers: [])
        XCTAssertEqual(placed.set.monitor, monitor, "Reselecting the same Mac keeps its monitor")
        let remote = WorkspaceMacOption(id: "book", name: "Travel", online: false)
        placed.chooseMac(remote, browsers: [])
        XCTAssertEqual(placed.set.monitor, .generic(.main))
        XCTAssertEqual(placed.set.position, .topLeft)
        var unplaced = tabDraft()
        unplaced.chooseMac(remote, browsers: [])
        XCTAssertNil(unplaced.set.monitor)
        XCTAssertNil(unplaced.set.position)
    }

    func testMonitorChoicesUseSuppliedMacDisplaysAndKeepUnavailableSavedMonitor() {
        let studio = WorkspaceDisplay(id: "1", name: "Desk", stableUUID: "studio-screen")
        let travel = WorkspaceDisplay(id: "2", name: "Laptop", stableUUID: "travel-screen")
        let saved = WorkspaceMonitorChoice.specific(id: "unplugged", name: "Away")
        let generic = WorkspaceDisplayChoice.allCases.map { WorkspaceMonitorChoice.generic($0) }
        let studioChoices = WorkspaceEditorMonitorChoices.choices(displays: [studio, studio], saved: saved)
        XCTAssertEqual(studioChoices, generic + [.specific(id: "studio-screen", name: "Desk"), saved])
        let travelChoices = WorkspaceEditorMonitorChoices.choices(displays: [travel], saved: nil)
        XCTAssertFalse(travelChoices.contains(.specific(id: "studio-screen", name: "Desk")))
        XCTAssertEqual(travelChoices, generic + [.specific(id: "travel-screen", name: "Laptop")])
        XCTAssertEqual(WorkspaceEditorMonitorChoices.choices(displays: [], saved: saved), generic + [saved])
        XCTAssertEqual(WorkspaceEditorMonitorChoices.choices(displays: [studio], saved: .specific(id: "studio-screen", name: "Desk")),
                       generic + [.specific(id: "studio-screen", name: "Desk")])
        XCTAssertEqual(WorkspaceEditorMonitorChoices.choices(displays: [.init(id: "old", name: "Old build")], saved: nil), generic)
    }

    func testTabFooterExplainsReuseAndUndo() {
        XCTAssertEqual(WorkspaceTabSetEditor.footer,
                       "If this window is still open, running the routine usually brings it back instead of opening another. Undo doesn't close tabs.")
    }
}
