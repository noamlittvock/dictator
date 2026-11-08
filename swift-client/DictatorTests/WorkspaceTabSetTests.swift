import XCTest
@testable import Dictator

final class WorkspaceTabSetTests: XCTestCase {
    private func tabSet(id: String = "window", macID: String = "mini", browser: String = "com.example.browser") -> WorkspaceTabSet {
        WorkspaceTabSet(id: id, macID: macID, macName: "Studio", browserBundleID: browser,
                        browserName: "Browser", urls: ["https://example.com/a"])
    }

    private func config(_ action: WorkspaceAction) -> WorkspaceLaunchConfig {
        WorkspaceLaunchConfig(routines: [WorkspaceRoutine(id: "routine", name: "Desk", actions: [action])])
    }

    private func layout() -> WorkspaceSavedLayout {
        WorkspaceSavedLayout(macName: "Studio", capturedAt: Date(timeIntervalSinceReferenceDate: 0),
                             screens: [.init(id: "screen", visibleFrame: .init(width: 1200, height: 900), isMain: true)],
                             windows: [.init(bundleID: "editor", appName: "Editor", screenID: "screen",
                                             place: .init(width: 0.5, height: 1))])
    }

    func testNormalizationUsesWebSchemesAndKeepsPortsPathsQueriesAndFragments() {
        let cases = [
            ("example.com", "https://example.com"),
            ("example.com:8080/a?b=1#c", "https://example.com:8080/a?b=1#c"),
            ("localhost:3000", "http://localhost:3000"),
            ("LOCALHOST:3000/x", "http://LOCALHOST:3000/x"),
            ("127.0.0.1:8000/x", "http://127.0.0.1:8000/x"),
            ("localhost", "http://localhost"),
            ("127.0.0.1", "http://127.0.0.1"),
            ("HTTP://example.com/a", "http://example.com/a"),
            ("hTtPs://example.com/a", "https://example.com/a"),
            ("https://localhost:3000", "https://localhost:3000"),
            ("https://[::1]:8000/x", "https://[::1]:8000/x")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(WorkspaceTabAddress.normalize(input), expected, input)
            XCTAssertTrue(WorkspaceTabAddress.isAllowed(expected), expected)
        }
    }

    func testNormalizationRejectsSchemesFlagsCredentialsWhitespaceAndControls() {
        let rejected = ["", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "chrome://settings",
                        "mailto:a@b.c", "about:blank", "--incognito", "-x", "https://user:pw@host.com",
                        "https://user@host.com", "https://", "https:///path", "http:example.com", "example",
                        "https://host.com:abc", "https://host.com\\path", "https://host.com/a b",
                        " example.com", "example.com ", "\nexample.com", "example.com\t"]
        for input in rejected {
            XCTAssertNil(WorkspaceTabAddress.normalize(input), input)
            XCTAssertFalse(WorkspaceTabAddress.isAllowed(input), input)
        }
        for value in Array(UInt32(0)...0x20) + Array(UInt32(0x7F)...0x9F) + [0xA0, 0x2003, 0x200B, 0x2028, 0x2029, 0xFEFF] {
            let input = "https://example.com/a" + String(UnicodeScalar(value)!) + "b"
            XCTAssertNil(WorkspaceTabAddress.normalize(input), "U+\(String(value, radix: 16))")
            XCTAssertFalse(WorkspaceTabAddress.isAllowed(input))
        }
    }

    func testUnicodeDomainsAndPathsArePreservedAsWebAddresses() throws {
        let cases = [("שלום.ישראל/דרך?חיפוש=כן#פרק", "שלום.ישראל"),
                     ("例え.テスト/日本語", "例え.テスト"),
                     ("例え。テスト/日本語", "例え.テスト"),
                     ("münich.de/café", "münich.de"),
                     ("مثال.إختبار/العربية", "مثال.إختبار")]
        for (input, host) in cases {
            let address = try XCTUnwrap(WorkspaceTabAddress.normalize(input), input)
            let parts = try XCTUnwrap(URLComponents(string: address))
            XCTAssertEqual(parts.host, host)
            XCTAssertTrue(WorkspaceTabAddress.isAllowed(address))
            XCTAssertEqual(WorkspaceTabAddress.normalize(address), address)
        }
    }

    func testNormalizationIsIdempotentAcrossGeneratedAddresses() throws {
        let schemes = ["", "http://", "https://", "HtTpS://"]
        let hosts = ["example.com", "localhost", "127.0.0.1", "שלום.ישראל", "例え.テスト", "münich.de", "例え．テスト"]
        let ports = ["", ":8080"]
        let suffixes = ["", "/", "/דרך", "/日本語?q=café#פרק", "/a%20b", "/%D7%90?x=1&y=2#c", "/100%", "/😀"]
        var accepted = 0
        for scheme in schemes {
            for host in hosts {
                for port in ports {
                    for suffix in suffixes {
                        let input = scheme + host + port + suffix
                        let normalized = try XCTUnwrap(WorkspaceTabAddress.normalize(input), input)
                        XCTAssertEqual(WorkspaceTabAddress.normalize(normalized), normalized, input)
                        XCTAssertTrue(WorkspaceTabAddress.isAllowed(normalized), input)
                        accepted += 1
                    }
                }
            }
        }
        XCTAssertEqual(accepted, schemes.count * hosts.count * ports.count * suffixes.count)
    }

    func testLengthLimitAppliesBeforeAndAfterURLSerialization() throws {
        let prefix = "https://example.com/"
        let longest = prefix + String(repeating: "a", count: WorkspaceTabSet.maxAddressLength - prefix.utf8.count)
        XCTAssertEqual(WorkspaceTabAddress.normalize(longest), longest)
        XCTAssertTrue(WorkspaceTabAddress.isAllowed(longest))
        XCTAssertNil(WorkspaceTabAddress.normalize(longest + "a"))
        XCTAssertNil(WorkspaceTabAddress.normalize("example.com/" + String(repeating: "a", count: 2030)))
        let expanding = prefix + String(repeating: "א", count: 400)
        XCTAssertLessThan(expanding.utf8.count, WorkspaceTabSet.maxAddressLength)
        XCTAssertNil(WorkspaceTabAddress.normalize(expanding), "Percent encoding also has to fit")
        let unicode = try XCTUnwrap(WorkspaceTabAddress.normalize(prefix + String(repeating: "א", count: 100)))
        XCTAssertTrue(WorkspaceTabAddress.isAllowed(unicode))
    }

    func testParseKeepsTabOrderAndDuplicatesAndReportsRejectedLines() {
        let parsed = WorkspaceTabAddress.parse("\n example.com \r\nlocalhost:3000\n\n--incognito\nexample.com\njavascript:alert(1)\n")
        XCTAssertEqual(parsed.addresses, ["https://example.com", "http://localhost:3000", "https://example.com"])
        XCTAssertEqual(parsed.rejected, ["--incognito", "javascript:alert(1)"])
    }

    func testOpeningTabsBuildsCompatibleSortedUniqueBrowserList() {
        let sets = [tabSet(id: "one", browser: "z.browser"), tabSet(id: "two", browser: "a.browser"), tabSet(id: "three", browser: "z.browser")]
        let action = WorkspaceAction.openingTabs(sets, id: "step")
        XCTAssertEqual(action.id, "step")
        XCTAssertEqual(action.kind, .arrangeWindows)
        XCTAssertEqual(action.bundleIDs, ["a.browser", "z.browser"])
        XCTAssertEqual(action.tabSets, sets)
        XCTAssertTrue(action.isTabStep)
        XCTAssertFalse(action.isPlacement)
        XCTAssertFalse(action.isRememberedLayout)
        XCTAssertNil(action.openMissingApps)
        XCTAssertTrue(config(action).validate().isEmpty)
        XCTAssertNotEqual(WorkspaceAction.openingTabs(sets).id, WorkspaceAction.openingTabs(sets).id)
    }

    func testTabStepValidationRejectsEveryInvalidCombinationWithOnePlainError() {
        let valid = WorkspaceAction.openingTabs([tabSet()])
        let changes: [(inout WorkspaceAction) -> Void] = [
            { $0.kind = .centerLastWindow }, { $0.kind = .hideIdleApps },
            { $0.remembered = [:] }, { $0.placements = [] },
            { $0.openMissingApps = false }, { $0.openMissingApps = true },
            { $0.tabSets = [] },
            { $0.tabSets = (0..<21).map { self.tabSet(id: "\($0)", macID: "mac\($0)") } },
            { $0.tabSets = [self.tabSet(), self.tabSet()] },
            { $0.bundleIDs = [] }, { $0.bundleIDs = ["other.browser"] },
            { $0.bundleIDs.append("other.browser") },
            { $0.tabSets?[0].urls = [] }, { $0.tabSets?[0].urls = ["example.com"] },
            { $0.tabSets?[0].urls = ["javascript:alert(1)"] },
            { $0.tabSets?[0].urls = Array(repeating: "https://example.com", count: 51) },
            { $0.tabSets?[0].id = "" }, { $0.tabSets?[0].macID = "" },
            { $0.tabSets?[0].macName = "" }, { $0.tabSets?[0].browserName = "" },
            { $0.tabSets?[0].browserBundleID = "" },
            { $0.tabSets?[0].profile = .init(directory: "../Work", name: "Work") }
        ]
        for (index, change) in changes.enumerated() {
            var broken = valid
            change(&broken)
            XCTAssertEqual(config(broken).validate(), ["Each Open tabs step needs 1–20 windows with valid web addresses"], "Case \(index)")
            XCTAssertNil(config(broken).encoded())
        }
    }

    func testTabSetBoundsAndUniqueIDs() {
        var sets = (0..<20).map { tabSet(id: "\($0)", macID: "mac\($0)") }
        sets[0].urls = Array(repeating: "https://example.com", count: 50)
        let first = WorkspaceAction.openingTabs(sets, id: "first")
        var copy = sets[0]; copy.id = "copy"
        let second = WorkspaceAction.openingTabs([copy], id: "second")
        XCTAssertTrue(WorkspaceLaunchConfig(routines: [.init(name: "Desk", actions: [first, second])]).validate().isEmpty)
        // The tracker finds a window by its set, so an id can't appear in two steps.
        let sameID = WorkspaceAction.openingTabs([sets[0]], id: "third")
        XCTAssertEqual(WorkspaceLaunchConfig(routines: [.init(name: "Desk", actions: [first, sameID])]).validate(), ["Each browser window needs its own id"])
        XCTAssertTrue(sets[0].isLocal("mac0"))
        XCTAssertTrue(sets[0].isLocal("hardware", aliases: ["mac0"]))
        XCTAssertFalse(sets[0].isLocal("other"))
    }

    func testProfileAndBrowserValidationBounds() {
        XCTAssertTrue(WorkspaceBrowserProfile(directory: "Profile 1", name: "עבודה").isValid)
        XCTAssertTrue(WorkspaceBrowserProfile(directory: String(repeating: "a", count: 255), name: String(repeating: "n", count: 120)).isValid)
        for directory in ["", ".", "..", "-x", "/tmp/Work", "a/b", "a\\b", "a\0b", "a\nb", String(repeating: "a", count: 256)] {
            XCTAssertFalse(WorkspaceBrowserProfile(directory: directory, name: "Work").isValid, directory)
        }
        XCTAssertFalse(WorkspaceBrowserProfile(directory: "Default", name: " ").isValid)
        XCTAssertFalse(WorkspaceBrowserProfile(directory: "Default", name: String(repeating: "n", count: 121)).isValid)
        let profiles = (0..<50).map { WorkspaceBrowserProfile(directory: "Profile \($0)", name: "Work") }
        XCTAssertTrue(WorkspaceBrowserInfo(bundleID: "browser", name: "Browser", profiles: profiles).isValid)
        XCTAssertFalse(WorkspaceBrowserInfo(bundleID: "browser", name: "Browser", profiles: profiles + [profiles[0]]).isValid)
        XCTAssertFalse(WorkspaceBrowserInfo(bundleID: "browser", name: "Browser", profiles: [profiles[0], profiles[0]]).isValid)
    }

    func testTabStepsNeverTileCaptureOrCountSkippedBrowserWindows() {
        let action = WorkspaceAction.openingTabs([tabSet()])
        let snapshot = WorkspaceSnapshot(displays: layout().screens,
            windows: [.init(id: "browser-window", bundleID: "com.example.browser", frame: .init(width: 400, height: 300)),
                      .init(id: "minimized", bundleID: "com.example.browser", frame: .init(width: 400, height: 300), isMinimized: true)],
            applications: [.init(bundleID: "com.example.browser", name: "Browser")],
            skipped: [.init(bundleID: "com.example.browser", appName: "Browser", reason: .minimized, count: 1)])
        for mac in ["mini", "other"] {
            XCTAssertTrue(action.localApps(mac).isEmpty)
            XCTAssertTrue(action.localApps(mac, aliases: ["mini"]).isEmpty)
            for preview in [false, true] {
                let routine = config(action).routines[0]
                let plan = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [], macID: mac, preview: preview)
                XCTAssertTrue(plan.operations.isEmpty)
                XCTAssertTrue(plan.windowStack.isEmpty)
                XCTAssertTrue(plan.placementTiles.isEmpty)
                XCTAssertTrue(plan.notes.isEmpty)
                XCTAssertTrue(WorkspaceLaunchExecutor.windowsToBringBack(in: routine, snapshot: snapshot, macID: mac, aliases: []).isEmpty)
            }
        }
        let empty = WorkspacePlanner.plan(routine: config(action).routines[0], snapshot: .init(), protectedBundleIDs: [], macID: "mini")
        XCTAssertTrue(empty.operations.isEmpty)
        XCTAssertTrue(empty.notes.isEmpty)
        let tiling = WorkspaceAction(kind: .arrangeWindows, bundleIDs: action.bundleIDs)
        let mixed = WorkspaceRoutine(name: "Desk", actions: [action, tiling])
        let mixedPlan = WorkspacePlanner.plan(routine: mixed, snapshot: snapshot, protectedBundleIDs: [], macID: "mini")
        let tilePlan = WorkspacePlanner.plan(routine: config(tiling).routines[0], snapshot: snapshot, protectedBundleIDs: [], macID: "mini")
        XCTAssertEqual(mixedPlan, tilePlan, "Later steps still arrange the existing windows")
    }

    func testTabStepRoundTripAndEditingPreserveOptionalFields() throws {
        var set = tabSet()
        set.profile = .init(directory: "Profile 1", name: "Work")
        let value = config(.openingTabs([set], id: "tabs"))
        let json = try XCTUnwrap(value.encoded())
        XCTAssertEqual(WorkspaceLaunchConfig.decode(json), value)
        XCTAssertEqual(WorkspaceLaunchConfig.decodeForEditing(json), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let routines = try XCTUnwrap(object["routines"] as? [[String: Any]])
        let actions = try XCTUnwrap(routines[0]["actions"] as? [[String: Any]])
        XCTAssertEqual(actions[0]["kind"] as? String, "arrangeWindows")
        XCTAssertEqual(actions[0]["bundleIDs"] as? [String], [set.browserBundleID])
        XCTAssertNotNil(actions[0]["tabSets"])
        XCTAssertNil(actions[0]["openMissingApps"])
    }

    func testOlderJSONWithoutNewKeysStillDecodes() throws {
        let json = #"{"version":1,"routines":[{"id":"old","name":"Desk","enabled":true,"actions":[{"id":"step","kind":"arrangeWindows","bundleIDs":["browser"],"display":"main","layout":"halves","idleMinutes":180}]}]}"#
        let old = try XCTUnwrap(WorkspaceLaunchConfig.decode(json))
        XCTAssertNil(old.routines[0].actions[0].tabSets)
        XCTAssertEqual(WorkspaceLaunchConfig.decodeForEditing(json), old)
        let counts = try JSONDecoder().decode(WorkspaceRunCounts.self, from: Data(#"{"windowsMoved":1,"windowsBroughtBack":2,"appsOpened":3,"windowsMinimized":4,"skips":{}}"#.utf8))
        XCTAssertNil(counts.tabsOpened)
        let saved = try JSONDecoder().decode(WorkspaceSavedLayout.self, from: Data(#"{"macName":"Studio","capturedAt":0,"screens":[],"windows":[{"bundleID":"editor","appName":"Editor","screenID":"screen","place":{"x":0,"y":0,"width":1,"height":1}}]}"#.utf8))
        XCTAssertNil(saved.browsers)
        XCTAssertTrue(saved.isValid)
    }

    func testCapturedBrowserListsAreValidatedAndNeverRemembered() throws {
        var captured = layout()
        XCTAssertTrue(captured.isValid)
        captured.browsers = (0..<20).map { .init(bundleID: "browser\($0)", name: "Browser \($0)") }
        XCTAssertTrue(captured.isValid)
        let wire = try JSONEncoder().encode(captured)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSavedLayout.self, from: wire), captured)
        captured.browsers?.append(.init(bundleID: "extra", name: "Extra"))
        XCTAssertFalse(captured.isValid)
        captured.browsers = [.init(bundleID: "browser", name: "")]
        XCTAssertFalse(captured.isValid)
        captured.browsers = [.init(bundleID: "browser", name: "Browser")]
        let action = WorkspaceAction.remembering(["mini": captured], id: "remember", openMissingApps: false)
        var expected = captured
        expected.browsers = nil
        XCTAssertEqual(action.remembered?["mini"], expected)
        XCTAssertEqual(action.openMissingApps, false)
        XCTAssertEqual(captured.browsers?.count, 1, "The live capture stays available to its caller")
        let routine = WorkspaceRoutine.remembering(["mini": captured], existing: [])
        XCTAssertEqual(routine.actions[0].remembered?["mini"], expected)
        let json = try XCTUnwrap(WorkspaceLaunchConfig(routines: [routine]).encoded())
        XCTAssertFalse(json.contains("browsers"))
    }

    func testDiagnosticsOnlyAppendPositiveTabCounts() throws {
        var counts = WorkspaceRunCounts(windowsMoved: 2, windowsBroughtBack: 1, appsOpened: 3, windowsMinimized: 4,
                                        skips: ["z": ["b": 2, "a": 1], "a": ["c": 3]])
        let original = "moved=2 broughtBack=1 opened=3 minimized=4 skips=[a:c=3;z:a=1,b=2]"
        XCTAssertEqual(counts.diagnostic, original)
        for value in [0, -1] {
            counts.tabsOpened = value
            XCTAssertEqual(counts.diagnostic, original)
        }
        counts.tabsOpened = 7
        XCTAssertEqual(counts.diagnostic, original + " tabs=7")
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceRunCounts.self, from: JSONEncoder().encode(counts)), counts)
    }

    func testAccessibilityDependsOnThisMacWhileUndoOwnershipIncludesEveryMac() {
        let tabs = WorkspaceAction.openingTabs([tabSet()])
        let remotePlacement = WorkspaceAction.placing([.init(bundleID: "editor", appName: "Editor", macID: "book", macName: "Book")])
        let remoteRemember = WorkspaceAction.remembering(["book": layout()])
        for remote in [remotePlacement, remoteRemember] {
            let value = WorkspaceRoutine(name: "Mixed", actions: [tabs, remote])
            XCTAssertTrue(value.onlyOpensTabs(macID: "mini", aliases: ["setup-mini"]))
            XCTAssertFalse(value.onlyOpensTabs(macID: "book", aliases: []))
            XCTAssertFalse(value.onlyOpensTabs(macID: "hardware-book", aliases: ["book"]))
            XCTAssertTrue(value.hasWindowSteps, "Remote window work must still replace fleet Undo")
        }
        for windowStep in [WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["browser"]),
                           WorkspaceAction(kind: .centerLastWindow), WorkspaceAction(kind: .hideIdleApps)] {
            XCTAssertFalse(WorkspaceRoutine(name: "Local", actions: [tabs, windowStep]).onlyOpensTabs(macID: "mini", aliases: []))
        }
        XCTAssertFalse(WorkspaceRoutine(name: "Empty").onlyOpensTabs(macID: "mini", aliases: []))
        let tabOnly = WorkspaceRoutine(name: "Tabs", actions: [tabs])
        XCTAssertTrue(tabOnly.onlyOpensTabs(macID: "mini", aliases: []))
        XCTAssertFalse(tabOnly.hasWindowSteps)
    }

    func testCaptureErrorIsOptionalOnWireAndStrippedFromSavedLayouts() throws {
        var captured = layout()
        captured.captureError = "Synthetic capture problem"
        let data = try JSONEncoder().encode(captured)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSavedLayout.self, from: data), captured)
        var oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        oldObject.removeValue(forKey: "captureError")
        let oldData = try JSONSerialization.data(withJSONObject: oldObject)
        XCTAssertNil(try JSONDecoder().decode(WorkspaceSavedLayout.self, from: oldData).captureError)
        XCTAssertNil(WorkspaceAction.remembering(["mini": captured]).remembered?["mini"]?.captureError)
    }
}
