import Foundation

// Core ↔ Edge repository protocol, layered on top of EdgeProtocol.
//
// Where EdgeProtocol.swift carries the live dictation session (audio,
// hotkeys, insertion), this file carries the other thing an Edge needs from
// its Core: replication of history, the dictionary, and shared settings.
// Every Mac keeps a full local copy of all three and reads/writes only that
// copy; `HistorySyncEngine` uses these requests to keep an Edge's copy and
// the Core's authoritative store converged. `RepoRequest`/`RepoResult` ride
// inside `EdgeMessage.repoRequest`/`CoreMessage.repoResponse` using the same
// flat-envelope, "kind"-discriminated encoding as `SessionOutcome`.

/// Bounds `RepoServer.handle` enforces on every decoded `RepoRequest` before
/// it touches a repository (a pairing token grants full data authority, not
/// unbounded resource amplification or malformed durable values), plus the
/// client-side pagination defaults and the Core's response byte budget.
enum RepoRequestLimits {
    /// Page size the client-side helpers request per round trip.
    /// `RepoServer` does not promise this many rows fit a response — see
    /// `pageByteBudget`.
    static let historyPageSize = 200
    static let dictionaryPageSize = 200
    /// `historyManifest` rows are tiny (id + timestamp), so a manifest page
    /// can be much larger than an entry page and still fit the frame.
    static let manifestPageSize = 2_000

    /// `historyPage`/`dictionaryPage` `limit`.
    static let pageLimitRange = 1...500
    /// `historyManifest` `limit`.
    static let manifestLimitRange = 1...5_000
    /// `historyDelete`/`dictionaryDelete`/`historyFetch` `ids`.
    static let maxIdsPerRequest = 500
    /// `dictionaryUpsert` / `historyUpsert` entry count.
    static let maxUpsertEntries = 500
    static let maxPatternLength = 512
    static let maxReplacementLength = 512
    /// `HistoryRecordDTO.text` / `DictationEntryDTO.text`.
    static let maxTextLength = 131_072
    static let durationSecondsRange: ClosedRange<Double> = 0...180
    static let maxInferenceMs = 300_000
    static let maxSourceLength = 128
    static let maxEdgeIdLength = 128
    /// Session ids, import batch ids, model names.
    static let maxShortFieldLength = 256
    static let maxSurfacePolicyJSONLength = 64 * 1_024
    static let maxSetupRoutingJSONLength = 64 * 1_024
    static let maxVoiceLaunchJSONLength = 512 * 1_024
    static let maxWorkspaceLaunchJSONBytes = 128 * 1_024
    static let validModalities: Set<String> = ["voice", "typed"]

    /// Encoded-byte budget a single paged response is built to fit under.
    /// Comfortably inside `EdgeProtocol.maxTextFrameBytes` (256 KB) once
    /// envelope/request-id overhead is added — see EdgeProtocolTests for the
    /// size assertion. Pages are built by encoding entries incrementally
    /// against this budget rather than trusting a fixed row count to fit,
    /// because two allowed 131_072-character entries already exceed the
    /// frame limit on their own.
    static let pageByteBudget = 200 * 1_024
}

// MARK: - DTOs

/// `(timestamp, id)` pagination cursor for `historyPage`/`historyManifest`:
/// `timestamp` alone is not a stable boundary — many rows can share the
/// exact same millisecond — so `id` breaks the tie deterministically.
struct HistoryCursor: Codable, Equatable {
    var timestamp: Date
    var id: UUID
}

/// Wire/UI-facing mirror of `DictationEntry` (a SwiftData `@Model`, which
/// isn't itself `Codable`/`Sendable` across the wire).
struct DictationEntryDTO: Codable, Equatable, Identifiable {
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
    /// Which install first wrote the row — see `DictationEntry.originEdgeId`.
    var originEdgeId: String?
    /// Replication state as seen by the machine that produced this DTO —
    /// see `DictationEntry.syncedAt`. Purely informational on the wire.
    var syncedAt: Date?
    /// Set when `text` was shortened to fit `RepoRequestLimits.pageByteBudget`
    /// because this single entry's own encoded size already exceeded it.
    /// `nil`/`false` for every ordinarily-sized entry.
    var truncated: Bool?
    /// Prompt attribution — see `DictationEntry.toolId` and friends. Older
    /// peers omit these fields; Codable decodes them as nil.
    var toolId: String? = nil
    var captureSource: String? = nil
    var remoteHost: String? = nil
    var surfaceLabel: String? = nil
    var captureReason: String? = nil
    var workingDirectory: String? = nil
    var sessionId: String? = nil
    var importBatchId: String? = nil
    /// Measurements — see `EntryMetrics`.
    var typingSeconds: Double? = nil
    var latencyMs: Int? = nil
    var polishModel: String? = nil
    var firstTakeAfterLoad: Bool? = nil
    var cleanupLevel: String? = nil
    var cleanupOutcome: String? = nil
    var cleanupMs: Int? = nil

    var heardText: String? = nil
    var editedText: String? = nil
    var editedTextRevision: Int? = nil

    var cursor: HistoryCursor { HistoryCursor(timestamp: timestamp, id: id) }

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

/// Where a history row came from, in capture terms (v2).
struct PromptAttribution: Codable, Equatable, Sendable {
    var toolId: String? = nil
    var captureSource: String? = nil
    var remoteHost: String? = nil
    var surfaceLabel: String? = nil
    var captureReason: String? = nil
    var workingDirectory: String? = nil
    /// The tool's conversation / session id, when the capture carried one.
    var sessionId: String? = nil
    /// Which Import history run wrote the row.
    var importBatchId: String? = nil
}

/// What was measured while a row was made — included in Dataset exports.
/// Every field is optional: older rows, imports and most captures have none.
struct EntryMetrics: Codable, Equatable, Sendable {
    /// Typed prompts: first keystroke to submit.
    var typingSeconds: Double? = nil
    /// Dictation: hotkey release to the text landing in the app.
    var latencyMs: Int? = nil
    /// Dictation: the model that polished the transcript, `none` when the
    /// raw transcript was kept.
    var polishModel: String? = nil
    /// Dictation: the first take after Dictator started or the model changed,
    /// which includes loading time.
    var firstTakeAfterLoad: Bool? = nil
    /// Dictation: the `RefineLevel` chosen for this take.
    var cleanupLevel: String? = nil
    /// Dictation: what clean-up actually did (`CleanupOutcome`). `polishModel`
    /// only says which model was asked.
    var cleanupOutcome: String? = nil
    /// Dictation: how long clean-up took, including any retry.
    var cleanupMs: Int? = nil
}

/// Wire/UI-facing mirror of `DictationStats`.
struct DictationStatsDTO: Codable, Equatable {
    var totalWords: Int
    var totalDictations: Int
    var totalAudioSeconds: Double
}

/// Wire/UI-facing mirror of `DictionaryEntry`.
struct DictionaryEntryDTO: Codable, Equatable, Identifiable {
    var id: UUID
    var pattern: String
    var replacement: String
    var isVocabulary: Bool
    var isStarred: Bool? = nil
    var useCount: Int? = nil
    var lastUsedAt: Date? = nil
    var origin: String? = nil
    var isForgotten: Bool? = nil
}

/// Identity-only history metadata: a live row, or explicit deletion proof.
/// The sync engine compares stores without shipping transcript text.
struct HistoryManifestItem: Codable, Equatable, Identifiable {
    var id: UUID
    var timestamp: Date
    /// Explicit deletion proof. Optional so old peers can still decode this
    /// manifest; only updated peers interpret it as a deletion. For these
    /// items `timestamp` is the deletion time, keeping new deletes on the
    /// newest manifest pages used by incremental sync.
    var deletedAt: Date? = nil
    var hasEditedText: Bool? = nil
    var editedTextRevision: Int? = nil

    var cursor: HistoryCursor { HistoryCursor(timestamp: timestamp, id: id) }
}

/// Snapshot of the `AppSettings` fields a Core shares with its Edges.
struct CoreSettingsDTO: Codable, Equatable {
    var refineLevel: String
    var customSystemPrompt: String
    var persistHistory: Bool
    /// The Core's cached surface policy (`AppSettings.cachedSurfacePolicyJSON`).
    /// Optional on the wire so a peer built before this field existed still
    /// decodes; `nil` means "unknown", never "clear it".
    var surfacePolicyJSON: String?
    /// The Core's `AppSettings.setupRoutingJSON`; same optional-on-the-wire rule.
    var setupRoutingJSON: String?
    /// The Core's `AppSettings.voiceLaunchJSON`; same optional-on-the-wire rule.
    var voiceLaunchJSON: String?
    /// Optional for compatibility; missing means leave the local setting alone.
    var workspaceLaunchJSON: String?
    /// Shared pack policy. Missing fields preserve local choices on older peers;
    /// empty arrays explicitly clear a choice. Installed apps stay per Mac.
    var vocabularyPacksAutomatic: Bool?
    var vocabularyPacksOn: [String]?
    var vocabularyPacksOff: [String]?
    var learnFromCorrections: Bool? = nil
    /// Missing preserves the local choice; empty means Automatic.
    var micOwnerEdgeID: String?


    // Keep the shared settings format used by existing Macs.
    private enum CodingKeys: String, CodingKey {
        case refineLevel, customSystemPrompt, persistHistory, surfacePolicyJSON, setupRoutingJSON, voiceLaunchJSON
        case workspaceLaunchJSON = "workspaceResetJSON"
        case vocabularyPacksAutomatic, vocabularyPacksOn, vocabularyPacksOff, learnFromCorrections, micOwnerEdgeID
    }

    init(refineLevel: String, customSystemPrompt: String, persistHistory: Bool, surfacePolicyJSON: String? = nil, setupRoutingJSON: String? = nil, voiceLaunchJSON: String? = nil, workspaceLaunchJSON: String? = nil, vocabularyPacksAutomatic: Bool? = nil, vocabularyPacksOn: [String]? = nil, vocabularyPacksOff: [String]? = nil, learnFromCorrections: Bool? = nil, micOwnerEdgeID: String? = nil) {
        self.refineLevel = refineLevel
        self.customSystemPrompt = customSystemPrompt
        self.persistHistory = persistHistory
        self.surfacePolicyJSON = surfacePolicyJSON
        self.setupRoutingJSON = setupRoutingJSON
        self.voiceLaunchJSON = voiceLaunchJSON
        self.workspaceLaunchJSON = workspaceLaunchJSON
        self.vocabularyPacksAutomatic = vocabularyPacksAutomatic
        self.vocabularyPacksOn = vocabularyPacksOn
        self.vocabularyPacksOff = vocabularyPacksOff
        self.learnFromCorrections = learnFromCorrections
        self.micOwnerEdgeID = micOwnerEdgeID
    }
}

/// Partial update to `CoreSettingsDTO` — every field is optional so a patch
/// can touch just one setting without round-tripping the others.
struct CoreSettingsPatch: Codable, Equatable {
    var refineLevel: String?
    var customSystemPrompt: String?
    var persistHistory: Bool?
    var surfacePolicyJSON: String?
    var setupRoutingJSON: String?
    var voiceLaunchJSON: String?
    /// Optional for compatibility; missing means leave the local setting alone.
    var workspaceLaunchJSON: String?
    var vocabularyPacksAutomatic: Bool?
    var vocabularyPacksOn: [String]?
    var vocabularyPacksOff: [String]?
    var learnFromCorrections: Bool? = nil
    /// Missing preserves the local choice; empty means Automatic.
    var micOwnerEdgeID: String?


    // Keep the shared settings format used by existing Macs.
    private enum CodingKeys: String, CodingKey {
        case refineLevel, customSystemPrompt, persistHistory, surfacePolicyJSON, setupRoutingJSON, voiceLaunchJSON
        case workspaceLaunchJSON = "workspaceResetJSON"
        case vocabularyPacksAutomatic, vocabularyPacksOn, vocabularyPacksOff, learnFromCorrections, micOwnerEdgeID
    }

    init(refineLevel: String? = nil, customSystemPrompt: String? = nil, persistHistory: Bool? = nil, surfacePolicyJSON: String? = nil, setupRoutingJSON: String? = nil, voiceLaunchJSON: String? = nil, workspaceLaunchJSON: String? = nil, vocabularyPacksAutomatic: Bool? = nil, vocabularyPacksOn: [String]? = nil, vocabularyPacksOff: [String]? = nil, learnFromCorrections: Bool? = nil, micOwnerEdgeID: String? = nil) {
        self.refineLevel = refineLevel
        self.customSystemPrompt = customSystemPrompt
        self.persistHistory = persistHistory
        self.surfacePolicyJSON = surfacePolicyJSON
        self.setupRoutingJSON = setupRoutingJSON
        self.voiceLaunchJSON = voiceLaunchJSON
        self.workspaceLaunchJSON = workspaceLaunchJSON
        self.vocabularyPacksAutomatic = vocabularyPacksAutomatic
        self.vocabularyPacksOn = vocabularyPacksOn
        self.vocabularyPacksOff = vocabularyPacksOff
        self.learnFromCorrections = learnFromCorrections
        self.micOwnerEdgeID = micOwnerEdgeID
    }

    var isEmpty: Bool {
        refineLevel == nil && customSystemPrompt == nil && persistHistory == nil && surfacePolicyJSON == nil && setupRoutingJSON == nil && voiceLaunchJSON == nil && workspaceLaunchJSON == nil && vocabularyPacksAutomatic == nil && vocabularyPacksOn == nil && vocabularyPacksOff == nil && learnFromCorrections == nil && micOwnerEdgeID == nil
    }
}

/// What a caller supplies to record one dictation or typed prompt into this
/// Mac's store (`HistoryRepository.record`). Never crosses the wire —
/// replication ships the resulting `DictationEntryDTO` by id instead.
struct HistoryRecordDTO: Equatable {
    var id: UUID? = nil
    var heardText: String? = nil
    var editedText: String? = nil
    var text: String
    var durationSeconds: Double
    var inferenceMs: Int?
    var modality: String
    var source: String
    var destinationAppBundleId: String?
    var destinationAppName: String?
    var destinationURL: String?
    var insertionMethod: String?
    var surfaceHost: String?
    var originEdgeId: String?
    /// v2 attribution. `toolId` / `remoteHost` also feed the save decision.
    var attribution = PromptAttribution()
    var metrics = EntryMetrics()
    /// When the prompt was actually submitted, if not "now" (connector
    /// records collected later from a server).
    var timestamp: Date?

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
        surfaceHost: String? = nil,
        originEdgeId: String? = nil,
        attribution: PromptAttribution = PromptAttribution()
    ) {
        self.text = text
        self.durationSeconds = durationSeconds
        self.inferenceMs = inferenceMs
        self.modality = modality
        self.source = source
        self.destinationAppBundleId = destinationAppBundleId
        self.destinationAppName = destinationAppName
        self.destinationURL = destinationURL
        self.insertionMethod = insertionMethod
        self.surfaceHost = surfaceHost
        self.originEdgeId = originEdgeId
        self.attribution = attribution
    }

    /// The capture context the policy is evaluated against.
    var captureContext: CaptureContext {
        let host = surfaceHost ?? destinationURL.flatMap { SurfacePolicy.extractHost(from: $0) }
        let catalog = ToolCatalog.shared
        let toolID = attribution.toolId
            ?? catalog.tool(forHost: host)?.id
            ?? catalog.tool(forBundleID: destinationAppBundleId).flatMap { $0.category == .editor ? nil : $0.id }
        return CaptureContext(
            toolID: toolID,
            appBundleID: destinationAppBundleId,
            appName: destinationAppName,
            webHost: host,
            url: destinationURL,
            remoteHost: attribution.remoteHost,
            workingDirectory: attribution.workingDirectory
        )
    }
}

// MARK: - Requests / results

/// Encoded flat with a `kind` discriminator, same pattern as `SessionOutcome`
/// in EdgeProtocol.swift: `{"kind":"historyPage","limit":200,"before":null}`.
enum RepoRequest: Codable, Equatable {
    /// Full entries, newest first; `before` is an exclusive `(timestamp, id)`
    /// cursor for the next page.
    case historyPage(limit: Int, before: HistoryCursor?)
    /// Identity-only live rows and explicit deletions, newest first, using
    /// the same cursor scheme. Older peers ignore optional deletion proof.
    case historyManifest(limit: Int, before: HistoryCursor?)
    /// Full entries for exactly these ids (unknown ids are omitted).
    case historyFetch(ids: [UUID])
    /// Idempotent insert-by-id: an id the Core already holds is left
    /// untouched (entries are immutable). This is how an Edge's locally
    /// recorded dictations reach the Core, and it is safe to retry.
    case historyUpsert([DictationEntryDTO])
    case historyDelete(ids: [UUID])
    case historyStats
    /// Ascending by (pattern, id); optional afterID includes the remainder of
    /// a tied pattern. Omitting it retains the legacy pattern-only cursor.
    case dictionaryPage(limit: Int, afterPattern: String?, includeForgotten: Bool? = nil, afterID: UUID? = nil)
    case dictionaryUpsert([DictionaryEntryDTO])
    case dictionaryDelete(ids: [UUID])
    case correction(CorrectionReport)
    case settingsGet
    case settingsSet(CoreSettingsPatch)

    private enum CodingKeys: String, CodingKey {
        case kind, limit, before, ids, entries, patch, afterPattern, correction, includeForgotten, afterID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "historyPage":
            self = .historyPage(
                limit: try container.decode(Int.self, forKey: .limit),
                before: try container.decodeIfPresent(HistoryCursor.self, forKey: .before)
            )
        case "historyManifest":
            self = .historyManifest(
                limit: try container.decode(Int.self, forKey: .limit),
                before: try container.decodeIfPresent(HistoryCursor.self, forKey: .before)
            )
        case "historyFetch":
            self = .historyFetch(ids: try container.decode([UUID].self, forKey: .ids))
        case "historyUpsert":
            self = .historyUpsert(try container.decode([DictationEntryDTO].self, forKey: .entries))
        case "historyDelete":
            self = .historyDelete(ids: try container.decode([UUID].self, forKey: .ids))
        case "historyStats":
            self = .historyStats
        case "dictionaryPage":
            self = .dictionaryPage(
                limit: try container.decode(Int.self, forKey: .limit),
                afterPattern: try container.decodeIfPresent(String.self, forKey: .afterPattern),
                includeForgotten: try container.decodeIfPresent(Bool.self, forKey: .includeForgotten),
                afterID: try container.decodeIfPresent(UUID.self, forKey: .afterID)
            )
        case "dictionaryUpsert":
            self = .dictionaryUpsert(try container.decode([DictionaryEntryDTO].self, forKey: .entries))
        case "dictionaryDelete":
            self = .dictionaryDelete(ids: try container.decode([UUID].self, forKey: .ids))
        case "correction":
            self = .correction(try container.decode(CorrectionReport.self, forKey: .correction))
        case "settingsGet":
            self = .settingsGet
        case "settingsSet":
            self = .settingsSet(try container.decode(CoreSettingsPatch.self, forKey: .patch))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown repo request kind \(other)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .historyPage(let limit, let before):
            try container.encode("historyPage", forKey: .kind)
            try container.encode(limit, forKey: .limit)
            try container.encodeIfPresent(before, forKey: .before)
        case .historyManifest(let limit, let before):
            try container.encode("historyManifest", forKey: .kind)
            try container.encode(limit, forKey: .limit)
            try container.encodeIfPresent(before, forKey: .before)
        case .historyFetch(let ids):
            try container.encode("historyFetch", forKey: .kind)
            try container.encode(ids, forKey: .ids)
        case .historyUpsert(let entries):
            try container.encode("historyUpsert", forKey: .kind)
            try container.encode(entries, forKey: .entries)
        case .historyDelete(let ids):
            try container.encode("historyDelete", forKey: .kind)
            try container.encode(ids, forKey: .ids)
        case .historyStats:
            try container.encode("historyStats", forKey: .kind)
        case .dictionaryPage(let limit, let afterPattern, let includeForgotten, let afterID):
            try container.encode("dictionaryPage", forKey: .kind)
            try container.encode(limit, forKey: .limit)
            try container.encodeIfPresent(afterPattern, forKey: .afterPattern)
            try container.encodeIfPresent(includeForgotten, forKey: .includeForgotten)
            try container.encodeIfPresent(afterID, forKey: .afterID)
        case .dictionaryUpsert(let entries):
            try container.encode("dictionaryUpsert", forKey: .kind)
            try container.encode(entries, forKey: .entries)
        case .dictionaryDelete(let ids):
            try container.encode("dictionaryDelete", forKey: .kind)
            try container.encode(ids, forKey: .ids)
        case .correction(let report):
            try container.encode("correction", forKey: .kind)
            try container.encode(report, forKey: .correction)
        case .settingsGet:
            try container.encode("settingsGet", forKey: .kind)
        case .settingsSet(let patch):
            try container.encode("settingsSet", forKey: .kind)
            try container.encode(patch, forKey: .patch)
        }
    }
}

/// Encoded flat, same pattern as `RepoRequest`.
enum RepoResult: Codable, Equatable {
    case historyPage([DictationEntryDTO])
    case historyManifest([HistoryManifestItem])
    case historyStats(DictationStatsDTO?)
    case dictionaryPage([DictionaryEntryDTO])
    case settings(CoreSettingsDTO)
    case ok
    case correctionOutcome(CorrectionOutcome)
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case kind, history, manifest, stats, dictionary, settings, message, correctionOutcome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "historyPage":
            self = .historyPage(try container.decode([DictationEntryDTO].self, forKey: .history))
        case "historyManifest":
            self = .historyManifest(try container.decode([HistoryManifestItem].self, forKey: .manifest))
        case "historyStats":
            self = .historyStats(try container.decodeIfPresent(DictationStatsDTO.self, forKey: .stats))
        case "dictionaryPage":
            self = .dictionaryPage(try container.decode([DictionaryEntryDTO].self, forKey: .dictionary))
        case "settings":
            self = .settings(try container.decode(CoreSettingsDTO.self, forKey: .settings))
        case "ok":
            if let outcome = try container.decodeIfPresent(CorrectionOutcome.self, forKey: .correctionOutcome) {
                self = .correctionOutcome(outcome)
            } else { self = .ok }
        case "error":
            self = .error(try container.decode(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown repo result kind \(other)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .historyPage(let entries):
            try container.encode("historyPage", forKey: .kind)
            try container.encode(entries, forKey: .history)
        case .historyManifest(let items):
            try container.encode("historyManifest", forKey: .kind)
            try container.encode(items, forKey: .manifest)
        case .historyStats(let stats):
            try container.encode("historyStats", forKey: .kind)
            try container.encodeIfPresent(stats, forKey: .stats)
        case .dictionaryPage(let entries):
            try container.encode("dictionaryPage", forKey: .kind)
            try container.encode(entries, forKey: .dictionary)
        case .settings(let settings):
            try container.encode("settings", forKey: .kind)
            try container.encode(settings, forKey: .settings)
        case .correctionOutcome(let outcome):
            try container.encode("ok", forKey: .kind)
            try container.encode(outcome, forKey: .correctionOutcome)
        case .ok:
            try container.encode("ok", forKey: .kind)
        case .error(let message):
            try container.encode("error", forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

/// What kind of Core-side store changed, broadcast to every connected Edge
/// via `CoreMessage.repoChanged` so their sync engines know to pull. Also
/// the currency `RepositoryHub` uses for its own per-domain version bumps.
enum RepoChange: String, Codable {
    case history, dictionary, settings
}
