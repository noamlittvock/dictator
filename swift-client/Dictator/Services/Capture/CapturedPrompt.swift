import Foundation

/// One prompt on its way into history, from any capture source.
struct CapturedPrompt: Equatable, Sendable {
    var text: String
    var source: CaptureSource
    var context: CaptureContext
    var timestamp: Date
    var sessionID: String?
    /// Identity for "already stored" checks across restarts: a spool record
    /// id, or `agy:<conversation>:<step>`.
    var dedupeKey: String?
    /// Keyboard time spent composing it (see `TypedPromptCapture.Draft`),
    /// when it was typed on this Mac.
    var typingSeconds: Double? = nil
}

/// Parses what connectors produce — spool records written by
/// `dictator-capture`, and lines of the tools' own history files — into
/// `CapturedPrompt`s. Pure; every format has fixture tests.
enum ConnectorParsers {
    // MARK: Spool records

    /// A spool line is `{"v":1,"tool":…,"machine":…,"ts":…,"payload":{…}}`,
    /// the payload being exactly what the tool gave its hook.
    static func parseSpoolRecord(
        _ data: Data,
        id: String,
        remoteHost: String?,
        catalog: ToolCatalog
    ) -> CapturedPrompt? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolID = record["tool"] as? String,
              let tool = catalog.tool(id: toolID) else { return nil }
        let payload = record["payload"] as? [String: Any] ?? [:]
        let connector = tool.connector
        let machine = record["machine"] as? String
        let timestamp = (record["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()

        var text: String?
        var dedupeKey = "spool:\(id)"
        if connector?.promptField == "@agy-transcript" {
            guard let line = record["last_user_input"] as? [String: Any],
                  let parsed = parseAntigravityStep(line) else { return nil }
            text = parsed.text
            let conversation = payload["conversationId"] as? String ?? "?"
            dedupeKey = "agy:\(conversation):\(parsed.step)"
        } else {
            text = value(at: connector?.promptField ?? "prompt", in: payload) as? String
        }

        // Claude Code labels non-human turns (`-p`/SDK runs, scheduled
        // wake-ups, background polls) — only the person's own prompts count.
        let origin = payload["source"] as? String
        if let origin, origin != "user" {
            return nil
        }
        if payload["agent_id"] != nil { return nil }
        // A terminal agent with no terminal anywhere up its process chain
        // was run by a script or another agent, not typed by a person —
        // unless the tool itself says a user typed it. (Editors' agents,
        // like Cursor's, are GUI apps and never have a terminal.)
        if tool.category == .agent, record["tty"] as? String == "none", origin != "user" {
            return nil
        }

        guard let cleaned = cleanPrompt(text) else { return nil }
        let session = connector?.sessionField.flatMap { value(at: $0, in: payload) as? String }
        let cwd = connector?.cwdField.flatMap { value(at: $0, in: payload) as? String }
        return CapturedPrompt(
            text: cleaned,
            source: .hook,
            context: CaptureContext(
                toolID: tool.id,
                remoteHost: remoteHost,
                toolMachine: machine,
                workingDirectory: cwd
            ),
            timestamp: timestamp,
            sessionID: session,
            dedupeKey: dedupeKey
        )
    }

    // MARK: History files

    /// `~/.claude/history.jsonl`: `{"display", "pastedContents", "timestamp"
    /// (ms), "project", "sessionId"}`. Pasted blocks appear in `display` as
    /// `[Pasted text #1 …]` and are restored from `pastedContents`.
    static func parseClaudeHistoryLine(_ line: Data, toolID: String) -> CapturedPrompt? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              var display = object["display"] as? String else { return nil }
        if let pasted = object["pastedContents"] as? [String: Any] {
            for (key, value) in pasted {
                guard let item = value as? [String: Any], let content = item["content"] as? String else { continue }
                let pattern = "\\[Pasted text #\(key)[^\\]]*\\]"
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(display.startIndex..., in: display)
                    display = regex.stringByReplacingMatches(
                        in: display, range: range,
                        withTemplate: NSRegularExpression.escapedTemplate(for: content)
                    )
                }
            }
        }
        guard let text = cleanPrompt(display) else { return nil }
        let ms = (object["timestamp"] as? NSNumber)?.doubleValue
        let session = object["sessionId"] as? String
        return CapturedPrompt(
            text: text,
            source: .transcript,
            context: CaptureContext(toolID: toolID, workingDirectory: object["project"] as? String),
            timestamp: ms.map { Date(timeIntervalSince1970: $0 / 1_000) } ?? Date(),
            sessionID: session,
            dedupeKey: "claude-history:\(session ?? "?"):\(ImportDates.wholeNumber(ms ?? 0))"
        )
    }

    /// `~/.codex/history.jsonl`: `{"session_id", "ts" (s), "text"}`.
    static func parseCodexHistoryLine(_ line: Data, toolID: String) -> CapturedPrompt? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let text = cleanPrompt(object["text"] as? String) else { return nil }
        let ts = (object["ts"] as? NSNumber)?.doubleValue
        let session = object["session_id"] as? String
        return CapturedPrompt(
            text: text,
            source: .transcript,
            context: CaptureContext(toolID: toolID),
            timestamp: ts.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            sessionID: session,
            dedupeKey: "codex-history:\(session ?? "?"):\(ImportDates.wholeNumber(ts ?? 0))"
        )
    }

    /// Antigravity transcript step: a `USER_INPUT` from `USER_EXPLICIT`, the
    /// typed text wrapped in `<USER_REQUEST>…</USER_REQUEST>`.
    static func parseAntigravityStep(_ object: [String: Any]) -> (text: String, step: Int)? {
        guard object["type"] as? String == "USER_INPUT",
              (object["source"] as? String).map({ $0 == "USER_EXPLICIT" }) ?? true,
              let content = object["content"] as? String else { return nil }
        var text = content
        if let start = content.range(of: "<USER_REQUEST>"),
           let end = content.range(of: "</USER_REQUEST>", range: start.upperBound..<content.endIndex) {
            text = String(content[start.upperBound..<end.lowerBound])
        }
        guard let cleaned = cleanPrompt(text) else { return nil }
        return (cleaned, (object["step_index"] as? NSNumber)?.intValue ?? -1)
    }

    static func parseAntigravityLine(_ line: Data, conversation: String, toolID: String) -> CapturedPrompt? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let parsed = parseAntigravityStep(object) else { return nil }
        let created = (object["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return CapturedPrompt(
            text: parsed.text,
            source: .transcript,
            context: CaptureContext(toolID: toolID),
            timestamp: created ?? Date(),
            sessionID: conversation,
            dedupeKey: "agy:\(conversation):\(parsed.step)"
        )
    }

    // MARK: Helpers

    /// Trims, drops empty prompts and bare slash commands (`/clear`,
    /// `/model opus`) — those drive the tool, they aren't prompts.
    static func cleanPrompt(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/") {
            let words = text.split(whereSeparator: \.isWhitespace)
            if words.count <= 2, words.first?.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" || $0 == "_" }) == true {
                return nil
            }
        }
        return text
    }

    static func value(at path: String, in object: [String: Any]) -> Any? {
        var current: Any? = object
        for key in path.split(separator: ".") {
            current = (current as? [String: Any])?[String(key)]
        }
        return current
    }
}
