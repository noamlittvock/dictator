import SwiftUI

/// The one-click fix for a near miss, shared by the notice on screen and
/// the "Try it" box: what was heard, coloured by role, with the unknown name
/// as "norm?", then "Did you mean…?" and up to three names. Suggestions are
/// ordered by how close they sound, but nothing is saved until the person clicks.
struct VoiceNearMissFixView: View {
    let miss: VoiceNearMiss
    /// Returns a plain reason when the choice can't be saved.
    let onEntry: (_ span: Int, _ entryId: String) -> String?
    let onVoiceCommand: (_ commandId: String) -> String?
    @State private var settings = AppSettings.shared
    @State private var problem: String?

    private var config: VoiceLaunchConfig { settings.voiceLaunch }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            switch miss.kind {
            case .entry: entryBody
            case .trigger: triggerBody
            }
            if let problem {
                Text(problem).font(.dsSecondary).foregroundStyle(Color.dsWarning).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Entry

    private var list: VoiceList? { config.list(named: miss.listName ?? "") ?? config.lists.first { $0.id == miss.listId } }

    /// The first heard word(s) are the name; nothing asks how long it is.
    static let defaultSpan = 0

    private var entryBody: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            SpokenPhraseView(segments: SpokenPhrase.segments(for: miss, config: config))
            if let list {
                let ranked = VoiceLaunchEngine.rankedEntries(heard: miss.heardSpans.first ?? miss.heard, in: list)
                FlowRow(spacing: DSSpace.xs) {
                    Text("Did you mean…?").font(.dsSecondaryMedium).foregroundStyle(Color.dsTextSecondary)
                    ForEach(ranked.prefix(VoiceLaunchEngine.maxNearMissCandidates), id: \.entryId) { candidate in
                        Button(candidate.name) { problem = onEntry(Self.defaultSpan, candidate.entryId) }
                            .buttonStyle(.dsSecondary).controlSize(.small)
                    }
                    if ranked.count > VoiceLaunchEngine.maxNearMissCandidates {
                        Menu("Someone else…") {
                            ForEach(ranked, id: \.entryId) { candidate in
                                Button(candidate.name) { problem = onEntry(Self.defaultSpan, candidate.entryId) }
                            }
                        }
                        .fixedSize().controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Trigger

    private var triggerBody: some View {
        let options = config.commands.filter { $0.enabled && miss.offers($0) && VoiceLaunchEngine.triggerAliasCandidate(miss, for: $0) != nil }
        return HStack(spacing: DSSpace.xs) {
            Text("Didn’t catch which command. Make “\(miss.heard)” mean…")
                .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary).fixedSize(horizontal: false, vertical: true)
            if !options.isEmpty {
                Menu("Choose…") {
                    ForEach(options) { voiceCommand in
                        let alias = VoiceLaunchEngine.triggerAliasCandidate(miss, for: voiceCommand) ?? ""
                        let title = VoiceCards.title(for: voiceCommand)
                        // Shows the exact words that would be saved when they differ from what is named above.
                        Button(VoiceLaunchText.key(alias) == VoiceLaunchText.key(miss.heard) ? title : "\(title) (“\(alias)”)") {
                            problem = onVoiceCommand(voiceCommand.id)
                        }
                    }
                }
                .fixedSize().controlSize(.small)
            }
        }
    }
}
