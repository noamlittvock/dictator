import Foundation
import Observation

/// Deliberately contains no plan, transcript, slot, app or window details.
struct CommandActivityRecord: Codable, Equatable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable { case done, stopped, failed }
    var id: UUID
    var time: Date
    var commandId: String
    var commandName: String
    var trigger: VoiceCommandTrigger
    var outcome: Outcome
    var failureTitle: String?

    /// Only audited, fixed titles may cross into persistent activity. Other
    /// titles can contain spoken names, app names, paths or service errors.
    static func safeFailureTitle(_ title: String) -> String {
        switch title {
        case "Dictator needs Accessibility access", "Dictator couldn’t press the key",
             "Dictator couldn’t open a terminal", "The web address isn’t valid",
             "That folder isn’t on this Mac", "This routine is off. Turn it on to run it.":
            return title
        default: return "The command could not finish"
        }
    }
}

/// Serial file work never runs on the main thread. Atomic snapshots also
/// ensure a queued write cannot resurrect records after a subsequent Clear.
private final class CommandActivityFile: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "dev.noamlitt.dictator.command-activity", qos: .utility)
    init(url: URL) { self.url = url }

    func load() async -> [CommandActivityRecord] {
        await withCheckedContinuation { continuation in
            queue.async {
                let records = (try? Data(contentsOf: self.url))
                    .flatMap { try? JSONDecoder().decode([CommandActivityRecord].self, from: $0) } ?? []
                continuation.resume(returning: Array(records.prefix(CommandActivity.limit)))
            }
        }
    }

    func write(_ records: [CommandActivityRecord]) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(records)
                try data.write(to: self.url, options: [.atomic, .completeFileProtectionUnlessOpen])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
            } catch {
                // Activity is best effort, never a reason to fail a command.
            }
        }
    }

    func clear() {
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }

    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

@MainActor
@Observable
final class CommandActivity {
    nonisolated static let limit = 50
    static let shared: CommandActivity = {
        // Executor tests that do not inject an activity store stay entirely
        // in memory and never open the owner's Application Support folder.
        if NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return CommandActivity(fileURL: nil, saveAllowed: { false })
        }
        let settings = AppSettings.shared
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictator", isDirectory: true)
        let activity = CommandActivity(fileURL: folder.appendingPathComponent("recent-commands.json"),
                                       saveAllowed: { settings.persistHistory }, paused: { settings.isPromptCapturePaused() })
        activity.observePause(settings)
        return activity
    }()

    private(set) var records: [CommandActivityRecord] = []
    private(set) var lastPlan: VoiceLaunchPlan?
    private(set) var isRunningAgain = false
    /// A transient success signal for Welcome, even with history saving off.
    private(set) var lastSuccessCommandId: String?
    private(set) var lastSuccessTime: Date?
    @ObservationIgnored private let file: CommandActivityFile?
    @ObservationIgnored private let saveAllowed: () -> Bool
    @ObservationIgnored private let paused: () -> Bool
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var privacyRevision = 0

    init(fileURL: URL?, saveAllowed: @escaping () -> Bool = { true }, paused: @escaping () -> Bool = { false }) {
        file = fileURL.map(CommandActivityFile.init)
        self.saveAllowed = saveAllowed
        self.paused = paused
    }

    func load() async {
        guard !loaded else { return }
        let saved = await file?.load() ?? []
        guard !loaded else { return }
        loaded = true
        records = saved
    }

    struct Run {
        let time: Date
        let save: Bool
        let revision: Int
    }

    func begin(_ plan: VoiceLaunchPlan) async -> Run {
        await load()
        if paused() { pause() } else { lastPlan = plan }
        return Run(time: Date(), save: saveAllowed() && !paused(), revision: privacyRevision)
    }

    func finish(_ run: Run, plan: VoiceLaunchPlan, trigger: VoiceCommandTrigger, result: VoiceLaunchExecutor.Result) {
        if case .done = result {
            lastSuccessCommandId = plan.commandId
            lastSuccessTime = Date()
        }
        if paused() { pause() }
        guard run.save, saveAllowed(), !paused(), run.revision == privacyRevision else { return }
        let outcome: CommandActivityRecord.Outcome
        let title: String?
        switch result {
        case .done: outcome = .done; title = nil
        case .cancelled: outcome = .stopped; title = nil
        case .stopped(let alert): outcome = .failed; title = CommandActivityRecord.safeFailureTitle(alert.title)
        }
        records.insert(CommandActivityRecord(id: UUID(), time: run.time, commandId: plan.commandId,
                                             commandName: plan.commandName, trigger: trigger, outcome: outcome,
                                             failureTitle: title), at: 0)
        records = Array(records.prefix(Self.limit))
        file?.write(records)
    }

    func clear() {
        // Invalidates in-flight runs as well as pending loads.
        privacyRevision += 1
        loaded = true
        records = []
        file?.clear()
    }

    func pause() {
        privacyRevision += 1
        lastPlan = nil
        lastSuccessCommandId = nil
        lastSuccessTime = nil
    }

    var canRunAgain: Bool { lastPlan != nil && !paused() && !isRunningAgain }

    func runAgain(services: VoiceLaunchServices? = nil,
                  progress: ((VoiceLaunchProgress.Event) -> Void)? = nil) async -> VoiceLaunchExecutor.Result? {
        if paused() { pause() }
        guard canRunAgain, let plan = lastPlan else { return nil }
        isRunningAgain = true
        defer { isRunningAgain = false }
        return await VoiceLaunchExecutor.run(plan, services: services, trigger: .runAgain, activity: self, progress: progress)
    }

    func flush() async { await file?.flush() }

    private func observePause(_ settings: AppSettings) {
        withObservationTracking {
            if settings.isPromptCapturePaused() { pause() }
            _ = settings.promptCapturePausedUntil
        } onChange: { [weak self] in
            // Clear on every pause edit, including a quick pause then resume.
            Task { @MainActor [weak self] in
                self?.pause()
                self?.observePause(settings)
            }
        }
    }
}
