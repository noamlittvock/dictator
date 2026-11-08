import Foundation

// Readers for files the person picks: ChatGPT and Claude exports, Gemini
// Takeout, and plain text / JSON-lines files. Readers for data already on
// this Mac (Claude Code, Codex, Wispr Flow) are in ImportLocalReaders.swift.

// MARK: - ChatGPT

/// ChatGPT export `conversations.json`: an array of conversations, each with
/// a `mapping` tree of `{message: {author.role, content.{content_type,
/// parts}, create_time, metadata}}` nodes. Every user node is read (edited
/// prompts included — they were typed too), in time order.
enum ChatGPTExportReader {
    static let hint = "Choose conversations.json from the ChatGPT data export."

    static func read(_ url: URL) throws -> ImportReadResult {
        let file = try ImportPaths.exportFile(url, names: ["conversations.json"], hint: hint)
        let data = try ImportPaths.readData(file)
        guard let conversations = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw ImportError.unrecognized(hint)
        }
        var collector = ImportCollector()
        var sawMapping = false
        for case let conversation as [String: Any] in conversations {
            guard let mapping = conversation.importDict("mapping") else { continue }
            sawMapping = true
            autoreleasepool {
                read(conversation: conversation, mapping: mapping, into: &collector)
            }
        }
        guard sawMapping || conversations.isEmpty else { throw ImportError.unrecognized(hint) }
        return collector.result
    }

    private static func read(conversation: [String: Any], mapping: [String: Any], into collector: inout ImportCollector) {
        let conversationId = conversation.importString("conversation_id") ?? conversation.importString("id") ?? ""
        let conversationTime = ImportDates.parse(conversation["create_time"])
        var nodes: [(time: Date?, id: String, message: [String: Any])] = []
        for (nodeId, value) in mapping {
            guard let node = value as? [String: Any], let message = node.importDict("message") else { continue }
            nodes.append((ImportDates.parse(message["create_time"]), message.importString("id") ?? nodeId, message))
        }
        nodes.sort { lhs, rhs in
            switch (lhs.time, rhs.time) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.id < rhs.id
            }
        }
        for node in nodes {
            let message = node.message
            guard message.importDict("author")?.importString("role") == "user" else { continue }
            let metadata = message.importDict("metadata") ?? [:]
            if metadata.importBool("is_visually_hidden_from_conversation") || metadata.importBool("is_user_system_message") {
                continue
            }
            let content = message.importDict("content") ?? [:]
            let contentType = content.importString("content_type") ?? "text"
            guard contentType == "text" || contentType == "multimodal_text" else { continue }
            let parts = (content["parts"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
            guard let text = collector.accept(parts.joined(separator: "\n")) else { continue }
            collector.append(ImportedPrompt(
                text: text,
                timestamp: node.time ?? conversationTime,
                toolId: "chatgpt",
                url: conversationId.isEmpty ? nil : "https://chatgpt.com/c/\(conversationId)",
                sessionId: conversationId.isEmpty ? nil : conversationId,
                sourceKey: "chatgpt:\(conversationId):\(node.id)"
            ))
        }
    }
}

// MARK: - Claude.ai export

/// Claude export `conversations.json`: an array of `{uuid, created_at,
/// chat_messages: [{uuid, sender, text, content: [{type, text}],
/// created_at}]}`. Human messages only.
enum ClaudeExportReader {
    static let hint = "Choose conversations.json from the Claude data export."

    static func read(_ url: URL) throws -> ImportReadResult {
        let file = try ImportPaths.exportFile(url, names: ["conversations.json"], hint: hint)
        let data = try ImportPaths.readData(file)
        guard let conversations = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw ImportError.unrecognized(hint)
        }
        var collector = ImportCollector()
        var sawMessages = false
        for case let conversation as [String: Any] in conversations {
            guard let messages = conversation["chat_messages"] as? [Any] else { continue }
            sawMessages = true
            let conversationId = conversation.importString("uuid") ?? conversation.importString("id") ?? ""
            let conversationTime = ImportDates.parse(conversation["created_at"])
            for (index, item) in messages.enumerated() {
                guard let message = item as? [String: Any], message.importString("sender") == "human" else { continue }
                let raw = ImportTextFilter.cleanText(message["text"])
                let text = raw.isEmpty ? ImportTextFilter.textBlocks(message["content"]) : raw
                guard let kept = collector.accept(text) else { continue }
                let time = ImportDates.parse(message["created_at"])
                    ?? ImportDates.parse(message["updated_at"])
                    ?? conversationTime
                let messageId = message.importString("uuid") ?? "\(index)"
                collector.append(ImportedPrompt(
                    text: kept,
                    timestamp: time,
                    toolId: "claude",
                    url: conversationId.isEmpty ? nil : "https://claude.ai/chat/\(conversationId)",
                    sessionId: conversationId.isEmpty ? nil : conversationId,
                    sourceKey: "claude:\(conversationId):\(messageId)"
                ))
            }
        }
        guard sawMessages || conversations.isEmpty else { throw ImportError.unrecognized(hint) }
        return collector.result
    }
}

// MARK: - Gemini (Google Takeout)

/// Takeout `My Activity/Gemini Apps/MyActivity.json`: an array of activity
/// items `{header: "Gemini Apps" | "Bard", title: "Prompted …", time}`.
/// Items that aren't prompts ("Used …", feedback, other products) are
/// skipped. Also accepts the `{conversations: [{messages: [{role,
/// content}]}]}` shape some third-party exporters write.
enum GeminiTakeoutReader {
    static let hint = "Choose MyActivity.json from Google Takeout (My Activity › Gemini Apps, JSON format)."
    static let titlePrefixes = ["Prompted ", "Said: ", "Said ", "Asked "]

    static func read(_ url: URL) throws -> ImportReadResult {
        let file = try ImportPaths.exportFile(url, names: ["MyActivity.json"], hint: hint)
        guard file.pathExtension.lowercased() != "html" else { throw ImportError.unrecognized(hint) }
        let data = try ImportPaths.readData(file)
        let json = try? JSONSerialization.jsonObject(with: data)
        if let items = json as? [Any] {
            return try readActivity(items)
        }
        if let object = json as? [String: Any], let conversations = object["conversations"] as? [Any] {
            return readConversations(conversations)
        }
        throw ImportError.unrecognized(hint)
    }

    private static func readActivity(_ items: [Any]) throws -> ImportReadResult {
        var collector = ImportCollector()
        var sawActivity = false
        for case let item as [String: Any] in items {
            guard let title = item.importString("title") else { continue }
            sawActivity = true
            if let header = item.importString("header") {
                let lowered = header.lowercased()
                guard lowered.contains("gemini") || lowered.contains("bard") else { continue }
            }
            guard let prefix = titlePrefixes.first(where: { title.hasPrefix($0) }) else { continue }
            guard let text = collector.accept(String(title.dropFirst(prefix.count))) else { continue }
            let timeString = item.importString("time") ?? ""
            let time = ImportDates.parse(string: timeString)
            collector.append(ImportedPrompt(
                text: text,
                timestamp: time,
                toolId: "gemini",
                sourceKey: "gemini:\(timeString):\(ImportHash.short(text))"
            ))
        }
        guard sawActivity || items.isEmpty else { throw ImportError.unrecognized(hint) }
        return collector.result
    }

    private static func readConversations(_ conversations: [Any]) -> ImportReadResult {
        var collector = ImportCollector()
        for (conversationIndex, item) in conversations.enumerated() {
            guard let conversation = item as? [String: Any] else { continue }
            let conversationId = conversation.importString("id") ?? "generic-\(conversationIndex)"
            for (index, entry) in (conversation["messages"] as? [Any] ?? []).enumerated() {
                guard let message = entry as? [String: Any],
                      message.importString("role")?.lowercased() == "user" else { continue }
                guard let text = collector.accept(message["content"] as? String) else { continue }
                collector.append(ImportedPrompt(
                    text: text,
                    timestamp: ImportDates.parse(message["timestamp"] ?? message["create_time"]),
                    toolId: "gemini",
                    sessionId: conversationId,
                    sourceKey: "gemini:\(conversationId):\(index)"
                ))
            }
        }
        return collector.result
    }
}

// MARK: - Text / JSON lines

/// When every non-empty line is a JSON object with a string `text`
/// (optional `time` / `timestamp` / `ts` / `created_at`, `tool`,
/// `modality`, `role`), those are used; otherwise each non-empty line is one prompt
/// with no date. Reads at most `maxLines` lines. Short prompts are kept —
/// the person chose these lines — but scaffolding and explicitly non-user
/// messages are still dropped.
enum TextFileReader {
    static let maxLines = 200_000

    static func read(_ url: URL) throws -> ImportReadResult {
        let state = ImportPaths.exists(url)
        guard state.exists else { throw ImportError.notFound(ImportPaths.display(url)) }
        guard !state.isDirectory else {
            throw ImportError.unrecognized("Choose a .txt or .jsonl file with one prompt per line.")
        }

        var lines: [(number: Int, text: String)] = []
        var allJSON = true
        var objects: [[String: Any]] = []
        try ImportLines.forEach(in: url) { data, number in
            var text = String(decoding: data, as: UTF8.self)
            if text.hasSuffix("\r") { text.removeLast() }
            if number == 1, text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            if text.trimmingCharacters(in: .whitespaces).isEmpty { return number < maxLines }
            lines.append((number, text))
            if allJSON {
                if let object = ImportLines.jsonObject(Data(text.utf8)), object["text"] is String {
                    objects.append(object)
                } else {
                    allJSON = false
                    objects.removeAll()
                }
            }
            return number < maxLines
        }

        var collector = ImportCollector()
        if allJSON, !objects.isEmpty {
            for object in objects {
                guard allowsMessageRoles(in: object) else { continue }
                guard let text = collector.accept(object["text"] as? String, strictLength: false) else { continue }
                let rawTime = object["time"] ?? object["timestamp"] ?? object["ts"] ?? object["created_at"]
                let time = ImportDates.parse(rawTime)
                let modality: DatasetRow.Modality = (object.importString("modality")?.lowercased() == "voice") ? .voice : .typed
                let hash = ImportHash.short(text)
                let key = time.map { "text:\(Int($0.timeIntervalSince1970)):\(hash)" } ?? "text:\(hash)"
                collector.append(ImportedPrompt(
                    text: text,
                    timestamp: time,
                    modality: modality,
                    toolId: object.importString("tool")?.lowercased(),
                    sourceKey: key
                ))
            }
        } else {
            for line in lines {
                if let object = ImportLines.jsonObject(Data(line.text.utf8)), object["text"] is String,
                   !allowsMessageRoles(in: object) { continue }
                guard let text = collector.accept(line.text, strictLength: false) else { continue }
                collector.append(ImportedPrompt(
                    text: text,
                    timestamp: nil,
                    sourceKey: "text:\(ImportHash.short(text))"
                ))
            }
        }
        return collector.result
    }

    /// Unlabelled lines remain valid prompts. When an export identifies its
    /// speaker, every supplied role must identify the person, not a reply or
    /// system/tool message. Support the common nested export author shapes too.
    private static func allowsMessageRoles(in object: [String: Any]) -> Bool {
        let author = object["author"] as? [String: Any]
        let message = object["message"] as? [String: Any]
        let authorName = (object["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let knownRoles = ["user", "human", "assistant", "system", "developer", "tool", "function", "model"]
        // An author can also be a person's name, which is not a role label.
        let authorRole = authorName.flatMap { knownRoles.contains($0) ? $0 : nil }
        let roles = [object["role"] as? String, authorRole,
                     author?["role"] as? String, message?["role"] as? String]
        return roles.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .allSatisfy { $0 == "user" || $0 == "human" }
    }
}
