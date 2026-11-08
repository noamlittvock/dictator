import Foundation

/// The single place a finished dictation gets its dictionary replacements
/// when the text did not come from a server that already applied them.
///
/// One owner per path: either the AI clean-up (its job applies the
/// replacements itself, `CleanupPrompt.job`) or, when clean-up is skipped,
/// this direct pass. Never both, or a non-idempotent rule such as
/// GPT -> Chat GPT turns into Chat Chat GPT.
enum TextFinisher {
    /// `cleanUp` is given the original words and must apply the dictionary
    /// itself. Pass nil when clean-up is off or unavailable.
    static func finish(
        _ text: String,
        dictionary: [[String: String]],
        cleanUp: ((String) async -> String)?
    ) async -> String {
        if let cleanUp, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return await cleanUp(text)
        }
        return CleanupPrompt.applyReplacements(text, dictionary: dictionary)
    }
}
