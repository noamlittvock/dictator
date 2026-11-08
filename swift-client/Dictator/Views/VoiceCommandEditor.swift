import AppKit
import SwiftUI

/// Adds or edits one shortcut: its name, what you say (a sentence builder with
/// a live preview), what should happen (plain actions) and which words get
/// cleaned up. Nothing here shows how it works underneath.
struct VoiceCommandEditor: View {
    @State var voiceCommand: VoiceCommand
    @State private var builder: SentenceBuilder
    @State private var sentenceEditable: Bool
    let isNew: Bool
    let onSave: (VoiceCommand) -> Void
    @State private var settings = AppSettings.shared
    @State private var saveProblem: VoiceSaveProblem?
    @State private var teachingTrigger = false
    @Environment(\.dismiss) private var dismiss

    init(voiceCommand: VoiceCommand, isNew: Bool, onSave: @escaping (VoiceCommand) -> Void) {
        _voiceCommand = State(initialValue: voiceCommand)
        self.isNew = isNew
        self.onSave = onSave
        let empty = voiceCommand.pattern.trimmingCharacters(in: .whitespaces).isEmpty
        let parsed = empty ? SentenceBuilder() : SentenceBuilder(pattern: voiceCommand.pattern)
        _builder = State(initialValue: parsed ?? SentenceBuilder())
        _sentenceEditable = State(initialValue: parsed != nil)
    }

    private var config: VoiceLaunchConfig { settings.voiceLaunch }

    private var textSlots: [String] {
        guard case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern) else { return [] }
        return parsed.slots.filter { $0.list == nil }.map(\.name)
    }

    /// What's wrong right now, in plain words. A missing name isn't
    /// mentioned until Save.
    private var liveProblem: String? {
        var draft = voiceCommand
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = "This command" }
        return triggerProblem(for: draft) ?? VoiceBuildProblems.problem(for: config, editing: draft)
    }

    var body: some View {
        DSSheet(title: isNew ? VoiceBuildCopy.newCommand : VoiceBuildCopy.editCommand, width: .wide, height: 720) {
            VStack(alignment: .leading, spacing: DSSpace.l) {
                field(VoiceBuildCopy.nameLabel, TextField(VoiceBuildCopy.namePlaceholder, text: $voiceCommand.name))
                sentenceSection
                VoiceActionsView(steps: $voiceCommand.steps, pattern: voiceCommand.pattern, cleanUpSlot: voiceCommand.cleanUpSlot, config: config)
                if !textSlots.isEmpty { cleanUpSection }
                VoiceAppScopeSection(apps: $voiceCommand.onlyInApps)
                VoiceCommandTriggersView(command: $voiceCommand, config: config)
                HStack(spacing: DSSpace.m) {
                    Text(VoiceBuildCopy.turnedOn).font(.dsBodyMedium)
                    Spacer()
                    Toggle(VoiceBuildCopy.turnedOn, isOn: $voiceCommand.enabled).labelsHidden().toggleStyle(.switch)
                }
                if let problem = saveProblem?.message(for: voiceCommand) ?? liveProblem {
                    Text(problem).font(.dsSecondary).foregroundStyle(Color.dsWarning).fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button(VoiceBuildCopy.cancelButton) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(isNew ? VoiceBuildCopy.addButton : "Save") { save() }
                .buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
        }
        .onChange(of: builder) { _, new in
            if sentenceEditable { voiceCommand.pattern = new.pattern }
        }
        .sheet(isPresented: $teachingTrigger) {
            VoiceTeachSheet(
                title: VoiceBuildCopy.teachTitle(voiceCommand.triggerWords.joined(separator: " ")),
                phrase: VoiceTeach.phrase(forTrigger: voiceCommand),
                isTrigger: true,
                target: .trigger(commandId: voiceCommand.id, commands: config.commands.filter { $0.id != voiceCommand.id } + [voiceCommand])
            ) { aliases in
                voiceCommand.triggerAliases.append(contentsOf: aliases)
            }
        }
    }

    // MARK: Sentence

    @ViewBuilder private var sentenceSection: some View {
        if sentenceEditable {
            VoiceSentenceBuilderView(
                builder: $builder,
                alsoListenFor: $voiceCommand.triggerAliases,
                config: config,
                onEnsureList: { name, fields in settings.updateVoiceLaunch { $0.addList(named: name, fields: fields) } },
                onTeach: { voiceCommand.pattern = builder.pattern; teachingTrigger = true })
        } else {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text(VoiceBuildCopy.whatDoYouSay).font(.dsSection).foregroundStyle(Color.dsTextPrimary)
                SpokenPhraseView(segments: SentenceBuilder.exampleSegments(pattern: voiceCommand.pattern, config: config))
                Text(VoiceBuildCopy.sentenceOtherWay).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                Button(VoiceBuildCopy.startAgain) {
                    builder = SentenceBuilder()
                    voiceCommand.pattern = ""
                    sentenceEditable = true
                }
            }
        }
    }

    // MARK: Clean-up

    private var cleanUpSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            HStack(spacing: DSSpace.m) {
                Text(VoiceBuildCopy.cleanUpTitle).font(.dsBodyMedium)
                Spacer()
                Toggle(VoiceBuildCopy.cleanUpTitle, isOn: Binding(
                    get: { voiceCommand.cleanUpSlot != nil },
                    set: { on in voiceCommand.cleanUpSlot = on ? VoiceStep.Kind.mainWords(pattern: voiceCommand.pattern, cleanUpSlot: nil) : nil }))
                    .labelsHidden().toggleStyle(.switch)
            }
            Text(VoiceBuildCopy.cleanUpHelp).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
        }
    }

    private func field<Content: View>(_ title: String, _ content: Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            Text(title).font(.dsSection).foregroundStyle(Color.dsTextSecondary)
            content
        }
    }

    private func triggerProblem(for command: VoiceCommand) -> String? {
        VoiceCommandHotkeys.problem(for: command, commands: config.commands,
            routines: settings.workspaceLaunch.routines, triggers: settings.hotkeyTriggers)
    }

    private func save() {
        voiceCommand.name = voiceCommand.name.trimmingCharacters(in: .whitespacesAndNewlines)
        voiceCommand.pattern = voiceCommand.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if !textSlots.contains(voiceCommand.cleanUpSlot ?? "") { voiceCommand.cleanUpSlot = nil }
        if voiceCommand.name.isEmpty { saveProblem = VoiceSaveProblem(VoiceBuildCopy.giveName, voiceCommand); return }
        if let reason = triggerProblem(for: voiceCommand) ?? VoiceBuildProblems.problem(for: config, editing: voiceCommand) {
            saveProblem = VoiceSaveProblem(reason, voiceCommand)
            return
        }
        onSave(voiceCommand)
        dismiss()
    }
}

/// What Save found wrong, kept only while the shortcut is exactly as it was
/// then: once anything is edited, the live check takes over, so a fixed name
/// doesn't keep its old warning.
struct VoiceSaveProblem: Equatable {
    var text: String
    var voiceCommand: VoiceCommand

    init(_ text: String, _ voiceCommand: VoiceCommand) {
        self.text = text
        self.voiceCommand = voiceCommand
    }

    func message(for current: VoiceCommand) -> String? {
        current == voiceCommand ? text : nil
    }
}
