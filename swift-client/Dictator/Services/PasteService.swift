import AppKit
import Carbon.HIToolbox
import Foundation

/// Types text by pasting it: stashes the clipboard, pastes with ⌘V, and
/// puts the clipboard back.
enum PasteService {
    private static let vkAnsiV: CGKeyCode = 9 // Carbon kVK_ANSI_V
    private static let postEventSettleInterval: TimeInterval = 0.1

    /// Marker written to our synthetic ⌘V's `eventSourceUserData` field so
    /// `HotkeyService`'s tap can tell "we just typed this" apart from a real
    /// user ⌘V — otherwise our own paste would look like local typing
    /// activity and wrongly claim focus for this machine mid cross-machine
    /// handoff. "DICT" as ASCII, packed big-endian.
    static let syntheticEventTag: Int64 = 0x44494354 // "DICT"

    /// Private event source dedicated to our synthetic keystrokes. `.privateState`
    /// keeps it isolated from the real HID/session event state, and reusing one
    /// instance (rather than `nil`, which posts as the current session's
    /// default source) is what lets us stamp `eventSourceUserData` below.
    private static let syntheticEventSource = CGEventSource(stateID: .privateState)

    /// True if `event` was tagged by `postCmdV()` below — i.e. it's our own
    /// synthetic paste, not the user's keyboard.
    static func isSyntheticEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticEventTag
    }

    enum Outcome {
        case pasted
        /// Injection was impossible or could not be proven. The text is left
        /// on the clipboard and the reason is safe to show to the user.
        case clipboardOnly(String, needsAccessibility: Bool)
    }

    /// Stash → write → ⌘V → settle → restore.
    ///
    /// With `joiningPrecedingText`, the text is first joined to what's
    /// already before the caret (`InsertionSeam`), read from the same
    /// snapshot that verifies the paste. Fields that expose no text get
    /// `text` as it is.
    @discardableResult
    static func paste(_ text: String, joiningPrecedingText: Bool = false, expectedBundleID: String? = nil) -> Outcome {
        // Posting a synthetic Cmd+V needs Accessibility (kTCCServicePostEvent).
        // Input Monitoring is enough to hear the hotkey but not to inject the
        // keystroke, so this check is not redundant with the hotkey tap. Without
        // it the paste silently no-ops and the deferred restore wipes the
        // transcription off the clipboard 80ms later — the user loses the text
        // with no indication anything went wrong.
        guard CGPreflightPostEventAccess() else {
            writePasteboard(text)  // deliberately not restored: this is the fallback
            NSLog("[Paste] no post-event access; left %d chars on the clipboard", text.count)
            HotkeyService.recordDiagnostics(
                "paste BLOCKED postEventAccess=false chars=\(text.count) left-on-clipboard"
            )
            return .clipboardOnly(
                "Dictator needs Accessibility permission to type for you. Your text is on the clipboard.",
                needsAccessibility: true
            )
        }

        // Password fields and other secure input swallow synthetic keys, so a
        // ⌘V would vanish. Leave the text on the clipboard instead.
        guard PasteDecision.shouldSendPaste(secureInputEnabled: IsSecureEventInputEnabled()) else {
            writePasteboard(text)
            HotkeyService.recordDiagnostics("paste BLOCKED secure-input chars=\(text.count) left-on-clipboard")
            return .clipboardOnly(PasteDecision.secureInputReason, needsAccessibility: false)
        }

        let insertionSnapshot = CaretLocator.textInsertionSnapshot()
        // Check after the AX probe before reading any insertion context from
        // the current app. This also avoids copying a joined payload from an
        // app that was never the requested destination.
        if let refused = refuseUnlessFrontmost(expectedBundleID, text: text) { return refused }

        let probedApp = NSWorkspace.shared.frontmostApplication
        if let outcome = copyIfNonEditableFinder(
            text, frontmostBundleID: probedApp?.bundleIdentifier,
            frontmostProcessID: probedApp?.processIdentifier,
            snapshotProcessID: insertionSnapshot?.processID,
            isFocusedEditableField: { CaretLocator.isFocusedEditableTarget(insertionSnapshot, expectedProcessID: probedApp?.processIdentifier) },
            copy: writePasteboard
        ) {
            HotkeyService.recordDiagnostics("paste BLOCKED Finder-without-editable-field chars=\(text.count) left-on-clipboard")
            return outcome
        }

        let payload = joiningPrecedingText
            ? InsertionSeam.join(text, after: insertionSnapshot?.precedingText)
            : text
        let speed = PasteDecision.hostSpeed(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            catalog: ToolCatalog.shared
        )
        let stash = stashPasteboard()
        writePasteboard(payload)
        let pasteboardWriteCount = NSPasteboard.general.changeCount

        // The AX insertion probe above can take time. Check after it and
        // immediately before posting ⌘V so a focus change cannot send the
        // words to a different app. Keep the payload on the clipboard on a
        // mismatch.
        if let refused = refuseUnlessFrontmost(expectedBundleID, text: text) { return refused }

        // Recheck the actual app immediately before the event. A readable
        // snapshot from TextEdit must not authorize a later paste in Finder.
        let pasteApp = NSWorkspace.shared.frontmostApplication
        if let outcome = postPasteIfAllowed(
            text, frontmostBundleID: pasteApp?.bundleIdentifier,
            frontmostProcessID: pasteApp?.processIdentifier,
            snapshotProcessID: insertionSnapshot?.processID,
            isFocusedEditableField: { CaretLocator.isFocusedEditableTarget(insertionSnapshot, expectedProcessID: pasteApp?.processIdentifier) },
            copy: writePasteboard, post: postCmdV
        ) {
            HotkeyService.recordDiagnostics("paste BLOCKED before-event chars=\(text.count) left-on-clipboard")
            return outcome
        }

        Thread.sleep(forTimeInterval: postEventSettleInterval)
        var confirmed = false
        if let insertionSnapshot {
            // Give slow fields a short window to show the text.
            let deadline = Date().addingTimeInterval(PasteDecision.verificationWindow)
            func state() -> Bool? { CaretLocator.insertionState(payload, from: insertionSnapshot) }
            var landed = state()
            while landed == false && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                landed = state()
            }
            confirmed = landed == true
            let field = landed.map { $0 ? "changed" : "unchanged" } ?? "unreadable"
            HotkeyService.recordDiagnostics("paste confirmed=\(confirmed) field=\(field) chars=\(payload.count)")
        } else {
            HotkeyService.recordDiagnostics("paste confirmed=false snapshot=none chars=\(payload.count)")
        }
        if !confirmed {
            // Unconfirmed (no snapshot, or the field is unchanged or
            // unreadable): wait longer in slow apps before the old clipboard
            // comes back, so a late paste still gets our text.
            let extra = PasteDecision.restoreDelay(for: speed) - postEventSettleInterval
            if extra > 0 { Thread.sleep(forTimeInterval: extra) }
        }

        // Restore only if neither the destination nor the user has changed the
        // pasteboard since Dictator wrote its payload.
        switch PasteDecision.verdict(
            confirmed: confirmed,
            changeCountMoved: NSPasteboard.general.changeCount != pasteboardWriteCount,
            frontmostBundleID: pasteApp?.bundleIdentifier, catalog: ToolCatalog.shared
        ) {
        case .pastedRestoreClipboard:
            restorePasteboard(stash)
        case .pastedLeaveClipboard:
            break
        }
        return .pasted
    }

    /// Leaves `text` on the clipboard and says so when `expectedBundleID`
    /// is set and isn't the frontmost app; nil when the paste may go on.
    private static func refuseUnlessFrontmost(_ expectedBundleID: String?, text: String) -> Outcome? {
        guard let expectedBundleID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != expectedBundleID else { return nil }
        writePasteboard(text)
        let name = VoiceAppNames.name(for: expectedBundleID)
            ?? expectedBundleID.split(separator: ".").last.map(String.init) ?? expectedBundleID
        HotkeyService.recordDiagnostics("paste BLOCKED frontmost-app-mismatch expected=\(expectedBundleID) chars=\(text.count) left-on-clipboard")
        return .clipboardOnly("\(name) isn’t in front. Nothing was typed.", needsAccessibility: false)
    }

    /// Bounded pre-event seam: tests substitute only clipboard/event effects;
    /// they never request permissions, probe AX, or touch the real pasteboard.
    /// Nil means the event was posted; insertion verification still follows.
    static func postPasteIfAllowed(
        _ text: String, frontmostBundleID: String?, frontmostProcessID: Int32?,
        snapshotProcessID: Int32?, isFocusedEditableField: () -> Bool = { false },
        copy: (String) -> Void, post: () -> Bool
    ) -> Outcome? {
        if let outcome = copyIfNonEditableFinder(
            text, frontmostBundleID: frontmostBundleID, frontmostProcessID: frontmostProcessID,
            snapshotProcessID: snapshotProcessID, isFocusedEditableField: isFocusedEditableField, copy: copy
        ) { return outcome }
        guard post() else {
            return .clipboardOnly(
                "Dictator couldn’t press ⌘V for you. Use Copy Last Transcription in Dictator’s menu.",
                needsAccessibility: false
            )
        }
        return nil
    }

    private static func copyIfNonEditableFinder(
        _ text: String, frontmostBundleID: String?, frontmostProcessID: Int32?,
        snapshotProcessID: Int32?, isFocusedEditableField: () -> Bool, copy: (String) -> Void
    ) -> Outcome? {
        // Only Finder receives the stricter AX check; unknown terminal/web
        // fields keep their existing best-effort path without extra probes.
        let focusedFieldMatches = frontmostBundleID == "com.apple.finder" ? isFocusedEditableField() : false
        guard let reason = PasteDecision.clipboardOnlyReason(
            frontmostBundleID: frontmostBundleID, frontmostProcessID: frontmostProcessID,
            snapshotProcessID: snapshotProcessID, focusedEditableFieldMatches: focusedFieldMatches
        ) else { return nil }
        copy(text)
        return .clipboardOnly(reason, needsAccessibility: false)
    }

    // MARK: - Private

    private static func stashPasteboard() -> [(NSPasteboard.PasteboardType, Data)] {
        let pb = NSPasteboard.general
        guard let types = pb.types else { return [] }

        var stash: [(NSPasteboard.PasteboardType, Data)] = []
        for type in types {
            if let data = pb.data(forType: type) {
                stash.append((type, data))
            }
        }
        return stash
    }

    private static func restorePasteboard(_ stash: [(NSPasteboard.PasteboardType, Data)]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        for (type, data) in stash {
            pb.setData(data, forType: type)
        }
    }

    /// Puts `text` on the clipboard and types nothing.
    static func copyToClipboard(_ text: String) {
        writePasteboard(text)
    }

    private static func writePasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Post Cmd+V keystroke to frontmost app via CGEvent.
    /// Requires Accessibility permission.
    private static func postCmdV() -> Bool {
        guard let downEvent = CGEvent(keyboardEventSource: syntheticEventSource, virtualKey: vkAnsiV, keyDown: true),
              let upEvent = CGEvent(keyboardEventSource: syntheticEventSource, virtualKey: vkAnsiV, keyDown: false)
        else { return false }
        downEvent.flags = .maskCommand
        downEvent.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        downEvent.post(tap: .cgSessionEventTap)

        upEvent.flags = .maskCommand
        upEvent.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        upEvent.post(tap: .cgSessionEventTap)
        return true
    }
}
