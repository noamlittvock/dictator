import XCTest
@testable import Dictator

final class LocalSecretTests: XCTestCase {
    override func tearDown() {
        LocalSecret.directoryOverrideForTesting = nil
        super.tearDown()
    }

    func testConstantTimeEqualMatchesEqualStrings() {
        XCTAssertTrue(LocalSecret.constantTimeEqual("abc123", "abc123"))
    }

    func testConstantTimeEqualRejectsUnequalSameLength() {
        XCTAssertFalse(LocalSecret.constantTimeEqual("abc123", "abc124"))
    }

    func testConstantTimeEqualRejectsUnequalDifferentLength() {
        XCTAssertFalse(LocalSecret.constantTimeEqual("abc123", "abc1234"))
    }

    func testConstantTimeEqualMatchesEmptyStrings() {
        XCTAssertTrue(LocalSecret.constantTimeEqual("", ""))
    }

    func testSharedTokenIsSixtyFourLowercaseHexChars() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalSecretTests-\(UUID().uuidString)", isDirectory: true)
        LocalSecret.directoryOverrideForTesting = tempDirectory
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let token = try LocalSecret.sharedToken(fileName: "test.token")

        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        })
    }

    func testSharedTokenIsStableAcrossCalls() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalSecretTests-\(UUID().uuidString)", isDirectory: true)
        LocalSecret.directoryOverrideForTesting = tempDirectory
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let first = try LocalSecret.sharedToken(fileName: "test.token")
        let second = try LocalSecret.sharedToken(fileName: "test.token")

        XCTAssertEqual(first, second)
    }

    func testRotationReplacesPersistedTokenAndKeepsOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        LocalSecret.directoryOverrideForTesting = root
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try LocalSecret.sharedToken(fileName: "core-pairing.token")
        let replacement = try LocalSecret.rotateSharedToken()
        XCTAssertNotEqual(old, replacement)
        XCTAssertEqual(replacement.count, 64)
        XCTAssertTrue(replacement.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(try LocalSecret.sharedToken(fileName: "core-pairing.token"), replacement)
        let url = root.appendingPathComponent("core-pairing.token")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["core-pairing.token"])
    }

    func testFailureBeforeAtomicPublicationPreservesOldTokenAndRemovesTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        LocalSecret.directoryOverrideForTesting = root
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try LocalSecret.sharedToken(fileName: "core-pairing.token")
        let url = root.appendingPathComponent("core-pairing.token")
        XCTAssertThrowsError(try LocalSecret.writePrivateSecret("replacement", to: url, beforeRename: {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), old)
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        XCTAssertEqual(try LocalSecret.sharedToken(fileName: "core-pairing.token"), old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["core-pairing.token"])
    }

    func testPastingRemoteKeyNeverChangesLocalServerKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        LocalSecret.directoryOverrideForTesting = root
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(LocalSecret.speechServerKey())
        XCTAssertNil(LocalSecret.remoteSpeechServerKey())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try LocalSecret.saveSpeechServerKey("  synthetic-remote_key\n")
        XCTAssertNil(LocalSecret.speechServerKey(), "Pasting must not create the server-owned file")
        let local = root.appendingPathComponent("speech-server.token")
        try LocalSecret.writePrivateSecret("synthetic-local", to: local)
        let remote = root.appendingPathComponent("speech-server-remote.token")
        XCTAssertEqual(LocalSecret.remoteSpeechServerKey(), "synthetic-remote_key")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: remote.path)[.posixPermissions] as? Int, 0o600)
        try LocalSecret.saveSpeechServerKey("replacement-remote")
        XCTAssertEqual(LocalSecret.speechServerKey(), "synthetic-local")
        XCTAssertEqual(try String(contentsOf: local), "synthetic-local")
        XCTAssertEqual(LocalSecret.remoteSpeechServerKey(), "replacement-remote")
        XCTAssertThrowsError(try LocalSecret.saveSpeechServerKey("key\r\nInjected: header"))
        XCTAssertEqual(LocalSecret.remoteSpeechServerKey(), "replacement-remote")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["speech-server.token", "speech-server-remote.token"])
    }

    func testSpeechKeySelectionUsesRequestHostAndOwnInterfaces() {
        let own: Set<String> = ["100.101.102.103", "192.168.1.8", "fd7a:115c:a1e0::1"]
        for host in ["localhost", "LOCALHOST.", "127.0.0.1", "127.9.8.7", "::1", "[::1]", "100.101.102.103", "192.168.1.8", "fd7a:115c:a1e0::1", "FD7A:115C:A1E0:0:0:0:0:1", "::ffff:100.101.102.103"] {
            XCTAssertEqual(LocalSecret.speechKey(requestHost: host, ownAddresses: own, localKey: "local", remoteKey: "remote"), "local", host)
            XCTAssertNil(LocalSecret.speechKey(requestHost: host, ownAddresses: own, localKey: nil, remoteKey: "remote"), host)
        }
        for host in ["100.101.102.104", "speech.example", "fd7a:115c:a1e0::2", "127.evil.example"] {
            XCTAssertEqual(LocalSecret.speechKey(requestHost: host, ownAddresses: own, localKey: "local", remoteKey: "remote"), "remote")
            XCTAssertEqual(LocalSecret.speechKey(requestHost: host, ownAddresses: own, localKey: "local", remoteKey: nil), "local")
            XCTAssertNil(LocalSecret.speechKey(requestHost: host, ownAddresses: own, localKey: nil, remoteKey: nil))
        }
    }

    func testEmptyInvalidOrUnreadableSpeechKeyIsNeverRegenerated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        LocalSecret.directoryOverrideForTesting = root
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("speech-server.token")
        for data in [Data(), Data(" \n".utf8), Data([0xff]), Data("key with spaces".utf8)] {
            try data.write(to: url)
            XCTAssertNil(LocalSecret.speechServerKey())
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertNil(LocalSecret.speechServerKey())
    }
}
