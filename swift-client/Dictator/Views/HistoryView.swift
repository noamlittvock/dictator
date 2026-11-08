import SwiftUI

/// A window retains this model across tab changes. The feed reads one page
/// at a time; only an explicit request for older history advances the cursor.
/// Every await checks a generation so stale pages cannot replace a new filter.
@Observable
@MainActor
final class HistoryFeedModel {
    private(set) var entries: [DictationEntryDTO] = []
    private(set) var entriesVersion = 0
    private(set) var destinations: [String] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    var filterID = "all"
    var loadError: String?

    private static let pageSize = 100
    private var loadGeneration = 0
    private var cursor: HistoryCursor?
    private var loadedRepository: ObjectIdentifier?
    private var loadedVersion: Int?
    private var loadedFilter = HistoryFilter.all
    private var metadataVersion: Int?

    func loadIfNeeded(from repositories: Repositories, version: Int) async {
        let filter = HistoryFilter(id: filterID)
        if loadedRepository == ObjectIdentifier(repositories), loadedVersion == version, loadedFilter == filter {
            if metadataVersion != version {
                let generation = loadGeneration
                do {
                    let names = try await repositories.history.destinationNames()
                    guard !Task.isCancelled, generation == loadGeneration else { return }
                    destinations = names
                    metadataVersion = version
                } catch {
                    if !Task.isCancelled, generation == loadGeneration { loadError = error.localizedDescription }
                }
            }
            return
        }
        await reload(from: repositories, filter: filter, version: version)
    }

    func reload(from repositories: Repositories, filter: HistoryFilter = .all, version: Int? = nil) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let repositoryID = ObjectIdentifier(repositories)
        let needsMetadata = loadedRepository != repositoryID || metadataVersion != version || version == nil
        let filterChanged = loadedFilter != filter || loadedRepository != repositoryID
        if loadedRepository != repositoryID { metadataVersion = nil; destinations = [] }
        loadedVersion = nil
        loadedFilter = filter
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        isLoadingMore = false
        hasMore = false
        loadError = nil
        if filterChanged { entries = []; entriesVersion &+= 1 }

        do {
            let firstPage = try await repositories.history.browsePage(limit: Self.pageSize, before: nil, filter: filter)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            entries = firstPage
            entriesVersion &+= 1
            cursor = firstPage.last?.cursor
            hasMore = !firstPage.isEmpty
            isLoading = false
            loadedRepository = repositoryID
            loadedVersion = version

            // The destination menu doesn't gate the first paint.
            if needsMetadata {
                let names = try await repositories.history.destinationNames()
                guard !Task.isCancelled, generation == loadGeneration else { return }
                destinations = names
                metadataVersion = version
            }
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    func loadMore(from repositories: Repositories) async {
        guard hasMore, !isLoading, !isLoadingMore, loadedRepository == ObjectIdentifier(repositories) else { return }
        let generation = loadGeneration
        isLoadingMore = true
        loadError = nil
        do {
            let batch = try await repositories.history.browsePage(limit: Self.pageSize, before: cursor, filter: loadedFilter)
            guard generation == loadGeneration else { return }
            isLoadingMore = false
            guard !Task.isCancelled else { return }
            if let last = batch.last {
                entries.append(contentsOf: batch)
                entriesVersion &+= 1
                cursor = last.cursor
            } else {
                hasMore = false
            }
        } catch {
            guard generation == loadGeneration else { return }
            isLoadingMore = false
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }
}

/// Shared destructive-delete guard for both the History feed's row/Clean-Up
/// deletes and `CleanUpHistorySheet`'s purge: the caller captures
/// `expectedVersion` at the moment of confirmation (the click itself, or the
/// preview it's confirming), and this re-validates it right before deleting
/// — a stale preview (something else landed in the store since, e.g. rows
/// replicated in from the Core) aborts the whole action instead of silently
/// deleting the wrong rows.
@MainActor
enum HistoryDestructiveAction {
    static func delete(
        ids: [UUID],
        boundTo repositories: Repositories,
        hub: RepositoryHub,
        expectedVersion: Int
    ) async -> String? {
        guard !ids.isEmpty else { return nil }
        guard hub.historyVersion == expectedVersion else {
            return "History changed after Dictator checked it. Choose Clean Up again to check the latest entries."
        }
        do {
            try await repositories.history.delete(ids: ids)
            return nil
        } catch {
            return "Couldn't delete entries: \(error.localizedDescription)"
        }
    }
}

struct HistoryView: View {
    @Environment(\.repositoryHub) private var hub
    @Bindable var model: HistoryFeedModel
    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared
    @State private var exportError: String?
    @State private var isPreparingAction = false

    // Entries flagged by ModelEcho as internal model/agent text (not real
    // dictation), staged for the bulk "Clean Up" confirmation before deletion.
    @State private var whyEntry: DictationEntryDTO?
    @State private var fixingWord: DictationEntryDTO?
    @State private var cleanupVersion: Int?
    @State private var cleanupCandidates: [DictationEntryDTO] = []
    @State private var showCleanupConfirm = false

    // Group only loaded rows, and rebuild when a page arrives rather than
    // repeating date formatting during rendering or scrolling.
    @State private var derived = DerivedHistory.empty

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLine

            // HStack, not HSplitView: NSSplitView (backing HSplitView) does not
            // propagate the toolbar safe-area inset to its subviews, so the feed's
            // ScrollView rendered its content + scrollbar up under the "History"
            // title bar. A plain HStack propagates safe area, so the ScrollView
            // insets below the toolbar automatically.
            historyFeed
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Home")
        .sheet(item: $fixingWord) { entry in
            HistoryWordCorrectionSheet(entry: entry)
        }
        .onAppear { rebuild() }
        .task(id: HistoryLoadKey(version: hub?.historyVersion, filter: model.filterID)) {
            guard let hub else { return }
            await model.loadIfNeeded(from: hub.current, version: hub.historyVersion)
            rebuild()
        }
        .onChange(of: model.entriesVersion) { rebuild() }
        .onChange(of: model.destinations) { rebuild() }
        .toolbar {
            ToolbarItem {
                Picker("History Filter", selection: $model.filterID) {
                    ForEach(derived.filterOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
                .help("Filter saved prompts")
            }

            ToolbarItem {
                Button {
                    prepareCleanup()
                } label: {
                    Label("Clean Up", systemImage: "sparkles")
                }
                .disabled(isPreparingAction || model.isLoading)
                .help("Find and permanently delete entries that look like text an AI tool added, not words you dictated or typed")
            }
        }
        .alert("Clean Up History", isPresented: $showCleanupConfirm) {
            if cleanupCandidates.isEmpty {
                Button("OK", role: .cancel) {}
            } else {
                Button("Delete \(cleanupCandidates.count)", role: .destructive) {
                    deleteCandidates()
                }
                Button("Cancel", role: .cancel) { cleanupCandidates = [] }
            }
        } message: {
            if cleanupCandidates.isEmpty {
                Text("No entries look like text an AI tool added. Nothing to delete.")
            } else {
                let n = cleanupCandidates.count
                Text("\(n) \(n == 1 ? "entry looks" : "entries look") like text an AI tool added, not words you dictated or typed. Permanently delete \(n == 1 ? "it" : "them")? This can't be undone.")
            }
        }
        .alert("Couldn't Clean Up History", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    /// One line under the title: what replication is doing. Always shown
    /// (even "Standalone"), so a dead Core link or a pile of unsynced
    /// entries is never silent.
    @ViewBuilder
    private var statusLine: some View {
        if let loadError = model.loadError {
            DSEmptyState(title: loadError)
                .dsPageFrame(.wide)
        } else {
            SyncStatusLine(viewModel: viewModel, loading: model.isLoading)
                .dsPageFrame(.wide)
                .padding(.top, DSSpace.xs)
        }
    }

    /// Whole-store operations run only when requested, independently of the
    /// feed's loaded page or selected filter.
    private func prepareCleanup() {
        guard let hub else { return }
        let repositories = hub.current
        let version = hub.historyVersion
        isPreparingAction = true
        Task {
            defer { isPreparingAction = false }
            do {
                let entries = try await repositories.history.allEntries()
                guard hub.historyVersion == version else {
                    exportError = "History changed while Dictator was checking it. Choose Clean Up again."
                    return
                }
                cleanupCandidates = entries.filter { ModelEcho.isLikelyModelEcho($0.text) }
                cleanupVersion = version
                showCleanupConfirm = true
            } catch { exportError = error.localizedDescription }
        }
    }

    private func deleteCandidates() {
        delete(cleanupCandidates, expectedVersion: cleanupVersion)
        cleanupCandidates = []
        cleanupVersion = nil
    }

    /// Permanently remove entries via the repository layer. The click that
    /// calls this (a row's context-menu "Delete", or the Clean Up alert's
    /// "Delete N" button) is the confirmation, so the repository identity
    /// and history version are captured right here rather than after
    /// any `await`. A bulk delete uses the preview's version. On success the
    /// hub's version bump drives the feed's single `.task(id:)` reload path.
    private func delete(_ targets: [DictationEntryDTO], expectedVersion: Int? = nil) {
        guard !targets.isEmpty, let hub else { return }
        let repo = hub.current
        let ids = targets.map(\.id)
        let version = expectedVersion ?? hub.historyVersion
        Task {
            if let error = await HistoryDestructiveAction.delete(
                ids: ids, boundTo: repo, hub: hub, expectedVersion: version
            ) {
                exportError = error
            }
        }
    }

    /// What to do to fill an empty history, naming the key actually set and
    /// mentioning typing only where typed history is on.
    static func emptyHistoryHint(key: KeyCombo, typedHistoryOn: Bool) -> String {
        let key = key.symbolName
        if typedHistoryOn {
            return "Hold \(key) and speak, or send a message in one of the apps you chose to save."
        }
        return "Hold \(key) and speak. What you dictate shows up here."
    }

    @ViewBuilder
    private var historyFeed: some View {
        if model.isLoading && derived.filtered.isEmpty {
            ProgressView("Loading history…")
                .font(.dsBody)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if derived.filtered.isEmpty {
            if settings.isHistoryCaptureEnabled {
                DSEmptyState(
                    symbol: "text.bubble",
                    title: model.filterID == "all" ? BrandVoice.noHistory : "No Matching History",
                    detail: model.filterID == "all" ? Self.emptyHistoryHint(
                        key: settings.dictationKeys,
                        typedHistoryOn: settings.surfacePolicy.allowsAnyTypedSave
                    ) : "Choose another history filter."
                )
                .dsPageFrame(.wide)
            } else {
                DSEmptyState(
                    symbol: "lock.shield",
                    title: "History Is Off",
                    detail: "Dictations aren’t being saved. Turn on “Save everything you dictate” in Settings › History & Privacy to keep them."
                ) {
                    Button("Open History & Privacy") { AppNavigation.shared.openSettings(.history) }
                        .buttonStyle(.dsPrimary)
                }
                .dsPageFrame(.wide)
            }
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                // Only explicitly loaded pages are laid out here. Avoid the
                // lazy stack's accessibility traversal: it can trap after a
                // page append even when every item has a stable identity.
                VStack(alignment: .leading, spacing: 0) {
                    // Each feed item has one view and one stable identity.
                    ForEach(derived.items) { item in
                        switch item {
                        case .day(let date):
                            Text(date.uppercased())
                                .accessibilityAddTraits(.isHeader)
                                .font(.dsSection)
                                .tracking(1.2)
                                .foregroundStyle(Color.dsTextTertiary)
                                .padding(.top, DSSpace.m)
                                .padding(.bottom, DSSpace.xxs)

                        case .entry(let entry):
                            VStack(spacing: 0) {
                                HistoryRow(entry: entry)
                                    .contextMenu {
                                        Button("Why Was This Saved?") { whyEntry = entry }
                                        if (entry.modality ?? "voice") == "voice" {
                                            Button("Fix a word") { fixingWord = entry }
                                        }
                                        if let tool = entry.toolId.flatMap({ ToolCatalog.shared.tool(id: $0) }),
                                           (entry.modality ?? "voice") == "typed" {
                                            Button("Stop Keeping Typing from \(tool.name)") {
                                                PromptCaptureCenter.shared.setTool(tool.id, on: false)
                                            }
                                        }
                                        if let exception = HistoryExceptions.stopSavingRule(for: entry) {
                                            Button("Never Keep from \(ExceptionDescription.describe(exception).replacingOccurrences(of: " — typing", with: "").replacingOccurrences(of: " — dictation", with: ""))") {
                                                settings.updateSurfacePolicy { $0.rules.insert(exception, at: 0) }
                                            }
                                        }
                                        Divider()
                                        Button("Delete", role: .destructive) {
                                            delete([entry])
                                        }
                                    }
                                Rectangle().fill(Color.dsDivider).frame(height: 1)
                                    .accessibilityHidden(true)
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("History entry")
                            .accessibilityIdentifier("history-entry-\(entry.id.uuidString)")
                        }
                    }
                    if model.hasMore {
                        Button {
                            guard let hub else { return }
                            Task { await model.loadMore(from: hub.current) }
                        } label: {
                            HStack(spacing: DSSpace.xs) {
                                if model.isLoadingMore { ProgressView().controlSize(.small) }
                                Text(model.isLoadingMore ? "Loading older entries…" : "Load older entries")
                            }
                        }
                        .disabled(model.isLoading || model.isLoadingMore)
                        .padding(.vertical, DSSpace.m)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, DSSpace.m)
                .dsPageFrame(.wide)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("History entries")
                .accessibilityIdentifier("history-feed-items")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.visible)
            .clipped()
            .background(Color.dsBgContent)
            .alert(
                "Why this was saved",
                isPresented: Binding(get: { whyEntry != nil }, set: { if !$0 { whyEntry = nil } }),
                presenting: whyEntry
            ) { _ in
                Button("Choose Apps to Save Typing…") { AppNavigation.shared.openPromptSettings() }
                Button("OK", role: .cancel) {}
            } message: { entry in
                Text(HistoryExceptions.explanation(for: entry))
            }
        }
    }

    /// The repository has already applied the filter across the store.
    /// Rebuild date groups and menu options when loaded rows change.
    private func rebuild() {
        let entries = model.entries
        let filtered = entries

        let items = HistoryFeedItem.make(from: filtered) { Self.dayFormatter.string(from: $0) }

        let destinations = Set(model.destinations + entries.compactMap(\.destinationDisplayName))
            .sorted()
            .map { HistoryFilter.destination($0).option }
        let options = [
            HistoryFilter.all.option,
            HistoryFilter.spoken.option,
            HistoryFilter.typed.option,
        ] + destinations

        derived = DerivedHistory(
            filtered: filtered,
            items: items,
            filterOptions: options
        )
    }

    /// Relative date-group formatter ("Today", "Jun 12, 2026"). Allocated once —
    /// `DateFormatter()` is too costly to build per render.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        return f
    }()
}

/// A flat, stable sequence for the feed and its accessibility children.
/// Date headers and history rows occupy separate identity namespaces.
enum HistoryFeedItem: Identifiable {
    case day(String)
    case entry(DictationEntryDTO)

    enum ID: Hashable {
        case day(String)
        case entry(UUID)
    }

    var id: ID {
        switch self {
        case .day(let label): return .day(label)
        case .entry(let entry): return .entry(entry.id)
        }
    }

    static func make(from entries: [DictationEntryDTO], dayLabel: (Date) -> String) -> [Self] {
        let groups = Dictionary(grouping: entries) { dayLabel($0.timestamp) }
            .sorted { a, b in
                guard let firstA = a.value.first, let firstB = b.value.first else { return false }
                return firstA.timestamp > firstB.timestamp
            }
        return groups.flatMap { label, entries in
            [Self.day(label)] + entries.map(Self.entry)
        }
    }
}

/// Snapshot of everything HistoryView derives from (entries, filter).
/// Recomputed only when inputs change so the view body stays cheap.
private struct DerivedHistory {
    var filtered: [DictationEntryDTO]
    var items: [HistoryFeedItem]
    var filterOptions: [HistoryFilterOption]

    static let empty = DerivedHistory(
        filtered: [],
        items: [],
        filterOptions: []
    )
}

/// Detects history entries that are internal model / agent context that leaked
/// into the dictation feed (e.g. harness prompts, "## My request for Codex",
/// "The user has the in-app browser open. Current URL: ...") rather than text a
/// person actually dictated or typed. Deliberately high-precision: better to
/// leave a borderline entry for manual deletion than to purge real dictation.
enum ModelEcho {
    /// Phrases that essentially never appear in genuine dictation but are
    /// hallmarks of agent/harness output or third-person narration about "the
    /// user". Any single match flags the entry.
    private static let strongPhrases: [String] = [
        "request for codex",
        "request for claude",
        "in app browser",
        "in-app browser",
        "current url:",
        "the user has the",
        "the user is currently",
        "<system-reminder",
        "</system-reminder>",
        "as an ai language model",
        "i am an ai language model",
        "i'm an ai language model",
    ]

    static func isLikelyModelEcho(_ rawText: String) -> Bool {
        let text = rawText.lowercased()
        guard !text.isEmpty else { return false }

        for phrase in strongPhrases where text.contains(phrase) {
            return true
        }

        // Markdown-structured context that narrates "the user" in third person
        // (a heading line plus a mention of "the user") is agent scaffolding,
        // not something a person dictates into a text field.
        let hasHeading = rawText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        if hasHeading && text.contains("the user") {
            return true
        }
        return false
    }
}

private struct HistoryLoadKey: Equatable {
    let version: Int?
    let filter: String
}

struct HistoryRow: View {
    let entry: DictationEntryDTO
    @State private var settings = AppSettings.shared

    /// Only meaningful on an Edge: a row this Mac wrote that the Core has
    /// not acknowledged. Core/standalone rows are never "pending".
    private var showsPendingMarker: Bool {
        settings.coreRole == .edge && entry.syncedAt == nil
    }
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: DSSpace.s) {
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                HStack(spacing: DSSpace.xs) {
                    ModalityBadge(modality: modality)
                    Text(timeString)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextSecondary)
                        .accessibilityLabel("\(dateString), \(timeString)")
                    if let stamp = CleanupStamp(entry) {
                        CleanupStampButton(entry: entry, stamp: stamp)
                    }
                    if let destinationLabel {
                        Label(destinationLabel, systemImage: "arrow.forward.circle")
                            .font(.dsCaption)
                            .foregroundStyle(Color.dsTextSecondary)
                            .lineLimit(1)
                            .help(destinationHelp ?? destinationLabel)
                    }
                    if entry.truncated == true {
                        Text("(truncated)")
                            .font(.dsCaption)
                            .foregroundStyle(Color.dsWarning)
                            .help("Dictator shortened this entry because it was too large to send in full.")
                    }
                    if showsPendingMarker {
                        Image(systemName: "arrow.up.circle.dotted")
                            .font(.dsIconSmall)
                            .foregroundStyle(Color.dsTextTertiary)
                            .help("Saved on this Mac; not yet copied to the main Mac.")
                            .accessibilityLabel("Waiting to sync")
                    }
                }

                Text(previewText)
                    .font(.dsBody)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: false)
                    .frame(maxHeight: 76, alignment: .top)
                    .clipped()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Button {
                copy(entry.text)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.dsIconSmall)
                    .foregroundStyle(copied ? Color.dsSuccess : Color.dsTextTertiary)
                    .frame(width: DSSpace.m)
            }
            .buttonStyle(.dsQuiet)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Copy history text")
            .help("Copy history text")
        }
        // Compact feed rows keep the metadata and text together.
        .padding(.vertical, DSSpace.xs)
        .frame(maxHeight: 128, alignment: .top)
        .clipped()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }

    private var modality: EntryModality {
        EntryModality(rawValue: entry.modality ?? "voice") ?? .voice
    }

    private var previewText: String {
        let maxPreviewLength = 1_200
        guard entry.text.utf16.count > maxPreviewLength else { return entry.text }
        let preview = String(entry.text.prefix(maxPreviewLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return preview + "..."
    }

    private var destinationLabel: String? {
        if let tool = entry.toolId.flatMap({ ToolCatalog.shared.tool(id: $0) }) {
            return entry.remoteHost.map { "\(tool.name) · \($0)" } ?? tool.name
        }
        guard let name = entry.destinationAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return entry.destinationAppBundleId.map { DatasetDestinationResolver.displayName(appName: nil, bundle: $0) }
        }
        return DatasetDestinationResolver.displayName(appName: name, bundle: entry.destinationAppBundleId)
    }

    private var destinationHelp: String? {
        var parts: [String] = []
        if modality == .voice {
            parts.append("Dictated into \(destinationLabel ?? "an app")")
        }
        if let surface = entry.surfaceLabel, !surface.isEmpty {
            parts.append(surface)
        }
        if let source = entry.captureSource.flatMap(CaptureSource.init(rawValue:)), source != .voice {
            parts.append(source.title)
        }
        if let url = entry.destinationURL, !url.isEmpty {
            parts.append(url)
        }
        if let insertion = DestinationSnapshot.insertionDescription(entry.insertionMethod) {
            parts.append(insertion)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // Static formatters: allocated once, not per row per render. Allocating a
    // DateFormatter on every row while scrolling was a primary cause of jank.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var timeString: String {
        Self.timeFormatter.string(from: entry.timestamp)
    }

    private var dateString: String {
        Self.dateFormatter.string(from: entry.timestamp)
    }
}

/// What clean-up did to one dictation. The tag stays quiet; clicking it
/// compares what was heard with what was typed.
private struct CleanupStampButton: View {
    let entry: DictationEntryDTO
    let stamp: CleanupStamp
    @State private var showsDetail = false

    var body: some View {
        Button { showsDetail = true } label: {
            Text(tag)
                .font(.dsCaption)
                .foregroundStyle(stamp.note == nil ? Color.dsTextSecondary : Color.dsWarning)
                .lineLimit(1)
        }
        .buttonStyle(.dsQuiet)
        .controlSize(.small)
        .help("See what changed")
        .popover(isPresented: $showsDetail, arrowEdge: .bottom) { CleanupDetail(entry: entry, stamp: stamp) }
    }

    private var tag: String {
        entry.cleanupMs.map { "\(stamp.label) · \(CleanupStamp.seconds($0))" } ?? stamp.label
    }
}

/// What was heard against what was typed, for one dictation.
struct CleanupDetail: View {
    let entry: DictationEntryDTO
    let stamp: CleanupStamp

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(stamp.label).font(.dsSection)
            if let note = stamp.note {
                Text(note).font(.dsBody).foregroundStyle(Color.dsTextSecondary)
            }
            // A shortened row would read as if the end had been removed.
            if let heard = entry.heardText, entry.truncated != true {
                Text(changes(heard: heard))
                    .font(.dsBody)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let model = entry.polishModel, model != "none" {
                Text("AI model: \(ModelCatalog.name(of: model))")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
            }
        }
        .padding(DSSpace.m)
        .frame(width: 340, alignment: .leading)
    }

    private func changes(heard: String) -> AttributedString {
        var result = AttributedString()
        for piece in WordChanges.between(heard: heard, typed: entry.text) {
            var word = AttributedString(piece.text + " ")
            switch piece.kind {
            case .same: break
            case .added:
                word.foregroundColor = .dsAccent
            case .removed:
                word.foregroundColor = .dsTextTertiary
                word.strikethroughStyle = .single
            }
            result += word
        }
        return result
    }
}

private enum EntryModality: String {
    case voice
    case typed
    case voiceDerived = "voice_derived"

    var label: String {
        switch self {
        case .voice: "Spoken"
        case .typed: "Typed"
        case .voiceDerived: "Voice-derived"
        }
    }

    var systemImage: String {
        switch self {
        case .voice: "mic.fill"
        case .typed: "keyboard"
        case .voiceDerived: "mic.badge.plus"
        }
    }

    var color: Color {
        switch self {
        case .voice: .dsAccent
        case .typed: .dsDataOchre
        case .voiceDerived: .dsDataTeal
        }
    }
}

private struct ModalityBadge: View {
    let modality: EntryModality

    var body: some View {
        Image(systemName: modality.systemImage)
            .font(.dsIconSmall)
            .foregroundStyle(modality.color)
            .frame(width: DSSpace.m, height: DSSpace.m)
            .background(modality.color.opacity(0.12), in: Capsule())
            .help(modality.label)
            .accessibilityLabel(modality.label)
    }
}

/// History → right-click helpers: explain a row's save decision, and build
/// the "never save from here" exception for it.
enum HistoryExceptions {
    static func explanation(for entry: DictationEntryDTO) -> String {
        var lines: [String] = []
        let catalog = ToolCatalog.shared
        if let surface = entry.surfaceLabel, !surface.isEmpty {
            lines.append("Where: \(surface)")
        } else if let name = entry.destinationAppName ?? entry.destinationAppBundleId {
            lines.append("Where: \(name)")
        }
        if let source = entry.captureSource.flatMap(CaptureSource.init(rawValue:)) {
            lines.append("How: \(source.title)")
        } else {
            lines.append("How: \((entry.modality ?? "voice") == "voice" ? "Dictation" : "Typed")")
        }
        if let dir = entry.workingDirectory, !dir.isEmpty {
            lines.append("Project: \(dir)")
        }
        if let reason = entry.captureReason {
            lines.append(CaptureDecision(action: .save, reason: reason).explanation(catalog: catalog))
        } else {
            lines.append("Saved before Dictator recorded reasons.")
        }
        return lines.joined(separator: "\n")
    }

    /// The most specific surface of this row, as an ignore rule for the
    /// same kind of input (typing or dictation).
    static func stopSavingRule(for entry: DictationEntryDTO) -> SurfaceRule? {
        let modality = (entry.modality ?? "voice") == "typed" ? "typed" : "voice"
        if let remote = entry.remoteHost, !remote.isEmpty {
            return SurfaceRule(kind: "remote", pattern: remote, action: "ignore", modality: modality)
        }
        if let host = entry.destinationURL.flatMap({ SurfacePolicy.extractHost(from: $0) }) {
            return SurfaceRule(kind: "domain", pattern: host, action: "ignore", modality: modality)
        }
        if entry.toolId == nil, let bundle = entry.destinationAppBundleId, !bundle.isEmpty {
            return SurfaceRule(kind: "app", pattern: bundle, action: "ignore", modality: modality)
        }
        return nil
    }
}

/// Word ranges preserve the original punctuation and spacing between selected
/// chips; the selection always describes one contiguous dictated span.
enum HistoryCorrectionWords {
    static func span(in text: String, ranges: [Range<String.Index>], selection: ClosedRange<Int>?) -> HistoryCorrectionSpan? {
        guard let selection, ranges.indices.contains(selection.lowerBound), ranges.indices.contains(selection.upperBound) else { return nil }
        return HistoryCorrectionSpan(start: text.distance(from: text.startIndex, to: ranges[selection.lowerBound].lowerBound),
            end: text.distance(from: text.startIndex, to: ranges[selection.upperBound].upperBound), originalText: text)
    }
    static func ranges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }
    static func heard(in text: String, ranges: [Range<String.Index>], selection: ClosedRange<Int>?) -> String {
        guard let selection, ranges.indices.contains(selection.lowerBound), ranges.indices.contains(selection.upperBound) else { return "" }
        return String(text[ranges[selection.lowerBound].lowerBound..<ranges[selection.upperBound].upperBound])
    }
}

private struct HistoryWordCorrectionSheet: View {
    let entry: DictationEntryDTO
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ClosedRange<Int>?
    @State private var corrected = ""
    @State private var saving = false
    @State private var confirmation: String?

    private var text: String { entry.editedText ?? entry.text }
    private var ranges: [Range<String.Index>] { HistoryCorrectionWords.ranges(in: text) }
    private var heard: String { HistoryCorrectionWords.heard(in: text, ranges: ranges, selection: selection) }

    var body: some View {
        DSSheet(title: "Fix a word") {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                if let confirmation {
                    Text(confirmation).font(.dsBody)
                } else {
                    Text("Tap a wrong word, or the first and last words of a phrase.")
                        .font(.dsBody).foregroundStyle(Color.dsTextSecondary)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: DSSpace.xs)], spacing: DSSpace.xs) {
                            ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
                                Button {
                                    if let current = selection, !current.contains(index) {
                                        selection = min(current.lowerBound, index)...max(current.upperBound, index)
                                    } else { selection = index...index }
                                } label: {
                                    Text(String(text[range]))
                                        .font(.dsBody)
                                        .padding(.horizontal, DSSpace.xs).padding(.vertical, DSSpace.xxs)
                                        .frame(maxWidth: .infinity)
                                        .background(selection?.contains(index) == true ? Color.dsAccentQuiet : Color.dsSurfaceControl, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(selection?.contains(index) == true ? "Selected" : "")
                            }
                        }
                    }.frame(maxHeight: 200)
                    if !heard.isEmpty { Text("Heard as “\(heard)”").font(.dsCaption).foregroundStyle(Color.dsTextSecondary) }
                    TextField("Right spelling", text: $corrected).textFieldStyle(.roundedBorder)
                }
            }
        } actions: {
            if confirmation != nil {
                Button("Done") { dismiss() }
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
            } else {
                Group {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if saving { ProgressView().controlSize(.small) }
                    Button("Save") {
                        saving = true
                        Task {
                            confirmation = await DictatorViewModel.shared.learnCorrection(heard: heard,
                                corrected: corrected.trimmingCharacters(in: .whitespacesAndNewlines), entryID: entry.id,
                                selection: HistoryCorrectionWords.span(in: text, ranges: ranges, selection: selection))
                            saving = false
                        }
                    }
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(heard.isEmpty || corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(saving)
            }
        }
        .interactiveDismissDisabled(saving)
    }
}
