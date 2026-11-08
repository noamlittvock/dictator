import Foundation
import SwiftData

// Every Mac reads and writes only its own SwiftData store through these
// protocols. `LocalSwiftDataRepositories.swift` is the one production
// conformer; `HistorySyncEngine` keeps an Edge's store converged with the
// Core's over `CoreSyncClient` (RepoRequest/RepoResult), so a UI never has
// to know whether a Core is reachable right now — it always works, and
// anything written offline is replicated later.

@MainActor
protocol HistoryRepository: AnyObject {
    /// Newest first. `before` is an exclusive `(timestamp, id)` cursor for
    /// the next page — see `HistoryCursor`.
    func page(limit: Int, before: HistoryCursor?) async throws -> [DictationEntryDTO]
    /// Whole-store reads for explicit export/cleanup. The local repository
    /// preserves full text. The default loops wire pages until an empty page,
    /// since a short page may mean the byte budget was reached.
    func allEntries() async throws -> [DictationEntryDTO]
    /// Local browsing: filters cover the store, not just already loaded rows.
    func browsePage(limit: Int, before: HistoryCursor?, filter: HistoryFilter) async throws -> [DictationEntryDTO]
    func destinationNames() async throws -> [String]
    func stats() async throws -> DictationStatsDTO?
    /// Deletes locally and (in Edge role) queues the delete for the Core.
    func delete(ids: [UUID]) async throws
    /// Applies the persist gate and stats update, writes locally, and
    /// leaves the row pending replication (`syncedAt == nil`).
    func entry(id: UUID) async throws -> DictationEntryDTO?
    func saveEditedText(_ text: String, id: UUID) async throws
    func saveManualEdit(_ text: String, id: UUID, expectedText: String) async throws -> Bool
    func record(_ entry: HistoryRecordDTO) async throws
    /// Owned by `RepositoryHub` — nothing else may assign this. Observe
    /// `RepositoryHub.historyVersion`/`.version` instead.
    var onChange: (() -> Void)? { get set }
    var changeIsReplica: Bool { get }
}

extension HistoryRepository {
    var changeIsReplica: Bool { false }
    func entry(id: UUID) async throws -> DictationEntryDTO? {
        try await allEntries().first { $0.id == id }
    }
    func saveEditedText(_ text: String, id: UUID) async throws {}
    func saveManualEdit(_ text: String, id: UUID, expectedText: String) async throws -> Bool { false }
    func browsePage(limit: Int, before: HistoryCursor?, filter: HistoryFilter) async throws -> [DictationEntryDTO] {
        guard limit > 0 else { return [] }
        if filter == .all { return try await page(limit: limit, before: before) }
        var result: [DictationEntryDTO] = []
        var cursor = before
        while result.count < limit {
            try Task.checkCancellation()
            let batch = try await page(limit: limit, before: cursor)
            guard let last = batch.last else { break }
            result.append(contentsOf: batch.filter { filter.matches($0) }.prefix(limit - result.count))
            cursor = last.cursor
        }
        return result
    }

    func destinationNames() async throws -> [String] {
        Array(Set(try await allEntries().compactMap(\.destinationDisplayName))).sorted()
    }

    func allEntries() async throws -> [DictationEntryDTO] {
        var all: [DictationEntryDTO] = []
        var before: HistoryCursor?
        while true {
            let batch = try await page(limit: RepoRequestLimits.historyPageSize, before: before)
            guard let last = batch.last else { break }
            all.append(contentsOf: batch)
            before = last.cursor
        }
        return all
    }
}

@MainActor
protocol DictionaryRepository: AnyObject {
    /// Ascending lexically by (pattern, id). The optional id breaks ties.
    func page(limit: Int, afterPattern: String?) async throws -> [DictionaryEntryDTO]
    func page(limit: Int, afterPattern: String?, includeForgotten: Bool) async throws -> [DictionaryEntryDTO]
    func page(limit: Int, afterPattern: String?, includeForgotten: Bool, afterID: UUID?) async throws -> [DictionaryEntryDTO]
    /// Loops `page()` until an empty page signals the end. Default
    /// implementation below — conformers only need `page()`.
    func entries() async throws -> [DictionaryEntryDTO]
    /// Insert or update by `id`; in Edge role also queued for the Core.
    func upsert(_ entries: [DictionaryEntryDTO]) async throws
    /// Deletes locally; in Edge role also queued for the Core.
    func delete(ids: [UUID]) async throws
    /// Owned by `RepositoryHub` — see `HistoryRepository.onChange`.
    var onChange: (() -> Void)? { get set }
    var changeIsReplica: Bool { get }
}

extension DictionaryRepository {
    var changeIsReplica: Bool { false }
    func page(limit: Int, afterPattern: String?, includeForgotten: Bool) async throws -> [DictionaryEntryDTO] {
        try await page(limit: limit, afterPattern: afterPattern, includeForgotten: includeForgotten, afterID: nil)
    }

    func page(limit: Int, afterPattern: String?, includeForgotten: Bool, afterID: UUID?) async throws -> [DictionaryEntryDTO] {
        // Compatibility for injected repositories which only implement legacy
        // paging. Filter before applying the requested limit, as production does.
        var rows: [DictionaryEntryDTO] = []
        var cursor: String?
        while true {
            let batch = try await page(limit: RepoRequestLimits.dictionaryPageSize, afterPattern: cursor)
            guard let last = batch.last else { break }
            rows += batch
            cursor = last.pattern
        }
        let filtered = rows.filter { row in
            guard includeForgotten || row.isForgotten != true else { return false }
            guard let afterPattern else { return true }
            return row.pattern > afterPattern || (row.pattern == afterPattern && afterID.map { row.id.uuidString > $0.uuidString } == true)
        }.sorted { $0.pattern == $1.pattern ? $0.id.uuidString < $1.id.uuidString : $0.pattern < $1.pattern }
        return encodedBudgetPage(Array(filtered.prefix(max(0, limit))), budget: RepoRequestLimits.pageByteBudget)
    }

    func entries() async throws -> [DictionaryEntryDTO] {
        var all: [DictionaryEntryDTO] = []
        var after: String?
        var afterID: UUID?
        while true {
            let batch = try await page(limit: RepoRequestLimits.dictionaryPageSize, afterPattern: after, includeForgotten: true, afterID: afterID)
            guard let last = batch.last else { break }
            all.append(contentsOf: batch)
            after = last.pattern
            afterID = last.id
        }
        return all
    }
}

@MainActor
protocol CoreSettingsRepository: AnyObject {
    func get() async throws -> CoreSettingsDTO
    func set(_ patch: CoreSettingsPatch) async throws
    /// Owned by `RepositoryHub` — see `HistoryRepository.onChange`.
    var onChange: (() -> Void)? { get set }
}

// MARK: - Replication seams

/// The extra, sync-only surface `HistorySyncEngine` needs on the local
/// history store. Kept off `HistoryRepository` so the UI-facing protocol
/// stays small and so a test fake for the feed never has to implement it.
@MainActor
protocol HistorySyncStore: AnyObject {
    /// `(id, timestamp)` of every row, plus whether it is still pending.
    func localManifest() async throws -> [(item: HistoryManifestItem, pending: Bool)]
    /// Live rows and deletion proofs, newest first and byte-budgeted —
    /// what the Core serves. Deletion markers use their deletion timestamp.
    func manifestPage(limit: Int, before: HistoryCursor?) async throws -> [HistoryManifestItem]
    /// Id-only local presence check. This must not materialize or encode full
    /// history rows, because full-row fetches are byte-budgeted.
    func existingIDs(ids: [UUID]) async throws -> Set<UUID>
    /// All local deletion intent, including deletes made while standalone.
    /// A full sync reconciles this against the main Mac's durable proof.
    func localDeletions() async throws -> [HistoryManifestItem]
    /// Durable explicit deletion IDs already known here.
    func deletionIDs(ids: [UUID]) async throws -> Set<UUID>
    /// Persist remote deletion proof and remove matching rows atomically,
    /// including pending rows. Never echoes a delete back into the outbox.
    func applyDeletions(_ items: [HistoryManifestItem]) async throws
    func fetch(ids: [UUID]) async throws -> [DictationEntryDTO]
    /// Rows this Mac wrote that no Core has acknowledged yet, oldest first.
    func pendingSync(limit: Int, excluding skipped: Set<UUID>) async throws -> [DictationEntryDTO]
    /// How many rows are still pending (`syncedAt == nil`).
    func pendingCount() async throws -> Int
    func markSynced(ids: [UUID]) async throws
    /// Inserts every entry whose id is not already present, keeping the
    /// given ids/timestamps and marking them synced (they arrived through
    /// replication). Returns how many were inserted. `asReplica: true`
    /// skips the stats bump (a row pulled from the Core was already counted
    /// there); the Core itself passes `false` so an Edge's upload counts
    /// once, on the Core.
    @discardableResult
    func insertMissing(_ entries: [DictationEntryDTO], asReplica: Bool) async throws -> Int
    /// Deletes rows because the Core no longer has them — never queues an
    /// outbox delete (that would echo the Core's own deletion back at it).
    func deleteReplicas(ids: [UUID]) async throws
    /// Overwrites the local aggregate stats with the Core's.
    func replaceStats(_ stats: DictationStatsDTO) async throws
}

@MainActor
protocol DictionarySyncStore: AnyObject {
    /// Makes the local dictionary exactly `entries` (insert/update/delete)
    /// without touching the outbox.
    func replaceAll(with entries: [DictionaryEntryDTO]) async throws
}

/// One queued local mutation still to be replayed against the Core.
struct SyncOutboxEntry: Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    var request: RepoRequest
}

/// Durable queue of history deletes and dictionary edits made on an Edge
/// (see `SyncOutboxItem`). `enabled` is flipped by the coordinator with the
/// role: only an Edge has a Core to replay against, so only an Edge queues.
@MainActor
protocol SyncOutbox: AnyObject {
    var enabled: Bool { get set }
    func enqueue(_ request: RepoRequest) throws
    /// Inserts into an existing SwiftData transaction so a history delete
    /// and its outbox record save atomically.
    func enqueue(_ request: RepoRequest, in context: ModelContext) throws
    func pending(limit: Int) throws -> [SyncOutboxEntry]
    func markFailed(id: UUID, message: String) throws
    func remove(ids: [UUID]) throws
    func count() throws -> Int
}

/// One bundle the app passes around: this Mac's store, plus the sync-only
/// views of it and its outbox.
@MainActor
final class Repositories {
    let history: HistoryRepository
    let dictionary: DictionaryRepository
    let settings: CoreSettingsRepository
    let historySync: HistorySyncStore
    let dictionarySync: DictionarySyncStore
    let outbox: SyncOutbox

    init(
        history: HistoryRepository,
        dictionary: DictionaryRepository,
        settings: CoreSettingsRepository,
        historySync: HistorySyncStore,
        dictionarySync: DictionarySyncStore,
        outbox: SyncOutbox
    ) {
        self.history = history
        self.dictionary = dictionary
        self.settings = settings
        self.historySync = historySync
        self.dictionarySync = dictionarySync
        self.outbox = outbox
    }

    /// For tests that drive a view model against fakes and never sync.
    convenience init(history: HistoryRepository, dictionary: DictionaryRepository, settings: CoreSettingsRepository) {
        self.init(
            history: history, dictionary: dictionary, settings: settings,
            historySync: InertHistorySyncStore(), dictionarySync: InertDictionarySyncStore(), outbox: InertSyncOutbox()
        )
    }
}

/// No-op sync seams for the fake-backed `Repositories` tests build.
@MainActor final class InertHistorySyncStore: HistorySyncStore {
    func localManifest() async throws -> [(item: HistoryManifestItem, pending: Bool)] { [] }
    func manifestPage(limit: Int, before: HistoryCursor?) async throws -> [HistoryManifestItem] { [] }
    func existingIDs(ids: [UUID]) async throws -> Set<UUID> { [] }
    func localDeletions() async throws -> [HistoryManifestItem] { [] }
    func deletionIDs(ids: [UUID]) async throws -> Set<UUID> { [] }
    func applyDeletions(_ items: [HistoryManifestItem]) async throws {}
    func fetch(ids: [UUID]) async throws -> [DictationEntryDTO] { [] }
    func pendingSync(limit: Int, excluding skipped: Set<UUID>) async throws -> [DictationEntryDTO] { [] }
    func pendingCount() async throws -> Int { 0 }
    func markSynced(ids: [UUID]) async throws {}
    func insertMissing(_ entries: [DictationEntryDTO], asReplica: Bool) async throws -> Int { 0 }
    func deleteReplicas(ids: [UUID]) async throws {}
    func replaceStats(_ stats: DictationStatsDTO) async throws {}
}

@MainActor final class InertDictionarySyncStore: DictionarySyncStore {
    func replaceAll(with entries: [DictionaryEntryDTO]) async throws {}
}

@MainActor final class InertSyncOutbox: SyncOutbox {
    var enabled = false
    func enqueue(_ request: RepoRequest) throws {}
    func enqueue(_ request: RepoRequest, in context: ModelContext) throws {}
    func pending(limit: Int) throws -> [SyncOutboxEntry] { [] }
    func markFailed(id: UUID, message: String) throws {}
    func remove(ids: [UUID]) throws {}
    func count() throws -> Int { 0 }
}

enum RepositoryError: Error, LocalizedError, Equatable {
    /// The local store (no `ModelContainer`) or repository is not usable.
    case unavailable(String)
    /// The remote Core answered with `RepoResult.error`.
    case remote(String)
    /// No `RepoResult` arrived within the transport's timeout.
    case timeout

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .remote(let message): message
        case .timeout: "The main Mac didn’t answer in time."
        }
    }
}

/// Feed filters are local UI queries; they do not change the replication protocol.
enum HistoryFilter: Equatable, Sendable {
    case all, spoken, typed, destination(String)

    init(id: String) {
        switch id {
        case "spoken": self = .spoken
        case "typed": self = .typed
        default:
            self = id.hasPrefix("destination:") ? .destination(String(id.dropFirst("destination:".count))) : .all
        }
    }

    var id: String {
        switch self {
        case .all: "all"
        case .spoken: "spoken"
        case .typed: "typed"
        case .destination(let name): "destination:\(name)"
        }
    }

    var option: HistoryFilterOption {
        switch self {
        case .all: HistoryFilterOption(id: id, label: "All")
        case .spoken: HistoryFilterOption(id: id, label: "Spoken")
        case .typed: HistoryFilterOption(id: id, label: "Typed")
        case .destination(let name): HistoryFilterOption(id: id, label: name)
        }
    }

    func matches(_ entry: DictationEntryDTO) -> Bool {
        matches(modality: entry.modality, destination: entry.destinationDisplayName)
    }

    func matches(modality: String?, destination: String?) -> Bool {
        switch self {
        case .all: true
        case .spoken: modality != "typed"
        case .typed: modality == "typed"
        case .destination(let name): destination == name
        }
    }

    static func destinationName(toolID: String?, appName: String?, bundleID: String?, catalog: ToolCatalog) -> String? {
        if let tool = toolID.flatMap({ catalog.tool(id: $0) }) { return tool.name }
        if let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        return nil
    }
}

struct HistoryFilterOption {
    let id: String
    let label: String
}

extension DictationEntryDTO {
    var destinationDisplayName: String? {
        HistoryFilter.destinationName(toolID: toolId, appName: destinationAppName,
                                      bundleID: destinationAppBundleId, catalog: ToolCatalog.shared)
    }
}
