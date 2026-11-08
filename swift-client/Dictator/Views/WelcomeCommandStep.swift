import SwiftUI

/// Uses the same catalog insertion and matcher as Commands. Existing
/// commands, including disabled commands, always win over the starter set.
enum WelcomeCommandStarter {
    static let phrase = "Open Safari"
    static let templateIDs = ["open-app", "google", "youtube"]

    @discardableResult
    static func add(to config: inout VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared) -> Bool {
        guard config.commands.isEmpty else { return false }
        let templates = templateIDs.compactMap { id in catalog.available.first { $0.id == id } }
        guard templates.count == templateIDs.count,
              templates.allSatisfy({ template in
                  !template.steps.isEmpty && template.steps.allSatisfy { step in
                      switch step.kind {
                      case .openApp: return step.deferred == nil
                      case .openLink:
                          guard let link = step.link, let url = URL(string: link), url.scheme == "https" else { return false }
                          return ["www.google.com", "www.youtube.com"].contains(url.host ?? "") && step.deferred == nil
                      default: return false
                      }
                  }
              }) else { return false }
        var starter = config
        for template in templates {
            guard catalog.add(template, to: &starter) == nil else { return false }
        }
        config = starter
        return true
    }
}

struct WelcomeCommandStep: View {
    @State private var settings = AppSettings.shared
    @State private var activity = CommandActivity.shared
    @State private var skipped = false
    @State private var starterIDs: Set<String> = []
    @State private var enabledAt: Date?
    @State private var problem: String?

    private var worked: Bool {
        guard let id = activity.lastSuccessCommandId, let time = activity.lastSuccessTime, let enabledAt else { return false }
        return starterIDs.contains(id) && time >= enabledAt
    }

    var body: some View {
        HStack(alignment: .top, spacing: DSSpace.s) {
            DSStepBadge(number: 5, done: worked || skipped || (starterIDs.isEmpty && !settings.voiceLaunch.commands.isEmpty))
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text("Try a command").font(.dsSection).foregroundStyle(Color.dsTextPrimary)
                commandContent
            }
        }
    }

    private var commandContent: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            if worked {
                Label("Your command worked", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.dsSuccess)
            } else if skipped {
                Text("You can try Commands later.")
            } else if !starterIDs.isEmpty {
                Text("Commands keys: \(settings.hotkeyTriggers.commands.symbolName)")
                    .font(.dsBodyMedium)
                Text(VoiceBuildCopy.howToSay(keys: settings.hotkeyTriggers.commands, phrase: WelcomeCommandStarter.phrase))
                if case .matched = VoiceTryItResult.result(for: WelcomeCommandStarter.phrase, in: settings.voiceLaunch),
                   let action = VoiceTryItResult.actionSentence(for: WelcomeCommandStarter.phrase, in: settings.voiceLaunch,
                                                                routines: settings.workspaceLaunch.routines) {
                    Text(action).foregroundStyle(Color.dsTextSecondary)
                }
                Button("Skip") { skipped = true }.buttonStyle(.dsQuiet)
            } else if !settings.voiceLaunch.commands.isEmpty {
                Text("Commands are already set up.")
            } else {
                Text("Open apps and search Google or YouTube.")
                    .foregroundStyle(Color.dsTextSecondary)
                HStack(spacing: DSSpace.s) {
                    Button("Turn on starter commands") { enable() }
                    Button("Skip") { skipped = true }.buttonStyle(.dsQuiet)
                }
                if let problem { Text(problem).foregroundStyle(Color.dsWarning) }
            }
        }
        .font(.dsBody)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func enable() {
        var added = false
        settings.updateVoiceLaunch { config in
            added = WelcomeCommandStarter.add(to: &config)
            if added { starterIDs = Set(config.commands.map(\.id)) }
        }
        if added { enabledAt = Date() }
        else if settings.voiceLaunch.commands.isEmpty { problem = "Starter commands are unavailable. You can finish setup now." }
    }
}
