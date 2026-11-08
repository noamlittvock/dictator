import Foundation

// Dictator inside the Shortcuts app: what the three actions (Dictate, Run a
// Voice launch shortcut, Clean up text) do, kept apart from the AppIntents
// types so it can be tested with a mocked pipeline. `DictatorIntents.swift`
// is the thin layer Shortcuts, Spotlight and Siri see.

/// A problem, said plainly. Shown by the Shortcuts app as the reason the
/// action stopped.
struct ShortcutsBridgeError: Error, LocalizedError, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    static let notReady = ShortcutsBridgeError("Dictator isn’t ready yet. Open Dictator and try again.")
    static let noSpeech = ShortcutsBridgeError("Dictator didn’t hear anything. Check your microphone and try again.")
    static let cancelled = ShortcutsBridgeError("Cancelled.")
    static let noCleanupModel = ShortcutsBridgeError(
        "No AI model is chosen for clean-up. Choose one in Dictator › Settings › Your Macs, then try again.")
    static let nothingToClean = ShortcutsBridgeError("There is no text to clean up.")
}

/// What one recording turned into, before dictionary and clean-up.
struct ShortcutsHeard: Equatable {
    var text: String
    var seconds: Double
}

/// A Voice launch shortcut as Shortcuts lists it.
struct ShortcutsVoiceCommand: Equatable, Identifiable {
    var id: String
    /// The card title.
    var name: String
    /// The opening words to say, e.g. "WhatsApp".
    var opens: String
}

/// What the actions need from the running app. The app fills these in;
/// tests fill in fakes.
@MainActor
struct ShortcutsBridgeServices {
    var config: () -> VoiceLaunchConfig
    /// Records on this Mac and returns the words as spoken. Throws a plain reason.
    var listen: () async throws -> ShortcutsHeard
    /// Dictionary replacements, then (when `useAI`) the clean-up model, on
    /// the main Mac. Throws a plain reason.
    var finish: (_ text: String, _ useAI: Bool) async throws -> String
    /// False when the setting "Exact" asks for no clean-up.
    var cleanupAllowed: () -> Bool
    /// True when a clean-up model is chosen (or the speech server's own is up).
    var cleanupAvailable: () -> Bool
    /// Saves a Shortcuts dictation to history, under the normal rules.
    var saveHistory: (HistoryRecordDTO) async -> Void
    var originEdgeId: () -> EdgeID?
    /// Runs a plan on this Mac, exactly as a spoken one, telling each answer.
    var runPlan: (VoiceLaunchPlan, @escaping (VoiceShortcutAnswer) -> Void) async -> VoiceLaunchExecutor.Result
}

@MainActor
enum ShortcutsBridge {
    /// Set by the app once it has started; nil before (and in hosted tests).
    static var services: ShortcutsBridgeServices?

    private static func ready() throws -> ShortcutsBridgeServices {
        guard let services else { throw ShortcutsBridgeError.notReady }
        return services
    }

    // MARK: Listing

    /// The enabled Voice launch shortcuts, for the Shortcuts app's picker.
    static func voiceCommands(in config: VoiceLaunchConfig) -> [ShortcutsVoiceCommand] {
        config.commands.filter(\.enabled).map {
            ShortcutsVoiceCommand(id: $0.id, name: $0.name, opens: $0.triggerWords.joined(separator: " "))
        }
    }

    static func voiceCommands(matching text: String, in config: VoiceLaunchConfig) -> [ShortcutsVoiceCommand] {
        let wanted = VoiceLaunchText.normalizedWords(text).joined(separator: " ")
        let all = voiceCommands(in: config)
        guard !wanted.isEmpty else { return all }
        return all.filter {
            VoiceLaunchText.normalizedWords($0.name).joined(separator: " ").contains(wanted)
                || VoiceLaunchText.normalizedWords($0.opens).joined(separator: " ").contains(wanted)
        }
    }

    // MARK: Dictate

    /// The text of one recording. Not pasted. Saved to history, marked as
    /// coming from Shortcuts.
    static func dictate(cleanUp: Bool) async throws -> String {
        let services = try ready()
        let heard = try await services.listen()
        let words = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw ShortcutsBridgeError.noSpeech }
        let text = try await services.finish(words, cleanUp && services.cleanupAllowed())
        var record = historyRecord(text: text, seconds: heard.seconds, originEdgeId: services.originEdgeId())
        record.heardText = words
        await services.saveHistory(record)
        return text
    }

    /// The history row for a Shortcuts dictation: an ordinary spoken entry
    /// whose source and capture reason say it came from Shortcuts.
    static func historyRecord(text: String, seconds: Double, originEdgeId: EdgeID?) -> HistoryRecordDTO {
        HistoryRecordDTO(
            text: text,
            durationSeconds: seconds,
            modality: "voice",
            source: historySource,
            originEdgeId: originEdgeId,
            attribution: PromptAttribution(captureSource: CaptureSource.shortcuts.rawValue)
        )
    }

    static let historySource = "shortcuts"

    // MARK: Clean up text

    static func cleanUp(_ text: String) async throws -> String {
        let services = try ready()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShortcutsBridgeError.nothingToClean }
        guard services.cleanupAvailable() else { throw ShortcutsBridgeError.noCleanupModel }
        return try await services.finish(text, true)
    }

    // MARK: Run a Voice launch shortcut

    /// What is said to run `shortcut`: its opening words, then `words`.
    static func sentence(for voiceCommand: VoiceCommand, words: String?) -> String {
        let rest = (words ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (voiceCommand.triggerWords + (rest.isEmpty ? [] : [rest])).joined(separator: " ")
    }

    /// Runs the shortcut as if the sentence had been spoken, cancel pause
    /// included, and returns its last answer, else its main words.
    static func run(commandId: String, words: String?) async throws -> String {
        let services = try ready()
        let config = services.config()
        guard let voiceCommand = config.commands.first(where: { $0.id == commandId }) else {
            throw ShortcutsBridgeError("That command isn’t in Dictator any more. Choose it again in the Shortcuts action.")
        }
        guard voiceCommand.enabled else {
            throw ShortcutsBridgeError("“\(voiceCommand.name)” is turned off in Dictator › Commands.")
        }
        // Only this shortcut can match, so another one never runs instead.
        var only = config
        only.commands = [voiceCommand]
        let said = sentence(for: voiceCommand, words: words)
        let plan: VoiceLaunchPlan
        switch VoiceLaunchEngine.plan(for: said, in: only) {
        case .plan(let value): plan = value
        case .noMatch(let reason): throw noMatch(reason, voiceCommand: voiceCommand, config: config)
        case .nearMiss(let miss):
            if miss.kind == .entry {
                throw ShortcutsBridgeError("Dictator didn’t recognise “\(miss.heard)” for “\(voiceCommand.name)”. Check the words you gave the action.")
            }
            throw noMatch(.noneMatched, voiceCommand: voiceCommand, config: config)
        }
        var last: VoiceShortcutAnswer?
        let result = await services.runPlan(plan) { answer in last = answer }
        switch result {
        case .done:
            if let last, !last.text.isEmpty { return last.text }
            return plan.mainText
        case .cancelled(let alert):
            throw ShortcutsBridgeError(alert.title + ".")
        case .stopped(let alert):
            throw ShortcutsBridgeError("\(alert.title). \(alert.detail)")
        }
    }

    static func noMatch(_ reason: NoMatchReason, voiceCommand: VoiceCommand, config: VoiceLaunchConfig) -> ShortcutsBridgeError {
        switch reason {
        case .nothingSaid, .noCommands, .noneMatched, .tie:
            let example = SentenceBuilder.exampleSentence(pattern: voiceCommand.pattern, config: config)
            let fit = "Those words don’t fit “\(voiceCommand.name)”."
            return ShortcutsBridgeError(example.isEmpty ? fit : "\(fit) For example: \(example)")
        }
    }

    // MARK: Plain messages

    /// A failure as one plain sentence: a dictation alert's title and detail,
    /// or the error's own words.
    static func plain(_ error: Error) -> String {
        if let error = error as? ShortcutsBridgeError { return error.message }
        return plain(message: error.localizedDescription)
    }

    static func plain(message: String) -> String {
        guard message.contains("\n") else { return message }
        let alert = DictationAlert.decode(failure: message)
        let title = alert.title.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return "\(title). \(alert.detail)"
    }
}
