import XCTest
@testable import Dictator

/// Synthetic rows shaped like real history metadata; no personal data.
final class DatasetDestinationTests: XCTestCase {
    let catalog = ToolCatalog.load(bundled: Bundle.main.url(forResource: "tool-catalog", withExtension: "json"), custom: nil)
    lazy var resolver = DatasetDestinationResolver(catalog: catalog)

    func row(tool: String? = nil, bundle: String? = nil, app: String? = nil, url: String? = nil, capture: String? = nil,
             source: String? = nil, modality: String = "typed", importBatch: String? = nil) -> DatasetRow {
        var attribution = PromptAttribution()
        attribution.toolId = tool; attribution.captureSource = capture; attribution.importBatchId = importBatch
        return DatasetRow(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_800_000_000), text: "synthetic", wordCount: 1,
                        modality: modality, durationSeconds: 0, source: source, insertionMethod: nil,
                        destinationAppBundleId: bundle, destinationAppName: app, destinationURL: url, originEdgeId: nil,
                        attribution: attribution, metrics: EntryMetrics())
    }

    func testEveryDestinationResolvesToOneNameInVendorTerms() {
        func check(_ row: DatasetRow, _ key: String, _ name: String, vendor: String?, line: UInt = #line) {
            let resolved = resolver.resolve(row)
            XCTAssertEqual(resolved.key, key, line: line)
            XCTAssertEqual(resolved.name, name, line: line)
            XCTAssertEqual(resolved.vendor, vendor, line: line)
        }
        // The merged ChatGPT app is ChatGPT unless the prompt recorded Codex.
        check(row(bundle: "com.openai.codex", app: "ChatGPT"), "tool:chatgpt", "ChatGPT", vendor: "OpenAI")
        // CLIs detected inside a terminal.
        check(row(tool: "claude-code", app: "Claude Code", capture: "hook"), "tool:claude-code", "Claude Code", vendor: "Anthropic")
        // Websites of AI tools count as the tool; other sites stay with the browser.
        check(row(bundle: "com.google.Chrome", app: "Google Chrome", url: "https://claude.ai/new"), "tool:claude", "Claude", vendor: "Anthropic")
        check(row(bundle: "com.google.Chrome", app: "Chrome", url: "https://docs.google.com/x"), "app:com.google.Chrome", "Chrome", vendor: nil)
        // Terminals, ssh and multiplexers whose program wasn't recorded.
        for terminal in [row(bundle: "com.googlecode.iterm2", app: "iTerm2"), row(app: "herdr-app"),
                         row(bundle: "dev.herdr.app", app: "Herdr"), row(bundle: "com.t3tools.t3code", app: "T3 Code (Beta)"),
                         row(url: "terminal://com.apple.Terminal/ttys001")] {
            check(terminal, "terminal", "Terminal or agent app, tool not recorded", vendor: nil)
        }
        // An editor alone doesn't mean its AI panel.
        check(row(bundle: "com.microsoft.VSCode", app: "Visual Studio Code"), "app:com.microsoft.VSCode", "VS Code", vendor: nil)
        // Readable names for apps that recorded only a bundle ID or invisible marks.
        check(row(bundle: "com.apple.ScreenSharing", app: "com.apple.ScreenSharing"), "app:com.apple.ScreenSharing", "Screen Sharing", vendor: nil)
        check(row(bundle: "net.whatsapp.WhatsApp", app: "\u{200E}WhatsApp"), "app:net.whatsapp.WhatsApp", "WhatsApp", vendor: nil)
        check(row(), "unknown", "Not recorded", vendor: nil)
        // Tools added from 2026 usage research, by app, process alias or website.
        check(row(bundle: "com.nousresearch.hermes", app: "Hermes"), "tool:hermes-agent", "Hermes Agent", vendor: "Nous Research")
        check(row(url: "https://notebooklm.google.com/notebook/x"), "tool:notebooklm", "NotebookLM", vendor: "Google")
        check(row(url: "https://www.perplexity.ai/search"), "tool:perplexity", "Perplexity", vendor: "Perplexity")
    }

    func testGroupsPutVendorsFirstAndVendorFilterCoversEveryProduct() throws {
        let rows = resolver.annotate([
            row(bundle: "com.anthropic.claudefordesktop", app: "Claude"), row(bundle: "com.anthropic.claudefordesktop", app: "Claude"),
            row(tool: "claude-code"), row(bundle: "com.openai.codex", app: "ChatGPT"),
            row(bundle: "com.googlecode.iterm2"), row(bundle: "com.google.Chrome", app: "Chrome"),
            row(bundle: "com.google.Chrome", app: "Google Chrome"), row(bundle: "com.google.Chrome", app: "Google Chrome"),
        ])
        let groups = DatasetDestinationGroup.groups(for: rows)
        XCTAssertEqual(groups.map(\.title), ["Anthropic", "OpenAI", "Terminals", "Other apps"])
        XCTAssertEqual(groups[0].allKey, "vendor:Anthropic")
        XCTAssertTrue(catalog.tools.allSatisfy { $0.vendor != nil }, "Sent to groups by vendor, so every catalog tool names one")
        XCTAssertEqual(groups[0].allCount, 3)
        XCTAssertNil(groups[1].allKey, "A vendor with one product needs no separate 'All' entry")
        XCTAssertEqual(groups.last?.options.first?.name, "Chrome", "Every spelling of one app shares the catalog name")

        var query = DatasetQuery(); query.destination = "vendor:Anthropic"
        XCTAssertEqual(try query.select(rows).count, 3)
        query.destination = "tool:claude-code"
        XCTAssertEqual(try query.select(rows).count, 1)
        query.destination = "terminal"
        XCTAssertEqual(try query.select(rows).count, 1)
    }

    func testSavedByReplacesCaptureMethodAndOrigin() throws {
        XCTAssertEqual(row(capture: "voice", modality: "voice").savedBy, .dictation)
        XCTAssertEqual(row(modality: "voice").savedBy, .dictation)
        XCTAssertEqual(row(capture: "composer").savedBy, .typedHistory)
        XCTAssertEqual(row(capture: "keystrokes").savedBy, .typedHistory)
        XCTAssertEqual(row(capture: "hook").savedBy, .connectedTool)
        XCTAssertEqual(row(capture: "import", modality: "voice").savedBy, .imported)
        XCTAssertEqual(row(importBatch: "b").savedBy, .imported)
    }

    func testExportedRecordsNameDestinationVendorAndSavedBy() throws {
        let rows = resolver.annotate([row(bundle: "com.openai.codex", app: "ChatGPT", capture: "composer"), row(bundle: "com.googlecode.iterm2", modality: "voice")])
        let dataset = try Dataset.build(rows: rows, query: DatasetQuery(), preparation: DatasetPreparation())
        // Same timestamp, so order is by ID; compare by destination.
        let byDestination = Dictionary(uniqueKeysWithValues: dataset.records.map { ($0.destination ?? "", $0) })
        XCTAssertEqual(Set(byDestination.keys), ["ChatGPT", "Terminal or agent app, tool not recorded"])
        XCTAssertEqual(byDestination["ChatGPT"]?.vendor, "OpenAI")
        XCTAssertEqual(byDestination["ChatGPT"]?.savedBy, "typedHistory")
        XCTAssertNil(byDestination["Terminal or agent app, tool not recorded"]?.vendor)
        XCTAssertEqual(byDestination["Terminal or agent app, tool not recorded"]?.savedBy, "dictation")
        var noContext = DatasetPreparation(); noContext.includeContext = false
        XCTAssertNil(try Dataset.build(rows: rows, query: DatasetQuery(), preparation: noContext).records.first?.destination)
    }
}
