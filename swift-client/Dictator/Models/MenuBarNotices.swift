import Foundation

/// One thing in the menu bar that needs the user. The menu shows these only
/// while they apply; when all is well it shows none.
struct MenuBarNotice: Equatable, Identifiable {
    enum Fix: Equatable {
        case privacyPane(String)
        case retry
        case settings(SettingsSection)
        case syncNow
        case openDictator
    }

    let text: String
    let symbol: String
    let fix: Fix
    /// A line under it, for what the click alone can't tell the user.
    var hint: String? = nil

    var id: String { text }
}

/// What the menu needs to say, kept apart from the view because SwiftUI can't
/// render a native menu in a test.
enum MenuBarNotices {
    struct Input {
        var permission: String? = nil
        var needsAccessibility = false
        var accessibilityGranted = false
        var error: String? = nil
        var microphone: String? = nil
        var storage: String? = nil
        var insertion: String? = nil
        var connection: (text: String, ok: Bool) = ("", true)
        /// Set on a connected Mac; only an unhealthy sync is worth a line.
        var syncProblem: String? = nil
        var syncCanRunNow = false
        var cleanupNotSetUp = false
        var unsavedPlaces = 0
    }

    /// Most blocking first: a Mac that can't dictate says so at the top.
    static func make(_ input: Input) -> [MenuBarNotice] {
        var notices: [MenuBarNotice] = []
        if let message = input.permission {
            notices.append(MenuBarNotice(text: message, symbol: "lock", fix: .privacyPane(pane(for: message)),
                                         hint: hint(for: message, accessibilityGranted: input.accessibilityGranted)))
        }
        if let error = input.error {
            notices.append(MenuBarNotice(text: error, symbol: "exclamationmark.triangle", fix: .openDictator))
        }
        if let microphone = input.microphone {
            notices.append(MenuBarNotice(text: microphone, symbol: "mic.slash", fix: .retry))
        }
        if let storage = input.storage {
            notices.append(MenuBarNotice(text: storage, symbol: "externaldrive.badge.exclamationmark", fix: .settings(.history)))
        }
        if let insertion = input.insertion {
            notices.append(MenuBarNotice(text: insertion, symbol: "doc.on.clipboard",
                                         fix: input.needsAccessibility ? .privacyPane(accessibilityPane) : .openDictator))
        }
        if !input.connection.ok {
            notices.append(MenuBarNotice(text: input.connection.text, symbol: "network.slash", fix: .settings(.macs)))
        }
        if let sync = input.syncProblem {
            notices.append(MenuBarNotice(text: sync, symbol: "arrow.triangle.2.circlepath",
                                         fix: input.syncCanRunNow ? .syncNow : .settings(.macs)))
        }
        if input.cleanupNotSetUp {
            notices.append(MenuBarNotice(text: "Add an AI model for clean-up", symbol: "sparkles", fix: .settings(.macs)))
        }
        if input.unsavedPlaces > 0 {
            let text = input.unsavedPlaces == 1 ? "1 place you typed in isn’t kept" : "\(input.unsavedPlaces) places you typed in aren’t kept"
            notices.append(MenuBarNotice(text: text, symbol: "keyboard", fix: .settings(.typedApps)))
        }
        return notices
    }

    private static let accessibilityPane = "Privacy_Accessibility"

    private static func pane(for message: String) -> String {
        if message.localizedCaseInsensitiveContains("microphone") { return "Privacy_Microphone" }
        if message.localizedCaseInsensitiveContains("input monitoring") { return "Privacy_ListenEvent" }
        return accessibilityPane
    }

    /// macOS can show Dictator as allowed after a rebuild without honoring it.
    private static func hint(for message: String, accessibilityGranted: Bool) -> String? {
        if message.localizedCaseInsensitiveContains("microphone") { return nil }
        if message.localizedCaseInsensitiveContains("input monitoring") {
            return "Turn Dictator on in Input Monitoring, then try again."
        }
        return accessibilityGranted ? "Dictator has permission now. Try again or relaunch."
            : "If Dictator is already listed, remove it and add it again."
    }
}
