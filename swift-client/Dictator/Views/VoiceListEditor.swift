import SwiftUI

/// The "Lists" section of the page: people, projects, or anything else you
/// can say by name.
struct VoiceListsSection: View {
    @State private var settings = AppSettings.shared
    @Binding var editingList: VoiceList?
    @State private var problem: String?

    var body: some View {
        let lists = settings.voiceLaunch.lists
        SettingsSectionCard(
            title: VoiceBuildCopy.yourLists,
            footer: VoiceBuildCopy.listsFooter
        ) {
            if lists.isEmpty {
                DSEmptyState(title: VoiceBuildCopy.noLists, detail: VoiceBuildCopy.noListsHelp) { newButton }
            } else {
                ForEach(lists) { list in
                    SettingsRow(title: list.name, detail: VoiceYourShortcuts.isYourShortcuts(list) ? "Filled from the Shortcuts app; you can’t edit it here." : Self.summary(list)) {
                        if !VoiceYourShortcuts.isYourShortcuts(list) {
                            HStack(spacing: DSSpace.s) {
                                Button("Edit") { editingList = list }
                                Button { remove(list) } label: { Image(systemName: "trash").font(.dsIcon) }.buttonStyle(.dsQuiet)
                                    .accessibilityLabel(VoiceBuildCopy.removeNamed(list.name))
                            }
                        }
                    }
                    SettingsDivider()
                }
                SettingsRow(title: VoiceBuildCopy.newListRow, detail: problem, detailColor: .dsWarning) { newButton }
            }
        }
    }

    private var newButton: some View {
        Button(VoiceBuildCopy.newList) {
            // Saved only when the editor's Save is pressed.
            editingList = settings.voiceLaunch.newListDraft(named: "New list")
        }
        .disabled(settings.voiceLaunch.lists.count >= VoiceLaunchConfig.maxLists)
    }

    private func remove(_ list: VoiceList) {
        var reason: String?
        settings.updateVoiceLaunch { reason = $0.removeList(id: list.id) }
        problem = reason
    }

    static func summary(_ list: VoiceList) -> String {
        let count = list.entries.count
        let entries = count == 1 ? "1 entry" : "\(count) entries"
        return list.fields.isEmpty ? entries : "\(entries) · \(list.fields.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "))"
    }
}

/// Edits one list: its name, its details (fields) and its entries.
struct VoiceListEditor: View {
    @State var list: VoiceList
    let config: VoiceLaunchConfig
    /// Saves; returns a plain reason when it can't.
    let onSave: (VoiceList) -> String?
    @State private var newField = ""
    @State private var problem: String?
    @State private var teaching: TeachRequest?
    @Environment(\.dismiss) private var dismiss

    private struct TeachRequest: Identifiable { var id: String }

    var body: some View {
        DSSheet(title: VoiceBuildCopy.editList, width: .standard, height: 600) {
            VStack(alignment: .leading, spacing: DSSpace.l) {
                labeled(VoiceBuildCopy.listNameLabel, TextField("People", text: $list.name))
                fieldsSection
                entriesSection
                if let problem {
                    Text(problem).font(.dsSecondary).foregroundStyle(Color.dsWarning).fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { save() }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
        }
        .sheet(item: $teaching) { request in
            if let index = list.entries.firstIndex(where: { $0.id == request.id }) {
                let entry = list.entries[index]
                VoiceTeachSheet(
                    title: VoiceBuildCopy.teachTitle(entry.displayName),
                    phrase: VoiceTeach.phrase(for: entry, in: list, config: config),
                    isTrigger: false,
                    target: .entry(list: list, entryId: entry.id)
                ) { aliases in
                    list.entries[index].names.append(contentsOf: aliases)
                }
            }
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(VoiceBuildCopy.detailsTitle).font(.dsSection).foregroundStyle(Color.dsTextSecondary)
            HStack(spacing: DSSpace.xs) {
                ForEach(list.fields, id: \.self) { field in
                    HStack(spacing: DSSpace.xxs) {
                        Text(field).font(.dsSecondary)
                        Button { removeField(field) } label: { Image(systemName: "xmark.circle.fill").font(.dsIcon) }.buttonStyle(.plain).accessibilityLabel(VoiceBuildCopy.removeNamed(field))
                    }
                    .padding(.horizontal, DSSpace.xs).padding(.vertical, DSSpace.hair)
                    .background(Color.dsSurfaceControl, in: Capsule())
                }
                TextField(VoiceBuildCopy.addDetailPlaceholder, text: $newField).frame(width: 190).onSubmit(addField)
                Button(VoiceBuildCopy.addButton, action: addField).disabled(newField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(VoiceBuildCopy.detailsHelp)
                .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
        }
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(VoiceBuildCopy.entriesTitle).font(.dsSection).foregroundStyle(Color.dsTextSecondary)
            ForEach($list.entries) { $entry in
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    HStack {
                        TextField(VoiceBuildCopy.entryNamePlaceholder, text: Binding(
                            get: { entry.names.first ?? "" },
                            set: { new in
                                if entry.names.isEmpty { entry.names = [new] } else { entry.names[0] = new }
                            }))
                        Button(VoiceBuildCopy.teach) { teaching = TeachRequest(id: entry.id) }
                            .disabled(entry.displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                            .help(VoiceBuildCopy.teachHelp)
                        Button { list.entries.removeAll { $0.id == entry.id } } label: { Image(systemName: "trash").font(.dsIcon) }.buttonStyle(.dsQuiet)
                            .accessibilityLabel(VoiceBuildCopy.removeEntry)
                    }
                    TextField(VoiceBuildCopy.alsoCalledPlaceholder, text: Binding(
                        get: { entry.names.dropFirst().joined(separator: ", ") },
                        set: { new in entry.names = [entry.names.first ?? ""] + VoiceListEntry.names(from: new) }))
                    ForEach(list.fields, id: \.self) { field in
                        HStack {
                            Text(field).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary).frame(width: 90, alignment: .leading)
                            TextField("", text: Binding(get: { entry.values[field] ?? "" }, set: { entry.values[field] = $0 }))
                        }
                    }
                }
                .padding(DSSpace.m)
                .dsCardSurface()
            }
            Button(VoiceBuildCopy.addEntry) { list.entries.append(VoiceListEntry(names: [])) }
                .disabled(list.entries.count >= VoiceLaunchConfig.maxEntriesPerList)
            Text(VoiceBuildCopy.entriesHelp)
                .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
        }
    }

    /// The setting's own reasons talk about "fields"; here they are details.
    static func plain(_ reason: String) -> String {
        reason.replacingOccurrences(of: "Field names", with: "Detail names").replacingOccurrences(of: "the field", with: "the detail")
            .replacingOccurrences(of: "field", with: "detail")
    }

    private func labeled<Content: View>(_ title: String, _ content: Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            Text(title).font(.dsSection).foregroundStyle(Color.dsTextSecondary)
            content
        }
    }

    private func addField() {
        let field = SentenceBuilder.slotName(from: newField, avoiding: [], fallback: "detail")
        guard !newField.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard !field.isEmpty, !list.fields.contains(field) else { return }
        list.fields.append(field)
        newField = ""
    }

    private func removeField(_ field: String) {
        list.fields.removeAll { $0 == field }
        for index in list.entries.indices { list.entries[index].values[field] = nil }
    }

    private func save() {
        list.name = list.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Entries left blank are dropped rather than reported.
        list.entries.removeAll { $0.names.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } && $0.values.values.allSatisfy(\.isEmpty) }
        for index in list.entries.indices {
            list.entries[index].names = list.entries[index].names.map { $0.trimmingCharacters(in: .whitespaces) }
            if list.entries[index].names.first?.isEmpty == true, list.entries[index].names.count > 1 { list.entries[index].names.removeFirst() }
        }
        if let reason = onSave(list) {
            problem = Self.plain(reason)
            return
        }
        dismiss()
    }
}
