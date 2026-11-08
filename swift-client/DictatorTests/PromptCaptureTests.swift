import XCTest
import Observation
@testable import Dictator

// MARK: - Catalog

final class ToolCatalogTests: XCTestCase {
    private var catalog: ToolCatalog { .shared }

    func testBundledCatalogLoads() {
        XCTAssertGreaterThan(catalog.tools.count, 20)
        XCTAssertNotNil(catalog.tool(id: "claude-code"))
        XCTAssertNotNil(catalog.tool(id: "codex"))
        XCTAssertEqual(Set(catalog.tools.map(\.id)).count, catalog.tools.count, "tool ids must be unique")
    }

    func testLookupByAppWebsiteAndLegacyID() {
        XCTAssertEqual(catalog.tool(forBundleID: "com.openai.codex")?.id, "chatgpt")
        XCTAssertEqual(catalog.tool(forBundleID: "com.openai.chat")?.id, "chatgpt")
        XCTAssertEqual(catalog.tool(forBundleID: "com.jetbrains.pycharm")?.id, "jetbrains-ai")
        XCTAssertEqual(catalog.tool(forHost: "work.claude.ai")?.id, "claude")
        XCTAssertNil(catalog.tool(forHost: "notclaude.ai"))
        XCTAssertEqual(catalog.hostApp(bundleID: "com.mitchellh.ghostty")?.kind, .terminal)
        XCTAssertEqual(catalog.hostApp(bundleID: "company.thebrowser.Browser")?.kind, .browser)
    }

    func testProcessMatchingUsesNamesNotSubstrings() {
        XCTAssertEqual(catalog.tool(forProcess: "/Users/x/.local/share/claude/versions/2.1", arguments: [])?.id, nil)
        XCTAssertEqual(catalog.tool(forProcess: "/Users/x/.local/bin/claude", arguments: [])?.id, "claude-code")
        XCTAssertEqual(catalog.tool(forProcess: "/usr/local/bin/node", arguments: ["/usr/local/lib/node_modules/@openai/codex/bin/codex.js"])?.id, "codex")
        XCTAssertNil(catalog.tool(forProcess: "/usr/bin/vim", arguments: ["claude-notes.md"]))
        XCTAssertNil(catalog.tool(forProcess: "/bin/zsh", arguments: ["-c", "cd ~/claude-projects"]))
    }

    func testCustomToolsMerge() throws {
        var base = ToolCatalog(version: 1, tools: [ToolDefinition(id: "a", name: "A", category: .agent)], hostApps: [])
        base.merge(ToolCatalog(version: 1, tools: [
            ToolDefinition(id: "a", name: "A2", category: .agent),
            ToolDefinition(id: "b", name: "B", category: .chat),
        ], hostApps: []))
        XCTAssertEqual(base.tools.map(\.name), ["A2", "B"])
    }
}

// MARK: - Custom tool removal

@MainActor
final class CustomToolRemovalTests: XCTestCase {
    private let target = ToolDefinition(id: "custom-qa-removal", name: "QA removal", category: .chat)
    private let other = ToolDefinition(id: "custom-qa-keep", name: "QA keep", category: .chat)

    private func fixture(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("custom-tools.json")
        try JSONEncoder().encode(ToolCatalog(version: 1, tools: [target, other], hostApps: [])).write(to: url)
        try body(url)
    }

    func testRemovalInvalidatesCatalogAndPolicyReadersAndPreservesForeignChoices() throws {
        try fixture { url in
            let store = ToolCatalogStore(bundled: nil, custom: url)
            let settings = AppSettings.shared
            let original = settings.cachedSurfacePolicyJSON
            defer { settings.cachedSurfacePolicyJSON = original }
            let rules = [SurfaceRule(kind: "domain", pattern: "example.invalid", action: "ignore"),
                         SurfaceRule(kind: "tool", pattern: "remote-only-tool", action: "ignore", modality: "voice")]
            settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "ignore", defaultVoice: "ignore", rules: rules,
                version: 2, tools: [target.id: ToolSwitch(typed: true, voice: false), other.id: ToolSwitch(typed: false),
                                   "remote-only-tool": ToolSwitch(typed: true)], scrubSecrets: false))
            let catalogChanged = expectation(description: "same-page catalog reader invalidated")
            let policyChanged = expectation(description: "same-page policy reader invalidated")
            withObservationTracking { _ = store.catalog.tools } onChange: { catalogChanged.fulfill() }
            withObservationTracking { _ = settings.surfacePolicy.allowsAnyTypedSave } onChange: { policyChanged.fulfill() }
            try CustomToolRemoval.remove(id: target.id, settings: settings) { try store.removeCustomTool(id: $0) }
            wait(for: [catalogChanged, policyChanged], timeout: 0.1)
            XCTAssertNil(store.catalog.tool(id: target.id))
            XCTAssertEqual(store.catalog.tools, [other])
            XCTAssertEqual(try ToolCatalog.decode(Data(contentsOf: url)).tools, [other])
            XCTAssertNil(settings.surfacePolicy.tools?[target.id], "remove the entire selected switch, including its voice override")
            XCTAssertEqual(settings.surfacePolicy.tools?[other.id], ToolSwitch(typed: false))
            XCTAssertEqual(settings.surfacePolicy.tools?["remote-only-tool"], ToolSwitch(typed: true))
            XCTAssertEqual(settings.surfacePolicy.rules, rules)
            XCTAssertEqual(settings.surfacePolicy.defaultVoice, "ignore")
            XCTAssertEqual(settings.surfacePolicy.scrubSecrets, false)
        }
    }

    func testRemovingOnlyEnabledToolTurnsTypedHistoryOffWithoutChangingHistoryMaster() throws {
        try fixture { url in
            let store = ToolCatalogStore(bundled: nil, custom: url)
            let settings = AppSettings.shared
            let original = settings.cachedSurfacePolicyJSON
            let historyMaster = settings.persistHistory
            defer { settings.cachedSurfacePolicyJSON = original }
            settings.updateCachedSurfacePolicy(SurfacePolicy(version: 2, tools: [target.id: ToolSwitch(typed: true)]))
            XCTAssertTrue(settings.surfacePolicy.allowsAnyTypedSave)
            try CustomToolRemoval.remove(id: target.id, settings: settings) { try store.removeCustomTool(id: $0) }
            XCTAssertFalse(settings.surfacePolicy.allowsAnyTypedSave)
            XCTAssertEqual(settings.persistHistory, historyMaster)
        }
    }

    func testFailedWriteKeepsCatalogDiskAndPolicyUnchanged() throws {
        try fixture { url in
            let before = try Data(contentsOf: url)
            let store = ToolCatalogStore(bundled: nil, custom: url, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
            let settings = AppSettings.shared
            let original = settings.cachedSurfacePolicyJSON
            defer { settings.cachedSurfacePolicyJSON = original }
            settings.updateCachedSurfacePolicy(SurfacePolicy(version: 2, tools: [target.id: ToolSwitch(typed: true, voice: false)]))
            let policy = settings.surfacePolicy
            XCTAssertThrowsError(try CustomToolRemoval.remove(id: target.id, settings: settings) { try store.removeCustomTool(id: $0) })
            XCTAssertNotNil(store.catalog.tool(id: target.id))
            XCTAssertEqual(try Data(contentsOf: url), before)
            XCTAssertEqual(settings.surfacePolicy, policy)
        }
    }

    func testMalformedCustomFileIsNotOverwrittenBySaveOrRemoval() throws {
        try fixture { url in
            let bad = Data("not a catalog".utf8)
            try bad.write(to: url)
            let store = ToolCatalogStore(bundled: nil, custom: url)
            XCTAssertThrowsError(try store.removeCustomTool(id: target.id))
            XCTAssertThrowsError(try store.saveCustomTool(target))
            XCTAssertEqual(try Data(contentsOf: url), bad)
        }
    }

    func testExplicitRetryAfterMissingFileRemovesOnlySelectedOrphan() throws {
        try fixture { url in
            try FileManager.default.removeItem(at: url)
            let store = ToolCatalogStore(bundled: nil, custom: url)
            let settings = AppSettings.shared
            let original = settings.cachedSurfacePolicyJSON
            defer { settings.cachedSurfacePolicyJSON = original }
            settings.updateCachedSurfacePolicy(SurfacePolicy(version: 2,
                tools: [target.id: ToolSwitch(typed: true), "unknown-other-mac": ToolSwitch(typed: true)]))
            try CustomToolRemoval.remove(id: target.id, settings: settings) { try store.removeCustomTool(id: $0) }
            XCTAssertNil(settings.surfacePolicy.tools?[target.id])
            XCTAssertTrue(settings.surfacePolicy.isToolOn("unknown-other-mac"))
        }
    }

    func testAddingToolAlsoPublishesTheCatalog() throws {
        try fixture { url in
            let store = ToolCatalogStore(bundled: nil, custom: url)
            let changed = expectation(description: "catalog addition invalidates readers")
            withObservationTracking { _ = store.catalog.tools } onChange: { changed.fulfill() }
            let added = ToolDefinition(id: "custom-added", name: "Added", category: .chat)
            try store.saveCustomTool(added)
            wait(for: [changed], timeout: 0.1)
            XCTAssertEqual(store.catalog.tool(id: added.id), added)
        }
    }
}

// MARK: - Policy

final class SurfacePolicyV2Tests: XCTestCase {
    private let catalog = ToolCatalog.shared

    private func policy(tools: [String: ToolSwitch], rules: [SurfaceRule] = [], typed: String = "ignore", voice: String = "save") -> SurfacePolicy {
        SurfacePolicy(defaultTyped: typed, defaultVoice: voice, rules: rules, version: 2, tools: tools)
    }

    func testToolSwitchesDecideTypedPrompts() {
        let p = policy(tools: ["claude-code": ToolSwitch(typed: true), "codex": ToolSwitch(typed: false)])
        XCTAssertEqual(p.decide(CaptureContext(toolID: "claude-code"), modality: "typed").action, .save)
        XCTAssertEqual(p.decide(CaptureContext(toolID: "codex"), modality: "typed").reason, "tool-off:codex")
        XCTAssertEqual(p.decide(CaptureContext(toolID: "gemini-cli"), modality: "typed").reason, "tool-unset:gemini-cli")
        XCTAssertEqual(p.decide(CaptureContext(appBundleID: "com.tinyspeck.slackmacgap"), modality: "typed").action, .ignore)
    }

    func testVoiceFollowsDefaultUnlessToolSaysNo() {
        let p = policy(tools: ["claude": ToolSwitch(typed: true, voice: false), "codex": ToolSwitch(typed: false)])
        XCTAssertEqual(p.decide(CaptureContext(toolID: "claude"), modality: "voice").action, .ignore)
        XCTAssertEqual(p.decide(CaptureContext(toolID: "codex"), modality: "voice").action, .save)
        XCTAssertEqual(p.decide(CaptureContext(appBundleID: "com.apple.mail"), modality: "voice").action, .save)
    }

    func testOverridesWinAndMatchEveryKind() {
        let p = policy(
            tools: ["codex": ToolSwitch(typed: true)],
            rules: [
                SurfaceRule(kind: "remote", pattern: "work-*", action: "ignore", modality: "both"),
                SurfaceRule(kind: "app", pattern: "com.tinyspeck.slackmacgap", action: "save", modality: "typed"),
                SurfaceRule(kind: "domain", pattern: "notion.so", action: "save", modality: "typed"),
                SurfaceRule(kind: "tool", pattern: "claude", action: "ignore", modality: "voice"),
            ]
        )
        XCTAssertEqual(p.decide(CaptureContext(toolID: "codex", remoteHost: "work-box"), modality: "typed").action, .ignore)
        XCTAssertEqual(p.decide(CaptureContext(toolID: "codex", remoteHost: "home-box"), modality: "typed").action, .save)
        XCTAssertEqual(p.decide(CaptureContext(appBundleID: "com.tinyspeck.slackmacgap"), modality: "typed").action, .save)
        XCTAssertEqual(p.decide(CaptureContext(webHost: "www.notion.so"), modality: "typed").action, .save)
        XCTAssertEqual(p.decide(CaptureContext(toolID: "claude"), modality: "voice").action, .ignore)
    }

    func testAllowsAnyTypedSave() {
        XCTAssertFalse(policy(tools: [:]).allowsAnyTypedSave)
        XCTAssertTrue(policy(tools: ["codex": ToolSwitch(typed: true)]).allowsAnyTypedSave)
        XCTAssertFalse(policy(tools: ["codex": ToolSwitch(typed: false)]).allowsAnyTypedSave)
        XCTAssertTrue(policy(tools: [:], typed: "save").allowsAnyTypedSave)
    }

    func testV2JSONRoundTripsAndOldPeersIgnoreNewKeys() throws {
        let p = policy(tools: ["codex": ToolSwitch(typed: true, voice: false)], rules: [SurfaceRule(kind: "remote", pattern: "x", action: "ignore")])
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(SurfacePolicy.self, from: data), p)
        // A v1 decoder only needs the three v1 keys, which are still there.
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(object["default_typed"])
        XCTAssertNotNil(object["rules"])
    }

    func testDecisionExplanationsAreHuman() {
        XCTAssertEqual(CaptureDecision(action: .save, reason: "tool:claude-code").explanation(), "Typed history is on for Claude Code (Settings › History & Privacy › Choose Apps).")
        XCTAssertEqual(CaptureDecision(action: .save, reason: "override:domain:notion.so").explanation(), "An exception you added saves prompts from notion.so.")
        XCTAssertEqual(CaptureDecision(action: .save, reason: "override:domain:localhost:3000").explanation(), "An exception you added saves prompts from localhost:3000.")
        XCTAssertEqual(CaptureDecision(action: .ignore, reason: "override:remote:work-*").explanation(), "An exception you added ignores servers matching work-*.")
        XCTAssertEqual(CaptureDecision(action: .ignore, reason: "override:tool:claude-code").explanation(), "An exception you added ignores Claude Code.")
        XCTAssertEqual(CaptureDecision(action: .ignore, reason: "override:app:invalid.example.MissingApp").explanation(), "An exception you added ignores Missing App.")
        XCTAssertEqual(DestinationSnapshot.insertionDescription("paste"), "Pasted by Dictator")
        XCTAssertEqual(DestinationSnapshot.insertionDescription("import"), "Imported from another app")
        XCTAssertNil(DestinationSnapshot.insertionDescription("hook"))
        XCTAssertTrue(CaptureDecision(action: .save, reason: "default:voice").explanation().contains("Dictation"))
    }
}

// The settings page observes these derived values, not the JSON backing field.
@MainActor
final class SurfacePolicyObservationTests: XCTestCase {
    func testExceptionAddAndRemoveInvalidateStatusAndVisibleRulesWithoutNavigation() {
        let settings = AppSettings.shared
        let original = settings.cachedSurfacePolicyJSON
        defer { settings.cachedSurfacePolicyJSON = original }
        settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "ignore", defaultVoice: "save", rules: [], version: 2, tools: [:]))
        let rule = SurfaceRule(kind: "app", pattern: "com.example.synthetic-editor", action: "save", modality: "typed")

        func observeThenEdit(_ edit: (inout SurfacePolicy) -> Void) {
            let statusChanged = expectation(description: "derived typed-history status invalidated")
            let rowsChanged = expectation(description: "visible exception list invalidated")
            withObservationTracking {
                _ = settings.surfacePolicy.allowsAnyTypedSave
            } onChange: { statusChanged.fulfill() }
            withObservationTracking {
                _ = settings.surfacePolicy.rules
            } onChange: { rowsChanged.fulfill() }
            settings.updateSurfacePolicy(edit)
            wait(for: [statusChanged, rowsChanged], timeout: 0.1)
        }

        XCTAssertFalse(settings.surfacePolicy.allowsAnyTypedSave)
        observeThenEdit { $0.rules.append(rule) }
        XCTAssertTrue(settings.surfacePolicy.allowsAnyTypedSave)
        XCTAssertEqual(settings.surfacePolicy.rules, [rule])
        observeThenEdit { $0.rules.removeAll() }
        XCTAssertFalse(settings.surfacePolicy.allowsAnyTypedSave)
        XCTAssertTrue(settings.surfacePolicy.rules.isEmpty)
    }

    func testMirroredJSONUpdateInvalidatesDerivedPolicyReaders() throws {
        let settings = AppSettings.shared
        let original = settings.cachedSurfacePolicyJSON
        defer { settings.cachedSurfacePolicyJSON = original }
        settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "ignore", defaultVoice: "save", rules: [], version: 2, tools: [:]))
        let changed = expectation(description: "mirrored policy refresh invalidates derived reader")
        withObservationTracking {
            _ = settings.surfacePolicy.allowsAnyTypedSave
        } onChange: { changed.fulfill() }
        let remotePolicy = SurfacePolicy(defaultTyped: "ignore", defaultVoice: "save", rules: [], version: 2,
                                         tools: ["codex": ToolSwitch(typed: true)])
        settings.cachedSurfacePolicyJSON = try XCTUnwrap(String(data: JSONEncoder().encode(remotePolicy), encoding: .utf8))
        wait(for: [changed], timeout: 0.1)
        XCTAssertTrue(settings.surfacePolicy.allowsAnyTypedSave)
        XCTAssertTrue(settings.surfacePolicy.isToolOn("codex"))
    }
}

// MARK: - Command lines & editors

final class CommandLineClassifierTests: XCTestCase {
    private let catalog = ToolCatalog.shared

    private func job(_ commands: [[String]]) -> [CommandLineClassifier.Process] {
        commands.map { CommandLineClassifier.Process(executable: $0[0], argv: $0) }
    }

    func testLocalToolInForeground() {
        let result = CommandLineClassifier.classify(job([["/bin/zsh"], ["/Users/x/.local/bin/claude", "--resume"]]), catalog: catalog)
        XCTAssertEqual(result.toolID, "claude-code")
        XCTAssertNil(result.remoteHost)
        XCTAssertFalse(result.isShell)
    }

    func testShellOnly() {
        let result = CommandLineClassifier.classify(job([["-zsh"]]), catalog: catalog)
        XCTAssertTrue(result.isShell)
        XCTAssertNil(result.toolID)
    }

    func testSSHVariants() {
        func remote(_ argv: [String]) -> CommandLineClassifier.Result {
            CommandLineClassifier.classify(job([argv]), catalog: catalog)
        }
        XCTAssertEqual(remote(["ssh", "build-box"]).remoteHost, "build-box")
        XCTAssertNil(remote(["ssh", "build-box"]).toolID)
        XCTAssertEqual(remote(["ssh", "-p", "2222", "me@10.0.0.5"]).remoteHost, "10.0.0.5")
        XCTAssertEqual(remote(["ssh", "-tt", "-J", "jump", "box", "claude"]).remoteHost, "box")
        XCTAssertEqual(remote(["ssh", "-tt", "-J", "jump", "box", "claude"]).toolID, "claude-code")
        XCTAssertEqual(remote(["ssh", "-i~/.ssh/k", "box", "--", "codex", "exec", "hi"]).toolID, "codex")
        XCTAssertEqual(remote(["ssh", "-o", "User=me", "box"]).remoteHost, "box")
        XCTAssertEqual(remote(["mosh", "--ssh=ssh -p 22", "dev", "--", "gemini"]).remoteHost, "dev")
        XCTAssertEqual(remote(["kitten", "ssh", "gpu-box"]).remoteHost, "gpu-box")
        XCTAssertEqual(remote(["docker", "exec", "-it", "sandbox", "claude"]).remoteHost, "container sandbox")
        XCTAssertEqual(remote(["docker", "exec", "-it", "sandbox", "claude"]).toolID, "claude-code")
        XCTAssertEqual(remote(["kubectl", "exec", "-it", "agent-pod", "--", "codex"]).toolID, "codex")
        XCTAssertEqual(remote(["ssh", "ssh://me@host.example:2200"]).remoteHost, "host.example")
    }

    func testTmuxClientIsLookedThrough() {
        let result = CommandLineClassifier.classify(job([["/opt/homebrew/bin/tmux", "-L", "work", "attach"]]), catalog: catalog)
        XCTAssertEqual(result.multiplexer, .tmux(executable: "/opt/homebrew/bin/tmux", socketArgs: ["-L", "work"]))
    }

    func testEditorFocus() {
        XCTAssertEqual(CommandLineClassifier.editorSubSurface(classes: ["xterm-helper-textarea", "terminal-wrapper"], descriptions: []), .terminal)
        XCTAssertEqual(CommandLineClassifier.editorSubSurface(classes: ["monaco-editor", "interactive-input-part", "interactive-session"], descriptions: []), .chatPanel)
        XCTAssertEqual(CommandLineClassifier.editorSubSurface(classes: ["native-edit-context", "monaco-editor", "editor-instance"], descriptions: []), .codeEditor)
        XCTAssertEqual(CommandLineClassifier.editorSubSurface(classes: [], descriptions: ["Terminal 1, zsh"]), .terminal)
        XCTAssertNil(CommandLineClassifier.editorSubSurface(classes: ["sidebar"], descriptions: ["Explorer"]))
    }

    func testInlinePromptAtAShell() {
        XCTAssertEqual(TypedPromptCapture.inlinePrompt(fromCommandLine: #"claude "fix the flaky test""#, catalog: catalog)?.prompt, "fix the flaky test")
        XCTAssertEqual(TypedPromptCapture.inlinePrompt(fromCommandLine: "codex exec -m o4 'add docs please'", catalog: catalog)?.toolID, "codex")
        XCTAssertEqual(TypedPromptCapture.inlinePrompt(fromCommandLine: "codex exec -m o4 'add docs please'", catalog: catalog)?.prompt, "add docs please")
        XCTAssertNil(TypedPromptCapture.inlinePrompt(fromCommandLine: "claude --resume", catalog: catalog))
        XCTAssertNil(TypedPromptCapture.inlinePrompt(fromCommandLine: "git commit -m 'claude fix'", catalog: catalog))
    }

    func testShellWords() {
        XCTAssertEqual(TypedPromptCapture.shellWords(#"a "b c" 'd e' f\ g"#), ["a", "b c", "d e", "f g"])
    }
}

// MARK: - Connector parsers

final class ConnectorParserTests: XCTestCase {
    private let catalog = ToolCatalog.shared

    private func record(_ tool: String, _ payload: String, extra: String = "") -> Data {
        Data(#"{"v":1,"tool":"\#(tool)","machine":"box","ts":1790000000,"payload":\#(payload)\#(extra)}"#.utf8)
    }

    func testClaudeHookRecord() throws {
        let data = record("claude-code", #"{"session_id":"s1","cwd":"/repo","prompt":"refactor the parser","source":"user","hook_event_name":"UserPromptSubmit"}"#)
        let prompt = try XCTUnwrap(ConnectorParsers.parseSpoolRecord(data, id: "1-2-3", remoteHost: "gpu", catalog: catalog))
        XCTAssertEqual(prompt.text, "refactor the parser")
        XCTAssertEqual(prompt.source, .hook)
        XCTAssertEqual(prompt.context.toolID, "claude-code")
        XCTAssertEqual(prompt.context.remoteHost, "gpu")
        XCTAssertEqual(prompt.context.toolMachine, "box")
        XCTAssertEqual(prompt.context.workingDirectory, "/repo")
        XCTAssertEqual(prompt.sessionID, "s1")
        XCTAssertEqual(prompt.dedupeKey, "spool:1-2-3")
        XCTAssertEqual(prompt.timestamp, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testNonHumanClaudeTurnsAreDropped() {
        XCTAssertNil(ConnectorParsers.parseSpoolRecord(record("claude-code", #"{"prompt":"scheduled","source":"schedule_wakeup"}"#), id: "a", remoteHost: nil, catalog: catalog))
        XCTAssertNil(ConnectorParsers.parseSpoolRecord(record("claude-code", #"{"prompt":"from a script","source":"sdk"}"#), id: "a", remoteHost: nil, catalog: catalog))
        XCTAssertNil(ConnectorParsers.parseSpoolRecord(record("claude-code", #"{"prompt":"sub","agent_id":"x"}"#), id: "a", remoteHost: nil, catalog: catalog))
        XCTAssertNil(ConnectorParsers.parseSpoolRecord(record("claude-code", #"{"prompt":"/clear"}"#), id: "a", remoteHost: nil, catalog: catalog))
        XCTAssertNil(ConnectorParsers.parseSpoolRecord(record("nope", #"{"prompt":"x y"}"#), id: "a", remoteHost: nil, catalog: catalog))
        XCTAssertNil(ConnectorParsers.parseSpoolRecord(Data("not json".utf8), id: "a", remoteHost: nil, catalog: catalog))
    }

    func testScriptedAgentRunsAreDroppedButPeopleAreKept() {
        func rec(_ tool: String, tty: String, payload: String) -> Data {
            Data(#"{"v":1,"tool":"\#(tool)","machine":"m","ts":1,"tty":"\#(tty)","payload":\#(payload)}"#.utf8)
        }
        // `claude -p` from a script / another agent: no terminal, no `source`.
        XCTAssertNil(ConnectorParsers.parseSpoolRecord(rec("claude-code", tty: "none", payload: #"{"prompt":"summarise the diff"}"#), id: "a", remoteHost: nil, catalog: catalog))
        XCTAssertNil(ConnectorParsers.parseSpoolRecord(rec("codex", tty: "none", payload: #"{"prompt":"summarise the diff"}"#), id: "a", remoteHost: nil, catalog: catalog))
        // A person at a terminal, or a tool that says a user typed it.
        XCTAssertNotNil(ConnectorParsers.parseSpoolRecord(rec("claude-code", tty: "ttys001", payload: #"{"prompt":"summarise the diff"}"#), id: "a", remoteHost: nil, catalog: catalog))
        XCTAssertNotNil(ConnectorParsers.parseSpoolRecord(rec("claude-code", tty: "none", payload: #"{"prompt":"summarise the diff","source":"user"}"#), id: "a", remoteHost: nil, catalog: catalog))
        // No `ps` on the server: unknown, so kept.
        XCTAssertNotNil(ConnectorParsers.parseSpoolRecord(rec("codex", tty: "unknown", payload: #"{"prompt":"summarise the diff"}"#), id: "a", remoteHost: nil, catalog: catalog))
        // Editor agents are GUI apps: never a terminal, still people.
        XCTAssertNotNil(ConnectorParsers.parseSpoolRecord(rec("cursor", tty: "none", payload: #"{"prompt":"explain this function"}"#), id: "a", remoteHost: nil, catalog: catalog))
    }

    func testCodexCursorCopilotRecords() {
        XCTAssertEqual(ConnectorParsers.parseSpoolRecord(record("codex", #"{"session_id":"t","prompt":"add a test","turn_id":"1"}"#), id: "a", remoteHost: nil, catalog: catalog)?.text, "add a test")
        XCTAssertEqual(ConnectorParsers.parseSpoolRecord(record("cursor", #"{"conversation_id":"c","prompt":"explain this"}"#), id: "a", remoteHost: nil, catalog: catalog)?.sessionID, "c")
        XCTAssertEqual(ConnectorParsers.parseSpoolRecord(record("copilot-cli", #"{"sessionId":"s","cwd":"/w","prompt":"list files"}"#), id: "a", remoteHost: nil, catalog: catalog)?.context.workingDirectory, "/w")
    }

    func testAntigravityRecordTakesTheTranscriptStep() throws {
        let data = record("antigravity-cli", #"{"conversationId":"conv9","transcriptPath":"/t"}"#,
                          extra: #","last_user_input":{"step_index":4,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<USER_REQUEST>ship it now</USER_REQUEST><ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>"}"#)
        let prompt = try XCTUnwrap(ConnectorParsers.parseSpoolRecord(data, id: "z", remoteHost: nil, catalog: catalog))
        XCTAssertEqual(prompt.text, "ship it now")
        XCTAssertEqual(prompt.dedupeKey, "agy:conv9:4")
    }

    func testClaudeHistoryRestoresPastedText() throws {
        let line = Data(#"{"display":"review this [Pasted text #1 +3 lines] carefully","pastedContents":{"1":{"id":1,"type":"text","content":"func a() {}"}},"timestamp":1790000000123,"project":"/p","sessionId":"s"}"#.utf8)
        let prompt = try XCTUnwrap(ConnectorParsers.parseClaudeHistoryLine(line, toolID: "claude-code"))
        XCTAssertEqual(prompt.text, "review this func a() {} carefully")
        XCTAssertEqual(prompt.source, .transcript)
        XCTAssertEqual(prompt.context.workingDirectory, "/p")
    }

    func testCodexHistory() {
        let line = Data(#"{"session_id":"s","ts":1790000000,"text":"write the migration"}"#.utf8)
        XCTAssertEqual(ConnectorParsers.parseCodexHistoryLine(line, toolID: "codex")?.text, "write the migration")
    }

    func testCleanPrompt() {
        XCTAssertNil(ConnectorParsers.cleanPrompt("   "))
        XCTAssertNil(ConnectorParsers.cleanPrompt("/model opus"))
        XCTAssertEqual(ConnectorParsers.cleanPrompt("/Users/me/file.txt is broken, fix it"), "/Users/me/file.txt is broken, fix it")
        XCTAssertEqual(ConnectorParsers.cleanPrompt(" yes "), "yes")
    }
}

// MARK: - Config installers

final class ConnectorInstallerTests: XCTestCase {
    private let command = "/Users/me/.dictator/bin/dictator-capture hook claude-code"

    func testNestedHookMergePreservesEverythingElse() throws {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": "other-tool"]]]],
                      "Stop": [["hooks": [["type": "command", "command": "notify"]]]]],
        ]
        var updated = try ConnectorInstaller.addHook(format: "nested-hooks", root: existing, event: "UserPromptSubmit", command: command)
        updated = try ConnectorInstaller.addHook(format: "nested-hooks", root: updated, event: "UserPromptSubmit", command: command)
        XCTAssertEqual(updated["model"] as? String, "opus")
        let hooks = updated["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["Stop"])
        let groups = hooks["UserPromptSubmit"] as! [[String: Any]]
        XCTAssertEqual(groups.count, 2, "installing twice keeps one Dictator entry")
        let rendered = try ConnectorInstaller.render(updated)
        XCTAssertEqual(rendered.components(separatedBy: "dictator-capture").count - 1, 1)

        let removed = ConnectorInstaller.removeHook(format: "nested-hooks", root: updated, event: "UserPromptSubmit")
        let remainingGroups = (removed["hooks"] as! [String: Any])["UserPromptSubmit"] as! [[String: Any]]
        XCTAssertEqual(remainingGroups.count, 1)
        XCTAssertFalse(try ConnectorInstaller.render(removed).contains("dictator-capture"))
    }

    func testRemovingTheOnlyHookLeavesNoEmptyHooksKey() throws {
        let added = try ConnectorInstaller.addHook(format: "nested-hooks", root: ["theme": "dark"], event: "UserPromptSubmit", command: command)
        let removed = ConnectorInstaller.removeHook(format: "nested-hooks", root: added, event: "UserPromptSubmit")
        XCTAssertNil(removed["hooks"])
        XCTAssertEqual(removed["theme"] as? String, "dark")
    }

    func testGeminiCursorAgyShapes() throws {
        let gemini = try ConnectorInstaller.addHook(format: "gemini-hooks", root: [:], event: "BeforeAgent", command: command)
        let geminiHandler = (((gemini["hooks"] as! [String: Any])["BeforeAgent"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(geminiHandler["timeout"] as? Int, 5_000)
        XCTAssertEqual(geminiHandler["name"] as? String, "dictator-capture")

        let cursor = try ConnectorInstaller.addHook(format: "cursor-hooks", root: [:], event: "beforeSubmitPrompt", command: command)
        XCTAssertEqual(cursor["version"] as? Int, 1)
        XCTAssertEqual(((cursor["hooks"] as! [String: Any])["beforeSubmitPrompt"] as! [[String: Any]])[0]["command"] as? String, command)

        let agy = try ConnectorInstaller.addHook(format: "agy-hooks", root: ["mine": ["Stop": []]], event: "PreInvocation", command: command)
        XCTAssertNotNil(agy["mine"])
        XCTAssertNotNil((agy["dictator-capture"] as? [String: Any])?["PreInvocation"])
        XCTAssertNil(ConnectorInstaller.removeHook(format: "agy-hooks", root: agy, event: "PreInvocation")["dictator-capture"])
    }

    func testCodexFeatureFlag() throws {
        XCTAssertEqual(try ConnectorInstaller.enableCodexHooksFeature(in: ""), "[features]\nhooks = true\n")
        XCTAssertEqual(try ConnectorInstaller.enableCodexHooksFeature(in: "model = \"o4\"\n"), "model = \"o4\"\n\n[features]\nhooks = true\n")
        XCTAssertEqual(try ConnectorInstaller.enableCodexHooksFeature(in: "[features]\nweb = true\n[tui]\nx=1\n"), "[features]\nhooks = true\nweb = true\n[tui]\nx=1\n")
        XCTAssertEqual(try ConnectorInstaller.enableCodexHooksFeature(in: "[features]\nhooks = false\n"), "[features]\nhooks = true\n")
        XCTAssertEqual(try ConnectorInstaller.enableCodexHooksFeature(in: "features.hooks = false\n"), "features.hooks = true\n")
        XCTAssertEqual(try ConnectorInstaller.enableCodexHooksFeature(in: "[ features ] # flags\nweb = true\n"), "[ features ] # flags\nhooks = true\nweb = true\n")
        // `hooks` under another table is not the feature flag.
        XCTAssertEqual(try ConnectorInstaller.enableCodexHooksFeature(in: "[tui]\nhooks = 1\n"), "[tui]\nhooks = 1\n\n[features]\nhooks = true\n")
        XCTAssertThrowsError(try ConnectorInstaller.enableCodexHooksFeature(in: "features = { web = true }\n"))
    }

    func testCommandQuoting() {
        XCTAssertEqual(ConnectorInstaller.hookCommand(home: "/Users/me", toolID: "cursor", reply: #"{"continue":true}"#),
                       #"/Users/me/.dictator/bin/dictator-capture hook cursor '{"continue":true}'"#)
        XCTAssertEqual(ConnectorInstaller.hookCommand(home: "/Users/my name", toolID: "codex", reply: nil),
                       "'/Users/my name/.dictator/bin/dictator-capture' hook codex")
    }

    func testOpenCodePluginRendering() {
        let rendered = ConnectorInstaller.renderOpenCodePlugin(template: "const SHIM = __DICTATOR_CAPTURE_PATH__;", shimPath: "/Users/a \"b\"/x")
        XCTAssertEqual(rendered, #"const SHIM = "/Users/a \"b\"/x";"#)
    }

    func testUnreadableConfigIsLeftAlone() {
        XCTAssertThrowsError(try ConnectorInstaller.parseObject("{ // comment\n}", path: ".gemini/settings.json"))
        XCTAssertEqual(try ConnectorInstaller.parseObject(nil, path: "x").count, 0)
    }

    func testInstallAndUninstallOnADisk() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let access = LocalConfigFileAccess(homeDirectory: home)
        try await access.write(".claude/settings.json", contents: #"{"model":"opus"}"#, backup: false, executable: false)
        let claude = try XCTUnwrap(ToolCatalog.shared.tool(id: "claude-code"))
        let codex = try XCTUnwrap(ToolCatalog.shared.tool(id: "codex"))

        try await ConnectorInstaller.install(claude, on: access)
        try await ConnectorInstaller.install(codex, on: access)
        let isClaudeInstalled = await ConnectorInstaller.isInstalled(claude, on: access)
        let isCodexInstalled = await ConnectorInstaller.isInstalled(codex, on: access)
        XCTAssertTrue(isClaudeInstalled)
        XCTAssertTrue(isCodexInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.claude/settings.json.dictator-backup"))
        let settings = try String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8)
        XCTAssertTrue(settings.contains("\"model\" : \"opus\""))
        XCTAssertTrue(try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8).contains("hooks = true"))

        try await ConnectorInstaller.uninstall(claude, on: access)
        let stillInstalled = await ConnectorInstaller.isInstalled(claude, on: access)
        XCTAssertFalse(stillInstalled)
        XCTAssertTrue(try String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8).contains("opus"))
    }

    func testDedicatedHookCollisionsAreLeftUnchanged() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-hooks-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let access = LocalConfigFileAccess(homeDirectory: home)
        for id in ["opencode", "copilot-cli"] {
            let tool = try XCTUnwrap(ToolCatalog.shared.tool(id: id))
            let path = try XCTUnwrap(tool.connector?.hookConfig)
            let original = "My own hook mentioning dictator-capture, not owned by Dictator.\n"
            try await access.write(path, contents: original, backup: false, executable: false)
            do {
                try await ConnectorInstaller.install(tool, on: access)
                XCTFail("An unrelated hook must not be replaced")
            } catch {
                XCTAssertEqual(error as? ConnectorError, .conflictingConfig(path: path))
            }
            do {
                try await ConnectorInstaller.uninstall(tool, on: access)
                XCTFail("An unrelated hook must not be removed")
            } catch {
                XCTAssertEqual(error as? ConnectorError, .conflictingConfig(path: path))
            }
            let remaining = try await access.read(path)
            let backup = try await access.read(path + ".dictator-backup")
            let installed = await ConnectorInstaller.isInstalled(tool, on: access)
            XCTAssertEqual(remaining, original)
            XCTAssertNil(backup)
            XCTAssertFalse(installed, "A mention of the marker does not prove file ownership")
        }
    }

    func testDedicatedHooksRemoveOnlyTheirOwnNewFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-hooks-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let access = LocalConfigFileAccess(homeDirectory: home)
        for id in ["opencode", "copilot-cli"] {
            let tool = try XCTUnwrap(ToolCatalog.shared.tool(id: id))
            let path = try XCTUnwrap(tool.connector?.hookConfig)
            try await ConnectorInstaller.install(tool, on: access)
            let firstRead = try await access.read(path)
            let first = try XCTUnwrap(firstRead)
            try await ConnectorInstaller.install(tool, on: access)
            let installed = await ConnectorInstaller.isInstalled(tool, on: access)
            let repeated = try await access.read(path)
            XCTAssertTrue(installed)
            XCTAssertEqual(repeated, first)
            try await ConnectorInstaller.uninstall(tool, on: access)
            let removed = try await access.read(path)
            XCTAssertNil(removed)
        }
    }

    func testDedicatedHookRemovalRestoresOriginalBackupWithoutReplacingIt() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-hooks-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let access = LocalConfigFileAccess(homeDirectory: home)
        for id in ["opencode", "copilot-cli"] {
            let tool = try XCTUnwrap(ToolCatalog.shared.tool(id: id))
            let path = try XCTUnwrap(tool.connector?.hookConfig)
            try await ConnectorInstaller.install(tool, on: access)
            let ownedRead = try await access.read(path)
            let owned = try XCTUnwrap(ownedRead)
            // A prior setup left its replacement and the user's original backup.
            let original = "Original user hook for \(id)\n"
            try await access.write(path, contents: original, backup: false, executable: false)
            try await access.write(path, contents: owned, backup: true, executable: false)
            try await ConnectorInstaller.install(tool, on: access)
            let backup = try await access.read(path + ".dictator-backup")
            XCTAssertEqual(backup, original, "Repeated setup must not replace the original backup")
            try await ConnectorInstaller.uninstall(tool, on: access)
            let restored = try await access.read(path)
            XCTAssertEqual(restored, original)
        }
    }

    func testEditedDedicatedHookIsNotOverwrittenOrDeleted() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-hooks-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let access = LocalConfigFileAccess(homeDirectory: home)
        for id in ["opencode", "copilot-cli"] {
            let tool = try XCTUnwrap(ToolCatalog.shared.tool(id: id))
            let path = try XCTUnwrap(tool.connector?.hookConfig)
            try await ConnectorInstaller.install(tool, on: access)
            let ownedRead = try await access.read(path)
            let owned = try XCTUnwrap(ownedRead)
            let edited = owned + "\n"
            try await access.write(path, contents: edited, backup: false, executable: false)
            do {
                try await ConnectorInstaller.uninstall(tool, on: access)
                XCTFail("A changed hook must be left for the user to review")
            } catch {
                XCTAssertEqual(error as? ConnectorError, .conflictingConfig(path: path))
            }
            let remaining = try await access.read(path)
            XCTAssertEqual(remaining, edited)
        }
    }
}

// MARK: - Shim → spool → prompt, end to end

@MainActor
final class ShimSpoolTests: XCTestCase {
    func testFailedSaveKeepsTheRecordForRetry() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let spool = home.appendingPathComponent(".dictator/spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        try Data(#"{"v":1,"tool":"codex","machine":"m","ts":1,"tty":"ttys1","payload":{"prompt":"keep me safe"}}"#.utf8)
            .write(to: spool.appendingPathComponent("1-1-1.json"))
        var attempts = 0
        let failing = LocalSpoolWatcher(home: home.path) { _ in attempts += 1; return false }
        await failing.scan()
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.appendingPathComponent("1-1-1.json").path))
        let working = LocalSpoolWatcher(home: home.path) { _ in attempts += 1; return true }
        await working.scan()
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.appendingPathComponent("1-1-1.json").path))
        XCTAssertEqual(attempts, 2)
    }

    func testShimRecordIsCollectedAndDeleted() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-shim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let script = try ConnectorInstaller.bundledShim()
        XCTAssertEqual(ConnectorInstaller.shimVersion(in: script), "1")
        let shim = home.appendingPathComponent("dictator-capture")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try script.write(to: shim, atomically: true, encoding: .utf8)

        func run(_ args: [String], stdin: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [shim.path] + args
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        let stdout = try run(["hook", "claude-code"], stdin: #"{"session_id":"s","cwd":"/r","prompt":"write \"tests\" for\nthe parser","source":"user"}"#)
        XCTAssertEqual(stdout, "", "a Claude Code hook must print nothing")
        XCTAssertEqual(try run(["hook", "cursor", #"{"continue":true}"#], stdin: #"{"prompt":"hi there"}"#), "{\"continue\":true}\n")

        // `drain` output is what remote collection parses.
        let drained = try run(["drain"], stdin: "")
        XCTAssertEqual(drained.split(separator: "\n").count, 2)

        var collected: [CapturedPrompt] = []
        let watcher = LocalSpoolWatcher(home: home.path) { collected.append($0); return true }
        // The watcher looks in <home>/.dictator/spool — the shim wrote there.
        await watcher.scan()
        XCTAssertEqual(Set(collected.map(\.text)), ["write \"tests\" for\nthe parser", "hi there"])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".dictator/spool").path)
        XCTAssertTrue(remaining.filter { $0.hasSuffix(".json") }.isEmpty)
    }
}

// MARK: - Recorder, scrubbing, similarity

final class SecretScrubberTests: XCTestCase {
    func testCommonSecretsAreRedacted() {
        let text = """
        use sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123 and ghp_abcdefghijklmnopqrstuvwxyz0123456789
        AKIAABCDEFGHIJKLMNOP password=hunter2hunter https://me:s3cretpass@db.example.com/x
        -----BEGIN OPENSSH PRIVATE KEY-----
        abc
        -----END OPENSSH PRIVATE KEY-----
        """
        let scrubbed = SecretScrubber.scrub(text)
        for secret in ["sk-ant-api03", "ghp_abc", "AKIAABCD", "hunter2hunter", "s3cretpass", "BEGIN OPENSSH"] {
            XCTAssertFalse(scrubbed.contains(secret), "\(secret) leaked: \(scrubbed)")
        }
        XCTAssertTrue(scrubbed.contains("password=[redacted]"))
        XCTAssertTrue(scrubbed.contains("db.example.com"))
    }

    func testOrdinaryTextIsUntouched() {
        let text = "Refactor the skill-loader so tasks use sk-style names; keep the API keys section as is."
        XCTAssertEqual(SecretScrubber.scrub(text), text)
    }
}

@MainActor
final class PromptRecorderTests: XCTestCase {
    private var savedJSON = ""
    private var savedPersist = true
    private var savedPause: Date?
    private var keysURL: URL!

    override func setUp() async throws {
        let settings = AppSettings.shared
        savedJSON = settings.cachedSurfacePolicyJSON
        savedPersist = settings.persistHistory
        savedPause = settings.promptCapturePausedUntil
        settings.persistHistory = true
        settings.promptCapturePausedUntil = nil
        settings.updateCachedSurfacePolicy(SurfacePolicy(
            defaultTyped: "ignore", defaultVoice: "save", rules: [], version: 2,
            tools: ["claude-code": ToolSwitch(typed: true), "codex": ToolSwitch(typed: true)]
        ))
        keysURL = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        let settings = AppSettings.shared
        settings.cachedSurfacePolicyJSON = savedJSON
        settings.persistHistory = savedPersist
        settings.promptCapturePausedUntil = savedPause
        try? FileManager.default.removeItem(at: keysURL)
    }

    private func makeRecorder(_ saved: @escaping (CapturedPrompt) -> Void) -> (PromptRecorder, NoticedSurfaceStore) {
        let notices = NoticedSurfaceStore(url: nil)
        let recorder = PromptRecorder(notices: notices, keysURL: keysURL) { saved($0) }
        recorder.holdInterval = .milliseconds(150)
        return (recorder, notices)
    }

    private func prompt(_ text: String, _ source: CaptureSource, tool: String? = "claude-code", key: String? = nil) -> CapturedPrompt {
        CapturedPrompt(text: text, source: source, context: CaptureContext(toolID: tool), timestamp: Date(), sessionID: nil, dedupeKey: key)
    }

    func testExactSourceSupersedesHeldKeystrokes() async throws {
        var saved: [CapturedPrompt] = []
        let (recorder, _) = makeRecorder { saved.append($0) }
        recorder.submit(prompt("fix the flaky tset in parser", .keystrokes))
        recorder.submit(prompt("fix the flaky test in parser", .hook, key: "k1"))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(saved.map(\.source), [.hook])
        XCTAssertEqual(saved.first?.text, "fix the flaky test in parser")
    }

    func testLateKeystrokeDuplicateIsDropped() async throws {
        var saved: [CapturedPrompt] = []
        let (recorder, _) = makeRecorder { saved.append($0) }
        recorder.submit(prompt("add docs to the readme", .hook, key: "k2"))
        try await Task.sleep(for: .milliseconds(50))
        recorder.submit(prompt("add docs to the readme", .keystrokes))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(saved.count, 1)
    }

    func testRepeatedExactPromptsAreBothKept() async throws {
        var saved: [CapturedPrompt] = []
        let (recorder, _) = makeRecorder { saved.append($0) }
        await recorder.ingest(prompt("continue", .hook, key: "a"))
        await recorder.ingest(prompt("continue", .hook, key: "b"))
        await recorder.ingest(prompt("fix the login bug", .hook, key: "c"))
        await recorder.ingest(prompt("fix the login bug in Safari", .hook, key: "d"))
        XCTAssertEqual(saved.count, 4)
    }

    func testSameRecordIsNeverStoredTwice() async throws {
        var saved: [CapturedPrompt] = []
        let (recorder, _) = makeRecorder { saved.append($0) }
        recorder.submit(prompt("one prompt only", .hook, key: "spool:abc"))
        try await Task.sleep(for: .milliseconds(50))
        recorder.submit(prompt("one prompt only", .hook, key: "spool:abc"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(recorder.hasStored(key: "spool:abc"))
    }

    func testToolNotSetUpIsNoticedNotSaved() async throws {
        var saved: [CapturedPrompt] = []
        let (recorder, notices) = makeRecorder { saved.append($0) }
        recorder.submit(prompt("hello gemini friend", .hook, tool: "gemini-cli", key: "g"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(notices.active.first?.kind, .toolOff)
    }

    func testPauseAndSecretsAndShortKeystrokes() async throws {
        var saved: [CapturedPrompt] = []
        let (recorder, _) = makeRecorder { saved.append($0) }
        await recorder.ingest(prompt("ok", .keystrokes))
        AppSettings.shared.promptCapturePausedUntil = Date().addingTimeInterval(60)
        await recorder.ingest(prompt("while paused prompt", .hook, key: "p"))
        AppSettings.shared.promptCapturePausedUntil = nil
        await recorder.ingest(prompt("use key sk-proj-abcdefghijklmnopqrstuvwxyz123456 here", .hook, key: "s"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.text, "use key [redacted] here")
    }

    func testSimilarity() {
        XCTAssertTrue(PromptRecorder.isSimilar("Fix the bug!", "fix the bug"))
        XCTAssertTrue(PromptRecorder.isSimilar("please fix the login bug in auth.swift", "fix the login bug in auth.swift"))
        XCTAssertFalse(PromptRecorder.isSimilar("fix the bug", "write the docs"))
    }
}

// MARK: - Remote helpers

final class RemoteCaptureHelperTests: XCTestCase {
    func testProbeParsing() {
        let probe = RemoteCaptureService.parseProbe("home=/home/me\nsystem=Linux x86_64\nshim=1\ntool=claude-code\ntool=codex\n")
        XCTAssertEqual(probe.home, "/home/me")
        XCTAssertEqual(probe.system, "Linux x86_64")
        XCTAssertEqual(probe.shimVersion, "1")
        XCTAssertEqual(probe.detectedToolIDs, ["claude-code", "codex"])
    }

    func testSSHConfigAliases() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        try "Host build gpu-box\n  HostName 10.0.0.2\nHost *.internal !bad\nInclude conf.d/*\n".write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host  lab\n".write(to: ssh.appendingPathComponent("conf.d/extra"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RemoteCaptureService.sshConfigAliases(home: home.path), ["build", "gpu-box", "lab"])
    }

    func testSSHErrorsAreExplained() {
        XCTAssertEqual(SSHRunner.classify("me@box: Permission denied (publickey)."), .authentication)
        XCTAssertEqual(SSHRunner.classify("Host key verification failed."), .hostKey)
        XCTAssertEqual(SSHRunner.classify("ssh: Could not resolve hostname nope: nodename nor servname provided"), .unknownHost)
        XCTAssertFalse(SSHRunner.isValidHost("-oProxyCommand=x"))
        XCTAssertFalse(SSHRunner.isValidHost("a b"))
        XCTAssertTrue(SSHRunner.isValidHost("me@10.0.0.5"))
        XCTAssertEqual(SSHRunner.quote("it's"), #"'it'\''s'"#)
    }
}

// MARK: - Process table

final class ProcessTableTests: XCTestCase {
    func testSnapshotFindsThisProcessAndItsArguments() throws {
        let table = ProcessTable.snapshot()
        let me = try XCTUnwrap(table.entry(getpid()))
        XCTAssertEqual(me.ppid, getppid())
        let args = try XCTUnwrap(ProcessTable.arguments(of: getpid()))
        XCTAssertFalse(args.executable.isEmpty)
        XCTAssertFalse(args.argv.isEmpty)
    }

    func testCaptureContextLabel() {
        let context = CaptureContext(toolID: "codex", appBundleID: "com.googlecode.iterm2", appName: "iTerm", subSurface: .terminal, remoteHost: "gpu")
        XCTAssertEqual(context.label(), "iTerm → ssh gpu → Codex")
        XCTAssertEqual(CaptureContext(toolID: "claude-code", toolMachine: "box").label(), "box → Claude Code")
    }
}

// MARK: - First-run connector setup

@MainActor
final class ConnectorSetupResultTests: XCTestCase {
    /// One failing then one succeeding connector: the first failure stays
    /// in the results; the later success doesn't hide it.
    func testEarlierFailureSurvivesALaterSuccess() async {
        let failing = ToolDefinition(id: "a-tool", name: "A Tool", category: .agent)
        let working = ToolDefinition(id: "b-tool", name: "B Tool", category: .agent)
        var attempted: [String] = []

        let results = await PromptCaptureCenter.runConnectorSetup([(failing, .hook), (working, .transcript)]) { tool, _ in
            attempted.append(tool.id)
            return tool.id == "a-tool" ? "Couldn’t write its settings file." : nil
        }

        XCTAssertEqual(attempted, ["a-tool", "b-tool"])
        XCTAssertEqual(results.map(\.toolID), ["a-tool", "b-tool"])
        XCTAssertEqual(results[0].error, "Couldn’t write its settings file.")
        XCTAssertFalse(results[0].succeeded)
        XCTAssertTrue(results[1].succeeded)
        XCTAssertEqual(results[1].method, .transcript)
        XCTAssertFalse(results.allSatisfy(\.succeeded), "setup must not read as fully successful")
    }

    func testAllSucceedingIsReportedAsComplete() async {
        let tool = ToolDefinition(id: "a-tool", name: "A Tool", category: .agent)
        let results = await PromptCaptureCenter.runConnectorSetup([(tool, .hook)]) { _, _ in nil }
        XCTAssertTrue(results.allSatisfy(\.succeeded))
    }
}

// MARK: - Local setup is separate from mirrored permission

@MainActor
final class LocalPromptSetupTests: XCTestCase {
    private var home: URL!
    private var access: LocalConfigFileAccess!
    private var center: PromptCaptureCenter!
    private var savedJSON = ""
    private var savedMethods: [String: String] = [:]
    private var savedHistory = true
    private var savedPause: Date?
    private var settings: AppSettings { .shared }
    private var claude: ToolDefinition { ToolCatalog.shared.tool(id: "claude-code")! }
    private var codex: ToolDefinition { ToolCatalog.shared.tool(id: "codex")! }

    override func setUp() async throws {
        savedJSON = settings.cachedSurfacePolicyJSON
        savedMethods = settings.captureMethods
        savedHistory = settings.persistHistory
        savedPause = settings.promptCapturePausedUntil
        settings.captureMethods = [:]
        settings.persistHistory = true
        settings.promptCapturePausedUntil = nil
        settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "ignore", defaultVoice: "save", rules: [],
            version: 2, tools: ["claude-code": ToolSwitch(typed: true), "codex": ToolSwitch(typed: true)]))
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-setup-\(UUID().uuidString)")
        access = LocalConfigFileAccess(homeDirectory: home.path)
        let syntheticAccess = access!
        center = PromptCaptureCenter(access: syntheticAccess, localPresence: { tool in
            await ConnectorInstaller.isToolPresent(tool, on: syntheticAccess)
        }, initializeCollectors: false)
    }

    override func tearDown() async throws {
        center.stopStatusMonitoring()
        settings.cachedSurfacePolicyJSON = savedJSON
        settings.captureMethods = savedMethods
        settings.persistHistory = savedHistory
        settings.promptCapturePausedUntil = savedPause
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ path: String, _ contents: String) async throws {
        try await access.write(path, contents: contents, backup: false, executable: false)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Status did not refresh", file: file, line: line)
    }

    func testChosenHookMissingNeedsSetupWithoutWritingAnything() async throws {
        let original = #"{"model":"synthetic","hooks":{"SessionStart":[]}}"#
        try await write(".claude/settings.json", original)
        settings.captureMethods[claude.id] = "hook"
        await center.refreshStatuses()
        XCTAssertTrue(center.needsSetup(claude))
        XCTAssertEqual(center.toolsNeedingSetup.map(\.id), [claude.id])
        XCTAssertEqual(center.localState(for: claude), "Needs setup")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(ConnectorInstaller.shimRelativePath).path))
    }

    func testRecommendedHookMissingNeedsSetupButAbsentAndOffToolsDoNot() async throws {
        await center.refreshStatuses()
        XCTAssertTrue(center.toolsNeedingSetup.isEmpty, "Enabled elsewhere is not evidence of local presence")
        try await write(".claude/settings.json", "{}")
        await center.refreshStatuses()
        XCTAssertTrue(center.needsSetup(claude))
        settings.updateSurfacePolicy { $0.setTool(claude.id, typed: false) }
        XCTAssertFalse(center.needsSetup(claude))
        XCTAssertTrue(center.toolsNeedingSetup.isEmpty)
    }

    func testFreshPolicyDoesNotOfferSetupOrTurnTypedHistoryOn() async throws {
        try await write(".claude/settings.json", "{}")
        settings.updateCachedSurfacePolicy(.fallback)
        await center.refreshStatuses()
        XCTAssertFalse(settings.surfacePolicy.allowsAnyTypedSave)
        XCTAssertTrue(center.toolsNeedingSetup.isEmpty)
        let results = await center.setUpAll()
        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(settings.surfacePolicy.allowsAnyTypedSave)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8), "{}")
    }

    func testAlternateMethodsArePreservedByRepair() async throws {
        try await write(".claude/settings.json", "{}")
        try await write(".codex/hooks.json", "{}")
        settings.captureMethods = [claude.id: "transcript", codex.id: "keystrokes"]
        await center.refreshStatuses()
        XCTAssertTrue(center.toolsNeedingSetup.isEmpty)
        let results = await center.setUpAll()
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(settings.captureMethods, [claude.id: "transcript", codex.id: "keystrokes"])
        XCTAssertEqual(center.captureDescription(for: claude), "From the tool’s history file")
        XCTAssertEqual(center.captureDescription(for: codex), "From the keyboard")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8), "{}")
    }

    func testOneClickRepairKeepsBackupsAndClearsSetupWithoutRelaunch() async throws {
        let original = #"{"model":"synthetic"}"#
        try await write(".claude/settings.json", original)
        settings.captureMethods[claude.id] = "hook"
        await center.refreshStatuses()
        let results = await center.setUpAll()
        XCTAssertEqual(results.map(\.toolID), [claude.id])
        XCTAssertTrue(results.allSatisfy(\.succeeded))
        XCTAssertTrue(center.toolsNeedingSetup.isEmpty)
        XCTAssertEqual(center.localState(for: claude), "Set up")
        XCTAssertTrue(center.connectorCovers(claude.id))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/settings.json.dictator-backup"), encoding: .utf8), original)
    }

    func testRepairRetainsEarlierFailureWhenLaterToolSucceeds() async throws {
        try await write(".claude/settings.json", "{invalid synthetic JSON")
        try await write(".codex/hooks.json", "{}")
        await center.refreshStatuses()
        let results = await center.setUpAll()
        XCTAssertEqual(results.map(\.toolID), [claude.id, codex.id])
        XCTAssertFalse(results[0].succeeded)
        XCTAssertTrue(results[1].succeeded)
        XCTAssertEqual(center.setupResults, results)
        XCTAssertTrue(center.lastConnectorError?.contains("Claude Code") == true)
        XCTAssertEqual(center.toolsNeedingSetup.map(\.id), [claude.id])
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8), "{invalid synthetic JSON")
    }

    func testLaunchUpdatesExistingOldShimWhenHookMethodIsUsed() async throws {
        try await write(ConnectorInstaller.shimRelativePath, "#!/bin/sh\nDICTATOR_CAPTURE_VERSION=0\nexit 0\n")
        settings.captureMethods[claude.id] = "hook"
        center.startStatusMonitoring()
        try await eventually { self.center.statuses[self.claude.id] != nil }
        let script = try await access.read(ConnectorInstaller.shimRelativePath)
        XCTAssertEqual(script, try ConnectorInstaller.bundledShim())
    }

    func testLaunchLeavesExistingShimAloneWithoutHookMethod() async throws {
        let original = "#!/bin/sh\nDICTATOR_CAPTURE_VERSION=0\nexit 0\n"
        try await write(ConnectorInstaller.shimRelativePath, original)
        settings.captureMethods[claude.id] = "keystrokes"
        center.startStatusMonitoring()
        try await eventually { self.center.statuses[self.claude.id] != nil }
        let script = try await access.read(ConnectorInstaller.shimRelativePath)
        XCTAssertEqual(script, original)
    }

    func testInstallShimDoesNotWriteWhenVersionsMatch() async throws {
        let original = "#!/bin/sh\nDICTATOR_CAPTURE_VERSION=1\n# Synthetic existing shim\n"
        try await write(ConnectorInstaller.shimRelativePath, original)
        try await ConnectorInstaller.installShim(on: access, script: "#!/bin/sh\nDICTATOR_CAPTURE_VERSION=1\n# Same version\n")
        let script = try await access.read(ConnectorInstaller.shimRelativePath)
        XCTAssertEqual(script, original)
    }

    func testLaunchAndMonitoringLeaveMissingShimMissing() async throws {
        try await ConnectorInstaller.install(claude, on: access)
        settings.captureMethods[claude.id] = "hook"
        center.startStatusMonitoring(pollInterval: .milliseconds(20))
        try await eventually { self.center.statuses[self.claude.id] != nil }
        XCTAssertTrue(center.needsSetup(claude))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(ConnectorInstaller.shimRelativePath).path))
        try await ConnectorInstaller.installShim(on: access, script: "#!/bin/sh\nexit 0\n")
        try await eventually { !self.center.needsSetup(self.claude) }
        try await access.delete(ConnectorInstaller.shimRelativePath)
        try await eventually { self.center.needsSetup(self.claude) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(ConnectorInstaller.shimRelativePath).path))
    }

    func testExternalHookRepairAndRemovalAreObservedWithoutRelaunch() async throws {
        try await write(".claude/settings.json", "{}")
        try await ConnectorInstaller.installShim(on: access, script: "#!/bin/sh\nexit 0\n")
        center.startStatusMonitoring(pollInterval: .milliseconds(20))
        try await eventually { self.center.needsSetup(self.claude) }
        try await ConnectorInstaller.install(claude, on: access)
        try await eventually { !self.center.needsSetup(self.claude) }
        try await ConnectorInstaller.uninstall(claude, on: access)
        try await eventually { self.center.needsSetup(self.claude) }
        let installed = await ConnectorInstaller.isInstalled(claude, on: access)
        XCTAssertFalse(installed)
    }

    func testMirroredPolicyChangeRechecksLocalPresenceWithoutWritingConfig() async throws {
        settings.updateSurfacePolicy { $0.setTool(claude.id, typed: false) }
        center.startStatusMonitoring(pollInterval: .seconds(60))
        try await eventually { self.center.statuses[self.claude.id] != nil }
        XCTAssertFalse(center.statuses[claude.id]!.installed)
        try await write(".claude/settings.json", "{}")
        let mirrored = SurfacePolicy(defaultTyped: "ignore", defaultVoice: "save", rules: [], version: 2,
            tools: [claude.id: ToolSwitch(typed: true)])
        // This is the same JSON assignment used by CoreSettingsMirror.
        settings.cachedSurfacePolicyJSON = String(decoding: try JSONEncoder().encode(mirrored), as: UTF8.self)
        try await eventually { self.center.needsSetup(self.claude) }
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8), "{}")
        XCTAssertNil(settings.captureMethods[claude.id])
    }

    func testSwitchingAwayFromHookRemovesConfigEvenWhenShimWasDeleted() async throws {
        try await ConnectorInstaller.install(claude, on: access)
        settings.captureMethods[claude.id] = "hook"
        await center.refreshStatuses()
        let failure = await center.setMethod(.keystrokes, for: claude)
        XCTAssertNil(failure)
        let installed = await ConnectorInstaller.isInstalled(claude, on: access)
        XCTAssertFalse(installed)
        XCTAssertFalse(center.needsSetup(claude))
    }

    func testAnSSHRunPastItsDeadlineIsATimeoutEvenIfItExitsCleanly() async {
        do {
            _ = try await SSHRunner.launch(executable: "/bin/sh", arguments: ["-c", "trap 'exit 0' TERM; while :; do /bin/sleep 0.05; done"], stdin: "", timeout: 0.3)
            XCTFail("a run cut off at its deadline must not pass as a success")
        } catch {
            XCTAssertEqual(error as? SSHRunner.Failure, .timeout)
        }
    }

    func testScrubberCatchesPrefixedNamesAndQuotedPhrases() {
        for (text, secret) in [("export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI", "wJalrXUtnFEMI"), ("DB_PASSWORD=correcthorse", "correcthorse"),
                               ("JWT_SECRET=abcdefghij", "abcdefghij"), ("refresh_token=abcdefghij", "abcdefghij"),
                               ("OPENAI_API_KEY: abcdefghij", "abcdefghij"), (#"{"password": "my secret hunter2 passphrase"}"#, "hunter2")] {
            XCTAssertFalse(SecretScrubber.scrub(text).contains(secret), text)
        }
        for text in ["the password field is required", "my secret is out", "a passphrase-free login"] {
            XCTAssertEqual(SecretScrubber.scrub(text), text)
        }
    }

    func testScrubberStaysFastOnALongUnbrokenWord() {
        for text in [String(repeating: "a-", count: 60_000), String(repeating: "a.", count: 60_000), String(repeating: "x", count: 131_072),
                     String(repeating: "password_", count: 15_000), "http://" + String(repeating: "a", count: 131_072)] {
            let start = Date()
            _ = SecretScrubber.scrub(text)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, String(text.prefix(12)))
        }
    }

    func testAnOutOfRangeTimestampCannotCrashTheCollector() {
        for number in ["1e20", "-1e20", "1e308"] {
            let claude = Data(#"{"display":"hello world","timestamp":\#(number),"sessionId":"s"}"#.utf8)
            let codex = Data(#"{"text":"hello world","ts":\#(number),"session_id":"s"}"#.utf8)
            _ = ConnectorParsers.parseClaudeHistoryLine(claude, toolID: "claude-code")
            _ = ConnectorParsers.parseCodexHistoryLine(codex, toolID: "codex")
        }
        XCTAssertEqual(ImportDates.wholeNumber(1e20), Int.max)
        XCTAssertEqual(ImportDates.wholeNumber(-1e20), Int.min)
        XCTAssertEqual(ImportDates.wholeNumber(.nan), 0)
        XCTAssertNil(ImportDates.fromUnix(1e20))
        XCTAssertNotNil(ImportDates.fromUnix(1_790_000_000))
        XCTAssertNotNil(ImportDates.fromUnix(1_790_000_000_000))
    }

    func testAToolIdCannotBreakOutOfAHookCommand() {
        let command = ConnectorInstaller.hookCommand(home: "/Users/me", toolID: #"x"; id #"#, reply: nil)
        XCTAssertTrue(command.hasSuffix(#"hook 'x"; id #'"#), command)
        XCTAssertTrue(ConnectorInstaller.hookCommand(home: "/Users/me", toolID: "claude-code", reply: nil).hasSuffix("hook claude-code"))
    }

    func testBrowserKeystrokesAreNeverAPromptUnlessEverythingIsSaved() {
        XCTAssertFalse(TypedPromptCapture.keepsKeystrokes(isBrowser: true, savesEverything: false))
        XCTAssertTrue(TypedPromptCapture.keepsKeystrokes(isBrowser: true, savesEverything: true))
        XCTAssertTrue(TypedPromptCapture.keepsKeystrokes(isBrowser: false, savesEverything: false))
    }
}
