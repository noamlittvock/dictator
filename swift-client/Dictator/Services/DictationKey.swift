import CoreGraphics
import Foundation

/// The modifier key that starts dictation (Right Option by default) and the
/// rules for telling it apart from a character chord.
struct DictationKey: Equatable {
    static let rightOption = DictationKey(keyCode: 61)

    let keyCode: CGKeyCode

    init(keyCode: CGKeyCode) { self.keyCode = keyCode }

    /// The key from the saved setting, falling back to Right Option.
    init(setting: Int) {
        self.keyCode = (0...255).contains(setting) && setting != 0 ? CGKeyCode(setting) : 61
    }

    /// Modifier keys report through flag changes; every other key through
    /// key down and key up.
    var isModifier: Bool { [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode) }

    /// Short label for instructions, e.g. "Right ⌥".
    var symbolName: String {
        switch keyCode {
        case 58: "Left ⌥"
        case 61: "Right ⌥"
        case 54: "Right ⌘"
        case 55: "Left ⌘"
        case 59: "Left ⌃"
        case 62: "Right ⌃"
        case 56: "Left Shift"
        case 60: "Right Shift"
        case 63: "fn"
        default: WorkspaceHotkeyFormat.keyName(UInt32(keyCode))
        }
    }

    /// Full label for Settings, e.g. "Right ⌥ Option".
    var displayName: String {
        switch keyCode {
        case 58: "Left ⌥ Option"
        case 61: "Right ⌥ Option"
        case 54: "Right ⌘ Command"
        case 55: "Left ⌘ Command"
        case 59: "Left ⌃ Control"
        case 62: "Right ⌃ Control"
        case 56: "Left ⇧ Shift"
        case 60: "Right ⇧ Shift"
        case 63: "fn (Globe)"
        default: WorkspaceHotkeyFormat.keyName(UInt32(keyCode))
        }
    }

    /// Hardware-specific flag for this physical key (NX_DEVICE*KEYMASK).
    var deviceFlag: CGEventFlags {
        switch keyCode {
        case 58: CGEventFlags(rawValue: 0x20)       // Left Option
        case 61: CGEventFlags(rawValue: 0x40)       // Right Option
        case 54: CGEventFlags(rawValue: 0x10)       // Right Command
        case 55: CGEventFlags(rawValue: 0x08)       // Left Command
        case 59: CGEventFlags(rawValue: 0x01)       // Left Control
        case 62: CGEventFlags(rawValue: 0x2000)     // Right Control
        case 56: CGEventFlags(rawValue: 0x02)       // Left Shift
        case 60: CGEventFlags(rawValue: 0x04)       // Right Shift
        case 63: .maskSecondaryFn
        default: CGEventFlags(rawValue: 0)
        }
    }

    /// The generic modifier mask, used only when the keyboard does not
    /// report the hardware flag and the event is for this very key.
    var genericFlag: CGEventFlags {
        switch keyCode {
        case 58, 61: .maskAlternate
        case 54, 55: .maskCommand
        case 59, 62: .maskControl
        case 56, 60: .maskShift
        case 63: .maskSecondaryFn
        default: CGEventFlags(rawValue: 0)
        }
    }

    /// Is the key held, according to a flagsChanged event for `eventKeyCode`?
    func isHeld(flags: CGEventFlags, eventKeyCode: CGKeyCode) -> Bool {
        if deviceFlag.rawValue != 0, flags.contains(deviceFlag) { return true }
        return eventKeyCode == keyCode && genericFlag.rawValue != 0 && flags.contains(genericFlag)
    }

    /// Is the key held, according to the physical state (the watchdog)?
    func isHeldPhysically(flags: CGEventFlags) -> Bool {
        flags.contains(deviceFlag) || (genericFlag.rawValue != 0 && flags.contains(genericFlag))
    }
}

/// Decides when another key pressed during the hold means the user was typing
/// a character (Right Option + a key makes letters on Hebrew, Polish, German
/// and other layouts), not starting dictation.
enum DictationChord {
    /// How long after the key goes down another key still counts as a chord.
    /// Kept short on purpose: without a limit, any key pressed during a long
    /// hold-to-talk would silently discard the recording.
    static let window: TimeInterval = 1.5

    static func isCharacterChord(
        dictationHeld: Bool,
        secondsSincePress: TimeInterval,
        pressedKeyCode: CGKeyCode,
        trigger: KeyCombo,
        isSynthetic: Bool
    ) -> Bool {
        guard dictationHeld, !isSynthetic, trigger.isModifierOnly else { return false }
        guard !trigger.keyCodes.contains(pressedKeyCode), pressedKeyCode != 53 else { return false } // 53 = Esc
        return secondsSincePress <= window
    }
}

/// One key, or several held together: what starts dictation or runs a
/// command. Modifiers come first, then at most one regular key.
struct KeyCombo: Hashable {
    let keyCodes: [CGKeyCode]

    init(_ keyCodes: [CGKeyCode]) {
        var unique: [CGKeyCode] = []
        for code in keyCodes where !unique.contains(code) { unique.append(code) }
        self.keyCodes = unique.filter { DictationKey(keyCode: $0).isModifier }
            + unique.filter { !DictationKey(keyCode: $0).isModifier }
    }

    init(_ key: DictationKey) { self.init([key.keyCode]) }

    /// Reads a saved value. Nil when there is nothing usable.
    init?(stored: [Any]?) {
        let codes = (stored as? [Int] ?? []).filter { (0...255).contains($0) }.map { CGKeyCode($0) }
        guard !codes.isEmpty else { return nil }
        self.init(codes)
    }

    static func == (a: KeyCombo, b: KeyCombo) -> Bool { Set(a.keyCodes) == Set(b.keyCodes) }
    func hash(into hasher: inout Hasher) { hasher.combine(Set(keyCodes)) }

    var primary: CGKeyCode { keyCodes.first ?? DictationKey.rightOption.keyCode }
    var modifiers: [CGKeyCode] { keyCodes.filter { DictationKey(keyCode: $0).isModifier } }
    var regularKey: CGKeyCode? { keyCodes.last { !DictationKey(keyCode: $0).isModifier } }
    var isModifierOnly: Bool { regularKey == nil }

    /// Short label for instructions, e.g. "Right ⌥ + Right Shift".
    var symbolName: String { keyCodes.map { DictationKey(keyCode: $0).symbolName }.joined(separator: " + ") }
    /// Full label for Settings. One key keeps its long name.
    var displayName: String { keyCodes.count == 1 ? DictationKey(keyCode: primary).displayName : symbolName }

    func contains(_ other: KeyCombo) -> Bool { Set(keyCodes).isSuperset(of: other.keyCodes) }

    /// Are all the keys held, according to an event for `eventKeyCode`?
    func isHeld(flags: CGEventFlags, eventKeyCode: CGKeyCode, regularKeys: Set<CGKeyCode>) -> Bool {
        keyCodes.allSatisfy { code in
            let key = DictationKey(keyCode: code)
            return key.isModifier ? key.isHeld(flags: flags, eventKeyCode: eventKeyCode) : regularKeys.contains(code)
        }
    }

    /// Are all the keys held, according to the physical state (the watchdog)?
    func isHeldPhysically(flags: CGEventFlags, keyIsDown: (CGKeyCode) -> Bool) -> Bool {
        keyCodes.allSatisfy { code in
            let key = DictationKey(keyCode: code)
            return key.isModifier ? key.isHeldPhysically(flags: flags) : keyIsDown(code)
        }
    }

    /// The same keys as a keyboard shortcut, when they include a regular key.
    var hotkey: WorkspaceHotkey? {
        guard let regularKey else { return nil }
        let masks = WorkspaceHotkeyConflict.modifierKeys
        return WorkspaceHotkey(keyCode: UInt32(regularKey), modifiers: modifiers.reduce(0) { $0 | (masks[Int($1)] ?? 0) })
    }
}

/// The keys this Mac listens for.
struct HotkeyTriggers: Equatable {
    let dictation: KeyCombo
    let commands: KeyCombo
    /// Every key in either trigger. Stored, because the event tap reads it on every key press.
    let keyCodes: Set<CGKeyCode>
    /// The non-modifier keys in either trigger, such as F13.
    let regularKeys: Set<CGKeyCode>

    static let standard = HotkeyTriggers(dictation: KeyCombo(.rightOption))
    static var current: HotkeyTriggers { AppSettings.shared.hotkeyTriggers }

    /// With no choice of its own, Commands is the dictation keys plus a Shift key.
    init(dictation: KeyCombo, commands: KeyCombo? = nil) {
        self.dictation = dictation
        let extra = [60, 56, 61, 58].first { !dictation.keyCodes.contains($0) } ?? 60
        self.commands = commands ?? KeyCombo(dictation.keyCodes + [extra])
        keyCodes = Set(dictation.keyCodes + self.commands.keyCodes)
        regularKeys = Set([dictation.regularKey, self.commands.regularKey].compactMap { $0 })
    }


    func isHeldPhysically(flags: CGEventFlags, keyIsDown: (CGKeyCode) -> Bool) -> Bool {
        dictation.isHeldPhysically(flags: flags, keyIsDown: keyIsDown) || commands.isHeldPhysically(flags: flags, keyIsDown: keyIsDown)
    }

    /// Does this regular key, with the modifiers that are down, begin a trigger?
    func startsWith(regularKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        [dictation, commands].contains { combo in
            combo.regularKey == regularKey
                && combo.modifiers.allSatisfy { DictationKey(keyCode: $0).isHeld(flags: flags, eventKeyCode: regularKey) }
        }
    }
}

/// Turns the keys pressed in a recorder into a combination. Modifiers can be
/// pressed alone, so a combination ends when they are all released; a regular
/// key ends it at once.
struct KeyComboCapture {
    private var down: Set<CGKeyCode> = []
    private var pressed: [CGKeyCode] = []

    mutating func modifier(_ keyCode: CGKeyCode, isDown: Bool) -> KeyCombo? {
        if isDown {
            down.insert(keyCode)
            if !pressed.contains(keyCode) { pressed.append(keyCode) }
            return nil
        }
        down.remove(keyCode)
        return down.isEmpty && !pressed.isEmpty ? KeyCombo(pressed) : nil
    }

    func regularKey(_ keyCode: CGKeyCode) -> KeyCombo { KeyCombo(pressed + [keyCode]) }
}

/// Any key or combination can start Dictator, except where it couldn't work
/// or would take something away from the Mac.
enum KeyComboRules {
    enum Role { case dictation, commands }

    private static let capsLock: CGKeyCode = 57
    private static let esc: CGKeyCode = 53
    /// Keys that don't type anything, so they can stand alone.
    private static let freeKeys: Set<CGKeyCode> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
                                                   114, 115, 116, 119, 121]
    /// Modifiers that also take part in everyday typing and shortcuts.
    private static let busyKeys: Set<CGKeyCode> = [55, 59, 58, 56, 60]

    static func problem(_ combo: KeyCombo, role: Role, dictation: KeyCombo, customCommands: KeyCombo?, shortcuts: [WorkspaceHotkey]) -> String? {
        if combo.keyCodes.contains(capsLock) { return "Caps Lock can’t be held down, so it can’t start Dictator." }
        if combo.keyCodes.contains(esc) { return "Esc cancels a dictation. Choose a different key." }
        if let key = combo.regularKey, !freeKeys.contains(key), !combo.modifiers.contains(where: { ![56, 60].contains($0) }) {
            return "You’d lose that key for typing. Hold ⌃, ⌥ or ⌘ with it, or choose a key like F13."
        }
        switch role {
        case .dictation:
            if let customCommands, combo.contains(customCommands) { return "Those keys already run commands." }
        case .commands:
            if dictation.contains(combo) { return "Those keys already start dictation. Add a key, or choose another." }
        }
        if let hotkey = combo.hotkey {
            if let reserved = WorkspaceHotkeyConflict.reservedByMac.first(where: { $0.keyCode == hotkey.keyCode && $0.modifiers == hotkey.modifiers }) {
                return "macOS already uses these keys (\(reserved.what))."
            }
            if shortcuts.contains(hotkey) { return "A routine or command already uses these keys." }
        }
        return nil
    }

    /// Allowed, but worth knowing.
    static func caution(_ combo: KeyCombo) -> String? {
        combo.keyCodes.count == 1 && busyKeys.contains(combo.primary)
            ? "You also use this key for other things, so Dictator may start for a moment when you do."
            : nil
    }
}
