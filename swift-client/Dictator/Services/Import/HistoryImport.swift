import Foundation

// Import history: read prompts people already wrote elsewhere (chat
// exports, coding-tool logs on this Mac, Wispr Flow dictations, plain text
// files) into plain `ImportedPrompt` values. Everything here is pure and
// deterministic — no network, no models — and safe off the main thread.
// The readers live in `ImportReaders.swift` / `ImportLocalReaders.swift`,
// shared parsing helpers in `ImportSupport.swift`, and duplicate handling
// in `ImportDeduper.swift`.

enum ImportSourceKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case chatgpt, claude, claudeCode, codex, gemini, wisprFlow, textFile
    var id: String { rawValue }
}

/// What a source can tell us about each prompt.
struct ImportFields: OptionSet, Sendable {
    let rawValue: Int
    static let text = ImportFields(rawValue: 1 << 0)
    static let date = ImportFields(rawValue: 1 << 1)
    static let project = ImportFields(rawValue: 1 << 2)
    static let spokenOrTyped = ImportFields(rawValue: 1 << 3)
    static let duration = ImportFields(rawValue: 1 << 4)
    static let conversation = ImportFields(rawValue: 1 << 5)
}

struct ImportSourceInfo: Sendable {
    var kind: ImportSourceKind
    var name: String
    var how: String
    /// True when the source is read from its default place on this Mac;
    /// false when the person picks an export file.
    var readsFromThisMac: Bool
    var defaultLocation: String?
    var fileHint: String?
    var fields: ImportFields

    static func info(for kind: ImportSourceKind) -> ImportSourceInfo {
        switch kind {
        case .chatgpt:
            return ImportSourceInfo(
                kind: kind, name: "ChatGPT", how: "Export file from ChatGPT settings",
                readsFromThisMac: false, defaultLocation: nil, fileHint: "conversations.json",
                fields: [.text, .date, .conversation]
            )
        case .claude:
            return ImportSourceInfo(
                kind: kind, name: "Claude", how: "Export file from Claude settings",
                readsFromThisMac: false, defaultLocation: nil, fileHint: "conversations.json",
                fields: [.text, .date, .conversation]
            )
        case .claudeCode:
            return ImportSourceInfo(
                kind: kind, name: "Claude Code", how: "Read from this Mac",
                readsFromThisMac: true, defaultLocation: "~/.claude/projects", fileHint: ".jsonl",
                fields: [.text, .date, .project, .conversation]
            )
        case .codex:
            return ImportSourceInfo(
                kind: kind, name: "Codex", how: "Read from this Mac",
                readsFromThisMac: true, defaultLocation: "~/.codex", fileHint: "history.jsonl",
                fields: [.text, .date, .project, .conversation]
            )
        case .gemini:
            return ImportSourceInfo(
                kind: kind, name: "Gemini", how: "Google Takeout (My Activity › Gemini)",
                readsFromThisMac: false, defaultLocation: nil, fileHint: "MyActivity.json",
                fields: [.text, .date]
            )
        case .wisprFlow:
            return ImportSourceInfo(
                kind: kind, name: "Wispr Flow", how: "Read from this Mac",
                readsFromThisMac: true,
                defaultLocation: "~/Library/Application Support/Wispr Flow/flow.sqlite",
                fileHint: "flow.sqlite",
                fields: [.text, .date, .spokenOrTyped, .duration]
            )
        case .textFile:
            return ImportSourceInfo(
                kind: kind, name: "Text or JSONL file",
                how: "One prompt per line, or JSON lines with text and time",
                readsFromThisMac: false, defaultLocation: nil, fileHint: ".txt or .jsonl",
                fields: [.text, .date]
            )
        }
    }
}

/// One prompt read from an outside source, before it becomes a history row.
struct ImportedPrompt: Equatable, Sendable {
    var text: String
    var timestamp: Date?
    /// `.typed`, except Wispr Flow dictations (`.voice`).
    var modality: DatasetRow.Modality
    /// Catalog tool id (`chatgpt`, `claude`, `claude-code`, `codex`, `gemini`).
    /// Nil for Wispr Flow, which is not a tool — its app fields say where the
    /// dictation went.
    var toolId: String?
    var appName: String?
    var appBundleId: String?
    var url: String?
    var workingDirectory: String?
    var sessionId: String?
    var durationSeconds: Double?
    /// Stable id within the source (`chatgpt:<conversation>:<message>`), so a
    /// message is never imported twice.
    var sourceKey: String

    init(
        text: String,
        timestamp: Date?,
        modality: DatasetRow.Modality = .typed,
        toolId: String? = nil,
        appName: String? = nil,
        appBundleId: String? = nil,
        url: String? = nil,
        workingDirectory: String? = nil,
        sessionId: String? = nil,
        durationSeconds: Double? = nil,
        sourceKey: String
    ) {
        self.text = text
        self.timestamp = timestamp
        self.modality = modality
        self.toolId = toolId
        self.appName = appName
        self.appBundleId = appBundleId
        self.url = url
        self.workingDirectory = workingDirectory
        self.sessionId = sessionId
        self.durationSeconds = durationSeconds
        self.sourceKey = sourceKey
    }
}

struct ImportReadResult: Sendable {
    var prompts: [ImportedPrompt]
    /// Scaffolding, injected context and control commands that were dropped.
    var skippedNoise: Int
    /// Messages with no text (image-only, blank).
    var skippedEmpty: Int

    init(prompts: [ImportedPrompt] = [], skippedNoise: Int = 0, skippedEmpty: Int = 0) {
        self.prompts = prompts
        self.skippedNoise = skippedNoise
        self.skippedEmpty = skippedEmpty
    }
}

enum ImportError: LocalizedError, Equatable {
    /// The file or folder (a display path) does not exist.
    case notFound(String)
    /// The file or folder (a display path) exists but could not be opened.
    case unreadable(String)
    /// The file was opened but is not the expected format; the value says
    /// which file to choose instead.
    case unrecognized(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "Dictator found nothing at \(path)."
        case .unreadable(let path):
            return "Dictator couldn't open \(path)."
        case .unrecognized(let hint):
            return "This file is not in a format Dictator recognizes. \(hint)"
        }
    }
}

enum HistoryImportReader {
    /// Reads a source. `url` nil = the source's default location on this Mac
    /// (for `readsFromThisMac` sources). Safe to call off the main thread;
    /// line-based sources are streamed, and lines over 8 MB are skipped.
    static func read(
        _ kind: ImportSourceKind,
        from url: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ImportReadResult {
        switch kind {
        case .chatgpt:
            return try ChatGPTExportReader.read(try requiredURL(url, kind))
        case .claude:
            return try ClaudeExportReader.read(try requiredURL(url, kind))
        case .gemini:
            return try GeminiTakeoutReader.read(try requiredURL(url, kind))
        case .textFile:
            return try TextFileReader.read(try requiredURL(url, kind))
        case .claudeCode:
            let target = url ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
            return try ClaudeCodeReader.read(target)
        case .codex:
            let target = url ?? home.appendingPathComponent(".codex", isDirectory: true)
            return try CodexReader.read(target)
        case .wisprFlow:
            let target = url ?? home.appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite")
            return try WisprFlowReader.read(target)
        }
    }

    private static func requiredURL(_ url: URL?, _ kind: ImportSourceKind) throws -> URL {
        guard let url else {
            let info = ImportSourceInfo.info(for: kind)
            throw ImportError.notFound(info.fileHint ?? info.name)
        }
        return url
    }
}
