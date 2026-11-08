import Darwin
import Foundation

public enum SurfaceAction: String, Codable, Sendable, Equatable {
    case save
    case ignore
}

public enum SurfaceModality: String, Codable, Sendable, Equatable {
    case both
    case typed
    case voice
}

/// One override: a rare exception layered over the per-tool switches ("Codex over ssh to
/// work-box: don't save", "Slack: save typed").
public struct SurfaceRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(kind):\(pattern):\(modality):\(action)" }
    public var kind: String
    public var pattern: String
    public var action: String
    public var modality: String

    public init(
        kind: String,
        pattern: String,
        action: String,
        modality: String = "both"
    ) {
        self.kind = kind
        self.pattern = pattern
        self.action = action
        self.modality = modality
    }

    public enum CodingKeys: String, CodingKey {
        case kind
        case pattern
        case action
        case modality
    }
}

/// Per-tool switch (v2). `typed` saves prompts typed or submitted to the
/// tool; `voice == false` additionally stops saving dictation into it.
public struct ToolSwitch: Codable, Sendable, Equatable {
    public var typed: Bool
    public var voice: Bool?

    public init(typed: Bool, voice: Bool? = nil) {
        self.typed = typed
        self.voice = voice
    }
}

/// Why something was (or wasn't) saved — stored on each entry and shown by
/// "Why was this saved?".
struct CaptureDecision: Equatable, Sendable {
    var action: SurfaceAction
    /// `override:<rule id>`, `tool:<id>`, `tool-off:<id>`, `tool-unset:<id>`,
    /// `default:typed`, `default:voice`, `paused`,
    /// `history-off`.
    var reason: String

    var isSave: Bool { action == .save }

    func explanation(catalog: ToolCatalog = .shared) -> String {
        let parts = reason.split(separator: ":", maxSplits: 1).map(String.init)
        let head = parts.first ?? reason
        let tail = parts.count > 1 ? parts[1] : ""
        let toolName = catalog.tool(id: tail)?.name ?? tail
        switch head {
        case "override":
            let rule = tail.split(separator: ":", maxSplits: 1).map(String.init)
            let what = rule.count >= 2 ? ExceptionDescription.target(kind: rule[0], pattern: rule[1], catalog: catalog) : tail
            return action == .save ? "An exception you added saves prompts from \(what)." : "An exception you added ignores \(what)."
        case "tool":
            return "Typed history is on for \(toolName) (Settings › History & Privacy › Choose Apps)."
        case "tool-off":
            return "Typed history is off for \(toolName)."
        case "tool-unset":
            return "Typed history isn't on for \(toolName)."
        case "default":
            if tail == "voice" {
                return action == .save ? "Dictation is saved everywhere." : "Dictation saving is turned off."
            }
            return action == .save ? "\"Keep everything I type\" is on." : "Typing here isn't kept."
        case "paused":
            return "Typed history is paused."
        case "history-off":
            return "History is turned off."
        default:
            return reason
        }
    }
}

public struct SurfacePolicy: Codable, Sendable, Equatable {
    public var defaultTyped: String
    public var defaultVoice: String
    /// Overrides evaluated before the tool switches.
    public var rules: [SurfaceRule]
    public var version: Int?
    public var tools: [String: ToolSwitch]?
    /// Replace API keys, tokens and private keys with `[redacted]` before a
    /// prompt is stored (default on).
    public var scrubSecrets: Bool?

    public enum CodingKeys: String, CodingKey {
        case defaultTyped = "default_typed"
        case defaultVoice = "default_voice"
        case rules
        case version
        case tools
        case scrubSecrets = "scrub_secrets"
    }

    public init(
        defaultTyped: String = "ignore",
        defaultVoice: String = "save",
        rules: [SurfaceRule] = [],
        version: Int? = nil,
        tools: [String: ToolSwitch]? = nil,
        scrubSecrets: Bool? = nil
    ) {
        self.defaultTyped = defaultTyped
        self.defaultVoice = defaultVoice
        self.rules = rules
        self.version = version
        self.tools = tools
        self.scrubSecrets = scrubSecrets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultTyped = try c.decodeIfPresent(String.self, forKey: .defaultTyped) ?? "ignore"
        defaultVoice = try c.decodeIfPresent(String.self, forKey: .defaultVoice) ?? "save"
        rules = try c.decodeIfPresent([SurfaceRule].self, forKey: .rules) ?? []
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        tools = try c.decodeIfPresent([String: ToolSwitch].self, forKey: .tools)
        scrubSecrets = try c.decodeIfPresent(Bool.self, forKey: .scrubSecrets)
    }

    static let currentVersion = 2

    var shouldScrubSecrets: Bool { scrubSecrets ?? true }

    func isToolOn(_ toolID: String) -> Bool {
        tools?[toolID]?.typed == true
    }

    mutating func setTool(_ toolID: String, typed: Bool) {
        var all = tools ?? [:]
        var entry = all[toolID] ?? ToolSwitch(typed: typed)
        entry.typed = typed
        all[toolID] = entry
        tools = all
    }

    /// Whether this policy can save at least one typed surface. This is a
    /// capability check, not an evaluation for one particular frontmost app:
    /// it decides whether the keystroke tap needs to feed typed capture at all.
    public var allowsAnyTypedSave: Bool {
        if SurfaceAction(rawValue: Self.norm(defaultTyped)) == .save {
            return true
        }
        if tools?.values.contains(where: \.typed) == true {
            return true
        }
        return rules.contains { rule in
            Self.norm(rule.action) == SurfaceAction.save.rawValue
                && (Self.norm(rule.modality) == SurfaceModality.both.rawValue || Self.norm(rule.modality) == SurfaceModality.typed.rawValue)
        }
    }

    /// Used until a policy has been mirrored from the Core or saved locally:
    /// dictation is saved everywhere; typed history is off until the user
    /// opts in (first-run step or Settings › History & Privacy › Choose Apps).
    public static var fallback: SurfacePolicy {
        freshV2(catalog: .shared)
    }

    static func freshV2(catalog: ToolCatalog) -> SurfacePolicy {
        SurfacePolicy(
            defaultTyped: "ignore",
            defaultVoice: "save",
            rules: [],
            version: currentVersion,
            tools: [:],
            scrubSecrets: true
        )
    }

    // MARK: - v2 evaluation

    func decide(_ context: CaptureContext, modality: String, catalog: ToolCatalog = .shared) -> CaptureDecision {
        let target = Self.norm(modality)
        for rule in rules {
            let ruleModality = Self.norm(rule.modality)
            if ruleModality != "both" && ruleModality != target { continue }
            if Self.matches(rule: rule, context: context, catalog: catalog) {
                let action = SurfaceAction(rawValue: Self.norm(rule.action)) ?? .ignore
                return CaptureDecision(action: action, reason: "override:\(rule.kind):\(rule.pattern)")
            }
        }

        if let toolID = context.toolID {
            if let entry = tools?[toolID] {
                if target == "typed" {
                    return CaptureDecision(action: entry.typed ? .save : .ignore, reason: entry.typed ? "tool:\(toolID)" : "tool-off:\(toolID)")
                }
                if entry.voice == false {
                    return CaptureDecision(action: .ignore, reason: "tool-off:\(toolID)")
                }
            } else if target == "typed" {
                return CaptureDecision(action: .ignore, reason: "tool-unset:\(toolID)")
            }
        }

        if target == "typed" {
            let action = SurfaceAction(rawValue: Self.norm(defaultTyped)) ?? .ignore
            return CaptureDecision(action: action, reason: "default:typed")
        }
        let action = SurfaceAction(rawValue: Self.norm(defaultVoice)) ?? .save
        return CaptureDecision(action: action, reason: "default:voice")
    }

    static func matches(rule: SurfaceRule, context: CaptureContext, catalog: ToolCatalog) -> Bool {
        let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        switch norm(rule.kind) {
        case "any":
            return true
        case "domain":
            return domainMatches(host: context.webHost, pattern: pattern)
        case "app":
            guard let bundle = context.appBundleID, !bundle.isEmpty else { return false }
            return fnmatch(pattern, bundle, 0) == 0
        case "tool":
            guard let toolID = context.toolID else { return false }
            return fnmatch(pattern, toolID, 0) == 0
        case "remote":
            guard let remote = context.remoteHost?.lowercased(), !remote.isEmpty else { return false }
            return fnmatch(pattern.lowercased(), remote, 0) == 0
        default:
            return false
        }
    }

    static func norm(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func normalizeHost(_ host: String) -> String {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        return trimmed
    }

    public static func domainMatches(host: String?, pattern: String) -> Bool {
        guard let host else { return false }
        let normalizedHost = normalizeHost(host)
        let normalizedPattern = normalizeHost(pattern)
        guard !normalizedHost.isEmpty, !normalizedPattern.isEmpty else { return false }
        return normalizedHost == normalizedPattern || normalizedHost.hasSuffix("." + normalizedPattern)
    }

    public static func extractHost(from urlString: String?) -> String? {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            if let url = URL(string: raw), let host = url.host, !host.isEmpty {
                return host
            }
            return nil
        }
        if !raw.contains("://") {
            let firstPart = raw.split(separator: "/").first.map(String.init) ?? raw
            if firstPart.contains(".") {
                return firstPart
            }
        }
        return nil
    }
}
