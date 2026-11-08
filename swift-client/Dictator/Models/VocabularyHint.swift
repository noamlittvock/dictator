import Foundation

struct VocabularyHintInput: Equatable {
    var ownerNames: [String] = []
    var starred: [String] = []
    var ranked: [VocabularyHintWord] = []
    var voiceLaunch: [String] = []
    var nearby: [String] = []
    var packs: [String] = []
    var isVoiceLaunch = false
}

struct VocabularyHintWord: Equatable {
    var text: String
    var useCount: Int
    var lastUsedAt: Date?
}

enum VocabularyHint {
    private struct Frames: Decodable {
        var budget: Int
        var frames: [String: String]
    }

    private static let frames: Frames = {
        // Like the other shared catalogs, project.yml puts the original JSON
        // in the app bundle. The source path supports standalone unit checks.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/vocabulary-hints.json")
        let url = Bundle.main.url(forResource: "vocabulary-hints", withExtension: "json") ?? source
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Frames.self, from: data) else {
            preconditionFailure("Missing shared vocabulary-hints.json")
        }
        return value
    }()

    static var budget: Int { frames.budget }

    static func orderedTerms(_ input: VocabularyHintInput) -> [String] {
        let ranked = input.ranked.enumerated().sorted {
            if $0.element.useCount != $1.element.useCount { return $0.element.useCount > $1.element.useCount }
            let lhs = $0.element.lastUsedAt ?? .distantPast
            let rhs = $1.element.lastUsedAt ?? .distantPast
            if lhs != rhs { return lhs > rhs }
            return $0.offset < $1.offset
        }.map { $0.element.text }
        let words = (input.isVoiceLaunch ? input.voiceLaunch : []) + input.ownerNames + input.starred + ranked
            + (input.isVoiceLaunch ? [] : input.voiceLaunch) + input.nearby + input.packs
        var seen = Set<String>()
        return words.compactMap {
            let term = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }

    /// `tokens` measures the candidate comma list. Engines wrap it in the
    /// selected sentence frame inside this closure, counting the entire prompt
    /// with their real tokenizer. Never truncate a word or token sequence.
    static func fit(_ terms: [String], budget: Int, tokens: (String) -> Int) -> [String] {
        var fitted: [String] = []
        for term in terms where !term.isEmpty {
            let candidate = fitted + [term]
            if tokens(candidate.joined(separator: ", ")) <= budget { fitted = candidate }
        }
        return fitted
    }

    static func prompt(_ terms: [String], language: String?) -> String {
        guard !terms.isEmpty else { return "" }
        let code = language?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        let frame = code.flatMap { frames.frames[$0] } ?? frames.frames["fallback"]!
        return frame.replacingOccurrences(of: "{terms}", with: terms.joined(separator: ", "))
    }
}
