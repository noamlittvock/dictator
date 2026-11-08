import Foundation

/// Value-only diff and safety policy. No storage, Accessibility or language assumptions.
/// The caller supplies the system spell checker for the person's chosen languages.
enum CorrectionLearner {
    struct Substitution: Equatable {
        var heard: String
        var corrected: String
    }

    static func substitutions(inserted: String, edited: String,
                              isKnownWord: (String) -> Bool) -> [Substitution] {
        guard !containsMarkupOrCode(inserted), !containsMarkupOrCode(edited) else { return [] }
        let before = inserted.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = edited.split(whereSeparator: \.isWhitespace).map(String.init)
        // Bound the quadratic alignment, and decline wholesale replacements.
        guard !before.isEmpty, !after.isEmpty, before.count == after.count, before.count <= 512, after.count <= 512 else { return [] }
        var lengths = Array(repeating: Array(repeating: 0, count: after.count + 1), count: before.count + 1)
        for i in before.indices.reversed() {
            for j in after.indices.reversed() {
                lengths[i][j] = before[i] == after[j] ? 1 + lengths[i + 1][j + 1]
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var spans: [(heard: [String], corrected: [String])] = []
        var removed: [String] = [], added: [String] = []
        func flush() {
            if !removed.isEmpty || !added.isEmpty { spans.append((removed, added)) }
            removed = []; added = []
        }
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, j < after.count, before[i] == after[j] {
                flush(); i += 1; j += 1
            } else if j < after.count, i == before.count || lengths[i][j + 1] >= lengths[i + 1][j] {
                added.append(after[j]); j += 1
            } else { removed.append(before[i]); i += 1 }
        }
        flush()
        guard spans.count <= 3, spans.allSatisfy({ !$0.heard.isEmpty && $0.heard.count == $0.corrected.count }) else { return [] }
        return spans.compactMap { span in
            guard (1...3).contains(span.heard.count), (1...3).contains(span.corrected.count),
                  let heard = term(span.heard), let corrected = term(span.corrected),
                  heard != corrected else { return nil }
            let a = folded(heard), b = folded(corrected)
            let brandCase = a == b && hasInternalCapital(corrected)
            // Case-only sentence capitalization is not a learned name.
            guard a != b || brandCase else { return nil }
            guard similar(a, b) else { return nil }
            let words = corrected.split(separator: " ").map(String.init)
            guard brandCase || !words.allSatisfy(isKnownWord) else { return nil }
            return Substitution(heard: heard, corrected: corrected)
        }
    }

    static func ownsEdit(inserted: String, edited: String) -> Bool {
        let before = inserted.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = edited.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !before.isEmpty, before.count == after.count, before.count <= 512,
              inserted.prefix(while: \.isWhitespace) == edited.prefix(while: \.isWhitespace),
              inserted.reversed().prefix(while: \.isWhitespace).elementsEqual(edited.reversed().prefix(while: \.isWhitespace)),
              !containsMarkupOrCode(inserted), !containsMarkupOrCode(edited) else { return false }
        var changed = false
        for (index, pair) in zip(before, after).enumerated() where pair.0 != pair.1 {
            let (a, b) = pair
            guard let heard = term([a]), let corrected = term([b]),
                  similar(folded(heard), folded(corrected)) else { return false }
            let source = Array(folded(heard)), target = Array(folded(corrected))
            let distance = editDistance(source, target)
            // If an optimal alignment can insert at an outer boundary, the
            // extra characters could be unrelated typing. Fail closed even
            // when another equally good alignment looks like a correction.
            if index == 0, distance == editDistance(source, Array(target.dropFirst())) + 1 { return false }
            if index == before.count - 1, distance == editDistance(source, Array(target.dropLast())) + 1 { return false }
            changed = true
        }
        return changed && !substitutions(inserted: inserted, edited: edited, isKnownWord: { _ in false }).isEmpty
    }

    private static func containsMarkupOrCode(_ text: String) -> Bool {
        if text.contains("`") || text.contains("=>") || text.contains("::") || text.contains("=") { return true }
        let pattern = #"(?m)^\s*(?:#{1,6}\s|[-*+]\s|>\s|\|)|\[[^\]]+\]\([^)]*\)|\b(?:let|var|const|func|def|class|import)\s+\w+"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func term(_ tokens: [String]) -> String? {
        // Only sentence punctuation at the outside is stripped. In particular,
        // dots inside a word, slashes, digits, underscores, markup and symbols
        // cannot be turned into plausible vocabulary by tokenization.
        let punctuation = CharacterSet(charactersIn: ",.!?;:…\"“”«»")
        guard !tokens.contains(where: { $0.hasSuffix(":") }) else { return nil }
        let joined = tokens.joined(separator: " ").trimmingCharacters(in: punctuation)
        guard (2...40).contains(joined.count) else { return nil }
        for word in joined.split(separator: " ") {
            guard word.count >= 2 else { return nil }
            var letters = 0
            for scalar in word.unicodeScalars {
                if CharacterSet.letters.contains(scalar) { letters += 1 }
                else if CharacterSet.nonBaseCharacters.contains(scalar) { continue }
                else if scalar == "'" || scalar == "’" { continue }
                else { return nil }
            }
            guard letters >= 2 else { return nil }
            let lower = word.lowercased()
            // Long hex strings and opaque consonant-heavy Latin identifiers.
            if word.count >= 8, word.allSatisfy({ "abcdefABCDEF".contains($0) }) { return nil }
            if word.count >= 12, word.unicodeScalars.allSatisfy({ $0.isASCII }),
               !lower.contains(where: { "aeiouy".contains($0) }) { return nil }
            // Multiple internal capitals are generally code/key identifiers.
            if word.filter(\.isUppercase).count > 3 { return nil }
        }
        return joined
    }

    static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().filter { !$0.isWhitespace }
    }

    private static func hasInternalCapital(_ text: String) -> Bool {
        text.split(separator: " ").contains { word in
            word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
        }
    }

    /// Normalized Levenshtein distance, over Unicode characters. Requiring
    /// shared letters plus <= 40% edits rejects semantic rewrites of similar size.
    static func similar(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard Set(a).intersection(b).count >= 2 else { return false }
        return Double(editDistance(a, b)) / Double(max(a.count, b.count)) <= 0.4
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, char) in a.enumerated() {
            var current = [i + 1]
            for (j, other) in b.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (char == other ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// Repository command, never a typed-history capture. Automatic observations
/// carry the dictation's stable row id; explicit History fixes set `explicit`.
/// Older peers ignore unknown repository requests without a protocol bump.
struct CorrectionReport: Codable, Equatable {
    var heard: String
    var corrected: String
    var entryID: UUID? = nil
    var explicit: Bool? = nil
    var pairsOnly: Bool? = nil
    var context: CaptureContext? = nil
    var selection: HistoryCorrectionSpan? = nil
}

/// Offsets count Swift Characters (extended grapheme clusters), as in the sheet.
struct HistoryCorrectionSpan: Codable, Equatable {
    var start: Int
    var end: Int
    var originalText: String

    func replacing(in current: String, heard: String, with corrected: String) throws -> String {
        guard current == originalText, start >= 0, end > start, end <= current.count else {
            throw RepositoryError.remote("This history row changed. Close this sheet and try again.")
        }
        let lower = current.index(current.startIndex, offsetBy: start)
        let upper = current.index(current.startIndex, offsetBy: end)
        guard String(current[lower..<upper]) == heard else {
            throw RepositoryError.remote("This history row changed. Close this sheet and try again.")
        }
        return String(current[..<lower]) + corrected + String(current[upper...])
    }
}

struct CorrectionOutcome: Codable, Equatable {
    var historySaved: Bool
    var learned: Bool
    var learningFailed: Bool? = nil

    var message: String {
        if historySaved {
            if learningFailed == true { return "Correction saved. The spelling couldn’t be learned. You can add it in Dictionary." }
            return learned ? "Correction saved and spelling learned." : "Correction saved. No new word was learned."
        }
        return learned ? "Spelling learned. The history row wasn’t changed." : "The history row wasn’t changed and no new word was learned."
    }
}
