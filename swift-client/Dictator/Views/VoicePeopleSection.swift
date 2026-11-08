import AppKit
import Contacts
import ContactsUI
import SwiftUI

/// "People": who you can say by name, with what Dictator can do for each.
struct VoicePeopleSection: View {
    @State private var settings = AppSettings.shared
    @State private var editing: PersonDraft?
    @State private var isNew = false
    @State private var checking: String?
    @State private var contacts = ContactsPicker()
    @State private var contactsProblem: String?

    var body: some View {
        let people = VoicePeople.people(in: settings.voiceLaunch)
        SettingsSectionCard(title: "People", footer: "The names you can say after a start word like WhatsApp or Email.") {
            if people.isEmpty {
                DSEmptyState(title: "No one yet", detail: "Add a person, then say their name after WhatsApp or Email.")
                SettingsDivider()
            }
            ForEach(people) { person in
                HStack(spacing: DSSpace.s) {
                    PersonAvatar(name: person.displayName)
                    VStack(alignment: .leading, spacing: DSSpace.hair) {
                        Text(person.displayName).font(.dsBodyMedium).foregroundStyle(Color.dsTextPrimary)
                        if let note = VoicePeople.missingNote(person) {
                            Text(note).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(VoicePeople.badges(person), id: \.self) { badge in
                        Text(badge).font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                            .padding(.horizontal, DSSpace.xs).padding(.vertical, DSSpace.hair)
                            .background(Color.dsSurfaceControl, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.dsBorderSubtle, lineWidth: 1))
                            .help("Can be reached by \(badge)")
                    }
                    Button("Check name") { checking = person.id }
                        .help("Say the name out loud and see how Dictator hears it.")
                    Button("Edit") { isNew = false; editing = VoicePeople.draft(person) }
                }
                .padding(.horizontal, DSSpace.m).padding(.vertical, DSSpace.s)
                SettingsDivider()
            }
            SettingsRow(title: "Add a person", detail: contactsProblem, detailColor: .dsWarning) {
                HStack(spacing: DSSpace.s) {
                    Button("Add from Contacts") { contacts.show() }
                        .background(ContactsAnchor(picker: contacts))
                    Button("Add") { isNew = true; editing = PersonDraft() }
                }
            }
        }
        .onAppear {
            contacts.onPick = { draft in
                contactsProblem = draft.name.isEmpty ? "That contact has no name to say." : nil
                if !draft.name.isEmpty { isNew = true; editing = draft }
            }
        }
        .sheet(item: Binding(get: { editing.map(DraftBox.init) }, set: { editing = $0?.draft })) { box in
            VoicePersonEditor(draft: box.draft, isNew: isNew) { saved in
                var reason: String?
                settings.updateVoiceLaunch { reason = VoicePeople.save(saved, in: &$0) }
                return reason
            } onRemove: { id in
                settings.updateVoiceLaunch { VoicePeople.remove(id: id, from: &$0) }
            }
        }
        .sheet(item: Binding(get: { checking.map(IdBox.init) }, set: { checking = $0?.id })) { box in
            VoiceCheckNameSheet(entryId: box.id)
        }
    }

    private struct DraftBox: Identifiable { var draft: PersonDraft; var id: String { draft.id ?? "new" } }
    private struct IdBox: Identifiable { var id: String }
}

/// A person's initials in a circle, like Contacts.
struct PersonAvatar: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        let initials = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        Text(initials.isEmpty ? "?" : initials)
            .font(.dsCaptionMedium)
            .foregroundStyle(Color.dsAccent)
            .frame(width: size, height: size)
            .background(Color.dsAccentQuiet, in: Circle())
            .overlay(Circle().strokeBorder(Color.dsAccentQStrong, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Adds or edits a person: a name, a phone number and an email.
struct VoicePersonEditor: View {
    @State var draft: PersonDraft
    let isNew: Bool
    /// Saves; returns a plain reason when it can't.
    let onSave: (PersonDraft) -> String?
    let onRemove: (String) -> Void
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DSSheet(title: isNew ? "Add a person" : "Edit person", width: .compact) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                field("Name you say", TextField("Dana", text: $draft.name))
                field("Phone (for WhatsApp)", TextField("+972 50 123 4567", text: $draft.phone))
                field("Email", TextField("dana@example.com", text: $draft.email))
                if let problem { Text(problem).font(.dsSecondary).foregroundStyle(Color.dsWarning) }
            }
        } leadingActions: {
            if let id = draft.id, !isNew {
                Button("Remove", role: .destructive) { onRemove(id); dismiss() }
                    .buttonStyle(.dsDestructive)
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(isNew ? "Add" : "Save") {
                problem = onSave(draft)
                if problem == nil { dismiss() }
            }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
        }
    }

    private func field<Content: View>(_ title: String, _ content: Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            Text(title).font(.dsSecondaryMedium).foregroundStyle(Color.dsTextSecondary)
            content.textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Contacts

/// Shows the system contact picker. It runs in its own process and hands
/// back only the contact you choose, so Dictator never reads your address
/// book and asks for no Contacts permission.
@MainActor
final class ContactsPicker: NSObject, CNContactPickerDelegate {
    weak var anchor: NSView?
    var onPick: ((PersonDraft) -> Void)?
    private let picker = CNContactPicker()

    func show() {
        guard let anchor else { return }
        picker.delegate = self
        picker.showRelative(to: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func contactPicker(_ picker: CNContactPicker, didSelect contact: CNContact) {
        onPick?(VoicePeople.draft(
            givenName: contact.givenName, familyName: contact.familyName, nickname: contact.nickname, organization: contact.organizationName,
            phones: contact.phoneNumbers.map { $0.value.stringValue }, emails: contact.emailAddresses.map { $0.value as String }))
    }
}

private struct ContactsAnchor: NSViewRepresentable {
    let picker: ContactsPicker
    func makeNSView(context: Context) -> NSView { let view = NSView(); picker.anchor = view; return view }
    func updateNSView(_ view: NSView, context: Context) { picker.anchor = view }
}

// MARK: - Check name

/// "Check name": say the name twice, and Dictator tells you how it heard it.
/// New spellings that belong to nobody else are saved on their own.
struct VoiceCheckNameSheet: View {
    let entryId: String
    var listName = VoiceCards.peopleList
    private enum Stage { case phrase, nameOnly, result }

    @State private var settings = AppSettings.shared
    @State private var session = VoiceTeachSession(takeCount: VoiceCheckName.takeCount)
    @State private var stage: Stage = .phrase
    @State private var outcome: VoiceCheckName.Outcome?
    @State private var heardSegments: [PhraseSegment] = []
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss

    private var config: VoiceLaunchConfig { settings.voiceLaunch }
    private var list: VoiceList? { config.list(named: listName) }
    private var entry: VoiceListEntry? { list?.entries.first { $0.id == entryId } }
    private var name: String { entry?.displayName ?? "" }

    private var phrase: VoiceTeachPhrase {
        guard let entry, let list, stage == .phrase else { return VoiceTeachPhrase(text: name, leadingWords: []) }
        return VoiceTeach.phrase(for: entry, in: list, config: config)
    }

    var body: some View {
        DSSheet(title: "Check name", width: .compact) {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                if stage == .result { result } else { recording }
                if let message = session.message {
                    Text(message).font(.dsSecondary).foregroundStyle(Color.dsWarning).fixedSize(horizontal: false, vertical: true)
                }
            }
        } leadingActions: {
            if stage == .result {
                Button("Check again") { restart() }.buttonStyle(.dsQuiet)
            }
        } actions: {
            if stage == .result {
                Button("Done") { dismiss() }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { session.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: recordTapped) {
                    Label(buttonTitle, systemImage: session.phase == .recording ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(.dsPrimary).disabled(session.phase == .transcribing)
            }
        }
        .onDisappear { session.cancel() }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            if let notice { Text(notice).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary) }
            Text(stage == .nameOnly ? "Say just the name, twice." : "Say this twice.").font(.dsBody).foregroundStyle(Color.dsTextSecondary)
            Text("“\(phrase.text)”").font(.dsStat).foregroundStyle(Color.dsTextPrimary)
            Text("\(min(session.transcripts.count + 1, VoiceCheckName.takeCount)) of \(VoiceCheckName.takeCount)")
                .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            if session.phase == .recording {
                ProgressView(value: Double(min(max(session.level * 4, 0), 1))).frame(width: 220)
                TakeStopCountdown(session: session)
            }
        }
    }

    @ViewBuilder private var result: some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            if !heardSegments.isEmpty { SpokenPhraseView(segments: heardSegments) }
            if let outcome {
                Text(outcome.message(name: name)).font(.dsBody).foregroundStyle(Color.dsTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttonTitle: String {
        switch session.phase {
        case .ready: session.transcripts.isEmpty ? "Record" : "Record again"
        case .recording: "Listening… click to stop"
        case .transcribing: "Working it out…"
        }
    }

    private func recordTapped() {
        if session.phase == .recording { session.stopNow(); return }
        Task {
            await session.record()
            if session.isComplete { finish() }
        }
    }

    private func finish() {
        guard let list, let entry else { return }
        guard let heard = VoiceCheckName.names(from: session.transcripts, phrase: phrase) else {
            // The opening word wasn't heard right: record the name on its own.
            stage = .nameOnly
            notice = "Dictator didn’t catch “\(phrase.leadingWords.joined(separator: " "))”."
            session = VoiceTeachSession(takeCount: VoiceCheckName.takeCount)
            return
        }
        let found = VoiceCheckName.outcome(heard: heard, entryId: entry.id, in: list)
        var saved: [String] = []
        settings.updateVoiceLaunch { saved = VoiceCheckName.save(found, listId: list.id, entryId: entry.id, in: &$0) }
        var shown = found
        shown.toSave = saved
        outcome = shown
        var segments: [PhraseSegment] = []
        if let alias = found.heard.first {
            let lead = phrase.leadingWords.joined(separator: " ")
            if !lead.isEmpty { segments.append(.opens(lead)) }
            segments.append(.who(alias))
        }
        heardSegments = segments
        stage = .result
    }

    private func restart() {
        session.cancel()
        session = VoiceTeachSession(takeCount: VoiceCheckName.takeCount)
        stage = .phrase
        outcome = nil
        notice = nil
    }
}


/// "Your Shortcuts": the Shortcuts on the main Mac you can run by saying
/// "Shortcut" and a name. Read only; you can add other ways to say a name.
struct VoiceYourShortcutsSection: View {
    @State private var settings = AppSettings.shared
    @State private var checking: String?
    @State private var refreshing = false
    @State private var failed = false

    private var canRefresh: Bool { settings.coreRole != .edge }

    var body: some View {
        let entries = VoiceYourShortcuts.entries(in: settings.voiceLaunch)
        SettingsSectionCard(title: "Your Shortcuts",
                            footer: "The Shortcuts on the main Mac. Say “Shortcut” and its name to run it.") {
            if entries.isEmpty {
                DSEmptyState(title: "No Shortcuts yet",
                            detail: failed ? "Dictator couldn’t read the Shortcuts on this Mac." : "Make one in the Shortcuts app, then refresh.") { refreshButton }
            } else {
                ForEach(entries) { entry in
                    SettingsRow(title: entry.displayName, detail: entry.names.count > 1 ? "Also: " + entry.names.dropFirst().joined(separator: ", ") : nil) {
                        Button("Check name") { checking = entry.id }
                    }
                    SettingsDivider()
                }
                SettingsRow(title: "Refresh", detail: failed ? "Couldn’t read the Shortcuts app. Showing the last list." : nil, detailColor: .dsWarning) { refreshButton }
            }
        }
        .task { await refresh() }
        .sheet(item: Binding(get: { checking.map(IdBox.init) }, set: { checking = $0?.id })) { box in
            VoiceCheckNameSheet(entryId: box.id, listName: VoiceCards.shortcutsList)
        }
    }

    @ViewBuilder private var refreshButton: some View {
        if canRefresh { Button("Refresh") { Task { await refresh() } }.disabled(refreshing) }
    }

    private func refresh() async {
        guard canRefresh else { return }
        refreshing = true
        let list = await VoiceLaunchActing.fetchYourShortcuts(role: settings.coreRole, config: settings.voiceLaunch, force: true, services: .live)
        failed = list == nil
        if let list { settings.updateVoiceLaunch { VoiceYourShortcuts.merge(list, into: &$0) } }
        refreshing = false
    }

    private struct IdBox: Identifiable { var id: String }
}
