import XCTest
@testable import Dictator

/// Covers `DictatorViewModel.coreURL(for:)` — an Edge must only
/// ever be able to dial a Tailscale-reachable Core address, so the pairing
/// token and audio never leave the tailnet. `coreURL(for:)` is `static`
/// (internal) precisely so this can call it directly without spinning up
/// the coordinator's `EdgeRuntime`/`CoreHost`.
///
/// The `onConnected`/`leaveEdgeRoleIfNeeded` guard (only reset a session
/// that's actually live on the remote broker, guarded by
/// `isLocalEdgeAttached`) is not covered by a test in this file: exercising
/// it means driving a real handshake against a live `CoreConnection`/
/// `CoreServer` pair while a genuine mid-session `EdgeRuntime` phase is held
/// open — `DictatorViewModel` exposes none of `edgeRuntime`/
/// `isLocalEdgeAttached`/`edgeConnection` for a test to poke directly (by
/// design — see its generation-guard comments), and
/// `CoreServerLoopbackTests` (the one place this codebase does drive a real
/// handshake) has no `EdgeRuntime` to put into a non-idle phase without a
/// live mic. `EdgeRuntimeTests`' own `resetSession` coverage
/// (`testResetSessionFromRecordingGoesIdleAndClearsFlags` etc.) already
/// proves `resetSession` itself is correct once called; this guard is purely
/// about the caller deciding whether to call it, which is what the guard
/// comments at both call sites in `DictatorViewModel.swift` document.
final class DictatorViewModelRoleTests: XCTestCase {
    func testADotTsNetEndingElsewhereInTheAddressIsNotTailscale() {
        for address in ["evil.example.com/.ts.net", "evil.example.com/.ts.net:8080", "192.168.1.50?.ts.net", "evil.example.com#.ts.net",
                        "user@evil.example.com/.ts.net", ".ts.net", "-a.ts.net", "a..ts.net", "evil.ts.net.example.com"] {
            XCTAssertNil(DictatorViewModel.coreURL(for: address), address)
        }
        XCTAssertEqual(DictatorViewModel.coreURL(for: "studio.tail1234.ts.net:7880")?.host, "studio.tail1234.ts.net")
    }

    func testAcceptsBareTailscaleIPv4() {
        let url = DictatorViewModel.coreURL(for: "100.101.102.103")
        XCTAssertEqual(url?.absoluteString, "ws://100.101.102.103:\(EdgeProtocol.corePort)")
    }

    func testAcceptsTailscaleIPv4WithExplicitPort() {
        let url = DictatorViewModel.coreURL(for: "100.101.102.103:7880")
        XCTAssertEqual(url?.absoluteString, "ws://100.101.102.103:7880")
    }

    func testAcceptsMagicDNSHostname() {
        let url = DictatorViewModel.coreURL(for: "mac-mini.tail1234.ts.net")
        XCTAssertEqual(url?.absoluteString, "ws://mac-mini.tail1234.ts.net:\(EdgeProtocol.corePort)")
    }

    func testAcceptsMagicDNSHostnameWithExplicitPort() {
        let url = DictatorViewModel.coreURL(for: "mac-mini.tail1234.ts.net:7880")
        XCTAssertEqual(url?.absoluteString, "ws://mac-mini.tail1234.ts.net:7880")
    }

    func testRejectsLANAddress() {
        XCTAssertNil(DictatorViewModel.coreURL(for: "192.168.1.5"))
    }

    func testRejectsPublicHostname() {
        XCTAssertNil(DictatorViewModel.coreURL(for: "example.com"))
    }

    func testRejectsIPv4OutsideTailscaleCGNATRange() {
        // Second octet 128 is outside the 100.64.0.0/10 range (64...127).
        XCTAssertNil(DictatorViewModel.coreURL(for: "100.128.0.1"))
    }

    func testRejectsExplicitScheme() {
        XCTAssertNil(DictatorViewModel.coreURL(for: "ws://x"))
    }

    func testRejectsEmptyAddress() {
        XCTAssertNil(DictatorViewModel.coreURL(for: ""))
        XCTAssertNil(DictatorViewModel.coreURL(for: "   "))
    }

    func testTrimsWhitespace() {
        let url = DictatorViewModel.coreURL(for: "  100.101.102.103  ")
        XCTAssertEqual(url?.absoluteString, "ws://100.101.102.103:\(EdgeProtocol.corePort)")
    }

    func testRejectsInvalidPort() {
        XCTAssertNil(DictatorViewModel.coreURL(for: "100.101.102.103:not-a-port"))
        XCTAssertNil(DictatorViewModel.coreURL(for: "100.101.102.103:0"))
    }
}
