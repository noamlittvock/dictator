import CryptoKit
import Foundation
import Observation

struct DatasetSelection: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var query: DatasetQuery
    var preparation: DatasetPreparation
}

@Observable
@MainActor
final class DatasetStore {
    static let shared = DatasetStore(loadSavedState: false)
    enum State: Equatable { case idle, loading, loaded, failed(String) }
    private(set) var state: State = .idle
    private(set) var rows: [DatasetRow] = [] {
        didSet {
            destinationGroups = DatasetDestinationGroup.groups(for: rows)
            lastSavedByTool = DatasetToolLastSaved.byTool(in: rows)
        }
    }
    private(set) var lastSavedByTool: [String: [DatasetToolLastSaved]] = [:]
    /// "Sent to" choices with counts, rebuilt whenever history is read.
    private(set) var destinationGroups: [DatasetDestinationGroup] = []
    private(set) var dataset: Dataset?
    private(set) var preparing = false
    private(set) var refreshing = false
    private(set) var busy = false
    private(set) var busyTitle: String?
    private(set) var running = false
    private(set) var packages: [DatasetPackage] = []
    private(set) var handoffs: [UUID: DatasetHandoff] = [:]
    private(set) var handoffFailures: Set<UUID> = []
    private var loadingHandoffs: Set<UUID> = []
    private(set) var selections: [DatasetSelection] = []
    private(set) var computers: [String: String] = [:]
    private(set) var importSession = ImportSession()
    private(set) var lastSavedPackage: DatasetPackage?
    private(set) var lastExportedURL: URL?
    private(set) var lastCLIPackage: DatasetPackage?
    var query = DatasetQuery() { didSet { editRevision += 1; prepare() } }
    var preparation = DatasetPreparation() { didSet { editRevision += 1; prepare() } }
    var name = "Prompt export" { didSet { editRevision += 1; prepare() } }
    /// Bumped only by the user's own choices, so a dictation arriving after
    /// Create doesn't retract the "ready" hand-off while it's being used.
    private(set) var editRevision = 0
    private var created: (package: DatasetPackage, editRevision: Int)?
    /// The dataset just created from the current choices, if they haven't changed since.
    var readyPackage: DatasetPackage? {
        guard let created, created.editRevision == editRevision else { return nil }
        return packages.first { $0.id == created.package.id } ?? created.package
    }
    var cli = DatasetCLI()
    var lastError: String?
    private(set) var queryError: String?
    var notice: String?
    private let archive: DatasetArchive
    private var hub: RepositoryHub?
    private var knownComputers: () -> [String: String] = { [:] }
    private(set) var localEdgeId: String?
    private var started = false
    private var prepareTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var runner: DatasetCLIRunner?
    private var revision = 0
    private var persistedSelections: [DatasetSelection] = []
    private var savedStateLoaded = false

    init(archive: DatasetArchive = .local, loadSavedState: Bool = true) {
        self.archive = archive
        if loadSavedState { restoreSavedState() }
    }

    private func restoreSavedState() {
        guard !savedStateLoaded else { return }
        savedStateLoaded = true
        do {
            let url = archive.root.appendingPathComponent("preferences.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let saved = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
                selections = saved.selections; cli = saved.cli; computers = saved.computers
                persistedSelections = saved.selections
            }
            packages = try archive.packages()
        } catch { lastError = "Dictator couldn't read your saved dataset choices: \(error.localizedDescription)" }
    }

    func start(hub: RepositoryHub, localEdgeId: String, computers: @escaping () -> [String: String]) {
        self.hub = hub; self.localEdgeId = localEdgeId; knownComputers = computers
        guard !started else { return }; started = true
        observeHistory()
        // No background scanning, matching, notifications or tool-log access.
    }

    func ensureLoaded() {
        restoreSavedState()
        if state == .idle { Task { await reload() } }
    }

    func reload() async {
        restoreSavedState()
        refreshing = true
        defer { refreshing = false }
        do { packages = try archive.packages() } catch { lastError = error.localizedDescription }
        guard let history = hub?.current.history as? HistoryDatasetStore else {
            if rows.isEmpty {
                state = .failed("History isn't available on this Mac yet.")
            } else {
                lastError = "History isn't available on this Mac yet. Showing the last loaded copy."
            }
            return
        }
        if rows.isEmpty { state = .loading }
        do {
            let fetched = try await history.datasetRows()
            let resolver = DatasetDestinationResolver(catalog: ToolCatalog.shared)
            rows = await Task.detached(priority: .userInitiated) { resolver.annotate(fetched) }.value
            computers.merge(knownComputers(), uniquingKeysWith: { _, new in new })
            if let localEdgeId { computers[localEdgeId] = Host.current().localizedName ?? "This Mac" }
            state = .loaded
            prepare()
        } catch {
            if rows.isEmpty {
                state = .failed(error.localizedDescription)
            } else {
                state = .loaded
                lastError = "Couldn't refresh history. Showing the last loaded copy. \(error.localizedDescription)"
            }
        }
    }

    private func observeHistory() {
        guard let hub else { return }
        withObservationTracking { _ = hub.historyVersion } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeHistory()
                if self.state != .idle {
                    self.reloadTask?.cancel()
                    self.reloadTask = Task {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        await self.reload()
                    }
                }
            }
        }
    }

    func loadForPreview(_ rows: [DatasetRow], catalog: ToolCatalog = ToolCatalog.shared) async {
        self.rows = DatasetDestinationResolver(catalog: catalog).annotate(rows); state = .loaded
        prepare()
        await prepareTask?.value
    }

    private func prepare() {
        guard state == .loaded else { return }
        revision += 1
        let expected = revision
        prepareTask?.cancel(); preparing = true
        let rows = rows, query = query, options = preparation, computers = computers, title = name
        prepareTask = Task { [weak self] in
            // Coalesce typing before scanning. The detached task never touches the store.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Dataset.build(rows: rows, query: query, preparation: options, computers: computers, name: title) }
            }.value
            guard !Task.isCancelled, let self, self.revision == expected else { return }
            self.preparing = false
            switch result {
            case .success(let value): self.dataset = value; self.queryError = nil
            case .failure(let error): self.dataset = nil; self.queryError = error.localizedDescription
            }
        }
    }

    var canSave: Bool { state == .loaded && !preparing && !busy && !running && !(dataset?.records.isEmpty ?? true) }

    private func clearActionFeedback() {
        lastError = nil
        notice = nil
        lastSavedPackage = nil
        lastExportedURL = nil
        lastCLIPackage = nil
    }

    func savePackage(exportTo destination: URL? = nil) async {
        guard canSave, let dataset else { return }
        busy = true
        busyTitle = "Creating dataset…"
        clearActionFeedback()
        defer { busy = false; busyTitle = nil }
        let archive = archive
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let package = try archive.save(dataset)
                // A second Save of the same prepared preview gets a distinct package.
                return package
            }.value
            // A completed save gets a new identity without rescanning unchanged data.
            if self.dataset?.manifest.id == dataset.manifest.id {
                self.dataset?.manifest.id = UUID()
                self.dataset?.manifest.createdAt = Date()
            }
            packages = try archive.packages()
            lastSavedPackage = packages.first { $0.id == result.id } ?? result
            created = (lastSavedPackage ?? result, editRevision)
            if let destination {
                do {
                    let exportedURL = try await Task.detached { try archive.export(result, to: destination) }.value
                    lastExportedURL = exportedURL
                    notice = "Saved a copy of the dataset in the chosen folder. The original stays in Datasets."
                } catch { lastError = "The dataset was created, but the copy couldn't be saved in that folder: \(error.localizedDescription)" }
            }
        } catch { lastError = error.localizedDescription }
    }

    /// Loading and rendering use only the integrity-checked saved snapshot, never history.
    func prepareHandoff(_ package: DatasetPackage) async {
        guard handoffs[package.id] == nil, loadingHandoffs.insert(package.id).inserted else { return }
        handoffFailures.remove(package.id)
        defer { loadingHandoffs.remove(package.id) }
        let archive = archive
        do {
            let handoff = try await Task.detached(priority: .userInitiated) {
                let saved = try archive.load(package)
                return try DatasetHandoff.render(records: saved.records, manifest: saved.manifest)
            }.value
            handoffs[package.id] = handoff
        } catch {
            handoffFailures.insert(package.id)
            lastError = "Couldn't prepare the prompts: \(error.localizedDescription)"
        }
    }

    func saveHandoff(_ handoff: DatasetHandoff, to destination: URL) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try Data(handoff.text.utf8).write(to: destination, options: .atomic)
            }.value
            lastExportedURL = destination
            notice = "Saved the prompts as one file for upload to your chat app."
        } catch { lastError = "Couldn't save the prompts: \(error.localizedDescription)" }
    }

    func exportPackage(_ package: DatasetPackage, to destination: URL) async {
        guard !busy, !running else { return }
        busy = true; busyTitle = "Saving a copy…"
        clearActionFeedback(); lastSavedPackage = package; lastExportedURL = nil
        defer { busy = false; busyTitle = nil }
        let archive = archive
        do {
            let exportedURL = try await Task.detached { try archive.export(package, to: destination) }.value
            lastExportedURL = exportedURL
            notice = "Saved a copy of the dataset in the chosen folder, including attached reports."
        } catch { lastError = error.localizedDescription }
    }

    func attachReport(_ source: URL, to package: DatasetPackage) async {
        guard !busy, !running else { return }
        busy = true; busyTitle = "Adding report…"
        clearActionFeedback()
        defer { busy = false; busyTitle = nil }
        let archive = archive
        do {
            try await Task.detached { try archive.attachReport(source, to: package) }.value
            packages = try archive.packages()
            lastSavedPackage = packages.first { $0.id == package.id }
            notice = "Attached the report to the dataset without changing it."
        } catch { lastError = error.localizedDescription }
    }

    func removePackage(_ package: DatasetPackage) async {
        guard !running, !busy else { return }
        busy = true; busyTitle = "Deleting dataset…"
        clearActionFeedback()
        defer { busy = false; busyTitle = nil }
        let archive = archive
        do {
            try await Task.detached { try archive.remove(package) }.value
            packages = try archive.packages()
            if lastSavedPackage?.id == package.id { lastSavedPackage = nil }
            if created?.package.id == package.id { created = nil }
            handoffs.removeValue(forKey: package.id)
            handoffFailures.remove(package.id)
            notice = "Deleted the dataset and its attached reports from this Mac. Your history and copies saved elsewhere are unchanged."
        } catch { lastError = error.localizedDescription }
    }

    func runCLI(for package: DatasetPackage) async {
        guard !running, !busy else { return }
        guard !cli.executable.isEmpty else { lastError = "Choose the program to run first."; return }
        running = true
        clearActionFeedback(); lastCLIPackage = package
        let runner = DatasetCLIRunner(); self.runner = runner
        defer { running = false; self.runner = nil }
        let archive = archive, cli = cli
        do {
            try savePreferences()
            let result = try await Task.detached(priority: .userInitiated) {
                let dataset = try archive.load(package)
                return try runner.run(cli, input: dataset.agentInput(instructions: cli.instructions), directory: package.url)
            }.value
            if result.exitCode == 0 {
                notice = "The tool finished. Its output is saved with this dataset."
            } else {
                lastError = "The tool stopped with an error. Its output is saved with this dataset."
            }
        } catch is CancellationError {
            notice = "Tool run cancelled. Available output is kept with the dataset."
        } catch { lastError = error.localizedDescription }
        do {
            packages = try archive.packages()
            lastCLIPackage = packages.first { $0.id == package.id } ?? package
        } catch { lastError = error.localizedDescription }
    }

    func cancelCLI() { runner?.cancel() }

    func saveSelection(name presetName: String? = nil) {
        let selectionName = (presetName ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectionName.isEmpty else { lastError = "Give the selection a name first."; return }
        clearActionFeedback()
        do {
            try query.validate()
            let item = DatasetSelection(name: selectionName, query: query, preparation: preparation)
            selections.append(item)
            try savePreferences()
            notice = "Saved the selection on this Mac."
        } catch { selections = persistedSelections; lastError = error.localizedDescription }
    }

    func useSelection(_ selection: DatasetSelection) {
        query = selection.query; preparation = selection.preparation
    }

    func removeSelection(_ id: UUID) {
        clearActionFeedback()
        selections.removeAll { $0.id == id }
        do {
            try savePreferences()
            notice = "Deleted the saved selection. Your history and datasets are unchanged."
        } catch { selections = persistedSelections; lastError = error.localizedDescription }
    }

    private struct Preferences: Codable { var selections: [DatasetSelection]; var cli: DatasetCLI; var computers: [String: String] }
    func savePreferences() throws {
        try FileManager.default.createDirectory(at: archive.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Internal preferences preserve Foundation Date precision, including filter bounds.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Preferences(selections: selections, cli: cli, computers: computers))
            .write(to: archive.root.appendingPathComponent("preferences.json"), options: .atomic)
        persistedSelections = selections
    }
    // MARK: - Import history

    struct ImportSession {
        enum Stage: Equatable {
            case choosing
            case reading
            case preview
            case importing
            case done(Int)
            case failed(String)
        }
        var kind: ImportSourceKind?
        var url: URL?
        var stage: Stage = .choosing
        var preview: ImportPreview?
        var batchID: String?
    }

    func resetImport() {
        importSession = ImportSession()
    }

    func chooseImportSource(_ kind: ImportSourceKind) {
        importSession = ImportSession(kind: kind)
    }

    func readImport(from url: URL?) async {
        guard let kind = importSession.kind else { return }
        importSession.url = url
        importSession.stage = .reading
        if rows.isEmpty { await reload() }
        let existing = rows
        let store = hub?.current.history as? HistoryDatasetStore
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try HistoryImportReader.read(kind, from: url)
            }.value
            // Prompts this importer already wrote keep their id (derived
            // from the source's own message id), so they're recognised.
            let candidateIDs = Dictionary(result.prompts.map { (Self.importID($0.sourceKey), $0.sourceKey) }, uniquingKeysWith: { a, _ in a })
            var importedKeys = Set<String>()
            var deletedKeys = Set<String>()
            if let store {
                let ids = Array(candidateIDs.keys)
                for start in stride(from: 0, to: ids.count, by: 2_000) {
                    let batch = Array(ids[start..<min(start + 2_000, ids.count)])
                    let present = try await store.existingIDs(ids: batch)
                    let deleted = try await store.deletionIDs(ids: batch)
                    for id in present { if let key = candidateIDs[id] { importedKeys.insert(key) } }
                    for id in deleted { if let key = candidateIDs[id] { deletedKeys.insert(key) } }
                }
            }
            let preview = await Task.detached(priority: .userInitiated) {
                ImportDeduper.preview(result, existing: existing, importedKeys: importedKeys, deletedKeys: deletedKeys)
            }.value
            importSession.preview = preview
            importSession.stage = .preview
        } catch {
            importSession.stage = .failed(error.localizedDescription)
        }
    }

    func runImport() async {
        guard let kind = importSession.kind, let preview = importSession.preview,
              let store = hub?.current.history as? HistoryDatasetStore else { return }
        importSession.stage = .importing
        let batchID = Self.makeBatchID(kind)
        let dtos = preview.toImport.map { Self.dto(for: $0, kind: kind, batchID: batchID) }
        do {
            let inserted = try await store.insertImported(dtos)
            importSession.batchID = batchID
            importSession.stage = .done(inserted)
            await reload()
        } catch {
            importSession.stage = .failed(error.localizedDescription)
        }
    }

    /// Removes every row one import added (on an Edge, the delete goes to
    /// the Core through the outbox like any other).
    func removeImport(batchID: String) async {
        guard let store = hub?.current.history as? HistoryDatasetStore else { return }
        do {
            let ids = try await store.ids(forImportBatch: batchID)
            for start in stride(from: 0, to: ids.count, by: 2_000) {
                try await store.delete(ids: Array(ids[start..<min(start + 2_000, ids.count)]))
            }
            if importSession.batchID == batchID { importSession = ImportSession() }
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    struct PastImport: Identifiable {
        var id: String
        var name: String
        var date: Date?
        var count: Int
    }

    var pastImports: [PastImport] {
        var batches: [String: (count: Int, first: DatasetRow)] = [:]
        for row in rows where row.isImported {
            if let batch = row.importBatchId {
                batches[batch, default: (0, row)].count += 1
            }
        }
        return batches.map { id, value -> PastImport in
            let parts = Self.parseBatchID(id)
            return PastImport(id: id, name: parts.kind.map { ImportSourceInfo.info(for: $0).name } ?? "Import", date: parts.date, count: value.count)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func makeBatchID(_ kind: ImportSourceKind, date: Date = Date()) -> String {
        "\(kind.rawValue)|\(Int(date.timeIntervalSince1970))|\(UUID().uuidString.prefix(8).lowercased())"
    }

    static func parseBatchID(_ id: String) -> (kind: ImportSourceKind?, date: Date?) {
        let parts = id.split(separator: "|")
        let kind = parts.first.flatMap { ImportSourceKind(rawValue: String($0)) }
        let date = parts.count > 1 ? TimeInterval(parts[1]).map(Date.init(timeIntervalSince1970:)) : nil
        return (kind, date)
    }

    /// A stable row id from the source's own message id: importing the same
    /// file twice can never create the same row twice.
    static func importID(_ sourceKey: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("dictator-import:\(sourceKey)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func dto(for prompt: ImportedPrompt, kind: ImportSourceKind, batchID: String) -> DictationEntryDTO {
        DictationEntryDTO(
            id: importID(prompt.sourceKey),
            timestamp: prompt.timestamp ?? Date(timeIntervalSince1970: 0),
            text: prompt.text,
            durationSeconds: prompt.durationSeconds ?? 0,
            inferenceMs: nil,
            wordCount: prompt.text.split(separator: " ").count,
            modality: prompt.modality.rawValue,
            source: "import:\(kind.rawValue)",
            destinationAppBundleId: prompt.appBundleId,
            destinationAppName: prompt.appName,
            destinationURL: prompt.url,
            insertionMethod: "import",
            originEdgeId: nil,
            syncedAt: nil,
            truncated: nil,
            toolId: prompt.toolId,
            captureSource: "import",
            workingDirectory: prompt.workingDirectory,
            sessionId: prompt.sessionId,
            importBatchId: batchID
        )
    }
}
