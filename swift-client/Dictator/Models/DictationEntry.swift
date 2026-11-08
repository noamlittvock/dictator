import Foundation
import SwiftData

@Model
final class DictationEntry {
    var id: UUID
    var timestamp: Date
    var heardText: String? = nil
    var editedText: String? = nil
    var editedTextRevision: Int = 0
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
    var cleanupLevel: String?
    var cleanupOutcome: String?
    var cleanupMs: Int?

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
        self.cleanupLevel = metrics.cleanupLevel
        self.cleanupOutcome = metrics.cleanupOutcome
        self.cleanupMs = metrics.cleanupMs
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
            firstTakeAfterLoad: firstTakeAfterLoad,
            cleanupLevel: cleanupLevel,
            cleanupOutcome: cleanupOutcome,
            cleanupMs: cleanupMs
        )
    }
}
