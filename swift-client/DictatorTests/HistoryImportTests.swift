import SQLite3
import XCTest
@testable import Dictator

/// Import history readers and dedupe. Every fixture is synthetic and written
/// to a fresh temporary folder; no test reads real user data.
final class HistoryImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    @discardableResult
    private func write(_ relative: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func jsonLines(_ objects: [Any]) throws -> String {
        try objects.map { try json($0) }.joined(separator: "\n") + "\n"
    }

    private func date(_ iso: String) -> Date {
        ImportDates.parse(string: iso)!
    }

    private func row(_ text: String, _ iso: String) -> DatasetRow {
        DatasetRow(
            id: UUID(), timestamp: date(iso), text: text, wordCount: text.split(separator: " ").count,
            modality: .typed, durationSeconds: 0, captureSource: nil, toolId: nil, appBundleId: nil,
            appName: nil, webHost: nil, remoteHost: nil, workingDirectory: nil, sessionId: nil,
            originEdgeId: nil, isImported: false, importBatchId: nil, typingSeconds: nil,
            latencyMs: nil, polishModel: nil, firstTakeAfterLoad: nil
        )
    }

    private func prompt(_ text: String, _ iso: String?, key: String) -> ImportedPrompt {
        ImportedPrompt(text: text, timestamp: iso.map(date), sourceKey: key)
    }

    // MARK: ChatGPT

    func testChatGPTExportReadsVisibleUserTextOnly() throws {
        let conversation: [String: Any] = [
            "id": "conv-1",
            "create_time": 1_700_000_000.0,
            "mapping": [
                "root": ["id": "root", "message": NSNull()],
                "sys": ["message": [
                    "id": "sys", "author": ["role": "system"], "create_time": 1_700_000_000.0,
                    "content": ["content_type": "text", "parts": ["You are a helpful assistant"]],
                ]],
                "ctx": ["message": [
                    "id": "ctx", "author": ["role": "user"], "create_time": 1_700_000_001.0,
                    "content": ["content_type": "user_editable_context", "parts": ["About me: long custom text"]],
                ]],
                "hidden": ["message": [
                    "id": "hidden", "author": ["role": "user"], "create_time": 1_700_000_002.0,
                    "content": ["content_type": "text", "parts": ["Hidden bootstrap message here"]],
                    "metadata": ["is_visually_hidden_from_conversation": true],
                ]],
                "u1": ["message": [
                    "id": "u1", "author": ["role": "user"], "create_time": 1_700_000_010.5,
                    "content": ["content_type": "text", "parts": ["Explain the borrow checker simply"]],
                ]],
                "a1": ["message": [
                    "id": "a1", "author": ["role": "assistant"], "create_time": 1_700_000_011.0,
                    "content": ["content_type": "text", "parts": ["Sure, here is an explanation"]],
                ]],
                "u2": ["message": [
                    "id": "u2", "author": ["role": "user"], "create_time": 1_700_000_020.0,
                    "content": ["content_type": "multimodal_text",
                                "parts": [["asset_pointer": "file-service://x"], "What is in this picture please"]],
                ]],
                "img": ["message": [
                    "id": "img", "author": ["role": "user"], "create_time": 1_700_000_030.0,
                    "content": ["content_type": "multimodal_text", "parts": [["asset_pointer": "file-service://y"]]],
                ]],
            ],
        ]
        let url = try write("chatgpt/conversations.json", try json([conversation]))

        let result = try HistoryImportReader.read(.chatgpt, from: url)

        XCTAssertEqual(result.prompts.map(\.text), ["Explain the borrow checker simply", "What is in this picture please"])
        XCTAssertEqual(result.skippedEmpty, 1)
        let first = try XCTUnwrap(result.prompts.first)
        XCTAssertEqual(first.toolId, "chatgpt")
        XCTAssertEqual(first.modality, .typed)
        XCTAssertEqual(first.sessionId, "conv-1")
        XCTAssertEqual(first.url, "https://chatgpt.com/c/conv-1")
        XCTAssertEqual(first.sourceKey, "chatgpt:conv-1:u1")
        XCTAssertEqual(first.timestamp, Date(timeIntervalSince1970: 1_700_000_010.5))

        // Choosing the export folder finds conversations.json inside it.
        let viaFolder = try HistoryImportReader.read(.chatgpt, from: root.appendingPathComponent("chatgpt"))
        XCTAssertEqual(viaFolder.prompts, result.prompts)
    }

    func testChatGPTRejectsOtherFiles() throws {
        let url = try write("other.json", try json(["not": "an export"]))
        XCTAssertThrowsError(try HistoryImportReader.read(.chatgpt, from: url)) { error in
            guard case ImportError.unrecognized = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try HistoryImportReader.read(.chatgpt, from: root.appendingPathComponent("missing.json"))) { error in
            guard case ImportError.notFound = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Claude.ai

    func testClaudeExportReadsHumanMessages() throws {
        let conversation: [String: Any] = [
            "uuid": "c-1",
            "created_at": "2025-03-01T10:00:00Z",
            "chat_messages": [
                ["uuid": "m1", "sender": "human", "text": "Draft a polite reminder email",
                 "created_at": "2025-03-01T10:00:05.123456Z"],
                ["uuid": "m2", "sender": "assistant", "text": "Here is a draft email for you"],
                ["uuid": "m3", "sender": "human", "text": "",
                 "content": [["type": "text", "text": "Make it shorter and friendlier"],
                             ["type": "tool_use", "text": "ignored tool block"]],
                 "created_at": "2025-03-01T10:01:00+02:00"],
                ["uuid": "m4", "sender": "human", "text": "   "],
            ],
        ]
        let url = try write("claude/conversations.json", try json([conversation]))

        let result = try HistoryImportReader.read(.claude, from: url)

        XCTAssertEqual(result.prompts.map(\.text), ["Draft a polite reminder email", "Make it shorter and friendlier"])
        XCTAssertEqual(result.skippedEmpty, 1)
        XCTAssertEqual(result.prompts[0].sourceKey, "claude:c-1:m1")
        XCTAssertEqual(result.prompts[0].toolId, "claude")
        XCTAssertEqual(result.prompts[0].url, "https://claude.ai/chat/c-1")
        XCTAssertEqual(result.prompts[0].timestamp?.timeIntervalSince1970 ?? 0, date("2025-03-01T10:00:05Z").timeIntervalSince1970 + 0.123456, accuracy: 0.001)
        XCTAssertEqual(result.prompts[1].timestamp, date("2025-03-01T08:01:00Z"))
    }

    // MARK: Claude Code

    func testClaudeCodeKeepsOnlyThePersonsTurns() throws {
        let base: [String: Any] = ["type": "user", "cwd": "/Users/x/dictator", "sessionId": "s-1"]
        func line(_ extra: [String: Any]) -> [String: Any] { base.merging(extra) { _, new in new } }
        let lines: [Any] = [
            line(["uuid": "u1", "timestamp": "2026-01-02T03:04:05.678Z",
                  "message": ["role": "user", "content": "Refactor the importer into smaller files"]]),
            line(["uuid": "u2", "timestamp": "2026-01-02T03:05:00Z",
                  "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]],
                  "toolUseResult": ["stdout": "ok"]]),
            line(["uuid": "u3", "timestamp": "2026-01-02T03:06:00Z", "isMeta": true,
                  "message": ["role": "user", "content": "Caveat: generated by local commands"]]),
            line(["uuid": "u4", "timestamp": "2026-01-02T03:07:00Z", "isCompactSummary": true,
                  "message": ["role": "user", "content": "This session is being continued from before"]]),
            line(["uuid": "u5", "timestamp": "2026-01-02T03:08:00Z", "isSidechain": true,
                  "message": ["role": "user", "content": "Sub-agent task description goes here"]]),
            line(["uuid": "u6", "timestamp": "2026-01-02T03:09:00Z", "origin": ["kind": "task-notification"],
                  "message": ["role": "user", "content": "A background task finished running"]]),
            line(["uuid": "u7", "timestamp": "2026-01-02T03:10:00Z",
                  "message": ["role": "user", "content": "<command-name>/clear</command-name>"]]),
            line(["uuid": "u8", "timestamp": "2026-01-02T03:11:00Z", "origin": ["kind": "human"],
                  "message": ["role": "user", "content": [["type": "image", "source": [:]],
                                                          ["type": "text", "text": "Why does this screenshot show an error"]]]]),
            ["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "content": "Done"]],
            line(["uuid": "u9", "timestamp": "2026-01-02T03:12:00Z", "entrypoint": "sdk-cli",
                  "message": ["role": "user", "content": "Scripted prompt from an SDK run"]]),
        ]
        let file = try write("claude/projects/-Users-x-dictator/s-1.jsonl", try jsonLines(lines) + "not json at all\n")

        let result = try HistoryImportReader.read(.claudeCode, from: root.appendingPathComponent("claude/projects"))

        XCTAssertEqual(result.prompts.map(\.text), [
            "Refactor the importer into smaller files",
            "Why does this screenshot show an error",
        ])
        XCTAssertEqual(result.skippedNoise, 1) // the <command-name> wrapper
        let first = result.prompts[0]
        XCTAssertEqual(first.toolId, "claude-code")
        XCTAssertEqual(first.workingDirectory, "/Users/x/dictator")
        XCTAssertEqual(first.sessionId, "s-1")
        XCTAssertEqual(first.sourceKey, "claude-code:u1")
        XCTAssertEqual(first.timestamp?.timeIntervalSince1970 ?? 0, date("2026-01-02T03:04:05Z").timeIntervalSince1970 + 0.678, accuracy: 0.001)

        // A single session file works too.
        XCTAssertEqual(try HistoryImportReader.read(.claudeCode, from: file).prompts, result.prompts)
    }

    func testDefaultLocationsResolveAgainstHome() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        XCTAssertThrowsError(try HistoryImportReader.read(.claudeCode, from: nil, home: home)) { error in
            guard case ImportError.notFound = error else { return XCTFail("\(error)") }
        }
        try write("home/.claude/projects/p/s.jsonl", try jsonLines([[
            "type": "user", "uuid": "x1", "timestamp": "2026-01-01T00:00:00Z",
            "message": ["role": "user", "content": "Read from the default location please"],
        ]]))
        XCTAssertEqual(try HistoryImportReader.read(.claudeCode, from: nil, home: home).prompts.count, 1)
        XCTAssertThrowsError(try HistoryImportReader.read(.wisprFlow, from: nil, home: home))
        XCTAssertThrowsError(try HistoryImportReader.read(.chatgpt, from: nil, home: home))
    }

    // MARK: Codex

    func testCodexPrefersSessionLogsOverHistory() throws {
        try write("codex/history.jsonl", try jsonLines([
            ["session_id": "sess-a", "ts": 1_760_000_000, "text": "Add a unit test for the parser"],
            ["session_id": "sess-b", "ts": 1_760_100_000, "text": "Only in history, not in a session"],
        ]))
        let sessionId = "01a0bb7e-e961-7be1-a620-52d58a281546"
        try write("codex/sessions/2025/10/09/rollout-2025-10-09T08-53-20-\(sessionId).jsonl", try jsonLines([
            ["type": "session_meta", "timestamp": "2025-10-09T08:53:19Z",
             "payload": ["id": sessionId, "cwd": "/Users/x/app"]],
            ["type": "response_item", "timestamp": "2025-10-09T08:53:19Z",
             "payload": ["type": "message", "role": "user",
                         "content": [["type": "input_text", "text": "<environment_context>cwd</environment_context>"]]]],
            ["type": "turn_context", "timestamp": "2025-10-09T08:53:20Z", "payload": ["cwd": "/Users/x/app/sub"]],
            ["type": "response_item", "timestamp": "2025-10-09T08:53:20.100Z",
             "payload": ["type": "message", "role": "user",
                         "content": [["type": "input_text", "text": "Add a unit test for the parser"]]]],
            ["type": "event_msg", "timestamp": "2025-10-09T08:53:20.200Z",
             "payload": ["type": "user_message", "message": "Add a unit test for the parser"]],
            ["type": "response_item", "timestamp": "2025-10-09T08:53:30Z",
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Done"]]]],
        ]))

        let result = try HistoryImportReader.read(.codex, from: root.appendingPathComponent("codex"))

        XCTAssertEqual(result.prompts.map(\.text), ["Add a unit test for the parser", "Only in history, not in a session"])
        XCTAssertEqual(result.skippedNoise, 1)
        let session = result.prompts[0]
        XCTAssertEqual(session.workingDirectory, "/Users/x/app/sub")
        XCTAssertEqual(session.sessionId, sessionId)
        XCTAssertEqual(session.toolId, "codex")
        XCTAssertTrue(session.sourceKey.hasPrefix("codex:\(sessionId):"))
        let history = result.prompts[1]
        XCTAssertEqual(history.sessionId, "sess-b")
        XCTAssertEqual(history.timestamp, Date(timeIntervalSince1970: 1_760_100_000))
        XCTAssertNil(history.workingDirectory)
    }

    // MARK: Gemini

    func testGeminiTakeoutReadsPromptedItems() throws {
        let items: [Any] = [
            ["header": "Gemini Apps", "title": "Prompted Plan a three day trip to Lisbon",
             "time": "2025-05-04T12:30:15.123Z", "products": ["Gemini Apps"]],
            ["header": "Gemini Apps", "title": "Used an Assistant feature", "time": "2025-05-04T12:31:00Z"],
            ["header": "Bard", "title": "Prompted Summarize this article for me", "time": "2023-08-01T09:00:00Z"],
            ["header": "Search", "title": "Prompted something from another product", "time": "2025-05-04T12:00:00Z"],
            "not an object",
        ]
        let url = try write("Takeout/My Activity/Gemini Apps/MyActivity.json", try json(items))

        let result = try HistoryImportReader.read(.gemini, from: url)

        XCTAssertEqual(result.prompts.map(\.text), ["Plan a three day trip to Lisbon", "Summarize this article for me"])
        XCTAssertEqual(result.prompts.first?.toolId, "gemini")
        XCTAssertEqual(result.prompts.first?.timestamp?.timeIntervalSince1970 ?? 0, date("2025-05-04T12:30:15Z").timeIntervalSince1970 + 0.123, accuracy: 0.001)
        // Choosing the Takeout folder finds MyActivity.json.
        XCTAssertEqual(try HistoryImportReader.read(.gemini, from: root.appendingPathComponent("Takeout")).prompts.count, 2)
    }

    // MARK: Wispr Flow

    func testWisprFlowReadsHistoryTableReadOnly() throws {
        let url = root.appendingPathComponent("Wispr Flow/flow.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE History (transcriptEntityId TEXT, asrText TEXT, formattedText TEXT, editedText TEXT,
                              timestamp TEXT, app TEXT, url TEXT, duration REAL);
        INSERT INTO History VALUES ('t1', 'raw words', 'Formatted words.', NULL,
                                    '2025-06-01 12:34:56.789 +00:00', 'com.tinyspeck.slackmacgap', NULL, 4.5);
        INSERT INTO History VALUES ('t2', 'hi', 'Hi', 'Hi there, edited.',
                                    '2025-06-01T13:00:00Z', 'com.google.Chrome', 'https://mail.google.com/mail', 2);
        INSERT INTO History VALUES ('t3', '', NULL, NULL, '2025-06-01T14:00:00Z', 'com.apple.Notes', NULL, 1);
        INSERT INTO History VALUES ('t4', 'ok', NULL, NULL, '2025-06-01T15:00:00Z', 'org.example.unknown', NULL, NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let result = try HistoryImportReader.read(.wisprFlow, from: url)

        XCTAssertEqual(result.prompts.map(\.text), ["Formatted words.", "Hi there, edited.", "ok"])
        XCTAssertEqual(result.skippedEmpty, 1)
        let first = result.prompts[0]
        XCTAssertEqual(first.modality, .voice)
        XCTAssertNil(first.toolId)
        XCTAssertEqual(first.appBundleId, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(first.appName, "Slack")
        XCTAssertEqual(first.durationSeconds, 4.5)
        XCTAssertEqual(first.sourceKey, "wispr:t1")
        XCTAssertEqual(first.timestamp?.timeIntervalSince1970 ?? 0, date("2025-06-01T12:34:56Z").timeIntervalSince1970 + 0.789, accuracy: 0.001)
        XCTAssertEqual(result.prompts[1].url, "https://mail.google.com/mail")
        XCTAssertEqual(result.prompts[2].appBundleId, "org.example.unknown")
        XCTAssertNil(result.prompts[2].appName)
        XCTAssertNil(result.prompts[2].durationSeconds)

        // A database without a History table isn't Wispr Flow's.
        let other = root.appendingPathComponent("other.sqlite")
        XCTAssertEqual(sqlite3_open(other.path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE Notes (x TEXT)", nil, nil, nil)
        sqlite3_close(db)
        XCTAssertThrowsError(try HistoryImportReader.read(.wisprFlow, from: other)) { error in
            guard case ImportError.unrecognized = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Text files

    func testTextFileOnePromptPerLine() throws {
        let url = try write("prompts.txt", "\u{FEFF}First prompt here\r\n\nfix it\n<system-reminder>x</system-reminder>\n{\"text\": \"json-looking line\"}\n")
        let result = try HistoryImportReader.read(.textFile, from: url)
        XCTAssertEqual(result.prompts.map(\.text), ["First prompt here", "fix it", "{\"text\": \"json-looking line\"}"])
        XCTAssertTrue(result.prompts.allSatisfy { $0.timestamp == nil && $0.toolId == nil })
        XCTAssertEqual(result.skippedNoise, 1)
    }

    func testTextFileJSONLines() throws {
        let url = try write("prompts.jsonl", try jsonLines([
            ["text": "Summarize the meeting notes", "time": "2025-02-03T04:05:06Z", "tool": "ChatGPT"],
            ["text": "Second one with unix time", "timestamp": 1_738_555_506_000],
            ["text": "No time at all"],
        ]))
        let result = try HistoryImportReader.read(.textFile, from: url)
        XCTAssertEqual(result.prompts.map(\.text), ["Summarize the meeting notes", "Second one with unix time", "No time at all"])
        XCTAssertEqual(result.prompts[0].timestamp, date("2025-02-03T04:05:06Z"))
        XCTAssertEqual(result.prompts[0].toolId, "chatgpt")
        XCTAssertEqual(result.prompts[1].timestamp, Date(timeIntervalSince1970: 1_738_555_506))
        XCTAssertNil(result.prompts[2].timestamp)
        XCTAssertEqual(Set(result.prompts.map(\.sourceKey)).count, 3)
    }

    func testTextFileJSONLinesImportsOnlyUserRolesAndUnlabelledPrompts() throws {
        let url = try write("roles.jsonl", try jsonLines([
            ["text": "Explicit user prompt", "role": "user"],
            ["text": "Human prompt with normalized role", "role": " HUMAN \n"],
            ["text": "Unlabelled prompt remains supported"],
            ["text": "Named author remains supported", "author": "Sample Person"],
            ["text": "Nested author user prompt", "author": ["role": "user"]],
            ["text": "String author human prompt", "author": "human"],
            ["text": "Nested message user prompt", "message": ["role": "user"]],
            ["text": "Assistant reply must be excluded", "role": "assistant"],
            ["text": "System instructions must be excluded", "role": "system"],
            ["text": "Developer instructions must be excluded", "role": "developer"],
            ["text": "Tool output must be excluded", "role": "tool"],
            ["text": "Model output must be excluded", "role": "model"],
            ["text": "Unknown speaker must be excluded", "role": "unknown"],
            ["text": "Nested author assistant must be excluded", "author": ["role": "assistant"]],
            ["text": "String author assistant must be excluded", "author": "assistant"],
            ["text": "Nested message assistant must be excluded", "message": ["role": "assistant"]],
            ["text": "Conflicting roles must be excluded", "role": "user", "author": ["role": "assistant"]],
        ]))

        let result = try HistoryImportReader.read(.textFile, from: url)

        XCTAssertEqual(result.prompts.map(\.text), [
            "Explicit user prompt", "Human prompt with normalized role",
            "Unlabelled prompt remains supported", "Named author remains supported", "Nested author user prompt",
            "String author human prompt", "Nested message user prompt",
        ])
    }

    func testMixedTextFileStillExcludesExplicitAssistantJSONLine() throws {
        let userJSON = try json(["text": "A JSON-looking user prompt", "role": "user"])
        let unlabelledJSON = try json(["text": "An unlabelled JSON-looking prompt"])
        let assistantJSON = try json(["text": "Assistant reply must not become plain text", "role": "assistant"])
        let url = try write("mixed.txt", "An ordinary plain text prompt\n\(userJSON)\n\(unlabelledJSON)\n\(assistantJSON)\n")

        let result = try HistoryImportReader.read(.textFile, from: url)

        XCTAssertEqual(result.prompts.map(\.text), ["An ordinary plain text prompt", userJSON, unlabelledJSON])
    }

    // MARK: Noise

    func testNoiseFilter() {
        typealias F = ImportTextFilter
        XCTAssertEqual(F.classify("  Write a haiku about autumn  "), .keep("Write a haiku about autumn"))
        XCTAssertEqual(F.classify("   "), .empty)
        XCTAssertEqual(F.classify(nil), .empty)
        XCTAssertEqual(F.classify("thanks"), .noise) // too short for a typed source
        XCTAssertEqual(F.classify("thanks", strictLength: false), .keep("thanks"))
        XCTAssertEqual(F.classify("<environment_context>\n<cwd>/x</cwd>"), .noise)
        XCTAssertEqual(F.classify("You are running inside the Codex desktop app, with sandboxing"), .noise)
        XCTAssertEqual(F.classify("Base directory for this skill: /x/y and more"), .noise)
        XCTAssertEqual(F.classify("Look at this <system-reminder>stuff</system-reminder> ok"), .noise)
        XCTAssertEqual(F.classify("<image name=a.png> </image>"), .noise)
        XCTAssertEqual(F.classify("<image name=a.png> what is wrong here"), .keep("<image name=a.png> what is wrong here"))
        XCTAssertEqual(F.classify("/model opus", strictLength: false), .noise)
        XCTAssertEqual(F.classify("exit", strictLength: false), .noise)
        XCTAssertEqual(F.classify("help me write a cover letter"), .keep("help me write a cover letter"))
        XCTAssertEqual(F.classify("[Request interrupted by user for tool use]"), .noise)
    }

    // MARK: Dates

    func testDateParsingVariants() {
        let reference = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        XCTAssertEqual(ImportDates.parse(string: "2023-11-14T22:13:20Z"), reference)
        XCTAssertEqual(ImportDates.parse(string: "2023-11-14T22:13:20.000Z"), reference)
        XCTAssertEqual(ImportDates.parse(string: "2023-11-14T22:13:20.500Z"), reference.addingTimeInterval(0.5))
        XCTAssertEqual(ImportDates.parse(string: "2023-11-15T00:13:20+02:00"), reference)
        XCTAssertEqual(ImportDates.parse(string: "2023-11-14T17:13:20-0500"), reference)
        XCTAssertEqual(ImportDates.parse(string: "2023-11-14 22:13:20 +00:00"), reference)
        XCTAssertEqual(ImportDates.parse(string: "2023-11-14 22:13:20"), reference)
        XCTAssertEqual(ImportDates.parse(string: "2023-11-14T22:13"), reference.addingTimeInterval(-20))
        XCTAssertEqual(ImportDates.parse(string: "2023-11-14"), Date(timeIntervalSince1970: 1_699_920_000))
        XCTAssertEqual(ImportDates.parse(string: "1700000000"), reference)
        XCTAssertEqual(ImportDates.parse(1_700_000_000), reference)
        XCTAssertEqual(ImportDates.parse(1_700_000_000_000), reference)
        XCTAssertEqual(ImportDates.parse(NSNumber(value: 1_700_000_000.25)), reference.addingTimeInterval(0.25))
        XCTAssertNil(ImportDates.parse(string: "yesterday"))
        XCTAssertNil(ImportDates.parse(string: "2023-13-01T00:00:00Z"))
        XCTAssertNil(ImportDates.parse(NSNumber(value: true)))
        XCTAssertNil(ImportDates.parse(nil))
        XCTAssertEqual(ImportDates.parse(string: "2024-02-29T12:00:00Z"), Date(timeIntervalSince1970: 1_709_208_000))
    }

    // MARK: Lines

    func testLineReaderSkipsOversizedLinesAndHandlesNoTrailingNewline() throws {
        let long = String(repeating: "x", count: 3_000)
        let url = try write("lines.txt", "one\n\(long)\ntwo\nthree")
        var seen: [(Int, String)] = []
        try ImportLines.forEach(in: url, maxLineBytes: 1_000) { data, number in
            seen.append((number, String(decoding: data, as: UTF8.self)))
            return true
        }
        XCTAssertEqual(seen.map(\.1), ["one", "two", "three"])
        XCTAssertEqual(seen.map(\.0), [1, 3, 4])
    }

    // MARK: Dedupe

    func testDedupeAgainstHistoryAndWithinSource() {
        let read = ImportReadResult(prompts: [
            prompt("Deploy the service tonight", "2025-01-10T12:00:00Z", key: "k1"), // in history, 30 h apart
            prompt("Deploy the service tonight!", "2025-01-10T12:00:30Z", key: "k1b"), // same text 30 s later
            prompt("Write the release notes", "2025-01-10T12:00:00Z", key: "k2"), // history row 3 days away
            prompt("Already imported before", "2025-01-11T09:00:00Z", key: "old-key"),
            prompt("An undated prompt here", nil, key: "k4"), // history has the text
            prompt("Brand new prompt", "2025-01-12T08:00:00Z", key: "k5"),
            prompt("Brand new prompt", "2025-01-12T08:00:00Z", key: "k5"), // exact repeat
            prompt("Brand new prompt", "2025-01-12T09:00:00Z", key: "k6"), // same text an hour later: kept
            prompt("Undated twice", nil, key: "u1"),
            prompt("undated, TWICE", nil, key: "u2"),
        ])
        let existing = [
            row("deploy the service tonight", "2025-01-11T18:00:00Z"),
            row("Write the release notes", "2025-01-13T12:00:01Z"),
            row("An undated prompt here.", "2020-01-01T00:00:00Z"),
        ]

        let preview = ImportDeduper.preview(read, existing: existing, importedKeys: ["old-key"])

        XCTAssertEqual(preview.toImport.map(\.sourceKey), ["k2", "k5", "k6", "u1"])
        XCTAssertEqual(preview.alreadyInHistory, 3) // k1, old-key, k4
        XCTAssertEqual(preview.duplicatesInSource, 3) // k1b, second k5, u2
        XCTAssertEqual(preview.earliest, date("2025-01-10T12:00:00Z"))
        XCTAssertEqual(preview.latest, date("2025-01-12T09:00:00Z"))
    }

    func testImportPreviewKeepsExplicitlyDeletedSourceIDsSeparateFromExistingRows() {
        let read = ImportReadResult(prompts: [
            prompt("Deleted synthetic prompt", nil, key: "deleted"),
            prompt("Existing synthetic prompt", nil, key: "existing"),
            prompt("New synthetic prompt", nil, key: "new"),
        ])
        let preview = ImportDeduper.preview(read, existing: [], importedKeys: ["existing"], deletedKeys: ["deleted"])
        XCTAssertEqual(preview.toImport.map(\.sourceKey), ["new"])
        XCTAssertEqual(preview.alreadyInHistory, 1)
        XCTAssertEqual(preview.previouslyDeleted, 1)
    }

    func testADeletedPromptDoesNotHideALaterOneWithTheSameWords() {
        let read = ImportReadResult(prompts: [
            prompt("same words here", "2025-01-11T18:00:00Z", key: "gone"),
            prompt("same words here", "2025-01-11T18:00:30Z", key: "kept"),
        ])
        let preview = ImportDeduper.preview(read, existing: [], importedKeys: [], deletedKeys: ["gone"])
        XCTAssertEqual(preview.toImport.map(\.sourceKey), ["kept"])
        XCTAssertEqual(preview.previouslyDeleted, 1)
    }

    func testDedupeWindowEdges() {
        XCTAssertTrue(ImportDeduper.matchesExisting([100, 200_000], 100 + 36 * 3_600))
        XCTAssertFalse(ImportDeduper.matchesExisting([100], 101 + 36 * 3_600))
        XCTAssertTrue(ImportDeduper.matchesExisting([500_000], 500_000 - 36 * 3_600))
        XCTAssertTrue(ImportDeduper.matchesExisting([1], nil))
        XCTAssertFalse(ImportDeduper.matchesExisting(nil, nil))
        XCTAssertFalse(ImportDeduper.matchesExisting([], 5))
    }

    func testSourceInfoCoversEveryKind() {
        for kind in ImportSourceKind.allCases {
            let info = ImportSourceInfo.info(for: kind)
            XCTAssertEqual(info.kind, kind)
            XCTAssertFalse(info.name.isEmpty)
            XCTAssertTrue(info.fields.contains(.text))
            XCTAssertEqual(info.readsFromThisMac, info.defaultLocation != nil)
            XCTAssertFalse(info.how.contains("!"))
        }
        XCTAssertTrue(ImportSourceInfo.info(for: .wisprFlow).fields.contains(.duration))
    }
}
