import XCTest
@testable import Dictator

/// The pure rules behind pasting: secure input, verification, and how long
/// to wait before the old clipboard comes back. No pasteboard is touched.
final class PasteDecisionTests: XCTestCase {
    private let catalog = ToolCatalog(
        version: 1, tools: [],
        hostApps: [
            HostApp(id: "terminal", name: "Terminal", kind: .terminal, bundleIDs: ["com.apple.Terminal"]),
            HostApp(id: "chrome", name: "Chrome", kind: .browser, bundleIDs: ["com.google.Chrome"]),
            HostApp(id: "code", name: "VS Code", kind: .editor, bundleIDs: ["com.microsoft.VSCode"])
        ]
    )

    func testSecureInputBlocksThePaste() {
        XCTAssertFalse(PasteDecision.shouldSendPaste(secureInputEnabled: true))
        XCTAssertTrue(PasteDecision.shouldSendPaste(secureInputEnabled: false))
        XCTAssertTrue(PasteDecision.secureInputReason.contains("on the clipboard"))
    }

    func testFinderWithoutAnEditableSnapshotUsesClipboardOnly() {
        XCTAssertEqual(PasteDecision.clipboardOnlyReason(
            frontmostBundleID: "com.apple.finder", frontmostProcessID: 100, snapshotProcessID: nil
        ), PasteDecision.finderTextFieldReason)
    }

    func testEditableFinderSearchOrRenameSnapshotCanPaste() {
        XCTAssertNil(PasteDecision.clipboardOnlyReason(
            frontmostBundleID: "com.apple.finder", frontmostProcessID: 100, snapshotProcessID: 100,
            focusedEditableFieldMatches: true
        ))
    }

    func testSnapshotFromAnotherProcessCannotAuthorizeFinderPaste() {
        for owner: Int32? in [200, 0, nil] {
            XCTAssertEqual(PasteDecision.clipboardOnlyReason(
                frontmostBundleID: "com.apple.finder", frontmostProcessID: 100, snapshotProcessID: owner,
                focusedEditableFieldMatches: true
            ), PasteDecision.finderTextFieldReason)
        }
        XCTAssertEqual(PasteDecision.clipboardOnlyReason(
            frontmostBundleID: "com.apple.finder", frontmostProcessID: nil, snapshotProcessID: 100,
            focusedEditableFieldMatches: true
        ), PasteDecision.finderTextFieldReason)
    }

    func testUnreadableOtherAppsRetainTheirBestEffortPaste() {
        for bundle: String? in [nil, "", "com.apple.TextEdit", "com.apple.Terminal", "com.google.Chrome", "example.unknown"] {
            XCTAssertNil(PasteDecision.clipboardOnlyReason(
                frontmostBundleID: bundle, frontmostProcessID: nil, snapshotProcessID: nil
            ), bundle ?? "unknown app")
        }
    }

    func testFinderBlockCopiesOriginalTextBeforeAnyEventAndDoesNotRestoreOverIt() {
        var clipboard = "prior clipboard marker"
        var posts = 0
        let outcome = PasteService.postPasteIfAllowed(
            "Synthetic dictation.", frontmostBundleID: "com.apple.finder", frontmostProcessID: 100,
            snapshotProcessID: nil, copy: { clipboard = $0 }, post: {
                posts += 1
                // A successful path would eventually restore this marker.
                clipboard = "prior clipboard marker"
                return true
            }
        )
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(clipboard, "Synthetic dictation.")
        guard case .clipboardOnly(let reason, let needsAccessibility) = outcome else {
            return XCTFail("Finder without a field must report clipboard fallback")
        }
        XCTAssertEqual(reason, PasteDecision.finderTextFieldReason)
        XCTAssertFalse(needsAccessibility)
    }

    func testFinalPreEventCheckBlocksFinderAfterTextEditSnapshot() {
        var copies: [String] = []
        var posts = 0
        let outcome = PasteService.postPasteIfAllowed(
            "Original recognized text.", frontmostBundleID: "com.apple.finder", frontmostProcessID: 100,
            snapshotProcessID: 200, copy: { copies.append($0) }, post: { posts += 1; return true }
        )
        XCTAssertNotNil(outcome)
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(copies, ["Original recognized text."])
    }

    func testEditableFinderAndUnknownAppReachTheExistingEventPath() {
        for context: (String?, Int32?, Int32?) in [("com.apple.finder", 100, 100), ("com.apple.Terminal", 200, nil), (nil, nil, nil)] {
            var copies = 0
            var posts = 0
            let outcome = PasteService.postPasteIfAllowed(
                "Synthetic text.", frontmostBundleID: context.0, frontmostProcessID: context.1,
                snapshotProcessID: context.2, isFocusedEditableField: { true }, copy: { _ in copies += 1 }, post: { posts += 1; return true }
            )
            XCTAssertNil(outcome)
            XCTAssertEqual(posts, 1)
            XCTAssertEqual(copies, 0)
        }
    }

    func testSameProcessFinderNeedsTheOriginalFieldStillFocusedAndEditable() {
        let snapshotField = "original Finder search field"
        for currentField: String? in [nil, "Finder file pane", "another Finder text field"] {
            var clipboard = "previous clipboard marker"
            var posted = false
            var focusChecks = 0
            let outcome = PasteService.postPasteIfAllowed(
                "Original recognized text.", frontmostBundleID: "com.apple.finder", frontmostProcessID: 100,
                snapshotProcessID: 100, isFocusedEditableField: {
                    focusChecks += 1
                    return currentField == snapshotField
                }, copy: { clipboard = $0 }, post: { posted = true; return true }
            )
            XCTAssertNotNil(outcome)
            XCTAssertEqual(focusChecks, 1)
            XCTAssertFalse(posted)
            XCTAssertEqual(clipboard, "Original recognized text.")
        }
    }

    func testUnchangedFocusedFinderFieldReachesEventButOtherAppsDoNotProbeIt() {
        for bundle: String? in ["com.apple.finder", "com.apple.Terminal", nil] {
            var calls: [String] = []
            let outcome = PasteService.postPasteIfAllowed(
                "Synthetic text.", frontmostBundleID: bundle, frontmostProcessID: 100,
                snapshotProcessID: 100, isFocusedEditableField: { calls.append("focused field"); return true },
                copy: { _ in calls.append("copy fallback") }, post: { calls.append("event"); return true }
            )
            XCTAssertNil(outcome)
            XCTAssertEqual(calls, bundle == "com.apple.finder" ? ["focused field", "event"] : ["event"])
        }
    }

    func testReadOnlyTextOrWritableNonTextElementDoesNotAuthorizeFinderPaste() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            XCTAssertFalse(PasteDecision.isEditableTextField(role: role, valueSettable: false, selectedTextSettable: false))
            XCTAssertTrue(PasteDecision.isEditableTextField(role: role, valueSettable: true, selectedTextSettable: false))
            XCTAssertTrue(PasteDecision.isEditableTextField(role: role, valueSettable: false, selectedTextSettable: true))
        }
        for role: String? in [nil, "AXOutline", "AXRow", "AXStaticText", "AXGroup"] {
            XCTAssertFalse(PasteDecision.isEditableTextField(role: role, valueSettable: true, selectedTextSettable: true))
        }
    }

    func testExistingEventCreationFailureRetainsTheClipboardFallback() {
        var clipboard = "Recognized text already on clipboard."
        var posts = 0
        let outcome = PasteService.postPasteIfAllowed(
            clipboard, frontmostBundleID: "com.apple.Terminal", frontmostProcessID: 200,
            snapshotProcessID: nil, copy: { clipboard = $0 }, post: { posts += 1; return false }
        )
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(clipboard, "Recognized text already on clipboard.")
        guard case .clipboardOnly(let reason, let needsAccessibility) = outcome else {
            return XCTFail("Event creation failure must keep the existing fallback")
        }
        XCTAssertTrue(reason.contains("couldn’t press ⌘V"))
        XCTAssertFalse(needsAccessibility)
    }

    func testUnchangedFieldInGoogleDocsIsNotAFailedPaste() {
        // Google Docs takes typing through a hidden field it empties after
        // each paste, so the field reads unchanged although the words landed.
        let landed = PasteDecision.insertionState(matchesExpected: false, snapshotValue: "", currentValue: "")
        XCTAssertEqual(landed, false)
        XCTAssertEqual(PasteDecision.verdict(confirmed: landed == true, changeCountMoved: false,
                                             frontmostBundleID: "com.google.Chrome", catalog: catalog), .pastedRestoreClipboard)
    }

    func testVerifiedPasteRestoresOldClipboard() {
        XCTAssertEqual(PasteDecision.verdict(confirmed: true, changeCountMoved: false, frontmostBundleID: "com.apple.TextEdit", catalog: catalog), .pastedRestoreClipboard)
    }

    func testUnverifiedPasteRestoresOnlyForCatalogHosts() {
        for id in ["com.apple.Terminal", "com.google.Chrome", "com.microsoft.VSCode"] {
            XCTAssertEqual(PasteDecision.verdict(confirmed: false, changeCountMoved: false,
                frontmostBundleID: id, catalog: catalog), .pastedRestoreClipboard, id)
        }
        for id: String? in ["com.apple.TextEdit", "com.tinyspeck.slackmacgap", "example.unknown", "", nil] {
            XCTAssertEqual(PasteDecision.verdict(confirmed: false, changeCountMoved: false,
                frontmostBundleID: id, catalog: catalog), .pastedLeaveClipboard, id ?? "unknown")
        }
    }

    func testUnverifiedPasteRestoresForAIApps() {
        for id in ["com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex"] {
            XCTAssertEqual(PasteDecision.verdict(confirmed: false, changeCountMoved: false,
                                                 frontmostBundleID: id, catalog: .shared), .pastedRestoreClipboard, id)
        }
    }

    func testConfirmedResultsAndMovedClipboardDoNotDependOnHost() {
        for id: String? in ["com.apple.Terminal", "com.apple.TextEdit", nil] {
            for moved in [false, true] {
                XCTAssertEqual(PasteDecision.verdict(confirmed: true, changeCountMoved: moved,
                    frontmostBundleID: id, catalog: catalog), moved ? .pastedLeaveClipboard : .pastedRestoreClipboard)
            }
            XCTAssertEqual(PasteDecision.verdict(confirmed: false, changeCountMoved: true,
                frontmostBundleID: id, catalog: catalog), .pastedLeaveClipboard)
        }
    }

    func testTerminalsBrowsersAndEditorsAreSlowHosts() {
        for id in ["com.apple.Terminal", "com.google.Chrome", "com.microsoft.VSCode"] {
            XCTAssertEqual(PasteDecision.hostSpeed(frontmostBundleID: id, catalog: catalog), .slow, id)
        }
    }

    func testPlainNativeAppIsFastAndUnknownIsSlow() {
        XCTAssertEqual(PasteDecision.hostSpeed(frontmostBundleID: "com.apple.Notes", catalog: catalog), .native)
        XCTAssertEqual(PasteDecision.hostSpeed(frontmostBundleID: nil, catalog: catalog), .slow)
    }

    func testElectronAndAppleAppsAreClassifiedConservatively() {
        let expected: [(String, PasteDecision.HostSpeed)] = [
            ("com.tinyspeck.slackmacgap", .slow),
            ("com.hnc.Discord", .slow),
            ("com.microsoft.VSCode", .slow),
            ("com.apple.Safari", .slow),
            ("com.apple.Terminal", .slow),
            ("com.apple.Notes", .native),
            ("com.apple.TextEdit", .native)
        ]
        let withSafari = ToolCatalog(version: 1, tools: [], hostApps: catalog.hostApps + [
            HostApp(id: "safari", name: "Safari", kind: .browser, bundleIDs: ["com.apple.Safari"])
        ])
        for (id, speed) in expected {
            XCTAssertEqual(PasteDecision.hostSpeed(frontmostBundleID: id, catalog: withSafari), speed, id)
        }
    }

    func testRestoreDelayIsLongerForSlowHosts() {
        XCTAssertEqual(PasteDecision.restoreDelay(for: .native), 0.1)
        XCTAssertGreaterThanOrEqual(PasteDecision.restoreDelay(for: .slow), 0.6)
    }
}
