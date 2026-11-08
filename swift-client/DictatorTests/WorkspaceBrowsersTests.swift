import XCTest
@testable import Dictator

final class WorkspaceBrowsersTests: XCTestCase {
    private let support = URL(fileURLWithPath: "/synthetic/Library/Application Support", isDirectory: true)
    private let chrome = WorkspaceBrowsers.CatalogEntry(bundleID: "test.chrome", profileRoot: "Google/Chrome")

    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    func testOnlyCatalogBrowsersOpenTheirOwnWindow() {
        XCTAssertTrue(WorkspaceBrowsers.opensItsOwnWindow(bundleID: chrome.bundleID, catalog: [chrome]))
        XCTAssertFalse(WorkspaceBrowsers.opensItsOwnWindow(bundleID: "test.unknown", catalog: [chrome]))
        XCTAssertFalse(WorkspaceBrowsers.opensItsOwnWindow(bundleID: chrome.bundleID, catalog: []))
    }

    func testProfilesUseListedOrderThenSortedFoldersAndDisambiguateNames() throws {
        let data = try json(["profile": [
            "info_cache": ["Profile 2": ["name": "Work"], "Default": ["name": "Work"],
                           "Zed": ["name": "Personal"], "Alpha": [:]],
            "profiles_order": ["Profile 2", "missing", "Profile 2", "Zed"]
        ]])
        XCTAssertEqual(WorkspaceBrowsers.profiles(fromLocalState: data), [
            .init(directory: "Profile 2", name: "Work (Profile 2)"),
            .init(directory: "Zed", name: "Personal"),
            .init(directory: "Alpha", name: "Alpha"),
            .init(directory: "Default", name: "Work (Default)")
        ])
    }

    func testProfilesNeverUseSignInFieldsAndKeepUnicodeNames() throws {
        let data = try json(["profile": ["info_cache": [
            "Default": ["user_name": "secret@example.test", "gaia_name": "Private person", "gaia_id": "private"],
            "Profile 1": ["name": "עבודה", "user_name": ["malformed": true]],
            "Profile 2": ["name": NSNull(), "gaia_given_name": "Private"]
        ], "profiles_order": ["Profile 1", "Default"]],
        "user_name": "also private", "other": ["profile": ["info_cache": ["Wrong": ["name": "Wrong"]]]]])
        XCTAssertEqual(WorkspaceBrowsers.profiles(fromLocalState: data), [
            .init(directory: "Profile 1", name: "עבודה"), .init(directory: "Default", name: "Default"),
            .init(directory: "Profile 2", name: "Profile 2")
        ])
    }

    func testProfilesDropInvalidFoldersNamesAndEntries() throws {
        var cache: [String: Any] = ["Default": ["name": "Good"], "Blank": ["name": " \n"],
                                    "Long name": ["name": String(repeating: "x", count: 121)],
                                    "Not a name": ["name": 42], "Not an object": 42]
        for folder in ["", ".", "..", "../escape", "a/b", "a\\b", "-flag", "a\n", "a\u{7f}", String(repeating: "a", count: 256)] {
            cache[folder] = ["name": "Bad"]
        }
        XCTAssertEqual(WorkspaceBrowsers.profiles(fromLocalState: try json(["profile": ["info_cache": cache]])),
                       [.init(directory: "Default", name: "Good")])
    }

    func testProfilesCapAtFiftyAfterValidationAndDeduplication() throws {
        var cache: [String: Any] = [:]
        for number in 0..<60 { cache[String(format: "Profile %02d", number)] = ["name": "Profile \(number)"] }
        let data = try json(["profile": ["info_cache": cache, "profiles_order": ["missing", "Profile 59", "Profile 59", 42]]])
        let result = WorkspaceBrowsers.profiles(fromLocalState: data)
        XCTAssertEqual(result.count, 50)
        XCTAssertEqual(result.first?.directory, "Profile 59")
        XCTAssertEqual(result.last?.directory, "Profile 48")
        XCTAssertEqual(Set(result.map(\.directory)).count, 50)
        XCTAssertTrue(result.allSatisfy(\.isValid))
    }

    func testMalformedOrMissingProfileDataIsEmpty() throws {
        for text in ["{", "[]", "null", "{}", "{\"profile\":[]}", "{\"profile\":{\"info_cache\":[]}}"] {
            XCTAssertEqual(WorkspaceBrowsers.profiles(fromLocalState: Data(text.utf8)), [])
        }
        let wrongOrder = try json(["profile": ["info_cache": ["B": [:], "A": [:]], "profiles_order": "bad"]])
        XCTAssertEqual(WorkspaceBrowsers.profiles(fromLocalState: wrongOrder).map(\.directory), ["A", "B"])
    }

    func testArgumentsHaveFixedOrderAndNeverAcceptFlagsAsAddresses() {
        let urls = ["https://example.test/a?b=1#c", "http://localhost:3000/x"]
        XCTAssertEqual(WorkspaceBrowsers.launchArguments(profileDirectory: "Profile 1", urls: urls),
                       ["--profile-directory=Profile 1", "--new-window", "--"] + urls)
        XCTAssertEqual(WorkspaceBrowsers.launchArguments(profileDirectory: nil, urls: urls), ["--new-window", "--"] + urls)
        for address in ["--incognito", "-x", "example.test", "file:///etc/passwd", "javascript:alert(1)",
                        "https://user:pw@example.test", "https://", "https://example.test/a b", "https://example.test/\n"] {
            XCTAssertNil(WorkspaceBrowsers.launchArguments(profileDirectory: nil, urls: [urls[0], address]))
        }
        XCTAssertNil(WorkspaceBrowsers.launchArguments(profileDirectory: nil, urls: []))
    }

    func testArgumentsValidateFolderUsingProfileRules() {
        for folder in ["", ".", "..", "../escape", "a/b", "a\\b", "-flag", "a\n", "a\u{7f}", String(repeating: "x", count: 256)] {
            XCTAssertNil(WorkspaceBrowsers.launchArguments(profileDirectory: folder, urls: ["https://example.test"]), folder)
        }
        for folder in ["Default", "Profile 1", "עבודה", String(repeating: "x", count: 255)] {
            XCTAssertNotNil(WorkspaceBrowsers.launchArguments(profileDirectory: folder, urls: ["https://example.test"]), folder)
        }
    }

    func testAssemblyIncludesUnknownBrowsersDeduplicatesExcludesAndSortsDefaultFirst() throws {
        let data = try json(["profile": ["info_cache": ["Default": ["name": "Work"]]]])
        var reads: [URL] = []
        let result = WorkspaceBrowsers.assemble(apps: [
            .init(bundleID: "test.chrome", name: "Chrome"), .init(bundleID: "test.safari", name: "Safari"),
            .init(bundleID: "test.unknown", name: "A new browser"), .init(bundleID: "test.chrome", name: "Duplicate"),
            .init(bundleID: "test.dictator", name: "Dictator"), .init(bundleID: "test.z", name: "Zebra"),
            .init(bundleID: "test.alpha", name: "a new browser")
        ], defaultBundleID: "test.safari", excludedBundleIDs: ["test.dictator"], catalog: [chrome], applicationSupport: support) { url, limit in
            reads.append(url)
            XCTAssertEqual(limit, 8 * 1024 * 1024)
            return data
        }
        XCTAssertEqual(result.map(\.bundleID), ["test.safari", "test.alpha", "test.unknown", "test.chrome", "test.z"])
        XCTAssertEqual(result.first(where: { $0.bundleID == "test.chrome" })?.profiles, [.init(directory: "Default", name: "Work")])
        XCTAssertTrue(result.filter { $0.bundleID != "test.chrome" }.allSatisfy { $0.profiles.isEmpty })
        XCTAssertEqual(reads, [support.appendingPathComponent("Google/Chrome/Local State")])
    }

    func testUnreadableMalformedAndOversizedStateLeaveBrowserAvailableWithoutProfiles() {
        let oversized = Data(repeating: 0x20, count: WorkspaceBrowsers.maxLocalStateBytes + 1)
        for data in [nil, Data("{".utf8), oversized] as [Data?] {
            let browsers = WorkspaceBrowsers.assemble(apps: [.init(bundleID: chrome.bundleID, name: "Chrome")],
                defaultBundleID: nil, excludedBundleIDs: [], catalog: [chrome], applicationSupport: support) { _, _ in data }
            XCTAssertEqual(browsers, [.init(bundleID: chrome.bundleID, name: "Chrome")])
        }
        XCTAssertEqual(WorkspaceBrowsers.profiles(fromLocalState: oversized), [])
    }

    func testStateSizeLimitIsInclusive() throws {
        var data = try json(["profile": ["info_cache": ["Default": [:]]]])
        data.append(Data(repeating: 0x20, count: WorkspaceBrowsers.maxLocalStateBytes - data.count))
        XCTAssertEqual(WorkspaceBrowsers.profiles(fromLocalState: data), [.init(directory: "Default", name: "Default")])
    }

    func testCatalogPathsCannotEscapeApplicationSupport() {
        for path in ["", "/absolute", "../escape", "Google/../escape", "Google//Chrome", "Google/Chrome/", "a\\b", "a\n"] {
            let entry = WorkspaceBrowsers.CatalogEntry(bundleID: chrome.bundleID, profileRoot: path)
            XCTAssertNil(entry.root(in: support), path)
            let result = WorkspaceBrowsers.assemble(apps: [.init(bundleID: chrome.bundleID, name: "Chrome")],
                defaultBundleID: nil, excludedBundleIDs: [], catalog: [entry], applicationSupport: support) { _, _ in
                    XCTFail("Invalid catalog path must not be read")
                    return nil
                }
            XCTAssertEqual(result.first?.profiles, [])
        }
    }

    func testCatalogLaunchRequiresExistingProfileFolderAndUsesArguments() {
        let urls = ["https://example.test"]
        var checked: [URL] = []
        let missing = WorkspaceBrowsers.launchRequest(bundleID: chrome.bundleID, profileDirectory: "Profile 1", urls: urls,
            catalog: [chrome], applicationSupport: support) { checked.append($0); return false }
        XCTAssertNil(missing)
        XCTAssertEqual(checked, [support.appendingPathComponent("Google/Chrome/Profile 1", isDirectory: true)])
        let present = WorkspaceBrowsers.launchRequest(bundleID: chrome.bundleID, profileDirectory: "Profile 1", urls: urls,
            catalog: [chrome], applicationSupport: support) { _ in true }
        XCTAssertEqual(present, .application(arguments: ["--profile-directory=Profile 1", "--new-window", "--"] + urls))
        let lastUsed = WorkspaceBrowsers.launchRequest(bundleID: chrome.bundleID, profileDirectory: nil, urls: urls,
            catalog: [chrome], applicationSupport: support) { _ in XCTFail("No chosen profile to check"); return false }
        XCTAssertEqual(lastUsed, .application(arguments: ["--new-window", "--"] + urls))
    }

    func testUnknownBrowserUsesURLAPIAndRefusesAnyNamedProfile() {
        let urls = ["https://example.test", "http://localhost:3000"]
        func request(_ profile: String?, _ addresses: [String]) -> WorkspaceBrowsers.LaunchRequest? {
            WorkspaceBrowsers.launchRequest(bundleID: "test.unknown", profileDirectory: profile, urls: addresses,
                catalog: [chrome], applicationSupport: support) { _ in XCTFail("Unknown browser has no profile root"); return true }
        }
        XCTAssertEqual(request(nil, urls), .addresses(urls.map { URL(string: $0)! }))
        XCTAssertNil(request("Default", urls))
        XCTAssertNil(request(nil, ["--incognito"]))
        XCTAssertNil(request(nil, []))
    }

    func testInvalidProfileNeverReachesFilesystemCheck() {
        XCTAssertNil(WorkspaceBrowsers.launchRequest(bundleID: chrome.bundleID, profileDirectory: "../escape", urls: ["https://example.test"],
            catalog: [chrome], applicationSupport: support) { _ in XCTFail("Invalid folder must not be inspected"); return true })
    }

    func testBundledCatalogContainsBrowserDataAndExistingToolReaderAcceptsExtraKey() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "tool-catalog", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let entries = WorkspaceBrowsers.catalog(from: data)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: entries.map { ($0.bundleID, $0.profileRoot) }), [
            "com.google.Chrome": "Google/Chrome", "com.google.Chrome.beta": "Google/Chrome Beta",
            "com.google.Chrome.canary": "Google/Chrome Canary", "com.brave.Browser": "BraveSoftware/Brave-Browser",
            "com.microsoft.edgemac": "Microsoft Edge", "com.vivaldi.Vivaldi": "Vivaldi", "org.chromium.Chromium": "Chromium"
        ])
        let tools = try ToolCatalog.decode(data)
        XCTAssertFalse(tools.tools.isEmpty)
        XCTAssertFalse(tools.hostApps.isEmpty)
        XCTAssertEqual(WorkspaceBrowsers.catalog(from: Data("{}".utf8)), [])
        XCTAssertEqual(WorkspaceBrowsers.catalog(from: Data("{".utf8)), [])
    }
}
