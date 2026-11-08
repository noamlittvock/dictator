import Foundation

/// Reads and writes files in a home directory — this Mac's, or a server's
/// over SSH (`RemoteConfigFileAccess`). Paths are home-relative.
protocol ConfigFileAccess: Sendable {
    /// Absolute home directory on that machine.
    var homeDirectory: String { get }
    func read(_ relativePath: String) async throws -> String?
    /// Writes atomically; with `backup`, first copies an existing file to
    /// `<file>.dictator-backup`.
    func write(_ relativePath: String, contents: String, backup: Bool, executable: Bool) async throws
    func delete(_ relativePath: String) async throws
    func exists(_ relativePath: String) async -> Bool
}

struct LocalConfigFileAccess: ConfigFileAccess {
    let homeDirectory: String

    init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    private func url(_ relativePath: String) -> URL {
        URL(fileURLWithPath: homeDirectory).appendingPathComponent(relativePath)
    }

    func read(_ relativePath: String) async throws -> String? {
        let url = url(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func write(_ relativePath: String, contents: String, backup: Bool, executable: Bool) async throws {
        // Write through a symlink (dotfiles managers) rather than replace it,
        // and back up the content, not the link.
        let url = url(relativePath).resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backup, fm.fileExists(atPath: url.path) {
            let backupURL = URL(fileURLWithPath: url.path + ".dictator-backup")
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: url, to: backupURL)
        }
        let existingMode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        try contents.write(to: url, atomically: true, encoding: .utf8)
        let mode: Int = executable ? 0o700 : (existingMode?.intValue ?? 0o600)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func delete(_ relativePath: String) async throws {
        let url = url(relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func exists(_ relativePath: String) async -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath).path)
    }
}

enum ConnectorError: LocalizedError, Equatable {
    case unreadableConfig(path: String)
    case conflictingConfig(path: String)
    case unsupported(toolName: String)
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case .unreadableConfig(let path):
            "Dictator couldn't read ~/\(path) (it may contain comments or not be valid JSON), so it left it untouched."
        case .conflictingConfig(let path):
            "The existing ~/\(path) isn't Dictator’s own hook file, so Dictator left it unchanged."
        case .unsupported(let name):
            "\(name) has no hook Dictator can install."
        case .missingResource(let name):
            "This copy of Dictator is missing a file it needs (\(name)). Reinstall Dictator, then try again."
        }
    }
}

/// Installs, detects and removes Dictator's prompt hook in each tool's own
/// configuration. Every change is a merge — other hooks and settings are
/// kept — the previous file is saved as `<file>.dictator-backup`, and our
/// entry is recognisable by the `dictator-capture` command so it can be
/// found and removed again.
enum ConnectorInstaller {
    static let shimRelativePath = ".dictator/bin/dictator-capture"
    static let spoolRelativePath = ".dictator/spool"
    static let marker = "dictator-capture"

    static func shimPath(home: String) -> String {
        (home as NSString).appendingPathComponent(shimRelativePath)
    }

    /// The command line registered in the tool's config.
    static func hookCommand(home: String, toolID: String, reply: String?) -> String {
        var command = shellQuote(shimPath(home: home)) + " hook " + shellQuote(toolID)
        if let reply { command += " " + shellQuote(reply) }
        return command
    }

    static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+=:,@"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Resources

    static func bundledShim() throws -> String {
        guard let url = Bundle.main.url(forResource: "dictator-capture", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConnectorError.missingResource("dictator-capture")
        }
        return text
    }

    static func bundledShimVersion() -> String? {
        guard let shim = try? bundledShim() else { return nil }
        return shimVersion(in: shim)
    }

    static func shimVersion(in script: String) -> String? {
        for line in script.split(separator: "\n") where line.hasPrefix("DICTATOR_CAPTURE_VERSION=") {
            return String(line.dropFirst("DICTATOR_CAPTURE_VERSION=".count))
        }
        return nil
    }

    static func openCodePlugin(shimPath: String) throws -> String {
        guard let url = Bundle.main.url(forResource: "opencode-plugin", withExtension: "js"),
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConnectorError.missingResource("opencode-plugin.js")
        }
        return renderOpenCodePlugin(template: template, shimPath: shimPath)
    }

    static func renderOpenCodePlugin(template: String, shimPath: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = (try? String(data: encoder.encode(shimPath), encoding: .utf8)) ?? "\"\(shimPath)\""
        return template.replacingOccurrences(of: "__DICTATOR_CAPTURE_PATH__", with: encoded)
    }

    // MARK: - Shim

    /// Puts (or refreshes) the shim at `~/.dictator/bin/dictator-capture`.
    static func installShim(on access: ConfigFileAccess, script: String) async throws {
        let current = try? await access.read(shimRelativePath)
        if current == script { return }
        if let current, let version = shimVersion(in: script), shimVersion(in: current) == version { return }
        try await access.write(shimRelativePath, contents: script, backup: false, executable: true)
    }

    // MARK: - Install / remove / status

    static func install(_ tool: ToolDefinition, on access: ConfigFileAccess) async throws {
        guard let connector = tool.connector, connector.supportsHook,
              let format = connector.hookFormat, let configPath = connector.hookConfig else {
            throw ConnectorError.unsupported(toolName: tool.name)
        }
        let command = hookCommand(home: access.homeDirectory, toolID: tool.id, reply: connector.hookReply)
        switch format {
        case "opencode-plugin", "copilot-hooks":
            let contents = try dedicatedContents(format: format, event: connector.hookEvent, command: command, home: access.homeDirectory)
            if let existing = try await access.read(configPath) {
                // These are dedicated files, not shared settings. Arbitrary
                // JavaScript or hook JSON cannot safely be replaced or merged.
                guard existing == contents else { throw ConnectorError.conflictingConfig(path: configPath) }
                return // Keep the original backup intact on repeated setup.
            }
            // A leftover original must not become an unrelated future
            // install's restore target.
            guard try await access.read(configPath + ".dictator-backup") == nil else {
                throw ConnectorError.conflictingConfig(path: configPath + ".dictator-backup")
            }
            try await access.write(configPath, contents: contents, backup: false, executable: false)
        default:
            // Prepare every change before writing any, so a refusal (an
            // unreadable file) leaves the tool exactly as it was.
            var codexToml: (original: String, enabled: String)?
            if format == "codex-hooks" {
                let toml = try await access.read(".codex/config.toml") ?? ""
                codexToml = (toml, try enableCodexHooksFeature(in: toml))
            }
            let existing = try await access.read(configPath)
            let root = try parseObject(existing, path: configPath)
            let updated = try addHook(format: format, root: root, event: connector.hookEvent ?? "", command: command)
            if let codexToml, codexToml.enabled != codexToml.original {
                try await access.write(".codex/config.toml", contents: codexToml.enabled, backup: true, executable: false)
            }
            try await access.write(configPath, contents: try render(updated), backup: true, executable: false)
        }
    }

    static func uninstall(_ tool: ToolDefinition, on access: ConfigFileAccess) async throws {
        guard let connector = tool.connector, let format = connector.hookFormat,
              let configPath = connector.hookConfig else { return }
        switch format {
        case "opencode-plugin", "copilot-hooks":
            guard let existing = try await access.read(configPath) else { return }
            let command = hookCommand(home: access.homeDirectory, toolID: tool.id, reply: connector.hookReply)
            let owned = try dedicatedContents(format: format, event: connector.hookEvent, command: command, home: access.homeDirectory)
            guard existing == owned else { throw ConnectorError.conflictingConfig(path: configPath) }
            if let previous = try await access.read(configPath + ".dictator-backup") {
                try await access.write(configPath, contents: previous, backup: false, executable: false)
                try await access.delete(configPath + ".dictator-backup")
            } else {
                try await access.delete(configPath)
            }
        default:
            guard let existing = try await access.read(configPath) else { return }
            let root = try parseObject(existing, path: configPath)
            let updated = removeHook(format: format, root: root, event: connector.hookEvent ?? "")
            try await access.write(configPath, contents: try render(updated), backup: true, executable: false)
        }
    }

    static func isInstalled(_ tool: ToolDefinition, on access: ConfigFileAccess) async -> Bool {
        guard let connector = tool.connector, let configPath = connector.hookConfig else { return false }
        guard let contents = try? await access.read(configPath) else { return false }
        if let format = connector.hookFormat, format == "opencode-plugin" || format == "copilot-hooks" {
            let command = hookCommand(home: access.homeDirectory, toolID: tool.id, reply: connector.hookReply)
            let owned = try? dedicatedContents(format: format, event: connector.hookEvent, command: command, home: access.homeDirectory)
            return contents == owned
        }
        return contents.contains(marker)
    }

    private static func dedicatedContents(format: String, event: String?, command: String, home: String) throws -> String {
        if format == "opencode-plugin" {
            return try openCodePlugin(shimPath: shimPath(home: home))
        }
        return try render(copilotHooks(command: command, event: event ?? "userPromptSubmitted"))
    }

    /// Whether the tool appears to be installed on that machine: one of its
    /// config directories exists.
    static func isToolPresent(_ tool: ToolDefinition, on access: ConfigFileAccess) async -> Bool {
        for dir in tool.signatures.configDirs where await access.exists(dir) {
            return true
        }
        return false
    }

    // MARK: - JSON config transforms (pure, unit-tested)

    static func parseObject(_ text: String?, path: String) throws -> [String: Any] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.unreadableConfig(path: path)
        }
        return object
    }

    static func render(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func isOurs(_ handler: Any) -> Bool {
        guard let handler = handler as? [String: Any] else { return false }
        return ["command", "bash"].contains { key in
            (handler[key] as? String)?.contains(marker) == true
        }
    }

    static func addHook(format: String, root: [String: Any], event: String, command: String) throws -> [String: Any] {
        var root = removeHook(format: format, root: root, event: event)
        switch format {
        case "nested-hooks", "codex-hooks", "gemini-hooks":
            // {"hooks": {"<Event>": [{"hooks": [{"type": "command", …}]}]}}
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            var groups = hooks[event] as? [Any] ?? []
            var handler: [String: Any] = ["type": "command", "command": command]
            if format == "gemini-hooks" {
                handler["name"] = marker
                handler["timeout"] = 5_000 // milliseconds
            } else {
                handler["timeout"] = 5 // seconds
            }
            groups.append(["hooks": [handler]])
            hooks[event] = groups
            root["hooks"] = hooks
        case "cursor-hooks":
            // {"version": 1, "hooks": {"beforeSubmitPrompt": [{"command": …}]}}
            if root["version"] == nil { root["version"] = 1 }
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            var list = hooks[event] as? [Any] ?? []
            list.append(["command": command])
            hooks[event] = list
            root["hooks"] = hooks
        case "agy-hooks":
            // {"<hook name>": {"PreInvocation": [{"type": "command", …}]}}
            root[marker] = [event: [["type": "command", "command": command, "timeout": 5]]]
        default:
            throw ConnectorError.unsupported(toolName: format)
        }
        return root
    }

    static func removeHook(format: String, root: [String: Any], event: String) -> [String: Any] {
        var root = root
        switch format {
        case "nested-hooks", "codex-hooks", "gemini-hooks":
            guard var hooks = root["hooks"] as? [String: Any], let groups = hooks[event] as? [Any] else { return root }
            let kept: [Any] = groups.compactMap { group in
                guard var group = group as? [String: Any], let handlers = group["hooks"] as? [Any] else { return group }
                let remaining = handlers.filter { !isOurs($0) }
                if remaining.isEmpty { return nil }
                group["hooks"] = remaining
                return group
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        case "cursor-hooks":
            guard var hooks = root["hooks"] as? [String: Any], let list = hooks[event] as? [Any] else { return root }
            let kept = list.filter { !isOurs($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            root["hooks"] = hooks
        case "agy-hooks":
            root.removeValue(forKey: marker)
        default:
            break
        }
        return root
    }

    static func copilotHooks(command: String, event: String) -> [String: Any] {
        ["version": 1, "hooks": [event: [["type": "command", "bash": command]]]]
    }

    /// Codex runs hooks only with `[features] hooks = true`. Throws rather
    /// than guess when `features` is an inline table (appending a second
    /// `[features]` would make the file invalid and Codex refuse to start).
    static func enableCodexHooksFeature(in toml: String) throws -> String {
        var lines = toml.components(separatedBy: "\n")
        func stripped(_ line: String) -> String {
            var text = line
            if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
            return text.trimmingCharacters(in: .whitespaces)
        }
        func isFeaturesHeader(_ line: String) -> Bool {
            let text = stripped(line)
            guard text.hasPrefix("["), text.hasSuffix("]"), !text.hasPrefix("[[") else { return false }
            return text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces) == "features"
        }
        func key(_ line: String) -> String? {
            let text = stripped(line)
            guard let eq = text.firstIndex(of: "=") else { return nil }
            return text[..<eq].trimmingCharacters(in: .whitespaces)
        }
        var inTable = false
        for (index, line) in lines.enumerated() {
            let text = stripped(line)
            if text.hasPrefix("[") { inTable = true; continue }
            guard !inTable else { continue }
            if key(line) == "features.hooks" {
                lines[index] = "features.hooks = true"
                return lines.joined(separator: "\n")
            }
            if key(line) == "features" {
                throw ConnectorError.unreadableConfig(path: ".codex/config.toml")
            }
        }
        if let header = lines.firstIndex(where: isFeaturesHeader) {
            var index = header + 1
            while index < lines.count, !stripped(lines[index]).hasPrefix("[") {
                if key(lines[index]) == "hooks" {
                    lines[index] = "hooks = true"
                    return lines.joined(separator: "\n")
                }
                index += 1
            }
            lines.insert("hooks = true", at: header + 1)
            return lines.joined(separator: "\n")
        }
        var text = toml
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        return text + "[features]\nhooks = true\n"
    }
}
