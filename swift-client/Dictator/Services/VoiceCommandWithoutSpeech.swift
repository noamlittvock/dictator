import AppKit

/// No transcript is synthesized: optional slots and everything said are empty.
/// Both Macs read the same local setting populated by CoreSettingsMirror.
enum VoiceCommandWithoutSpeech {
    static func needsSpokenWords(_ command: VoiceCommand) -> Bool {
        guard case .success(let pattern) = VoicePattern.parse(command.pattern) else { return true }
        return pattern.parts.contains { part in
            switch part {
            case .textSlot, .listSlot: true
            case .literal, .optional: false
            }
        }
    }

    static func plan(_ command: VoiceCommand, in config: VoiceLaunchConfig) -> Result<VoiceLaunchPlan, Refusal> {
        guard command.enabled else { return .failure(Refusal("This command is turned off.")) }
        guard !needsSpokenWords(command) else {
            return .failure(Refusal("This command needs spoken words. Use a command with no required spoken parts."))
        }
        if let reason = config.validate(command) { return .failure(Refusal(reason)) }
        return .success(VoiceLaunchEngine.render(VoiceLaunchMatch(voiceCommand: command, slots: [:], specificity: 0), in: config))
    }

    static func permissionSummary(_ plan: VoiceLaunchPlan, routines: [WorkspaceRoutine] = []) -> String {
        plan.steps.filter { $0.kind != .confirm }.map { step in
            switch step.kind {
            case .runInTerminal:
                let command = (step.command ?? "").isEmpty ? VoiceLaunchConfig.defaultAgentCommand : step.command!
                return "Run \(command) in \(step.folder ?? "the chosen folder")."
            case .runAppleShortcut:
                return "Run Apple Shortcut “\(step.shortcutName ?? "the chosen Shortcut")”."
            default:
                return VoiceBuildCopy.summary(step, routines: routines)
            }
        }.joined(separator: "\n")
    }

    struct Refusal: Error, Equatable {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }
}

/// URL parsing has no side effects and returns only an exact saved identity.
/// Query text is never passed to rendering, execution, notices or diagnostics.
enum VoiceCommandURL {
    static func commandKey(_ url: URL) -> String? {
        guard url.absoluteString.utf8.count <= 8_192,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "dictator", parts.host?.lowercased() == "run",
              parts.user == nil, parts.password == nil, parts.rangeOfPort == nil,
              !url.absoluteString.prefix(while: { $0 != "?" }).hasSuffix(":"),
              parts.path.isEmpty, parts.fragment == nil else { return nil }
        let keys = (parts.queryItems ?? []).filter { $0.name == "command" }
        guard keys.count == 1, let key = keys.first?.value, !key.isEmpty, key.count <= 300,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return key
    }

    static func link(for command: VoiceCommand) -> URL? {
        var parts = URLComponents()
        parts.scheme = "dictator"
        parts.host = "run"
        parts.queryItems = [URLQueryItem(name: "command", value: command.id)]
        return parts.url
    }

    /// Do not guess when a name or id identifies more than one command.
    static func resolve(_ key: String, in config: VoiceLaunchConfig) -> VoiceCommand? {
        let matches = config.commands.filter { $0.id == key || $0.name == key }
        return matches.count == 1 ? matches.first : nil
    }
}

@MainActor
final class VoiceCommandTriggerController {
    static let shared = VoiceCommandTriggerController.live()
    struct Services {
        var config: () -> VoiceLaunchConfig
        var paused: () -> Bool
        var developmentBuild: () -> Bool
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var allow: (VoiceLaunchPlan) async -> Bool
        var execute: (VoiceLaunchPlan, VoiceCommandTrigger) async -> VoiceLaunchExecutor.Result
        var notice: (String) -> Void
    }

    private let services: Services
    private(set) var ready = false
    private(set) var isBusy = false
    private var lastLinkAt: TimeInterval?
    /// A link that launched Dictator arrives before it has finished starting.
    private var earlyLink: URL?
    private(set) var earlyLinkRun: Task<Void, Never>?
    static let minimumLinkInterval: TimeInterval = 2

    init(services: Services) { self.services = services }
    func finishStarting() {
        ready = true
        guard let url = earlyLink else { return }
        earlyLink = nil
        earlyLinkRun = Task { await handleURL(url) }
    }

    func handleURL(_ url: URL) async {
        guard ready else {
            if earlyLink == nil { earlyLink = url }
            return
        }
        guard !services.developmentBuild(), !isBusy else { return }
        let now = services.now()
        if let lastLinkAt, now - lastLinkAt < Self.minimumLinkInterval { return }
        lastLinkAt = now
        guard let key = VoiceCommandURL.commandKey(url) else { return }
        guard let command = VoiceCommandURL.resolve(key, in: services.config()) else {
            services.notice("No command matches this link.")
            return
        }
        await run(command, trigger: .otherApp)
    }

    /// The one entry point for keyboard and other-app starts. No input words.
    @discardableResult
    func run(_ command: VoiceCommand, trigger: VoiceCommandTrigger) async -> Bool {
        guard ready, !services.developmentBuild(), !isBusy else { return false }
        // Pause stops typed-history capture, not commands, so only a link
        // that something else started waits for it to end.
        guard trigger != .otherApp || !services.paused() else {
            services.notice("Dictator is paused. Resume it to start commands from other apps.")
            return false
        }
        let config = services.config()
        guard let current = config.commands.first(where: { $0.id == command.id }), current == command else {
            services.notice("This command changed. Start it again.")
            return false
        }
        guard trigger != .otherApp || command.runsFromOtherApps else {
            services.notice("This command does not allow other apps to start it.")
            return false
        }
        let plan: VoiceLaunchPlan
        switch VoiceCommandWithoutSpeech.plan(current, in: config) {
        case .failure(let refusal): services.notice(refusal.reason); return false
        case .success(let rendered): plan = rendered
        }
        isBusy = true
        defer { isBusy = false }
        if trigger == .otherApp, command.steps.contains(where: { $0.isActing || $0.kind == .runInTerminal }) {
            guard await services.allow(plan) else { return false }
        }
        // A modal dialog can dispatch settings and Pause changes. Never run a stale approval.
        guard ready, !services.developmentBuild(), trigger != .otherApp || !services.paused(),
              services.config().commands.first(where: { $0.id == command.id }) == command else {
            services.notice("The command or Dictator's state changed. Start it again.")
            return false
        }
        switch await services.execute(plan, trigger) {
        case .done: return true
        case .stopped(let alert), .cancelled(let alert): services.notice(alert.title + " " + alert.detail); return false
        }
    }

    private static func live() -> VoiceCommandTriggerController {
        let alerts = DictationAlertController()
        let progress = VoiceLaunchProgressController()
        return VoiceCommandTriggerController(services: Services(
            config: { AppSettings.shared.voiceLaunch },
            paused: { AppSettings.shared.isPromptCapturePaused() },
            developmentBuild: {
                #if DEBUG
                return true
                #else
                return Bundle.main.bundleIdentifier != "dev.noamlitt.dictator"
                #endif
            },
            allow: { plan in
                let alert = NSAlert()
                alert.messageText = "Allow “\(plan.commandName)” to run?"
                // Plain permission copy, independent of BrandVoice and URL text.
                alert.informativeText = "Another app asked Dictator to run this command.\n\n" + VoiceCommandWithoutSpeech.permissionSummary(plan, routines: AppSettings.shared.workspaceLaunch.routines)
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Cancel")
                // Something else opened this dialog, so Return must not approve it.
                alert.buttons.first?.keyEquivalent = ""
                alert.buttons.last?.keyEquivalent = "\r"
                NSApp.activate(ignoringOtherApps: true)
                return alert.runModal() == .alertFirstButtonReturn
            },
            execute: { plan, trigger in
                progress.begin(plan)
                defer { progress.end() }
                return await VoiceLaunchExecutor.run(plan, trigger: trigger, progress: { progress.apply($0) })
            },
            notice: { reason in alerts.show(DictationAlert(title: "Command not run", detail: reason, action: nil, tone: .notice)) }
        ))
    }
}
