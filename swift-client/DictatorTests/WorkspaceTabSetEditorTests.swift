import XCTest
@testable import Dictator

final class WorkspaceTabSetEditorTests: XCTestCase {
    private let mac = WorkspaceMacOption(id: "mini", name: "Studio", online: true, isCurrent: true)
    private let work = WorkspaceBrowserProfile(directory: "Profile 1", name: "Work")
    private var chrome: WorkspaceBrowserInfo { .init(bundleID: "browser.chrome", name: "Chrome", profiles: [work]) }
    private let safari = WorkspaceBrowserInfo(bundleID: "browser.safari", name: "Safari")

    private func draft(_ text: String = "example.com") -> WorkspaceTabSetDraft {
        var value = WorkspaceTabSetDraft.newWindow(mac: mac, browsers: [chrome, safari])
        value.addressesText = text
        return value
    }

    func testNewWindowUsesThisMacAndFirstBrowserWithoutProfileOrAddresses() {
        let value = WorkspaceTabSetDraft.newWindow(mac: mac, browsers: [safari, chrome])
        XCTAssertEqual(value.set.macID, mac.id)
        XCTAssertEqual(value.set.macName, mac.name)
        XCTAssertEqual(value.set.browserBundleID, safari.bundleID)
        XCTAssertNil(value.set.profile)
        XCTAssertEqual(value.addressesText, "")
        XCTAssertEqual(value.problem, "Add at least one web address to this window.")
    }

    func testUnknownBrowsersDoNotInventAChoice() {
        var value = WorkspaceTabSetDraft.newWindow(mac: mac, browsers: [])
        value.addressesText = "example.com"
        XCTAssertEqual(value.set.browserBundleID, "")
        XCTAssertEqual(value.browserChoices([]), [])
        XCTAssertEqual(value.problem, "Choose a browser for this window.")
    }

    func testWindowCaptionOnlyAppearsForAChosenNonCatalogBrowser() {
        let catalog = [WorkspaceBrowsers.CatalogEntry(bundleID: chrome.bundleID, profileRoot: "Google/Chrome")]
        var value = WorkspaceTabSetDraft.newWindow(mac: mac, browsers: [])
        XCTAssertNil(value.windowCaption(catalog: catalog))
        value.chooseBrowser(chrome)
        XCTAssertNil(value.windowCaption(catalog: catalog))
        value.chooseBrowser(safari)
        let caption = "This browser decides where these pages open, so they may join a window that's already open."
        XCTAssertEqual(value.windowCaption(catalog: catalog), caption)
        XCTAssertEqual(value.windowCaption(catalog: []), caption)
        XCTAssertEqual(value.browserChoices([]), [safari])
        XCTAssertEqual(value.windowCaption(catalog: catalog), caption, "A saved browser still needs the caption while unavailable")
    }

    func testTextStaysAsTypedAndSavedAddressesAreNormalizedInOrder() {
        let text = "example.com\n\nlocalhost:3000/work\nexample.com\nHTTPS://example.org/path\n"
        let value = draft(text)
        XCTAssertEqual(value.addressesText, text)
        XCTAssertNil(value.problem)
        XCTAssertEqual(value.saved.urls, ["https://example.com", "http://localhost:3000/work", "https://example.com", "https://example.org/path"])
        XCTAssertEqual(value.addressesText, text)
        XCTAssertTrue(value.saved.isValid)
        XCTAssertEqual(WorkspaceTabSetDraft(value.saved).saved, value.saved)
    }

    func testEveryRejectedLineIsListedAndBlocksSaveEvenWithValidAddresses() {
        let value = draft("example.com\njavascript:alert(1)\n--incognito\nnot an address\nfile:///etc/passwd")
        XCTAssertEqual(value.parsed.rejected, ["javascript:alert(1)", "--incognito", "not an address", "file:///etc/passwd"])
        XCTAssertEqual(value.saved.urls, ["https://example.com"])
        XCTAssertEqual(WorkspaceTabSetDraft.problem([value]), "Use a web address for each line listed below.")
    }

    func testEachWindowNeedsAddressesAndFiftyIsTheLimit() {
        XCTAssertNotNil(WorkspaceTabSetDraft.problem([draft(), draft("\n \n")]))
        XCTAssertNil(draft(Array(repeating: "example.com", count: 50).joined(separator: "\n")).problem)
        XCTAssertEqual(draft(Array(repeating: "example.com", count: 51).joined(separator: "\n")).problem,
                       "Use at most 50 web addresses in each window.")
        XCTAssertNotNil(WorkspaceTabSetDraft.problem([]))
        XCTAssertNil(WorkspaceTabSetDraft.problem((0..<20).map { _ in draft() }))
        XCTAssertNotNil(WorkspaceTabSetDraft.problem((0..<21).map { _ in draft() }))
    }

    func testUnavailableBrowserAndProfileStaySelectedThroughEditingAndMacChange() {
        var value = draft()
        value.set.profile = work
        let before = value.saved
        XCTAssertEqual(value.browserChoices([safari]).map(\.bundleID), [safari.bundleID, chrome.bundleID])
        XCTAssertEqual(value.profileChoices([]), [work])
        XCTAssertEqual(value.saved, before)
        XCTAssertNil(value.problem, "Temporary discovery failures must not prevent saving valid stored choices")
        let remote = WorkspaceMacOption(id: "book", name: "Travel", online: false)
        value.chooseMac(remote, browsers: [safari])
        XCTAssertEqual(value.set.macID, remote.id)
        XCTAssertEqual(value.set.macName, remote.name)
        XCTAssertEqual(value.set.browserBundleID, chrome.bundleID)
        XCTAssertEqual(value.set.profile, work)
        XCTAssertEqual(WorkspaceTabSetDraft.availabilityLabel("Chrome", available: false), "Chrome (not available right now)")
        XCTAssertEqual(WorkspaceTabSetDraft.availabilityLabel("Work", available: true), "Work")
    }

    func testAvailableChoicesAreNotDuplicatedAndInventoryDoesNotOverwriteStoredNames() {
        var value = draft()
        value.set.profile = work
        var renamed = chrome
        renamed.name = "New browser name"
        renamed.profiles = [.init(directory: work.directory, name: "Renamed profile")]
        XCTAssertEqual(value.browserChoices([renamed]), [renamed])
        XCTAssertEqual(value.profileChoices(renamed.profiles), renamed.profiles)
        XCTAssertEqual(value.set.browserName, chrome.name)
        XCTAssertEqual(value.set.profile, work)
    }

    func testOnlyChoosingADifferentBrowserClearsTheProfile() {
        var value = draft()
        value.set.profile = work
        value.chooseBrowser(chrome)
        XCTAssertEqual(value.set.profile, work)
        value.chooseBrowser(safari)
        XCTAssertNil(value.set.profile)
        XCTAssertEqual(value.set.browserName, "Safari")
        XCTAssertEqual(value.addressesText, "example.com")
    }

    func testAnEmptyBrowserCanUseDiscoveryAfterChoosingAMac() {
        var value = WorkspaceTabSetDraft.newWindow(mac: mac, browsers: [])
        value.chooseMac(mac, browsers: [safari, chrome])
        XCTAssertEqual(value.set.browserBundleID, safari.bundleID)
        XCTAssertNil(value.set.profile)
    }

    func testEveryNewWindowAndRepairedStoredWindowHasADistinctID() {
        let first = draft()
        var emptyID = first.set
        emptyID.id = ""
        let values = WorkspaceTabSetDraft.editing([first.set, first.set, emptyID])
        XCTAssertEqual(values.first?.id, first.id)
        XCTAssertEqual(Set(values.map(\.id)).count, 3)
        XCTAssertTrue(values.allSatisfy { !$0.id.isEmpty })
        XCTAssertEqual(Set((0..<100).map { _ in draft().id }).count, 100)
    }

    func testActionKeepsCompatibilityKindSortedUniqueBrowsersAndStableStepID() {
        var second = draft("example.org")
        second.chooseBrowser(safari)
        second.set.profile = nil
        let action = WorkspaceTabSetDraft.action([second, draft(), draft()], id: "step")
        XCTAssertEqual(action.id, "step")
        XCTAssertEqual(action.kind, .arrangeWindows)
        XCTAssertTrue(action.isTabStep)
        XCTAssertEqual(action.bundleIDs, [chrome.bundleID, safari.bundleID].sorted())
        XCTAssertEqual(action.tabSets?.count, 3)
        XCTAssertTrue(action.tabSets?.allSatisfy(\.isValid) == true)
        XCTAssertNil(action.placements)
        XCTAssertNil(action.remembered)
        XCTAssertNil(action.openMissingApps)
    }

    func testReorderingAndRemovingWindowsKeepsTextAndUpdatesBrowserList() {
        let first = draft("example.com\n")
        var second = draft("example.org\nexample.net")
        second.chooseBrowser(safari)
        var windows = [second, first]
        XCTAssertEqual(WorkspaceTabSetDraft.action(windows).tabSets?.map(\.id), [second.id, first.id])
        windows.removeLast()
        let action = WorkspaceTabSetDraft.action(windows)
        XCTAssertEqual(action.bundleIDs, [safari.bundleID])
        XCTAssertEqual(windows[0].addressesText, "example.org\nexample.net")
        XCTAssertEqual(action.tabSets?.first?.urls, ["https://example.org", "https://example.net"])
    }

    func testInvalidStoredProfileCannotBeSaved() {
        var value = draft()
        value.set.profile = .init(directory: "../bad", name: "Work")
        XCTAssertNotNil(value.problem)
    }

    func testSummariesDescribeTabCountsAndKeepStepOrderWithoutAddresses() {
        let one = WorkspaceTabSetDraft.action([draft()])
        let two = WorkspaceTabSetDraft.action([draft("example.com\nexample.org"), draft("example.net\nexample.edu\nexample.gov")])
        XCTAssertEqual(WorkspaceTabWords.summary(one.tabSets ?? []), "1 window, 1 tab")
        XCTAssertEqual(WorkspaceTabWords.summary(two.tabSets ?? []), "2 windows, 5 tabs")
        let routine = WorkspaceRoutine(name: "Work", actions: [one, .init(kind: .centerLastWindow), two])
        let summary = WorkspaceWords.summary(routine, macID: "mini", appName: { $0 })
        XCTAssertEqual(summary, "Open tabs: 1 window, 1 tab, then center the window you're using on the main screen, then open tabs: 2 windows, 5 tabs.")
        XCTAssertFalse(summary.contains("example"))
        XCTAssertFalse(summary.contains("Arrange"))
    }

    func testATabStepNeedsNoAppsAndAnArrangeStepStillDoes() {
        let tabs = WorkspaceRoutine(name: "Work", actions: [WorkspaceTabSetDraft.action([draft()])])
        XCTAssertEqual(WorkspaceWords.missing(tabs), [])
        let empty = WorkspaceRoutine(name: "Work", actions: [.init(kind: .arrangeWindows)])
        XCTAssertEqual(WorkspaceWords.missing(empty), ["the apps to use"])
    }
}
