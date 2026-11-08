import Foundation

/// The pure rules behind `PasteService`: when not to press ⌘V, what to do
/// after it, and how long to wait before putting the old clipboard back.
/// Kept free of AppKit so they can be tested with plain values.
enum PasteDecision {
    /// What kind of app has focus, as far as pasting is concerned.
    enum HostSpeed: Equatable {
        /// Ordinary native app: the paste lands almost at once.
        case native
        /// Electron, terminal, editor or browser: the paste can land late.
        case slow
    }

    static let nativeRestoreDelay: TimeInterval = 0.1
    static let slowRestoreDelay: TimeInterval = 0.8
    /// How long we keep checking that a verified paste really landed.
    static let verificationWindow: TimeInterval = 0.4

    static let secureInputReason =
        "Your text is on the clipboard. Press \u{2318}V to paste it - a password field, or an app protecting what you type, is blocking Dictator."
    static let finderTextFieldReason =
        "Dictator couldn’t confirm a text field in Finder. Your text is on the clipboard."

    /// Finder can turn a text paste into a file. Only a readable insertion
    /// snapshot still directly focused and editable in its current process is safe there. Other apps retain
    /// their existing best-effort paste when Accessibility cannot read a field.
    static func clipboardOnlyReason(
        frontmostBundleID: String?, frontmostProcessID: Int32?, snapshotProcessID: Int32?,
        focusedEditableFieldMatches: Bool = false
    ) -> String? {
        guard frontmostBundleID == "com.apple.finder" else { return nil }
        guard let frontmostProcessID, frontmostProcessID > 0,
              snapshotProcessID == frontmostProcessID,
              focusedEditableFieldMatches else { return finderTextFieldReason }
        return nil
    }

    /// A selectable text value alone is not an editable field (for example,
    /// Finder’s file names). The focused element must report a text role and
    /// a writable text attribute, never just a writable selection range.
    static func isEditableTextField(role: String?, valueSettable: Bool, selectedTextSettable: Bool) -> Bool {
        guard let role, ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) else { return false }
        return valueSettable || selectedTextSettable
    }

    /// Classify the frontmost app by its bundle id. Terminals and browsers in
    /// the tool catalog are slow even when they are Apple apps (Safari, Terminal).
    static func hostSpeed(frontmostBundleID: String?, catalog: ToolCatalog) -> HostSpeed {
        guard let id = frontmostBundleID, !id.isEmpty else { return .slow }
        if catalog.hostApp(bundleID: id) != nil { return .slow }
        // Conservative: only Apple's own apps are treated as fast. Slack,
        // Discord, VS Code and every other Electron or web-based app are slow.
        return id.hasPrefix("com.apple.") ? .native : .slow
    }

    static func restoreDelay(for speed: HostSpeed) -> TimeInterval {
        speed == .native ? nativeRestoreDelay : slowRestoreDelay
    }

    /// Should we press ⌘V at all? Secure input swallows synthetic keys.
    static func shouldSendPaste(secureInputEnabled: Bool) -> Bool {
        !secureInputEnabled
    }

    /// What the field shows after the paste. True when it holds exactly what
    /// we expect, or something different from before (a destination that
    /// uppercases, trims or curls quotes still took the paste). False when
    /// the value is unchanged, nil when it can't be read. Only true confirms
    /// the paste: an unchanged field doesn't prove it missed. Google Docs
    /// takes typing through a hidden field it empties after every paste, and
    /// web apps can update the field after the check has ended.
    static func insertionState(matchesExpected: Bool, snapshotValue: String, currentValue: String?) -> Bool? {
        if matchesExpected { return true }
        guard let currentValue else { return nil }
        return currentValue != snapshotValue
    }

    enum Verdict: Equatable {
        /// Put the old clipboard back.
        case pastedRestoreClipboard
        /// Leave the words on the clipboard: the clipboard changed under us,
        /// or the paste is unconfirmed in an app that may have missed it.
        case pastedLeaveClipboard
    }

    /// Decide after the paste whether the old clipboard comes back.
    /// `confirmed` is true only when the field showed the paste.
    static func verdict(
        confirmed: Bool, changeCountMoved: Bool, frontmostBundleID: String?, catalog: ToolCatalog
    ) -> Verdict {
        if changeCountMoved { return .pastedLeaveClipboard }
        if confirmed { return .pastedRestoreClipboard }
        // Terminals, editors, browsers and AI apps take a paste reliably even
        // when it can't be confirmed. Elsewhere the words stay on the
        // clipboard in case the paste missed.
        guard let id = frontmostBundleID,
              catalog.hostApp(bundleID: id) != nil || catalog.tool(forBundleID: id) != nil else {
            return .pastedLeaveClipboard
        }
        return .pastedRestoreClipboard
    }
}
