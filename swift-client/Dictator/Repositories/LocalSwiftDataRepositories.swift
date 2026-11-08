import Foundation
import SwiftData

// SwiftData-backed `Repositories` — this Mac's own store, the only thing the
// UI ever reads and the first place every write lands. `HistorySyncEngine`
// drives the `HistorySyncStore`/`DictionarySyncStore`/`SyncOutbox` surface
// below to replicate to and from a Core.

@MainActor final class LocalHistoryRepository: HistoryRepository, HistorySyncStore {
    private let container: ModelContainer
    private let outbox: SyncOutbox
    var onChange: (() -> Void)?
    private(set) var changeIsReplica = false

    private func notifyChange(isReplica: Bool = false) {
        changeIsReplica = isReplica
        defer { changeIsReplica = false }
        onChange?()
    }

    init(container: ModelContainer, outbox: SyncOutbox) {
        self.container = container
        self.outbox = outbox
    }

    func page(limit: Int, before: HistoryCursor?) async throws -> [DictationEntryDTO] {
        let container = container
        let readTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let context = ModelContext(container)
            return Self.budgetedPage(try Self.fetchNewest(context, limit: limit, before: before).map(DictationEntryDTO.init))
        }
        return try await withTaskCancellationHandler {
            try await readTask.value
        } onCancel: {
            readTask.cancel()
        }
    }

    /// Unlike wire pages, local browsing preserves the full text. Filter scans
    /// fetch only metadata; text faults are fulfilled only for matching rows.
    func browsePage(limit: Int, before: HistoryCursor?, filter: HistoryFilter) async throws -> [DictationEntryDTO] {
        guard limit > 0 else { return [] }
        let container = container
        let catalog = ToolCatalog.shared
        let readTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let context = ModelContext(container)
            var result: [DictationEntryDTO] = []
            var cursor = before
            while result.count < limit {
                try Task.checkCancellation()
                let batch = try Self.fetchNewest(context, limit: limit, before: cursor, metadataOnly: filter != .all)
                guard let last = batch.last else { break }
                for entry in batch {
                    let destination = HistoryFilter.destinationName(toolID: entry.toolId, appName: entry.destinationAppName,
                                                                    bundleID: entry.destinationAppBundleId, catalog: catalog)
                    if filter.matches(modality: entry.modality, destination: destination) {
                        result.append(DictationEntryDTO(entry))
                        if result.count == limit { return result }
                    }
                }
                cursor = HistoryCursor(timestamp: last.timestamp, id: last.id)
            }
            return result
        }
        return try await withTaskCancellationHandler {
            try await readTask.value
        } onCancel: {
            readTask.cancel()
        }
    }

    /// Whole-store actions are explicit. Read full local text, without the
    /// byte budget and truncation reserved for replication's wire pages.
    func allEntries() async throws -> [DictationEntryDTO] {
        let container = container
        let readTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<DictationEntry>())
            return rows.sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.id.uuidString > $1.id.uuidString
            }.map(DictationEntryDTO.init)
        }
        return try await withTaskCancellationHandler {
            try await readTask.value
        } onCancel: {
            readTask.cancel()
        }
    }

    func destinationNames() async throws -> [String] {
        let container = container
        let catalog = ToolCatalog.shared
        let readTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<DictationEntry>()
            descriptor.propertiesToFetch = [\.toolId, \.destinationAppName, \.destinationAppBundleId]
            let names = try context.fetch(descriptor).compactMap {
                HistoryFilter.destinationName(toolID: $0.toolId, appName: $0.destinationAppName,
                                              bundleID: $0.destinationAppBundleId, catalog: catalog)
            }
            return Array(Set(names)).sorted()
        }
        return try await withTaskCancellationHandler {
            try await readTask.value
        } onCancel: {
            readTask.cancel()
        }
    }

    /// Fetch only the requested prefix plus one row to detect a tie at its
    /// boundary. UUIDs cannot be sorted in SwiftData, so fetch the complete
    /// tied timestamp group only when needed and sort those IDs in memory.
    nonisolated private static func fetchNewest(
        _ context: ModelContext, limit: Int, before: HistoryCursor?, metadataOnly: Bool = false
    ) throws -> [DictationEntry] {
        guard limit > 0 else { return [] }
        func fetch(_ predicate: Predicate<DictationEntry>?, limit: Int? = nil) throws -> [DictationEntry] {
            var descriptor = FetchDescriptor<DictationEntry>(predicate: predicate, sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            descriptor.fetchLimit = limit
            if metadataOnly {
                descriptor.propertiesToFetch = [\.id, \.timestamp, \.modality, \.toolId, \.destinationAppName, \.destinationAppBundleId, \.editedTextRevision]
            }
            try Task.checkCancellation()
            return try context.fetch(descriptor)
        }
        func ordered(_ rows: [DictationEntry]) -> [DictationEntry] {
            rows.sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.id.uuidString > $1.id.uuidString
            }
        }
        var prefix: [DictationEntry] = []
        var predicate: Predicate<DictationEntry>?
        if let before {
            let boundary = before.timestamp
            prefix = ordered(try fetch(#Predicate { $0.timestamp == boundary }).filter { $0.id.uuidString < before.id.uuidString })
            if prefix.count >= limit { return Array(prefix.prefix(limit)) }
            predicate = #Predicate { $0.timestamp < boundary }
        }
        let remaining = limit - prefix.count
        var newer = try fetch(predicate, limit: remaining + 1)
        if newer.count > remaining, newer[remaining - 1].timestamp == newer[remaining].timestamp {
            let boundary = newer[remaining - 1].timestamp
            newer = newer.filter { $0.timestamp > boundary } + (try fetch(#Predicate { $0.timestamp == boundary }))
        }
        return Array((prefix + ordered(newer)).prefix(limit))
    }

    /// Encodes `paged` incrementally against `RepoRequestLimits.pageByteBudget`
    /// and stops before the running JSON array size would exceed it. A
    /// first entry that alone exceeds the budget is returned alone with
    /// `text` shortened to fit and `truncated: true`.
    nonisolated private static func budgetedPage(_ paged: [DictationEntryDTO]) -> [DictationEntryDTO] {
        let budget = RepoRequestLimits.pageByteBudget
        let page = encodedBudgetPage(paged, budget: budget)
        guard page.count == 1, let only = page.first else { return page }
        let size = (try? JSONEncoder().encode(only).count) ?? 0
        guard size + 2 > budget else { return page }
        return [truncated(only, budget: budget - 2)]
    }

    /// Shrinks `entry.text` until the entry's own encoded size fits
    /// `budget`, marking `truncated: true`. Shrinks in chunks (not
    /// char-by-char) since a 131_072-character entry could otherwise take
    /// thousands of encode passes to converge.
    nonisolated private static func truncated(_ entry: DictationEntryDTO, budget: Int) -> DictationEntryDTO {
        var mutable = entry
        mutable.truncated = true
        let encoder = JSONEncoder()
        while !mutable.text.isEmpty || !(mutable.heardText ?? "").isEmpty || !(mutable.editedText ?? "").isEmpty {
            let size = (try? encoder.encode(mutable).count) ?? Int.max
            if size <= budget { break }
            func shrink(_ text: String) -> String { String(text.prefix(max(0, text.count - max(64, text.count / 8)))) }
            mutable.text = shrink(mutable.text)
            mutable.heardText = mutable.heardText.map(shrink)
            mutable.editedText = mutable.editedText.map(shrink)
        }
        return mutable
    }

    func stats() async throws -> DictationStatsDTO? {
        let context = ModelContext(container)
        guard let stats = try context.fetch(FetchDescriptor<DictationStats>()).first else { return nil }
        return DictationStatsDTO(
            totalWords: stats.totalWords,
            totalDictations: stats.totalDictations,
            totalAudioSeconds: stats.totalAudioSeconds
        )
    }

    /// Deletes locally, and — in the same transaction — queues the delete
    /// for the Core when this Mac is an Edge (`outbox.enabled`).
    func delete(ids: [UUID]) async throws {
        let context = ModelContext(container)
        let idSet = Set(ids)
        let deletedAt = Date()
        for batch in Array(idSet).chunked(RepoRequestLimits.maxIdsPerRequest) {
            let wanted = Set(batch)
            let descriptor = FetchDescriptor<DictationEntry>(predicate: #Predicate { wanted.contains($0.id) })
            for entry in try context.fetch(descriptor) { context.delete(entry) }
            try Self.rememberDeletions(ids: wanted, at: deletedAt, in: context)
        }
        if outbox.enabled, !idSet.isEmpty {
            try outbox.enqueue(.historyDelete(ids: Array(idSet)), in: context)
        }
        try Self.save(context)
        notifyChange()
    }

    /// Persist gate via `AppSettings.shared.shouldPersist`; aggregate voice
    /// stats always updated (typed entries affect the History feed but not
    /// WPM); one `context.save()`/rollback for both. The new row starts
    /// pending replication (`syncedAt == nil`).
    func record(_ entry: HistoryRecordDTO) async throws {
        let modelContext = ModelContext(container)

        let context = entry.captureContext
        let decision = AppSettings.shared.captureDecision(for: context, modality: entry.modality, at: entry.timestamp ?? Date())
        let persisted = decision.isSave
        if persisted {
            var attribution = entry.attribution
            attribution.toolId = attribution.toolId ?? context.toolID
            attribution.captureReason = decision.reason
            if attribution.captureSource == nil, entry.modality == "voice" { attribution.captureSource = CaptureSource.voice.rawValue }
            let model = DictationEntry(
                text: entry.text,
                durationSeconds: entry.durationSeconds,
                inferenceMs: entry.inferenceMs,
                modality: entry.modality,
                source: entry.source,
                destinationAppBundleId: entry.destinationAppBundleId,
                destinationAppName: entry.destinationAppName,
                destinationURL: entry.destinationURL,
                insertionMethod: entry.insertionMethod,
                originEdgeId: entry.originEdgeId,
                attribution: attribution,
                metrics: entry.metrics
            )
            if let id = entry.id { model.id = id }
            model.heardText = entry.heardText
            model.editedText = entry.editedText
            if let timestamp = entry.timestamp { model.timestamp = timestamp }
            modelContext.insert(model)
        }

        if entry.modality == "voice" {
            let wordCount = entry.text.split(separator: " ").count
            try Self.statsRow(in: modelContext).record(wordCount: wordCount, durationSeconds: entry.durationSeconds)
        }

        try Self.save(modelContext)
        SyncDiagnostics.log("history: recorded \(entry.modality) source=\(entry.source) chars=\(entry.text.count) persisted=\(persisted) reason=\(decision.reason) tool=\(context.toolID ?? "-")")
        notifyChange()
    }

    func entry(id: UUID) async throws -> DictationEntryDTO? {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<DictationEntry>(predicate: #Predicate { $0.id == id })).first.map(DictationEntryDTO.init)
    }

    func saveEditedText(_ text: String, id: UUID) async throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DictationEntry>(predicate: #Predicate { $0.id == id })
        guard let row = try context.fetch(descriptor).first, row.editedText == nil else { return }
        let dto = DictationEntryDTO(row)
        let record = HistoryRecordDTO(text: row.text, durationSeconds: row.durationSeconds,
            destinationAppBundleId: row.destinationAppBundleId, destinationAppName: row.destinationAppName,
            destinationURL: row.destinationURL, attribution: dto.attribution)
        guard AppSettings.shared.captureDecision(for: record.captureContext, modality: "typed").isSave else { return }
        row.editedText = String(text.prefix(RepoRequestLimits.maxTextLength))
        try Self.save(context)
        notifyChange()
    }

    /// A deliberate History fix is independent of automatic typed capture.
    func saveManualEdit(_ text: String, id: UUID, expectedText: String) async throws -> Bool {
        let context = ModelContext(container)
        guard let row = try context.fetch(FetchDescriptor<DictationEntry>(predicate: #Predicate { $0.id == id })).first,
              (row.editedText ?? row.text) == expectedText else {
            throw RepositoryError.remote("This history row changed. Close this sheet and try again.")
        }
        guard AppSettings.shared.persistHistory else { return false }
        guard text.count <= RepoRequestLimits.maxTextLength, row.editedTextRevision < Int.max else {
            throw RepositoryError.remote("The correction couldn’t be saved.")
        }
        row.editedText = text
        row.editedTextRevision += 1
        row.syncedAt = nil
        try Self.save(context)
        notifyChange()
        return true
    }

    // MARK: - HistorySyncStore

    func localManifest() async throws -> [(item: HistoryManifestItem, pending: Bool)] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<DictationEntry>()
        descriptor.propertiesToFetch = [\.id, \.timestamp, \.syncedAt, \.editedTextRevision]
        let edited = try Self.editedIDs(in: context)
        return try context.fetch(descriptor).map {
            (HistoryManifestItem(id: $0.id, timestamp: $0.timestamp, hasEditedText: edited.contains($0.id), editedTextRevision: $0.editedTextRevision), $0.syncedAt == nil)
        }
    }

    func manifestPage(limit: Int, before: HistoryCursor?) async throws -> [HistoryManifestItem] {
        let context = ModelContext(container)
        let models = try Self.fetchNewest(context, limit: limit, before: before, metadataOnly: true)
        let edited = try Self.editedIDs(in: context, limitedTo: Set(models.map(\.id)))
        let live = models.map {
            HistoryManifestItem(id: $0.id, timestamp: $0.timestamp, hasEditedText: edited.contains($0.id), editedTextRevision: $0.editedTextRevision)
        }
        let deleted = try Self.fetchDeletions(context, limit: limit, before: before).map {
            HistoryManifestItem(id: $0.id, timestamp: $0.deletedAt, deletedAt: $0.deletedAt)
        }
        let merged = (live + deleted).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id.uuidString > $1.id.uuidString
        }
        return encodedBudgetPage(Array(merged.prefix(max(0, limit))), budget: RepoRequestLimits.pageByteBudget)
    }

    private static func editedIDs(in context: ModelContext, limitedTo ids: Set<UUID>? = nil) throws -> Set<UUID> {
        var descriptor: FetchDescriptor<DictationEntry>
        if let ids {
            descriptor = FetchDescriptor(predicate: #Predicate { ids.contains($0.id) && $0.editedText != nil })
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.editedText != nil })
        }
        descriptor.propertiesToFetch = [\.id]
        return Set(try context.fetch(descriptor).map(\.id))
    }

    func existingIDs(ids: [UUID]) async throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let context = ModelContext(container)
        let idSet = Set(ids)
        var descriptor = FetchDescriptor<DictationEntry>(predicate: #Predicate { idSet.contains($0.id) })
        descriptor.propertiesToFetch = [\.id]
        return Set(try context.fetch(descriptor).map(\.id))
    }

    func localDeletions() async throws -> [HistoryManifestItem] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<HistoryDeletion>()
        descriptor.propertiesToFetch = [\.id, \.deletedAt]
        return try context.fetch(descriptor).map {
            HistoryManifestItem(id: $0.id, timestamp: $0.deletedAt, deletedAt: $0.deletedAt)
        }
    }

    func deletionIDs(ids: [UUID]) async throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let context = ModelContext(container)
        let wanted = Set(ids)
        let descriptor = FetchDescriptor<HistoryDeletion>(predicate: #Predicate { wanted.contains($0.id) })
        return Set(try context.fetch(descriptor).map(\.id))
    }

    func applyDeletions(_ items: [HistoryManifestItem]) async throws {
        let deleted = items.filter { $0.deletedAt != nil }
        guard !deleted.isEmpty else { return }
        let context = ModelContext(container)
        var removed = false
        for batch in deleted.chunked(RepoRequestLimits.maxIdsPerRequest) {
            let wanted = Set(batch.map(\.id))
            let descriptor = FetchDescriptor<DictationEntry>(predicate: #Predicate { wanted.contains($0.id) })
            let existing = try context.fetch(descriptor)
            for row in existing { context.delete(row) }
            removed = removed || !existing.isEmpty
            let knownDescriptor = FetchDescriptor<HistoryDeletion>(predicate: #Predicate { wanted.contains($0.id) })
            var known = Set(try context.fetch(knownDescriptor).map(\.id))
            for item in batch {
                if let date = item.deletedAt, known.insert(item.id).inserted {
                    context.insert(HistoryDeletion(id: item.id, deletedAt: date))
                }
            }
        }
        try Self.save(context)
        if removed { notifyChange(isReplica: true) }
    }

    private static func rememberDeletions(ids: Set<UUID>, at date: Date, in context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        let descriptor = FetchDescriptor<HistoryDeletion>(predicate: #Predicate { ids.contains($0.id) })
        let known = Set(try context.fetch(descriptor).map(\.id))
        for id in ids.subtracting(known) { context.insert(HistoryDeletion(id: id, deletedAt: date)) }
    }

    /// A range scan over the unique indexed key bounds both SQL work and
    /// fetched models, even when every deletion has exactly the same date.
    private static func fetchDeletions(_ context: ModelContext, limit: Int, before: HistoryCursor?) throws -> [HistoryDeletion] {
        guard limit > 0 else { return [] }
        var predicate: Predicate<HistoryDeletion>?
        if let before {
            let boundary = HistoryDeletion.key(id: before.id, date: before.timestamp)
            predicate = #Predicate { $0.sortKey < boundary }
        }
        var descriptor = FetchDescriptor<HistoryDeletion>(predicate: predicate, sortBy: [SortDescriptor(\.sortKey, comparator: .lexical, order: .reverse)])
        descriptor.propertiesToFetch = [\.id, \.deletedAt, \.sortKey]
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func fetch(ids: [UUID]) async throws -> [DictationEntryDTO] {
        let context = ModelContext(container)
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<DictationEntry>(predicate: #Predicate { idSet.contains($0.id) })
        let fetched = try context.fetch(descriptor)
            .sorted { $0.timestamp > $1.timestamp }
            .map(DictationEntryDTO.init)
        return Self.budgetedPage(fetched)
    }

    func pendingSync(limit: Int, excluding skipped: Set<UUID>) async throws -> [DictationEntryDTO] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<DictationEntry>(predicate: #Predicate { $0.syncedAt == nil && !skipped.contains($0.id) })
        descriptor.sortBy = [SortDescriptor(\.timestamp, order: .forward)]
        descriptor.fetchLimit = limit
        return Self.budgetedPage(try context.fetch(descriptor).map(DictationEntryDTO.init))
    }

    func pendingCount() async throws -> Int {
        let context = ModelContext(container)
        return try context.fetchCount(FetchDescriptor<DictationEntry>(predicate: #Predicate { $0.syncedAt == nil }))
    }

    func markSynced(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let context = ModelContext(container)
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<DictationEntry>(predicate: #Predicate { idSet.contains($0.id) })
        let now = Date()
        for entry in try context.fetch(descriptor) where entry.syncedAt == nil {
            entry.syncedAt = now
        }
        try Self.save(context)
        // Not an `onChange`: the rows' content didn't change, only their
        // bookkeeping — the engine publishes its own pending count.
    }

    @discardableResult
    func insertMissing(_ entries: [DictationEntryDTO], asReplica: Bool) async throws -> Int {
        guard !entries.isEmpty else { return 0 }
        let context = ModelContext(container)
        let wanted = Set(entries.map(\.id))
        var descriptor = FetchDescriptor<DictationEntry>(predicate: #Predicate { wanted.contains($0.id) })
        descriptor.propertiesToFetch = [\.id]
        let present = Set(try context.fetch(descriptor).map(\.id))
        let deletionDescriptor = FetchDescriptor<HistoryDeletion>(predicate: #Predicate { wanted.contains($0.id) })
        let deleted = Set(try context.fetch(deletionDescriptor).map(\.id))

        var stagesChanged = false
        for dto in entries where present.contains(dto.id) && dto.editedText != nil {
            let id = dto.id
            if let row = try context.fetch(FetchDescriptor<DictationEntry>(predicate: #Predicate { $0.id == id })).first,
               (row.editedText == nil || (dto.editedTextRevision ?? 0) > row.editedTextRevision) {
                row.editedText = dto.editedText
                row.editedTextRevision = dto.editedTextRevision ?? 0
                stagesChanged = true
            }
        }
        var inserted = 0
        let now = Date()
        for dto in entries where !present.contains(dto.id) && !deleted.contains(dto.id) {
            let model = Self.newRow(from: dto, inferenceMs: dto.inferenceMs, defaultModality: "voice", defaultSource: "dictator")
            model.wordCount = dto.wordCount
            // A row that arrived through replication — pulled from the Core
            // or uploaded by an Edge — is by definition already shared.
            model.syncedAt = now
            context.insert(model)
            inserted += 1
            if !asReplica, (dto.modality ?? "voice") == "voice" {
                try Self.statsRow(in: context).record(wordCount: dto.wordCount, durationSeconds: dto.durationSeconds)
            }
        }
        guard inserted > 0 || stagesChanged else { return 0 }
        try Self.save(context)
        notifyChange(isReplica: asReplica)
        return inserted
    }

    func deleteReplicas(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let context = ModelContext(container)
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<DictationEntry>(predicate: #Predicate { idSet.contains($0.id) })
        let existing = try context.fetch(descriptor)
        guard !existing.isEmpty else { return }
        for entry in existing {
            context.delete(entry)
        }
        try Self.save(context)
        notifyChange(isReplica: true)
    }

    func replaceStats(_ stats: DictationStatsDTO) async throws {
        let context = ModelContext(container)
        let row = try Self.statsRow(in: context)
        guard row.totalWords != stats.totalWords
            || row.totalDictations != stats.totalDictations
            || row.totalAudioSeconds != stats.totalAudioSeconds else { return }
        row.totalWords = stats.totalWords
        row.totalDictations = stats.totalDictations
        row.totalAudioSeconds = stats.totalAudioSeconds
        try Self.save(context)
        notifyChange(isReplica: true)
    }

    /// A new row with `dto`'s id, timestamp and text fields; the defaults
    /// fill in a modality or source `dto` leaves out.
    private static func newRow(from dto: DictationEntryDTO, inferenceMs: Int?, defaultModality: String, defaultSource: String) -> DictationEntry {
        let model = DictationEntry(
            text: dto.text,
            durationSeconds: dto.durationSeconds,
            inferenceMs: inferenceMs,
            modality: dto.modality ?? defaultModality,
            source: dto.source ?? defaultSource,
            destinationAppBundleId: dto.destinationAppBundleId,
            destinationAppName: dto.destinationAppName,
            destinationURL: dto.destinationURL,
            insertionMethod: dto.insertionMethod,
            originEdgeId: dto.originEdgeId,
            attribution: dto.attribution,
            metrics: dto.metrics
        )
        model.heardText = dto.heardText
        model.editedText = dto.editedText
        model.editedTextRevision = dto.editedTextRevision ?? 0
        model.id = dto.id
        model.timestamp = dto.timestamp
        return model
    }

    private static func statsRow(in context: ModelContext) throws -> DictationStats {
        if let existing = try context.fetch(FetchDescriptor<DictationStats>()).first {
            return existing
        }
        let stats = DictationStats()
        context.insert(stats)
        return stats
    }

    private static func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

@MainActor final class LocalDictionaryRepository: DictionaryRepository, DictionarySyncStore {
    private let container: ModelContainer
    private let outbox: SyncOutbox
    var onChange: (() -> Void)?
    private(set) var changeIsReplica = false

    private func notifyChange(isReplica: Bool = false) {
        changeIsReplica = isReplica
        defer { changeIsReplica = false }
        onChange?()
    }

    init(container: ModelContainer, outbox: SyncOutbox) {
        self.container = container
        self.outbox = outbox
    }

    func page(limit: Int, afterPattern: String?) async throws -> [DictionaryEntryDTO] {
        try await page(limit: limit, afterPattern: afterPattern, includeForgotten: true)
    }

    func page(limit: Int, afterPattern: String?, includeForgotten: Bool) async throws -> [DictionaryEntryDTO] {
        try await page(limit: limit, afterPattern: afterPattern, includeForgotten: includeForgotten, afterID: nil)
    }

    func page(limit: Int, afterPattern: String?, includeForgotten: Bool, afterID: UUID?) async throws -> [DictionaryEntryDTO] {
        guard limit > 0 else { return [] }
        let context = ModelContext(container)
        func fetch(_ predicate: Predicate<DictionaryEntry>, limit: Int? = nil) throws -> [DictionaryEntry] {
            var descriptor = FetchDescriptor(predicate: predicate,
                sortBy: [SortDescriptor(\DictionaryEntry.pattern, comparator: .lexical, order: .forward)])
            descriptor.fetchLimit = limit
            return try context.fetch(descriptor)
        }
        func ordered(_ rows: [DictionaryEntry]) -> [DictionaryEntry] {
            rows.sorted { $0.pattern == $1.pattern ? $0.id.uuidString < $1.id.uuidString : $0.pattern < $1.pattern }
        }
        var rows: [DictionaryEntry] = []
        if let afterPattern, let afterID {
            rows = ordered(try fetch(#Predicate { $0.pattern == afterPattern && (includeForgotten || !$0.isForgotten) })
                .filter { $0.id.uuidString > afterID.uuidString })
        }
        if rows.count < limit {
            let remaining = limit - rows.count
            let predicate: Predicate<DictionaryEntry>
            if let afterPattern {
                predicate = #Predicate { $0.pattern > afterPattern && (includeForgotten || !$0.isForgotten) }
            } else {
                predicate = #Predicate { includeForgotten || !$0.isForgotten }
            }
            var next = try fetch(predicate, limit: remaining + 1)
            if next.count > remaining, next[remaining - 1].pattern == next[remaining].pattern {
                let boundary = next[remaining - 1].pattern
                next = next.filter { $0.pattern < boundary } + (try fetch(#Predicate {
                    $0.pattern == boundary && (includeForgotten || !$0.isForgotten)
                }))
            }
            rows += ordered(next)
        }
        return encodedBudgetPage(Array(rows.prefix(limit)).map(DictionaryEntryDTO.init), budget: RepoRequestLimits.pageByteBudget)
    }

    func upsert(_ entries: [DictionaryEntryDTO]) async throws {
        let saved = try applyUpsert(entries)
        if outbox.enabled {
            try outbox.enqueue(.dictionaryUpsert(saved))
        }
        notifyChange()
    }

    func delete(ids: [UUID]) async throws {
        try applyDelete(ids)
        if outbox.enabled {
            try outbox.enqueue(.dictionaryDelete(ids: ids))
        }
        notifyChange()
    }

    // MARK: - DictionarySyncStore

    func replaceAll(with entries: [DictionaryEntryDTO]) async throws {
        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<DictionaryEntry>())
        let wanted = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var changed = false
        for model in existing {
            if let dto = wanted[model.id] {
                let previous = DictionaryEntryDTO(model)
                Self.apply(dto, to: model)
                if DictionaryEntryDTO(model) != previous { changed = true }
            } else if !model.isForgotten {
                context.delete(model)
                changed = true
            }
        }
        let present = Set(existing.map(\.id))
        for dto in entries where !present.contains(dto.id) {
            let model = DictionaryEntry(pattern: dto.pattern, replacement: dto.replacement, isVocabulary: dto.isVocabulary)
            model.id = dto.id
            Self.apply(dto, to: model)
            context.insert(model)
            changed = true
        }
        guard changed else { return }
        try context.save()
        notifyChange(isReplica: true)
    }

    private func applyUpsert(_ entries: [DictionaryEntryDTO]) throws -> [DictionaryEntryDTO] {
        let context = ModelContext(container)
        var saved: [DictionaryEntryDTO] = []
        for var dto in entries {
            // A deliberate manual/import add can restore a previously forgotten
            // spelling. Reuse its id so the outbox clears the same tombstone.
            let requestedID = dto.id
            let alreadyExists = try context.fetchCount(FetchDescriptor<DictionaryEntry>(predicate: #Predicate { $0.id == requestedID })) > 0
            if !alreadyExists, dto.origin != "learned", dto.isForgotten != true {
                let pattern = dto.pattern
                let vocabulary = dto.isVocabulary
                let forgotten = FetchDescriptor<DictionaryEntry>(predicate: #Predicate {
                    $0.isForgotten && $0.isVocabulary == vocabulary
                })
                if let row = try context.fetch(forgotten).sorted(by: { $0.id.uuidString < $1.id.uuidString }).first(where: {
                    $0.pattern.caseInsensitiveCompare(pattern) == .orderedSame
                }) {
                    dto.id = row.id
                    dto.isForgotten = false
                }
            }
            saved.append(dto)
            let dtoId = dto.id
            let descriptor = FetchDescriptor<DictionaryEntry>(predicate: #Predicate { $0.id == dtoId })
            if let existing = try context.fetch(descriptor).first {
                Self.apply(dto, to: existing)
            } else {
                let model = DictionaryEntry(pattern: dto.pattern, replacement: dto.replacement, isVocabulary: dto.isVocabulary)
                model.id = dto.id
                Self.apply(dto, to: model)
                context.insert(model)
            }
        }
        try context.save()
        return saved
    }

    private func applyDelete(_ ids: [UUID]) throws {
        let context = ModelContext(container)
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<DictionaryEntry>(predicate: #Predicate { idSet.contains($0.id) })
        for entry in try context.fetch(descriptor) {
            if entry.origin == "learned" { entry.isForgotten = true }
            else { context.delete(entry) }
        }
        try context.save()
    }

    private static func apply(_ dto: DictionaryEntryDTO, to model: DictionaryEntry) {
        // Omitted metadata from an old peer cannot revive a forgotten row.
        // Undo and a deliberate manual add explicitly clear it.
        guard !model.isForgotten || dto.isForgotten == false else { return }
        update(\.pattern, of: model, to: dto.pattern)
        update(\.replacement, of: model, to: dto.replacement)
        update(\.isVocabulary, of: model, to: dto.isVocabulary)
        if let value = dto.isStarred { update(\.isStarred, of: model, to: value) }
        if let value = dto.useCount { update(\.useCount, of: model, to: max(model.useCount, value)) }
        if let value = dto.lastUsedAt { update(\.lastUsedAt, of: model, to: max(model.lastUsedAt ?? .distantPast, value)) }
        if let value = dto.origin { update(\.origin, of: model, to: value) }
        if let value = dto.isForgotten { update(\.isForgotten, of: model, to: value) }
    }

    /// Writes only a real difference, because SwiftData counts an equal value
    /// as an edit. A sync that changes nothing must leave its context clean:
    /// on macOS 15, rolling back such edits keeps the context, and with it the
    /// store, alive.
    private static func update<Value: Equatable>(
        _ field: ReferenceWritableKeyPath<DictionaryEntry, Value>, of model: DictionaryEntry, to value: Value
    ) {
        if model[keyPath: field] != value { model[keyPath: field] = value }
    }

    /// Main-Mac-only counters: one quiet save, no notification or outbox.
    func applyUsage(_ counts: [UUID: DictionaryUsage]) throws {
        let context = ModelContext(container)
        let ids = Set(counts.keys)
        let descriptor = FetchDescriptor<DictionaryEntry>(predicate: #Predicate { ids.contains($0.id) })
        var changed = false
        for row in try context.fetch(descriptor) where !row.isForgotten {
            guard let usage = counts[row.id] else { continue }
            row.useCount = min(Int.max - usage.count, row.useCount) + usage.count
            row.lastUsedAt = max(row.lastUsedAt ?? .distantPast, usage.lastUsedAt)
            changed = true
        }
        guard changed else { return }
        try context.save()
    }
}

@MainActor final class LocalCoreSettingsRepository: CoreSettingsRepository {
    var onChange: (() -> Void)?

    func get() async throws -> CoreSettingsDTO {
        AppSettings.shared.mirroredSettings
    }

    func set(_ patch: CoreSettingsPatch) async throws {
        if let id = patch.micOwnerEdgeID, let problem = RepoServer.validateMicOwnerEdgeID(id) {
            throw RepositoryError.unavailable(problem)
        }
        if let ids = patch.vocabularyPacksOn, !VocabularyPackCatalog.validSelection(ids) {
            throw RepositoryError.unavailable("Vocabulary pack choices are not valid.")
        }
        if let ids = patch.vocabularyPacksOff, !VocabularyPackCatalog.validSelection(ids) {
            throw RepositoryError.unavailable("Vocabulary pack choices are not valid.")
        }
        // Everything is checked before anything changes: half a patch could
        // turn history saving off and then fail on a later field.
        if let json = patch.workspaceLaunchJSON, WorkspaceLaunchConfig.decode(json) == nil {
            throw RepositoryError.unavailable("Workspaces settings are not valid.")
        }
        var level: RefineLevel?
        if let refineLevel = patch.refineLevel {
            guard let stored = RefineLevel.storedValue(refineLevel) else {
                throw RepositoryError.unavailable("Unknown refine level \(refineLevel).")
            }
            level = stored
        }
        if let surfacePolicyJSON = patch.surfacePolicyJSON {
            guard let data = surfacePolicyJSON.data(using: .utf8),
                  (try? JSONDecoder().decode(SurfacePolicy.self, from: data)) != nil else {
                throw RepositoryError.unavailable("Surface policy is not valid JSON.")
            }
        }
        if let setupRoutingJSON = patch.setupRoutingJSON, SetupRouting.decode(setupRoutingJSON) == nil {
            throw RepositoryError.unavailable("Setup routing is not valid JSON.")
        }
        if let voiceLaunchJSON = patch.voiceLaunchJSON {
            guard let config = VoiceLaunchConfig.decode(voiceLaunchJSON) else {
                throw RepositoryError.unavailable("Commands settings are not valid.")
            }
            if let problem = config.validate() { throw RepositoryError.unavailable(problem) }
        }
        let settings = AppSettings.shared
        if let level { settings.refineLevel = level }
        if let customSystemPrompt = patch.customSystemPrompt { settings.customSystemPrompt = customSystemPrompt }
        if let persistHistory = patch.persistHistory { settings.persistHistory = persistHistory }
        if let surfacePolicyJSON = patch.surfacePolicyJSON { settings.cachedSurfacePolicyJSON = surfacePolicyJSON }
        if let setupRoutingJSON = patch.setupRoutingJSON { settings.setupRoutingJSON = setupRoutingJSON }
        if let voiceLaunchJSON = patch.voiceLaunchJSON { settings.voiceLaunchJSON = voiceLaunchJSON }
        if let reset = patch.workspaceLaunchJSON { settings.workspaceLaunchJSON = reset }
        if let value = patch.vocabularyPacksAutomatic { settings.vocabularyPacksAutomatic = value }
        if let ids = patch.vocabularyPacksOn { settings.vocabularyPacksOn = ids }
        if let ids = patch.vocabularyPacksOff { settings.vocabularyPacksOff = ids }
        if let learn = patch.learnFromCorrections { settings.learnFromCorrections = learn }
        if let id = patch.micOwnerEdgeID { settings.micOwnerEdgeID = id }
        onChange?()
    }
}

/// `SyncOutbox` over `SyncOutboxItem` rows in the same store.
@MainActor final class LocalSyncOutbox: SyncOutbox {
    private let container: ModelContainer
    var enabled = false

    init(container: ModelContainer) {
        self.container = container
    }

    func enqueue(_ request: RepoRequest) throws {
        let context = ModelContext(container)
        try enqueue(request, in: context)
        try context.save()
    }

    func enqueue(_ request: RepoRequest, in context: ModelContext) throws {
        switch request {
        case .historyDelete(let ids):
            for chunk in ids.chunked(RepoRequestLimits.maxIdsPerRequest) {
                context.insert(SyncOutboxItem(kind: .historyDelete, payload: try JSONEncoder().encode(chunk)))
            }
        case .dictionaryUpsert(let entries):
            // A batch over the Core's limits would be refused, then parked as
            // failed for good: 100 full-length entries still fit one frame.
            for chunk in entries.chunked(100) {
                context.insert(SyncOutboxItem(kind: .dictionaryUpsert, payload: try JSONEncoder().encode(chunk)))
            }
        case .dictionaryDelete(let ids):
            for chunk in ids.chunked(RepoRequestLimits.maxIdsPerRequest) {
                context.insert(SyncOutboxItem(kind: .dictionaryDelete, payload: try JSONEncoder().encode(chunk)))
            }
        default:
            return
        }
    }

    func pending(limit: Int) throws -> [SyncOutboxEntry] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<SyncOutboxItem>(predicate: #Predicate { $0.failedAt == nil })
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .forward)]
        descriptor.fetchLimit = limit
        let decoder = JSONDecoder()
        return try context.fetch(descriptor).compactMap { item in
            let request: RepoRequest?
            switch SyncOutboxItem.Kind(rawValue: item.kind) {
            case .historyDelete:
                request = (try? decoder.decode([UUID].self, from: item.payload)).map { .historyDelete(ids: $0) }
            case .dictionaryUpsert:
                request = (try? decoder.decode([DictionaryEntryDTO].self, from: item.payload)).map { .dictionaryUpsert($0) }
            case .dictionaryDelete:
                request = (try? decoder.decode([UUID].self, from: item.payload)).map { .dictionaryDelete(ids: $0) }
            case nil:
                request = nil
            }
            guard let request else { return nil }
            return SyncOutboxEntry(id: item.id, createdAt: item.createdAt, request: request)
        }
    }

    func markFailed(id: UUID, message: String) throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<SyncOutboxItem>(predicate: #Predicate { $0.id == id })
        guard let item = try context.fetch(descriptor).first else { return }
        item.failedAt = Date()
        item.failureMessage = message
        try context.save()
    }

    func remove(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let context = ModelContext(container)
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<SyncOutboxItem>(predicate: #Predicate { idSet.contains($0.id) })
        for item in try context.fetch(descriptor) {
            context.delete(item)
        }
        try context.save()
    }

    func count() throws -> Int {
        let context = ModelContext(container)
        return try context.fetchCount(FetchDescriptor<SyncOutboxItem>(predicate: #Predicate { $0.failedAt == nil }))
    }
}

extension Repositories {
    static func make(container: ModelContainer) -> Repositories {
        let outbox = LocalSyncOutbox(container: container)
        let history = LocalHistoryRepository(container: container, outbox: outbox)
        let dictionary = LocalDictionaryRepository(container: container, outbox: outbox)
        return Repositories(
            history: history,
            dictionary: dictionary,
            settings: LocalCoreSettingsRepository(),
            historySync: history,
            dictionarySync: dictionary,
            outbox: outbox
        )
    }

    /// The schema every store — on disk, in memory, in tests — is built with.
    nonisolated static var schema: Schema { DictatorSchema.current }
}

/// Kept outside any actor so `PersistenceLoader` (nonisolated) can build a
/// container from it at launch.
enum DictatorSchema {
    static var current: Schema {
        Schema([
            DictationEntry.self,
            DictationStats.self,
            DictionaryEntry.self,
            SyncOutboxItem.self,
            HistoryDeletion.self,
        ])
    }
}

/// One `sync:`-prefixed line per persistence/replication event in
/// `~/Library/Logs/Dictator/hotkey.log` (the app's one diagnostics file) so
/// "did it save, did it sync" is answerable after the fact — before this,
/// the log only covered hotkeys and pastes and a silent non-save left no trace.
enum SyncDiagnostics {
    static func log(_ line: String) {
        HotkeyService.recordDiagnostics("sync: " + line)
    }
}

// MARK: - Byte-budgeted pagination

/// Encodes `items` one at a time and keeps appending while the running JSON
/// array size (item bytes + `,`/`[`/`]` overhead) stays within `budget`.
/// Always includes at least the first item when `items` isn't empty, even
/// if that item's own encoded size alone exceeds `budget` — a caller that
/// can shrink an oversized item (history's `text` truncation) detects that
/// case by re-measuring the returned single item against `budget` itself.
func encodedBudgetPage<T: Encodable>(_ items: [T], budget: Int) -> [T] {
    guard !items.isEmpty else { return [] }
    let encoder = JSONEncoder()
    var result: [T] = []
    var total = 2 // "[" + "]"
    for item in items {
        let size = (try? encoder.encode(item).count) ?? Int.max
        let addition = size + (result.isEmpty ? 0 : 1) // leading comma after the first
        if !result.isEmpty, total + addition > budget {
            break
        }
        total += addition
        result.append(item)
        if result.count == 1, total > budget {
            // The first item alone already exceeds the budget — stop so the
            // caller can decide how (or whether) to shrink it.
            break
        }
    }
    return result
}

// MARK: - Model → DTO

extension DictationEntryDTO {
    init(_ entry: DictationEntry) {
        self.init(
            id: entry.id,
            timestamp: entry.timestamp,
            text: entry.text,
            durationSeconds: entry.durationSeconds,
            inferenceMs: entry.inferenceMs,
            wordCount: entry.wordCount,
            modality: entry.modality,
            source: entry.source,
            destinationAppBundleId: entry.destinationAppBundleId,
            destinationAppName: entry.destinationAppName,
            destinationURL: entry.destinationURL,
            insertionMethod: entry.insertionMethod,
            originEdgeId: entry.originEdgeId,
            syncedAt: entry.syncedAt,
            truncated: nil,
            toolId: entry.toolId,
            captureSource: entry.captureSource,
            remoteHost: entry.remoteHost,
            surfaceLabel: entry.surfaceLabel,
            captureReason: entry.captureReason,
            workingDirectory: entry.workingDirectory,
            sessionId: entry.sessionId,
            importBatchId: entry.importBatchId,
            typingSeconds: entry.typingSeconds,
            latencyMs: entry.latencyMs,
            polishModel: entry.polishModel,
            firstTakeAfterLoad: entry.firstTakeAfterLoad,
            cleanupLevel: entry.cleanupLevel,
            cleanupOutcome: entry.cleanupOutcome,
            cleanupMs: entry.cleanupMs,
            heardText: entry.heardText, editedText: entry.editedText, editedTextRevision: entry.editedTextRevision
        )
    }
}

private extension DictionaryEntryDTO {
    init(_ entry: DictionaryEntry) {
        self.init(id: entry.id, pattern: entry.pattern, replacement: entry.replacement, isVocabulary: entry.isVocabulary,
                  isStarred: entry.isStarred, useCount: entry.useCount, lastUsedAt: entry.lastUsedAt, origin: entry.origin, isForgotten: entry.isForgotten)
    }
}

// MARK: - Dataset

/// What Dataset needs from this Mac's store beyond `HistoryRepository`:
/// every row at once as plain values, and bulk writes for Import history.
@MainActor
protocol HistoryDatasetStore: AnyObject {
    func datasetRows() async throws -> [DatasetRow]
    /// Inserts imported rows as-is — the capture policy doesn't apply to
    /// history the user chose to bring in. Existing or explicitly deleted
    /// IDs are skipped. New rows start pending replication like any other row.
    func insertImported(_ rows: [DictationEntryDTO]) async throws -> Int
    func existingIDs(ids: [UUID]) async throws -> Set<UUID>
    func deletionIDs(ids: [UUID]) async throws -> Set<UUID>
    func ids(forImportBatch batchID: String) async throws -> [UUID]
    func delete(ids: [UUID]) async throws
}

extension LocalHistoryRepository: HistoryDatasetStore {
    /// Read on a background context: a large store must not stall the UI.
    func datasetRows() async throws -> [DatasetRow] {
        let container = container
        return try await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            return try context.fetch(FetchDescriptor<DictationEntry>()).map { entry in
                DatasetRow(
                    id: entry.id,
                    timestamp: entry.timestamp,
                    text: entry.text,
                    wordCount: entry.wordCount,
                    modality: entry.modality,
                    durationSeconds: entry.durationSeconds,
                    source: entry.source,
                    insertionMethod: entry.insertionMethod,
                    destinationAppBundleId: entry.destinationAppBundleId,
                    destinationAppName: entry.destinationAppName,
                    destinationURL: entry.destinationURL,
                    originEdgeId: entry.originEdgeId,
                    attribution: entry.attribution,
                    metrics: entry.metrics,
                    inferenceMs: entry.inferenceMs
                )
            }
        }.value
    }

    func insertImported(_ rows: [DictationEntryDTO]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        var inserted = 0
        for start in stride(from: 0, to: rows.count, by: 1_000) {
            let chunk = Array(rows[start..<min(start + 1_000, rows.count)])
            let context = ModelContext(container)
            let wanted = Set(chunk.map(\.id))
            var descriptor = FetchDescriptor<DictationEntry>(predicate: #Predicate { wanted.contains($0.id) })
            descriptor.propertiesToFetch = [\.id]
            let present = Set(try context.fetch(descriptor).map(\.id))
            let deletionDescriptor = FetchDescriptor<HistoryDeletion>(predicate: #Predicate { wanted.contains($0.id) })
            let deleted = Set(try context.fetch(deletionDescriptor).map(\.id))
            for dto in chunk where !present.contains(dto.id) && !deleted.contains(dto.id) {
                let model = Self.newRow(from: dto, inferenceMs: nil, defaultModality: "typed", defaultSource: "import")
                context.insert(model)
                inserted += 1
            }
            try Self.save(context)
        }
        SyncDiagnostics.log("history: imported \(inserted) rows")
        onChange?()
        return inserted
    }

    func ids(forImportBatch batchID: String) async throws -> [UUID] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<DictationEntry>(predicate: #Predicate { $0.importBatchId == batchID })
        descriptor.propertiesToFetch = [\.id]
        return try context.fetch(descriptor).map(\.id)
    }
}
