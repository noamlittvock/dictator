import Foundation

/// The app's wording: direct, fast, confident and dry. Each line says what
/// is happening, what happened or what to do next. The person using the
/// Mac has the power; the app is never the subject of a joke.
enum BrandVoice {
    // MARK: Menu bar

    static let ready = "Ready to dictate"
    static let recording = "Recording speech…"
    static let processing = "Turning speech into text…"

    // MARK: Welcome

    static let welcomeIntro = "Hold a key, speak and release. Your words go into the focused app when it allows typing."
    static let speechReady = "Speech is ready. You can change the model later in Your Macs."
    static let startDictating = "Start dictating"

    // MARK: Home

    static let noHistory = "No history yet"

    // MARK: Your Macs

    static let yourMacsSummary = "See your Macs, their AI models and where each step of dictation runs."
    static let addMac = "Add a Mac"

    static func backupStandingIn(down: String, backup: String) -> String {
        "\(down) can’t be reached. \(backup) is the selected backup."
    }

    // MARK: Alert titles

    /// `place` reads mid-sentence: "your main Mac", "Mac mini".
    static func cantReach(_ place: String) -> String {
        "Can’t reach \(place)"
    }

    static let nothingHeard = "Nothing was heard"
    static let microphoneStopped = "The microphone stopped while you were talking"

    static func recordingsWaiting(_ count: Int) -> String {
        count == 1
            ? "1 recording needs your attention"
            : "\(count) recordings need your attention"
    }

    // MARK: Voice launch

    static let onNow = "Ready to run"
    static let nothingOn = "No commands on yet. Turn one on to run it by voice."
    static let howToSayIt = "How to say it"
    static let noVoiceCommandFits = "No command fits these words. Dictator would copy them to the clipboard and tell you."

    static func countdown(_ secondsLeft: Int) -> String {
        "Sending in \(secondsLeft) s. Esc to cancel."
    }

    // MARK: Workspace launch

    static let windowsSummary = "Arrange windows on the current desktop by voice, with a click or a keyboard shortcut."
    static let previewOnly = "Preview only. No window has moved."
    static let hideIdle = "Hides apps you haven't used for an hour. They stay open."
    static let rememberLayout = "Save this window layout"

    // MARK: Dictionary

    static let noDictionaryEntries = "No words added yet"

    // MARK: One-off moments

    /// The notice for this Mac's first dictation, once ever.
    static func takeFirstDictationMoment(settings: AppSettings = .shared) -> DictationAlert? {
        guard !settings.didPassFirstDictation else { return nil }
        settings.didPassFirstDictation = true
        return DictationAlert(title: "Your first dictation is done.", detail: "Hold your key whenever you have more to say.", tone: .notice)
    }

    /// Every line, with sample names, so tests can hold them all to the rules.
    static var allLines: [String] {
        [
            ready, recording, processing, welcomeIntro, speechReady, startDictating, noHistory,
            yourMacsSummary, addMac, backupStandingIn(down: "Mac mini", backup: "Mac Studio"),
            cantReach("your main Mac"), nothingHeard, microphoneStopped, recordingsWaiting(1), recordingsWaiting(3),
            onNow, nothingOn, howToSayIt, noVoiceCommandFits, countdown(3),
            windowsSummary, previewOnly, hideIdle, rememberLayout, noDictionaryEntries,
        ]
    }
}
