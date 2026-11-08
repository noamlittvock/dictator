import XCTest
@testable import Dictator

final class PairingCredentialStoreTests: XCTestCase {
    private var addressesUsed: [String] = []

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Dictator-PairingCredentialStoreTests-\(UUID().uuidString)", isDirectory: true
        )
        LocalSecret.directoryOverrideForTesting = tempRoot
    }

    override func tearDown() {
        for address in addressesUsed {
            try? PairingCredentialStore.delete(forCore: address)
        }
        addressesUsed = []
        LocalSecret.directoryOverrideForTesting = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testTokenFileIsOwnerOnly() throws {
        let address = track("100.64.1.9")
        try PairingCredentialStore.save(token: "private", forCore: address)
        let url = tempRoot.appendingPathComponent("pairing").appendingPathComponent(PairingCredentialStore.fileName(forCore: address))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    }

    func testFileNameIsFilesystemSafe() {
        XCTAssertEqual(PairingCredentialStore.fileName(forCore: "100.64.0.1:7880"), "100.64.0.1_7880.token")
        XCTAssertEqual(PairingCredentialStore.fileName(forCore: " My-Mac-Mini.example.ts.net "), "my-mac-mini.example.ts.net.token")
    }

    private func track(_ address: String) -> String {
        addressesUsed.append(address)
        return address
    }

    func testSaveThenReadRoundTrips() throws {
        let address = track("100.64.1.1")
        try PairingCredentialStore.save(token: "secret-token", forCore: address)

        let token = try PairingCredentialStore.token(forCore: address)

        XCTAssertEqual(token, "secret-token")
    }

    func testSaveOverwritesExistingToken() throws {
        let address = track("100.64.1.2")
        try PairingCredentialStore.save(token: "first-token", forCore: address)
        try PairingCredentialStore.save(token: "second-token", forCore: address)

        let token = try PairingCredentialStore.token(forCore: address)

        XCTAssertEqual(token, "second-token")
    }

    func testDeleteRemovesToken() throws {
        let address = track("100.64.1.3")
        try PairingCredentialStore.save(token: "to-delete", forCore: address)

        try PairingCredentialStore.delete(forCore: address)

        let token = try PairingCredentialStore.token(forCore: address)
        XCTAssertNil(token)
    }

    func testTokenForMissingCoreIsNil() throws {
        let address = track("100.64.1.4")
        let token = try PairingCredentialStore.token(forCore: address)
        XCTAssertNil(token)
    }

    func testDeleteToleratesMissingItem() throws {
        let address = track("100.64.1.5")
        try PairingCredentialStore.delete(forCore: address)
    }

    func testTwoCoreAddressesAreIndependent() throws {
        let addressA = track("100.64.1.6")
        let addressB = track("100.64.1.7")
        try PairingCredentialStore.save(token: "token-a", forCore: addressA)
        try PairingCredentialStore.save(token: "token-b", forCore: addressB)

        XCTAssertEqual(try PairingCredentialStore.token(forCore: addressA), "token-a")
        XCTAssertEqual(try PairingCredentialStore.token(forCore: addressB), "token-b")

        try PairingCredentialStore.delete(forCore: addressA)

        XCTAssertNil(try PairingCredentialStore.token(forCore: addressA))
        XCTAssertEqual(try PairingCredentialStore.token(forCore: addressB), "token-b")
    }
}
