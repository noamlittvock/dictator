import AppKit

/// Website icons for Voice launch cards. Asks the website itself first
/// (`apple-touch-icon.png`, then `favicon.ico`). No icon service is used.
/// Only the host name is sent, never anything you said.
/// Icons are kept in Caches, so each site is
/// asked once; a site with no icon is asked again the next time Dictator starts.
@MainActor
final class SiteIconStore {
    static let shared = SiteIconStore()

    private var memory: [String: NSImage] = [:]
    private var missing = Set<String>()
    private var loading: [String: Task<NSImage?, Never>] = [:]

    /// No network while tests run.
    private let enabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        && NSClassFromString("XCTestCase") == nil

    private nonisolated static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Dictator")
            .appendingPathComponent("SiteIcons")
    }

    /// The icon when it is already known, without asking the network.
    func cached(_ host: String) -> NSImage? {
        if let image = memory[host] { return image }
        guard enabled, !missing.contains(host), let file = Self.directory?.appendingPathComponent(host),
              let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { return nil }
        memory[host] = image
        return image
    }

    /// Whether asking again is pointless this session.
    func isMissing(_ host: String) -> Bool { !enabled || missing.contains(host) }

    func icon(for host: String) async -> NSImage? {
        if let image = cached(host) { return image }
        guard enabled, !missing.contains(host), VoiceIconSource.cleanHost(host) == host else { return nil }
        if let task = loading[host] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let data = await Self.download(host), let image = NSImage(data: data) else { return nil }
            if let directory = Self.directory {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appendingPathComponent(host), options: .atomic)
            }
            return image
        }
        loading[host] = task
        let image = await task.value
        loading[host] = nil
        if let image { memory[host] = image } else { missing.insert(host) }
        return image
    }

    private nonisolated static func download(_ host: String) async -> Data? {
        let addresses = [
            "https://\(host)/apple-touch-icon.png",
            "https://\(host)/favicon.ico",
        ]
        for address in addresses {
            guard let url = URL(string: address) else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 1_000_000,
                  let image = NSImage(data: data),
                  image.size.width >= 16 else { continue }
            return data
        }
        return nil
    }
}
