import Foundation

/// Core-side executor for `RepoRequest`s: validates each request against
/// `RepoRequestLimits` (a pairing token grants full data authority, not
/// unbounded resource amplification or malformed durable values) and, if it
/// passes, answers it against this Core's own `Repositories`.
///
/// Does not itself broadcast mutations: `RepositoryHub` is the single source
/// of change notifications — the local repositories' `onChange` already
/// fires on every mutation this makes, and `DictatorViewModel` turns the
/// resulting version bump into a `repo.changed` broadcast.
@MainActor final class RepoServer {
    var onCorrection: ((CorrectionReport) async throws -> CorrectionOutcome)?
    private let repositories: Repositories

    init(repositories: Repositories) {
        self.repositories = repositories
    }

    func handle(_ request: RepoRequest) async -> RepoResult {
        if let violation = Self.validate(request) {
            return .error("invalid request: \(violation)")
        }
        do {
            switch request {
            case .historyPage(let limit, let before):
                return .historyPage(try await repositories.history.page(limit: limit, before: before))
            case .historyManifest(let limit, let before):
                return .historyManifest(try await repositories.historySync.manifestPage(limit: limit, before: before))
            case .historyFetch(let ids):
                return .historyPage(try await repositories.historySync.fetch(ids: ids))
            case .historyUpsert(let entries):
                let inserted = try await repositories.historySync.insertMissing(entries, asReplica: false)
                SyncDiagnostics.log("core: upsert received=\(entries.count) inserted=\(inserted)")
                return .ok
            case .historyDelete(let ids):
                try await repositories.history.delete(ids: ids)
                return .ok
            case .historyStats:
                return .historyStats(try await repositories.history.stats())
            case .dictionaryPage(let limit, let afterPattern, let includeForgotten, let afterID):
                // Filter before paging: a tombstone-only page must not look like EOF.
                return .dictionaryPage(try await repositories.dictionary.page(limit: limit, afterPattern: afterPattern, includeForgotten: includeForgotten == true, afterID: afterID))
            case .dictionaryUpsert(let entries):
                try await repositories.dictionary.upsert(entries)
                return .ok
            case .dictionaryDelete(let ids):
                try await repositories.dictionary.delete(ids: ids)
                return .ok
            case .correction(let report):
                guard let onCorrection else { return .error("Correction saving is unavailable. Try again.") }
                return .correctionOutcome(try await onCorrection(report))
            case .settingsGet:
                return .settings(try await repositories.settings.get())
            case .settingsSet(let patch):
                try await repositories.settings.set(patch)
                return .ok
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Request bounds

    static func validate(_ request: RepoRequest) -> String? {
        switch request {
        case .historyPage(let limit, _):
            return validateLimit(limit)
        case .historyManifest(let limit, _):
            return RepoRequestLimits.manifestLimitRange.contains(limit)
                ? nil
                : "limit must be in \(RepoRequestLimits.manifestLimitRange)"
        case .historyFetch(let ids):
            return validateIds(ids)
        case .historyUpsert(let entries):
            guard entries.count <= RepoRequestLimits.maxUpsertEntries else {
                return "historyUpsert exceeds \(RepoRequestLimits.maxUpsertEntries) entries"
            }
            for entry in entries {
                if let violation = validateEntry(entry) { return violation }
            }
            return nil
        case .historyDelete(let ids):
            return validateIds(ids)
        case .historyStats:
            return nil
        case .dictionaryPage(let limit, let afterPattern, _, let afterID):
            if let violation = validateLimit(limit) { return violation }
            if afterID != nil && afterPattern == nil { return "afterID requires afterPattern" }
            if let afterPattern, afterPattern.count > RepoRequestLimits.maxPatternLength {
                return "afterPattern exceeds \(RepoRequestLimits.maxPatternLength) characters"
            }
            return nil
        case .dictionaryUpsert(let entries):
            guard entries.count <= RepoRequestLimits.maxUpsertEntries else {
                return "dictionaryUpsert exceeds \(RepoRequestLimits.maxUpsertEntries) entries"
            }
            for entry in entries {
                if let violation = validateDictionaryEntry(entry) { return violation }
            }
            return nil
        case .dictionaryDelete(let ids):
            return validateIds(ids)
        case .correction(let report):
            if let selection = report.selection {
                guard report.explicit == true, report.entryID != nil, selection.start >= 0,
                      selection.end > selection.start, selection.end <= selection.originalText.count,
                      selection.originalText.count <= RepoRequestLimits.maxTextLength else { return "invalid correction selection" }
            }
            return report.heard.count <= RepoRequestLimits.maxTextLength && report.corrected.count <= RepoRequestLimits.maxTextLength ? nil : "correction exceeds text limit"
        case .settingsGet:
            return nil
        case .settingsSet(let patch):
            if let id = patch.micOwnerEdgeID, let problem = Self.validateMicOwnerEdgeID(id) { return problem }
            if let ids = patch.vocabularyPacksOn, !VocabularyPackCatalog.validSelection(ids) {
                return "Vocabulary pack choices are not valid."
            }
            if let ids = patch.vocabularyPacksOff, !VocabularyPackCatalog.validSelection(ids) {
                return "Vocabulary pack choices are not valid."
            }
            if let json = patch.surfacePolicyJSON, json.count > RepoRequestLimits.maxSurfacePolicyJSONLength {
                return "surfacePolicyJSON exceeds \(RepoRequestLimits.maxSurfacePolicyJSONLength) characters"
            }
            if let json = patch.setupRoutingJSON, json.count > RepoRequestLimits.maxSetupRoutingJSONLength {
                return "setupRoutingJSON exceeds \(RepoRequestLimits.maxSetupRoutingJSONLength) characters"
            }
            if let json = patch.workspaceLaunchJSON {
                guard json.utf8.count <= RepoRequestLimits.maxWorkspaceLaunchJSONBytes,
                      WorkspaceLaunchConfig.decode(json) != nil else {
                    return "Workspaces settings are not valid."
                }
            }
            if let json = patch.voiceLaunchJSON {
                guard json.count <= RepoRequestLimits.maxVoiceLaunchJSONLength else {
                    return "voiceLaunchJSON exceeds \(RepoRequestLimits.maxVoiceLaunchJSONLength) characters"
                }
                guard let config = VoiceLaunchConfig.decode(json) else { return "voiceLaunchJSON is not a version 2 Commands setting" }
                if let problem = config.validate() { return problem }
            }
            return nil
        }
    }

    /// Offline choices remain valid; connectivity is checked when dictation starts.
    static func validateMicOwnerEdgeID(_ id: String) -> String? {
        guard id.count <= RepoRequestLimits.maxEdgeIdLength,
              id.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            return "Choose a valid Mac that records."
        }
        return nil
    }

    private static func validateLimit(_ limit: Int) -> String? {
        RepoRequestLimits.pageLimitRange.contains(limit)
            ? nil
            : "limit must be in \(RepoRequestLimits.pageLimitRange)"
    }

    private static func validateIds(_ ids: [UUID]) -> String? {
        ids.count <= RepoRequestLimits.maxIdsPerRequest
            ? nil
            : "too many ids (max \(RepoRequestLimits.maxIdsPerRequest))"
    }

    private static func validateDictionaryEntry(_ entry: DictionaryEntryDTO) -> String? {
        if entry.pattern.count > RepoRequestLimits.maxPatternLength {
            return "pattern exceeds \(RepoRequestLimits.maxPatternLength) characters"
        }
        if entry.replacement.count > RepoRequestLimits.maxReplacementLength {
            return "replacement exceeds \(RepoRequestLimits.maxReplacementLength) characters"
        }
        if let count = entry.useCount, count < 0 { return "useCount must be non-negative" }
        if let origin = entry.origin, !["manual", "learned", "imported"].contains(origin) { return "unknown dictionary origin" }
        return nil
    }

    /// Applies the history text and field bounds to a replicated entry.
    static func validateEntry(_ entry: DictationEntryDTO) -> String? {
        if (entry.heardText?.count ?? 0) > RepoRequestLimits.maxTextLength || (entry.editedText?.count ?? 0) > RepoRequestLimits.maxTextLength { return "stage exceeds text limit" }
        if let revision = entry.editedTextRevision, revision < 0 { return "invalid edit revision" }
        if entry.text.count > RepoRequestLimits.maxTextLength {
            return "text exceeds \(RepoRequestLimits.maxTextLength) characters"
        }
        guard entry.durationSeconds.isFinite, RepoRequestLimits.durationSecondsRange.contains(entry.durationSeconds) else {
            return "durationSeconds must be finite and in \(RepoRequestLimits.durationSecondsRange)"
        }
        if let inferenceMs = entry.inferenceMs, !(0...RepoRequestLimits.maxInferenceMs).contains(inferenceMs) {
            return "inferenceMs must be in 0...\(RepoRequestLimits.maxInferenceMs)"
        }
        if let modality = entry.modality, !RepoRequestLimits.validModalities.contains(modality) {
            return "unknown modality \(modality)"
        }
        if let source = entry.source, source.count > RepoRequestLimits.maxSourceLength {
            return "source exceeds \(RepoRequestLimits.maxSourceLength) characters"
        }
        if let origin = entry.originEdgeId, origin.count > RepoRequestLimits.maxEdgeIdLength {
            return "originEdgeId exceeds \(RepoRequestLimits.maxEdgeIdLength) characters"
        }
        // More words than characters is never real, and the stats add this up.
        guard (0...RepoRequestLimits.maxTextLength).contains(entry.wordCount) else {
            return "wordCount must be in 0...\(RepoRequestLimits.maxTextLength)"
        }
        for (name, value) in [("sessionId", entry.sessionId), ("importBatchId", entry.importBatchId), ("polishModel", entry.polishModel),
                              ("cleanupLevel", entry.cleanupLevel), ("cleanupOutcome", entry.cleanupOutcome)] {
            if let value, value.count > RepoRequestLimits.maxShortFieldLength {
                return "\(name) exceeds \(RepoRequestLimits.maxShortFieldLength) characters"
            }
        }
        if let typing = entry.typingSeconds, !(typing.isFinite && typing >= 0) {
            return "typingSeconds must be a non-negative number"
        }
        if let latency = entry.latencyMs, !(0...RepoRequestLimits.maxInferenceMs).contains(latency) {
            return "latencyMs must be in 0...\(RepoRequestLimits.maxInferenceMs)"
        }
        if let cleanup = entry.cleanupMs, !(0...RepoRequestLimits.maxInferenceMs).contains(cleanup) {
            return "cleanupMs must be in 0...\(RepoRequestLimits.maxInferenceMs)"
        }
        return nil
    }
}
