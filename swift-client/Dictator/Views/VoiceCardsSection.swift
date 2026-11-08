import AppKit
import SwiftUI

/// The things you can say. A line at the top says what is on now; a short
/// "How to say it" explains the sentence shapes; then compact cards under
/// headings (Message someone, Search the web…). Each card is one line: where
/// it goes (an app or website icon), its title, what to say, and an On / Off
/// switch. Clicking a card opens it, one at a time, to show the sentence in
/// its shapes, what happens, and its settings. Turning a card on asks at
/// most one plain question, then opens the card if it has settings.
struct VoiceCardsSection: View {
    @State private var settings = AppSettings.shared
    @State private var cardProblems: [String: String] = [:]
    @State private var asking: VoiceCard?
    @State private var open: String?
    let onEdit: (String) -> Void
    let onShowPeople: () -> Void

    init(openCard: String? = nil, onEdit: @escaping (String) -> Void, onShowPeople: @escaping () -> Void) {
        _open = State(initialValue: openCard)
        self.onEdit = onEdit
        self.onShowPeople = onShowPeople
    }

    private var config: VoiceLaunchConfig { settings.voiceLaunch }

    var body: some View {
        let cards = VoiceCards.cards(in: config, routines: settings.workspaceLaunch.routines)
        VStack(alignment: .leading, spacing: DSSpace.l) {
            onNow(cards.filter(\.isOn))
            VoiceHowToSay(startsOpen: !cards.contains(where: \.isOn))
            ForEach(VoiceCards.groups(cards)) { group in
                SettingsSectionCard(title: group.title) {
                    ForEach(Array(group.cards.enumerated()), id: \.element.id) { index, card in
                        if index > 0 { SettingsDivider() }
                        cardRow(card)
                    }
                }
            }
        }
        .sheet(item: $asking) { card in
            VoiceCardQuestionSheet(card: card) { mode, folders, shortcutMode in
                settings.updateVoiceLaunch { config in
                    if let conflict = VoiceCards.conflict(for: card.id, in: config) {
                        cardProblems[card.id] = conflict
                        return
                    }
                    if !folders.isEmpty { VoiceCards.addProjects(folders, to: &config) }
                    cardProblems[card.id] = VoiceCards.turnOn(card.id, in: &config, whatsAppMode: mode ?? .checkFirst, shortcutMode: shortcutMode ?? .pause)
                }
                open = card.id
                if card.ask == .shortcuts, cardProblems[card.id] == nil { Task { await VoiceLaunchActing.refreshYourShortcuts(force: true) } }
            }
        }
    }

    // MARK: What is on

    @ViewBuilder private func onNow(_ on: [VoiceCard]) -> some View {
        if on.isEmpty {
            DSEmptyState(title: BrandVoice.nothingOn)
        } else {
            FlowRow(spacing: DSSpace.xs) {
                Text(BrandVoice.onNow).font(.dsSecondaryMedium).foregroundStyle(Color.dsTextSecondary).padding(.trailing, DSSpace.hair)
                ForEach(on) { card in
                    Button { withAnimation(.easeInOut(duration: 0.15)) { open = card.id } } label: {
                        HStack(spacing: DSSpace.xxs) {
                            VoiceIconView(source: card.icon, size: 18)
                            Text(card.title).font(.dsSecondary).foregroundStyle(Color.dsTextPrimary)
                        }
                        .padding(.leading, DSSpace.xxs).padding(.trailing, DSSpace.xs).padding(.vertical, DSSpace.hair)
                        .background(Color.dsSurfaceCard, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.dsBorderSubtle, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Show \(card.title)")
                }
            }
        }
    }

    // MARK: A card

    private func cardRow(_ card: VoiceCard) -> some View {
        let isOpen = open == card.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DSSpace.s) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { open = isOpen ? nil : card.id } } label: {
                    HStack(spacing: DSSpace.s) {
                        Image(systemName: "chevron.right").font(.dsIconSmall)
                            .rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(Color.dsTextTertiary).frame(width: 10)
                        VoiceIconView(source: card.icon, size: 30, dimmed: !card.isOn)
                        VStack(alignment: .leading, spacing: DSSpace.hair) {
                            Text(card.title).font(.dsBodyMedium)
                                .foregroundStyle(Color.dsTextPrimary)
                            Self.sayLine(VoiceCards.segments(for: card, config: config))
                                .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary).lineLimit(1)
                        }
                        Spacer(minLength: DSSpace.xs)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(card.title)
                .accessibilityHint(isOpen ? "Hides the details" : "Shows what to say and what happens")
                Toggle(card.title, isOn: binding(card)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help(card.isOn ? "On" : "Off")
            }
            .padding(.horizontal, DSSpace.m).padding(.vertical, DSSpace.s)
            if let problem = cardProblems[card.id] {
                Text(problem).font(.dsSecondary).foregroundStyle(Color.dsWarning)
                    .padding(.horizontal, DSSpace.m).padding(.bottom, DSSpace.s)
            }
            if isOpen {
                details(card)
                    .padding(.leading, DSSpace.xxl).padding(.trailing, DSSpace.m).padding(.bottom, DSSpace.m)
            }
        }
    }

    /// The example in one line: the start word bold, a name medium, your words italic.
    static func sayLine(_ segments: [PhraseSegment]) -> Text {
        segments.reduce(Text("Say ").foregroundColor(.dsTextTertiary)) { line, segment in
            let part: Text
            switch segment.role {
            case .opens: part = Text(segment.text).fontWeight(.semibold).foregroundColor(.dsTextPrimary)
            case .who, .which: part = Text(segment.text).fontWeight(.medium).foregroundColor(.dsTextPrimary)
            case .words: part = Text(segment.text).italic()
            case .plain: part = Text(segment.text)
            }
            return line + Text(" ") + part
        }
    }

    @ViewBuilder private func details(_ card: VoiceCard) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            HStack(alignment: .center, spacing: DSSpace.xs) {
                Text("Say").font(.dsCaptionMedium).foregroundStyle(Color.dsTextTertiary)
                SpokenPhraseView(segments: VoiceCards.segments(for: card, config: config), showsCaptions: false)
            }
            if !card.does.isEmpty {
                Label { Text(card.does) } icon: { Image(systemName: "arrow.turn.down.right") }
                    .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if usesPeople(card) { peopleLine }
            if card.isOn {
                switch card.ask {
                case .whatsapp?: whatsAppMode
                case .projects?: VoiceProjectsRows()
                case .shortcuts?: shortcutMode
                case nil: EmptyView()
                }
            } else if card.ask != nil {
                Text("Turn it on to choose how it works.").font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            }
            if card.isCustom {
                HStack(spacing: DSSpace.xs) {
                    Button("Edit") { onEdit(card.id) }
                    Button("Remove", role: .destructive) {
                        settings.updateVoiceLaunch { $0.commands.removeAll { $0.id == card.id } }
                    }.buttonStyle(.dsDestructive)
                }
            }
        }
    }

    private func usesPeople(_ card: VoiceCard) -> Bool {
        guard case .success(let parsed) = VoicePattern.parse(card.pattern) else { return false }
        return parsed.slots.contains { $0.list.map(SpokenPhrase.isPeople) ?? false }
    }

    private var peopleLine: some View {
        let names = VoicePeople.people(in: config).map(\.displayName)
        return HStack(spacing: DSSpace.xs) {
            Image(systemName: "person.2").font(.dsIconSmall).foregroundStyle(Color.dsTextTertiary)
            Text(names.isEmpty ? "No one in People yet." : "You can say " + Self.list(names))
                .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary).lineLimit(1)
            Button(names.isEmpty ? "Add people…" : "Edit people…", action: onShowPeople).buttonStyle(.dsLink)
        }
    }

    /// "Dana, Sam and 3 more".
    static func list(_ names: [String], limit: Int = 3) -> String {
        if names.count <= limit {
            return names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
        return names.prefix(limit).joined(separator: ", ") + " and \(names.count - limit) more"
    }

    private func binding(_ card: VoiceCard) -> Binding<Bool> {
        Binding(
            get: { card.isOn },
            set: { on in
                if !on {
                    settings.updateVoiceLaunch { config in
                        if card.isCustom { VoiceCards.setCustom(card.id, on: false, in: &config) } else { VoiceCards.turnOff(card.id, in: &config) }
                    }
                } else if card.isCustom {
                    settings.updateVoiceLaunch { VoiceCards.setCustom(card.id, on: true, in: &$0) }
                } else if let conflict = VoiceCards.conflict(for: card.id, in: config) {
                    cardProblems[card.id] = conflict
                } else if needsQuestion(card) {
                    cardProblems[card.id] = nil
                    asking = card
                } else {
                    settings.updateVoiceLaunch { cardProblems[card.id] = VoiceCards.turnOn(card.id, in: &$0) }
                    if card.ask != nil { open = card.id }
                }
            })
    }

    private func needsQuestion(_ card: VoiceCard) -> Bool {
        switch card.ask {
        case .whatsapp?: !card.isAdded
        case .projects?: VoiceCards.projects(in: config).isEmpty
        case .shortcuts?: !card.isAdded
        case nil: false
        }
    }

    private var shortcutMode: some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            Picker("Before running", selection: Binding(
                get: { VoiceCards.shortcutMode(in: config) ?? .pause },
                set: { mode in settings.updateVoiceLaunch { cardProblems[VoiceCards.runShortcutCard] = VoiceCards.setShortcutMode(mode, in: &$0) } })) {
                Text("3 seconds to cancel").tag(ShortcutRunMode.pause)
                Text("Run right away").tag(ShortcutRunMode.rightAway)
            }
            .pickerStyle(.segmented).fixedSize()
            if VoiceCards.shortcutMode(in: config) == .pause {
                Text("You’ll have 3 seconds to press Esc.").font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
            }
        }
    }

    private var whatsAppMode: some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            Picker("Before sending", selection: Binding(
                get: { VoiceCards.whatsAppMode(in: config) ?? .checkFirst },
                set: { mode in settings.updateVoiceLaunch { cardProblems["whatsapp"] = VoiceCards.setWhatsAppMode(mode, in: &$0) } })) {
                Text("Let me check first").tag(WhatsAppMode.checkFirst)
                Text("Send right away").tag(WhatsAppMode.sendRightAway)
            }
            .pickerStyle(.segmented).fixedSize()
            if VoiceCards.whatsAppMode(in: config) == .sendRightAway {
                Text("You’ll have 3 seconds to press Esc.").font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
            }
        }
    }
}

/// The one question a card asks when you turn it on.
struct VoiceCardQuestionSheet: View {
    let card: VoiceCard
    /// The chosen way to send (WhatsApp) and the folders chosen (Claude Code).
    let onTurnOn: (WhatsAppMode?, [String], ShortcutRunMode?) -> Void
    @State private var mode: WhatsAppMode = .checkFirst
    @State private var shortcutMode: ShortcutRunMode = .pause
    @State private var folders: [String] = []
    @State private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DSSheet(title: card.title, width: .compact) {
            switch card.ask {
            case .whatsapp?: whatsApp
            case .projects?: projects
            case .shortcuts?: shortcuts
            case nil: EmptyView()
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Turn on") { onTurnOn(card.ask == .whatsapp ? mode : nil, folders, card.ask == .shortcuts ? shortcutMode : nil); dismiss() }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(card.ask == .projects && folders.isEmpty)
        }
    }

    private var whatsApp: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text("Send it right away, or let me check first?").font(.dsBody).foregroundStyle(Color.dsTextSecondary)
            Picker("", selection: $mode) {
                Text("Let me check first").tag(WhatsAppMode.checkFirst)
                Text("Send right away").tag(WhatsAppMode.sendRightAway)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if mode == .sendRightAway {
                Text("You’ll have 3 seconds to press Esc.").font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text("Run it right away, or give me 3 seconds to cancel?").font(.dsBody).foregroundStyle(Color.dsTextSecondary)
            Picker("", selection: $shortcutMode) {
                Text("Give me 3 seconds to cancel").tag(ShortcutRunMode.pause)
                Text("Run right away").tag(ShortcutRunMode.rightAway)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            Text("A Shortcut can do anything you built it to do, so the pause is the safe choice.")
                .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text("Which projects?").font(.dsBody).foregroundStyle(Color.dsTextSecondary)
            ForEach(folders, id: \.self) { folder in
                HStack {
                    Image(systemName: "folder")
                    Text((folder as NSString).lastPathComponent).font(.dsBody)
                    Spacer()
                    Button { folders.removeAll { $0 == folder } } label: { Image(systemName: "xmark.circle.fill").font(.dsIcon) }.buttonStyle(.plain).accessibilityLabel("Remove \((folder as NSString).lastPathComponent)")
                }
            }
            Button("Add a folder…") { for folder in VoiceFolderPicker.choose() where !folders.contains(folder) { folders.append(folder) } }
            HStack {
                Picker("Open it in", selection: $settings.voiceCommandTerminalApp) {
                    Text("Terminal").tag("terminal")
                    ForEach(ToolCatalog.shared.hostApps.filter { host in
                        host.id != "terminal" && host.kind == .terminal && host.runsScripts && host.bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
                    }) { Text($0.name).tag($0.id) }
                }.fixedSize()
                Text("This Mac only.").font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            }
        }
    }
}

enum VoiceFolderPicker {
    /// Asks for one or more folders; empty when cancelled.
    @MainActor static func choose() -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }
}

/// The Projects row inside the Claude Code card: each project's name (you
/// can change it) and folder, and a way to add more.
struct VoiceProjectsRows: View {
    @State private var settings = AppSettings.shared
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text("Projects").font(.dsSection).foregroundStyle(Color.dsTextSecondary)
            ForEach(VoiceCards.projects(in: settings.voiceLaunch)) { project in
                VoiceProjectRow(project: project) { name in
                    var reason: String?
                    settings.updateVoiceLaunch { reason = VoiceCards.renameProject(id: project.id, to: name, in: &$0) }
                    problem = reason
                    return reason
                } onRemove: {
                    settings.updateVoiceLaunch { VoiceCards.removeProject(id: project.id, from: &$0) }
                }
            }
            if let problem { Text(problem).font(.dsCaption).foregroundStyle(Color.dsWarning) }
            Button("Add a folder…") {
                let folders = VoiceFolderPicker.choose()
                if !folders.isEmpty { settings.updateVoiceLaunch { VoiceCards.addProjects(folders, to: &$0) } }
            }
        }
    }
}

private struct VoiceProjectRow: View {
    let project: VoiceListEntry
    /// Saves the new name; returns a plain reason when it can't.
    let onRename: (String) -> String?
    let onRemove: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: "folder").foregroundStyle(Color.dsTextTertiary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 160).focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            Text(((project.values["folder"] ?? "") as NSString).lastPathComponent)
                .font(.dsCaption).foregroundStyle(Color.dsTextTertiary).lineLimit(1)
            Spacer()
            Button(action: onRemove) { Image(systemName: "trash").font(.dsIcon) }.buttonStyle(.dsQuiet).accessibilityLabel("Remove \(project.displayName)")
        }
        .onAppear { name = project.displayName }
        .onChange(of: project.displayName) { _, new in if !focused { name = new } }
    }

    private func commit() {
        guard name != project.displayName else { return }
        if onRename(name) != nil { name = project.displayName }
    }
}
