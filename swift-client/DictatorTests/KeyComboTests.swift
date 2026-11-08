import CoreGraphics
import XCTest
@testable import Dictator

final class KeyComboTests: XCTestCase {
    private let f13: CGKeyCode = 105
    private let space: CGKeyCode = 49
    private let leftControl: CGKeyCode = 59

    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags
        return event
    }

    private func flags(_ code: CGKeyCode, _ flags: CGEventFlags) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
        event.type = .flagsChanged
        event.flags = flags
        return event
    }

    private func service(_ triggers: HotkeyTriggers) -> (HotkeyService, Counter) {
        let service = HotkeyService()
        service.triggers = triggers
        service.chordLatchKeyIsDown = { _ in false }
        service.dictationKeyIsDown = { false }
        let counter = Counter()
        service.onStart = { counter.starts += 1 }
        service.onStop = { _ in counter.stops += 1 }
        service.onVoiceCommandMode = { counter.commands += 1 }
        service.onCharacterChord = { counter.chords += 1 }
        return (service, counter)
    }

    private final class Counter { var starts = 0, stops = 0, commands = 0, chords = 0 }

    // MARK: Defaults

    func testTheStandardKeysStayRightOptionAndRightShift() {
        XCTAssertEqual(HotkeyTriggers.standard.dictation, KeyCombo([61]))
        XCTAssertEqual(HotkeyTriggers.standard.commands, KeyCombo([61, 60]))
        XCTAssertEqual(HotkeyTriggers.standard.commands.symbolName, "Right ⌥ + Right Shift")
    }

    func testCommandsFollowTheDictationKeysUntilChosen() {
        XCTAssertEqual(HotkeyTriggers(dictation: KeyCombo([54])).commands, KeyCombo([54, 60]))
        XCTAssertEqual(HotkeyTriggers(dictation: KeyCombo([f13])).commands.symbolName, "Right Shift + F13")
        XCTAssertEqual(HotkeyTriggers(dictation: KeyCombo([54]), commands: KeyCombo([f13])).commands, KeyCombo([f13]))
    }

    func testDictatingOnRightShiftStillLeavesADifferentCommandsKey() {
        let triggers = HotkeyTriggers(dictation: KeyCombo([60]))
        XCTAssertNotEqual(triggers.commands, triggers.dictation)
    }

    func testAKeySavedByAnOlderBuildStillWorks() {
        XCTAssertNil(KeyCombo(stored: nil))
        XCTAssertNil(KeyCombo(stored: []))
        XCTAssertEqual(KeyCombo(stored: [61, 60]), KeyCombo([60, 61]))
    }

    // MARK: Listening

    func testAFunctionKeyHoldsDictationAndNeverReachesTheApp() throws {
        let (service, count) = service(HotkeyTriggers(dictation: KeyCombo([f13])))
        XCTAssertTrue(service.handleEventForTesting(try key(f13, down: true)))
        XCTAssertEqual(count.starts, 1)
        let repeated = try key(f13, down: true)
        repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertTrue(service.handleEventForTesting(repeated))
        XCTAssertEqual(count.starts, 1)
        XCTAssertTrue(service.handleEventForTesting(try key(f13, down: false)))
        XCTAssertEqual(count.stops, 1)
        XCTAssertFalse(service.isPressed)
    }

    func testACombinationNeedsAllItsKeys() throws {
        let (service, count) = service(HotkeyTriggers(dictation: KeyCombo([leftControl, space])))
        XCTAssertFalse(service.handleEventForTesting(try key(space, down: true)), "Space alone types a space")
        XCTAssertEqual(count.starts, 0)
        _ = service.handleEventForTesting(try key(space, down: false))
        let control = CGEventFlags(rawValue: 0x1)
        _ = service.handleEventForTesting(try flags(leftControl, control))
        XCTAssertEqual(count.starts, 0)
        XCTAssertTrue(service.handleEventForTesting(try key(space, down: true, flags: control)))
        XCTAssertEqual(count.starts, 1)
        XCTAssertTrue(service.handleEventForTesting(try key(space, down: false, flags: control)))
        XCTAssertEqual(count.stops, 1)
    }

    func testTheOtherSidesModifierDoesNotCount() throws {
        let (service, count) = service(HotkeyTriggers(dictation: KeyCombo([leftControl, space])))
        let rightControl = CGEventFlags(rawValue: 0x2000).union(.maskControl)
        XCTAssertFalse(service.handleEventForTesting(try key(space, down: true, flags: rightControl)))
        XCTAssertEqual(count.starts, 0)
    }

    func testAKeyOfItsOwnStartsACommandStraightAway() throws {
        let (service, count) = service(HotkeyTriggers(dictation: KeyCombo([61]), commands: KeyCombo([f13])))
        XCTAssertTrue(service.handleEventForTesting(try key(f13, down: true)))
        XCTAssertEqual(count.starts, 1)
        XCTAssertEqual(count.commands, 1)
        XCTAssertTrue(service.voiceCommandMode)
        _ = service.handleEventForTesting(try key(f13, down: false))
        XCTAssertEqual(count.stops, 1)
    }

    func testAddingAKeyToDictationStillTurnsItIntoACommand() throws {
        let (service, count) = service(.standard)
        let option = CGEventFlags(rawValue: 0x40)
        _ = service.handleEventForTesting(try flags(61, option))
        XCTAssertEqual(count.commands, 0)
        _ = service.handleEventForTesting(try flags(60, option.union(CGEventFlags(rawValue: 0x04))))
        XCTAssertEqual(count.starts, 1)
        XCTAssertEqual(count.commands, 1)
        _ = service.handleEventForTesting(try flags(61, []))
        XCTAssertEqual(count.stops, 1)
    }

    func testRightShiftAloneStillDoesNothing() throws {
        let (service, count) = service(.standard)
        _ = service.handleEventForTesting(try flags(60, CGEventFlags(rawValue: 0x04)))
        XCTAssertEqual(count.starts, 0)
    }

    func testOtherKeysDuringAFunctionKeyHoldKeepTheRecording() throws {
        let (service, count) = service(HotkeyTriggers(dictation: KeyCombo([f13])))
        _ = service.handleEventForTesting(try key(f13, down: true))
        _ = service.handleEventForTesting(try key(0, down: true))
        XCTAssertTrue(service.isPressed)
        XCTAssertEqual(count.chords, 0)
    }

    func testRecordingLetsTheKeyThrough() throws {
        let (service, count) = service(HotkeyTriggers(dictation: KeyCombo([f13])))
        HotkeyService.isRecordingWorkspaceShortcut = true
        defer { HotkeyService.isRecordingWorkspaceShortcut = false }
        XCTAssertFalse(service.handleEventForTesting(try key(f13, down: true)))
        XCTAssertEqual(count.starts, 0)
    }

    func testTheWatchdogStopsAFunctionKeyWhoseReleaseWasLost() throws {
        let triggers = HotkeyTriggers(dictation: KeyCombo([f13]))
        XCTAssertTrue(triggers.isHeldPhysically(flags: []) { $0 == 105 })
        XCTAssertFalse(triggers.isHeldPhysically(flags: []) { _ in false })
    }

    // MARK: Recording

    func testCapturingModifiersWaitsForAllOfThemToBeReleased() {
        var capture = KeyComboCapture()
        XCTAssertNil(capture.modifier(61, isDown: true))
        XCTAssertNil(capture.modifier(60, isDown: true))
        XCTAssertNil(capture.modifier(60, isDown: false))
        XCTAssertEqual(capture.modifier(61, isDown: false), KeyCombo([61, 60]))
    }

    func testCapturingARegularKeyEndsAtOnce() {
        var capture = KeyComboCapture()
        _ = capture.modifier(59, isDown: true)
        XCTAssertEqual(capture.regularKey(49), KeyCombo([59, 49]))
    }

    // MARK: Rules

    private func problem(_ combo: KeyCombo, _ role: KeyComboRules.Role = .dictation, custom: KeyCombo? = nil, shortcuts: [WorkspaceHotkey] = []) -> String? {
        KeyComboRules.problem(combo, role: role, dictation: KeyCombo([61]), customCommands: custom, shortcuts: shortcuts)
    }

    func testAnythingUsableIsAllowed() {
        for combo in [KeyCombo([54]), KeyCombo([55]), KeyCombo([63]), KeyCombo([f13]), KeyCombo([96]), KeyCombo([59, 49]), KeyCombo([61, 58]), KeyCombo([62, 0])] {
            XCTAssertNil(problem(combo), combo.symbolName)
        }
    }

    func testKeysThatCouldNotWorkAreRefusedWithAReason() {
        XCTAssertNotNil(problem(KeyCombo([57])), "Caps Lock")
        XCTAssertNotNil(problem(KeyCombo([53])), "Esc")
        XCTAssertNotNil(problem(KeyCombo([0])), "a letter")
        XCTAssertNotNil(problem(KeyCombo([49])), "Space")
        XCTAssertNotNil(problem(KeyCombo([60, 0])), "Shift + a letter is a capital")
    }

    func testTheTwoTriggersCannotOverlapTheWrongWay() {
        XCTAssertNotNil(problem(KeyCombo([61]), .commands), "same as dictation")
        XCTAssertNil(problem(KeyCombo([61, 60]), .commands), "dictation plus a key")
        XCTAssertNil(problem(KeyCombo([f13]), .commands), "a key of its own")
        XCTAssertNotNil(problem(KeyCombo([f13]), .dictation, custom: KeyCombo([f13])))
    }

    func testMacAndRoutineShortcutsAreNotTaken() {
        XCTAssertNotNil(problem(KeyCombo([59, 54, 49])), "⌃⌘Space is the emoji picker")
        let routine = WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.control | WorkspaceHotkey.option)
        XCTAssertNotNil(problem(KeyCombo([59, 58, 15]), shortcuts: [routine]))
    }

    func testKeysUsedForOtherThingsGetACaution() {
        XCTAssertNotNil(KeyComboRules.caution(KeyCombo([55])))
        XCTAssertNil(KeyComboRules.caution(KeyCombo([61])))
        XCTAssertNil(KeyComboRules.caution(KeyCombo([f13])))
    }

    func testRoutineShortcutsCannotUseAWholeTrigger() {
        let triggers = HotkeyTriggers(dictation: KeyCombo([59, 49]))
        let same = WorkspaceHotkey(keyCode: 49, modifiers: WorkspaceHotkey.control)
        XCTAssertEqual(WorkspaceHotkeyConflict.problem(for: same, routineID: nil, routines: [], triggers: triggers), WorkspaceHotkeyConflict.dictationMessage)
    }
}
