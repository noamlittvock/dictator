import Foundation
import SwiftData

/// One mutation this Mac made locally that still has to reach its Core
/// (see `HistorySyncEngine`): a history delete, or a dictionary upsert or
/// delete. New history entries are not queued here — an entry is its own
/// outbox item via `DictationEntry.syncedAt == nil`. Persisted in the same
/// store as the data it describes so a delete and its outbox item land (or
/// fail) in one transaction, and so nothing is forgotten across a relaunch.
@Model
final class SyncOutboxItem {
    enum Kind: String {
        case historyDelete
        case dictionaryUpsert
        case dictionaryDelete
    }

    var id: UUID
    var createdAt: Date
    var kind: String
    /// JSON: `[UUID]` for the delete kinds, `[DictionaryEntryDTO]` for
    /// `dictionaryUpsert`.
    var payload: Data
    /// A remote validation error is durable but not retryable until the
    /// underlying local value is repaired.
    var failedAt: Date?
    var failureMessage: String?

    init(kind: Kind, payload: Data) {
        self.id = UUID()
        self.createdAt = Date()
        self.kind = kind.rawValue
        self.payload = payload
        self.failedAt = nil
        self.failureMessage = nil
    }
}


/// Durable, content-free proof that a user explicitly deleted this history ID.
/// Kept indefinitely so an offline peer cannot resurrect it with an old upload.
/// Written in the same transaction as the row deletion and optional outbox item.
@Model
final class HistoryDeletion {
    var id: UUID
    var deletedAt: Date
    /// A single indexed order key lets a page end inside a bulk deletion's
    /// shared timestamp without loading that entire timestamp group.
    @Attribute(.unique) var sortKey: String

    init(id: UUID, deletedAt: Date) {
        self.id = id
        self.deletedAt = deletedAt
        self.sortKey = Self.key(id: id, date: deletedAt)
    }

    static func key(id: UUID, date: Date) -> String {
        // IEEE doubles sort numerically after flipping positive sign bits
        // and complementing negative bits. Fixed-width hex preserves every
        // Date bit, including sub-microsecond differences, in SQLite order.
        let bits = date.timeIntervalSinceReferenceDate.bitPattern
        let sign: UInt64 = 1 << 63
        let ordered = bits & sign == 0 ? bits ^ sign : ~bits
        return String(format: "%016llX", ordered) + ":" + id.uuidString
    }
}
