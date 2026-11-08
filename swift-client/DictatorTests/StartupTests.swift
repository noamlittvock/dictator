import XCTest
@testable import Dictator

@MainActor
final class StartupTests: XCTestCase {
    func testAccidentalDevelopmentLaunchCannotStartLiveRuntime() {
        XCTAssertTrue(DevelopmentRuntimePolicy.blocksLiveRuntime(bundleID: "dev.noamlitt.dictator.development", arguments: []))
        XCTAssertTrue(DevelopmentRuntimePolicy.blocksLiveRuntime(bundleID: "dev.noamlitt.dictator.development", arguments: ["--enable-login"]))
        XCTAssertFalse(DevelopmentRuntimePolicy.blocksLiveRuntime(bundleID: "dev.noamlitt.dictator.development", arguments: ["--allow-development-runtime"]))
    }

    func testInstalledAppDoesNotNeedDevelopmentOptIn() {
        XCTAssertFalse(DevelopmentRuntimePolicy.blocksLiveRuntime(bundleID: "dev.noamlitt.dictator", arguments: []))
    }

    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "StartupTests-" + UUID().uuidString)!
        d.removeObject(forKey: StartupController.windowKey)
        return d
    }

    func testInitializationNeverRegistersAndRefreshReadsExternalChanges() {
        var state = StartupReport.Login.disabled
        var writes = 0
        let sut = StartupController(defaults: defaults(), readLogin: { state }, register: { writes += 1 }, unregister: { writes += 1 })
        XCTAssertEqual(sut.login, .disabled)
        XCTAssertEqual(writes, 0)
        state = .enabled
        sut.refresh()
        XCTAssertEqual(sut.login, .enabled)
        XCTAssertEqual(writes, 0)
    }

    func testEnablingExistingRegistrationIsIdempotent() {
        var writes = 0
        let sut = StartupController(defaults: defaults(), readLogin: { .enabled }, register: { writes += 1 }, unregister: {})
        sut.setLogin(true)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(sut.login, .enabled)
    }

    func testSuccessfulRequestCanStillRequireApproval() {
        var state = StartupReport.Login.disabled
        let sut = StartupController(defaults: defaults(), readLogin: { state }, register: { state = .needsApproval }, unregister: { state = .disabled })
        sut.setLogin(true)
        XCTAssertEqual(sut.login, .needsApproval)
        XCTAssertNil(sut.message)
        sut.setLogin(false)
        XCTAssertEqual(sut.login, .disabled)
    }

    func testFailurePreservesActualOSStateAndExplainsRecovery() {
        struct Denied: Error {}
        let sut = StartupController(defaults: defaults(), readLogin: { .disabled }, register: { throw Denied() }, unregister: {})
        sut.setLogin(true)
        XCTAssertEqual(sut.login, .disabled)
        XCTAssertNotNil(sut.message)
    }

    func testWindowChoiceIsPerInstallAndDoesNotRegisterLogin() {
        let first = defaults(), second = defaults()
        var writes = 0
        let sut = StartupController(defaults: first, readLogin: { .disabled }, register: { writes += 1 }, unregister: {})
        XCTAssertFalse(sut.showWindow)
        sut.setShowWindow(true)
        XCTAssertTrue(first.bool(forKey: StartupController.windowKey))
        XCTAssertFalse(second.bool(forKey: StartupController.windowKey))
        XCTAssertEqual(writes, 0)
    }

    func testWindowOpensAtMostOnceAndChangingPreferenceWaitsUntilNextLaunch() {
        let d = defaults()
        let sut = StartupController(defaults: d, readLogin: { .disabled }, register: {}, unregister: {})
        XCTAssertFalse(sut.claimLaunchWindow(hasCompletedWelcome: true))
        sut.setShowWindow(true)
        XCTAssertFalse(sut.claimLaunchWindow(hasCompletedWelcome: true))
        let nextLaunch = StartupController(defaults: d, readLogin: { .disabled }, register: {}, unregister: {})
        XCTAssertTrue(nextLaunch.claimLaunchWindow(hasCompletedWelcome: true))
        XCTAssertFalse(nextLaunch.claimLaunchWindow(hasCompletedWelcome: true))
        let firstUse = StartupController(defaults: defaults(), readLogin: { .disabled }, register: {}, unregister: {})
        XCTAssertTrue(firstUse.claimLaunchWindow(hasCompletedWelcome: false))
        XCTAssertFalse(firstUse.claimLaunchWindow(hasCompletedWelcome: false))
    }

    func testOfflineAndOlderMacNeverPromiseAutomaticStartup() {
        let enabled = StartupReport(login: .enabled, showWindow: false)
        XCTAssertTrue(StartupReport.detail(report: enabled, online: false, isMain: true).hasPrefix("Offline."))
        XCTAssertTrue(StartupReport.detail(report: nil, online: true, isMain: true).hasPrefix("Update Dictator"))
        XCTAssertTrue(StartupReport.detail(report: .init(login: .disabled, showWindow: false), online: true, isMain: true).contains("Your other Macs share"))
    }

    func testOptionalCapabilityReportSupportsOlderPeersAndRoundTrips() throws {
        let caps = EdgeCapabilities(hasMic: false, inputDeviceUID: "", accessibility: true, inputMonitoring: true, hotkeyMode: "none")
        let old = try JSONEncoder().encode(caps)
        XCTAssertNil(try JSONDecoder().decode(EdgeCapabilities.self, from: old).startup)
        var newer = caps
        newer.startup = .init(login: .needsApproval, showWindow: true)
        let message = EdgeMessage.capabilities(newer)
        XCTAssertEqual(try EdgeProtocolCodec.decodeEdgeMessage(EdgeProtocolCodec.encode(message)), message)
    }

    func testSetupReportTracksCapabilityChangesAndMarksOffline() {
        let saved = UserDefaults.standard.data(forKey: "setupKnownMachines")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "setupKnownMachines") }
            else { UserDefaults.standard.removeObject(forKey: "setupKnownMachines") }
        }
        UserDefaults.standard.removeObject(forKey: "setupKnownMachines")
        let directory = SetupDirectory(fetchHealth: { _ in nil })
        var caps = EdgeCapabilities(hasMic: false, inputDeviceUID: "", accessibility: true, inputMonitoring: true, hotkeyMode: "none")
        caps.startup = .init(login: .enabled, showWindow: false)
        directory.update(edges: [BrokerEdgeInfo(id: "startup-test", name: "Test Mac", caps: caps)], coreEdgeId: "startup-test")
        XCTAssertEqual(directory.snapshot?.machines.first(where: { $0.id == "startup-test" })?.startup, caps.startup)
        caps.startup = .init(login: .disabled, showWindow: true)
        directory.update(edges: [BrokerEdgeInfo(id: "startup-test", name: "Test Mac", caps: caps)], coreEdgeId: "startup-test")
        XCTAssertEqual(directory.snapshot?.machines.first(where: { $0.id == "startup-test" })?.startup, caps.startup)
        directory.update(edges: [], coreEdgeId: "startup-test")
        XCTAssertEqual(directory.snapshot?.machines.first(where: { $0.id == "startup-test" })?.online, false)
    }
}
