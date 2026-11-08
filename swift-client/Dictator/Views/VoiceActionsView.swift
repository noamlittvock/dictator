import AppKit
import SwiftUI

/// "What should happen?": numbered cards in plain words, each with Edit,
/// move and remove, and a menu to add another.
struct VoiceActionsView: View {
    @Binding var steps: [VoiceStep]
    let pattern: String
    let cleanUpSlot: String?
    let config: VoiceLaunchConfig

    /// What an action can use: what you say, and the answers of Shortcuts before it.
    private func values(before index: Int) -> [InsertableValue] {
        InsertableValue.available(pattern: pattern, config: config, before: Array(steps.prefix(index)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(VoiceBuildCopy.whatShouldHappen).font(.dsSection).foregroundStyle(Color.dsTextPrimary)
            Text(VoiceBuildCopy.whatShouldHappenHelp).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            if steps.isEmpty {
                DSEmptyState(title: VoiceBuildCopy.noActions)
            }
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                VoiceActionCard(step: binding(for: step.id), number: index + 1, values: values(before: index), pattern: pattern, config: config,
                                typesAnswer: steps.typingAnswer(of: step.id) != nil,
                                onTypeAnswer: { steps.setTypingAnswer(of: step.id, $0) },
                                canMoveUp: index > 0, canMoveDown: index < steps.count - 1,
                                onMove: { steps.move(step.id, by: $0) },
                                onRemove: { steps.removeAll { $0.id == step.id } })
            }
            Menu(VoiceBuildCopy.addAction) {
                ForEach(VoiceBuildCopy.addable(), id: \.self) { kind in
                    Button(VoiceBuildCopy.actionLabel(kind)) { steps.addAction(kind, pattern: pattern, cleanUpSlot: cleanUpSlot) }
                }
                Button(VoiceBuildCopy.typeTheAnswer) { steps.addTypeAnswer() }
                    .disabled(!steps.contains { $0.kind == .runAppleShortcut })
            }
            .fixedSize()
            .disabled(steps.count >= VoiceLaunchConfig.maxStepsPerCommand)
            if steps.contains(where: \.isActing) {
                Text(VoiceBuildCopy.pauseHelp).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func binding(for id: String) -> Binding<VoiceStep> {
        Binding(
            get: { steps.first { $0.id == id } ?? VoiceStep(id: id, kind: .typeText) },
            set: { new in
                guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
                let enablingBackground = new.background == true && steps[i].background != true
                steps[i] = new
                if enablingBackground, !steps.prefix(i).contains(where: { $0.kind == .confirm }) {
                    steps.insert(VoiceStep(kind: .confirm, text: VoiceStep.defaultConfirmSummary(pattern: pattern, cleanUpSlot: cleanUpSlot),
                                           seconds: VoiceStep.defaultConfirmSeconds), at: i)
                }
            })
    }
}

/// One action: a plain title and summary, and its settings when editing.
private struct VoiceActionCard: View {
    @Binding var step: VoiceStep
    let number: Int
    let values: [InsertableValue]
    let pattern: String
    let config: VoiceLaunchConfig
    let typesAnswer: Bool
    let onTypeAnswer: (Bool) -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let onRemove: () -> Void
    @State private var editing: Bool
    @State private var settings = AppSettings.shared
    @State private var pasted = ""
    @State private var exampleNote: String?
    @State private var exampleValue: String = ""

    init(step: Binding<VoiceStep>, number: Int, values: [InsertableValue], pattern: String, config: VoiceLaunchConfig,
         typesAnswer: Bool, onTypeAnswer: @escaping (Bool) -> Void, canMoveUp: Bool, canMoveDown: Bool, onMove: @escaping (Int) -> Void, onRemove: @escaping () -> Void) {
        _step = step
        self.number = number
        self.values = values
        self.pattern = pattern
        self.config = config
        self.typesAnswer = typesAnswer
        self.onTypeAnswer = onTypeAnswer
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.onMove = onMove
        self.onRemove = onRemove
        _editing = State(initialValue: Self.needsSetup(step.wrappedValue))
    }

    /// A new action that can't work until it is set up opens straight away.
    private static func needsSetup(_ step: VoiceStep) -> Bool {
        func blank(_ text: String?) -> Bool { (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        switch step.kind {
        case .openLink: return blank(step.link) || step.link == "https://"
        case .openApp: return blank(step.bundleId) && blank(step.text)
        case .runWorkspace: return blank(step.workspaceId) && blank(step.text)
        case .runInTerminal: return blank(step.folder) || (step.background == true && blank(step.command))
        case .runAppleShortcut: return blank(step.shortcutName)
        case .webhook: return blank(step.link) || step.link == "https://"
        case .appendToFile: return blank(step.path)
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.xs) {
                DSStepBadge(number: number)
                VStack(alignment: .leading, spacing: DSSpace.hair) {
                    Text(VoiceBuildCopy.cardTitle(step)).font(.dsBodyMedium).foregroundStyle(Color.dsTextPrimary)
                    Text(VoiceBuildCopy.summary(step, values: values, routines: settings.workspaceLaunch.routines)).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                        .lineLimit(2)
                }
                Spacer()
                Button(editing ? VoiceBuildCopy.done : VoiceBuildCopy.edit) { editing.toggle() }
                Button { onMove(-1) } label: { Image(systemName: "arrow.up").font(.dsIcon) }.buttonStyle(.dsQuiet).disabled(!canMoveUp).accessibilityLabel(VoiceBuildCopy.moveUp)
                Button { onMove(1) } label: { Image(systemName: "arrow.down").font(.dsIcon) }.buttonStyle(.dsQuiet).disabled(!canMoveDown).accessibilityLabel(VoiceBuildCopy.moveDown)
                Button(action: onRemove) { Image(systemName: "trash").font(.dsIcon) }.buttonStyle(.dsQuiet).accessibilityLabel(VoiceBuildCopy.removeAction)
            }
            if editing { fields }
        }
        .padding(DSSpace.m)
        .dsCardSurface()
    }

    // MARK: Settings

    @ViewBuilder private var fields: some View {
        switch step.kind {
        case .openLink: website
        case .openApp:
            HStack {
                Text(appName).font(.dsBody).foregroundStyle(Color.dsTextSecondary)
                Spacer()
                Button(VoiceBuildCopy.chooseApp) { chooseApp() }
            }
            labeled("App name", VoiceValueField(text: Binding(get: { step.text ?? "" }, set: { step.text = $0; step.bundleId = nil }), values: values))
        case .runWorkspace:
            Picker("Routine", selection: Binding(get: { step.workspaceId ?? "" }, set: { id in
                step.workspaceId = id.isEmpty ? nil : id
                if !id.isEmpty { step.text = nil }
            })) {
                Text("The name I say").tag("")
                ForEach(settings.workspaceLaunch.routines) { routine in Text(routine.name).tag(routine.id) }
                if let id = step.workspaceId, !settings.workspaceLaunch.routines.contains(where: { $0.id == id }) {
                    Text("Removed routine").tag(id)
                }
            }
            if step.workspaceId == nil {
                labeled("Routine name", VoiceValueField(text: bind(\.text), values: values))
            }
        case .waitForTextField:
            HStack {
                Text(VoiceBuildCopy.giveUpAfter).font(.dsBody).foregroundStyle(Color.dsTextSecondary)
                Stepper(value: Binding(get: { step.seconds ?? VoiceStep.defaultWaitSeconds }, set: { step.seconds = $0 }), in: 1...60, step: 1) {
                    Text("\(Int(step.seconds ?? VoiceStep.defaultWaitSeconds)) seconds").font(.dsBody)
                }
            }
        case .typeText:
            labeled(VoiceBuildCopy.whatToType, VoiceValueField(text: bind(\.text), values: values, lines: 2))
        case .runInTerminal: assistant
        case .pressKey:
            Picker(VoiceBuildCopy.keyLabel, selection: Binding(get: { step.key ?? "return" }, set: { step.key = $0 })) {
                ForEach(VoiceStep.keys, id: \.self) { Text(VoiceBuildCopy.keyChoice($0)).tag($0) }
            }.fixedSize()
        case .confirm:
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                labeled(VoiceBuildCopy.whatToShow, VoiceValueField(text: bind(\.text), values: values))
                Stepper(value: Binding(get: { step.seconds ?? VoiceStep.defaultConfirmSeconds }, set: { step.seconds = $0 }), in: 1...30, step: 1) {
                    Text("Wait \(Int(step.seconds ?? VoiceStep.defaultConfirmSeconds)) seconds").font(.dsBody)
                }
            }
        case .runAppleShortcut:
            VoiceAppleShortcutFields(step: $step, values: values, typesAnswer: typesAnswer, onTypeAnswer: onTypeAnswer)
        case .webhook:
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                labeled(VoiceBuildCopy.webhookAddress, TextField("https://…", text: bind(\.link)).textFieldStyle(.roundedBorder))
                Text(VoiceBuildCopy.webhookHelp).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            }
        case .appendToFile:
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                labeled(VoiceBuildCopy.fileLabel, HStack {
                    TextField("/path/to/file.txt", text: bind(\.path)).textFieldStyle(.roundedBorder)
                    Button(VoiceBuildCopy.chooseFolder) { chooseFile() }
                })
                labeled(VoiceBuildCopy.lineToAdd, VoiceValueField(text: bind(\.text), values: values))
            }
        }
    }

    private var appName: String {
        let id = step.bundleId ?? ""
        return id.isEmpty ? VoiceBuildCopy.noAppChosen : (VoiceAppNames.name(for: id) ?? id)
    }

    // MARK: Website, built from an example

    private var wordsChoices: [InsertableValue] { values.filter { $0.kind == .words || $0.kind == .someone } }

    private var website: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(VoiceBuildCopy.websiteFromExample).font(.dsSection).foregroundStyle(Color.dsTextSecondary)
            Text(VoiceBuildCopy.websiteExampleHelp).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            HStack {
                TextField(VoiceBuildCopy.pasteAddressPlaceholder, text: $pasted).textFieldStyle(.roundedBorder)
                Button(VoiceBuildCopy.useThisAddress) { useExample() }.disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if wordsChoices.count > 1 {
                Picker(VoiceBuildCopy.putInPlaceOfTest, selection: Binding(
                    get: { chosenValue?.template ?? "" }, set: { exampleValue = $0 })) {
                    ForEach(wordsChoices) { Text($0.name).tag($0.template) }
                }.fixedSize()
            }
            if let exampleNote {
                Text(exampleNote).font(.dsSecondary).foregroundStyle(exampleNote == VoiceBuildCopy.addressAdded ? Color.dsTextTertiary : Color.dsWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(VoiceBuildCopy.editAddress) {
                labeled(VoiceBuildCopy.addressLabel, VoiceValueField(text: bind(\.link), values: values, lines: 2))
                    .padding(.top, DSSpace.xxs)
            }
            .font(.dsSecondary)
        }
    }

    private var chosenValue: InsertableValue? {
        wordsChoices.first { $0.template == exampleValue } ?? wordsChoices.first { $0.kind == .words } ?? wordsChoices.first
    }

    private func useExample() {
        guard let value = chosenValue else { exampleNote = VoiceBuildCopy.needWordsFirst; return }
        switch ExampleAddress.convert(pasted, value: value.template) {
        case .converted(let link):
            step.link = link
            exampleNote = VoiceBuildCopy.addressAdded
            pasted = ""
        case .notFound: exampleNote = VoiceBuildCopy.testNotFound
        case .notAnAddress: exampleNote = VoiceBuildCopy.notAnAddress
        }
    }

    // MARK: Coding assistant

    private var assistant: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.m) {
                Text("Run in the background").font(.dsBodyMedium)
                Spacer()
                Toggle("Run in the background", isOn: Binding(get: { step.background == true }, set: { step.background = $0 ? true : nil }))
                    .labelsHidden().toggleStyle(.switch)
            }
            Text("No Terminal window. Dictator tells you if it fails.")
                .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            if step.background != true {
                labeled(VoiceBuildCopy.assistantLabel, Picker("", selection: Binding(
                    get: { step.command ?? VoiceLaunchConfig.defaultAgentCommand },
                    set: { step.command = $0 })) {
                    ForEach(CodingAssistant.allCases) { Text($0.name).tag($0.command) }
                    let current = step.command ?? VoiceLaunchConfig.defaultAgentCommand
                    if CodingAssistant.named(forCommand: current).assistant == nil { Text(current).tag(current) }
                }.labelsHidden().fixedSize())
            }
            labeled(step.background == true ? "Command (required)" : "Command", TextField("Command", text: Binding(
                get: { step.command ?? (step.background == true ? "" : VoiceLaunchConfig.defaultAgentCommand) },
                set: { step.command = $0 })).textFieldStyle(.roundedBorder))
            if step.background == true {
                Stepper(value: Binding(get: { step.timeoutSeconds ?? VoiceStep.defaultBackgroundTimeout }, set: { step.timeoutSeconds = $0 }), in: 1...VoiceStep.maximumBackgroundTimeout, step: 1) {
                    Text("Stop after \(Int(step.timeoutSeconds ?? VoiceStep.defaultBackgroundTimeout)) seconds").font(.dsBody)
                }
            }
            labeled(VoiceBuildCopy.folderLabel, HStack {
                Picker("", selection: Binding(
                    get: { (step.folder ?? "").hasPrefix("{") ? (step.folder ?? "") : "" },
                    set: { new in if !new.isEmpty || (step.folder ?? "").hasPrefix("{") { step.folder = new } })) {
                    Text(folderText).tag("")
                    ForEach(folderValues) { Text("The \($0.name)").tag($0.template) }
                }.labelsHidden().fixedSize()
                if !(step.folder ?? "").hasPrefix("{") { Button(VoiceBuildCopy.chooseFolder) { chooseFolder() } }
            })
            labeled(VoiceBuildCopy.whatToGiveIt, VoiceValueField(text: bind(\.argument), values: values))
            if step.background != true {
                labeled(VoiceBuildCopy.openInLabel, HStack {
                    Picker("", selection: $settings.voiceCommandTerminalApp) {
                        Text("Terminal").tag("terminal")
                        ForEach(ToolCatalog.shared.hostApps.filter { host in
                            host.id != "terminal" && host.kind == .terminal && host.runsScripts && host.bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
                        }) { Text($0.name).tag($0.id) }
                    }.labelsHidden().fixedSize()
                    Text(VoiceBuildCopy.openInHelp).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                })
            }
        }
    }

    private var folderValues: [InsertableValue] { values.filter { $0.kind == .detail && $0.template.hasSuffix(".folder}") } }

    private var folderText: String {
        let folder = step.folder ?? ""
        return folder.isEmpty || folder.hasPrefix("{") ? VoiceBuildCopy.aFolderIChoose : (folder as NSString).lastPathComponent
    }

    // MARK: Helpers

    private func bind(_ keyPath: WritableKeyPath<VoiceStep, String?>) -> Binding<String> {
        Binding(get: { step[keyPath: keyPath] ?? "" }, set: { step[keyPath: keyPath] = $0 })
    }

    private func labeled<Content: View>(_ title: String, _ content: Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            Text(title).font(.dsSection).foregroundStyle(Color.dsTextTertiary)
            content
        }
    }

    private func chooseApp() {
        if let id = VoiceAppPicker.choose().first { step.bundleId = id; step.text = nil }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = VoiceBuildCopy.chooseFileMessage
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { step.path = url.path }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { step.folder = url.path }
    }
}
