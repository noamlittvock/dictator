import AppKit
import SwiftUI

/// The settings of "Run an Apple Shortcut": pick one from this Mac's list,
/// what it is given, how long to wait, and what to do with its answer.
struct VoiceAppleShortcutFields: View {
    @Binding var step: VoiceStep
    let values: [InsertableValue]
    let typesAnswer: Bool
    let onTypeAnswer: (Bool) -> Void
    @State private var shortcuts: [AppleShortcutInfo] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var listFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            labeled(VoiceBuildCopy.chooseShortcut, HStack {
                Picker("", selection: Binding(get: { selectedId }, set: { choose($0) })) {
                    Text(VoiceBuildCopy.chooseShortcutPlaceholder).tag("")
                    if !currentIsListed, !name.isEmpty { Text("\(name) (\(VoiceBuildCopy.shortcutNotInList))").tag(currentTag) }
                    ForEach(shortcuts) { Text($0.name).tag($0.id) }
                }.labelsHidden().fixedSize()
                Button(VoiceBuildCopy.refreshShortcuts) { Task { await refresh() } }.disabled(loading)
                Button(VoiceBuildCopy.openInShortcuts) { openInShortcuts() }.disabled(name.isEmpty)
                Button(VoiceBuildCopy.newShortcutButton) { VoiceShortcutsApp.open() }
            })
            if listFailed {
                Text(VoiceBuildCopy.shortcutListFailed).font(.dsSecondary).foregroundStyle(Color.dsWarning)
            }
            labeled(VoiceBuildCopy.appleShortcutName, TextField("", text: Binding(
                get: { step.shortcutName ?? "" },
                set: { step.shortcutName = $0; step.shortcutId = nil })).textFieldStyle(.roundedBorder))
            Text(VoiceBuildCopy.shortcutHelp).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            labeled(VoiceBuildCopy.whatToSend, Picker("", selection: Binding(
                get: { step.sendsEverything }, set: { step.inputMode = $0 ? VoiceStep.inputJSON : VoiceStep.inputText })) {
                Text(VoiceBuildCopy.sendEverything).tag(true)
                Text(VoiceBuildCopy.sendJustWords).tag(false)
            }.labelsHidden().fixedSize())
            if !step.sendsEverything {
                labeled(VoiceBuildCopy.whatToGiveIt, VoiceValueField(text: Binding(get: { step.text ?? "" }, set: { step.text = $0 }), values: values))
            }
            HStack {
                Text(VoiceBuildCopy.timeLimit).font(.dsBody).foregroundStyle(Color.dsTextSecondary)
                Picker("", selection: Binding(get: { step.timeoutSeconds ?? VoiceStep.defaultShortcutTimeout },
                                              set: { step.timeoutSeconds = $0 == VoiceStep.defaultShortcutTimeout ? nil : $0 })) {
                    ForEach(VoiceStep.shortcutTimeoutChoices, id: \.self) { Text(VoiceBuildCopy.seconds(Int($0))).tag($0) }
                }.labelsHidden().fixedSize()
            }
            HStack(spacing: DSSpace.m) {
                Text(VoiceBuildCopy.doesntSend).font(.dsBodyMedium)
                Spacer()
                Toggle(VoiceBuildCopy.doesntSend, isOn: Binding(get: { step.readOnly == true }, set: { step.readOnly = $0 ? true : nil }))
                    .labelsHidden().toggleStyle(.switch)
            }
            Text(VoiceBuildCopy.doesntSendHelp).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            HStack(spacing: DSSpace.m) {
                Text(VoiceBuildCopy.typeItsAnswer).font(.dsBodyMedium)
                Spacer()
                Toggle(VoiceBuildCopy.typeItsAnswer, isOn: Binding(get: { typesAnswer }, set: onTypeAnswer))
                    .labelsHidden().toggleStyle(.switch)
            }
            labeled(VoiceBuildCopy.answerPartsLabel, TextField(VoiceBuildCopy.answerPartsPlaceholder, text: Binding(
                get: { (step.answerDetails ?? []).joined(separator: ", ") },
                set: { step.answerDetails = Self.details($0) })).textFieldStyle(.roundedBorder))
            Text(VoiceBuildCopy.answerPartsHelp).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            Text(VoiceBuildCopy.shortcutResponsibility).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { if !loaded { await refresh() } }
    }

    /// Names as typed, split at commas; anything but letters, digits and _ is dropped.
    static func details(_ text: String) -> [String]? {
        let names = text.split(separator: ",").map {
            String($0.trimmingCharacters(in: .whitespaces).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }.map(Character.init))
        }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : Array(names.prefix(20))
    }

    private var name: String { step.shortcutName ?? "" }
    private var currentTag: String { step.shortcutId.flatMap { $0.isEmpty ? nil : $0 } ?? name }
    private var currentIsListed: Bool { VoiceShortcutList.match(name: name, identifier: step.shortcutId, in: shortcuts) != nil }
    private var selectedId: String {
        if let match = VoiceShortcutList.match(name: name, identifier: step.shortcutId, in: shortcuts) { return match.id }
        return name.isEmpty ? "" : currentTag
    }

    private func choose(_ id: String) {
        guard let info = shortcuts.first(where: { $0.id == id }) else { return }
        step.shortcutName = info.name
        step.shortcutId = info.identifier
    }

    private func refresh() async {
        loading = true
        let list = await VoiceLaunchActing.listShortcuts(services: .live)
        loading = false
        loaded = true
        listFailed = list == nil
        if let list { shortcuts = list }
    }

    private func openInShortcuts() {
        let name = self.name
        Task { _ = await VoiceLaunchActing.viewShortcut(name: name, services: .live) }
    }

    private func labeled<Content: View>(_ title: String, _ content: Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            Text(title).font(.dsSection).foregroundStyle(Color.dsTextTertiary)
            content
        }
    }
}

enum VoiceShortcutsApp {
    /// Opens the Shortcuts app so a new Shortcut can be made there.
    @MainActor static func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
