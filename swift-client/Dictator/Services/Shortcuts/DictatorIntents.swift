import AppIntents
import Foundation

// Optional Dictator actions for the Shortcuts app, Spotlight and Siri. Each is
// a thin layer over `ShortcutsBridge`, which does the work and is tested.
// Actions run inside the Dictator app, so they use this Mac's own speech path
// and settings. The microphone is used only while Dictate runs.

/// App Intents are opt-in for builds with a genuine signing team and a native
/// Shortcuts verification. The local certificate used by the standard build
/// has no Team ID; macOS 27 rejects its App Intents connection before perform().
/// This does not disable Voice launch steps that run existing Apple Shortcuts.
enum DictatorAppIntentsBuild {
    #if DICTATOR_ENABLE_APP_INTENTS
    static let enabled = true
    #else
    static let enabled = false
    #endif

    static let unavailableMessage = "Dictator’s actions in Apple Shortcuts are unavailable in this build."
    static let unavailableHelp = "They need a build signed by an Apple developer and checked on this Mac."
}

extension ShortcutsBridgeError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

// MARK: - Dictate

struct DictateIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate"
    static let description = IntentDescription(
        "Listens through this Mac’s microphone and gives you what you said as text. It stops after 2 seconds of quiet, or after 2 minutes. Nothing is typed for you; the text goes on to the next action.",
        categoryName: "Dictation")
    static let openAppWhenRun = false
    #if DICTATOR_ENABLE_APP_INTENTS
    static let isDiscoverable = true
    #else
    static let isDiscoverable = false
    #endif

    @Parameter(title: "Clean up my words", default: true)
    var cleanUp: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ShortcutsBridge.dictate(cleanUp: cleanUp))
    }
}

// MARK: - Clean up text

struct CleanUpTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean up text"
    static let description = IntentDescription(
        "Tidies the text you give it with Dictator’s clean-up (punctuation, filler words, your dictionary’s replacements). This uses an AI model, so the same text can come back slightly different each time.",
        categoryName: "Dictation")
    static let openAppWhenRun = false
    #if DICTATOR_ENABLE_APP_INTENTS
    static let isDiscoverable = true
    #else
    static let isDiscoverable = false
    #endif

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Clean up \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ShortcutsBridge.cleanUp(text))
    }
}

// MARK: - Run a Command

struct VoiceShortcutEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Command")
    static let defaultQuery = VoiceShortcutQuery()

    var id: String
    var name: String
    var opens: String

    init(_ shortcut: ShortcutsVoiceCommand) {
        id = shortcut.id
        name = shortcut.name
        opens = shortcut.opens
    }

    var displayRepresentation: DisplayRepresentation {
        opens.isEmpty
            ? DisplayRepresentation(title: "\(name)")
            : DisplayRepresentation(title: "\(name)", subtitle: "Say “\(opens)”")
    }
}

struct VoiceShortcutQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [VoiceShortcutEntity] {
        let all = ShortcutsBridge.voiceCommands(in: AppSettings.shared.voiceLaunch)
        return identifiers.compactMap { id in all.first { $0.id == id } }.map(VoiceShortcutEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [VoiceShortcutEntity] {
        ShortcutsBridge.voiceCommands(matching: string, in: AppSettings.shared.voiceLaunch).map(VoiceShortcutEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [VoiceShortcutEntity] {
        ShortcutsBridge.voiceCommands(in: AppSettings.shared.voiceLaunch).map(VoiceShortcutEntity.init)
    }
}

struct RunVoiceLaunchShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a Command"
    static let description = IntentDescription(
        "Runs one of your commands on this Mac as if you had said it, including the pause that lets you cancel. Gives you the answer of the last Apple Shortcut it ran, or else the main words.",
        categoryName: "Commands")
    static let openAppWhenRun = false
    #if DICTATOR_ENABLE_APP_INTENTS
    static let isDiscoverable = true
    #else
    static let isDiscoverable = false
    #endif

    @Parameter(title: "Command")
    var shortcut: VoiceShortcutEntity

    @Parameter(title: "Words", description: "What you would say after the opening words.")
    var words: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$shortcut) with \(\.$words)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ShortcutsBridge.run(commandId: shortcut.id, words: words))
    }
}

// MARK: - Spotlight and Siri

struct DictatorShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        #if DICTATOR_ENABLE_APP_INTENTS
        return [AppShortcut(
            intent: DictateIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Start dictating with \(.applicationName)",
            ],
            shortTitle: "Dictate",
            systemImageName: "mic"),
        AppShortcut(
            intent: CleanUpTextIntent(),
            phrases: [
                "Clean up text with \(.applicationName)",
            ],
            shortTitle: "Clean up text",
            systemImageName: "text.badge.checkmark"),
        AppShortcut(
            intent: RunVoiceLaunchShortcutIntent(),
            phrases: [
                "Run a Command in \(.applicationName)",
                "Run my Command with \(.applicationName)",
            ],
            shortTitle: "Run a Command",
            systemImageName: "bolt")]
        #else
        return []
        #endif
    }
}
