import Foundation

/// Where a prompt went, in the terms people use: the AI tool and its vendor
/// when one is known, otherwise the terminal or app it was typed into.
///
/// Resolved once per history read from what each row recorded, using the
/// tool catalog's own identifiers. Nothing is guessed from prompt text.
struct DatasetDestination: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// A catalog AI tool (ChatGPT, Claude Code…).
        case aiTool
        /// A terminal, multiplexer or agent app whose AI tool wasn't recorded.
        case terminal
        /// Any other app.
        case app
        /// Nothing about the destination was recorded.
        case unknown
    }

    var kind: Kind
    /// Stable filter key: `tool:<id>`, `terminal`, `app:<bundle or name>`, `unknown`.
    var key: String
    var name: String
    /// The AI tool's maker, for tools only ("Anthropic", "OpenAI").
    var vendor: String?

    var vendorKey: String? { vendor.map { Self.vendorKey($0) } }
    static func vendorKey(_ vendor: String) -> String { "vendor:\(vendor)" }

    static let unknown = DatasetDestination(kind: .unknown, key: "unknown", name: "Not recorded")
    static let terminal = DatasetDestination(kind: .terminal, key: "terminal", name: "Terminal or agent app, tool not recorded")
}

struct DatasetDestinationResolver: Sendable {
    let catalog: ToolCatalog

    /// Terminal multiplexers that report themselves as the app. The pane's
    /// program is resolved at capture time when it can be; here they only
    /// count as a terminal.
    static let multiplexers = ["herdr", "tmux", "zellij"]
    /// Apps that run Claude Code, Codex and others inside them without
    /// recording which one (T3 Code). Herdr is a terminal in the catalog.
    static let agentApps: Set<String> = ["com.t3tools.t3code"]

    func annotate(_ rows: [DatasetRow]) -> [DatasetRow] {
        rows.map { row in
            var row = row
            row.destination = resolve(row)
            return row
        }
    }

    func resolve(_ row: DatasetRow) -> DatasetDestination {
        let bundle = row.appBundleId.flatMap { $0.isEmpty ? nil : $0 }
        let appName = row.appName.map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }

        // 1. The tool the row recorded, then the tool that owns the app
        //    (ChatGPT.app), then the tool that owns the website.
        //    Editors host many things, so an editor alone never implies its AI panel.
        if let id = row.toolId, !id.isEmpty {
            if let tool = catalog.tool(id: id) { return Self.destination(for: tool) }
            return DatasetDestination(kind: .aiTool, key: "tool:\(id)", name: id, vendor: id)
        }
        if let tool = catalog.tool(forBundleID: bundle), tool.category != .editor {
            return Self.destination(for: tool)
        }
        if let tool = catalog.tool(forHost: row.webHost) { return Self.destination(for: tool) }

        // 2. Terminals, multiplexers and agent apps whose program wasn't recorded.
        let identity = (bundle ?? appName ?? "").lowercased()
        if catalog.hostApp(bundleID: bundle)?.kind == .terminal
            || row.destinationURL?.hasPrefix("terminal:") == true
            || Self.multiplexers.contains(where: { identity.contains($0) })
            || bundle.map(Self.agentApps.contains) == true {
            return .terminal
        }

        // 3. Any other app, under its own name.
        guard let identifier = bundle ?? appName else { return .unknown }
        let name = catalog.hostApp(bundleID: bundle)?.name ?? Self.displayName(appName: appName, bundle: bundle)
        return DatasetDestination(kind: .app, key: "app:\(identifier)", name: name)
    }

    private static func destination(for tool: ToolDefinition) -> DatasetDestination {
        DatasetDestination(kind: .aiTool, key: "tool:\(tool.id)", name: tool.name, vendor: tool.vendor ?? tool.name)
    }

    /// Strips invisible direction marks some apps put in their names (‎WhatsApp).
    static func clean(_ name: String) -> String {
        name.filter { !"\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}".contains($0) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A readable name when the app recorded only its bundle ID:
    /// `com.apple.ScreenSharing` → "Screen Sharing".
    static func displayName(appName: String?, bundle: String?) -> String {
        if let appName, !looksLikeBundleID(appName) { return appName }
        let raw = (bundle ?? appName ?? "").split(separator: ".").last.map(String.init) ?? ""
        var words = ""
        for (index, character) in raw.enumerated() {
            if index > 0, character.isUppercase, let previous = words.last, previous.isLowercase { words.append(" ") }
            words.append(character == "-" || character == "_" ? " " : character)
        }
        return words.isEmpty ? (bundle ?? appName ?? "Unknown app") : words.prefix(1).uppercased() + words.dropFirst()
    }

    static func looksLikeBundleID(_ value: String) -> Bool {
        !value.contains(" ") && value.split(separator: ".").count >= 3
    }
}

/// One vendor's entry in the "Sent to" list, with its products.
struct DatasetDestinationGroup: Identifiable, Equatable, Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        var key: String
        var name: String
        var count: Int
        var id: String { key }
    }

    var title: String
    /// Filter key for the whole group (`vendor:…`), when it has more than one product.
    var allKey: String?
    var allCount: Int
    var options: [Option]
    var id: String { title }

    /// AI vendors first (largest first), then terminals, other apps and unrecorded.
    static func groups(for rows: [DatasetRow]) -> [DatasetDestinationGroup] {
        var counts: [String: (destination: DatasetDestination, count: Int, names: [String: Int])] = [:]
        for row in rows {
            let destination = row.destination ?? .unknown
            var entry = counts[destination.key] ?? (destination, 0, [:])
            entry.count += 1
            entry.names[destination.name, default: 0] += 1
            counts[destination.key] = entry
        }
        func option(_ entry: (destination: DatasetDestination, count: Int, names: [String: Int])) -> Option {
            // One app can record a few spellings (Chrome / Google Chrome); show the most common.
            let name = entry.names.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? entry.destination.name
            return Option(key: entry.destination.key, name: name, count: entry.count)
        }
        let byCount: (Option, Option) -> Bool = { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }

        var vendors: [String: [Option]] = [:]
        var apps: [Option] = []
        var terminal: Option?, unknown: Option?
        for entry in counts.values {
            switch entry.destination.kind {
            case .aiTool: vendors[entry.destination.vendor ?? entry.destination.name, default: []].append(option(entry))
            case .app: apps.append(option(entry))
            case .terminal: terminal = option(entry)
            case .unknown: unknown = option(entry)
            }
        }
        var result: [DatasetDestinationGroup] = []
        for (vendor, options) in vendors {
            let total: Int = options.reduce(0) { $0 + $1.count }
            let allKey: String? = options.count > 1 ? DatasetDestination.vendorKey(vendor) : nil
            result.append(DatasetDestinationGroup(title: vendor, allKey: allKey, allCount: total, options: options.sorted(by: byCount)))
        }
        result.sort { (a: DatasetDestinationGroup, b: DatasetDestinationGroup) -> Bool in
            a.allCount == b.allCount ? a.title < b.title : a.allCount > b.allCount
        }
        if let terminal { result.append(DatasetDestinationGroup(title: "Terminals", allCount: terminal.count, options: [terminal])) }
        if !apps.isEmpty {
            result.append(DatasetDestinationGroup(title: "Other apps", allCount: apps.reduce(0) { $0 + $1.count }, options: apps.sorted(by: byCount)))
        }
        if let unknown { result.append(DatasetDestinationGroup(title: "Not recorded", allCount: unknown.count, options: [unknown])) }
        return result
    }

    static func label(for key: String, in groups: [DatasetDestinationGroup]) -> String? {
        for group in groups {
            if group.allKey == key { return "All \(group.title)" }
            if let option = group.options.first(where: { $0.key == key }) { return option.name }
        }
        if key.hasPrefix("vendor:") { return "All \(key.dropFirst(7))" }
        return nil
    }
}
