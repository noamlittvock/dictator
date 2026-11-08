import AppKit
import Foundation
import Security
import Darwin

/// Shared helpers for local-only secrets: per-machine tokens written under
/// `~/Library/Application Support/Dictator/` (e.g. the pairing token).
enum LocalSecret {
    /// Overrides the directory used for token storage. Tests set this to a
    /// temporary directory so they never touch the user's real Application
    /// Support folder, then reset it to nil in tearDown.
    static var directoryOverrideForTesting: URL?

    /// Constant-time string comparison, used to avoid leaking token length
    /// or content via timing side channels.
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    /// The `Dictator` directory under Application Support, created 0700 if
    /// it does not already exist.
    static func applicationSupportDirectory(createIfNeeded: Bool = true) throws -> URL {
        let fileManager = FileManager.default
        let directory: URL
        if let override = directoryOverrideForTesting {
            directory = override
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            directory = applicationSupport.appendingPathComponent("Dictator", isDirectory: true)
        }

        guard createIfNeeded else { return directory }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private static func speechServerKeyURL() throws -> URL {
        if directoryOverrideForTesting == nil,
           let path = ProcessInfo.processInfo.environment["DICTATION_TOKEN_FILE"] {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return try applicationSupportDirectory(createIfNeeded: false).appendingPathComponent("speech-server.token")
    }

    /// Reads the server's key on each request, including after the server's first startup.
    /// Never creates a key, and never routes it through preferences or shared settings.
    static func speechServerKey() -> String? {
        readSpeechKey(at: try? speechServerKeyURL())
    }

    static func remoteSpeechServerKey() -> String? {
        readSpeechKey(at: try? remoteSpeechServerKeyURL())
    }

    private static func remoteSpeechServerKeyURL() throws -> URL {
        try applicationSupportDirectory(createIfNeeded: false).appendingPathComponent("speech-server-remote.token")
    }

    private static func readSpeechKey(at url: URL?) -> String? {
        guard let url, let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return validSpeechServerKey(key) ? key : nil
    }

    /// Pure selection: this Mac's server always uses its own key, even over Tailscale.
    static func speechKey(requestHost: String, ownAddresses: Set<String>, localKey: String?, remoteKey: String?) -> String? {
        let host = normalizedAddress(requestHost)
        let local = host == "localhost" || host == "::1" || (host.hasPrefix("127.") && host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { UInt8($0) != nil })
            || ownAddresses.contains { normalizedAddress($0) == host }
        return local ? localKey : (remoteKey ?? localKey)
    }

    private static func normalizedAddress(_ host: String) -> String {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
            .components(separatedBy: "%")[0]
        var address = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 {
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return bytes.suffix(4).map(String.init).joined(separator: ".")
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil { return String(cString: buffer) }
        }
        return value
    }

    static func ownInterfaceAddresses() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var addresses = Set<String>()
        var current = head
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.insert(String(cString: buffer))
            }
        }
        return addresses
    }

    enum SpeechKeyError: Error, LocalizedError {
        case invalid, saveFailed
        var errorDescription: String? {
            switch self {
            case .invalid: "Paste the speech server’s key without spaces or line breaks."
            case .saveFailed: "Dictator couldn’t save the speech server key. Check access to its file in Application Support and try again."
            }
        }
    }

    private static func validSpeechServerKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.allSatisfy { (33...126).contains($0) }
    }

    /// Puts a secret on the clipboard to carry to another Mac. Marked concealed,
    /// so clipboard managers skip it, and taken back after `lifetime` unless
    /// something else has been copied since.
    @MainActor
    static func copyToClipboard(_ secret: String, on pasteboard: NSPasteboard = .general, lifetime: TimeInterval = 120) {
        pasteboard.clearContents()
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let copied = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(lifetime))
            if pasteboard.changeCount == copied { pasteboard.clearContents() }
        }
    }

    /// Saves only the pasted remote key. The local server owns speech-server.token.
    static func saveSpeechServerKey(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validSpeechServerKey(key) else { throw SpeechKeyError.invalid }
        do {
            let url = try remoteSpeechServerKeyURL()
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try writePrivateSecret(key, to: url)
        } catch {
            throw SpeechKeyError.saveFailed
        }
    }

    private enum SecretWriteError: Error, LocalizedError {
        case saveFailed
        var errorDescription: String? {
            "Dictator couldn’t save its connection details. Check access to its files and try again."
        }
    }

    /// Only the rename publishes the replacement. Any earlier failure leaves
    /// the existing secret untouched, and no temporary file is world-readable.
    static func writePrivateSecret(_ value: String, to url: URL,
                                   beforeRename: () throws -> Void = {}) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".secret-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw SecretWriteError.saveFailed }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        guard fchmod(fd, 0o600) == 0 else { throw SecretWriteError.saveFailed }
        try Data(value.utf8).withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = write(fd, buffer.baseAddress! + written, buffer.count - written)
                guard count > 0 else { throw SecretWriteError.saveFailed }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw SecretWriteError.saveFailed }
        try beforeRename()
        guard rename(temporary.path, url.path) == 0 else { throw SecretWriteError.saveFailed }
    }

    /// Generates and atomically replaces the main Mac's shared pairing token.
    /// The caller must swap its in-memory value only after this returns.
    static func rotateSharedToken(fileName: String = "core-pairing.token") throws -> String {
        let directory = try applicationSupportDirectory()
        let token = try randomToken()
        try writePrivateSecret(token, to: directory.appendingPathComponent(fileName))
        return token
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Dictator couldn’t create the key other Macs use to connect to this one."])
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A stable, per-machine random token stored at
    /// `<applicationSupportDirectory>/<fileName>`, 0600, 64 lowercase-hex
    /// characters (32 random bytes). Reuses an existing valid file rather
    /// than regenerating on every call.
    static func sharedToken(fileName: String) throws -> String {
        let fileManager = FileManager.default
        let directory = try applicationSupportDirectory()
        let tokenURL = directory.appendingPathComponent(fileName)

        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           isValidToken(existing) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            return existing
        }

        let token = try randomToken()

        // Exclusive create so two processes racing on a missing token (e.g. a
        // relaunch overlapping the old instance) cannot each write their own
        // value; the loser re-reads the winner's file.
        let fd = open(tokenURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 {
            defer { close(fd) }
            var written = 0
            try Data(token.utf8).withUnsafeBytes { buffer in
                while written < buffer.count {
                    let n = write(fd, buffer.baseAddress! + written, buffer.count - written)
                    guard n > 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                                      userInfo: [NSLocalizedDescriptionKey: "Dictator couldn’t save the key other Macs use to connect to this one."])
                    }
                    written += n
                }
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            return token
        }
        guard errno == EEXIST else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Dictator couldn’t save the key other Macs use to connect to this one."])
        }
        // Lost the race, or the existing file was invalid: read what is there
        // now, and only replace it if it is still unusable.
        if let winner = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           isValidToken(winner) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            return winner
        }
        try Data(token.utf8).write(to: tokenURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return token
    }

    private static func isValidToken(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}
