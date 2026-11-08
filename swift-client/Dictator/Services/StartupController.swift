import AppKit
import Observation
import ServiceManagement

/// Per-install OS state. This is reported to other Macs, never applied by
/// settings mirroring: registration and approval belong to the local user.
struct StartupReport: Codable, Equatable {
    enum Login: String, Codable { case enabled, disabled, needsApproval, unavailable }
    var login: Login
    var showWindow: Bool

    var summary: String {
        switch login {
        case .enabled: "Opens after you log in"
        case .disabled: "Must be opened by hand"
        case .needsApproval: "Waiting for macOS approval"
        case .unavailable: "Startup status unavailable"
        }
    }

    static func detail(report: StartupReport?, online: Bool, isMain: Bool) -> String {
        guard online else { return "Offline. Open Dictator on this Mac to check its current startup settings." }
        guard let report else { return "Update Dictator on this Mac to share its startup settings." }
        if isMain && report.login != .enabled {
            return "Your other Macs share history and settings through this one. Configure startup on this Mac."
        }
        switch report.login {
        case .enabled: return report.showWindow ? "Shows its window, then connects when the network is ready." : "Stays in the menu bar, then connects when the network is ready."
        case .disabled: return "Open Dictator yourself after login, or enable automatic opening on this Mac."
        case .needsApproval: return "Approve Dictator in this Mac’s Login Items settings."
        case .unavailable: return "Check the installed app and Login Items on this Mac."
        }
    }
}

@MainActor
@Observable
final class StartupController {
    static let shared = StartupController()
    static let windowKey = "startupShowWindow"
    private(set) var login: StartupReport.Login = .unavailable
    private(set) var message: String?
    private(set) var showWindow: Bool
    @ObservationIgnored private var launchWindowConsidered = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readLogin: @MainActor () -> StartupReport.Login
    @ObservationIgnored private let register: () throws -> Void
    @ObservationIgnored private let unregister: () throws -> Void

    init(defaults: UserDefaults = .standard,
         readLogin: @escaping @MainActor () -> StartupReport.Login = StartupController.systemLogin,
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.defaults = defaults
        self.readLogin = readLogin
        self.register = register
        self.unregister = unregister
        showWindow = defaults.bool(forKey: Self.windowKey)
        refresh()
    }

    static func systemLogin() -> StartupReport.Login {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .needsApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    var report: StartupReport { StartupReport(login: login, showWindow: showWindow) }
    static var currentReport: StartupReport {
        StartupReport(login: systemLogin(), showWindow: UserDefaults.standard.bool(forKey: windowKey))
    }

    func refresh() {
        login = readLogin()
        showWindow = defaults.bool(forKey: Self.windowKey)
    }

    func setLogin(_ enabled: Bool) {
        message = nil
        refresh()
        if enabled && (login == .enabled || login == .needsApproval) { return }
        if !enabled && login == .disabled { return }
        do {
            if enabled { try register() } else { try unregister() }
        } catch {
            message = "Couldn’t change automatic opening. Check Login Items on this Mac and try again."
            NSLog("[Startup] login change failed: %@", error.localizedDescription)
        }
        // Registration can succeed but still need approval. Never promise
        // automatic opening until macOS actually reports enabled.
        refresh()
    }

    func setShowWindow(_ value: Bool) {
        defaults.set(value, forKey: Self.windowKey)
        showWindow = value
    }

    /// Menu-bar icon changes can recreate its view task during dictation.
    /// A launch preference must never reopen the window on those changes.
    func claimLaunchWindow(hasCompletedWelcome: Bool) -> Bool {
        guard !launchWindowConsidered else { return false }
        launchWindowConsidered = true
        return !hasCompletedWelcome || showWindow
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Build/test products must not become a second live dictation app merely
/// because Finder or an automation resolves the shared executable name.
enum DevelopmentRuntimePolicy {
    static func blocksLiveRuntime(bundleID: String?, arguments: [String]) -> Bool {
        bundleID == "dev.noamlitt.dictator.development" && !arguments.contains("--allow-development-runtime")
    }
}
