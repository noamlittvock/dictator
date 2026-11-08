import AppKit
import SwiftUI

/// Models offered in Add an AI model (`shared/model-catalog.json`). Any
/// other Ollama model can be typed in by name.
struct ModelCatalogEntry: Codable, Identifiable, Equatable {
    var model: String
    var name: String
    var summary: String
    var minMemoryGB: Int
    var recommendedFromGB: Int?
    var aliases: [String]?
    var id: String { model }
}

enum ModelCatalog {
    private struct File: Codable { var version: Int; var cleanup: [ModelCatalogEntry]; var speech: [ModelCatalogEntry]? }

    private static let file: File? = {
        guard let url = Bundle.main.url(forResource: "model-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()

    static let cleanup: [ModelCatalogEntry] = file?.cleanup ?? []
    static let speech: [ModelCatalogEntry] = file?.speech ?? []

    static func entries(for job: ModelJob) -> [ModelCatalogEntry] {
        job == .speech ? speech : cleanup
    }

    /// A listed model suggested by memory thresholds, without a quality comparison.
    static func recommended(for job: ModelJob = .cleanup, memoryGB memory: Int) -> ModelCatalogEntry? {
        entries(for: job)
            .filter { ($0.recommendedFromGB ?? .max) <= memory }
            .max { ($0.recommendedFromGB ?? 0) < ($1.recommendedFromGB ?? 0) }
    }

    static func name(of model: String) -> String {
        if let entry = (cleanup + speech).first(where: { $0.model == model || ($0.aliases?.contains(model) ?? false) }) { return entry.name }
        if LocalSpeechService.engine(of: model) == .apple {
            let identifier = LocalSpeechService.name(of: model)
            return "Apple · " + (Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
        }
        return LocalSpeechService.engine(of: model) == nil ? model : LocalSpeechService.name(of: model)
    }
}

/// Retained by the download task/callback even after its sheet is dismissed.
@MainActor
@Observable
final class ModelSetupActivation {
    private(set) var completed = false
    private(set) var activated = false
    private var source: SetupRouting.SpeechSource?
    private var cleanupBefore: SetupRouting?
    private var cleanupMachine: EdgeID?
    private var cleanupModel: String?

    func complete(job: ModelJob, machine: EdgeID, model: String, settings: AppSettings, snapshot: SetupSnapshot?) {
        guard !completed else { return }
        completed = true
        guard ModelSetupPolicy.shouldActivate(job: job, speechSources: settings.speechSources,
                                             routing: settings.setupRouting, snapshot: snapshot) else { return }
        switch job {
        case .speech:
            let source = SetupRouting.SpeechSource.mac(machine, model: model)
            self.source = source
            settings.updateSpeechSources { $0.insert(source, at: 0) }
        case .cleanup:
            cleanupBefore = settings.setupRouting
            cleanupMachine = machine
            cleanupModel = model
            settings.updateSetupRouting {
                $0.cleanupMachineId = machine
                $0.cleanupModel = model
            }
        }
        activated = true
    }

    /// Only undo this sheet's choice; preserve any later choice made elsewhere.
    func undo(settings: AppSettings) {
        guard activated else { return }
        if let source {
            settings.updateSpeechSources { $0.removeAll { $0 == source } }
        } else if let before = cleanupBefore,
                  settings.setupRouting.cleanupMachineId == cleanupMachine,
                  settings.setupRouting.cleanupModel == cleanupModel {
            settings.updateSetupRouting {
                $0.cleanupMachineId = before.cleanupMachineId
                $0.cleanupModel = before.cleanupModel
            }
        }
        activated = false
    }
}

/// Settings › Your Macs › a Mac › Add an AI model.
struct AddModelSheet: View {
    enum Step { case job, model, download, tryIt }
    enum Use { case every, backup, notYet }

    let machine: SetupSnapshot.Machine

    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared
    @State private var inventory = LocalModelInventory.shared
    @State private var speechService = LocalSpeechService.shared
    @State private var step: Step = .job
    @State private var job: ModelJob = .cleanup
    @State private var chosen: String?
    @State private var customModel = ""
    @State private var appleLanguage = ""
    @State private var appleLanguages: [String] = []
    @State private var progress: ModelPullProgress?
    @State private var downloadError: String?
    @State private var trial: (text: String, seconds: Double)?
    @State private var trialError: String?
    @State private var trying = false
    @State private var use: Use = .every
    @State private var activation = ModelSetupActivation()
    @State private var activatesOnCompletion = false

    init(machine: SetupSnapshot.Machine, initialJob: ModelJob? = nil) {
        self.machine = machine
        if let initialJob {
            _job = State(initialValue: initialJob)
            _step = State(initialValue: .model)
            _chosen = State(initialValue: ModelCatalog.recommended(for: initialJob, memoryGB: machine.profile?.memoryGB ?? 0)?.model)
        }
    }

    private static let cleanupSample = "um so I think we should uh move the the review to thursday if that works for everyone"
    private static let appleChoice = "apple"

    private var isThisMac: Bool { machine.id == viewModel.localEdgeId }
    private var canReach: Bool { isThisMac || settings.coreRole != .edge }
    /// "this Mac", or the other Mac's name when the sheet adds a model there.
    private var targetMacPhrase: String { isThisMac ? "this Mac" : machine.name }
    private var memory: Int { machine.profile?.memoryGB ?? 0 }
    private var appleAvailable: Bool { isThisMac ? LocalSpeechService.appleAvailable : (machine.appleSpeech == true) }

    /// Ollama models on the Mac (nil while Ollama isn't running there).
    private var ollamaModels: [String]? {
        isThisMac ? (inventory.ollamaRunning ? inventory.models : nil) : machine.localModels
    }

    private var speechModels: [String] {
        isThisMac ? speechService.installed : (machine.speechModels ?? [])
    }

    private var installed: [String] { job == .speech ? speechModels : (ollamaModels ?? []) }

    /// The model id being added.
    private var modelId: String {
        if chosen == Self.appleChoice { return "apple:" + appleLanguage }
        let typed = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen ?? typed
    }

    var body: some View {
        DSSheet(title: "Add an AI model to \(machine.name)",
                subtitle: memory > 0 ? "\(memory) GB memory" : "Memory unknown") {
            if !canReach {
                unreachable
            } else {
                switch step {
                case .job: jobStep
                case .model: modelStep
                case .download: downloadStep
                case .tryIt: tryStep
                }
            }
        } leadingActions: {
            if step == .model {
                Button("Back") { step = .job }
                    .buttonStyle(.dsQuiet)
            }
        } actions: {
            Button(step == .job || step == .model ? "Cancel" : "Close") { dismiss() }
            footer
        }
        .task(id: job) { if isThisMac && job == .cleanup { await inventory.refresh() } }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        Group {
            switch step {
            case .job:
                EmptyView()
            case .model:
                Button(installed.contains(modelId) ? "Continue" : "Download") { startDownload() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canDownload)
            case .download:
                Button("Continue") { step = .tryIt; runTrial() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(progress?.done != true || !activation.completed || downloadError != nil)
            case .tryIt:
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trying)
            }
        }
        .buttonStyle(.dsPrimary)
    }

    private var unreachable: some View {
        let main = viewModel.setupSnapshot?.mainMacName ?? "your main Mac"
        return DSEmptyState(title: "Add it from \(machine.name) or \(main)",
                            detail: "This Mac can’t install models on another Mac. Open Dictator on \(machine.name), or on \(main), and choose Add an AI model on this card there.")
    }

    // MARK: Step 1: job

    private var jobStep: some View {
        VStack(alignment: .leading, spacing: DSSpace.m) {
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                Text("What should it do?").font(.dsSection)
                Text("Each AI model runs on \(targetMacPhrase) and does one job.")
                    .font(.dsBody).foregroundStyle(Color.dsTextSecondary)
            }
            HStack(alignment: .top, spacing: DSSpace.s) {
                JobTile(job: .speech, title: "Turn speech into text", detail: "Listens to your recording and writes down the words.", note: nil, enabled: true) {
                    pick(.speech)
                }
                JobTile(job: .cleanup, title: "Clean up the text", detail: "Removes “um”s, fixes punctuation and capital letters.", note: nil, enabled: true) {
                    pick(.cleanup)
                }
            }
        }
    }

    private func pick(_ newJob: ModelJob) {
        job = newJob
        chosen = ModelCatalog.recommended(for: newJob, memoryGB: memory)?.model
        customModel = ""
        step = .model
    }

    // MARK: Step 2: model

    private var canDownload: Bool {
        if chosen == Self.appleChoice { return appleAvailable && !appleLanguage.isEmpty }
        if job == .cleanup && ollamaModels == nil { return false }
        return OllamaClient.isValidModelName(modelId) && fits(modelId)
    }

    private func fits(_ model: String) -> Bool {
        guard memory > 0, let entry = ModelCatalog.entries(for: job).first(where: { $0.model == model }) else { return true }
        return memory >= entry.minMemoryGB
    }

    @ViewBuilder
    private var modelStep: some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                Text("Choose a model").font(.dsSection)
                Text("Suggestions fit \(targetMacPhrase)’s memory. Try one with your usual speech.")
                    .font(.dsBody).foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if job == .cleanup, ollamaModels == nil { ollamaMissing }
            ScrollView {
                VStack(spacing: 0) {
                    let recommended = ModelCatalog.recommended(for: job, memoryGB: memory)?.model
                    ForEach(Array(ModelCatalog.entries(for: job).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { SettingsDivider() }
                        let ok = memory == 0 || memory >= entry.minMemoryGB
                        let already = installed.contains(entry.model)
                        SettingsChoiceRow(
                            title: entry.name + (entry.model == recommended ? " · suggested for its memory" : "") + (already ? " · already installed" : ""),
                            detail: ok ? entry.summary : "Needs more memory than \(machine.name) has.",
                            selected: chosen == entry.model,
                            enabled: ok
                        ) {
                            chosen = entry.model
                            customModel = ""
                        }
                    }
                    SettingsDivider()
                    if job == .speech {
                        appleRow
                    } else {
                        HStack(spacing: DSSpace.s) {
                            Text("Another Ollama model").font(.dsBodyMedium)
                            TextField("name, e.g. mistral:7b", text: $customModel)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: customModel) { _, value in if !value.isEmpty { chosen = nil } }
                        }
                        .padding(.horizontal, DSSpace.m)
                        .padding(.vertical, DSSpace.s)
                    }
                }
                .dsCardSurface()
            }
            .frame(maxHeight: 300)
        }
        .task { await loadAppleLanguages() }
    }

    @ViewBuilder
    private var appleRow: some View {
        SettingsChoiceRow(
            title: "Apple speech recognition",
            detail: appleAvailable
                ? "Uses macOS speech recognition in one language."
                : "Needs macOS 26 or later on \(machine.name).",
            selected: chosen == Self.appleChoice,
            enabled: appleAvailable
        ) {
            chosen = Self.appleChoice
            customModel = ""
        }
        if chosen == Self.appleChoice {
            HStack(spacing: DSSpace.s) {
                Text("Language").font(.dsBodyMedium)
                Picker("Language", selection: $appleLanguage) {
                    ForEach(appleLanguages, id: \.self) { identifier in
                        Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, DSSpace.xxl)
            .padding(.bottom, DSSpace.s)
        }
    }

    /// Apple's languages on this Mac, the user's own first.
    private func loadAppleLanguages() async {
        guard job == .speech, appleLanguages.isEmpty, #available(macOS 26, *) else { return }
        let all = await AppleSpeech.supportedLanguages()
        let mine = settings.dictationLanguages
        let preferred = all.filter { id in mine.contains { id.hasPrefix($0 + "-") || id == $0 } }
        let rest = all.filter { !preferred.contains($0) }
            .sorted { (Locale.current.localizedString(forIdentifier: $0) ?? $0) < (Locale.current.localizedString(forIdentifier: $1) ?? $1) }
        appleLanguages = preferred + rest
        if appleLanguage.isEmpty { appleLanguage = preferred.first ?? rest.first ?? "" }
    }

    private var ollamaMissing: some View {
        SettingsNotice(tone: .warning, text: Text(isThisMac
            ? "Clean-up models need Ollama first: a free app that runs AI models. Download it, open it, and this updates by itself."
            : "\(machine.name) needs Ollama first: a free app that runs AI models. On \(machine.name), download it from ollama.com and open it.")) {
            if isThisMac {
                Button("Download Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!) }
            }
        }
        .task(id: step) {
            while isThisMac, ollamaModels == nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await inventory.refresh()
            }
        }
    }

    // MARK: Step 3: download

    private var displayName: String { ModelCatalog.name(of: modelId) }

    private var downloadStep: some View {
        VStack(alignment: .leading, spacing: DSSpace.m) {
            Text(progress?.done == true && downloadError == nil ? "\(displayName) is on \(machine.name)" : "Getting \(displayName) for \(machine.name)")
                .font(.dsSection)
            if let downloadError {
                SettingsNotice(tone: .warning, text: Text(downloadError))
                Button("Try Again") { startDownload() }
            } else {
                ProgressView(value: progress?.fraction ?? (progress?.done == true ? 1 : 0))
                HStack(spacing: DSSpace.xs) {
                    Text(progressText).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                    Spacer()
                }
                Text(progress?.done == true ? "Ready to try."
                     : activatesOnCompletion ? "You can close this window. It starts working when it’s ready; keep Dictator open."
                     : "You can close this window and choose it later on its card; keep Dictator open.")
                    .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressText: String {
        guard let progress else { return "Starting…" }
        if progress.done { return "Done" }
        if progress.status == "installing", let fraction = progress.fraction { return "\(Int(fraction * 100))%" }
        if let completed = progress.completed, let total = progress.total, total > 1000 {
            let formatter = ByteCountFormatter()
            return "\(formatter.string(fromByteCount: completed)) of \(formatter.string(fromByteCount: total))"
        }
        if let fraction = progress.fraction { return "\(Int(fraction * 100))%" }
        return progress.status.capitalized
    }

    private func startDownload() {
        let model = modelId
        let job = self.job
        let machineID = machine.id
        // Capture the reference and settings directly. Completion must not
        // depend on SwiftUI retaining the dismissed sheet's State storage.
        let activation = self.activation
        let settings = self.settings
        let viewModel = self.viewModel
        let complete = {
            activation.complete(job: job, machine: machineID, model: model,
                                settings: settings, snapshot: viewModel.setupSnapshot)
        }
        activatesOnCompletion = ModelSetupPolicy.shouldActivate(
            job: job, speechSources: settings.speechSources, routing: settings.setupRouting, snapshot: viewModel.setupSnapshot
        )
        downloadError = nil
        progress = nil
        step = .download
        if installed.contains(model) {
            complete()
            progress = ModelPullProgress(status: "success", done: true)
            return
        }
        if isThisMac {
            Task {
                do {
                    let stream = job == .speech ? speechService.install(model) : OllamaClient.pull(model)
                    var downloaded = false
                    for try await update in stream {
                        if let error = update.error {
                            downloadError = "It stopped: \(error)"
                            return
                        }
                        downloaded = downloaded || update.done
                        progress = update
                    }
                    guard downloaded else {
                        downloadError = "The download stopped before the model was ready. Try again."
                        return
                    }
                    complete()
                    await inventory.refresh()
                    progress = ModelPullProgress(status: "success", done: true)
                } catch {
                    downloadError = "It stopped: \(error.localizedDescription)"
                }
            }
        } else {
            do {
                try viewModel.pullModel(on: machineID, model: model) { update in
                    if let error = update.error {
                        downloadError = "It stopped: \(error)"
                    } else {
                        if update.done { complete() }
                        progress = update
                    }
                }
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    // MARK: Step 4: try it

    private var tryStep: some View {
        VStack(alignment: .leading, spacing: DSSpace.m) {
            Text("Here’s how it did").font(.dsSection)
            HStack(alignment: .top, spacing: DSSpace.s) {
                if job == .speech {
                    sampleBox(label: "The sample recording says", text: DictatorViewModel.speechSample?.text ?? "", dim: true)
                } else {
                    sampleBox(label: "What was said", text: Self.cleanupSample, dim: true)
                }
                let label = job == .speech ? "It heard" : "After clean-up"
                if trying {
                    sampleBox(label: label, text: job == .speech ? "Listening… The first time can take a minute while the model loads." : "Cleaning up…", dim: true)
                } else if let trial {
                    sampleBox(label: String(format: "%@ · %.1f s", label, trial.seconds), text: trial.text, dim: false)
                } else {
                    sampleBox(label: label, text: "", dim: true)
                }
            }
            if let trialError {
                HStack(spacing: DSSpace.xs) {
                    Text(trialError).font(.dsSecondary).foregroundStyle(Color.dsWarning)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { runTrial() }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("When should Dictator use it?").font(.dsSection).padding(.bottom, DSSpace.xs)
                VStack(spacing: 0) {
                    SettingsChoiceRow(title: "For every dictation", detail: currentDescription.map { "Instead of \($0)." } ?? "Starting now.", selected: use == .every) { use = .every }
                    if job == .speech {
                        SettingsDivider()
                        SettingsChoiceRow(title: "As a backup", detail: currentDescription.map { "Only when \($0) can’t be used." } ?? "Only when your usual one can’t be used.", selected: use == .backup) { use = .backup }
                    }
                    SettingsDivider()
                    SettingsChoiceRow(title: "Not yet", detail: "It stays on \(machine.name). Choose it later on its card.", selected: use == .notYet) { use = .notYet }
                }
                .dsCardSurface()
            }
        }
    }

    /// What does this job now, in words ("Whisper Small on Mac mini").
    private var currentDescription: String? {
        guard let snapshot = viewModel.setupSnapshot else { return nil }
        if job == .speech {
            // This model may already be active: it can't replace itself.
            guard let first = settings.speechSources.first(where: { $0 != .mac(machine.id, model: modelId) }) else { return nil }
            if let model = first.model { return "\(ModelCatalog.name(of: model)) on \(snapshot.machineName(first.machineId) ?? "another Mac")" }
            return snapshot.speech.map { "the speech server on \(snapshot.machineName($0.machineId) ?? "another computer")" }
        }
        guard let speech = snapshot.speech, let model = speech.cleanupModel else { return nil }
        return "\(model) on \(snapshot.machineName(speech.cleanupMachineId ?? speech.machineId) ?? "the speech server")"
    }

    private func sampleBox(label: String, text: String, dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.hair) {
            Text(label).font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
            Text(text)
                .font(.dsBody)
                .foregroundStyle(dim ? Color.dsTextSecondary : Color.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpace.m)
        .dsCardSurface()
    }

    private func runTrial() {
        trying = true
        trialError = nil
        trial = nil
        let model = modelId
        Task {
            do {
                trial = job == .speech
                    ? try await viewModel.trySpeech(machine: machine.id, model: model)
                    : try await viewModel.tryCleanup(sample: Self.cleanupSample, machine: machine.id, model: model)
            } catch {
                trialError = "Couldn’t try it: \(error.localizedDescription)"
            }
            trying = false
        }
    }

    private func finish() {
        let model = modelId
        let id = machine.id
        switch (job, use) {
        case (_, .notYet):
            activation.undo(settings: settings)
        case (.speech, .every):
            settings.updateSpeechSources { $0.insert(.mac(id, model: model), at: 0) }
        case (.speech, .backup):
            settings.updateSpeechSources {
                let source = SetupRouting.SpeechSource.mac(id, model: model)
                $0.removeAll { $0 == source }
                $0.append(source)
            }
        case (.cleanup, _):
            settings.updateSetupRouting { routing in
                routing.cleanupMachineId = id
                routing.cleanupModel = model
            }
            if settings.refineLevel == .exact { settings.refineLevel = .medium }
        }
        dismiss()
    }
}

private struct JobTile: View {
    let job: ModelJob
    let title: String
    let detail: String
    let note: String?
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Image(systemName: job.symbol).font(.dsIconLarge).foregroundStyle(job.color)
                Text(title).font(.dsSection).foregroundStyle(Color.dsTextPrimary)
                Text(detail).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpace.m)
            .dsCardSurface(Color.dsSurfaceCard, border: Color.dsBorder)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }
}
