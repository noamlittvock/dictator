import Foundation
import Observation

/// Core/standalone role: keeps the picture of every Mac in the setup and of
/// the speech server, and hands it to `CoreHost` for every Edge
/// (`CoreMessage.setup`). Macs that disconnect stay listed as offline until
/// the user removes them.
@MainActor
@Observable
final class SetupDirectory {
    private(set) var snapshot: SetupSnapshot?
    @ObservationIgnored var onChange: ((SetupSnapshot) -> Void)?

    @ObservationIgnored private var known: [EdgeID: SetupSnapshot.Machine]
    @ObservationIgnored private var coreEdgeId: EdgeID?
    @ObservationIgnored private var speech: SetupSnapshot.SpeechService?
    @ObservationIgnored private var backups: [SetupSnapshot.SpeechService] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let fetchHealth: (URL) async -> [String: Any]?

    private static let knownKey = "setupKnownMachines"

    init(settings: AppSettings = .shared, fetchHealth: @escaping (URL) async -> [String: Any]? = SetupDirectory.defaultFetchHealth) {
        self.settings = settings
        self.fetchHealth = fetchHealth
        if let data = UserDefaults.standard.data(forKey: Self.knownKey),
           let list = try? JSONDecoder().decode([SetupSnapshot.Machine].self, from: data) {
            known = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        } else {
            known = [:]
        }
    }

    /// Checks the speech server now and every 20 seconds.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshServices()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Called whenever the broker's connected Macs change.
    func update(edges: [BrokerEdgeInfo], coreEdgeId: EdgeID?) {
        self.coreEdgeId = coreEdgeId
        let now = Date()
        let online = Set(edges.map(\.id))
        for edge in edges {
            var machine = known[edge.id] ?? SetupSnapshot.Machine(
                id: edge.id, name: edge.name, profile: nil, hasMic: false,
                online: true, lastSeen: now, isCore: false, localModels: nil
            )
            machine.name = edge.name
            machine.profile = edge.caps.machine ?? machine.profile
            machine.hasMic = edge.caps.hasMic
            machine.localModels = edge.caps.localModels
            machine.speechModels = edge.caps.speechModels
            machine.appleSpeech = edge.caps.appleSpeech
            machine.startup = edge.caps.startup
            machine.online = true
            machine.lastSeen = now
            known[edge.id] = machine
        }
        for id in known.keys where !online.contains(id) {
            known[id]?.online = false
        }
        for id in known.keys {
            known[id]?.isCore = id == coreEdgeId
        }
        persistKnown()
        rebuild()
    }

    /// Listing cleanup only, after CoreHost has revoked access and disconnected
    /// the Mac. Keep the offline guard so callers cannot forget a live peer.
    func forget(_ id: EdgeID) {
        guard id != coreEdgeId, known[id]?.online == false else { return }
        known[id] = nil
        persistKnown()
        rebuild()
    }

    /// Plain privacy copy, independent of the Dictator voice.
    nonisolated static func removalConfirmation(machine: SetupSnapshot.Machine, snapshot: SetupSnapshot?,
                                                speechAddresses: [String]) -> String {
        var message = "“\(machine.name)” will no longer be able to connect to the main Mac. History already on that Mac stays there. Any of your Macs that are off or disconnected right now must be added again through Settings › Your Macs › Add a Mac on the main Mac."
        let offline = snapshot?.machines.filter { !$0.online && !$0.isCore && $0.id != machine.id }.map(\.name) ?? []
        if !offline.isEmpty {
            message += "\n\nOff or disconnected: " + offline.map { "“\($0)”" }.joined(separator: ", ") + "."
        }
        let services = [snapshot?.speech].compactMap { $0 } + (snapshot?.backups ?? [])
        let addresses = speechAddresses + services.map(\.address)
        if addresses.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            message += "\n\nRemoving a Mac does not change the speech server key. That Mac may still have a copy. To change it, delete the key file on the server’s Mac and restart the server. Then paste the new key in Settings › Advanced › Speech server key on any other Mac that needs it."
        }
        return message
    }

    /// The cleanup choice or the speech server address changed.
    func settingsChanged() {
        rebuild()
        Task { await refreshServices() }
    }

    func refreshServices() async {
        speech = await probe(settings.serverURL)
        var checked: [SetupSnapshot.SpeechService] = []
        let others = (settings.backupServerURLs + settings.speechSources.compactMap(\.serverURL)).filter { $0 != settings.serverURL }
        for address in NSOrderedSet(array: others).array.compactMap({ $0 as? String }) {
            if let service = await probe(address) { checked.append(service) }
        }
        backups = checked
        rebuild()
    }

    private func probe(_ address: String) async -> SetupSnapshot.SpeechService? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = try? SpeechEndpoint.validated(trimmed)
        let health = if let base { await fetchHealth(base.appendingPathComponent("health")) } else { nil as [String: Any]? }
        let host = base?.host
        let machineId = machine(forHost: host)
        var cleanupMachineId = machineId
        if let ollama = health?["ollama_url"] as? String,
           let ollamaHost = URL(string: ollama)?.host, !Self.isLoopback(ollamaHost) {
            cleanupMachineId = machine(forHost: ollamaHost)
        }
        return SetupSnapshot.SpeechService(
            address: trimmed,
            machineId: machineId,
            reachable: health?["status"] as? String == "ok",
            speechModel: health?["asr_model"] as? String,
            cleanupModel: health?["polish_model"] as? String,
            cleanupMachineId: cleanupMachineId,
            checkedAt: Date()
        )
    }

    private func machine(forHost host: String?) -> EdgeID? {
        guard let host else { return nil }
        if Self.isLoopback(host) { return coreEdgeId }
        return known.values.first { $0.profile?.tailscaleIP == host }?.id
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func rebuild() {
        // Speech addresses are matched to Macs by Tailscale address, which
        // may only be known after the Macs report in.
        if var service = speech, service.machineId == nil {
            service.machineId = machine(forHost: URL(string: service.address)?.host)
            if service.cleanupMachineId == nil { service.cleanupMachineId = service.machineId }
            speech = service
        }
        let machines = known.values.sorted { lhs, rhs in
            if lhs.isCore != rhs.isCore { return lhs.isCore }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        // A cleanup Mac chosen in Your Macs overrides the server's own.
        var shownSpeech = speech
        let routing = settings.setupRouting
        if let id = routing.cleanupMachineId, var service = shownSpeech {
            service.cleanupMachineId = id
            service.cleanupModel = routing.cleanupModel ?? service.cleanupModel
            shownSpeech = service
        }
        var next = SetupSnapshot(
            coreId: coreEdgeId, machines: machines, speech: shownSpeech, backups: backups,
            cleanupOn: settings.refineLevel != .exact, generatedAt: snapshot?.generatedAt ?? Date()
        )
        if var previous = snapshot {
            previous.generatedAt = next.generatedAt
            if previous == next { return }
        }
        next.generatedAt = Date()
        snapshot = next
        onChange?(next)
    }

    private func persistKnown() {
        if let data = try? JSONEncoder().encode(Array(known.values)) {
            UserDefaults.standard.set(data, forKey: Self.knownKey)
        }
    }

    nonisolated static func defaultFetchHealth(_ url: URL) async -> [String: Any]? {
        guard let data = try? await TranscriptionService.healthData(at: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
