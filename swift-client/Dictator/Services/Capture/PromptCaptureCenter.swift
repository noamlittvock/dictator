import AppKit
import Foundation
import Observation

/// How a tool's prompts are captured on this Mac.
enum CaptureMethod: String, Codable, CaseIterable, Sendable {
    /// The tool's own prompt hook runs `dictator-capture` (exact).
    case hook
    /// Dictator reads the tool's own history file (exact, no config change).
    case transcript
    /// Keystrokes / the focused text box (no setup; best effort in terminals).
    case keystrokes

    var title: String {
        switch self {
        case .hook: "Tool hook"
        case .transcript: "Tool's history file"
        case .keystrokes: "Keyboard"
        }
    }

    var detail: String {
        switch self {
        case .hook: "Exact. Adds one hook to the tool's settings (a backup is kept)."
        case .transcript: "Exact. Reads the tool's own history file; changes nothing."
        case .keystrokes: "No setup. Best effort in terminals; exact in chat boxes."
        }
    }
}

/// What this Mac knows about one tool.
struct LocalToolStatus: Equatable, Sendable {
    /// Usable here: installed, or a website (always reachable).
    var present: Bool
    /// Installed here: its app, CLI or config directory was found.
    var installed: Bool
    /// Both the tool's configuration entry and this Mac's shim are present.
    var hookInstalled: Bool
    var method: CaptureMethod?
}

/// One tool's outcome from first-run exact-capture setup.
/// Each tool reports separately, so a later tool's success can never hide
/// an earlier tool's failure.
struct ConnectorSetupResult: Equatable, Identifiable, Sendable {
    var id: String { toolID }
    let toolID: String
    let toolName: String
    let method: CaptureMethod
    /// Why it couldn't be set up; nil when it was.
    let error: String?
    var succeeded: Bool { error == nil }
}

/// Owns prompt capture end to end and is what Settings talks to: the tool
/// switches (synced), this Mac's connectors, remote servers, the
/// "Noticed, not saved" list and pausing.
@MainActor
@Observable
final class PromptCaptureCenter {
    static let shared = PromptCaptureCenter()

    let notices = NoticedSurfaceStore()
    @ObservationIgnored private(set) var recorder: PromptRecorder!
    @ObservationIgnored private(set) var typedCapture: TypedPromptCapture!
    @ObservationIgnored private var spoolWatcher: LocalSpoolWatcher!
    @ObservationIgnored private var transcriptWatcher: TranscriptWatcher!
    private(set) var remote: RemoteCaptureService!

    private(set) var statuses: [String: LocalToolStatus] = [:]
    private(set) var lastConnectorError: String?
    private(set) var isRefreshing = false
    private(set) var isSettingUp = false
    private(set) var setupResults: [ConnectorSetupResult] = []

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let access: ConfigFileAccess
    @ObservationIgnored private let localPresence: (@MainActor (ToolDefinition) async -> Bool)?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var monitoringStatuses = false
    /// Set by the view model: turns a prompt into a history row.
    @ObservationIgnored var saveHandler: (@MainActor (CapturedPrompt) async throws -> Void)?
    @ObservationIgnored private var started = false

    /// Tests can exercise local setup with a synthetic home and no collectors.
    init(settings: AppSettings = .shared, access: ConfigFileAccess = LocalConfigFileAccess(),
         localPresence: (@MainActor (ToolDefinition) async -> Bool)? = nil,
         initializeCollectors: Bool = true) {
        self.settings = settings
        self.access = access
        self.localPresence = localPresence
        guard initializeCollectors else { return }
        recorder = PromptRecorder(settings: settings, notices: notices) { [weak self] prompt in
            guard let handler = self?.saveHandler else { return }
            try await handler(prompt)
        }
        let submit: LocalSpoolWatcher.Handler = { [weak self] prompt in
            await self?.recorder.ingest(prompt) ?? false
        }
        spoolWatcher = LocalSpoolWatcher(onPrompt: submit)
        transcriptWatcher = TranscriptWatcher(onPrompt: submit)
        remote = RemoteCaptureService(onPrompt: submit)
        typedCapture = TypedPromptCapture(
            settings: settings,
            recorder: recorder,
            notices: notices,
            connectorCovers: { [weak self] id in self?.connectorCovers(id) ?? false },
            remoteCovers: { [weak self] host in self?.remote.isCapturing(remote: host) ?? false }
        )
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        notices.resolve { $0.kind == .needsSetup } // shown as one banner now
        settings.storeDefaultSurfacePolicyIfNeeded()
        typedCapture.start()
        spoolWatcher.start()
        applyTranscriptMethods()
        remote.start()
        startStatusMonitoring()
    }

    // MARK: - Tool switches (shared across the user's Macs)

    func isOn(_ toolID: String) -> Bool {
        settings.surfacePolicy.isToolOn(toolID)
    }

    func setTool(_ toolID: String, on: Bool) {
        settings.updateSurfacePolicy { $0.setTool(toolID, typed: on) }
        if on {
            notices.resolve { $0.toolID == toolID && ($0.kind == .toolOff || $0.kind == .needsSetup) }
        }
    }

    /// Remove only this explicitly selected custom tool. Unknown mirrored tool
    /// IDs belong to other Macs and must never be pruned from the policy.
    func removeCustomTool(_ tool: ToolDefinition) {
        lastConnectorError = nil
        do {
            try CustomToolRemoval.remove(id: tool.id, settings: settings)
            settings.captureMethods.removeValue(forKey: tool.id)
            statuses.removeValue(forKey: tool.id)
            notices.resolve { $0.toolID == tool.id }
            applyTranscriptMethods()
        } catch {
            lastConnectorError = "Couldn’t remove \(tool.name): \(error.localizedDescription)"
        }
    }

    /// Shared permission to save is separate from this Mac's setup. A saved
    /// method choice is not evidence that its hook (and shim) still exists.
    func needsSetup(_ tool: ToolDefinition) -> Bool {
        guard isOn(tool.id), tool.connector != nil,
              let status = statuses[tool.id], status.installed else { return false }
        let chosen = settings.captureMethods[tool.id].flatMap(CaptureMethod.init(rawValue:))
        if (chosen ?? recommendedMethod(for: tool)) == .hook { return !status.hookInstalled }
        return chosen == nil
    }

    /// Only tools the user switched on and that were found on this Mac.
    var toolsNeedingSetup: [ToolDefinition] {
        ToolCatalog.shared.tools.filter { isOn($0.id) && needsSetup($0) }
    }

    /// Explicit user action only. Preserve a chosen method and retain every
    /// outcome, including failures followed by another tool's success.
    @discardableResult
    func setUpAll() async -> [ConnectorSetupResult] {
        guard !isSettingUp else { return setupResults }
        isSettingUp = true
        defer { isSettingUp = false }
        await refreshStatuses()
        let plan = toolsNeedingSetup.map { tool in
            (tool: tool, method: settings.captureMethods[tool.id].flatMap(CaptureMethod.init(rawValue:)) ?? recommendedMethod(for: tool))
        }
        setupResults = await Self.runConnectorSetup(plan) { tool, method in
            await self.setMethod(method, for: tool)
        }
        lastConnectorError = setupResults.filter { !$0.succeeded }
            .map { "\($0.toolName): \($0.error ?? "Couldn’t finish setup.")" }.joined(separator: "\n")
        if lastConnectorError?.isEmpty == true { lastConnectorError = nil }
        return setupResults
    }

    func recommendedMethod(for tool: ToolDefinition) -> CaptureMethod {
        if tool.connector?.supportsHook == true { return .hook }
        if TranscriptWatcher.isAvailable(for: tool) { return .transcript }
        return .keystrokes
    }

    func availableMethods(for tool: ToolDefinition) -> [CaptureMethod] {
        var methods: [CaptureMethod] = []
        if tool.connector?.supportsHook == true { methods.append(.hook) }
        if TranscriptWatcher.isAvailable(for: tool) { methods.append(.transcript) }
        methods.append(.keystrokes)
        return methods
    }

    /// Whether a connector already delivers this tool's prompts on this Mac,
    /// so keystroke capture should stand aside.
    func connectorCovers(_ toolID: String) -> Bool {
        switch settings.captureMethods[toolID].flatMap(CaptureMethod.init(rawValue:)) {
        case .hook: return statuses[toolID]?.hookInstalled ?? false
        case .transcript: return true
        default: return false
        }
    }

    // MARK: - Connectors on this Mac

    /// Returns why it failed, or nil when the method is now in place.
    @discardableResult
    func setMethod(_ method: CaptureMethod, for tool: ToolDefinition) async -> String? {
        lastConnectorError = nil
        var failure: String?
        do {
            if method == .hook {
                try await ConnectorInstaller.installShim(on: access, script: try ConnectorInstaller.bundledShim())
                try await ConnectorInstaller.install(tool, on: access)
            } else if await ConnectorInstaller.isInstalled(tool, on: access) {
                try await ConnectorInstaller.uninstall(tool, on: access)
            }
            settings.captureMethods[tool.id] = method.rawValue
            notices.resolve { $0.toolID == tool.id && $0.kind == .needsSetup }
        } catch {
            failure = error.localizedDescription
            lastConnectorError = "\(tool.name): \(error.localizedDescription)"
        }
        applyTranscriptMethods()
        await refreshStatus(tool)
        return failure
    }

    func removeConnector(_ tool: ToolDefinition) async {
        lastConnectorError = nil
        do {
            try await ConnectorInstaller.uninstall(tool, on: access)
        } catch {
            lastConnectorError = "\(tool.name): \(error.localizedDescription)"
        }
        settings.captureMethods.removeValue(forKey: tool.id)
        applyTranscriptMethods()
        await refreshStatus(tool)
    }

    /// Removes every hook Dictator added on this Mac, and the shim.
    func removeAllLocalHooks() async {
        for tool in ToolCatalog.shared.tools where tool.connector?.supportsHook == true {
            if await ConnectorInstaller.isInstalled(tool, on: access) {
                try? await ConnectorInstaller.uninstall(tool, on: access)
            }
            if settings.captureMethods[tool.id] == CaptureMethod.hook.rawValue {
                settings.captureMethods.removeValue(forKey: tool.id)
            }
        }
        try? await access.delete(ConnectorInstaller.shimRelativePath)
        await refreshStatuses()
    }

    private func applyTranscriptMethods() {
        let ids = Set(settings.captureMethods.filter { $0.value == CaptureMethod.transcript.rawValue }.keys)
        transcriptWatcher?.setTools(ids)
    }

    /// Refresh an existing shim once at launch; subsequent status checks only
    /// read configuration. A deleted shim requires explicit setup.
    func startStatusMonitoring(pollInterval: Duration = .seconds(300)) {
        guard !monitoringStatuses else { return }
        monitoringStatuses = true
        observeSetupChoices()
        statusTask = Task { [weak self] in
            await self?.refreshShimIfUsed()
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshStatuses()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private func refreshShimIfUsed() async {
        guard settings.captureMethods.values.contains(CaptureMethod.hook.rawValue),
              await access.exists(ConnectorInstaller.shimRelativePath),
              let script = try? ConnectorInstaller.bundledShim() else { return }
        try? await ConnectorInstaller.installShim(on: access, script: script)
    }

    func stopStatusMonitoring() {
        monitoringStatuses = false
        statusTask?.cancel()
        statusTask = nil
    }

    private func observeSetupChoices() {
        guard monitoringStatuses else { return }
        withObservationTracking {
            _ = settings.cachedSurfacePolicyJSON
            _ = settings.captureMethods
            _ = ToolCatalog.shared.tools
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.monitoringStatuses else { return }
                self.observeSetupChoices()
                await self.refreshStatuses()
            }
        }
    }

    // MARK: - Detection

    func refreshStatuses() async {
        isRefreshing = true
        defer { isRefreshing = false }
        for tool in ToolCatalog.shared.tools {
            await refreshStatus(tool)
        }
    }

    private func refreshStatus(_ tool: ToolDefinition) async {
        let installed: Bool
        if let localPresence { installed = await localPresence(tool) }
        else { installed = await isInstalledLocally(tool) }
        let present = installed || !tool.signatures.domains.isEmpty
        var hook = tool.connector?.supportsHook == true ? await ConnectorInstaller.isInstalled(tool, on: access) : false
        if hook { hook = await access.exists(ConnectorInstaller.shimRelativePath) }
        let method = settings.captureMethods[tool.id].flatMap(CaptureMethod.init(rawValue:))
        statuses[tool.id] = LocalToolStatus(present: present, installed: installed, hookInstalled: hook, method: method)
    }

    func captureDescription(for tool: ToolDefinition) -> String {
        let method = settings.captureMethods[tool.id].flatMap(CaptureMethod.init(rawValue:)) ?? recommendedMethod(for: tool)
        switch method {
        case .hook: return "From the tool’s prompt hook"
        case .transcript: return "From the tool’s history file"
        case .keystrokes: return tool.readsComposer ? "From the text box when you send" : "From the keyboard"
        }
    }

    func localState(for tool: ToolDefinition) -> String {
        guard let status = statuses[tool.id] else { return "Checking this Mac…" }
        guard status.present else { return "Not found on this Mac" }
        if needsSetup(tool) { return "Needs setup" }
        if !settings.persistHistory { return "History is off" }
        if let pause = pauseDescription { return pause }
        if status.hookInstalled, status.method == .hook || status.method == nil { return "Set up" }
        return "On"
    }

    private func isInstalledLocally(_ tool: ToolDefinition) async -> Bool {
        for bundleID in tool.signatures.bundleIDs where !bundleID.contains("*") {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil { return true }
        }
        if tool.signatures.bundleIDs.contains(where: { $0.contains("*") }) {
            let prefix = tool.signatures.bundleIDs.first { $0.contains("*") }!.replacingOccurrences(of: "*", with: "")
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier?.hasPrefix(prefix) == true }) { return true }
        }
        if await ConnectorInstaller.isToolPresent(tool, on: access) { return true }
        let home = NSHomeDirectory()
        let dirs = ["\(home)/.local/bin", "\(home)/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin"]
        for name in tool.signatures.processNames {
            if dirs.contains(where: { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }) { return true }
        }
        return false
    }

    // MARK: - First run

    /// Applies the first-run choices: switches the chosen tools on (and the
    /// rest off), and sets up exact capture for chosen tools found here.
    ///
    /// Returns one result per tool it tried to connect. Setup
    /// is only marked complete when every tool connected; otherwise the
    /// caller shows what failed, offers Retry, and calls `finishSetup()`
    /// once the user chooses to continue without them.
    @discardableResult
    func completeSetup(selected: Set<String>, useHooks: Bool) async -> [ConnectorSetupResult] {
        settings.updateSurfacePolicy { policy in
            for tool in ToolCatalog.shared.tools {
                policy.setTool(tool.id, typed: selected.contains(tool.id))
            }
        }
        var plan: [(tool: ToolDefinition, method: CaptureMethod)] = []
        for id in selected.sorted() {
            guard let tool = ToolCatalog.shared.tool(id: id), statuses[id]?.installed == true, tool.connector != nil else { continue }
            let method: CaptureMethod = useHooks ? recommendedMethod(for: tool)
                : (TranscriptWatcher.isAvailable(for: tool) ? .transcript : .keystrokes)
            plan.append((tool, method))
        }
        let results = await Self.runConnectorSetup(plan) { tool, method in
            await self.setMethod(method, for: tool)
        }
        if results.allSatisfy(\.succeeded) { finishSetup() }
        return results
    }

    /// Tries one failed tool again with the same method.
    func retryConnector(_ result: ConnectorSetupResult) async -> ConnectorSetupResult {
        guard let tool = ToolCatalog.shared.tool(id: result.toolID) else { return result }
        let error = await setMethod(result.method, for: tool)
        return ConnectorSetupResult(toolID: result.toolID, toolName: result.toolName, method: result.method, error: error)
    }

    /// The user is done with first-run setup (whatever connected or not).
    func finishSetup() {
        settings.didCompletePromptSetup = true
    }

    /// Connects each tool in turn and records each outcome on its own.
    static func runConnectorSetup(
        _ plan: [(tool: ToolDefinition, method: CaptureMethod)],
        apply: (ToolDefinition, CaptureMethod) async -> String?
    ) async -> [ConnectorSetupResult] {
        var results: [ConnectorSetupResult] = []
        for (tool, method) in plan {
            let error = await apply(tool, method)
            results.append(ConnectorSetupResult(toolID: tool.id, toolName: tool.name, method: method, error: error))
        }
        return results
    }

    // MARK: - Pause

    func pause(for interval: TimeInterval?) {
        settings.promptCapturePausedUntil = interval.map { Date().addingTimeInterval($0) } ?? .distantFuture
    }

    func resume() {
        settings.promptCapturePausedUntil = nil
    }

    var pauseDescription: String? {
        guard let until = settings.promptCapturePausedUntil, until > Date() else { return nil }
        if until == .distantFuture { return "Paused until you resume" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Paused until \(formatter.string(from: until))"
    }

    // MARK: - Tap fan-out

    func handleTyping(_ activity: TypingActivity) {
        typedCapture.handle(activity)
    }

    func handleMouseDown() {
        typedCapture.handleMouseDown()
    }
}

/// Disk persistence succeeds before policy changes are published. Using the
/// normal settings edit path also sends this exact removal through the mirror.
@MainActor
enum CustomToolRemoval {
    static func remove(id: String, settings: AppSettings,
                       removeFromCatalog: (String) throws -> Void = { try ToolCatalog.removeCustomTool(id: $0) }) throws {
        try removeFromCatalog(id)
        settings.updateSurfacePolicy { $0.tools?.removeValue(forKey: id) }
    }
}
