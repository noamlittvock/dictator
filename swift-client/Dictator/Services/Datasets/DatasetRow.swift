import Foundation

/// One history row as Dataset sees it: a plain value copied out of the
/// store once per refresh, so preparation runs off the main thread on
/// immutable data and can be tested without SwiftData.
struct DatasetRow: Equatable, Sendable, Identifiable {
    enum Modality: String, Sendable {
        case voice
        case typed
    }

    var id: UUID
    var timestamp: Date
    var text: String
    var wordCount: Int
    var modality: Modality
    /// Recording length for dictation (0 when unknown).
    var durationSeconds: Double
    /// `hook`, `transcript`, `composer`, `keystrokes`, `voice`, `import`.
    var captureSource: String?
    /// Catalog tool id, when known.
    var toolId: String?
    var appBundleId: String?
    var appName: String?
    /// Web host of the page it went to (browsers).
    var webHost: String?
    var remoteHost: String?
    var workingDirectory: String?
    var sessionId: String?
    /// Which install wrote it (`EdgeID`); nil for rows older than that field.
    var originEdgeId: String?
    /// True for rows that came from Import history (or the earlier import
    /// script) rather than being captured as they happened.
    var isImported: Bool
    var importBatchId: String?
    var typingSeconds: Double?
    var latencyMs: Int?
    var polishModel: String?
    var firstTakeAfterLoad: Bool?
    var cleanupLevel: String? = nil
    var cleanupOutcome: String? = nil
    var cleanupMs: Int? = nil
    var destinationURL: String? = nil
    var recordedModality: String? = nil
    var source: String? = nil
    var surfaceLabel: String? = nil
    var captureReason: String? = nil
    var insertionMethod: String? = nil
    var inferenceMs: Int? = nil
    /// Set by `DatasetDestinationResolver` when history is read.
    var destination: DatasetDestination? = nil

    /// How the prompt reached history, in one choice instead of the
    /// recorded capture method and import flags.
    var savedBy: DatasetQuery.SavedBy {
        if isImported { return .imported }
        switch captureSource {
        case "hook", "transcript": return .connectedTool
        case "composer", "keystrokes": return .typedHistory
        case "voice": return .dictation
        default: return modality == .voice ? .dictation : .typedHistory
        }
    }

    /// Project folder name ("dictator"), from the working directory.
    var project: String? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}

extension DatasetRow {
    init(
        id: UUID,
        timestamp: Date,
        text: String,
        wordCount: Int,
        modality: String?,
        durationSeconds: Double,
        source: String? = nil,
        insertionMethod: String?,
        destinationAppBundleId: String?,
        destinationAppName: String?,
        destinationURL: String?,
        originEdgeId: String?,
        attribution: PromptAttribution,
        metrics: EntryMetrics,
        inferenceMs: Int? = nil
    ) {
        let isVoice = modality == "voice" || modality == "voice_derived"
        self.init(
            id: id,
            timestamp: timestamp,
            text: text,
            wordCount: wordCount,
            modality: isVoice ? .voice : .typed,
            durationSeconds: durationSeconds,
            captureSource: attribution.captureSource,
            toolId: attribution.toolId,
            appBundleId: destinationAppBundleId,
            appName: destinationAppName,
            webHost: DatasetRow.host(of: destinationURL),
            remoteHost: attribution.remoteHost,
            workingDirectory: attribution.workingDirectory,
            sessionId: attribution.sessionId,
            originEdgeId: originEdgeId,
            isImported: attribution.importBatchId != nil || attribution.captureSource == "import",
            importBatchId: attribution.importBatchId,
            typingSeconds: metrics.typingSeconds,
            latencyMs: metrics.latencyMs,
            polishModel: metrics.polishModel,
            firstTakeAfterLoad: metrics.firstTakeAfterLoad,
            cleanupLevel: metrics.cleanupLevel,
            cleanupOutcome: metrics.cleanupOutcome,
            cleanupMs: metrics.cleanupMs
        )
        self.destinationURL = destinationURL
        self.recordedModality = modality
        self.source = source
        self.surfaceLabel = attribution.surfaceLabel
        self.captureReason = attribution.captureReason
        self.insertionMethod = insertionMethod
        self.inferenceMs = inferenceMs
    }

    init(_ dto: DictationEntryDTO) {
        self.init(
            id: dto.id,
            timestamp: dto.timestamp,
            text: dto.text,
            wordCount: dto.wordCount,
            modality: dto.modality,
            durationSeconds: dto.durationSeconds,
            source: dto.source,
            insertionMethod: dto.insertionMethod,
            destinationAppBundleId: dto.destinationAppBundleId,
            destinationAppName: dto.destinationAppName,
            destinationURL: dto.destinationURL,
            originEdgeId: dto.originEdgeId,
            attribution: dto.attribution,
            metrics: dto.metrics,
            inferenceMs: dto.inferenceMs
        )
    }

    /// `https://docs.google.com/…` → `docs.google.com`. Terminal pseudo URLs
    /// (`terminal://…`) and `unknown` are not web hosts.
    static func host(of url: String?) -> String? {
        guard let url, url.hasPrefix("http://") || url.hasPrefix("https://") else { return nil }
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Recorded dates only, with no prompt text or assessment of recency.
/// Unknown computers stay unknown; replication preserves the origin ID.
struct DatasetToolLastSaved: Equatable, Identifiable, Sendable {
    var computerID: String?
    var timestamp: Date
    var id: String { computerID ?? "" }

    static func byTool(in rows: [DatasetRow]) -> [String: [DatasetToolLastSaved]] {
        var latest: [String: [String: Date]] = [:]
        for row in rows {
            let toolID: String
            if let recorded = row.toolId, !recorded.isEmpty {
                toolID = recorded
            } else if let destination = row.destination, destination.kind == .aiTool,
                      destination.key.hasPrefix("tool:") {
                // Use the same app/website attribution as the rest of Dataset.
                toolID = String(destination.key.dropFirst(5))
            } else { continue }
            let computer = row.originEdgeId ?? ""
            latest[toolID, default: [:]][computer] = max(latest[toolID]?[computer] ?? .distantPast, row.timestamp)
        }
        return latest.mapValues { computers in
            computers.map { DatasetToolLastSaved(computerID: $0.key.isEmpty ? nil : $0.key, timestamp: $0.value) }
                .sorted { ($0.computerID ?? "") < ($1.computerID ?? "") }
        }
    }
}

/// Word-level text helpers used for preparing data. Deterministic and
/// language-agnostic (Latin and Hebrew letters, digits, apostrophes).
enum DatasetText {
    /// Lower-cased words, punctuation dropped.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
    }

    /// Words joined by single spaces — the form every comparison uses.
    static func normalized(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

}
