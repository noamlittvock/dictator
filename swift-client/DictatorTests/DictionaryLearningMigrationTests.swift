import Foundation
import SwiftData
import XCTest
@testable import Dictator

// Same entity names and pre-learning properties; no VersionedSchema or custom
// migration. These models write only synthetic values to a temporary store.
private enum BeforeLearning {
    
    @Model
    final class DictionaryEntry {
        var id: UUID
        var pattern: String
        var replacement: String
        var isVocabulary: Bool
    
        init(pattern: String, replacement: String, isVocabulary: Bool = true) {
            self.id = UUID()
            self.pattern = pattern
            self.replacement = replacement
            self.isVocabulary = isVocabulary
        }
    }
    
    
    @Model
    final class DictationEntry {
        var id: UUID
        var timestamp: Date
        var text: String
        var durationSeconds: Double
        var inferenceMs: Int?
        var wordCount: Int
        var modality: String?
        var source: String?
        var destinationAppBundleId: String?
        var destinationAppName: String?
        var destinationURL: String?
        var insertionMethod: String?
        /// Which install (its `EdgeID`) first wrote this row — part of the
        /// dataset, not just plumbing: it says which Mac the prompt was typed
        /// or spoken on. `nil` for rows written before this field existed.
        var originEdgeId: String?
        /// Replication bookkeeping (see `HistorySyncEngine`): `nil` means this
        /// Mac wrote the row and has not yet had it acknowledged by a Core —
        /// the row is "pending sync". Set the moment the Core acknowledges an
        /// upload, or immediately for rows this Mac pulled from the Core.
        /// Rows written on the Core itself (or in standalone role) keep `nil`
        /// too: nothing is lost by that, and if this Mac later connects to a
        /// Core as an Edge, every such row is simply offered to it.
        var syncedAt: Date?
        /// Prompt attribution (v2 capture). All optional: rows written before
        /// these existed, and dictation into non-tool apps, leave them nil.
        /// Catalog tool id (`claude-code`, `chatgpt`).
        var toolId: String?
        /// `hook`, `transcript`, `composer`, `keystrokes`, `voice`.
        var captureSource: String?
        /// ssh / mosh / container destination the tool ran on.
        var remoteHost: String?
        /// Human description of where it was typed ("iTerm → ssh box → Codex").
        var surfaceLabel: String?
        /// The policy clause that saved it — see `CaptureDecision.reason`.
        var captureReason: String?
        /// Project folder the tool ran in, when known.
        var workingDirectory: String?
        /// The tool's own conversation / session id (connector captures), so a
        /// run of prompts can be told apart from the next one.
        var sessionId: String?
        /// Set on rows brought in with Import history; one id per import, so an
        /// import can be undone as a whole.
        var importBatchId: String?
        /// Measurements (see `EntryMetrics`). All optional: most rows have none.
        var typingSeconds: Double?
        var latencyMs: Int?
        var polishModel: String?
        var firstTakeAfterLoad: Bool?
    
        init(
            text: String,
            durationSeconds: Double,
            inferenceMs: Int? = nil,
            modality: String = "voice",
            source: String = "dictator",
            destinationAppBundleId: String? = nil,
            destinationAppName: String? = nil,
            destinationURL: String? = nil,
            insertionMethod: String? = nil,
            originEdgeId: String? = nil,
            attribution: PromptAttribution = PromptAttribution(),
            metrics: EntryMetrics = EntryMetrics()
        ) {
            self.id = UUID()
            self.timestamp = Date()
            self.text = text
            self.durationSeconds = durationSeconds
            self.inferenceMs = inferenceMs
            self.wordCount = text.split(separator: " ").count
            self.modality = modality
            self.source = source
            self.destinationAppBundleId = destinationAppBundleId
            self.destinationAppName = destinationAppName
            self.destinationURL = destinationURL
            self.insertionMethod = insertionMethod
            self.originEdgeId = originEdgeId
            self.syncedAt = nil
            self.toolId = attribution.toolId
            self.captureSource = attribution.captureSource
            self.remoteHost = attribution.remoteHost
            self.surfaceLabel = attribution.surfaceLabel
            self.captureReason = attribution.captureReason
            self.workingDirectory = attribution.workingDirectory
            self.sessionId = attribution.sessionId
            self.importBatchId = attribution.importBatchId
            self.typingSeconds = metrics.typingSeconds
            self.latencyMs = metrics.latencyMs
            self.polishModel = metrics.polishModel
            self.firstTakeAfterLoad = metrics.firstTakeAfterLoad
        }
    
        var attribution: PromptAttribution {
            PromptAttribution(
                toolId: toolId,
                captureSource: captureSource,
                remoteHost: remoteHost,
                surfaceLabel: surfaceLabel,
                captureReason: captureReason,
                workingDirectory: workingDirectory,
                sessionId: sessionId,
                importBatchId: importBatchId
            )
        }
    
        var metrics: EntryMetrics {
            EntryMetrics(
                typingSeconds: typingSeconds,
                latencyMs: latencyMs,
                polishModel: polishModel,
                firstTakeAfterLoad: firstTakeAfterLoad
            )
        }
    }
}

@MainActor final class DictionaryLearningMigrationTests: XCTestCase {
    func testTenThousandPreLearningRowsPerEntityOpenWithDefaultsAndUnchangedContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMigration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Synthetic.store")
        var oldContainer: ModelContainer?
        var oldContext: ModelContext?
        defer { try? FileManager.default.removeItem(at: root) }
        let oldSchema = Schema([BeforeLearning.DictionaryEntry.self, BeforeLearning.DictationEntry.self,
                                DictationStats.self, SyncOutboxItem.self, HistoryDeletion.self])
        oldContainer = try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(schema: oldSchema, url: url)])
        oldContext = ModelContext(try XCTUnwrap(oldContainer))
        // One transaction for all synthetic rows; avoid per-row autosave work.
        oldContext?.autosaveEnabled = false
        let ids = (0..<10_000).map { _ in UUID() }
        for index in ids.indices {
            let history = BeforeLearning.DictationEntry(text: "Synthetic row \(index)", durationSeconds: 1)
            history.id = ids[index]
            oldContext?.insert(history)
            oldContext?.insert(BeforeLearning.DictionaryEntry(pattern: "SyntheticTerm\(index)", replacement: ""))
        }
        try oldContext?.save()
        oldContext = nil; oldContainer = nil
        let schema = Repositories.schema
        let migrated = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = ModelContext(migrated)
        let rows = try context.fetch(FetchDescriptor<DictationEntry>())
        XCTAssertEqual(rows.count, ids.count); XCTAssertEqual(Set(rows.map(\.id)), Set(ids))
        XCTAssertTrue(rows.allSatisfy { $0.heardText == nil && $0.editedText == nil })
        XCTAssertEqual(Set(rows.map(\.text)), Set(ids.indices.map { "Synthetic row \($0)" }))
        let dictionary = try context.fetch(FetchDescriptor<DictionaryEntry>())
        XCTAssertEqual(dictionary.count, ids.count)
        XCTAssertTrue(dictionary.allSatisfy { !$0.isStarred && $0.useCount == 0 && $0.lastUsedAt == nil && $0.origin == nil && !$0.isForgotten })
    }
}
