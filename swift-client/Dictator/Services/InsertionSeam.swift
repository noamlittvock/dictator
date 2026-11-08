import Foundation

/// Joins a dictation to the text already before the caret, so a dictation
/// that picks up where the last one (or the user's typing) stopped doesn't
/// land glued to it: "That's one" + "two." becomes "That's one two.", not
/// "That's onetwo.".
///
/// Only the new text changes, and only at its start: a leading space, and a
/// lowercased first word when the text before it is mid-sentence. Never the
/// text already in the field, and never a word other than the first.
enum InsertionSeam {
    /// How much text before the caret is enough to decide the seam.
    static let contextLength = 80

    /// Characters after which the next word follows with no space.
    private static let opening: Set<Character> = ["(", "[", "{", "“", "‘", "«", "/"]
    /// Straight quotes open when they follow a space or the field's start.
    private static let straightQuotes: Set<Character> = ["\"", "'"]
    /// Characters that attach to the word before them.
    private static let attaching: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "%", "…", "”", "’"]
    /// Endings after which the dictation continues the same sentence.
    private static let continuing: Set<Character> = [",", ";"]

    /// Sentence-starting words the clean-up capitalizes that are safe to
    /// lowercase mid-sentence: none is a name, and "I" is left alone.
    private static let lowercasable: Set<String> = [
        "a", "about", "after", "all", "also", "an", "and", "any", "are", "as", "at",
        "because", "before", "but", "by", "can", "could", "did", "do", "does",
        "for", "from", "had", "has", "have", "he", "her", "here", "his", "how",
        "if", "in", "is", "it", "it's", "its", "just", "maybe", "my", "no", "not",
        "of", "on", "one", "or", "our", "she", "should", "so", "some", "that",
        "that's", "the", "their", "then", "there", "there's", "these", "they",
        "this", "those", "to", "two", "was", "we", "were", "what", "when", "where",
        "which", "while", "who", "why", "with", "would", "yet", "you", "your",
    ]

    /// `text` as it should be typed after `preceding`, the text before the
    /// caret. With nothing readable before the caret, `text` is unchanged.
    static func join(_ text: String, after preceding: String?) -> String {
        guard let preceding, let last = preceding.last, !text.isEmpty else { return text }

        if last.isWhitespace {
            // The field already has the space; don't add a second one.
            let trimmed = text.drop { $0 == " " || $0 == "\t" }
            return trimmed.isEmpty ? text : String(trimmed)
        }
        guard let first = text.first, !first.isWhitespace else { return text }

        let body = midSentence(preceding) ? lowercasingFirstWord(text) : text
        if attaching.contains(first) || opensWord(preceding) { return body }
        return " " + body
    }

    /// Up to `maxLength` characters of `value` before the caret at UTF-16
    /// offset `caret` (the unit Accessibility ranges use).
    static func preceding(_ value: String, caret: Int, maxLength: Int = contextLength) -> String {
        let ns = value as NSString
        let location = min(max(caret, 0), ns.length)
        return String(ns.substring(to: location).suffix(maxLength))
    }

    // MARK: - Private

    private static func opensWord(_ preceding: String) -> Bool {
        guard let last = preceding.last else { return false }
        if opening.contains(last) { return true }
        guard straightQuotes.contains(last) else { return false }
        guard let before = preceding.dropLast().last else { return true }
        return before.isWhitespace || opening.contains(before)
    }

    private static func midSentence(_ preceding: String) -> Bool {
        guard let last = preceding.last else { return false }
        return continuing.contains(last) || last.isLetter || last.isNumber
    }

    /// Lowercases the first word when it's a capitalized common word
    /// ("The" → "the"); names, acronyms and "I" stay as they are.
    private static func lowercasingFirstWord(_ text: String) -> String {
        let word = text.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard let head = word.first, head.isUppercase,
              word.dropFirst().allSatisfy({ !$0.isUppercase }) else { return text }
        let lowered = word.lowercased()
        guard lowercasable.contains(lowered.replacingOccurrences(of: "’", with: "'")) else { return text }
        return lowered + text.dropFirst(word.count)
    }
}
