import AppKit
import CryptoKit
import Foundation

/// Only vocabulary and rules enter the dictionary. Pending confirmations keep
/// salted hashes and small counts in defaults, never a second copy of words.
@MainActor final class CorrectionLearningService {
    private struct Confirmation: Codable { var count: Int; var date: Date }
    private struct Ledger: Codable {
        var salt = UUID().uuidString
        var day = Date.distantPast
        var addedToday = 0
        var pending: [String: Confirmation] = [:]
        var observations: [String] = []
    }
    private let defaults: UserDefaults
    private let key = "dictionary.correctionConfirmations.v1"
    private var ledger: Ledger
    private var tail: Task<Bool, Error>?
    static let dailyLimit = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ledger = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } ?? Ledger()
    }

    @discardableResult
    func learn(_ report: CorrectionReport, dictionary: DictionaryRepository, languages: [String],
               at now: Date = Date(), isKnownWord: ((String) -> Bool)? = nil) async throws -> Bool {
        let previous = tail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            return try await self.apply(report, dictionary: dictionary, languages: languages, at: now, isKnownWord: isKnownWord)
        }
        tail = task
        defer { if tail == task { tail = nil } }
        return try await task.value
    }

    static func reports(_ report: CorrectionReport, keepSentence: Bool, languages: [String],
                        isKnownWord: ((String) -> Bool)? = nil) -> [CorrectionReport] {
        if keepSentence && report.pairsOnly != true { return [report] }
        let checker = isKnownWord ?? { Self.isKnownWord($0, languages: languages) }
        let before = report.heard.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = report.corrected.split(whereSeparator: \.isWhitespace).map(String.init)
        guard before.count == after.count else { return [] }
        return zip(before, after).flatMap { heard, corrected in
            CorrectionLearner.substitutions(inserted: heard, edited: corrected, isKnownWord: checker).map {
                CorrectionReport(heard: $0.heard, corrected: $0.corrected, entryID: report.entryID,
                                 explicit: report.explicit, pairsOnly: true, context: report.context)
            }
        }
    }

    @discardableResult
    func receive(_ report: CorrectionReport, repositories: Repositories, settings: AppSettings,
                 isKnownWord: ((String) -> Bool)? = nil) async throws -> CorrectionOutcome {
        var context = report.context
        let row: DictationEntryDTO?
        if let id = report.entryID { row = try await repositories.history.entry(id: id) }
        else { row = nil }
        if context == nil, let row {
            context = HistoryRecordDTO(text: row.text, durationSeconds: row.durationSeconds,
                destinationAppBundleId: row.destinationAppBundleId, destinationAppName: row.destinationAppName,
                destinationURL: row.destinationURL, attribution: row.attribution).captureContext
        }
        if report.explicit != true {
            guard settings.learnFromCorrections, let context, settings.correctionObservationAllowed(for: context),
                  CorrectionLearner.ownsEdit(inserted: report.heard, edited: report.corrected) else { return CorrectionOutcome(historySaved: false, learned: false) }
        }
        var historySaved = false
        let keepSentence = context.map { settings.captureDecision(for: $0, modality: "typed").isSave } ?? false
        if report.explicit != true, keepSentence, report.pairsOnly != true, let row {
            let sameSpan = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(report.heard.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            if sameSpan { try await repositories.history.saveEditedText(report.corrected, id: row.id) }
        }
        if report.explicit == true, let selection = report.selection {
            guard let row else { throw RepositoryError.remote("This history row changed. Close this sheet and try again.") }
            let current = row.editedText ?? row.text
            let edited = try selection.replacing(in: current, heard: report.heard, with: report.corrected)
            historySaved = try await repositories.history.saveManualEdit(edited, id: row.id, expectedText: current)
        }
        let filtered = report.explicit == true ? [report] : Self.reports(report, keepSentence: keepSentence, languages: settings.dictationLanguages, isKnownWord: isKnownWord)
        var learned = false
        do {
            for item in filtered {
                if try await learn(item, dictionary: repositories.dictionary, languages: settings.dictationLanguages, isKnownWord: isKnownWord) { learned = true }
            }
        } catch {
            guard historySaved else { throw error }
            return CorrectionOutcome(historySaved: true, learned: learned, learningFailed: true)
        }
        return CorrectionOutcome(historySaved: historySaved, learned: learned)
    }

    private func apply(_ report: CorrectionReport, dictionary: DictionaryRepository, languages: [String],
                       at now: Date, isKnownWord: ((String) -> Bool)?) async throws -> Bool {
        let checker = isKnownWord ?? { Self.isKnownWord($0, languages: languages) }
        let candidates = CorrectionLearner.substitutions(inserted: report.heard, edited: report.corrected, isKnownWord: checker)
        guard !candidates.isEmpty else { return false }
        // Serialized by `tail`; observation hashes use each word pair so a
        // replay cannot count twice after typed-history consent changes.
        let checkpoint = ledger
        if !Calendar.current.isDate(ledger.day, inSameDayAs: now) { ledger.day = now; ledger.addedToday = 0 }
        ledger.pending = ledger.pending.filter { now.timeIntervalSince($0.value.date) < 30 * 86_400 }
        let entries = try await dictionary.entries()
        var writes: [DictionaryEntryDTO] = []
        for correction in candidates {
            let observation = report.entryID.map {
                digest($0.uuidString + ":" + String(report.explicit == true) + ":" +
                       CorrectionLearner.folded(correction.heard) + "\u{0}" + CorrectionLearner.folded(correction.corrected))
            }
            if let observation, ledger.observations.contains(observation) { continue }
            let term = CorrectionLearner.folded(correction.corrected)
            let restoredWord = entries.contains { $0.isForgotten != true && $0.isVocabulary &&
                CorrectionLearner.folded($0.pattern) == term }
            let forgotten = entries.contains { row in
                guard row.isForgotten == true else { return false }
                // A restored word can learn other heard-as spellings. A still
                // forgotten rule blocks only its own source once the word is back.
                return CorrectionLearner.folded(row.pattern) == term ||
                    (!restoredWord && CorrectionLearner.folded(row.replacement) == term)
            }
            guard !forgotten else { continue }
            if let observation { ledger.observations.append(observation) }
            let fingerprint = digest(CorrectionLearner.folded(correction.heard) + "\u{0}" + CorrectionLearner.folded(correction.corrected))
            let count = min(2, (ledger.pending[fingerprint]?.count ?? 0) + 1)
            ledger.pending[fingerprint] = Confirmation(count: count, date: now)
            guard ledger.addedToday < Self.dailyLimit else { continue }
            let beforeCount = writes.count
            let active = entries.filter { $0.isForgotten != true } + writes
            if !active.contains(where: { $0.isVocabulary && CorrectionLearner.folded($0.pattern) == term }) {
                writes.append(DictionaryEntryDTO(id: UUID(), pattern: correction.corrected, replacement: "", isVocabulary: true, origin: "learned"))
            }
            if (report.explicit == true || count >= 2), correction.heard != correction.corrected,
               !(entries + writes).contains(where: { !$0.isVocabulary && $0.pattern.caseInsensitiveCompare(correction.heard) == .orderedSame }) {
                writes.append(DictionaryEntryDTO(id: UUID(), pattern: correction.heard, replacement: correction.corrected, isVocabulary: false, origin: "learned"))
            }
            let remaining = Self.dailyLimit - ledger.addedToday
            let additions = Array(writes.suffix(writes.count - beforeCount).prefix(remaining))
            writes = Array(writes.prefix(beforeCount)) + additions
            ledger.addedToday += additions.count
        }
        do { if !writes.isEmpty { try await dictionary.upsert(writes) } }
        catch { ledger = checkpoint; throw error }
        ledger.observations = Array(ledger.observations.suffix(128))
        if ledger.pending.count > 64 {
            let newest = ledger.pending.sorted { $0.value.date > $1.value.date }.prefix(64)
            ledger.pending = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        defaults.set(try JSONEncoder().encode(ledger), forKey: key)
        SyncDiagnostics.log("dictionary: learning candidates=\(candidates.count) added=\(writes.count)")
        return !writes.isEmpty
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data((ledger.salt + value).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isKnownWord(_ word: String, languages: [String]) -> Bool {
        let checker = NSSpellChecker.shared
        let available = checker.availableLanguages
        let chosen = languages.flatMap { language in
            available.filter { $0 == language || $0.hasPrefix(language + "_") || $0.hasPrefix(language + "-") }
        }
        let selected = chosen.isEmpty ? checker.userPreferredLanguages : chosen
        return selected.contains { language in
            checker.checkSpelling(of: word.lowercased(), startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }
}
