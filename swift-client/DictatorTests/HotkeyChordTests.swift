import XCTest
@testable import Dictator

/// The dictation key setting and the "was that a typed character?" rule.
final class HotkeyChordTests: XCTestCase {
    func testDefaultSettingIsRightOption() {
        XCTAssertEqual(DictationKey(setting: 61), .rightOption)
        XCTAssertEqual(DictationKey(setting: 0), .rightOption)
        XCTAssertEqual(DictationKey(setting: -4), .rightOption)
    }

    func testChosenKeyIsMatchedByItsOwnFlag() {
        let leftOption = DictationKey(setting: 58)
        XCTAssertTrue(leftOption.isHeld(flags: CGEventFlags(rawValue: 0x20), eventKeyCode: 58))
        XCTAssertFalse(leftOption.isHeld(flags: CGEventFlags(rawValue: 0x40), eventKeyCode: 61), "Right Option must not trigger Left Option")
        XCTAssertTrue(DictationKey.rightOption.isHeld(flags: CGEventFlags(rawValue: 0x40), eventKeyCode: 61))
    }

    func testGenericFlagCountsOnlyForTheKeysOwnEvent() {
        let key = DictationKey.rightOption
        XCTAssertTrue(key.isHeld(flags: .maskAlternate, eventKeyCode: 61))
        XCTAssertFalse(key.isHeld(flags: .maskAlternate, eventKeyCode: 58))
    }

    func testAnotherKeyDuringTheHoldIsACharacterChord() {
        XCTAssertTrue(DictationChord.isCharacterChord(
            dictationHeld: true, secondsSincePress: 0.2, pressedKeyCode: 0,
            trigger: KeyCombo(.rightOption), isSynthetic: false))
    }

    func testEscapeOrLateKeyOrNoHoldIsNotAChord() {
        let key = DictationKey.rightOption
        XCTAssertFalse(DictationChord.isCharacterChord(dictationHeld: true, secondsSincePress: 0.1, pressedKeyCode: 53, trigger: KeyCombo(key), isSynthetic: false))
        XCTAssertFalse(DictationChord.isCharacterChord(dictationHeld: true, secondsSincePress: 10, pressedKeyCode: 0, trigger: KeyCombo(key), isSynthetic: false))
        XCTAssertFalse(DictationChord.isCharacterChord(dictationHeld: false, secondsSincePress: 0.1, pressedKeyCode: 0, trigger: KeyCombo(key), isSynthetic: false))
        XCTAssertFalse(DictationChord.isCharacterChord(dictationHeld: true, secondsSincePress: 0.1, pressedKeyCode: 0, trigger: KeyCombo(key), isSynthetic: true))
    }

    func testLostKeyUpDoesNotLeaveTheNextPressIgnored() throws {
        let service = HotkeyService()
        var started = 0
        service.onStart = { started += 1 }
        service.triggers = .standard
        var keyDown = true
        service.chordLatchKeyIsDown = { _ in keyDown }

        let down = try XCTUnwrap(CGEvent(source: nil))
        down.type = .flagsChanged
        down.setIntegerValueField(.keyboardEventKeycode, value: 61)
        down.flags = CGEventFlags(rawValue: 0x40 | CGEventFlags.maskAlternate.rawValue)
        service.handleEventForTesting(down)
        service.stopModifierWatchdog()
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        service.handleEventForTesting(key) // chord: latched
        XCTAssertEqual(started, 1)

        // The key-up never arrives, but the key is physically up now.
        keyDown = false
        service.handleEventForTesting(down) // fresh press
        XCTAssertEqual(started, 2)
        service.stopModifierWatchdog()
    }

    func testChordDropsTheSessionQuietlyAndLetsTheKeyThrough() throws {
        let service = HotkeyService()
        var started = 0, cancelled = 0, stopped = 0
        service.onStart = { started += 1 }
        service.onCharacterChord = { cancelled += 1 }
        service.onStop = { _ in stopped += 1 }
        service.triggers = .standard
        service.chordLatchKeyIsDown = { _ in true } // the key really is still held

        let down = try XCTUnwrap(CGEvent(source: nil))
        down.type = .flagsChanged
        down.setIntegerValueField(.keyboardEventKeycode, value: 61)
        down.flags = CGEventFlags(rawValue: 0x40 | CGEventFlags.maskAlternate.rawValue)
        XCTAssertFalse(service.handleEventForTesting(down))
        XCTAssertEqual(started, 1)
        service.stopModifierWatchdog()

        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        XCTAssertFalse(service.handleEventForTesting(key), "the key must pass through")
        XCTAssertEqual(cancelled, 1)
        XCTAssertFalse(service.isPressed)

        // Still holding Right Option with a flags change must not restart.
        service.handleEventForTesting(down)
        XCTAssertEqual(started, 1)

        // Letting go ends quietly: no stop for the dropped session.
        let up = try XCTUnwrap(CGEvent(source: nil))
        up.type = .flagsChanged
        up.setIntegerValueField(.keyboardEventKeycode, value: 61)
        up.flags = []
        service.handleEventForTesting(up)
        XCTAssertEqual(stopped, 0)

        // And the next real press works again.
        service.handleEventForTesting(down)
        XCTAssertEqual(started, 2)
        service.stopModifierWatchdog()
    }

    // MARK: Esc during a voice-launch pause

    func testEscIsHeldBackOnlyWhileAVoiceLaunchPauseOwnsIt() throws {
        let service = HotkeyService()
        let esc = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        XCTAssertFalse(service.handleEventForTesting(esc), "no pause: Esc reaches the app in front")
        var cancelled = 0
        let token = VoiceLaunchEscapeWatch.register { cancelled += 1 }
        XCTAssertTrue(service.handleEventForTesting(esc), "the pause owns it")
        XCTAssertEqual(cancelled, 1)
        VoiceLaunchEscapeWatch.unregister(token)
        XCTAssertFalse(service.handleEventForTesting(esc))
    }
}
