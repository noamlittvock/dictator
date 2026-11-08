import Foundation

/// Errors surfaced by `PairingCredentialStore`.
enum PairingCredentialError: Error, LocalizedError, Equatable {
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .storage(let message):
            return message
        }
    }
}

/// Stores the Core pairing token an Edge holds for each Core it has paired
/// with, keyed by the Core's tailnet address, as a 0600 file under
/// `~/Library/Application Support/Dictator/pairing/` — the same posture as
/// the Core's own `core-pairing.token` (`LocalSecret`). The token never lands
/// in UserDefaults or in logs. (Not the Keychain: it re-prompts for access
/// whenever a self-signed app binary changes, and that prompt can sit
/// unanswered on a Mac nobody is looking at.) Tests redirect storage with
/// `LocalSecret.directoryOverrideForTesting`.
enum PairingCredentialStore {
    private static let directoryName = "pairing"

    /// Saves `token` for the Core at `address`, replacing any existing one.
    static func save(token: String, forCore address: String) throws {
        let url = try fileURL(forCore: address)
        do {
            try LocalSecret.writePrivateSecret(token, to: url)
        } catch {
            throw PairingCredentialError.storage("Couldn't save the pairing token: \(error.localizedDescription)")
        }
    }

    /// The stored token for the Core at `address`, or nil if none exists.
    static func token(forCore address: String) throws -> String? {
        let url = try fileURL(forCore: address)
        if let data = try? Data(contentsOf: url),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        return nil
    }

    /// Removes the stored token for the Core at `address`, if any. Tolerates
    /// there being nothing to delete.
    static func delete(forCore address: String) throws {
        let url = try fileURL(forCore: address)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw PairingCredentialError.storage("Couldn't remove the pairing token: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - File storage

    private static func fileURL(forCore address: String) throws -> URL {
        let base: URL
        do {
            base = try LocalSecret.applicationSupportDirectory()
                .appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PairingCredentialError.storage("Couldn't open the pairing token folder: \(error.localizedDescription)")
        }
        return base.appendingPathComponent(fileName(forCore: address))
    }

    /// One file per Core address; the address is made filesystem-safe.
    static func fileName(forCore address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let safe = trimmed.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" ? character : "_"
        }
        return String(safe) + ".token"
    }
}
