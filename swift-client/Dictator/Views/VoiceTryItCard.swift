import SwiftUI

/// Type a sentence and see what it would do. Nothing is run.
struct VoiceTryItCard: View {
    @State private var settings = AppSettings.shared
    @State private var sentence = ""

    var body: some View {
        SettingsSectionCard(title: VoiceBuildCopy.tryIt, footer: VoiceBuildCopy.tryItFooter) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                TextField(VoiceBuildCopy.tryItPlaceholder, text: $sentence).textFieldStyle(.roundedBorder)
                if !sentence.trimmingCharacters(in: .whitespaces).isEmpty {
                    answer(VoiceTryItResult.result(for: sentence, in: settings.voiceLaunch))
                }
            }
            .padding(DSSpace.m)
        }
    }

    @ViewBuilder private func answer(_ result: VoiceTryItResult) -> some View {
        switch result {
        case .noMatch(let reason):
            DSEmptyState(title: reason)
        case .nearMiss(let miss):
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text(miss.kind == .entry ? "Nothing would run yet." : VoiceTryItResult.explain(.noneMatched))
                    .font(.dsBody).foregroundStyle(Color.dsTextSecondary).fixedSize(horizontal: false, vertical: true)
                VoiceNearMissFixView(
                    miss: miss,
                    onEntry: { span, entryId in
                        var problem: String?
                        switch VoiceNearMissFix.fixEntry(miss, span: span, entryId: entryId, in: settings.voiceLaunch) {
                        case .failure(let reason): problem = reason.message
                        case .success(let fix): settings.updateVoiceLaunch { $0 = fix.config }
                        }
                        return problem
                    },
                    onVoiceCommand: { commandId in
                        switch VoiceNearMissFix.fixTrigger(miss, commandId: commandId, in: settings.voiceLaunch) {
                        case .failure(let reason): return reason.message
                        case .success(let config): settings.updateVoiceLaunch { $0 = config }; return nil
                        }
                    })
            }
        case .matched(let name, let slots, _):
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text("Runs “\(name)”").font(.dsSection).foregroundStyle(Color.dsTextPrimary)
                if let voiceCommand = settings.voiceLaunch.commands.first(where: { $0.name == name }) {
                    SpokenPhraseView(segments: SpokenPhrase.segments(
                        pattern: voiceCommand.pattern,
                        values: Dictionary(slots.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })))
                }
                if let sentence = VoiceTryItResult.actionSentence(for: sentence, in: settings.voiceLaunch, routines: settings.workspaceLaunch.routines) {
                    VStack(alignment: .leading, spacing: DSSpace.hair) {
                        Text(VoiceBuildCopy.wouldDo).font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                        Text(sentence).font(.dsSecondaryMedium).foregroundStyle(Color.dsTextPrimary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if case .plan(let plan) = VoiceLaunchEngine.plan(for: sentence, in: settings.voiceLaunch) {
                    let problems = VoiceLaunchReadiness.problems(for: plan, services: .live,
                        appInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
                        folderExists: {
                            var isDirectory: ObjCBool = false
                            let path = ($0 as NSString).expandingTildeInPath
                            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                        })
                    if problems.isEmpty {
                        Text("Ready on \(Host.current().localizedName ?? "this Mac")")
                            .font(.dsSecondaryMedium).foregroundStyle(Color.dsTextSecondary)
                    } else {
                        VStack(alignment: .leading, spacing: DSSpace.xxs) {
                            ForEach(problems.indices, id: \.self) { index in
                                Text(problems[index]).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
