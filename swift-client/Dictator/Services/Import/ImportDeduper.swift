import Foundation

struct ImportPreview: Sendable {
    /// What would be added, oldest first (undated prompts last).
    var toImport: [ImportedPrompt]
    /// Candidates already in history (same text near the same time, or an
    /// already-imported source key).
    var alreadyInHistory: Int
    /// Stable source IDs that were explicitly deleted and must stay deleted.
    var previouslyDeleted: Int = 0
    /// Repeats within the source itself.
    var duplicatesInSource: Int
    var earliest: Date?
    var latest: Date?
}

enum ImportDeduper {
    /// Existing rows and imports disagree on clocks and time zones (the old
    /// import script wrote UTC as local, exports round), so a match on text
    /// counts within this window.
    static let historyWindow: TimeInterval = 36 * 3_600
    /// Within one source, the same prompt again within this window is a
    /// replay (resumed or forked sessions, double submits) — the import
    /// script's near-duplicate compaction. Covers exact same-second repeats.
    static let sourceRepeatWindow: TimeInterval = 120

    /// Existing rows: every `DatasetRow` currently in history. A candidate is
    /// already in history when an existing row has the same normalized text
    /// (`DatasetText.normalized`) and either timestamp is nil or they are at
    /// most 36 hours apart, or when its `sourceKey` is in `importedKeys`.
    /// Within the source, repeats of the same normalized text (same source
    /// key, or at most `sourceRepeatWindow` apart, or both undated) collapse
    /// to the first. Linear in rows + candidates (dictionary lookups, binary
    /// search over each text's dates).
    static func preview(_ read: ImportReadResult, existing: [DatasetRow], importedKeys: Set<String>, deletedKeys: Set<String> = []) -> ImportPreview {
        var existingTimes: [String: [TimeInterval]] = [:]
        existingTimes.reserveCapacity(existing.count)
        for row in existing {
            existingTimes[ImportTextFilter.matchKey(row.text), default: []].append(row.timestamp.timeIntervalSince1970)
        }
        for key in existingTimes.keys {
            existingTimes[key]?.sort()
        }

        let candidates = read.prompts.enumerated().sorted { lhs, rhs in
            switch (lhs.element.timestamp, rhs.element.timestamp) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)

        var toImport: [ImportedPrompt] = []
        var alreadyInHistory = 0
        var previouslyDeleted = 0
        var duplicatesInSource = 0
        var seenKeys = Set<String>()
        /// Normalized text → time of the last kept (first-of-cluster)
        /// dated occurrence, and whether an undated one was seen.
        var lastDated: [String: TimeInterval] = [:]
        var seenUndated = Set<String>()

        for prompt in candidates {
            let text = ImportTextFilter.matchKey(prompt.text)
            let time = prompt.timestamp?.timeIntervalSince1970

            var repeatInSource = seenKeys.contains(prompt.sourceKey)
            // A prompt the user deleted must not count as the earlier copy of
            // a later one with the same words.
            if !repeatInSource, deletedKeys.contains(prompt.sourceKey) {
                seenKeys.insert(prompt.sourceKey)
                previouslyDeleted += 1
                continue
            }
            if !repeatInSource {
                if let time {
                    if let last = lastDated[text], abs(time - last) <= sourceRepeatWindow {
                        repeatInSource = true
                    } else {
                        lastDated[text] = time
                    }
                } else if !seenUndated.insert(text).inserted {
                    repeatInSource = true
                }
            }
            seenKeys.insert(prompt.sourceKey)
            if repeatInSource {
                duplicatesInSource += 1
                continue
            }

            if importedKeys.contains(prompt.sourceKey) || matchesExisting(existingTimes[text], time) {
                alreadyInHistory += 1
                continue
            }
            toImport.append(prompt)
        }

        let dates = toImport.compactMap(\.timestamp)
        return ImportPreview(
            toImport: toImport,
            alreadyInHistory: alreadyInHistory,
            previouslyDeleted: previouslyDeleted,
            duplicatesInSource: duplicatesInSource,
            earliest: dates.min(),
            latest: dates.max()
        )
    }

    /// True when `sorted` has a time within `historyWindow` of `time` (any
    /// time at all when `time` is nil).
    static func matchesExisting(_ sorted: [TimeInterval]?, _ time: TimeInterval?) -> Bool {
        guard let sorted, !sorted.isEmpty else { return false }
        guard let time else { return true }
        // First index with value >= time - window.
        var low = 0, high = sorted.count
        let floor = time - historyWindow
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < floor { low = mid + 1 } else { high = mid }
        }
        return low < sorted.count && sorted[low] <= time + historyWindow
    }
}
