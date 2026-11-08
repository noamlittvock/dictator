import Foundation
import Observation

/// The AI tools Dictator knows how to recognise, and the apps they run in.
///
/// Users choose *tools* ("Claude Code", "ChatGPT"), never bundle IDs. The
/// catalog maps each tool to everything that identifies it — apps, web
/// domains, process names, config directories — and to the connector that
/// captures its prompts exactly. It ships as `tool-catalog.json` (canonical
/// copy in the repo's `shared/`), and a user's own additions live beside the
/// store in `custom-tools.json`, so recognising a new tool never needs a
/// code change.
struct ToolCatalog: Codable, Equatable, Sendable {
    var version: Int
    var tools: [ToolDefinition]
    var hostApps: [HostApp]

    enum CodingKeys: String, CodingKey {
        case version, tools
        case hostApps = "host_apps"
    }

    // MARK: Lookup

    func tool(id: String) -> ToolDefinition? {
        tools.first { $0.id == id }
    }

    func hostApp(bundleID: String?) -> HostApp? {
        guard let bundleID else { return nil }
        return hostApps.first { $0.bundleIDs.contains { Self.glob($0, matches: bundleID) } }
    }

    /// The tool whose own app this is (ChatGPT.app, Claude.app, Cursor…).
    func tool(forBundleID bundleID: String?) -> ToolDefinition? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return tools.first { tool in tool.signatures.bundleIDs.contains { Self.glob($0, matches: bundleID) } }
    }

    /// The tool served by this web host (claude.ai, chatgpt.com…).
    func tool(forHost host: String?) -> ToolDefinition? {
        guard let host else { return nil }
        return tools.first { tool in
            tool.signatures.domains.contains { SurfacePolicy.domainMatches(host: host, pattern: $0) }
        }
    }

    /// The tool a process is, judged from its executable path and the first
    /// entries of its argv (argv[0] included — a native `claude` binary's
    /// executable is a version-numbered file) only — never from arbitrary substrings (a project folder
    /// called `claude-notes` must not look like Claude Code).
    func tool(forProcess executable: String, arguments: [String]) -> ToolDefinition? {
        let candidates = ([executable] + arguments.prefix(3)).map {
            URL(fileURLWithPath: $0).lastPathComponent.lowercased()
        }
        let joined = ([executable] + arguments.prefix(3)).joined(separator: " ").lowercased()
        for tool in tools {
            let sig = tool.signatures
            if candidates.contains(where: { sig.processNames.contains($0) }) { return tool }
            if sig.argvPatterns.contains(where: { joined.contains($0.lowercased()) }) { return tool }
        }
        return nil
    }

    /// First word of a remote command (`ssh host claude -p …`) → tool.
    func tool(forCommandWords words: [String]) -> ToolDefinition? {
        for word in words {
            let base = URL(fileURLWithPath: word).lastPathComponent.lowercased()
            if let tool = tools.first(where: { $0.signatures.processNames.contains(base) }) {
                return tool
            }
        }
        return nil
    }

    static func glob(_ pattern: String, matches value: String) -> Bool {
        fnmatch(pattern, value, 0) == 0
    }

    // MARK: Loading

    /// Reading the observable value also invalidates views after custom-tool edits.
    private static let store = ToolCatalogStore()
    static var shared: ToolCatalog { store.catalog }

    static func reload() { store.reload() }

    static func load(
        bundled: URL? = Bundle.main.url(forResource: "tool-catalog", withExtension: "json"),
        custom: URL? = customToolsURL
    ) -> ToolCatalog {
        var catalog = bundled.flatMap { try? decode(Data(contentsOf: $0)) } ?? .empty
        if let custom, let extra = try? decode(Data(contentsOf: custom)) {
            catalog.merge(extra)
        }
        return catalog
    }

    static func decode(_ data: Data) throws -> ToolCatalog {
        try JSONDecoder().decode(ToolCatalog.self, from: data)
    }

    mutating func merge(_ other: ToolCatalog) {
        for tool in other.tools {
            if let index = tools.firstIndex(where: { $0.id == tool.id }) {
                tools[index] = tool
            } else {
                tools.append(tool)
            }
        }
        for app in other.hostApps where !hostApps.contains(where: { $0.id == app.id }) {
            hostApps.append(app)
        }
    }

    static let empty = ToolCatalog(version: 0, tools: [], hostApps: [])

    static var customToolsURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dictator/custom-tools.json")
    }

    /// Adds (or replaces) one user-defined tool and publishes the saved catalog.
    static func saveCustomTool(_ tool: ToolDefinition) throws {
        try store.saveCustomTool(tool)
    }

    static func removeCustomTool(id: String) throws {
        try store.removeCustomTool(id: id)
    }

    static func isCustomTool(id: String) -> Bool {
        guard let url = customToolsURL,
              let custom = try? decode(Data(contentsOf: url)) else { return false }
        return custom.tools.contains { $0.id == id }
    }
}

/// Owns the catalog's observable snapshot. A failed write leaves readers on the
/// previous snapshot; malformed custom files are reported rather than replaced.
@Observable
final class ToolCatalogStore {
    private(set) var catalog: ToolCatalog
    @ObservationIgnored private let bundled: URL?
    @ObservationIgnored private let custom: URL?
    @ObservationIgnored private let write: (Data, URL) throws -> Void

    init(bundled: URL? = Bundle.main.url(forResource: "tool-catalog", withExtension: "json"),
         custom: URL? = ToolCatalog.customToolsURL,
         write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.bundled = bundled
        self.custom = custom
        self.write = write
        catalog = ToolCatalog.load(bundled: bundled, custom: custom)
    }

    func reload() { catalog = ToolCatalog.load(bundled: bundled, custom: custom) }

    private func readCustom() throws -> (URL, ToolCatalog) {
        guard let custom else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The folder for your added tools is unavailable."])
        }
        guard FileManager.default.fileExists(atPath: custom.path) else {
            return (custom, ToolCatalog(version: 1, tools: [], hostApps: []))
        }
        return (custom, try ToolCatalog.decode(Data(contentsOf: custom)))
    }

    private func persist(_ value: ToolCatalog, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(encoder.encode(value), url)
        reload()
    }

    func saveCustomTool(_ tool: ToolDefinition) throws {
        let (url, existing) = try readCustom()
        var value = existing
        value.tools.removeAll { $0.id == tool.id }
        value.tools.append(tool)
        try persist(value, to: url)
    }

    func removeCustomTool(id: String) throws {
        let (url, existing) = try readCustom()
        var value = existing
        value.tools.removeAll { $0.id == id }
        try persist(value, to: url)
    }
}

enum ToolCategory: String, Codable, CaseIterable, Sendable {
    /// Coding agents that run in a terminal (Claude Code, Codex, Gemini CLI…).
    case agent
    /// Chat assistants, as a desktop app, a website, or both (ChatGPT,
    /// Claude, Gemini, Perplexity…).
    case chat
    /// AI panels inside code editors (Cursor, Windsurf, VS Code chat…).
    case editor

    var title: String {
        switch self {
        case .agent: "Coding agents"
        case .chat: "Chat & assistants"
        case .editor: "Editor assistants"
        }
    }

    var subtitle: String {
        switch self {
        case .agent: "In any terminal, an editor's terminal, tmux, or over SSH"
        case .chat: "Their desktop apps and websites"
        case .editor: "The chat / agent panel — never the code you type"
        }
    }
}

struct ToolDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var vendor: String?
    var category: ToolCategory
    /// Pre-checked in first-run setup when the tool is found on this Mac.
    var defaultOn: Bool
    var signatures: ToolSignatures
    /// How to capture the tool's prompts exactly, if it can be.
    var connector: ToolConnector?
    /// Read the composer through Accessibility on submit (desktop and web
    /// chat surfaces). Keystroke reconstruction stays the fallback.
    var readsComposer: Bool
    var symbol: String?

    enum CodingKeys: String, CodingKey {
        case id, name, vendor, category, signatures, connector, symbol
        case defaultOn = "default_on"
        case readsComposer = "reads_composer"
    }

    init(
        id: String,
        name: String,
        vendor: String? = nil,
        category: ToolCategory,
        defaultOn: Bool = true,
        signatures: ToolSignatures = ToolSignatures(),
        connector: ToolConnector? = nil,
        readsComposer: Bool = false,
        symbol: String? = nil
    ) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.category = category
        self.defaultOn = defaultOn
        self.signatures = signatures
        self.connector = connector
        self.readsComposer = readsComposer
        self.symbol = symbol
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        category = try c.decode(ToolCategory.self, forKey: .category)
        defaultOn = try c.decodeIfPresent(Bool.self, forKey: .defaultOn) ?? true
        signatures = try c.decodeIfPresent(ToolSignatures.self, forKey: .signatures) ?? ToolSignatures()
        connector = try c.decodeIfPresent(ToolConnector.self, forKey: .connector)
        readsComposer = try c.decodeIfPresent(Bool.self, forKey: .readsComposer) ?? false
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
    }

    var displaySymbol: String {
        symbol ?? {
            switch category {
            case .agent: "terminal"
            case .chat: "bubble.left.and.bubble.right"
            case .editor: "chevron.left.forwardslash.chevron.right"
            }
        }()
    }
}

struct ToolSignatures: Codable, Equatable, Sendable {
    var bundleIDs: [String] = []
    var domains: [String] = []
    /// Executable basenames (`claude`, `codex`, `gemini`).
    var processNames: [String] = []
    /// Substrings of the first arguments that identify a script-launched
    /// tool (`@anthropic-ai/claude-code`, `@openai/codex`).
    var argvPatterns: [String] = []
    /// `~`-relative directories whose presence means the tool is installed.
    var configDirs: [String] = []

    enum CodingKeys: String, CodingKey {
        case bundleIDs = "bundle_ids"
        case domains
        case processNames = "process_names"
        case argvPatterns = "argv_patterns"
        case configDirs = "config_dirs"
    }

    init(
        bundleIDs: [String] = [],
        domains: [String] = [],
        processNames: [String] = [],
        argvPatterns: [String] = [],
        configDirs: [String] = []
    ) {
        self.bundleIDs = bundleIDs
        self.domains = domains
        self.processNames = processNames
        self.argvPatterns = argvPatterns
        self.configDirs = configDirs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        processNames = try c.decodeIfPresent([String].self, forKey: .processNames) ?? []
        argvPatterns = try c.decodeIfPresent([String].self, forKey: .argvPatterns) ?? []
        configDirs = try c.decodeIfPresent([String].self, forKey: .configDirs) ?? []
    }
}

/// How a tool's prompts are captured at the source. `hookFormat` names the
/// installer (which config file, which JSON shape); `transcript` names the
/// reader used when the user prefers not to change the tool's config.
struct ToolConnector: Codable, Equatable, Sendable {
    var hookFormat: String?
    /// `~`-relative config file the hook is registered in.
    var hookConfig: String?
    var hookEvent: String?
    /// What the shim prints on stdout for tools that require a JSON answer
    /// (Cursor wants `{"continue":true}`, Antigravity `{}`); nothing otherwise.
    var hookReply: String?
    /// Dotted path of the prompt text inside the hook's stdin JSON.
    var promptField: String
    var sessionField: String?
    var cwdField: String?
    var transcript: TranscriptSource?
    /// Shown in Settings next to the tool.
    var note: String?

    enum CodingKeys: String, CodingKey {
        case note, transcript
        case hookFormat = "hook_format"
        case hookConfig = "hook_config"
        case hookEvent = "hook_event"
        case hookReply = "hook_reply"
        case promptField = "prompt_field"
        case sessionField = "session_field"
        case cwdField = "cwd_field"
    }

    var supportsHook: Bool { hookFormat != nil && hookConfig != nil }
}

struct TranscriptSource: Codable, Equatable, Sendable {
    /// Parser to use: `claude-jsonl`, `codex-history`, `codex-rollout`.
    var format: String
    /// `~`-relative directory or file to watch.
    var path: String
    /// Glob of files inside `path` (for directories).
    var glob: String?
}

/// An app prompts can be typed *into* without it being the tool itself:
/// terminals, code editors, browsers.
struct HostApp: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case terminal
        case editor
        case browser
    }

    var id: String
    var name: String
    var kind: Kind
    var bundleIDs: [String]
    /// AppleScript dialect for reading the front tab's URL (browsers).
    var urlScript: String?
    var runsScripts: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case bundleIDs = "bundle_ids"
        case urlScript = "url_script"
        case runsScripts = "runs_scripts"
    }

    init(id: String, name: String, kind: Kind, bundleIDs: [String], urlScript: String? = nil, runsScripts: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.bundleIDs = bundleIDs
        self.urlScript = urlScript; self.runsScripts = runsScripts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind); bundleIDs = try c.decode([String].self, forKey: .bundleIDs)
        urlScript = try c.decodeIfPresent(String.self, forKey: .urlScript)
        runsScripts = try c.decodeIfPresent(Bool.self, forKey: .runsScripts) ?? false
    }
}
