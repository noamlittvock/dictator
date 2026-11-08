import SwiftUI

/// Settings › Your Macs: every Mac in the setup, the AI models on each,
/// and which Mac does each step of a dictation.
struct YourMacsSettingsPage: View {
    enum Step: String, CaseIterable, Identifiable {
        case record, speech, cleanup, save
        var id: String { rawValue }
    }

    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared
    @State private var selected: Step?
    @State private var showAddMac = false
    @State private var showJoin = false
    @State private var addModelFor: SetupSnapshot.Machine?

    var body: some View {
        SettingsPage(title: "Your Macs", summary: BrandVoice.yourMacsSummary, width: .wide) {
            HStack(spacing: DSSpace.s) {
                Button {
                    showAddMac = true
                } label: {
                    Label(BrandVoice.addMac, systemImage: "plus")
                }
                .buttonStyle(.dsPrimary)
                if settings.coreRole == .standalone || viewModel.pairingProblem != nil {
                    Button("Join Another Mac’s Setup…") { showJoin = true }
                        .buttonStyle(.dsLink)
                }
                Spacer()
            }

            if let problem = viewModel.pairingProblem ?? model.problem {
                SettingsNotice(tone: .warning, text: Text(problem))
            }

            machinesGrid

            recordingSection

            startupSection

            flow
        }
        .alert("Couldn’t remove this Mac", isPresented: Binding(
            get: { viewModel.removalError != nil },
            set: { if !$0 { viewModel.removalError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.removalError = nil }
        } message: {
            Text(viewModel.removalError ?? "")
        }
        .sheet(isPresented: $showAddMac) { AddMacSheet() }
        .sheet(isPresented: $showJoin) { JoinSetupSheet() }
        .sheet(item: $addModelFor) { machine in AddModelSheet(machine: machine) }
    }

    private func perform(_ action: YourMacsModel.ChipAction, chip: YourMacsModel.Chip, on machine: SetupSnapshot.Machine) {
        guard let model = chip.rawModel else { return }
        let source = SetupRouting.SpeechSource.mac(machine.id, model: model)
        switch action {
        case .useForCleanup:
            settings.updateSetupRouting { $0.cleanupMachineId = machine.id; $0.cleanupModel = model }
            if settings.refineLevel == .exact { settings.refineLevel = .medium }
        case .stopUsingForCleanup:
            settings.updateSetupRouting { $0.cleanupMachineId = nil; $0.cleanupModel = nil }
        case .useForSpeech, .makeFirstForSpeech:
            settings.updateSpeechSources { sources in
                sources.removeAll { $0 == source }
                sources.insert(source, at: 0)
            }
        case .useAsSpeechBackup:
            settings.updateSpeechSources { $0.append(source) }
        case .stopUsingForSpeech:
            settings.updateSpeechSources { $0.removeAll { $0 == source } }
        }
    }

    private var model: YourMacsModel {
        YourMacsModel(snapshot: viewModel.setupSnapshot, localId: viewModel.localEdgeId, settings: settings,
                      connectedToMainMac: viewModel.isConnectedEdgeRole, localHasMic: viewModel.localHasMic,
                      localSpeechModels: LocalSpeechService.shared.installed,
                      localCleanupModels: LocalModelInventory.shared.ollamaRunning ? LocalModelInventory.shared.models : nil)
    }

    private var recordingSection: some View {
        SettingsGroup(title: "Recording") {
            SettingsLabeledControl("Mac that records", help: YourMacsModel.recordingHelp) {
                Picker("Mac that records", selection: $settings.micOwnerEdgeID) {
                    Text("Automatic").tag("")
                    ForEach(model.recordingMachines) { machine in
                        Text(machine.online ? machine.name : "\(machine.name) (Offline)").tag(machine.id)
                    }
                    if !settings.micOwnerEdgeID.isEmpty,
                       !model.recordingMachines.contains(where: { $0.id == settings.micOwnerEdgeID }) {
                        Text("Chosen Mac (unavailable)").tag(settings.micOwnerEdgeID)
                            .disabled(true)
                    }
                }
            }
        }
    }

    // MARK: Macs

    private var machinesGrid: some View {
        let model = model
        let involved = model.involved(in: selected)
        return LazyVGrid(columns: model.machines.count == 1
                         ? [GridItem(.flexible(), alignment: .top)]
                         : [GridItem(.adaptive(minimum: 220), spacing: DSSpace.m, alignment: .top)],
                         alignment: .center, spacing: DSSpace.l) {
            ForEach(model.machines) { machine in
                MacCard(
                    machine: machine,
                    isThisMac: machine.id == model.localId,
                    models: model.models(on: machine),
                    highlighted: selected == nil || involved.contains(machine.id),
                    canForget: settings.coreRole != .edge && !machine.isCore && machine.id != model.localId,
                    removalConfirmation: SetupDirectory.removalConfirmation(
                        machine: machine, snapshot: viewModel.setupSnapshot,
                        speechAddresses: [settings.serverURL] + settings.backupServerURLs + settings.speechSources.compactMap(\.serverURL)),
                    keepsMainHistory: machine.isCore && model.machines.count > 1,
                    onAddModel: { addModelFor = machine },
                    onChipAction: { chip, action in perform(action, chip: chip, on: machine) },
                    onForget: { viewModel.forgetMachine(machine.id) }
                )
                .frame(maxWidth: model.machines.count == 1 ? 360 : .infinity)
                .anchorPreference(key: MacAnchorKey.self, value: .bounds) { [machine.id: $0] }
            }
        }
        .padding(.top, model.routes(for: selected).isEmpty ? DSSpace.m : DSSpace.xxl)
        .padding(.horizontal, DSSpace.m)
        .padding(.bottom, DSSpace.m)
        .overlayPreferenceValue(MacAnchorKey.self) { anchors in
            GeometryReader { proxy in
                ForEach(model.routes(for: selected)) { route in
                    // Arcs fit above a row. Across rows they cut through other Macs;
                    // the step cards below still explain those connections.
                    if let from = anchors[route.from], let to = anchors[route.to],
                       abs(proxy[from].minY - proxy[to].minY) < 1 {
                        RouteArc(from: proxy[from], to: proxy[to], lift: route.lift, color: route.color, waiting: route.waiting)
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .dsCardSurface()
    }

    private var startupSection: some View {
        SettingsSectionCard(title: "After login", footer: "Each Mac controls its own startup in Dictator › Settings › General. Keep your Macs awake and Tailscale on so they can reach each other. Offline Macs show no current status.") {
            ForEach(model.machines) { machine in
                let local = machine.id == viewModel.localEdgeId
                let report = local ? StartupController.currentReport : machine.startup
                let online = local || machine.online
                SettingsRow(title: machine.name + (local ? " · this Mac" : ""),
                            detail: StartupReport.detail(report: report, online: online, isMain: machine.isCore && model.machines.count > 1)) {
                    VStack(alignment: .trailing, spacing: DSSpace.xxs) {
                        Text(online ? (report?.summary ?? "Not reported") : "Offline")
                            .font(.dsSecondary)
                            .foregroundStyle(online && report?.login == .enabled ? Color.dsSuccess : Color.dsWarning)
                        if local {
                            Button("Configure startup") { AppNavigation.shared.settingsSection = .general }
                                .buttonStyle(.dsLink)
                        }
                    }
                }
                if machine.id != model.machines.last?.id { SettingsDivider() }
            }
            SettingsDivider()
            SettingsRow(title: "While disconnected", detail: "Recording here still needs a microphone and permissions; shared History waits for reconnection.") {
                EmptyView()
            }
        }
    }

    // MARK: Steps

    private var flow: some View {
        let model = model
        return VStack(alignment: .leading, spacing: DSSpace.s) {
            HStack(spacing: DSSpace.xs) {
                Text("What happens when you dictate")
                    .font(.dsSection)
                Spacer()
                if selected != nil {
                    Button("Show all steps") { selected = nil }
                        .buttonStyle(.dsLink)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: DSSpace.s, alignment: .top)], alignment: .leading, spacing: DSSpace.s) {
                ForEach(Step.allCases) { step in
                    StepCard(step: step, place: model.place(for: step), selected: selected == step) {
                        selected = selected == step ? nil : step
                    }
                }
            }
            Text(model.caption(for: selected))
                .font(.dsBody)
                .foregroundStyle(model.captionIsWarning(for: selected) ? Color.dsWarning : Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Model

/// Everything the page shows, worked out from the setup snapshot and the
/// chosen speech sources.
@MainActor
struct YourMacsModel {
    struct Chip: Identifiable {
        let id: String
        let job: ModelJob?
        let model: String
        /// The model's full id (Ollama tag or speech model id), for actions.
        var rawModel: String? = nil
        /// What the chip's menu offers.
        var actions: [ChipAction] = []
        var tag: String?
        var tagIsWarning = false
        var backup = false
        var active = true
        var statusIsUnverified = false
    }

    enum ChipAction: Hashable {
        case useForCleanup, stopUsingForCleanup
        case useForSpeech, useAsSpeechBackup, makeFirstForSpeech, stopUsingForSpeech

        var title: String {
            switch self {
            case .useForCleanup: "Use It to Clean Up Text"
            case .stopUsingForCleanup: "Go Back to the Speech Server’s Clean-up"
            case .useForSpeech: "Use It for Every Dictation"
            case .useAsSpeechBackup: "Use It as a Backup"
            case .makeFirstForSpeech: "Use It First"
            case .stopUsingForSpeech: "Stop Using It"
            }
        }
    }

    /// One place speech can be turned into text, resolved against the
    /// snapshot.
    struct Source {
        let source: SetupRouting.SpeechSource
        let machineId: EdgeID?
        let modelName: String
        let available: Bool
        let isServer: Bool
        var statusIsUnverified = false
    }

    struct Route: Identifiable {
        let id: String
        let from: EdgeID
        let to: EdgeID
        let color: Color
        var lift: CGFloat = 46
        var waiting = false
    }

    struct Place {
        let text: String
        let warning: Bool
    }

    let snapshot: SetupSnapshot?
    let localId: EdgeID
    let settings: AppSettings
    let speechSources: [SetupRouting.SpeechSource]
    let connectedToMainMac: Bool
    let localHasMic: Bool?
    let localSpeechModels: [String]
    let localCleanupModels: [String]?

    var isDisconnectedEdge: Bool { settings.coreRole == .edge && !connectedToMainMac }

    init(snapshot: SetupSnapshot?, localId: EdgeID, settings: AppSettings, speechSources: [SetupRouting.SpeechSource]? = nil,
         connectedToMainMac: Bool = false, localHasMic: Bool? = nil, localSpeechModels: [String] = [], localCleanupModels: [String]? = nil) {
        self.snapshot = snapshot
        self.localId = localId
        self.settings = settings
        self.connectedToMainMac = connectedToMainMac
        self.localHasMic = localHasMic
        self.localSpeechModels = localSpeechModels
        self.localCleanupModels = localCleanupModels
        if let speechSources {
            self.speechSources = speechSources
        } else if let chosen = settings.setupRouting.speechSources, !chosen.isEmpty {
            self.speechSources = chosen
        } else if let snapshot, let speech = snapshot.speech {
            // Not chosen yet: the main Mac's speech server, then its backups
            // (a connected Mac's own server address isn't the one in use).
            self.speechSources = ([speech] + snapshot.backups).map { .server($0.address) }
        } else {
            self.speechSources = settings.speechSources
        }
    }

    var machines: [SetupSnapshot.Machine] {
        if let snapshot, !snapshot.machines.isEmpty {
            guard isDisconnectedEdge else {
                return snapshot.machines.map { cached in
                    var machine = cached
                    if machine.id == localId, let localHasMic { machine.hasMic = localHasMic }
                    return machine
                }
            }
            // Cached inventory stays useful; its online bits are not current
            // evidence after losing the main Mac's transport.
            return snapshot.machines.map { cached in
                var machine = cached
                machine.online = machine.id == localId
                if machine.id == localId {
                    if let localHasMic { machine.hasMic = localHasMic }
                    machine.speechModels = localSpeechModels
                    machine.localModels = localCleanupModels
                }
                return machine
            }
        }
        return [SetupSnapshot.Machine(
            id: localId, name: Host.current().localizedName ?? "This Mac", profile: MachineProfile.current,
            hasMic: localHasMic ?? false, online: true, lastSeen: Date(), isCore: true,
            localModels: LocalModelInventory.shared.ollamaRunning ? LocalModelInventory.shared.models : nil,
            speechModels: LocalSpeechService.shared.installed, appleSpeech: LocalSpeechService.appleAvailable
        )]
    }

    static let recordingHelp = "Automatic records on the Mac you press the key on. If it has no microphone, Dictator asks first instead of using another Mac."

    var recordingMachines: [SetupSnapshot.Machine] {
        machines.filter(\.hasMic).sorted { $0.id < $1.id }
    }

    private var preferredRecorder: SetupSnapshot.Machine? {
        recordingMachines.first { $0.id == settings.micOwnerEdgeID && $0.online }
    }

    private var cleanupOn: Bool { settings.refineLevel != .exact }

    // MARK: Speech

    var sources: [Source] {
        let services = [snapshot?.speech].compactMap { $0 } + (snapshot?.backups ?? [])
        return speechSources.map { source in
            if let url = source.serverURL {
                let service = services.first { $0.address == url }
                return Source(source: source, machineId: service?.machineId,
                              modelName: service?.speechModel.map(Self.shortName) ?? "Speech server",
                              available: !isDisconnectedEdge && (service?.reachable ?? false), isServer: true,
                              statusIsUnverified: isDisconnectedEdge)
            }
            let machine = machines.first { $0.id == source.machineId }
            let model = source.model ?? ""
            return Source(source: source, machineId: source.machineId, modelName: ModelCatalog.name(of: model),
                          available: machine?.online == true && (machine?.speechModels?.contains(model) ?? false), isServer: false)
        }
    }

    /// The source dictation uses right now: the first one available.
    var activeSource: Source? {
        let all = sources
        return all.first(where: \.available) ?? all.first
    }

    var activeSpeechMachine: EdgeID? { activeSource?.machineId }

    // MARK: Cleanup

    var cleanupMachine: EdgeID? {
        guard cleanupOn else { return nil }
        if let chosen = settings.setupRouting.cleanupMachineId { return chosen }
        guard let speech = snapshot?.speech else { return nil }
        return speech.cleanupMachineId ?? speech.machineId
    }

    private var cleanupModel: String? {
        if settings.setupRouting.cleanupMachineId != nil { return settings.setupRouting.cleanupModel }
        return snapshot?.speech?.cleanupModel
    }

    /// Clean-up happens on this dictation.
    var cleanupRuns: Bool {
        guard let machine = cleanupMachine, isOnline(machine) else { return false }
        if isDisconnectedEdge, machine == localId {
            guard let cleanupModel, localCleanupModels?.contains(cleanupModel) == true else { return false }
        }
        if settings.setupRouting.cleanupMachineId == nil, activeSource?.isServer == true {
            return activeSource?.available == true
        }
        return true
    }

    var mainMac: SetupSnapshot.Machine? { machines.first(where: \.isCore) }

    func name(_ id: EdgeID?) -> String {
        machines.first { $0.id == id }?.name ?? "another computer"
    }

    private func isOnline(_ id: EdgeID?) -> Bool {
        machines.first { $0.id == id }?.online ?? false
    }

    // MARK: Chips

    func models(on machine: SetupSnapshot.Machine) -> [Chip] {
        var chips: [Chip] = []
        let all = sources
        let active = activeSource
        var usedSpeech = Set<String>()
        for (index, source) in all.enumerated() where source.machineId == machine.id {
            let isActive = active?.source == source.source
            var tag: String?
            var warning = false
            if !source.available {
                tag = source.statusIsUnverified ? "not checked" : (machine.online ? "not answering" : "off")
                warning = true
            } else if index > 0 && isActive {
                tag = "standing in"
                warning = true
            } else if index > 0 {
                tag = "backup"
            }
            var actions: [ChipAction] = []
            if !source.isServer {
                if index > 0 { actions.append(.makeFirstForSpeech) }
                actions.append(.stopUsingForSpeech)
            }
            if let model = source.source.model { usedSpeech.insert(model) }
            chips.append(Chip(id: "speech-\(index)", job: .speech, model: source.modelName, rawModel: source.source.model,
                              actions: actions, tag: tag, tagIsWarning: warning, backup: index > 0,
                              active: source.available, statusIsUnverified: source.statusIsUnverified))
        }
        for model in machine.speechModels ?? [] where !usedSpeech.contains(model) {
            chips.append(Chip(id: "speech-\(model)", job: .speech, model: ModelCatalog.name(of: model), rawModel: model,
                              actions: machine.online ? [.useForSpeech, .useAsSpeechBackup] : [], tag: "not in use", active: false))
        }
        var usedCleanup = Set<String>()
        if cleanupMachine == machine.id || (!cleanupOn && (snapshot?.speech.map { $0.cleanupMachineId ?? $0.machineId } ?? nil) == machine.id),
           let model = cleanupModel ?? snapshot?.speech?.cleanupModel {
            usedCleanup.insert(model)
            let ready = cleanupOn && cleanupRuns
            let unverified = isDisconnectedEdge && machine.id == localId && localCleanupModels == nil
            chips.append(Chip(id: "cleanup", job: .cleanup, model: Self.shortName(model), rawModel: model,
                              actions: settings.setupRouting.cleanupMachineId == nil ? [] : [.stopUsingForCleanup],
                              tag: !cleanupOn ? "off" : (ready ? nil : (unverified ? "not checked" : "not available")),
                              tagIsWarning: cleanupOn && !ready, active: ready, statusIsUnverified: unverified))
        }
        for model in machine.localModels ?? [] where !usedCleanup.contains(model) {
            chips.append(Chip(id: "local-\(model)", job: nil, model: Self.shortName(model), rawModel: model,
                              actions: machine.online ? [.useForCleanup] : [], tag: "not in use", active: false))
        }
        guard machine.online else {
            return chips.map { chip in
                var chip = chip
                chip.active = false
                chip.tag = chip.statusIsUnverified ? "not checked" : "off"
                chip.tagIsWarning = true
                chip.actions = []
                return chip
            }
        }
        return chips
    }

    /// Friendly names come from the shared catalog; custom tags remain recognizable.
    static func shortName(_ model: String) -> String {
        ModelCatalog.name(of: model)
    }

    // MARK: Steps and lines

    func involved(in step: YourMacsSettingsPage.Step?) -> Set<EdgeID> {
        switch step {
        case nil:
            return Set([localId, activeSpeechMachine, cleanupRuns ? cleanupMachine : nil].compactMap { $0 })
        case .record:
            if let recorder = preferredRecorder { return [recorder.id] }
            return Set(recordingMachines.filter(\.online).map(\.id))
        case .speech:
            return Set(sources.compactMap(\.machineId))
        case .cleanup:
            return Set([cleanupMachine].compactMap { $0 })
        case .save:
            return Set(machines.map(\.id))
        }
    }

    func routes(for step: YourMacsSettingsPage.Step?) -> [Route] {
        let voice = ModelJob.speech.color
        let speechWaiting = activeSource?.available != true
        switch step {
        case nil:
            var routes: [Route] = []
            let clean = cleanupRuns ? cleanupMachine : nil
            if let speechMac = activeSpeechMachine, speechMac != localId {
                routes.append(Route(id: "voice", from: localId, to: speechMac, color: voice, lift: 54, waiting: speechWaiting))
                if let clean, clean != speechMac {
                    routes.append(Route(id: "clean", from: speechMac, to: clean, color: ModelJob.cleanup.color, lift: 30, waiting: speechWaiting))
                    if clean != localId {
                        routes.append(Route(id: "text", from: clean, to: localId, color: Color.dsTextPrimary, lift: 20, waiting: speechWaiting))
                    }
                } else {
                    routes.append(Route(id: "text", from: speechMac, to: localId, color: clean != nil ? ModelJob.cleanup.color : Color.dsTextPrimary, lift: 28, waiting: speechWaiting))
                }
            } else if let clean, clean != localId {
                routes.append(Route(id: "clean", from: localId, to: clean, color: ModelJob.cleanup.color, lift: 40))
                routes.append(Route(id: "back", from: clean, to: localId, color: Color.dsTextPrimary, lift: 22))
            }
            return routes
        case .speech:
            guard let speechMac = activeSpeechMachine, speechMac != localId else { return [] }
            return [Route(id: "voice", from: localId, to: speechMac, color: voice, lift: 54, waiting: speechWaiting)]
        case .cleanup:
            guard let clean = cleanupMachine, let speechMac = activeSpeechMachine, clean != speechMac else { return [] }
            return [Route(id: "clean", from: speechMac, to: clean, color: ModelJob.cleanup.color, lift: 40, waiting: speechWaiting || !cleanupRuns)]
        case .save:
            guard let main = mainMac, machines.count > 1 else { return [] }
            return machines.filter { $0.id != main.id }.map {
                Route(id: "sync-\($0.id)", from: $0.id, to: main.id, color: Color.dsDataPlum,
                      lift: 34, waiting: !main.online || !$0.online)
            }
        case .record:
            return []
        }
    }

    func place(for step: YourMacsSettingsPage.Step) -> Place {
        switch step {
        case .record:
            if let recorder = preferredRecorder { return Place(text: recorder.name, warning: false) }
            return Place(text: "On the Mac you press the key on", warning: !settings.micOwnerEdgeID.isEmpty)
        case .speech:
            let all = sources
            guard let active = activeSource else {
                return Place(text: "Not set up", warning: true)
            }
            if !active.available { return Place(text: active.statusIsUnverified ? "Not checked" : "Can’t be reached", warning: true) }
            let here = active.machineId.map { name($0) } ?? "the speech server"
            if let first = all.first, first.source != active.source { return Place(text: "\(here), for now", warning: true) }
            return Place(text: here, warning: false)
        case .cleanup:
            guard cleanupOn else { return Place(text: "Off: no AI clean-up", warning: false) }
            guard let machine = cleanupMachine else { return Place(text: "No clean-up model yet", warning: true) }
            if !cleanupRuns {
                let local = isDisconnectedEdge && machine == localId
                return Place(text: local ? (localCleanupModels == nil ? "Not checked" : "Not available on this Mac") : "Skipped until \(name(machine)) is back", warning: true)
            }
            return Place(text: name(machine), warning: false)
        case .save:
            guard settings.persistHistory else { return Place(text: "Off: no new history", warning: false) }
            if machines.count <= 1 { return Place(text: "On this Mac", warning: false) }
            if let main = mainMac, !main.online { return Place(text: "Waiting for \(main.name)", warning: true) }
            return Place(text: "Every Mac keeps a copy", warning: false)
        }
    }

    var problem: String? {
        let all = sources
        if isDisconnectedEdge {
            if all.contains(where: \.available) {
                return "Your main Mac isn’t connected. A speech model on this Mac is available; shared history waits for reconnection."
            }
            if all.contains(where: \.statusIsUnverified) {
                return "Your main Mac isn’t connected, so Dictator can’t check the speech server."
            }
            return "Your main Mac isn’t connected. No speech model on this Mac is ready."
        }
        if let first = all.first, !first.available {
            let firstName = first.machineId.map { name($0) } ?? "The speech server"
            if let active = activeSource, active.available {
                let activeName = active.machineId.map { name($0) } ?? "the backup"
                return BrandVoice.backupStandingIn(down: firstName, backup: activeName)
            }
            return "\(firstName) can’t be reached, so dictation won’t work until it’s back."
        }
        if let main = mainMac, !main.online, main.id != localId {
            return "\(main.name) is off or can’t be reached. History saved here is copied over when it’s back."
        }
        return nil
    }

    func caption(for step: YourMacsSettingsPage.Step?) -> String {
        let here = name(localId)
        if isDisconnectedEdge, step == nil || step == .speech {
            return sources.contains(where: \.available)
                ? "A speech model on \(here) is available. Reconnect to check your other Macs."
                : "Reconnect to check your other Macs, or try dictating to check a speech server."
        }
        if step == nil || step == .speech, activeSource?.available != true {
            return "Nothing can turn your voice into text right now. Add a speech model or reconnect one of your Macs."
        }
        switch step {
        case nil:
            if let speechMac = activeSpeechMachine, speechMac != localId {
                if cleanupOn && !cleanupRuns {
                    return "Your voice goes from \(here) to \(name(speechMac)) and comes back as text, without clean-up for now."
                }
                return "Your voice goes from \(here) to \(name(speechMac)) and comes back as \(cleanupOn ? "clean " : "")text. Choose a step to see more."
            }
            return "Choose a step to see which Mac handles it."
        case .record:
            if let recorder = preferredRecorder {
                return "\(recorder.name) records when you press the dictation key on any of your Macs."
            }
            return settings.micOwnerEdgeID.isEmpty ? Self.recordingHelp : "Your chosen Mac is unavailable. " + Self.recordingHelp
        case .speech:
            let all = sources
            guard let first = all.first else { return "Nothing turns your voice into text yet. Add a speech model to one of your Macs." }
            let firstName = first.machineId.map { name($0) } ?? "The speech server"
            let others = all.dropFirst().map { $0.machineId.map { name($0) } ?? "the speech server" }
            if others.isEmpty { return "Speech recognition is set to \(firstName). No backup is selected." }
            return "First choice: \(firstName). Backups are tried in this order: \(others.joined(separator: ", then "))."
        case .cleanup:
            guard cleanupOn else { return "AI clean-up is off. Dictator keeps your words as heard, with your dictionary applied. Change this in Dictation." }
            guard let machine = cleanupMachine else { return "No Mac has a clean-up model yet. Add one to a Mac’s card." }
            return "Clean-up is set to \(name(machine)). If it can’t run, Dictator keeps your words as heard, with your dictionary applied."
        case .save:
            guard settings.persistHistory else {
                return machines.count <= 1
                    ? "New dictations and typed messages aren’t saved. Existing history stays on this Mac."
                    : "New dictations and typed messages aren’t saved. Existing history still syncs when your Macs are connected."
            }
            guard let main = mainMac, machines.count > 1 else { return "Your history is saved on this Mac." }
            return "\(main.name) holds the main copy of your history. Every Mac keeps its own copy and syncs with it."
        }
    }

    func captionIsWarning(for step: YourMacsSettingsPage.Step?) -> Bool {
        guard let step else { return problem != nil }
        return place(for: step).warning
    }
}

// MARK: - Mac card

private struct MacCard: View {
    let machine: SetupSnapshot.Machine
    let isThisMac: Bool
    let models: [YourMacsModel.Chip]
    let highlighted: Bool
    let canForget: Bool
    let removalConfirmation: String
    let keepsMainHistory: Bool
    let onAddModel: () -> Void
    let onChipAction: (YourMacsModel.Chip, YourMacsModel.ChipAction) -> Void
    let onForget: () -> Void
    @State private var confirmingForget = false

    var body: some View {
        VStack(spacing: DSSpace.xs) {
            MacIllustration(kind: machine.profile?.kind ?? .other, stroke: machine.online && highlighted ? .dsTextPrimary : .dsTextTertiary)
                .frame(width: 150, height: 96)
            HStack(spacing: DSSpace.xs) {
                Circle().fill(machine.online ? Color.dsSuccess : Color.dsWarning).frame(width: 8, height: 8)
                Text(machine.name)
                    .font(.dsBodyMedium)
                    .lineLimit(1)
                if canForget {
                    Menu {
                        Button("Remove from Your Macs…", role: .destructive) { confirmingForget = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Color.dsTextTertiary).font(.dsIcon)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Options for \(machine.name)")
                    .help("Options for \(machine.name)")
                    .confirmationDialog(
                        "Remove “\(machine.name)” from Your Macs?",
                        isPresented: $confirmingForget
                    ) {
                        Button("Remove Mac", role: .destructive, action: onForget)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(removalConfirmation)
                    }
                }
            }
            Text(subtitle)
                .font(.dsSecondary)
                .foregroundStyle(machine.online ? Color.dsTextTertiary : Color.dsWarning)
                .multilineTextAlignment(.center)
            if keepsMainHistory {
                Label("Keeps the main copy of your history", systemImage: "cylinder.split.1x2")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextTertiary)
                    .labelStyle(CompactLabelStyle())
            }
            VStack(spacing: DSSpace.xs) {
                ForEach(models) { chip in
                    ModelChip(chip: chip) { onChipAction(chip, $0) }
                }
                if machine.online {
                    Button("+ Add an AI model", action: onAddModel)
                        .buttonStyle(.dsQuiet)
                }
            }
            .padding(.top, DSSpace.xxs)
        }
        .frame(maxWidth: .infinity)
        .opacity(machine.online ? (highlighted ? 1 : 0.45) : 0.6)
        .animation(.easeOut(duration: 0.2), value: highlighted)
    }

    private var subtitle: String {
        if !machine.online {
            return "Off or can’t be reached · last seen \(machine.lastSeen.formatted(.relative(presentation: .named)))"
        }
        var parts: [String] = []
        if isThisMac { parts.append("This Mac") }
        if let memory = machine.profile?.memoryGB, memory > 0 { parts.append("\(memory) GB memory") }
        if !machine.hasMic { parts.append("no microphone") }
        return parts.joined(separator: " · ")
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DSSpace.xxs) {
            configuration.icon.font(.dsIconSmall)
            configuration.title
        }
    }
}

private struct ModelChip: View {
    let chip: YourMacsModel.Chip
    let perform: (YourMacsModel.ChipAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            HStack(spacing: DSSpace.xs) {
                Image(systemName: chip.job?.symbol ?? "shippingbox")
                    .font(.dsIcon)
                    .foregroundStyle(chip.active ? (chip.job?.color ?? Color.dsTextSecondary) : Color.dsTextSecondary)
                Text(chip.job?.title ?? "Clean-up model")
                    .font(.dsBodyMedium)
                    .foregroundStyle(chip.active ? Color.dsTextPrimary : Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !chip.actions.isEmpty {
                    Menu {
                        ForEach(chip.actions, id: \.self) { action in
                            Button(action.title) { perform(action) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Color.dsTextSecondary).font(.dsIcon)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Options for \(chip.model)")
                    .help("Options for \(chip.model)")
                }
            }
            Text(chip.model)
                .font(.dsSecondary)
                .foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tag = chip.tag {
                Text(tag)
                    .font(.dsSecondary)
                    .foregroundStyle(chip.tagIsWarning ? Color.dsWarning : Color.dsTextSecondary)
            }
        }
        .help(chip.rawModel ?? chip.model)
        .padding(.horizontal, DSSpace.m)
        .padding(.vertical, DSSpace.s)
        .dsCardSurface(chip.active ? (chip.job?.color ?? .dsSurfaceCard).opacity(0.10) : .dsSurfaceCard,
                       border: chip.active ? (chip.job?.color ?? .dsBorder).opacity(0.7) : .dsBorderSubtle)
    }
}

// MARK: - Steps

private struct StepCard: View {
    let step: YourMacsSettingsPage.Step
    let place: YourMacsModel.Place
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                HStack(spacing: DSSpace.xs) {
                    DSStepBadge(number: stepNumber)
                    Image(systemName: symbol)
                        .font(.dsIcon)
                        .foregroundStyle(color)
                    Text(title)
                        .font(.dsSection)
                        .foregroundStyle(Color.dsTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: DSSpace.xs) {
                    if place.warning {
                        Circle().fill(Color.dsWarning).frame(width: 6, height: 6)
                    }
                    Text(place.text)
                        .font(.dsBody)
                        .foregroundStyle(place.warning ? Color.dsWarning : Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpace.m)
            .dsCardSurface(selected ? .dsSurfaceRaised : .dsSurfaceCard,
                           border: selected ? color : .dsBorderSubtle)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var stepNumber: Int { (YourMacsSettingsPage.Step.allCases.firstIndex(of: step) ?? 0) + 1 }

    private var title: String {
        switch step {
        case .record: "Record your voice"
        case .speech: "Turn it into text"
        case .cleanup: "Clean up the text"
        case .save: "Save to your history"
        }
    }

    private var symbol: String {
        switch step {
        case .record: "mic"
        case .speech: ModelJob.speech.symbol
        case .cleanup: ModelJob.cleanup.symbol
        case .save: "cylinder.split.1x2"
        }
    }

    private var color: Color {
        switch step {
        case .record: .dsTextPrimary
        case .speech: ModelJob.speech.color
        case .cleanup: ModelJob.cleanup.color
        case .save: Color.dsDataPlum
        }
    }
}

// MARK: - Route lines

private struct MacAnchorKey: PreferenceKey {
    static var defaultValue: [EdgeID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [EdgeID: Anchor<CGRect>], nextValue: () -> [EdgeID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// An animated curve over the Macs, from one card's top to another's.
private struct RouteArc: View {
    let from: CGRect
    let to: CGRect
    let lift: CGFloat
    let color: Color
    let waiting: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        let start = CGPoint(x: from.midX + (to.midX > from.midX ? 10 : -10), y: from.minY - 2)
        let end = CGPoint(x: to.midX + (to.midX > from.midX ? -10 : 10), y: to.minY - 2)
        let top = min(start.y, end.y) - lift
        let path = Path { p in
            p.move(to: start)
            p.addCurve(to: end, control1: CGPoint(x: start.x, y: top), control2: CGPoint(x: end.x, y: top))
        }
        ZStack {
            path.stroke(waiting ? Color.dsTextTertiary : color,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: waiting ? [3, 5] : [6, 5], dashPhase: phase))
            Circle()
                .fill(waiting ? Color.dsTextTertiary : color)
                .frame(width: 7, height: 7)
                .position(end)
        }
        .onAppear {
            guard !waiting else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = -22 }
        }
    }
}
