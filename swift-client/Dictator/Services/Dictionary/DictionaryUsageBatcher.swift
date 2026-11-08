import Foundation

struct DictionaryUsage: Equatable {
    var count: Int
    var lastUsedAt: Date
}

/// Only the main/standalone Mac calls this. A take queues counters in memory;
/// one quiet transaction happens per flush, without a dictionary notification.
@MainActor final class DictionaryUsageBatcher {
    private(set) var pending: [UUID: DictionaryUsage] = [:]
    private var flushTask: Task<Void, Never>?
    var write: ([UUID: DictionaryUsage]) throws -> Void
    private let isMain: () -> Bool
    let interval: TimeInterval

    init(interval: TimeInterval = 60, isMain: @escaping () -> Bool = { true }, write: @escaping ([UUID: DictionaryUsage]) throws -> Void) {
        self.isMain = isMain
        self.interval = interval
        self.write = write
    }

    func record(text: String, entries: [DictionaryEntryDTO], at date: Date = Date()) {
        guard isMain() else { discard(); return }
        let lower = text.lowercased()
        for entry in entries where entry.isForgotten != true {
            let term = (entry.replacement.isEmpty ? entry.pattern : entry.replacement).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            // Unicode word boundaries keep substrings (e.g. Arc in March) out.
            let pattern = "(?<![\\p{L}\\p{M}\\p{N}_])" + NSRegularExpression.escapedPattern(for: term.lowercased()) + "(?![\\p{L}\\p{M}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let count = regex.numberOfMatches(in: lower, range: NSRange(lower.startIndex..., in: lower))
            guard count > 0 else { continue }
            let old = pending[entry.id]?.count ?? 0
            pending[entry.id] = DictionaryUsage(count: min(Int.max - count, old) + count, lastUsedAt: max(pending[entry.id]?.lastUsedAt ?? .distantPast, date))
        }
        guard !pending.isEmpty, flushTask == nil else { return }
        flushTask = Task { [weak self, interval] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    /// Synchronous so applicationWillTerminate can commit before process exit.
    func flush() {
        guard isMain() else { discard(); return }
        flushTask?.cancel(); flushTask = nil
        guard !pending.isEmpty else { return }
        do { try write(pending); pending.removeAll() }
        catch { SyncDiagnostics.log("dictionary: usage-write failed count=\(pending.count)") }
    }

    func discard() { flushTask?.cancel(); flushTask = nil; pending.removeAll() }
}
