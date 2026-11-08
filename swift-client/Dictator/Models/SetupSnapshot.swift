import Foundation
import IOKit

/// What kind of Mac this is, for the drawing on Settings › Your Macs.
enum MachineKind: String, Codable, Equatable {
    case laptop, mini, studio, imac, pro, other

    static func from(productName: String) -> MachineKind {
        let name = productName.lowercased()
        if name.contains("macbook") { return .laptop }
        if name.contains("mini") { return .mini }
        if name.contains("studio") { return .studio }
        if name.contains("imac") { return .imac }
        if name.contains("mac pro") { return .pro }
        return .other
    }
}

/// Fixed facts about one Mac, reported by its Edge in `EdgeCapabilities`.
struct MachineProfile: Codable, Equatable {
    /// "Mac mini (2024)", "MacBook Pro (14-inch, 2023)"; empty when unknown.
    var productName: String
    var memoryGB: Int
    /// This Mac's Tailscale address, so the Core can tell which Mac a
    /// service address (the speech server) belongs to.
    var tailscaleIP: String?

    var kind: MachineKind { MachineKind.from(productName: productName) }

    /// This Mac, with its Tailscale address read fresh (it can come up
    /// after Dictator starts).
    static var current: MachineProfile {
        MachineProfile(productName: fixedProductName, memoryGB: fixedMemoryGB, tailscaleIP: TailscaleInterface.currentAddress())
    }

    private static let fixedProductName = readProductName() ?? ""
    private static let fixedMemoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())

    /// Apple silicon Macs publish their marketing name in the device tree.
    private static func readProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let property = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: property.prefix { $0 != 0 }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }
}

/// The Core's picture of the whole setup, sent to every Edge (`CoreMessage.setup`)
/// so every Mac can draw Settings › Your Macs, including Macs that are off.
struct SetupSnapshot: Codable, Equatable {
    struct Machine: Codable, Equatable, Identifiable {
        var id: EdgeID
        var name: String
        var profile: MachineProfile?
        var hasMic: Bool
        var online: Bool
        /// When the Core last heard from it (for "off since …").
        var lastSeen: Date
        var isCore: Bool
        /// Models Ollama has installed on this Mac; nil when Ollama isn't
        /// running there (or the Mac didn't say).
        var localModels: [String]?
        /// Speech-to-text models in Dictator on this Mac.
        var speechModels: [String]? = nil
        /// It can run Apple's speech recognition.
        var appleSpeech: Bool? = nil
        /// Last report from this Mac; do not treat it as current while offline.
        var startup: StartupReport? = nil
    }

    /// The speech server the Core sends recordings to.
    struct SpeechService: Codable, Equatable {
        var address: String
        /// The Mac it runs on, when its address matches one of the machines.
        var machineId: EdgeID?
        var reachable: Bool
        var speechModel: String?
        var cleanupModel: String?
        /// The Mac running the cleanup model, when it's not the server's own.
        var cleanupMachineId: EdgeID?
        var checkedAt: Date
    }

    var coreId: EdgeID?
    var machines: [Machine]
    var speech: SpeechService?
    /// Backup speech servers, tried in order when `speech` can't be reached.
    var backups: [SpeechService] = []
    /// `false` = "exactly as spoken" (no cleanup).
    var cleanupOn: Bool
    var generatedAt: Date
}

/// Which Mac does which job, beyond the main speech server — edited on any
/// Mac and mirrored Core↔Edge (`AppSettings.setupRoutingJSON`).
struct SetupRouting: Codable, Equatable {
    /// The Mac that cleans up text and the model it uses; nil = the
    /// speech server's own cleanup model.
    var cleanupMachineId: EdgeID?
    var cleanupModel: String?
    /// Speech servers tried in order when the main one can't be reached.
    var backupServerURLs: [String] = []
    /// Where speech is turned into text, in order: a speech server, or a
    /// speech model in Dictator on one of the Macs. nil = the main speech
    /// server, then `backupServerURLs`.
    var speechSources: [SpeechSource]?
    /// The languages this user speaks (ISO codes); speech models choose
    /// among them. nil = the Mac's preferred languages.
    var languages: [String]?

    struct SpeechSource: Codable, Equatable, Hashable {
        var serverURL: String?
        var machineId: EdgeID?
        var model: String?

        static func server(_ url: String) -> SpeechSource { SpeechSource(serverURL: url) }
        static func mac(_ id: EdgeID, model: String) -> SpeechSource { SpeechSource(machineId: id, model: model) }
    }

    static func decode(_ json: String) -> SetupRouting? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SetupRouting.self, from: data)
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Configuration status, not a promise that a configured Mac is reachable.
enum CleanupStatus: Equatable {
    case skipped, ready, notSetUp, unknown

    static func evaluate(refineLevel: RefineLevel, routing: SetupRouting, snapshot: SetupSnapshot?) -> Self {
        if refineLevel == .exact { return .skipped }
        guard let snapshot else { return .unknown }
        if routing.cleanupMachineId != nil, routing.cleanupModel != nil { return .ready }
        // A speech server can clean up itself without a Mac/Ollama relay.
        return snapshot.speech?.cleanupModel != nil ? .ready : .notSetUp
    }
}

/// Whether completing model setup should fill a job that has no model yet.
enum ModelSetupPolicy {
    static func shouldActivate(
        job: ModelJob, speechSources: [SetupRouting.SpeechSource],
        routing: SetupRouting, snapshot: SetupSnapshot?
    ) -> Bool {
        switch job {
        case .speech:
            return speechSources.isEmpty
        case .cleanup:
            let chosen = routing.cleanupMachineId != nil && routing.cleanupModel != nil
            return !chosen && snapshot?.speech?.cleanupModel == nil
        }
    }
}
