import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Turns saved history into a dataset an agent can read. One path through the
/// screen: choose prompts → check what the agent gets → create → hand it off.
/// Everything with a sensible default stays folded behind a one-line summary.
struct DatasetView: View {
    @State private var store: DatasetStore
    @State private var tab: Int
    @State private var showImport = false
    @State private var showSaveSelection = false
    @State private var selectionName = ""
    @State private var cliPackage: DatasetPackage?
    @State private var removePackage: DatasetPackage?
    @State private var removeSelection: DatasetSelection?
    @State private var expanded: String?
    @State private var previewLimit = 5
    @State private var filePreview = false
    @State private var showMoreFilters = false
    @State private var showCleaning = false
    @State private var showFormat = false
    @State private var timeChoice: TimeChoice = .all
    @State private var captureCenter = PromptCaptureCenter.shared
    @State private var showSavingStatus = false

    enum TimeChoice: Hashable { case all, days(Int), custom }

    /// `expandOptions` opens every folded section; used for visual review.
    @MainActor init(store: DatasetStore? = nil, initialTab: Int = 0, expandOptions: Bool = false) {
        _store = State(initialValue: store ?? .shared)
        _tab = State(initialValue: initialTab)
        _showMoreFilters = State(initialValue: expandOptions)
        _showCleaning = State(initialValue: expandOptions)
        _showFormat = State(initialValue: expandOptions)
        _filePreview = State(initialValue: expandOptions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PromptCaptureSetupBanner()
                .dsPageFrame()
            statusArea
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.l) {
                    savingStatus
                    if tab == 0 { preparationContent } else { archiveContent }
                }
                .padding(.bottom, DSSpace.l)
                .dsPageFrame()
            }
        }
        .font(.dsBody)
        .background(Color.dsBgContent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if tab == 0, store.state == .loaded, !store.rows.isEmpty { actionBar }
        }
        .task {
            store.ensureLoaded()
            syncTimeChoice()
            await captureCenter.refreshStatuses()
        }
        .sheet(isPresented: $showImport) { ImportHistorySheet(store: store) }
        .sheet(isPresented: $showSaveSelection) { saveSelectionSheet }
        .sheet(item: $cliPackage) { package in DatasetCLISheet(store: store, package: package) }
        .alert(item: $removePackage) { package in
            Alert(
                title: Text("Delete “\(package.manifest.name)”?"),
                message: Text("The dataset and any reports attached to it will be deleted from this Mac. Your history and copies saved elsewhere stay as they are."),
                primaryButton: .destructive(Text("Delete dataset")) { Task { await store.removePackage(package) } },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $removeSelection) { selection in
            Alert(
                title: Text("Delete “\(selection.name)”?"),
                message: Text("This deletes only the saved selection. Your history and datasets are unchanged."),
                primaryButton: .destructive(Text("Delete selection")) { store.removeSelection(selection.id) },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DSSpace.l) {
            DSPageHeader(title: "Datasets", summary: "Turn your saved prompts into a dataset that an AI agent can read.", brief: HelpLibrary.brief(.datasets)) {
                Menu {
                    Button("Import prompts from other apps…") { store.resetImport(); showImport = true }
                    Button("Reload history") { Task { await store.reload() } }
                        .disabled(store.refreshing)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.dsIconLarge)
                        .foregroundStyle(Color.dsTextSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import prompts or reload history")
                .accessibilityLabel("More actions")
            }

            HStack(spacing: DSSpace.xs) {
                DSTabs(selection: $tab, items: [
                    (value: 0, title: "New"),
                    (value: 1, title: store.packages.isEmpty ? "Saved" : "Saved (\(store.packages.count))")
                ])
                Spacer()
                if store.refreshing {
                    ProgressView().controlSize(.small)
                    Text("Reading history…")
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
        }
        .padding(.top, DSSpace.l)
        .padding(.bottom, DSSpace.l)
        .dsPageFrame()
    }

    @ViewBuilder private var statusArea: some View {
        if store.lastError != nil || store.notice != nil || store.running {
            VStack(spacing: DSSpace.xs) {
                if let error = store.lastError {
                    if let package = store.lastCLIPackage, error.hasPrefix("The tool stopped") {
                        DatasetNotice(text: error, tone: .warning, onClose: { store.lastError = nil },
                                    actionTitle: "Show dataset in Finder",
                                    action: { NSWorkspace.shared.activateFileViewerSelecting([package.url]) })
                    } else {
                        DatasetNotice(text: error, tone: .warning) { store.lastError = nil }
                    }
                }
                if let notice = store.notice {
                    if let url = store.lastExportedURL {
                        DatasetNotice(text: notice, tone: .success, onClose: { store.notice = nil },
                                    actionTitle: "Show copy in Finder",
                                    action: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
                    } else {
                        DatasetNotice(text: notice, tone: .success) { store.notice = nil }
                    }
                }
                if store.running {
                    HStack(spacing: DSSpace.s) {
                        ProgressView().controlSize(.small)
                        Text("Your local tool is running. Its input and output are kept with the dataset.")
                            .font(.dsBody)
                            .foregroundStyle(Color.dsTextSecondary)
                        Spacer()
                        Button("Stop tool") { store.cancelCLI() }
                    }
                    .padding(DSSpace.m)
                    .dsCardSurface()
                }
            }
            .padding(.bottom, DSSpace.s)
            .dsPageFrame()
        }
    }

    // MARK: - What is being saved

    private var savingStatus: some View {
        let enabled = ToolCatalog.shared.tools.filter { captureCenter.isOn($0.id) }
        let tools = enabled.filter {
            captureCenter.statuses[$0.id]?.installed == true || !(store.lastSavedByTool[$0.id] ?? []).isEmpty
        }
        let otherCount = enabled.count - tools.count
        return DSCard {
            DisclosureGroup(isExpanded: $showSavingStatus) {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    if enabled.isEmpty {
                        Text("No tools are turned on for typed history.")
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                    ForEach(tools) { tool in
                        VStack(alignment: .leading, spacing: DSSpace.hair) {
                            HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                                Text(tool.name).font(.dsBodyMedium)
                                Spacer(minLength: DSSpace.xs)
                                Text(captureCenter.localState(for: tool))
                                    .foregroundStyle(captureCenter.needsSetup(tool) ? Color.dsWarning : Color.dsTextSecondary)
                            }
                            Text("\(Host.current().localizedName ?? "This Mac"): \(captureCenter.captureDescription(for: tool))")
                                .foregroundStyle(Color.dsTextSecondary)
                            savedDates(for: tool)
                        }
                        if tool.id != tools.last?.id { Divider() }
                    }
                    if otherCount > 0 {
                        Text(otherCount == 1 ? "1 other tool is on, with nothing saved yet." : "\(otherCount) other tools are on, with nothing saved yet.")
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                }
                .padding(.top, DSSpace.xs)
                .font(.dsSecondary)
            } label: {
                Text("What’s being saved").font(.dsSection)
            }
        }
    }

    @ViewBuilder private func savedDates(for tool: ToolDefinition) -> some View {
        let dates = store.lastSavedByTool[tool.id] ?? []
        if store.state == .loaded || !dates.isEmpty {
            if dates.isEmpty {
                Text("No saved prompts.").foregroundStyle(Color.dsTextTertiary)
            } else {
                ForEach(dates) { saved in
                    let computer = saved.computerID.map { store.computers[$0] ?? $0 } ?? "Computer not recorded"
                    Text("\(computer) · Last saved prompt: \(saved.timestamp.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(Color.dsTextTertiary)
                }
                if let localID = store.localEdgeId, !dates.contains(where: { $0.computerID == localID }) {
                    Text("No saved prompts from this Mac.").foregroundStyle(Color.dsTextTertiary)
                }
            }
        } else {
            Text(store.state == .idle || store.state == .loading ? "Reading saved dates…" : "Saved dates unavailable.")
                .foregroundStyle(Color.dsTextTertiary)
        }
    }

    // MARK: - New dataset

    @ViewBuilder private var preparationContent: some View {
        switch store.state {
        case .idle, .loading:
            ProgressView("Reading history on this Mac…")
                .frame(maxWidth: .infinity, minHeight: 160)
        case .failed(let message):
            DSEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't read history", detail: message) {
                Button("Try again") { Task { await store.reload() } }
            }
        case .loaded:
            if store.rows.isEmpty {
                emptyHistory
            } else {
                VStack(alignment: .leading, spacing: DSSpace.l) {
                    selectionCard
                    optionsCard
                    previewCard
                }
            }
        }
    }

    private var emptyHistory: some View {
        DSCard {
            DSEmptyState(symbol: "tray", title: "No saved prompts yet",
                         detail: "Saved dictations will appear here. You can also import prompts from another app, or turn on typed history for places you choose.") {
                HStack(spacing: DSSpace.xs) {
                    Button("Import prompts…") { store.resetImport(); showImport = true }
                        .buttonStyle(.dsPrimary)
                    Button("Open history settings") { AppNavigation.shared.openSettings(.history) }
                }
            }
        }
    }

    // MARK: Which prompts

    private var selectionCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                    Text("Which prompts?")
                        .font(.dsSection)
                    Spacer(minLength: DSSpace.xs)
                    if store.query != DatasetQuery() {
                        Button("Reset") { resetQuery() }
                            .buttonStyle(.dsLink)
                            .font(.dsBody)
                    }
                    selectionsMenu
                }

                field("From") {
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        FlowRow(spacing: DSSpace.xs) {
                            timeChip("Last 24 hours", .days(1))
                            timeChip("Last 7 days", .days(7))
                            timeChip("Last 30 days", .days(30))
                            timeChip("All time", .all)
                            timeChip("Custom…", .custom)
                        }
                        if timeChoice == .custom {
                            HStack(spacing: DSSpace.m) {
                                DatePicker("Start", selection: Binding(get: { store.query.from ?? Date() }, set: { store.query.from = $0 }),
                                           displayedComponents: [.date, .hourAndMinute])
                                DatePicker("End", selection: Binding(get: { store.query.through ?? Date() }, set: { store.query.through = $0 }),
                                           displayedComponents: [.date, .hourAndMinute])
                            }
                            .font(.dsBody)
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DSSpace.l) { destinationField; inputField }
                    VStack(alignment: .leading, spacing: DSSpace.m) { destinationField; inputField }
                }

                field("Containing") {
                    HStack(spacing: DSSpace.xs) {
                        TextField("Any text (optional)", text: $store.query.text)
                            .textFieldStyle(.roundedBorder)
                            .font(.dsBody)
                        Picker("Text match", selection: $store.query.textMatch) {
                            Text("Exact phrase").tag(DatasetQuery.TextMatch.contains)
                            Text("All of these words").tag(DatasetQuery.TextMatch.allWords)
                            Text("Any of these words").tag(DatasetQuery.TextMatch.anyWord)
                            Text("Regular expression").tag(DatasetQuery.TextMatch.regex)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .font(.dsBody)
                    }
                }

                Divider().overlay(Color.dsDivider)

                DatasetDisclosure(title: "More filters", summary: moreFiltersSummary, isExpanded: $showMoreFilters) {
                    moreFilters
                }
            }
        }
    }

    /// One place to pick where prompts went: by vendor first, since that's
    /// how people think of AI tools, then by product, terminal or app.
    private var destinationField: some View {
        destinationPicker("Sent to", selected: Binding(get: { store.query.selectedDestinations }, set: {
            store.query.destinations = $0
            store.query.destination = nil
        }), empty: "Anywhere")
    }

    private func destinationPicker(_ title: String, selected: Binding<[String]>, empty: String) -> some View {
        field(title) {
            Menu {
                Button(empty) { selected.wrappedValue = [] }
                ForEach(store.destinationGroups) { group in
                    Section(group.title) {
                        if let allKey = group.allKey {
                            destinationToggle("All \(group.title) (\(group.allCount.formatted()))", key: allKey, selected: selected)
                        }
                        ForEach(group.options) { option in
                            destinationToggle("\(option.name) (\(option.count.formatted()))", key: option.key, selected: selected)
                        }
                    }
                }
                // Saved choices remain removable even if their records are no longer present.
                ForEach(selected.wrappedValue.filter { key in
                    !store.destinationGroups.contains { $0.allKey == key || $0.options.contains { $0.key == key } }
                }, id: \.self) { key in
                    destinationToggle(destinationLabel(key), key: key, selected: selected)
                }
            } label: {
                Text(selected.wrappedValue.isEmpty ? empty : selected.wrappedValue.map(destinationLabel).joined(separator: " or "))
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(title)
        }
    }

    private func destinationToggle(_ title: String, key: String, selected: Binding<[String]>) -> some View {
        Toggle(title, isOn: Binding(get: { selected.wrappedValue.contains(key) }, set: { enabled in
            var values = Set(selected.wrappedValue)
            if enabled { values.insert(key) } else { values.remove(key) }
            selected.wrappedValue = values.sorted()
        }))
    }

    private func destinationLabel(_ key: String) -> String {
        DatasetDestinationGroup.label(for: key, in: store.destinationGroups) ?? key
    }

    private var inputField: some View {
        field("Input") {
            Picker("Input", selection: $store.query.input) {
                Text("Spoken and typed").tag(DatasetQuery.Input.all)
                Text("Spoken").tag(DatasetQuery.Input.voice)
                Text("Typed").tag(DatasetQuery.Input.typed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var selectionsMenu: some View {
        Menu {
            Button("Save these choices…") {
                selectionName = store.name == "Prompt export" ? "" : store.name
                showSaveSelection = true
            }
            if !store.selections.isEmpty {
                Section("Use a saved selection") {
                    ForEach(store.selections) { item in
                        Button(item.name) {
                            store.useSelection(item)
                            syncTimeChoice()
                        }
                    }
                }
                Menu("Delete a saved selection") {
                    ForEach(store.selections) { item in
                        Button(item.name) { removeSelection = item }
                    }
                }
            }
        } label: {
            Label(store.selections.isEmpty ? "Saved selections" : "Saved selections (\(store.selections.count))", systemImage: "bookmark")
                .font(.dsBody)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Reuse filters and cleaning choices you've saved")
    }

    private var moreFilters: some View {
        VStack(alignment: .leading, spacing: DSSpace.m) {
            destinationPicker("Not sent to", selected: Binding(get: { store.query.excludedDestinations ?? [] },
                                                               set: { store.query.excludedDestinations = $0 }), empty: "No exclusions")
            field("Leave out text") {
                TextField("Any of these terms, separated by spaces", text: Binding(get: { store.query.excludedText ?? "" },
                                                                                  set: { store.query.excludedText = $0 }))
                    .textFieldStyle(.roundedBorder)
                Text("Leave out prompts containing any of these terms, ignoring case.")
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextTertiary)
            }
            takeField
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: DSSpace.s) {
                Picker("Saved by", selection: Binding(get: { store.query.savedBy }, set: { store.query.savedBy = $0 })) {
                    Text("Any way").tag(DatasetQuery.SavedBy?.none)
                    ForEach(DatasetQuery.SavedBy.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                // Only websites that aren't themselves an AI tool; those are under Sent to.
                optionalChoice("Website", value: $store.query.website,
                               options: Array(Set(store.rows.filter { $0.destination?.kind != .aiTool }.compactMap(\.webHost))).sorted())
                optionalChoice("Project folder", value: $store.query.project, options: values(\.workingDirectory))
                optionalChoice("Computer", value: $store.query.computer, options: values(\.originEdgeId), label: { id in store.computers[id] ?? id })
                optionalChoice("Remote host", value: $store.query.remoteHost, options: values(\.remoteHost))
                if store.query.imports == .captured {
                    Picker("Origin", selection: $store.query.imports) {
                        Text("Any").tag(DatasetQuery.Imports.all)
                        Text("Not imported").tag(DatasetQuery.Imports.captured)
                    }
                }
            }
            .font(.dsBody)

            HStack(alignment: .top, spacing: DSSpace.m) {
                if values(\.sessionId).count > 1 || !store.query.session.isEmpty {
                    field("Conversation ID") {
                        TextField("Exact ID", text: $store.query.session)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                field("Words, at least") {
                    TextField("0", value: $store.query.minimumWords, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                field("At most") {
                    TextField("No limit", value: $store.query.maximumWords, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }
            Text("Filters with only one value in your history are hidden. Text and word-count filters look at prompts as saved, before cleaning. 0 words means no limit.")
                .font(.dsSecondary)
                .foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var takeField: some View {
        field("Take") {
            HStack(spacing: DSSpace.xs) {
                Picker("Take", selection: Binding(get: { store.query.takeMode }, set: { mode in
                    store.query.take = mode
                    if store.query.takeCount == nil { store.query.takeCount = 100 }
                    if mode == .random && store.query.randomSeed == nil { store.query.randomSeed = UUID().uuidString }
                })) {
                    Text("All").tag(DatasetQuery.Take.all)
                    Text("Newest N").tag(DatasetQuery.Take.newest)
                    Text("Oldest N").tag(DatasetQuery.Take.oldest)
                    Text("Random N").tag(DatasetQuery.Take.random)
                }
                .labelsHidden()
                .fixedSize()
                if store.query.takeMode != .all {
                    TextField("Number", value: Binding(get: { store.query.takeCount ?? 100 }, set: { store.query.takeCount = $0 }), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityLabel("Number of prompts to take")
                }
                if store.query.takeMode == .random {
                    Button("Shuffle") { store.query.randomSeed = UUID().uuidString }
                        .controlSize(.small)
                        .help("Pick a new random selection")
                }
            }
            Text("Applied after all filters. Prompts stay in date order.")
                .font(.dsSecondary)
                .foregroundStyle(Color.dsTextTertiary)
        }
    }

    private var takeDescription: String? {
        let q = store.query
        guard q.takeMode != .all else { return nil }
        return "\(q.takeMode.rawValue) \((q.takeCount ?? 0).formatted())"
    }

    private var moreFiltersSummary: String {
        let q = store.query
        var active: [String] = []
        if !(q.excludedDestinations ?? []).isEmpty { active.append("not sent to " + (q.excludedDestinations ?? []).map(destinationLabel).joined(separator: " or ")) }
        if let excluded = q.excludedText, !excluded.isEmpty { active.append("leaving out “\(excluded)”") }
        if let takeDescription { active.append(takeDescription) }
        if let savedBy = q.savedBy { active.append(savedBy.label.lowercased()) }
        if !q.website.isEmpty { active.append("website") }
        if !q.project.isEmpty { active.append("project") }
        if !q.computer.isEmpty { active.append("computer") }
        if !q.remoteHost.isEmpty { active.append("remote host") }
        if q.imports == .captured { active.append("not imported") }
        if !q.session.isEmpty { active.append("conversation") }
        if q.minimumWords > 0 || q.maximumWords > 0 { active.append("word count") }
        if active.isEmpty { return "How it was saved, website, computer and length — none set" }
        return "Filtering by " + active.joined(separator: ", ")
    }

    // MARK: Preparation options

    private var optionsCard: some View {
        DSCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                DatasetDisclosure(title: "Cleaning and privacy", summary: cleaningSummary,
                                tone: store.preparation.redactSecrets ? .neutral : .warning, isExpanded: $showCleaning) {
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Toggle("Hide passwords and keys when their format is recognized", isOn: $store.preparation.redactSecrets)
                        Toggle("Remove empty prompts", isOn: $store.preparation.removeEmpty)
                        Toggle("Remove exact repeats from the same place and conversation", isOn: $store.preparation.deduplicate)
                        Toggle("Trim spaces and blank lines around each prompt", isOn: $store.preparation.trimWhitespace)
                        Text("Hiding keys doesn't make prompts anonymous. Names and other private details stay in the text, so check the preview before sharing.")
                            .font(.dsSecondary)
                            .foregroundStyle(Color.dsTextTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                    .font(.dsBody)
                }
                .padding(.horizontal, DSSpace.m)
                .padding(.vertical, DSSpace.s)

                Divider().overlay(Color.dsDivider)

                DatasetDisclosure(title: "Format and details", summary: formatSummary, isExpanded: $showFormat) {
                    VStack(alignment: .leading, spacing: DSSpace.m) {
                        field("Dataset name") {
                            TextField("Prompt export", text: $store.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                        }
                        field("File format") {
                            VStack(alignment: .leading, spacing: DSSpace.xs) {
                                Picker("File format", selection: $store.preparation.format) {
                                    Text("JSONL").tag(DatasetPreparation.Format.jsonl)
                                    Text("JSON").tag(DatasetPreparation.Format.json)
                                    Text("CSV").tag(DatasetPreparation.Format.csv)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                                Text(formatDescription)
                                    .font(.dsSecondary)
                                    .foregroundStyle(Color.dsTextTertiary)
                            }
                        }
                        field("Include with each prompt") {
                            VStack(alignment: .leading, spacing: DSSpace.xs) {
                                Toggle("Where it was sent: tool, app, website, project and conversation", isOn: $store.preparation.includeContext)
                                Toggle("Timing and clean-up model", isOn: $store.preparation.includeTiming)
                                Toggle("The filters used to make this dataset (in its manifest.json details file)", isOn: $store.preparation.includeSelection)
                            }
                            .toggleStyle(.checkbox)
                        }
                        Button("Restore defaults") { store.preparation = DatasetPreparation() }
                            .buttonStyle(.dsLink)
                            .disabled(store.preparation == DatasetPreparation())
                    }
                    .font(.dsBody)
                }
                .padding(.horizontal, DSSpace.m)
                .padding(.vertical, DSSpace.s)
            }
        }
    }

    private var cleaningSummary: String {
        let p = store.preparation
        var parts = [p.redactSecrets ? "Passwords and keys hidden" : "Passwords and keys are not hidden"]
        if p.removeEmpty { parts.append("empty prompts removed") }
        parts.append(p.deduplicate ? "repeats removed" : "repeats kept")
        return parts.joined(separator: " · ")
    }

    private var formatSummary: String {
        let p = store.preparation
        let details: String
        switch (p.includeContext, p.includeTiming) {
        case (true, true): details = "with where-sent and timing details"
        case (true, false): details = "with where-sent details"
        case (false, true): details = "with timing details"
        case (false, false): details = "text and date only"
        }
        return "\(p.format.rawValue.uppercased()) \(details) · named “\(store.name.isEmpty ? "Prompt export" : store.name)”"
    }

    private var formatDescription: String {
        switch store.preparation.format {
        case .jsonl: "One prompt per line. The easiest for agents and scripts to read."
        case .json: "One structured list of prompts."
        case .csv: "Opens in spreadsheet apps. A JSON copy is always included for agents."
        }
    }

    // MARK: Preview

    private var previewCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                Text("What the agent will get")
                    .font(.dsSection)

                if let error = store.queryError {
                    DatasetNotice(text: error, tone: .warning)
                    Text("Fix this filter to see the preview and create the dataset.")
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                } else if let dataset = store.dataset {
                    datasetSummary(dataset)

                    if dataset.records.isEmpty {
                        emptyPreview(dataset)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(dataset.records.prefix(previewLimit)) { record in
                                Divider().overlay(Color.dsDivider)
                                previewRow(record).padding(.vertical, DSSpace.s)
                            }
                        }
                        if dataset.records.count > previewLimit {
                            Button("Show \(min(20, dataset.records.count - previewLimit)) more (\(previewLimit.formatted()) of \(dataset.records.count.formatted()) shown)") {
                                previewLimit += 20
                            }
                            .buttonStyle(.dsLink)
                            .font(.dsBody)
                        }
                        DatasetDisclosure(title: "The file itself",
                                        summary: "\(store.preparation.format.rawValue.uppercased()) · \(ByteCountFormatter.string(fromByteCount: Int64(dataset.data.count), countStyle: .file)) · plus manifest.json and SCHEMA.md, which describe it",
                                        actions: ("Show", "Hide"), isExpanded: $filePreview) {
                            VStack(alignment: .leading, spacing: DSSpace.xs) {
                                ScrollView([.horizontal, .vertical]) {
                                    Text(String(decoding: dataset.data.prefix(24_000), as: UTF8.self))
                                        .font(.dsMono)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(DSSpace.xs)
                                }
                                .frame(height: 220)
                                .background(Color.dsSurfaceSunken, in: RoundedRectangle(cornerRadius: DSRadius.control))
                                if dataset.data.count > 24_000 {
                                    Text("Showing the first 24,000 bytes. The dataset has the full file.")
                                        .font(.dsSecondary)
                                        .foregroundStyle(Color.dsTextTertiary)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView("Updating preview…")
                        .font(.dsBody)
                }
            }
        }
    }

    private func datasetSummary(_ dataset: Dataset) -> some View {
        let manifest = dataset.manifest
        var changes: [String] = []
        if manifest.emptyRemoved > 0 { changes.append("\(manifest.emptyRemoved.formatted()) empty removed") }
        if manifest.duplicatesRemoved > 0 { changes.append("\(manifest.duplicatesRemoved.formatted()) \(manifest.duplicatesRemoved == 1 ? "repeat" : "repeats") removed") }
        if manifest.recordsChangedByRedaction > 0 { changes.append("keys hidden in \(manifest.recordsChangedByRedaction.formatted())") }
        return VStack(alignment: .leading, spacing: DSSpace.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                Text(dataset.records.count.formatted())
                    .font(.dsStat)
                    .monospacedDigit()
                Text(promptLabel(dataset.records.count))
                    .font(.dsBody)
                    .foregroundStyle(Color.dsTextSecondary)
                if let first = manifest.earliest, let last = manifest.latest {
                    Text("· \(dateSpan(first, last))")
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            Text("Matched \(manifest.matchedRecords.formatted()), took \((manifest.takenRecords ?? manifest.matchedRecords).formatted())")
                .font(.dsBody)
                .foregroundStyle(Color.dsTextSecondary)
            Text(selectionDescription + (changes.isEmpty ? "" : " · " + changes.joined(separator: ", ")))
                .font(.dsBody)
                .foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The current filters read back as a sentence fragment.
    private var selectionDescription: String {
        let q = store.query
        var parts: [String] = []
        switch timeChoice {
        case .all: parts.append(q.from == nil && q.through == nil ? "All time" : "Custom dates")
        case .days(let days): parts.append(days == 1 ? "Last 24 hours" : "Last \(days) days")
        case .custom: parts.append("Custom dates")
        }
        if !q.selectedDestinations.isEmpty {
            parts.append(q.selectedDestinations.map(destinationLabel).joined(separator: " or "))
        } else {
            parts.append("anywhere")
        }
        if let savedBy = q.savedBy { parts.append(savedBy.label.lowercased()) }
        switch q.input {
        case .all: parts.append("spoken and typed")
        case .voice: parts.append("spoken only")
        case .typed: parts.append("typed only")
        }
        if !q.text.isEmpty { parts.append("containing “\(q.text)”") }
        if !(q.excludedDestinations ?? []).isEmpty { parts.append("not sent to " + (q.excludedDestinations ?? []).map(destinationLabel).joined(separator: " or ")) }
        if let excluded = q.excludedText, !excluded.isEmpty { parts.append("leaving out “\(excluded)”") }
        if let takeDescription { parts.append(takeDescription) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func emptyPreview(_ dataset: Dataset) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text("Matched \(dataset.manifest.matchedRecords.formatted()), took \((dataset.manifest.takenRecords ?? dataset.manifest.matchedRecords).formatted())")
                .font(.dsBody)
                .foregroundStyle(Color.dsTextSecondary)
            if dataset.manifest.matchedRecords == 0 {
                DSEmptyState(title: "No prompts match these choices.", detail: "Widen the time range or remove a filter.") {
                    Button("Reset filters") { resetQuery() }
                }
            } else {
                DSEmptyState(title: "Nothing is left after cleaning.",
                             detail: "\((dataset.manifest.takenRecords ?? dataset.manifest.matchedRecords).formatted()) prompts taken, but all were empty or repeats.") {
                    Button("Keep empty prompts and repeats") {
                        store.preparation.removeEmpty = false
                        store.preparation.deduplicate = false
                    }
                }
            }
        }
        .padding(.vertical, DSSpace.xs)
    }

    private func previewRow(_ record: DatasetRecord) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Button {
                expanded = expanded == record.id ? nil : record.id
            } label: {
                HStack(spacing: DSSpace.xs) {
                    Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                    if let place = record.destination ?? record.appName {
                        Text("·")
                        Text(place)
                    }
                    Text("·")
                    Text(record.input == "voice" ? "Spoken" : "Typed")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.dsIconSmall)
                        .rotationEffect(.degrees(expanded == record.id ? 90 : 0))
                }
                .font(.dsSecondary)
                .foregroundStyle(Color.dsTextTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded == record.id ? "Hide prompt details" : "Show prompt details")
            Text(record.text)
                .font(.dsBody)
                .lineLimit(expanded == record.id ? nil : 2)
                .textSelection(.enabled)
            if expanded == record.id {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: DSSpace.xs) {
                    ForEach(recordDetails(record), id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: DSSpace.hair) {
                            Text(label)
                                .font(.dsSecondaryMedium)
                                .foregroundStyle(Color.dsTextTertiary)
                            Text(value)
                                .font(.dsBody)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, DSSpace.xxs)
            }
        }
    }

    private func recordDetails(_ record: DatasetRecord) -> [(String, String)] {
        var details: [(String, String)] = [
            ("Input", (record.input == "voice" ? "Spoken" : "Typed") + (record.imported ? " · Imported" : "")),
            ("Words", record.wordCount.formatted())
        ]
        if let destination = record.destination { details.append(("Sent to", destination + (record.vendor.map { $0 == destination ? "" : " · \($0)" } ?? ""))) }
        if let savedBy = record.savedBy.flatMap(DatasetQuery.SavedBy.init(rawValue:)) { details.append(("Saved by", savedBy.label)) }
        if let app = record.appName ?? record.appID, app != record.destination { details.append(("App", app)) }
        if let website = record.website { details.append(("Website", website)) }
        if let project = record.project { details.append(("Project", project)) }
        if let computer = record.computerName ?? record.computer { details.append(("Computer", computer)) }
        if let session = record.session { details.append(("Conversation ID", session)) }
        if let remoteHost = record.remoteHost { details.append(("Remote host", remoteHost)) }
        if let seconds = record.speakingSeconds { details.append(("Speaking time", "\(seconds.formatted(.number.precision(.fractionLength(1)))) seconds")) }
        if let milliseconds = record.latencyMilliseconds { details.append(("Time until text appeared", "\(milliseconds) ms")) }
        if let model = record.cleanupModel { details.append(("Clean-up model", model)) }
        return details
    }

    // MARK: Action bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.dsBorder)
            Group {
                if let package = store.readyPackage {
                    readyBar(package)
                } else {
                    createBar
                }
            }
            .padding(.vertical, DSSpace.m)
            .dsPageFrame()
        }
        .background(Color.dsBgContent)
    }

    private var createBar: some View {
        HStack(spacing: DSSpace.m) {
            if store.busy || store.preparing { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                Text(actionTitle)
                    .font(.dsBodyMedium)
                Text("Creating saves it on this Mac. Then copy the prompts or save one file to upload to your chat app.")
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DSSpace.s)
            Button("Create dataset") { Task { await store.savePackage() } }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!store.canSave)
        }
    }

    private func readyBar(_ package: DatasetPackage) -> some View {
        let summary = VStack(alignment: .leading, spacing: DSSpace.hair) {
            Label("Dataset ready · \(package.manifest.exportedRecords.formatted()) \(promptLabel(package.manifest.exportedRecords))", systemImage: "checkmark.circle.fill")
                .font(.dsBodyMedium)
                .foregroundStyle(Color.dsSuccess)
            Text("Copy the prompts to paste into your chat app, or upload them as one file. Then add your task.")
                .font(.dsSecondary)
                .foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpace.xs) {
                summary
                Spacer(minLength: DSSpace.s)
                handoffActions(package)
            }
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                summary
                HStack(spacing: DSSpace.xs) { handoffActions(package) }
            }
        }
    }

    /// Both chat actions use the same rendered text from the saved canonical records.
    @ViewBuilder private func handoffActions(_ package: DatasetPackage) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            if let handoff = store.handoffs[package.id] {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DSSpace.xs) { chatActions(handoff, package: package) }
                    VStack(alignment: .leading, spacing: DSSpace.xs) { chatActions(handoff, package: package) }
                }
                if handoff.prefersFile {
                    Text("This dataset is too long to paste reliably. Save it as one file to upload.")
                        .font(.dsSecondary)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            } else if store.handoffFailures.contains(package.id) {
                Button("Try preparing prompts again") { Task { await store.prepareHandoff(package) } }
            } else {
                ProgressView("Preparing prompts…").controlSize(.small)
            }
        }
        .task(id: package.id) { await store.prepareHandoff(package) }
        DatasetCopyButton(title: "Copy location for a local agent", systemImage: "folder") { package.agentBrief() }
            .help("Copies the folder location and file list for an agent that can read this Mac's files")
        Menu {
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(package.url.path, forType: .string)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([package.url]) }
            Button("Save a copy to a folder…") { export(package) }
                .disabled(store.busy || store.running)
            Divider()
            Button("Attach a report…") { attach(package) }
                .disabled(store.busy || store.running)
            Button("Run a local tool on it…") { cliPackage = package }
                .disabled(store.busy || store.running)
            Divider()
            Button("Delete dataset…", role: .destructive) { removePackage = package }
                .disabled(store.busy || store.running)
        } label: {
            Image(systemName: "ellipsis")
                .font(.dsIcon)
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, DSSpace.xs)
        .frame(minHeight: 36)
        .background(Color.dsSurfaceControl, in: RoundedRectangle(cornerRadius: DSRadius.control))
        .accessibilityLabel("More for this dataset")
    }

    @ViewBuilder private func chatActions(_ handoff: DatasetHandoff, package: DatasetPackage) -> some View {
        if handoff.prefersFile {
            saveHandoffButton(handoff, package: package, prominent: true)
        }
        DatasetCopyButton(title: "Copy prompts", systemImage: "doc.on.doc", prominent: !handoff.prefersFile) { handoff.text }
            .help("Copies all prepared prompts and dataset notes as self-contained text to paste into your chat app")
        if !handoff.prefersFile {
            saveHandoffButton(handoff, package: package, prominent: false)
        }
        Text("\(handoff.promptCount.formatted()) \(promptLabel(handoff.promptCount)) · about \(handoff.approximateTokens.formatted()) tokens (approximate)")
            .font(.dsSecondary)
            .foregroundStyle(Color.dsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func saveHandoffButton(_ handoff: DatasetHandoff, package: DatasetPackage, prominent: Bool) -> some View {
        Button("Save as one file…") {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = package.manifest.name.replacingOccurrences(of: "/", with: "-") + ".md"
            panel.message = "Save the same prompts and notes as one file to upload to your chat app."
            if panel.runModal() == .OK, let destination = panel.url {
                Task { await store.saveHandoff(handoff, to: destination) }
            }
        }
        .buttonStyle(DSButtonStyle(kind: prominent ? .primary : .secondary))
        .help("Saves all prepared prompts and dataset notes in one Markdown file for upload")
    }

    private var actionTitle: String {
        if let busyTitle = store.busyTitle { return busyTitle }
        if store.preparing { return "Updating preview…" }
        if store.queryError != nil { return "Fix the filters to continue" }
        let count = store.dataset?.records.count ?? 0
        if count == 0 { return "No prompts to include" }
        return "\(count.formatted()) \(promptLabel(count)) · \(store.preparation.format.rawValue.uppercased())"
    }

    // MARK: - Datasets

    private var archiveContent: some View {
        VStack(alignment: .leading, spacing: DSSpace.m) {
            if store.packages.isEmpty {
                DSEmptyState(symbol: "archivebox", title: "No datasets yet",
                             detail: "Datasets you create are kept here, unchanged, until you delete them.") {
                    Button("Create a dataset") { tab = 0 }
                }
            } else {
                Text("Each dataset is a snapshot. Later changes to your history don't affect it.")
                    .font(.dsBody)
                    .foregroundStyle(Color.dsTextSecondary)
                ForEach(store.packages) { package in
                    DSCard {
                        VStack(alignment: .leading, spacing: DSSpace.s) {
                            VStack(alignment: .leading, spacing: DSSpace.hair) {
                                Text(package.manifest.name).font(.dsBodyMedium)
                                Text(packageSubtitle(package))
                                    .font(.dsSecondary)
                                    .foregroundStyle(Color.dsTextSecondary)
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: DSSpace.xs) { handoffActions(package) }
                                VStack(alignment: .leading, spacing: DSSpace.xs) { handoffActions(package) }
                            }
                            if !package.reports.isEmpty {
                                Divider().overlay(Color.dsDivider)
                                Text("Attached reports").font(.dsSection)
                                ForEach(package.reports, id: \.path) { report in
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([report]) } label: {
                                        Label(report.lastPathComponent, systemImage: "doc.text")
                                    }
                                    .buttonStyle(.dsLink)
                                    .font(.dsBody)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func packageSubtitle(_ package: DatasetPackage) -> String {
        let m = package.manifest
        var parts = ["\(m.exportedRecords.formatted()) \(promptLabel(m.exportedRecords))", m.preparation.format.rawValue.uppercased()]
        if let first = m.earliest, let last = m.latest { parts.append(dateSpan(first, last)) }
        parts.append("created \(m.createdAt.formatted(date: .abbreviated, time: .shortened))")
        return parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(title)
                .font(.dsSecondaryMedium)
                .foregroundStyle(Color.dsTextTertiary)
            content()
        }
    }

    private func timeChip(_ title: String, _ value: TimeChoice) -> some View {
        DatasetTimeChoice(title: title, selected: timeChoice == value) { setTime(value) }
    }

    /// Relative ranges have no end, so prompts saved later still count.
    private func setTime(_ value: TimeChoice) {
        timeChoice = value
        switch value {
        case .all:
            store.query.from = nil; store.query.through = nil
        case .days(let days):
            store.query.from = Calendar.current.date(byAdding: .day, value: -days, to: Date())
            store.query.through = nil
        case .custom:
            let now = Date()
            if store.query.from == nil { store.query.from = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: now)) }
            if store.query.through == nil { store.query.through = now }
        }
    }

    private func syncTimeChoice() {
        timeChoice = store.query.from == nil && store.query.through == nil ? .all : .custom
    }

    private func resetQuery() {
        store.query = DatasetQuery()
        timeChoice = .all
    }

    private func dateSpan(_ first: Date, _ last: Date) -> String {
        let a = first.datasetShort, b = last.datasetShort
        return a == b ? a : "\(a) – \(b)"
    }

    private func values(_ key: KeyPath<DatasetRow, String?>) -> [String] {
        Array(Set(store.rows.compactMap { $0[keyPath: key] }.filter { !$0.isEmpty })).sorted()
    }

    /// A filter worth showing only when history has more than one value for
    /// it, or when it's already set (from a saved selection).
    @ViewBuilder private func optionalChoice(_ title: String, value: Binding<String>, options: [String],
                                             label: @escaping (String) -> String = { $0 }) -> some View {
        if options.count > 1 || !value.wrappedValue.isEmpty {
            choice(title, value: value, options: options, label: label)
        }
    }

    private func choice(_ title: String, value: Binding<String>, options: [String], any: String = "Any",
                        label: @escaping (String) -> String = { $0 }) -> some View {
        Picker(title, selection: value) {
            Text(any).tag("")
            // Keep saved filters visible when their original records have been removed.
            if !value.wrappedValue.isEmpty && !options.contains(value.wrappedValue) {
                Text(label(value.wrappedValue)).tag(value.wrappedValue)
            }
            ForEach(options, id: \.self) { item in Text(label(item)).tag(item) }
        }
        .lineLimit(1)
    }

    private func promptLabel(_ count: Int) -> String {
        count == 1 ? "prompt" : "prompts"
    }

    private var saveSelectionSheet: some View {
        DSSheet(title: "Save these choices",
                subtitle: "Saves the filters, cleaning and format so you can make a fresh dataset from them later. Nothing is exported.",
                width: .compact) {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text("Name").font(.dsBodyMedium)
                TextField("For example, Coding prompts this month", text: $selectionName)
                    .textFieldStyle(.roundedBorder)
            }
        } actions: {
            Button("Cancel") { showSaveSelection = false }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                store.saveSelection(name: selectionName)
                if store.lastError == nil { showSaveSelection = false }
            }
            .buttonStyle(.dsPrimary)
            .disabled(selectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func destination() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder for a copy of the dataset. The original stays in Datasets."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save copy here"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func export(_ package: DatasetPackage) {
        guard let url = destination() else { return }
        Task { await store.exportPackage(package, to: url) }
    }

    private func attach(_ package: DatasetPackage) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.message = "Choose a report to keep with this dataset, such as your agent's findings. Dictator stores it unchanged."
        if panel.runModal() == .OK, let url = panel.url {
            Task { await store.attachReport(url, to: package) }
        }
    }
}

private struct DatasetCLISheet: View {
    @Bindable var store: DatasetStore
    let package: DatasetPackage
    @Environment(\.dismiss) private var dismiss
    @State private var arguments = ""

    var body: some View {
        DSSheet(title: "Run a local tool",
                subtitle: "\(package.manifest.name) · \(package.manifest.exportedRecords.formatted()) prompts", width: .wide) {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                Text("Runs a program on this Mac with your existing setup. Dictator sends it your instructions, the dataset's details and all prompts as JSON on standard input, and it may pass them to whichever service it is set up for.")
                    .font(.dsBody)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DSSpace.xs) {
                    TextField("Full path to the program", text: $store.cli.executable)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { store.cli.executable = url.path }
                    }
                }
                Text("Arguments (options added after the program's path) — one per line, passed as written").font(.dsCaption)
                TextEditor(text: $arguments)
                    .font(.dsMono)
                    .frame(height: 70)
                    .border(Color.dsBorder)
                Text("Your instructions (optional)").font(.dsCaption)
                TextEditor(text: $store.cli.instructions)
                    .font(.dsSecondary)
                    .frame(height: 100)
                    .border(Color.dsBorder)
                Text("It runs inside the dataset's folder. Its output, errors, exact input and command are saved with the dataset. Dictator starts it directly, not through a shell, so * and $ stay as typed. Dictator doesn't pick a provider or model.")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Run tool") {
                store.cli.arguments = arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
                Task { await store.runCLI(for: package) }
                dismiss()
            }
            .buttonStyle(.dsPrimary)
            .disabled(store.cli.executable.isEmpty || store.running)
        }
        .onAppear { arguments = store.cli.arguments.joined(separator: "\n") }
    }
}

/// A time-range value choice, separate from the page's navigation tabs.
private struct DatasetTimeChoice: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.dsBodyMedium)
                .foregroundStyle(selected ? Color.dsAccent : Color.dsTextPrimary)
                .padding(.horizontal, DSSpace.s)
                .padding(.vertical, DSSpace.xs)
                .background(selected ? Color.dsAccentQuiet : Color.dsSurfaceControl, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
