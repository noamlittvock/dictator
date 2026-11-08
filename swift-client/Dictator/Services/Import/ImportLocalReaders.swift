import Foundation
import SQLite3

// Readers for history already on this Mac: Claude Code session logs, Codex
// history and session logs, and Wispr Flow's database. All are opened
// read-only and streamed.

// MARK: - Claude Code

/// `~/.claude/projects/<slug>/<session>.jsonl`. Only the person's own turns:
/// `type: "user"` lines whose content is text, not tool results, meta
/// lines, compact summaries, sub-agent (sidechain) turns, SDK runs, or
/// system-originated turns (task notifications, auto-continuations, peer
/// messages). `url` may be the projects folder, one project folder, or a
/// single `.jsonl` file.
enum ClaudeCodeReader {
    private static let needles = [Data("\"type\":\"user\"".utf8), Data("\"type\": \"user\"".utf8)]

    static func read(_ url: URL) throws -> ImportReadResult {
        let state = ImportPaths.exists(url)
        guard state.exists else { throw ImportError.notFound(ImportPaths.display(url)) }
        let files = state.isDirectory
            ? ImportPaths.files(under: url) { $0.pathExtension == "jsonl" }
            : [url]
        var collector = ImportCollector()
        for file in files {
            do {
                try ImportLines.forEach(in: file) { line, number in
                    guard ImportLines.contains(line, anyOf: needles),
                          let object = ImportLines.jsonObject(line) else { return true }
                    read(object, file: file, line: number, into: &collector)
                    return true
                }
            } catch ImportError.unreadable where state.isDirectory {
                continue // one unreadable session shouldn't stop the rest
            }
        }
        return collector.result
    }

    static func isPersonTurn(_ object: [String: Any]) -> Bool {
        guard object.importString("type") == "user" else { return false }
        if let message = object.importDict("message"), let role = message.importString("role"), role != "user" {
            return false
        }
        if object.importBool("isMeta") || object.importBool("isCompactSummary")
            || object.importBool("isVisibleInTranscriptOnly") || object.importBool("isSidechain") {
            return false
        }
        if object["toolUseResult"] != nil { return false }
        if let origin = object.importDict("origin"), let kind = origin.importString("kind"), kind != "human" {
            return false
        }
        if let source = object.importString("promptSource"), source == "system" || source == "sdk" {
            return false
        }
        if let entry = object.importString("entrypoint"), entry.hasPrefix("sdk") { return false }
        return true
    }

    private static func read(_ object: [String: Any], file: URL, line: Int, into collector: inout ImportCollector) {
        guard isPersonTurn(object) else { return }
        let content = object.importDict("message")?["content"] ?? object["content"] ?? object["text"]
        if let blocks = content as? [Any],
           blocks.contains(where: { ($0 as? [String: Any])?.importString("type") == "tool_result" }) {
            return
        }
        guard let text = collector.accept(ImportTextFilter.textBlocks(content)) else { return }
        let session = object.importString("sessionId") ?? file.deletingPathExtension().lastPathComponent
        let key = object.importString("uuid").map { "claude-code:\($0)" } ?? "claude-code:\(session):\(line)"
        collector.append(ImportedPrompt(
            text: text,
            timestamp: ImportDates.parse(object["timestamp"]),
            toolId: "claude-code",
            workingDirectory: object.importString("cwd"),
            sessionId: session,
            sourceKey: key
        ))
    }
}

// MARK: - Codex

/// `~/.codex/history.jsonl` (`{session_id, ts, text}`) and
/// `~/.codex/sessions/**/rollout-*.jsonl` (`session_meta` / `turn_context`
/// give the session id and folder; prompts are `event_msg` `user_message`
/// or `response_item` user messages). Session logs win when both describe
/// the same prompt (same text within 5 seconds). `url` may be the `.codex`
/// folder, a sessions folder, or one `.jsonl` file (either kind).
enum CodexReader {
    static let sameWindow: TimeInterval = 5
    private static let sessionNeedles = [
        Data("user_message".utf8), Data("\"role\":\"user\"".utf8), Data("\"role\": \"user\"".utf8),
        Data("session_meta".utf8), Data("turn_context".utf8),
    ]
    private static let payloadNeedle = Data("\"payload\"".utf8)

    static func read(_ url: URL) throws -> ImportReadResult {
        let state = ImportPaths.exists(url)
        guard state.exists else { throw ImportError.notFound(ImportPaths.display(url)) }
        var files: [URL] = []
        if state.isDirectory {
            let history = url.appendingPathComponent("history.jsonl")
            let sessionFolders = ["sessions", "archived_sessions"]
                .map { url.appendingPathComponent($0, isDirectory: true) }
                .filter { ImportPaths.exists($0).isDirectory }
            if ImportPaths.exists(history).exists { files.append(history) }
            for folder in sessionFolders {
                files += ImportPaths.files(under: folder) { $0.pathExtension == "jsonl" }
            }
            if files.isEmpty, sessionFolders.isEmpty {
                files = ImportPaths.files(under: url) { $0.pathExtension == "jsonl" }
            }
        } else {
            files = [url]
        }

        var sessionCollector = ImportCollector()
        var historyCollector = ImportCollector()
        for file in files {
            var sessionId = sessionIdFromFileName(file)
            var cwd: String?
            do {
                try ImportLines.forEach(in: file) { line, number in
                    if line.range(of: payloadNeedle) != nil {
                        guard ImportLines.contains(line, anyOf: sessionNeedles),
                              let object = ImportLines.jsonObject(line) else { return true }
                        readSessionLine(object, file: file, line: number, sessionId: &sessionId, cwd: &cwd, into: &sessionCollector)
                    } else if let object = ImportLines.jsonObject(line) {
                        readHistoryLine(object, line: number, into: &historyCollector)
                    }
                    return true
                }
            } catch ImportError.unreadable where files.count > 1 {
                continue
            }
        }

        // Merge: sessions first (they know the folder), then history lines
        // no session already has.
        var result = ImportReadResult(
            skippedNoise: sessionCollector.result.skippedNoise + historyCollector.result.skippedNoise,
            skippedEmpty: sessionCollector.result.skippedEmpty + historyCollector.result.skippedEmpty
        )
        var seen: [String: [Date?]] = [:]
        func isRepeat(_ prompt: ImportedPrompt) -> Bool {
            let key = ImportTextFilter.matchKey(prompt.text)
            let times = seen[key] ?? []
            let hit = times.contains { other in
                switch (other, prompt.timestamp) {
                case let (a?, b?): return abs(a.timeIntervalSince(b)) <= sameWindow
                case (nil, nil): return true
                default: return false
                }
            }
            if !hit { seen[key, default: []].append(prompt.timestamp) }
            return hit
        }
        for prompt in sessionCollector.result.prompts where !isRepeat(prompt) {
            result.prompts.append(prompt)
        }
        for prompt in historyCollector.result.prompts where !isRepeat(prompt) {
            result.prompts.append(prompt)
        }
        return result
    }

    /// `rollout-2026-09-20T00-07-31-<uuid>.jsonl` → `<uuid>`.
    static func sessionIdFromFileName(_ file: URL) -> String? {
        let name = file.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("rollout-"), name.count > 36 else { return nil }
        let tail = String(name.suffix(36))
        return UUID(uuidString: tail) != nil ? tail : nil
    }

    private static func readSessionLine(
        _ object: [String: Any],
        file: URL,
        line: Int,
        sessionId: inout String?,
        cwd: inout String?,
        into collector: inout ImportCollector
    ) {
        let payload = object.importDict("payload") ?? [:]
        let type = object.importString("type")
        switch type {
        case "session_meta":
            sessionId = payload.importString("id") ?? payload.importString("session_id") ?? sessionId
            cwd = payload.importString("cwd") ?? cwd
            return
        case "turn_context":
            cwd = payload.importString("cwd") ?? cwd
            return
        default:
            break
        }
        let raw: String
        if type == "event_msg", payload.importString("type") == "user_message" {
            raw = ImportTextFilter.cleanText(payload["message"])
        } else if type == "response_item", payload.importString("type") == "message", payload.importString("role") == "user" {
            raw = ImportTextFilter.textBlocks(payload["content"])
        } else {
            return
        }
        guard let text = collector.accept(raw) else { return }
        let time = ImportDates.parse(object["timestamp"])
        let session = sessionId ?? file.deletingPathExtension().lastPathComponent
        let stamp = time.map { String(Int($0.timeIntervalSince1970)) } ?? "line\(line)"
        collector.append(ImportedPrompt(
            text: text,
            timestamp: time,
            toolId: "codex",
            workingDirectory: cwd,
            sessionId: session,
            sourceKey: "codex:\(session):\(stamp):\(ImportHash.short(text))"
        ))
    }

    private static func readHistoryLine(_ object: [String: Any], line: Int, into collector: inout ImportCollector) {
        let raw = ImportTextFilter.cleanText(object["text"] ?? object["message"] ?? object["prompt"])
        guard let text = collector.accept(raw) else { return }
        let time = ImportDates.parse(object["ts"] ?? object["timestamp"] ?? object["created_at"])
        let session = object.importString("session_id")
        let stamp = time.map { String(Int($0.timeIntervalSince1970)) } ?? "line\(line)"
        collector.append(ImportedPrompt(
            text: text,
            timestamp: time,
            toolId: "codex",
            sessionId: session,
            sourceKey: "codex:\(session ?? "history"):\(stamp):\(ImportHash.short(text))"
        ))
    }
}

// MARK: - Wispr Flow

/// Wispr Flow's `flow.sqlite`, table `History`, opened read-only. Text is
/// the first non-empty of `editedText`, `formattedText`, `pastedText`,
/// `asrText`; time from `timestamp` / `createdAt` / `startTime`; `app` is the
/// bundle id of the app the dictation went into, `url` the page, and
/// `duration` / `speechDuration` the length. Voice, no tool id.
enum WisprFlowReader {
    static let hint = "Choose flow.sqlite from Wispr Flow's folder in Application Support."

    /// Names for the bundle ids Wispr Flow records most (from the import script).
    static let bundleNames: [String: String] = [
        "com.openai.codex": "Codex",
        "com.openai.chat": "ChatGPT",
        "com.anthropic.claudefordesktop": "Claude",
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave Browser",
        "company.thebrowser.Browser": "Arc",
        "com.googlecode.iterm2": "iTerm2",
        "com.apple.Terminal": "Terminal",
        "com.mitchellh.ghostty": "Ghostty",
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.tdesktop.Telegram": "Telegram",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.mail": "Mail",
        "com.apple.Notes": "Notes",
        "com.apple.MobileSMS": "Messages",
        "notion.id": "Notion",
    ]

    static func read(_ url: URL) throws -> ImportReadResult {
        let state = ImportPaths.exists(url)
        guard state.exists else { throw ImportError.notFound(ImportPaths.display(url)) }
        let file = state.isDirectory ? url.appendingPathComponent("flow.sqlite") : url
        guard ImportPaths.exists(file).exists else { throw ImportError.notFound(ImportPaths.display(file)) }

        let db = try open(file)
        defer { sqlite3_close_v2(db) }
        guard try hasHistoryTable(db) else { throw ImportError.unrecognized(hint) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM History", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ImportError.unreadable(ImportPaths.display(file))
        }
        defer { sqlite3_finalize(statement) }

        var collector = ImportCollector()
        let columns = (0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ImportError.unreadable(ImportPaths.display(file)) }
            var row: [String: Any] = [:]
            for (index, name) in columns.enumerated() {
                if let value = value(statement, Int32(index)) { row[name] = value }
            }
            read(row, into: &collector)
        }
        return collector.result
    }

    private static func read(_ row: [String: Any], into collector: inout ImportCollector) {
        let variants = ["editedText", "formattedText", "pastedText", "asrText"].compactMap { row[$0] as? String }
        let raw = variants.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        guard let text = collector.accept(raw, strictLength: false) else { return }
        let time = ImportDates.parse(row["timestamp"]) ?? ImportDates.parse(row["createdAt"]) ?? ImportDates.parse(row["startTime"])
        let bundle = row.importString("app")
        let id = row.importString("transcriptEntityId") ?? row.importString("id")
            ?? (row["id"] as? Double).map { Int64(exactly: $0).map(String.init) ?? String($0) }
        let key = id ?? ImportHash.hex("\(time.map { String($0.timeIntervalSince1970) } ?? ""):\(text)")
        let duration = (row["duration"] as? Double) ?? (row["speechDuration"] as? Double)
            ?? (row.importString("duration")).flatMap(Double.init)
        collector.append(ImportedPrompt(
            text: text,
            timestamp: time,
            modality: .voice,
            toolId: nil,
            appName: bundle.flatMap { bundleNames[$0] },
            appBundleId: bundle,
            url: row.importString("url"),
            durationSeconds: duration.flatMap { $0 > 0 ? $0 : nil },
            sourceKey: "wispr:\(key)"
        ))
    }

    private static func open(_ file: URL) throws -> OpaquePointer {
        let encoded = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        for uri in ["file:\(encoded)?mode=ro", "file:\(encoded)?mode=ro&immutable=1"] {
            var db: OpaquePointer?
            if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db {
                sqlite3_busy_timeout(db, 2_000)
                // A WAL database opened read-only fails on first read when it
                // can't reach the -shm file; fall back to an immutable open.
                if sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK {
                    return db
                }
                sqlite3_close_v2(db)
            } else if let db {
                sqlite3_close_v2(db)
            }
        }
        throw ImportError.unreadable(ImportPaths.display(file))
    }

    private static func hasHistoryTable(_ db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = 'History'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ImportError.unrecognized(hint)
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func value(_ statement: OpaquePointer, _ index: Int32) -> Any? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return Double(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return sqlite3_column_double(statement, index)
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: pointer)
        default: return nil
        }
    }
}
