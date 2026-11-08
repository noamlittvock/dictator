import AppKit
import SwiftUI

/// The parts of the Voice launch page, one at a time.
enum VoiceLaunchTab: Hashable {
    case say, people, shortcuts
}

/// The "Commands" page. Tabs keep it short: the things you can say
/// (compact cards that open one at a time), the people you can say them to,
/// and your Apple Shortcuts once that card is on. "Build a command…" sits at
/// the top and opens the advanced view (`VoiceAdvancedView`): what you say,
/// what should happen, lists and a box to try a sentence.
struct VoiceLaunchView: View {
    @State private var navigation = AppNavigation.shared
    @State private var settings = AppSettings.shared
    @State private var showAdvanced = false
    @State private var editing: VoiceCommand?
    @State private var tab: VoiceLaunchTab
    private let openCard: String?

    /// `tab` and `openCard` choose what shows first (the snapshots use them).
    init(tab: VoiceLaunchTab = .say, openCard: String? = nil) {
        _tab = State(initialValue: tab)
        self.openCard = openCard
    }

    private var showsShortcuts: Bool {
        VoiceCards.cards(in: settings.voiceLaunch).contains { $0.id == VoiceCards.runShortcutCard && $0.isAdded }
    }

    var body: some View {
        Group {
            if showAdvanced {
                VoiceAdvancedView { showAdvanced = false }
            } else {
                DSPage(
                    title: SidebarItem.voiceLaunch.title,
                    summary: VoiceBuildCopy.howToSay(keys: settings.hotkeyTriggers.commands),
                    brief: HelpLibrary.brief(.commands, keys: settings.hotkeyTriggers)
                ) {
                    Button("Build a command…") { showAdvanced = true }
                        .buttonStyle(.dsPrimary)
                        .help("Set a phrase and the actions it runs, such as opening an app, website or Apple Shortcut.")
                } content: {
                    HStack(spacing: DSSpace.s) {
                        DSTabs(selection: $tab, items: tabItems)
                            .accessibilityLabel("Show")
                        Spacer()
                        CommandFileButtons()
                    }
                    switch tab == .shortcuts && !showsShortcuts ? .say : tab {
                    case .say:
                        VoiceCardsSection(openCard: openCard,
                                          onEdit: { id in editing = settings.voiceLaunch.commands.first { $0.id == id } },
                                          onShowPeople: { tab = .people })
                    case .people: VoicePeopleSection()
                    case .shortcuts: VoiceYourShortcutsSection()
                    }
                }
                .sheet(item: $editing) { voiceCommand in
                    VoiceCommandEditor(voiceCommand: voiceCommand, isNew: false) { saved in
                        settings.updateVoiceLaunch { config in
                            if let index = config.commands.firstIndex(where: { $0.id == saved.id }) { config.commands[index] = saved }
                        }
                    }
                }
            }
        }
        .onAppear { consumeVoiceCommandNavigation() }
        .onChange(of: navigation.voiceCommandID) { _, _ in consumeVoiceCommandNavigation() }
    }

    private func consumeVoiceCommandNavigation() {
        guard let id = navigation.voiceCommandID else { return }
        showAdvanced = false
        editing = settings.voiceLaunch.commands.first { $0.id == id }
        navigation.voiceCommandID = nil
    }

    private var tabItems: [(value: VoiceLaunchTab, title: String)] {
        var items: [(value: VoiceLaunchTab, title: String)] = [(.say, "Things to say"), (.people, peopleTitle)]
        if showsShortcuts { items.append((.shortcuts, "Apple Shortcuts")) }
        return items
    }

    private var peopleTitle: String {
        let count = VoicePeople.people(in: settings.voiceLaunch).count
        return count == 0 ? "People" : "People (\(count))"
    }
}

/// How a sentence is built, in the same shapes the cards use: the start
/// word, a person or project, your own words. Open at first; once something
/// is on it folds to one line you can open again.
struct VoiceHowToSay: View {
    @State private var open: Bool

    init(startsOpen: Bool) { _open = State(initialValue: startsOpen) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: DSSpace.xs) {
                    Image(systemName: "chevron.right").font(.dsIconSmall)
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(Color.dsTextTertiary).frame(width: 10)
                    Image(systemName: "questionmark.circle").foregroundStyle(Color.dsTextSecondary)
                    Text(BrandVoice.howToSayIt).font(.dsSection).foregroundStyle(Color.dsTextPrimary)
                    if !open {
                        Text("Start word, then who, then your words").font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, DSSpace.m).padding(.vertical, DSSpace.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the explanation" : "Shows how a sentence is built")
            if open {
                VStack(alignment: .leading, spacing: DSSpace.s) {
                    FlowRow(spacing: DSSpace.s) {
                        step(.opens("YouTube"), "Start word", "Picks what happens")
                        arrow
                        step(.who("Dana"), "Someone or a project", "Only for some")
                        arrow
                        step(PhraseSegment(text: "your own words", role: .words, label: nil), "Anything else", "Your message or search")
                    }
                    Text("If Dictator doesn’t hear a start word it knows, your words are copied to the clipboard instead.")
                        .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DSSpace.m).padding(.bottom, DSSpace.m)
            }
        }
        .dsCardSurface()
    }

    private func step(_ segment: PhraseSegment, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            PhraseChip(segment: segment)
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                Text(title).font(.dsSecondaryMedium).foregroundStyle(Color.dsTextPrimary)
                Text(detail).font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.dsIconSmall).foregroundStyle(Color.dsTextTertiary)
            .padding(.top, DSSpace.xxs)
    }
}

/// Build a command: every command in plain words, the lists, and a box to try
/// a sentence. Nothing here is needed for the cards.
struct VoiceAdvancedView: View {
    let onBack: () -> Void
    @State private var settings = AppSettings.shared
    @State private var editing: VoiceCommand?
    @State private var isNew = false
    @State private var editingList: VoiceList?

    var body: some View {
        let commands = settings.voiceLaunch.commands
        DSPage(title: SidebarItem.voiceLaunch.title, summary: VoiceBuildCopy.pageSummary, brief: HelpLibrary.brief(.buildCommand)) {
            makeOwnButton.buttonStyle(.dsPrimary)
        } content: {
            HStack {
                Button { onBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.dsQuiet)
                Spacer()
            }
            SettingsSectionCard(title: VoiceBuildCopy.yourCommands, footer: VoiceBuildCopy.unmatchedFooter) {
                if commands.isEmpty {
                    DSEmptyState(title: VoiceBuildCopy.noCommands, detail: VoiceBuildCopy.noCommandsHelp) { makeOwnButton }
                } else {
                    ForEach(commands) { voiceCommand in
                        commandRow(voiceCommand)
                        SettingsDivider()
                    }
                    SettingsRow(title: "Make your own") { makeOwnButton }
                }
            }

            VoiceListsSection(editingList: $editingList)

            VoiceTryItCard()
        }
        .sheet(item: $editing) { voiceCommand in
            VoiceCommandEditor(voiceCommand: voiceCommand, isNew: isNew) { saved in
                settings.updateVoiceLaunch { config in
                    if let index = config.commands.firstIndex(where: { $0.id == saved.id }) { config.commands[index] = saved } else { config.commands.append(saved) }
                }
            }
        }
        .sheet(item: $editingList) { list in
            VoiceListEditor(list: list, config: settings.voiceLaunch) { saved in
                var reason: String?
                settings.updateVoiceLaunch { reason = $0.save(saved) }
                return reason
            }
        }
    }

    private func commandRow(_ voiceCommand: VoiceCommand) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.s) {
                Text(voiceCommand.name).font(.dsBodyMedium).foregroundStyle(Color.dsTextPrimary)
                Spacer()
                Toggle("On", isOn: enabledBinding(voiceCommand.id)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                Button(VoiceBuildCopy.edit) { isNew = false; editing = voiceCommand }
                Button {
                    settings.updateVoiceLaunch { $0.commands.removeAll { $0.id == voiceCommand.id } }
                } label: { Image(systemName: "trash").font(.dsIcon) }
                    .buttonStyle(.dsQuiet)
                    .accessibilityLabel(VoiceBuildCopy.removeNamed(voiceCommand.name))
            }
            SpokenPhraseView(segments: SentenceBuilder.exampleSegments(pattern: voiceCommand.pattern, config: settings.voiceLaunch))
                .opacity(voiceCommand.enabled ? 1 : 0.6)
            if let note = VoiceAppPicker.scopeNote(voiceCommand.onlyInApps) {
                Text(note).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            }
            Text(VoiceBuildCopy.summary(of: voiceCommand.steps, routines: settings.workspaceLaunch.routines)).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
        }
        .padding(.horizontal, DSSpace.m).padding(.vertical, DSSpace.s)
    }

    private var makeOwnButton: some View {
        Button(VoiceBuildCopy.makeYourOwn) {
            isNew = true
            editing = VoiceCommand(name: "", pattern: "", steps: [])
        }
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.voiceLaunch.commands.first { $0.id == id }?.enabled ?? false },
            set: { on in settings.updateVoiceLaunch { config in
                if let index = config.commands.firstIndex(where: { $0.id == id }) { config.commands[index].enabled = on }
            } }
        )
    }

}
