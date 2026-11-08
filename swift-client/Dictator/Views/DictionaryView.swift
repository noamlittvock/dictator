import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The dictionary's DTOs from `RepositoryHub` instead of a `@Query`. They
/// always come from this Mac's own store, which replication keeps up to
/// date while this Mac is connected to a main Mac.
///
/// Reload discipline: observes only `RepositoryHub.dictionaryVersion` (not
/// the whole hub), and `reload` is generation-guarded — a pending reload
/// replaces the previous one, and only the latest generation's result is
/// ever applied ("latest request wins"). `upsert`/`delete` don't reload
/// themselves; the repository mutation bumps `dictionaryVersion`, and
/// `DictionaryView`'s `.onChange` is the one reload path, so a mutation
/// never double-reloads.
@Observable
@MainActor
final class DictionaryModel {
    private(set) var entries: [DictionaryEntryDTO] = []
    private(set) var isLoading = false
    var loadError: String?

    private var loadGeneration = 0

    func reload(from repositories: Repositories) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        loadError = nil
        do {
            // Match the old `@Query(sort: \DictionaryEntry.pattern)` ordering.
            let loaded = try await repositories.dictionary.entries().sorted { $0.pattern < $1.pattern }
            guard generation == loadGeneration else { return }
            entries = loaded.filter { $0.isForgotten != true }
        } catch {
            guard generation == loadGeneration else { return }
            loadError = error.localizedDescription
        }
        if generation == loadGeneration { isLoading = false }
    }

    func upsert(_ entries: [DictionaryEntryDTO], repositories: Repositories) async {
        guard !entries.isEmpty else { return }
        do {
            try await repositories.dictionary.upsert(entries)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func delete(ids: [UUID], repositories: Repositories) async {
        guard !ids.isEmpty else { return }
        do {
            try await repositories.dictionary.delete(ids: ids)
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Adding

    /// True while an Add is being written; the sheet disables Add so a
    /// second click can't queue a duplicate.
    private(set) var isSaving = false
    /// Why the last Add didn't save, in plain words. The sheet stays open
    /// with the typed values so the user can try again.
    private(set) var saveError: String?

    /// Saves one new entry and reports whether it was written. Nothing is
    /// cleared on failure: the caller keeps its form (and the entry's id,
    /// so a retry updates the same entry instead of adding a second one).
    @discardableResult
    func add(_ entry: DictionaryEntryDTO, repositories: Repositories) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await repositories.dictionary.upsert([entry])
            return true
        } catch {
            saveError = "“\(entry.pattern)” wasn’t saved: \(error.localizedDescription)"
            return false
        }
    }

    func clearSaveError() { saveError = nil }

    // MARK: Deleting with Undo

    private(set) var recentlyDeleted: DictionaryEntryDTO?
    private var deletedGroup: [DictionaryEntryDTO] = []

    func delete(_ entry: DictionaryEntryDTO, repositories: Repositories) async {
        await deleteGroup([entry], repositories: repositories)
    }

    func deleteGroup(_ entries: [DictionaryEntryDTO], repositories: Repositories) async {
        guard let first = entries.first else { return }
        do {
            try await repositories.dictionary.delete(ids: entries.map(\.id))
            deletedGroup = entries
            recentlyDeleted = first
        } catch {
            loadError = "“\(DictionaryWords.spelling(first))” wasn’t deleted: \(error.localizedDescription)"
        }
    }

    func undoDelete(repositories: Repositories) async {
        guard !deletedGroup.isEmpty else { return }
        // Undo restores the same identities and explicitly clears their tombstones.
        let restored = deletedGroup.map { entry in
            var copy = entry
            if copy.origin == "learned" { copy.isForgotten = false }
            return copy
        }
        do {
            try await repositories.dictionary.upsert(restored)
            deletedGroup = []
            recentlyDeleted = nil
        } catch {
            loadError = "The word couldn’t be put back: \(error.localizedDescription)"
        }
    }

    func forgetRecentlyDeleted(_ entry: DictionaryEntryDTO) {
        if recentlyDeleted?.id == entry.id { recentlyDeleted = nil; deletedGroup = [] }
    }

    /// Existing identities and metadata survive edits. New heard-as spellings
    /// get their own rows; only removed spellings are deleted.
    @discardableResult
    func saveWord(word: String, heardAs: [String], original: [DictionaryEntryDTO],
                  newID: UUID, repositories: Repositories) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let writes = DictionaryWords.edited(word: word, heardAs: heardAs, original: original, newID: newID)
        let removed = original.filter { old in !writes.contains { $0.id == old.id } }
        do {
            try await repositories.dictionary.upsert(writes)
            if !removed.isEmpty { try await repositories.dictionary.delete(ids: removed.map(\.id)) }
            return true
        } catch {
            // A multi-call edit can fail after its first write. Restore what was
            // there and remove new rows, retaining the sheet for a safe retry.
            do {
                if !original.isEmpty { try await repositories.dictionary.upsert(original) }
                let added = writes.filter { row in !original.contains { $0.id == row.id } }
                if !added.isEmpty { try await repositories.dictionary.delete(ids: added.map(\.id)) }
            } catch { loadError = "The word couldn’t be restored: \(error.localizedDescription)" }
            saveError = "“\(word)” wasn’t saved: \(error.localizedDescription)"
            return false
        }
    }
}

struct DictionaryWordGroup: Identifiable {
    var spelling: String
    var entries: [DictionaryEntryDTO]
    var id: String { DictionaryImportCandidate.normalize(spelling) }
    var heardAs: [String] {
        var seen = Set<String>()
        return entries.filter { !$0.isVocabulary }.map(\.pattern)
            .filter { seen.insert(DictionaryImportCandidate.normalize($0)).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var starred: Bool { entries.contains { $0.isStarred == true } }
    var learned: Bool { entries.contains { $0.origin == "learned" } }
    var useCount: Int { entries.map { $0.useCount ?? 0 }.max() ?? 0 }
}

enum DictionaryWords {
    static func spelling(_ entry: DictionaryEntryDTO) -> String {
        entry.isVocabulary ? entry.pattern : entry.replacement
    }

    static func groups(_ entries: [DictionaryEntryDTO], search: String = "") -> [DictionaryWordGroup] {
        let active = entries.filter { $0.isForgotten != true }
        let grouped = Dictionary(grouping: active) { DictionaryImportCandidate.normalize(spelling($0)) }
        return grouped.values.compactMap { rows -> DictionaryWordGroup? in
            let rows = rows.sorted { $0.id.uuidString < $1.id.uuidString }
            let spelling = spelling(rows.first(where: \.isVocabulary) ?? rows[0])
            guard search.isEmpty || ([spelling] + rows.map(\.pattern)).contains(where: {
                $0.localizedCaseInsensitiveContains(search)
            }) else { return nil }
            return DictionaryWordGroup(spelling: spelling, entries: rows)
        }.sorted {
            if $0.starred != $1.starred { return $0.starred }
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            return $0.spelling.localizedStandardCompare($1.spelling) == .orderedAscending
        }
    }

    /// The exact filtering used by real dictation, including learned hint-only words.
    static func matching(_ entries: [DictionaryEntryDTO]) -> [[String: String]] {
        entries.filter { $0.isForgotten != true && !($0.origin == "learned" && $0.isVocabulary) }
            .map { ["pattern": $0.pattern, "replacement": $0.replacement] }
    }

    static func edited(word: String, heardAs: [String], original: [DictionaryEntryDTO], newID: UUID) -> [DictionaryEntryDTO] {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = original.first(where: \.isVocabulary) ?? DictionaryEntryDTO(id: newID, pattern: word, replacement: "", isVocabulary: true)
        base.pattern = word
        base.origin = base.origin ?? "manual"
        base.isStarred = original.contains { $0.isStarred == true }
        var seen = Set<String>()
        let rules = heardAs.compactMap { heard -> DictionaryEntryDTO? in
            let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty, seen.insert(heard.lowercased()).inserted else { return nil }
            var rule = original.first { !$0.isVocabulary && $0.pattern.caseInsensitiveCompare(heard) == .orderedSame }
                ?? DictionaryEntryDTO(id: UUID(), pattern: heard, replacement: word, isVocabulary: false)
            rule.pattern = heard
            rule.replacement = word
            rule.origin = rule.origin ?? "manual"
            rule.isStarred = base.isStarred
            return rule
        }
        return [base] + rules
    }

    static func importing(_ candidates: [DictionaryImportCandidate], existing: [DictionaryEntryDTO], replace: Bool) -> [DictionaryEntryDTO] {
        let byKey = DictionaryImportParser.existingEntriesByKey(existing.filter { $0.isForgotten != true })
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard seen.insert(candidate.key).inserted else { return nil }
            if var old = byKey[candidate.key] {
                guard replace, old.replacement != candidate.replacement else { return nil }
                old.pattern = candidate.pattern
                old.replacement = candidate.replacement
                old.origin = "imported"
                return old
            }
            return DictionaryEntryDTO(id: UUID(), pattern: candidate.pattern, replacement: candidate.replacement,
                                      isVocabulary: candidate.isVocabulary, origin: "imported")
        }
    }

    static func export(_ entries: [DictionaryEntryDTO]) -> String {
        "# Dictator words 1\n" + entries.filter { $0.isForgotten != true }.map { entry in
            let plain = entry.isVocabulary ? entry.pattern : "\(entry.pattern) -> \(entry.replacement)"
            // Old plain text remains the format for ordinary words. An escaped
            // line preserves arrows, comment prefixes and embedded newlines too.
            if entry.pattern.contains("->") || entry.pattern.hasPrefix("#") || entry.pattern.hasPrefix("@word ") ||
                entry.pattern.contains(where: \.isNewline) || entry.replacement.contains(where: \.isNewline) ||
                entry.pattern != entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines) ||
                entry.replacement != entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines) {
                let fields = [entry.pattern, entry.replacement, entry.isVocabulary ? "word" : "rule"]
                let data = try! JSONEncoder().encode(fields)
                return "@word " + String(decoding: data, as: UTF8.self)
            }
            return plain
        }.sorted().joined(separator: "\n") + "\n"
    }
}

/// Shared by welcome and Dictionary: a tap always makes an explicit On/Off
/// choice, including when the current choice came from installed apps.
enum DictionaryFields {
    static func isOn(_ id: String, automatic: Bool, on: [String], off: [String], automaticIDs: [String]) -> Bool {
        !off.contains(id) && (on.contains(id) || (automatic && automaticIDs.contains(id)))
    }
    static func toggle(_ id: String, automatic: Bool, on: inout [String], off: inout [String], automaticIDs: [String]) {
        let wasOn = isOn(id, automatic: automatic, on: on, off: off, automaticIDs: automaticIDs)
        on.removeAll { $0 == id }; off.removeAll { $0 == id }
        if wasOn { off.append(id) } else { on.append(id) }
    }
}

struct DictionaryFieldChips: View {
    @Binding var on: [String]
    @Binding var off: [String]
    var automatic = true
    var installed: Set<String> = []

    private var automaticIDs: [String] { VocabularyPackCatalog.automaticIDs(installedBundleIDs: installed) }
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            DictionaryChipLayout {
                ForEach(VocabularyPackCatalog.all.filter { $0.alwaysOn != true }.sorted { $0.name < $1.name }) { field in
                    let selected = DictionaryFields.isOn(field.id, automatic: automatic, on: on, off: off, automaticIDs: automaticIDs)
                    let fromApps = automatic && automaticIDs.contains(field.id) && !on.contains(field.id) && !off.contains(field.id)
                    Button {
                        DictionaryFields.toggle(field.id, automatic: automatic, on: &on, off: &off, automaticIDs: automaticIDs)
                    } label: {
                        HStack(spacing: DSSpace.xxs) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.dsIconSmall)
                            Text(field.name).lineLimit(1)
                            if fromApps {
                                Circle().fill(Color.dsTextTertiary).frame(width: 4, height: 4)
                                    .help("From your apps").accessibilityHidden(true)
                            }
                        }
                        .font(.dsSecondary)
                        .padding(.horizontal, DSSpace.s)
                        .frame(height: DictionaryChipLayout.chipHeight)
                        .foregroundStyle(selected ? Color.dsAccent : Color.dsTextSecondary)
                        .background(selected ? Color.dsAccentQuiet : Color.dsSurfaceControl, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(fromApps ? "\(field.name) — from your apps" : field.name)
                    .accessibilityLabel(field.name)
                    .accessibilityValue(fromApps ? "On, from your apps" : (selected ? "On" : "Off"))
                }
            }
            if automatic && automaticIDs.contains(where: { !on.contains($0) && !off.contains($0) }) {
                HStack(spacing: DSSpace.xxs) {
                    Circle().frame(width: 4, height: 4)
                    Text("Chosen from your apps")
                }
                .font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
            }
        }
    }
}

/// Measures and places from the same bounded plan, including widths smaller
/// than a chip's ideal width. Both welcome and Dictionary use this layout.
struct DictionaryChipLayout: Layout {
    static let chipHeight: CGFloat = 34
    var spacing: CGFloat = DSSpace.xs

    static func frames(widths: [CGFloat], availableWidth: CGFloat, spacing: CGFloat = DSSpace.xs) -> [CGRect] {
        let width = max(0, availableWidth)
        var x: CGFloat = 0, y: CGFloat = 0
        return widths.map { ideal in
            let chipWidth = min(max(0, ideal), width)
            if x > 0 && x + chipWidth > width {
                x = 0
                y += chipHeight + spacing
            }
            let frame = CGRect(x: x, y: y, width: chipWidth, height: chipHeight)
            x += chipWidth + spacing
            return frame
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        Self.frames(widths: subviews.map { $0.sizeThatFits(.unspecified).width }, availableWidth: width, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.last?.maxY ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(width: bounds.width, subviews: subviews)
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }
}

struct DictionaryOverflowWords: View {
    let terms: [String]
    @Binding var isExpanded: Bool

    static func summary(count: Int) -> String {
        count == 1 ? "1 more word didn’t fit" : "\(count) more words didn’t fit"
    }

    var body: some View {
        if !terms.isEmpty {
            DisclosureGroup(Self.summary(count: terms.count), isExpanded: $isExpanded) {
                Text(terms.joined(separator: ", "))
                    .textSelection(.enabled).padding(.top, DSSpace.xxs)
            }
            .font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
        }
    }
}

struct DictionaryView: View {
    @Environment(\.repositoryHub) private var hub
    @State private var settings = AppSettings.shared
    @State private var model = DictionaryModel()
    @State private var installed: Set<String> = []
    @State private var showingWord = false
    @State private var showingImport = false
    @SceneStorage("dictionary.moreExpanded") private var more = false
    @State private var search = ""
    @State private var word = ""
    @State private var heardAs: [String] = []
    @State private var showHeardAs = false
    @State private var original: [DictionaryEntryDTO] = []
    @State private var newID = UUID()
    @State private var phrase = ""
    @State private var importText = ""
    @State private var replaceConflicts = false
    @State private var importMessage: String?
    @State private var importing = false
    @State private var showSkippedWords = false

    private var previewTerms: [String] {
        VocabularyHint.orderedTerms(VocabularyHint.vocabularyHintInput(entries: model.entries,
            ownerNames: [NSFullUserName()], voiceLaunch: VoiceLaunchEngine.hintWords(settings.voiceLaunch),
            forVoiceCommandSession: false, automatic: settings.vocabularyPacksAutomatic,
            on: settings.vocabularyPacksOn, off: settings.vocabularyPacksOff, installedBundleIDs: installed,
            destinationBundleID: nil, languages: settings.dictationLanguages))
    }

    private var groups: [DictionaryWordGroup] { DictionaryWords.groups(model.entries, search: search) }
    private var candidates: [DictionaryImportCandidate] { DictionaryImportParser.parse(importText) }
    private var conflicts: [DictionaryImportCandidate] {
        let existing = DictionaryImportParser.existingEntriesByKey(model.entries)
        return candidates.filter { candidate in
            existing[candidate.key].map { $0.replacement != candidate.replacement } ?? false
        }
    }
    private var importRows: [DictionaryEntryDTO] {
        DictionaryWords.importing(candidates, existing: model.entries, replace: replaceConflicts)
    }

    var body: some View {
        DSPage(title: "Dictionary", summary: "Add words and spellings the speech model should recognize.", brief: HelpLibrary.brief(.dictionary), width: .wide) {
            statusLine
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                DSSection(title: "Your fields")
                DictionaryFieldChips(on: $settings.vocabularyPacksOn, off: $settings.vocabularyPacksOff,
                                     automatic: settings.vocabularyPacksAutomatic, installed: installed)
            }
            wordsSection
            DisclosureGroup("More", isExpanded: $more) {
                moreContent.padding(.top, DSSpace.m)
            }
            .font(.dsBodyMedium)
        }
        .font(.dsBody)
        .foregroundStyle(Color.dsTextPrimary)
        .background(Color.dsBgContent)
        .tint(Color.dsAccent)
        .sheet(isPresented: $showingWord) { wordSheet }
        .sheet(isPresented: $showingImport) { importSheet }
        .task {
            installed = await InstalledApps.bundleIDs()
            await reload()
        }
        .onChange(of: hub?.dictionaryVersion) { _, _ in Task { await reload() } }
    }

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.s) {
                Text("Your words").font(.dsSection)
                Spacer()
                TextField("Search words", text: $search)
                    .textFieldStyle(.plain)
                    .font(.dsBody)
                    .padding(.horizontal, DSSpace.xs)
                    .frame(maxWidth: 200)
                    // Match the shared button's regular control height.
                    .frame(height: DSSpace.xl - DSSpace.xxs)
                    .background(Color.dsSurfaceControl, in: RoundedRectangle(cornerRadius: DSRadius.control))
                    .overlay(RoundedRectangle(cornerRadius: DSRadius.control).strokeBorder(Color.dsBorder))
                Button("Add", systemImage: "plus") { edit(nil) }
                    .buttonStyle(.dsPrimary)
            }
            if let deleted = model.recentlyDeleted { undoBanner(deleted) }
            if groups.isEmpty {
                DSEmptyState(title: search.isEmpty ? BrandVoice.noDictionaryEntries : "No matching words",
                             detail: search.isEmpty ? "Add a word or a heard-as spelling when you need one." : "Try another spelling.")
            } else {
                DSCard(padding: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(groups) { group in
                            DictionaryWordRow(group: group, edit: { edit(group) }, star: {
                                guard let hub else { return }
                                let rows = group.entries.map { row in var row = row; row.isStarred = !group.starred; return row }
                                Task { await model.upsert(rows, repositories: hub.current) }
                            }, delete: {
                                guard let hub else { return }
                                Task { await model.deleteGroup(group.entries, repositories: hub.current) }
                            })
                            if group.id != groups.last?.id { Divider().overlay(Color.dsDivider) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if model.isLoading {
            HStack(spacing: DSSpace.xs) { ProgressView().controlSize(.small); Text("Loading…").font(.dsCaption) }
        } else if !DictatorViewModel.shared.syncIsHealthy {
            SyncStatusLine(viewModel: DictatorViewModel.shared, loading: false)
        }
        if let error = model.loadError {
            DSEmptyState(symbol: "exclamationmark.triangle", title: error)
                .textSelection(.enabled)
        }
    }

    private var wordSheet: some View {
        DSSheet(title: original.isEmpty ? "Add a word" : "Edit word", width: .compact) {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                TextField("Word", text: $word).textFieldStyle(.roundedBorder).onSubmit { saveWord() }
                Button("Dictator hears it differently") {
                    showHeardAs.toggle()
                    if showHeardAs && heardAs.isEmpty { heardAs = [""] }
                }
                .buttonStyle(.dsLink)
                if showHeardAs {
                    Text("Heard as").font(.dsBody)
                    ScrollView {
                        VStack(spacing: DSSpace.xs) {
                            ForEach(heardAs.indices, id: \.self) { index in
                                HStack(spacing: DSSpace.xs) {
                                    TextField("Heard as", text: $heardAs[index])
                                        .textFieldStyle(.roundedBorder).onSubmit { saveWord() }
                                    Button { heardAs.remove(at: index) } label: {
                                        Image(systemName: "minus.circle").font(.dsIcon)
                                    }
                                    .buttonStyle(.plain).accessibilityLabel("Remove heard-as spelling")
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    Button("Add another heard-as spelling") { heardAs.append("") }
                        .buttonStyle(.dsLink)
                }
                if let error = model.saveError {
                    Text(error).font(.dsCaption).foregroundStyle(Color.dsWarning)
                }
            }
        } actions: {
            Button("Cancel") { showingWord = false }.keyboardShortcut(.cancelAction)
            if model.isSaving { ProgressView().controlSize(.small) }
            Button(model.saveError == nil ? "Save" : "Try Again") { saveWord() }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .disabled(model.isSaving)
        .interactiveDismissDisabled(model.isSaving)
    }

    private func edit(_ group: DictionaryWordGroup?) {
        original = group?.entries ?? []
        word = group?.spelling ?? ""
        heardAs = group?.heardAs ?? []
        showHeardAs = !heardAs.isEmpty
        newID = UUID()
        model.clearSaveError()
        showingWord = true
    }

    private func saveWord() {
        guard let hub, !model.isSaving, !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await model.saveWord(word: word, heardAs: heardAs,
                                    original: original, newID: newID, repositories: hub.current) {
                showingWord = false
            }
        }
    }

    private func undoBanner(_ entry: DictionaryEntryDTO) -> some View {
        HStack(spacing: DSSpace.xs) {
            Text("Deleted “\(DictionaryWords.spelling(entry))”.").font(.dsCaption)
            Spacer()
            Button("Undo") {
                guard let hub else { return }
                Task { await model.undoDelete(repositories: hub.current) }
            }
        }
        .padding(DSSpace.m).dsCardSurface(.dsSurfaceControl)
        .task(id: entry.id) {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            model.forgetRecentlyDeleted(entry)
        }
    }

    private var moreContent: some View {
        VStack(alignment: .leading, spacing: DSSpace.l) {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text("Try a phrase").font(.dsSection)
                TextField("Type a phrase", text: $phrase).textFieldStyle(.roundedBorder)
                if !phrase.isEmpty {
                    Text(CleanupPrompt.applyReplacements(phrase, dictionary: DictionaryWords.matching(model.entries)))
                        .font(.dsBody).textSelection(.enabled)
                }
            }
            listeningPreview
            HStack(spacing: DSSpace.m) {
                Text("Learn from my corrections").font(.dsBodyMedium)
                Spacer()
                Toggle("Learn from my corrections", isOn: $settings.learnFromCorrections)
                    .toggleStyle(.switch).labelsHidden()
            }
            HStack(spacing: DSSpace.m) {
                Text("Choose fields from my apps").font(.dsBodyMedium)
                Spacer()
                Toggle("Choose fields from my apps", isOn: $settings.vocabularyPacksAutomatic)
                    .toggleStyle(.switch).labelsHidden()
            }
            HStack(spacing: DSSpace.xs) {
                Button("Import…") { importMessage = nil; showingImport = true }
                Button("Export…") { exportWords() }
            }
        }
        .font(.dsBody)
    }

    private var listeningPreview: some View {
        let preview = LocalSpeechService.shared.dictionaryPreview(terms: previewTerms, language: settings.dictationLanguages.first)
        let skipped = previewTerms.filter { !preview.terms.contains($0) }
        return VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text("What Dictator listens for").font(.dsSection)
            Text(preview.estimated ? "About \(Int(preview.fullness * 100))% full. Words can vary with the speech engine, destination app and language." : "\(Int(preview.fullness * 100))% full. Words can vary with the speech engine, destination app and language.")
                .font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
            ProgressView(value: preview.fullness).accessibilityLabel("Space used")
            Text(preview.terms.isEmpty ? "No extra words right now." : preview.terms.joined(separator: ", "))
                .font(.dsBody).textSelection(.enabled)
            DictionaryOverflowWords(terms: skipped, isExpanded: $showSkippedWords)
        }
    }

    private var importSheet: some View {
        DSSheet(title: "Import words", subtitle: "One word per line. For a heard-as spelling: cloud code -> Claude Code",
                width: .standard, height: 560) {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                HStack(spacing: DSSpace.xs) {
                    Button("Choose text file…") { readImport() }
                    Spacer()
                }
                TextEditor(text: $importText).frame(minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: DSRadius.control).stroke(Color.dsBorder))
                if !conflicts.isEmpty {
                    Text("These heard-as spellings already point to another word:").font(.dsBody)
                    Text(conflicts.map { "\($0.pattern) → \($0.replacement)" }.joined(separator: "\n"))
                        .font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                    Toggle("Replace existing spellings", isOn: $replaceConflicts)
                }
                Text("\(importRows.count) to import. Words already here are skipped.")
                    .font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                if let importMessage { Text(importMessage).font(.dsCaption).foregroundStyle(Color.dsWarning) }
            }
        } actions: {
            Button("Cancel") { showingImport = false }.keyboardShortcut(.cancelAction)
            if importing { ProgressView().controlSize(.small) }
            Button(replaceConflicts && !conflicts.isEmpty ? "Replace and Import" : "Import") { importWords() }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction).disabled(importRows.isEmpty)
        }
        .disabled(importing)
        .interactiveDismissDisabled(importing)
    }

    private func importWords() {
        guard let hub else { return }
        let rows = importRows
        importing = true
        Task {
            defer { importing = false }
            do {
                try await hub.current.dictionary.upsert(rows)
                await reload()
                importMessage = "Imported \(rows.count) words."
            } catch { importMessage = "Words weren’t imported: \(error.localizedDescription)" }
        }
    }

    private func readImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { importText = try String(contentsOf: url, encoding: .utf8) }
        catch { importMessage = "The file couldn’t be read: \(error.localizedDescription)" }
    }

    private func exportWords() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Dictator words.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DictionaryWords.export(model.entries).write(to: url, atomically: true, encoding: .utf8) }
        catch { model.loadError = "Words weren’t exported: \(error.localizedDescription)" }
    }

    private func reload() async {
        guard let hub else { return }
        await model.reload(from: hub.current)
    }
}

private struct DictionaryWordRow: View {
    let group: DictionaryWordGroup
    let edit: () -> Void
    let star: () -> Void
    let delete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: DSSpace.xs) {
            Button(action: star) {
                Image(systemName: group.starred ? "star.fill" : "star")
                    .font(.dsIcon)
                    .foregroundStyle(group.starred ? Color.dsAccent : Color.dsTextTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.starred ? "Unstar \(group.spelling)" : "Star \(group.spelling)")
            Button(action: edit) {
                HStack(spacing: DSSpace.xs) {
                    VStack(alignment: .leading, spacing: DSSpace.hair) {
                        Text(group.spelling).font(.dsBodyMedium)
                        if !group.heardAs.isEmpty {
                            Text("heard as " + group.heardAs.joined(separator: ", "))
                                .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                        }
                    }
                    if group.learned { Text("Learned").font(.dsCaption).foregroundStyle(Color.dsTextTertiary) }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: delete) { Image(systemName: "trash").font(.dsIcon).foregroundStyle(Color.dsTextTertiary) }
                .buttonStyle(.plain).opacity(hovered ? 1 : 0)
                .accessibilityLabel("Delete \(group.spelling)")
        }
        .padding(.horizontal, DSSpace.m)
        .padding(.vertical, DSSpace.s)
        .onHover { hovered = $0 }
        .contextMenu { Button("Edit word", action: edit); Button("Delete", role: .destructive, action: delete) }
    }
}

struct DictionaryImportCandidate: Identifiable {
    let id = UUID()
    let pattern: String
    let replacement: String
    let isVocabulary: Bool

    var key: String {
        "\(isVocabulary ? "v" : "r"):\(Self.normalize(pattern))"
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum DictionaryImportParser {
    static func parse(_ text: String) -> [DictionaryImportCandidate] {
        let escapedFormat = text.split(whereSeparator: \.isNewline).first == "# Dictator words 1"
        return text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

            if escapedFormat, line.hasPrefix("@word "),
               let fields = try? JSONDecoder().decode([String].self, from: Data(line.dropFirst(6).utf8)),
               fields.count == 3, ["word", "rule"].contains(fields[2]), !fields[0].isEmpty,
               fields[2] == "word" || !fields[1].isEmpty {
                return DictionaryImportCandidate(pattern: fields[0], replacement: fields[1], isVocabulary: fields[2] == "word")
            }
            if let range = line.range(of: "->") {
                let pattern = line[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pattern.isEmpty, !replacement.isEmpty else { return nil }
                return DictionaryImportCandidate(
                    pattern: pattern,
                    replacement: replacement,
                    isVocabulary: false
                )
            }

            return DictionaryImportCandidate(
                pattern: line,
                replacement: "",
                isVocabulary: true
            )
        }
    }

    /// Used by `DictionaryView` (repository-backed DTOs).
    static func existingEntriesByKey(_ entries: [DictionaryEntryDTO]) -> [String: DictionaryEntryDTO] {
        entries.reduce(into: [:]) { result, entry in
            let key = "\(entry.isVocabulary ? "v" : "r"):\(DictionaryImportCandidate.normalize(entry.pattern))"
            result[key] = result[key] ?? entry
        }
    }
}
