import AppKit

/// What Dictator knows about browsers on this Mac.
enum WorkspaceBrowsers {
    static let maxLocalStateBytes = 8 * 1024 * 1024

    struct Application: Sendable {
        var bundleID: String
        var name: String
    }

    struct CatalogEntry: Decodable, Equatable, Sendable {
        var bundleID: String
        var profileRoot: String

        enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id"
            case profileRoot = "profile_root"
        }

        func root(in applicationSupport: URL) -> URL? {
            let parts = profileRoot.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !profileRoot.contains("\\"), !profileRoot.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
            return applicationSupport.appendingPathComponent(profileRoot, isDirectory: true)
        }
    }

    enum LaunchRequest: Equatable, Sendable {
        case application(arguments: [String])
        case addresses([URL])
    }

    static func catalog(from data: Data) -> [CatalogEntry] {
        struct Catalog: Decodable { var browsers: [CatalogEntry] }
        return (try? JSONDecoder().decode(Catalog.self, from: data).browsers) ?? []
    }

    static let bundledCatalog: [CatalogEntry] = {
        guard let url = Bundle.main.url(forResource: "tool-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return catalog(from: data)
    }()

    /// Catalog browsers receive --new-window; other browsers choose their own destination.
    static func opensItsOwnWindow(bundleID: String, catalog: [CatalogEntry] = bundledCatalog) -> Bool {
        catalog.contains { $0.bundleID == bundleID }
    }

    static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Only profile folders, display names and their order are inspected.
    static func profiles(fromLocalState data: Data) -> [WorkspaceBrowserProfile] {
        guard data.count <= maxLocalStateBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        var valid: [String: WorkspaceBrowserProfile] = [:]
        for (directory, value) in cache {
            guard let info = value as? [String: Any] else { continue }
            let name: String
            if let value = info["name"], !(value is NSNull) {
                guard let text = value as? String else { continue }
                name = text
            } else { name = directory }
            let item = WorkspaceBrowserProfile(directory: directory, name: name)
            if item.isValid { valid[directory] = item }
        }
        let counts = Dictionary(grouping: valid.values, by: \.name).mapValues(\.count)
        let listed = (profile["profiles_order"] as? [Any])?.compactMap { $0 as? String } ?? []
        var seen = Set<String>()
        var result: [WorkspaceBrowserProfile] = []
        for directory in listed + valid.keys.sorted() {
            guard seen.insert(directory).inserted, var item = valid[directory] else { continue }
            if counts[item.name, default: 0] > 1 { item.name += " (\(directory))" }
            guard item.isValid else { continue }
            result.append(item)
            if result.count == 50 { break }
        }
        return result
    }

    static func launchArguments(profileDirectory: String?, urls: [String]) -> [String]? {
        guard !urls.isEmpty, urls.allSatisfy(WorkspaceTabAddress.isAllowed) else { return nil }
        var arguments: [String] = []
        if let directory = profileDirectory {
            guard WorkspaceBrowserProfile(directory: directory, name: "Profile").isValid else { return nil }
            arguments.append("--profile-directory=\(directory)")
        }
        return arguments + ["--new-window", "--"] + urls
    }

    /// Injection keeps discovery independent of LaunchServices and personal browser files.
    static func assemble(apps: [Application], defaultBundleID: String?, excludedBundleIDs: Set<String>,
                         catalog: [CatalogEntry], applicationSupport: URL,
                         readFile: (URL, Int) -> Data?) -> [WorkspaceBrowserInfo] {
        var seen = Set<String>()
        return apps.compactMap { app -> WorkspaceBrowserInfo? in
            guard !excludedBundleIDs.contains(app.bundleID), seen.insert(app.bundleID).inserted else { return nil }
            var profiles: [WorkspaceBrowserProfile] = []
            if let entry = catalog.first(where: { $0.bundleID == app.bundleID }),
               let root = entry.root(in: applicationSupport),
               let data = readFile(root.appendingPathComponent("Local State"), maxLocalStateBytes), data.count <= maxLocalStateBytes {
                profiles = self.profiles(fromLocalState: data)
            }
            let browser = WorkspaceBrowserInfo(bundleID: app.bundleID, name: app.name, profiles: profiles)
            return browser.isValid ? browser : nil
        }.sorted { left, right in
            if (left.bundleID == defaultBundleID) != (right.bundleID == defaultBundleID) { return left.bundleID == defaultBundleID }
            let order = left.name.localizedCaseInsensitiveCompare(right.name)
            return order == .orderedSame ? left.bundleID < right.bundleID : order == .orderedAscending
        }
    }

    /// A stale Local State entry must never cause Chromium to create a new profile.
    static func launchRequest(bundleID: String, profileDirectory: String?, urls: [String],
                              catalog: [CatalogEntry], applicationSupport: URL,
                              isDirectory: (URL) -> Bool) -> LaunchRequest? {
        guard let arguments = launchArguments(profileDirectory: profileDirectory, urls: urls) else { return nil }
        if let entry = catalog.first(where: { $0.bundleID == bundleID }) {
            if let directory = profileDirectory {
                guard let root = entry.root(in: applicationSupport),
                      isDirectory(root.appendingPathComponent(directory, isDirectory: true)) else { return nil }
            }
            return .application(arguments: arguments)
        }
        guard profileDirectory == nil else { return nil }
        let addresses = urls.compactMap(URL.init(string:))
        return addresses.count == urls.count ? .addresses(addresses) : nil
    }

    private static func readLocalState(at url: URL, maximumBytes: Int) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else { return nil }
        return data
    }

    /// Every app that opens web addresses, with profiles where Dictator can read them.
    static func installed() async -> [WorkspaceBrowserInfo] {
        let (apps, defaultBundleID, excluded) = await MainActor.run {
            let address = URL(string: "https://example.com")!
            let workspace = NSWorkspace.shared
            let defaultBundleID = workspace.urlForApplication(toOpen: address).flatMap { Bundle(url: $0)?.bundleIdentifier }
            let apps = workspace.urlsForApplications(toOpen: address).compactMap { url -> Application? in
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                return Application(bundleID: id, name: name)
            }
            let excluded = Set([Bundle.main.bundleIdentifier, "dev.noamlitt.dictator", "dev.noamlitt.dictator.development"].compactMap { $0 })
            return (apps, defaultBundleID, excluded)
        }
        return await Task.detached(priority: .utility) {
            assemble(apps: apps, defaultBundleID: defaultBundleID, excludedBundleIDs: excluded,
                     catalog: bundledCatalog, applicationSupport: applicationSupport, readFile: readLocalState)
        }.value
    }
}
