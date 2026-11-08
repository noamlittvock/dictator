import Foundation

/// A browser profile on one Mac. Only the folder name and the name the person
/// sees are kept; sign-in details such as email addresses are never read.
struct WorkspaceBrowserProfile: Codable, Equatable, Hashable, Sendable, Identifiable {
    var directory: String
    var name: String
    var id: String { directory }
    init(directory: String, name: String) { self.directory = directory; self.name = name }

    /// The folder becomes a launch argument, so it can't be a path or a flag.
    var isValid: Bool {
        (1...255).contains(directory.count) && directory != "." && directory != ".." && !directory.hasPrefix("-")
            && !directory.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120
    }
}

/// A browser found on one Mac. `profiles` is empty for a browser Dictator
/// can't open a named profile in.
struct WorkspaceBrowserInfo: Codable, Equatable, Sendable, Identifiable {
    var bundleID: String
    var name: String
    var profiles: [WorkspaceBrowserProfile]
    var id: String { bundleID }
    init(bundleID: String, name: String, profiles: [WorkspaceBrowserProfile] = []) {
        self.bundleID = bundleID; self.name = name; self.profiles = profiles
    }

    var isValid: Bool {
        (1...255).contains(bundleID.count) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120
            && profiles.count <= 50 && profiles.allSatisfy(\.isValid) && Set(profiles.map(\.directory)).count == profiles.count
    }
}

/// One browser window to open on one Mac: which browser, which profile and
/// which addresses, in tab order. `profile` nil means the browser decides.
struct WorkspaceTabSet: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var macID: String
    var macName: String
    var browserBundleID: String
    var browserName: String
    var profile: WorkspaceBrowserProfile?
    var urls: [String]
    /// Where this one window goes. Nil leaves it where the browser puts it.
    /// A person can only set these together. Optional for routines saved earlier.
    var monitor: WorkspaceMonitorChoice?
    var position: WorkspacePosition?

    static let maxTabs = 50
    static let maxAddressLength = 2048

    init(id: String = UUID().uuidString, macID: String, macName: String, browserBundleID: String,
         browserName: String, profile: WorkspaceBrowserProfile? = nil, urls: [String] = [],
         monitor: WorkspaceMonitorChoice? = nil, position: WorkspacePosition? = nil) {
        self.id = id; self.macID = macID; self.macName = macName; self.browserBundleID = browserBundleID
        self.browserName = browserName; self.profile = profile; self.urls = urls
        self.monitor = monitor; self.position = position
    }

    var isValid: Bool {
        (1...255).contains(id.count) && (1...64).contains(macID.count) && (1...120).contains(macName.count)
            && !browserBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && browserBundleID.count <= 255
            && !browserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && browserName.count <= 120
            && ((monitor == nil && position == nil) || (monitor?.isValid == true && position != nil))
            && (profile?.isValid ?? true) && (1...Self.maxTabs).contains(urls.count) && urls.allSatisfy(WorkspaceTabAddress.isAllowed)
    }

    /// What makes two windows the same window. Stays in memory.
    var signature: [String] { [browserBundleID, profile?.directory ?? ""] + urls }

    /// "Chrome (Work)", or "Chrome" when the browser decides the profile.
    var browserLabel: String { profile.map { "\(browserName) (\($0.name))" } ?? browserName }

    func isLocal(_ id: String?, aliases: Set<String> = []) -> Bool { macID == id || aliases.contains(macID) }
}

/// Turns what a person types into an address that is safe to hand to a browser.
enum WorkspaceTabAddress {
    /// A clean http or https address, or nil when it isn't one.
    static func normalize(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= WorkspaceTabSet.maxAddressLength,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
              }) else { return nil }
        let lower = text.lowercased()
        let candidate: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            candidate = text
        } else if hasOtherScheme(text) {
            return nil
        } else {
            let host = lower.prefix { $0 != "/" && $0 != ":" && $0 != "?" && $0 != "#" }
            let isLocal = host == "localhost" || host == "127.0.0.1"
            // IDNA also accepts these Unicode forms of the domain separator.
            let dottedHost = host.replacingOccurrences(of: "。", with: ".")
                .replacingOccurrences(of: "．", with: ".").replacingOccurrences(of: "｡", with: ".")
            guard isLocal || (dottedHost.contains(".") && !dottedHost.hasPrefix("-") && !dottedHost.hasPrefix(".")) else { return nil }
            candidate = (isLocal ? "http://" : "https://") + text
        }
        guard let parts = URLComponents(string: candidate), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        var clean = parts
        clean.scheme = scheme
        guard let result = clean.string, result.utf8.count <= WorkspaceTabSet.maxAddressLength else { return nil }
        return result
    }

    /// "mailto:", "javascript:" and "chrome://" all count; "example.com:8080" does not.
    private static func hasOtherScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let name = text[..<colon]
        guard let first = name.first, first.isASCII, first.isLetter,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }) else { return false }
        let rest = text[text.index(after: colon)...]
        let port = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return port.isEmpty || !port.allSatisfy(\.isNumber) || !(name.contains(".") || name.lowercased() == "localhost")
    }

    /// True only for an address `normalize` would leave unchanged.
    static func isAllowed(_ address: String) -> Bool { normalize(address) == address }
    /// One address per line. Blank lines are ignored and duplicates are kept,
    /// because a person may want the same page twice.
    static func parse(_ text: String) -> (addresses: [String], rejected: [String]) {
        var addresses: [String] = [], rejected: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let address = normalize(trimmed) { addresses.append(address) } else { rejected.append(trimmed) }
        }
        return (addresses, rejected)
    }
}

/// Thrown when a browser hasn't answered in time. The request can't be taken
/// back, so its tabs may still appear: this is not the same as "didn't open".
struct WorkspaceTabOpenTimedOut: Error {}

/// The lines a person reads about tab sets. They name no addresses, because
/// these lines reach status text. Failure lines must use browser names only.
enum WorkspaceTabWords {
    /// "Chrome (Work) will open 3 tabs on Studio." Only some browsers can promise
    /// a new window, so this line doesn't.
    static func preview(_ set: WorkspaceTabSet) -> String {
        let place = set.monitor.flatMap { _ in set.position.map { ", \($0.label)" } } ?? ""
        return "\(set.browserLabel) will open \(count(set.urls.count)) on \(set.macName)\(place)."
    }
    /// A note when the set can't open here, or nil when it can.
    static func blocked(_ set: WorkspaceTabSet, browsers: [WorkspaceBrowserInfo], macName: String, preview: Bool) -> String? {
        let result = preview ? "won't open" : "didn't open"
        guard let browser = browsers.first(where: { $0.bundleID == set.browserBundleID }) else {
            return "\(set.browserName) isn't on \(macName), so its tabs \(result)."
        }
        if let profile = set.profile, !browser.profiles.contains(where: { $0.directory == profile.directory }) {
            return "\(set.browserName) on \(macName) can't find the selected profile, so its tabs \(result)."
        }
        return nil
    }
    /// "2 windows, 5 tabs".
    static func summary(_ sets: [WorkspaceTabSet]) -> String {
        let windows = sets.count == 1 ? "1 window" : "\(sets.count) windows"
        return "\(windows), \(count(sets.reduce(0) { $0 + $1.urls.count }))"
    }

    static func failure(browsers: [String], macName: String) -> String {
        "\(WorkspaceWords.list(browsers)) couldn't open its tabs on \(macName). Check this routine in Workspaces."
    }

    static func slow(browsers: [String], macName: String) -> String {
        "\(WorkspaceWords.list(browsers)) was slow to open on \(macName), so its tabs may still appear."
    }

    /// "Bring back 2 windows".
    static func bringBack(_ count: Int) -> String { count == 1 ? "Bring back 1 window" : "Bring back \(count) windows" }

    /// "3 tabs", "1 tab".
    static func count(_ tabs: Int) -> String { tabs == 1 ? "1 tab" : "\(tabs) tabs" }
}
