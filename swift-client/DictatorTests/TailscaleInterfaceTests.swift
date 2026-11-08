import XCTest
@testable import Dictator

final class TailscaleInterfaceTests: XCTestCase {
    // MARK: isTailscaleAddress

    func testLowerBoundaryIsInRange() {
        XCTAssertTrue(TailscaleInterface.isTailscaleAddress("100.64.0.0"))
    }

    func testUpperBoundaryIsInRange() {
        XCTAssertTrue(TailscaleInterface.isTailscaleAddress("100.127.255.255"))
    }

    func testJustBelowLowerBoundaryIsOutOfRange() {
        XCTAssertFalse(TailscaleInterface.isTailscaleAddress("100.63.255.255"))
    }

    func testJustAboveUpperBoundaryIsOutOfRange() {
        XCTAssertFalse(TailscaleInterface.isTailscaleAddress("100.128.0.0"))
    }

    func testUnrelatedPrivateAddressIsOutOfRange() {
        XCTAssertFalse(TailscaleInterface.isTailscaleAddress("10.0.0.1"))
    }

    func testGarbageStringIsOutOfRange() {
        XCTAssertFalse(TailscaleInterface.isTailscaleAddress("garbage"))
    }

    func testIncompleteAddressIsOutOfRange() {
        XCTAssertFalse(TailscaleInterface.isTailscaleAddress("100.64.0"))
    }

    // MARK: select

    func testSelectPrefersUtunOverEnWhenBothInRange() {
        let interfaces = [
            InterfaceAddress(name: "en0", ipv4: "100.64.1.1"),
            InterfaceAddress(name: "utun3", ipv4: "100.64.1.2"),
        ]
        XCTAssertEqual(TailscaleInterface.select(from: interfaces), "100.64.1.2")
    }

    func testSelectIgnoresNonUtunInRangeAddressWhenUtunCandidateExists() {
        let interfaces = [
            InterfaceAddress(name: "en0", ipv4: "100.64.1.1"),
            InterfaceAddress(name: "utun9", ipv4: "100.64.1.2"),
            InterfaceAddress(name: "utun1", ipv4: "100.64.1.3"),
        ]
        // Lowest utun name wins among utun candidates; en0 is excluded.
        XCTAssertEqual(TailscaleInterface.select(from: interfaces), "100.64.1.3")
    }

    func testSelectTakesNonUtunAddressWhenNoUtunCandidateExists() {
        let interfaces = [
            InterfaceAddress(name: "en0", ipv4: "100.64.1.1"),
            InterfaceAddress(name: "lo0", ipv4: "127.0.0.1"),
        ]
        XCTAssertEqual(TailscaleInterface.select(from: interfaces), "100.64.1.1")
    }

    func testSelectPrefersLowestNameAmongMultipleUtunCandidates() {
        let interfaces = [
            InterfaceAddress(name: "utun5", ipv4: "100.64.1.5"),
            InterfaceAddress(name: "utun2", ipv4: "100.64.1.2"),
        ]
        XCTAssertEqual(TailscaleInterface.select(from: interfaces), "100.64.1.2")
    }

    func testSelectReturnsNilForEmptyList() {
        XCTAssertNil(TailscaleInterface.select(from: []))
    }

    func testSelectReturnsNilWhenNoCandidatesInRange() {
        let interfaces = [
            InterfaceAddress(name: "lo0", ipv4: "127.0.0.1"),
            InterfaceAddress(name: "en0", ipv4: "192.168.1.5"),
        ]
        XCTAssertNil(TailscaleInterface.select(from: interfaces))
    }

    // MARK: currentInterfaces

    func testCurrentInterfacesContainsLoopback() {
        let interfaces = TailscaleInterface.currentInterfaces()
        XCTAssertTrue(
            interfaces.contains(InterfaceAddress(name: "lo0", ipv4: "127.0.0.1")),
            "Expected lo0/127.0.0.1 among \(interfaces)"
        )
    }
}
