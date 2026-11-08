import Observation
import SwiftUI

/// Cross-window navigation requests: the menu bar (or a notice) asks the
/// main window to show a screen — e.g. Settings → Prompts, or first-run
/// prompt setup.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    /// Set to jump the main window to a sidebar item; consumed by it.
    var mainSelection: SidebarItem?
    /// Set to jump Settings to a section; consumed by `SettingsView`.
    var settingsSection: SettingsSection?
    /// Select a shortcut in the Voice launch editor on arrival.
    var voiceCommandID: String?

    func openVoiceCommand(_ id: String) {
        voiceCommandID = id
        mainSelection = .voiceLaunch
        mainWindowRequests += 1
    }

    /// Present "Which AI tools should Dictator keep your prompts from?".
    var showPromptSetup = false

    func openPromptSettings() {
        mainSelection = .settings
        settingsSection = .typedApps
    }

    /// Bumped to bring the main window forward (opened by the menu-bar
    /// label, which is always alive).
    var mainWindowRequests = 0

    /// Opens the main window on a Settings page (e.g. from a dictation alert).
    func openSettings(_ section: SettingsSection) {
        mainSelection = .settings
        settingsSection = section
        mainWindowRequests += 1
    }

    func openDatasets() {
        mainSelection = .datasets
    }

    /// Set to open a Help topic; consumed by `HelpView`.
    var helpTopicID: String?

    /// Opens Help, on one topic if given.
    func openHelp(topic: String? = nil) {
        helpTopicID = topic
        mainSelection = .help
        mainWindowRequests += 1
    }

    /// Follows a link from a Help topic.
    func open(_ link: HelpLink) {
        switch link {
        case .page(let item): mainSelection = item
        case .settings(let section): openSettings(section)
        }
    }
}
