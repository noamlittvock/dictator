import AVFoundation
import Foundation
import Observation
import SwiftData
import SwiftUI

enum DictatorState: Equatable {
    case idle
    case needsPermission(String)
    case recording
    case processing
    case error(String)
}

/// Records why an Edge isn't currently connected to its Core, for
/// `roleStatus`. Kept as a small enum (not a raw string) so the display text
/// for "no pairing token" and the generic unreachable fallback stays exact
/// regardless of what a `CoreConnection` drop reason happens to say.
private enum EdgeConnectivityIssue: Equatable {
    case noAddressConfigured
    case pairingRequired(String)
    case noPairingToken
    case invalidAddress
    case unreachable(String?)
    /// The main Mac and this Mac run incompatible versions; one must update.
    case versionMismatch(ProtocolMismatch)
}

/// Thin coordinator: creates the machine-local `EdgeRuntime` and the
/// broker-owning `CoreHost`, wires them together according to
/// `AppSettings.coreRole`, and keeps the persistence/indicator
/// wiring that isn't part of the Edge↔Core protocol. Every dictation —
/// standalone, Core, or Edge — flows through `SessionBroker` via one of
/// these two objects; this class doesn't run the flow itself.
@Observable
@MainActor
final class DictatorViewModel {
    /// `DictatorApp` uses this shared instance (rather than a private
    /// `@State`) so `ConnectionDetailsView` — a settings pane with no other
    /// route back to the running app's `EdgeRuntime`/`CoreHost` — can read
    /// `roleStatus`/`connectedEdges` and call `applyRole()`, the same way
    /// every other settings tab reaches `AppSettings.shared`.
    static let shared = DictatorViewModel()

    private let settings = AppSettings.shared
    private let transcriptionService = TranscriptionService()
    private var datasetStore: DatasetStore?
    @ObservationIgnored private var heardBySession: [SessionID: String] = [:]
    @ObservationIgnored private let correctionLearning = CorrectionLearningService()
    @ObservationIgnored private lazy var dictionaryUsage = DictionaryUsageBatcher(isMain: { [weak self] in
        guard let self else { return false }
        return self.settings.coreRole != .edge
    }) { [weak self] counts in
        guard let self, self.settings.coreRole != .edge else { return }
        try (self.repositoryHub.current.dictionary as? LocalDictionaryRepository)?.applyUsage(counts)
    }
    @ObservationIgnored private lazy var editWatcher = EditWatcher(reader: NativeEditAccessibilityReader(), allowed: { [weak self] context in
        guard let self else { return false }
        return self.settings.correctionObservationAllowed(for: context)
    }, prepare: { [weak self] report, context in
        guard let self else { return [] }
        return CorrectionLearningService.reports(report,
            keepSentence: self.settings.captureDecision(for: context, modality: "typed").isSave,
            languages: self.settings.dictationLanguages)
    }, deliver: { [weak self] report in
        Task { @MainActor [weak self] in _ = await self?.receiveCorrection(report) }
    })

    private var edgeRuntime: EdgeRuntime!
    private var coreHost: CoreHost!
    private var edgeConnection: CoreConnection?
    /// Recovery for recording checkpoints left on disk by either role (this machine's
    /// own Edge captures, and — in Core role — takes retained for retry). See
    /// `MenuBarView`/`HistoryPrivacySettingsPage`.
    private var recoveryService: RecoveryService!

    /// Repository access for the History/Dictionary/Settings UI and for
    /// `saveEntry`/`loadDictionary` below. Always the same `RepositoryHub`
    /// instance for this object's whole lifetime, and always over this
    /// Mac's own store — a connected Core changes what `syncEngine`
    /// replicates into that store, never what the UI reads.
    let repositoryHub: RepositoryHub
    /// Local-first replication to a Core while in Edge role — see
    /// `HistorySyncEngine`. Views read its `status`/`pendingCount`.
    let syncEngine: HistorySyncEngine
    private let settingsMirror = CoreSettingsMirror()
    @ObservationIgnored private var coreSettingsChanges: CoreSettingsChangeObserver?
    /// Core/standalone role: the picture of every Mac and the speech server
    /// (Settings › Your Macs), sent to every Edge.
    let setupDirectory = SetupDirectory()
    private var isLocalEdgeAttached = false
    private var isEdgeConnected = false
    /// Core role: restarts the listener when Tailscale comes up after launch.
    private var tailscaleWatcher: TailscaleAddressWatcher?
    private var edgeIssue: EdgeConnectivityIssue?
    private var pendingLocalEdgeSwitch: (() -> Void)?
    /// Bumped by every `applyRole()`: every deferred closure and
    /// `CoreConnection` callback captures the generation current when it was
    /// created and no-ops if it's since gone stale, so a role flipped back
    /// and forth (or a callback queued on a connection that's no longer the
    /// live one) can never act on state that belongs to an earlier role.
    private var roleGeneration = 0

    /// Which model polished each session's take, whether it was the first
    /// take for that model since launch, and what its clean-up really did
    /// (shown in history, included in Dataset exports).
    private struct CleanupRecord {
        var model: String
        var firstAfterLoad: Bool
        /// Nil for voice commands, which aren't cleaned up as a dictation.
        var level: RefineLevel?
        var outcome: CleanupOutcome? = nil
        var ms: Int? = nil
    }
    private var polishBySession: [SessionID: CleanupRecord] = [:]
    private var modelsUsedSinceLaunch = Set<String>()
    private var serverPolishModel: String?

    var persistenceWarning: String?

    /// `installLocalRepositories(_:)` (its `didSet`) moves the hub, the Core
    /// host and the sync engine onto the real on-disk bundle the moment
    /// this is actually set. Until then they run over an in-memory
    /// placeholder (see `Self.makeInMemoryRepositories`) so nothing crashes
    /// before persistence exists — hosted unit tests never set it, and
    /// `DictatorApp.init` sets it moments after constructing `.shared`.
    var modelContainer: ModelContainer? {
        didSet {
            guard let modelContainer else { return }
            installLocalRepositories(Repositories.make(container: modelContainer))
        }
    }

    init() {
        let runtime = EdgeRuntime()
        edgeRuntime = runtime
        let placeholderRepositories = Self.makeInMemoryRepositories()
        repositoryHub = RepositoryHub(current: placeholderRepositories)
        syncEngine = HistorySyncEngine(repositories: placeholderRepositories)
        coreHost = CoreHost(
            // The Core's identity must be independent of any
            // local Edge's id — see `CoreHost.persistentCoreId()`.
            coreId: CoreHost.persistentCoreId(),
            repositories: placeholderRepositories,
            transcribe: { [weak self] header, data in
                guard let self else { throw CancellationError() }
                let result = try await self.transcribe(header, data)
                return (result.text, result.inferenceMs)
            },
            recordHistory: { [weak self] sessionId, text, duration, inferenceMs, destination, initiator in
                guard let self else { throw CancellationError() }
                try await self.recordHistory(sessionId, text, duration, inferenceMs, destination, initiator: initiator)
            },
            transcribeWithRawText: { [weak self] header, data in
                guard let self else { throw CancellationError() }
                return try await self.transcribe(header, data)
            }
        )
        coreHost.onHeardText = { [weak self] id, text in self?.heardBySession[id] = text }
        coreHost.onSessionFinished = { [weak self] id in self?.heardBySession.removeValue(forKey: id) }
        coreHost.onCorrection = { [weak self] report in
            guard let self else { throw CancellationError() }
            return try await self.correctionLearning.receive(report, repositories: self.repositoryHub.current, settings: self.settings)
        }
        runtime.onInsertedForLearning = { [weak self] session, text, context in
            self?.editWatcher.inserted(text, entryID: UUID(uuidString: session), context: context)
        }
        runtime.onNextDictationForLearning = { [weak self] in self?.editWatcher.finish() }
        coreHost.transcribeRaw = { [weak self] header, data in
            guard let self else { throw CancellationError() }
            return try await self.transcribe(header, data, rawOnly: true).text
        }
        VoiceTeachService.shared.transcribe = { [weak self] audio in
            guard let self else { throw CancellationError() }
            return try await self.teachTranscribe(audio)
        }
        VoiceTeachService.shared.recorder = runtime
        coreHost.cleanUpText = { [weak self] text, useAI in
            guard let self else { throw CancellationError() }
            return try await self.cleanUpTextForShortcuts(text, useAI: useAI)
        }
        ShortcutsBridge.services = makeShortcutsServices()
        coreHost.resolveVoiceCommand = { [weak self] sessionId, transcript in
            guard let self else { return VoiceCommandResolution(text: transcript) }
            return await self.resolveVoiceCommand(sessionId: sessionId, transcript: transcript)
        }
        recoveryService = RecoveryService(
            loadDictionary: { [weak self] in await self?.loadDictionary() ?? [] },
            transcribe: { [weak self] audio in
                guard let self else { throw CancellationError() }
                return try await self.recoverTranscribe(audio)
            },
            // Rethrows (after still reporting it, for the
            // persistence-warning UI) instead of swallowing the error —
            // `RecoveryService.transcribe` needs to know a history write
            // failed so it keeps the checkpoint (marked `.failed`) instead
            // of unconditionally deleting a take whose history entry never
            // actually landed.
            saveEntry: { [weak self] text, duration, inferenceMs, source in
                do {
                    try await self?.saveEntry(text: text, duration: duration, inferenceMs: inferenceMs, source: source)
                } catch {
                    self?.reportPersistenceIssue(error)
                    throw error
                }
            },
            saveEntryWithStages: { [weak self] text, heard, duration, inferenceMs, source in
                do {
                    try await self?.saveEntry(text: text, duration: duration, inferenceMs: inferenceMs, source: source, heardText: heard)
                } catch {
                    self?.reportPersistenceIssue(error)
                    throw error
                }
            }
        )
        let workspace = WorkspaceLaunchController.shared
        workspace.fleet = self
        workspace.macName = { [weak runtime] in runtime?.edgeName ?? Host.current().localizedName ?? "This Mac" }
        runtime.onWorkspaceCapture = { await WorkspaceLaunchController.shared.answerCaptureRequest() }
        runtime.onWorkspaceRun = { routineID, undo, from, operationID in
            await WorkspaceLaunchController.shared.answerRunReport(routineID: routineID, undo: undo, from: from, operationID: operationID)
        }
        armRepositoryChangeObservers()
    }

    /// Placeholder local bundle used only until `modelContainer` is
    /// actually set — an in-memory `ModelContainer` (never persisted,
    /// thrown away the moment real persistence arrives) so
    /// `repositoryHub`/`coreHost` have something usable from the moment
    /// this object exists, without needing a disk location that may not
    /// exist yet (hosted unit tests never provide one at all). Unlike the
    /// on-disk containers `PersistenceLoader` guards so carefully, there's
    /// no file I/O, disk permissions, or migration involved here to fail —
    /// an in-memory container with this fixed, well-formed schema does not
    /// fail to initialize in practice.
    private static func makeInMemoryRepositories() -> Repositories {
        let schema = Repositories.schema
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        return Repositories.make(container: container)
    }

    /// Swaps in the freshly-built on-disk bundle — called once persistence
    /// is actually available (`modelContainer`'s `didSet`). The hub, the
    /// Core host and the sync engine all move onto the same instance.
    private func installLocalRepositories(_ repositories: Repositories) {
        coreHost.repositories = repositories
        repositoryHub.install(repositories)
        syncEngine.setRepositories(repositories)
        let datasetStore = DatasetStore.shared
        self.datasetStore = datasetStore
        datasetStore.start(hub: repositoryHub, localEdgeId: localEdgeId) { [weak self] in
            Dictionary((self?.connectedEdges ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        }
    }

    // MARK: - Repo change propagation

    /// A repository's one `onChange` slot belongs to `RepositoryHub` alone
    /// (see `RepositoryHub.subscribe`), so this observes the hub's three
    /// per-domain versions directly. `coreHost.repositories` and
    /// `repositoryHub.current` are the same local bundle, so any
    /// history/dictionary mutation against it — this Mac's own dictation, a
    /// Settings-tab edit, or a remote edge's `historyUpsert`/
    /// `dictionaryUpsert` routed through `RepoServer` — already bumps the
    /// matching hub version. In Core role that becomes one `repo.changed`
    /// broadcast to every connected edge; in Edge role it tells the sync
    /// engine there may be something to push.
    ///
    /// Armed once, for the object's whole lifetime: these observers are
    /// always "on"; they simply pick the right consumer by `coreRole`.
    private func armRepositoryChangeObservers() {
        armHistoryVersionObserver()
        armDictionaryVersionObserver()
        coreSettingsChanges = CoreSettingsChangeObserver(settings: settings, hub: repositoryHub, applySettings: { [weak self] in
            self?.applyMicOwnerPreference()
        }) { [weak self] in
            self?.coreHost.broadcastRepoChanged(.settings)
        }
    }

    private func armHistoryVersionObserver() {
        withObservationTracking {
            _ = repositoryHub.historyLocalVersion
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.armHistoryVersionObserver()
                switch self.settings.coreRole {
                case .core: self.coreHost.broadcastRepoChanged(.history)
                case .edge: self.syncEngine.localChanged()
                case .standalone: break
                }
            }
        }
    }

    private func armDictionaryVersionObserver() {
        withObservationTracking {
            _ = repositoryHub.dictionaryLocalVersion
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.armDictionaryVersionObserver()
                switch self.settings.coreRole {
                case .core: self.coreHost.broadcastRepoChanged(.dictionary)
                case .edge: self.syncEngine.localChanged()
                case .standalone: break
                }
            }
        }
    }

    // MARK: - Derived display state

    /// `.recording`/`.processing` come from `edgeRuntime.phase`;
    /// `.needsPermission`/`.error` come from its runtime health — a pure
    /// function of current state, so there is no separate "clear the stale
    /// error" step to forget.
    var state: DictatorState {
        if let errorMessage = edgeRuntime.errorMessage {
            return .error(errorMessage)
        }
        if case .needsPermission(let message) = edgeRuntime.health {
            return .needsPermission(message)
        }
        switch edgeRuntime.phase {
        case .idle: return .idle
        case .recording: return .recording
        case .processing, .inserting: return .processing
        }
    }

    var lastTranscription: String? { edgeRuntime.lastTranscription }
    var errorMessage: String? { edgeRuntime.errorMessage }
    var insertionWarning: String? { edgeRuntime.insertionWarning }
    var needsAccessibility: Bool { edgeRuntime.needsAccessibility }
    /// Non-blocking: "no microphone available to this machine right now."
    var micWarning: String? { edgeRuntime.micWarning }
    var localHasMic: Bool { edgeRuntime.capabilities().hasMic }

    // MARK: - Recovery

    /// Recording checkpoints left on disk, excluding whatever session is
    /// currently active on this machine — read by `MenuBarView` and
    /// `HistoryPrivacySettingsPage`.
    ///
    /// A plain read of `recoveryService.takes` — nothing else. SwiftUI can
    /// call it from the middle of view evaluation, where assigning
    /// `recoveryService.activeTakeIds` (which re-runs `refresh()`, a
    /// synchronous directory scan) would risk repeated invalidation/render
    /// cycles and a filesystem scan on ordinary recomputation. Active ids
    /// are updated from lifecycle events instead — see
    /// `updateRecoveryActiveTakeIds()` and `armRecoveryLifecycleObserver()`.
    var recoverableTakes: [RecoveryService.RecoverableTake] { recoveryService.takes }
    var recoveryNotice: String? { recoveryService.lastNotice }

    func isRecoveryBusy(_ take: RecoveryService.RecoverableTake) -> Bool {
        recoveryService.busyTakeIds.contains(take.id)
    }

    func transcribeRecoveredTake(_ take: RecoveryService.RecoverableTake) async {
        await recoveryService.transcribe(take)
        if let alert = recoveryService.lastAlert { edgeRuntime.alerts.show(alert) }
    }

    func discardRecoveredTake(_ take: RecoveryService.RecoverableTake) {
        recoveryService.discard(take)
    }

    /// For `MenuBarView`'s `onAppear` and any other spot that wants a fresh
    /// read without waiting for the next phase-change tick.
    func refreshRecoverableTakes() {
        recoveryService.refresh()
    }

    /// Recomputes which take ids belong to a session currently active on
    /// this machine and pushes them onto `recoveryService.activeTakeIds` —
    /// whose `didSet` re-runs `refresh()` (see `RecoveryService`). Called
    /// from lifecycle events only (armed once in `setup()` via
    /// `armRecoveryLifecycleObserver()`, watching `edgeRuntime.phase`; also
    /// after transcribe/discard and at launch), never from a view's
    /// body/getter.
    private func updateRecoveryActiveTakeIds() {
        var active: Set<String> = []
        if let sessionId = edgeRuntime.lastSessionState?.sessionId, edgeRuntime.phase != .idle {
            active.insert(RecordingCheckpointStore.edgeTakeId(sessionId))
            active.insert(RecordingCheckpointStore.coreTakeId(sessionId))
        }
        recoveryService.activeTakeIds = active
    }

    /// Re-arms itself on every change (same `withObservationTracking`
    /// pattern as `armHistoryVersionObserver`/`observePendingRoleSwitch`
    /// elsewhere in this file) so every transition of `edgeRuntime.phase` —
    /// in particular back to `.idle`, when a just-finished session's take
    /// should stop being excluded — updates the recovery list.
    private func armRecoveryLifecycleObserver() {
        withObservationTracking {
            _ = edgeRuntime.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.armRecoveryLifecycleObserver()
                self.updateRecoveryActiveTakeIds()
            }
        }
    }

    /// The hands-free mode actually in effect on this machine's hotkey tap
    /// — mirrors `edgeRuntime.handsFree`, which in Edge role comes from the
    /// Core's own `config` broadcast rather than this machine's own
    /// setting. For `GeneralSettingsPage`'s "Core's setting applies" note.
    var effectiveHandsFree: Bool { edgeRuntime.handsFree }

    /// True while this install is in Edge role and actually connected to a
    /// Core — the settings UI uses it to show the hands-free picker as
    /// disabled-but-informative rather than editable, since the Core owns
    /// the mode in that case.
    var isConnectedEdgeRole: Bool { settings.coreRole == .edge && isEdgeConnected }

    /// For `ConnectionDetailsView`: the Core's-eye view of who's connected
    /// (includes the local edge once attached), this machine's own
    /// `EdgeID` (to mark "This Mac" in that list), and the listener's
    /// address/warning.
    var connectedEdges: [BrokerEdgeInfo] { coreHost.connectedEdges }
    var localEdgeId: EdgeID { edgeRuntime.edgeId }
    var listeningAddress: String? { coreHost.listeningAddress }
    var listenerWarning: String? { coreHost.listenerWarning }

    /// Non-nil once `CoreSettingsMirror`'s last settings write to
    /// the Core failed even after its one retry — `roleStatus` below
    /// surfaces it inline; exposed here too for `MenuBarView`/other Edge-role
    /// UI that wants to show it more prominently.
    var mirrorWarning: String? { settingsMirror.mirrorWarning }

    /// `roleStatus` in plain words, for Settings.
    var connectionSummary: (text: String, ok: Bool) {
        let mainName = setupSnapshot?.mainMacName ?? "your main Mac"
        switch settings.coreRole {
        case .standalone:
            return ("This Mac works on its own.", true)
        case .core:
            if coreHost.listeningAddress != nil {
                return ("Other Macs can connect to this Mac.", true)
            }
            if coreHost.listenerWarning == "no Tailscale address found" || coreHost.listenerWarning == nil {
                return ("Other Macs can’t connect yet: Tailscale isn’t on here.", false)
            }
            return ("Other Macs can’t connect right now: \(coreHost.listenerWarning ?? "")", false)
        case .edge:
            if isEdgeConnected {
                if mirrorWarning != nil { return ("Connected to \(mainName), but settings didn’t sync. Dictator will try again.", false) }
                return ("Connected to \(mainName).", true)
            }
            switch edgeIssue {
            case .noPairingToken, .noAddressConfigured:
                return ("This Mac hasn’t joined a setup yet. Paste an invitation from your main Mac.", false)
            case .pairingRequired(let message):
                return (message, false)
            case .invalidAddress:
                return ("The main Mac’s address isn’t a Tailscale address. Paste a new invitation.", false)
            case .unreachable(let reason) where reason == Self.coreIdentityChangedMessage:
                return ("\(mainName) was reinstalled or replaced. Paste a new invitation from it.", false)
            case .versionMismatch(let mismatch):
                return (mismatch.updateMessage(mainMacName: mainName), false)
            case .unreachable, .none:
                return ("Can’t reach \(mainName). Dictation works on this Mac on its own until it’s back.", false)
            }
        }
    }

    // MARK: - Sync status (for views)

    var syncPendingCount: Int { syncEngine.pendingCount }
    var lastSyncAt: Date? { syncEngine.lastSyncAt }
    var lastSyncSummary: String? { syncEngine.lastSummary }

    /// One line for the History status bar, the menu bar and the Computers
    /// tab: what replication is doing right now, in the user's terms.
    var syncStatusText: String {
        Self.syncStatusText(
            status: syncEngine.status, role: settings.coreRole,
            pending: syncEngine.pendingCount, lastSyncAt: syncEngine.lastSyncAt
        )
    }

    /// Pure so tests can check every state reads in plain words: "main
    /// Mac"/"this Mac", never Core/Edge/Standalone or a raw error.
    nonisolated static func syncStatusText(
        status: HistorySyncEngine.Status, role: CoreRole, pending: Int, lastSyncAt: Date?
    ) -> String {
        let pendingText = pending == 0 ? "" : " · \(pending) waiting"
        switch status {
        case .standalone:
            return role == .core ? "This is the main Mac: it keeps the shared history" : "History stays on this Mac"
        case .offline:
            return "Can’t reach your main Mac — saving on this Mac for now\(pendingText)"
        case .syncing:
            return "Updating history with your main Mac…\(pendingText)"
        case .synced:
            if let lastSyncAt {
                return "History up to date with your main Mac \(relativeTime(lastSyncAt))\(pendingText)"
            }
            return "History up to date with your main Mac\(pendingText)"
        case .failed(let message):
            return "\(syncProblemText(message))\(pendingText)"
        }
    }

    /// A sync error in words a person can act on; the raw message stays in
    /// the sync log.
    nonisolated static func syncProblemText(_ message: String) -> String {
        let lowered = message.lowercased()
        if ["unauthorized", "401", "403", "pairing", "token", "forbidden"].contains(where: lowered.contains) {
            return "Your main Mac no longer recognizes this Mac. Paste a new invitation in Settings › Your Macs"
        }
        if ["timed out", "timeout", "offline", "not connected", "could not connect", "connection", "network", "refused", "unreachable"].contains(where: lowered.contains) {
            return "Couldn’t reach your main Mac to update history. Dictator will try again"
        }
        return "History couldn’t be updated with your main Mac. Dictator will try again"
    }

    func syncNow() {
        syncEngine.syncNow()
    }

    /// Menu-bar/feed presentation helpers.
    var showsSyncInMenu: Bool { settings.coreRole == .edge }
    var syncCanRunNow: Bool { settings.coreRole == .edge && isEdgeConnected }
    var syncIsHealthy: Bool {
        switch syncEngine.status {
        case .standalone, .syncing: return true
        case .synced: return syncEngine.pendingCount == 0
        case .offline, .failed: return false
        }
    }
    var syncSymbol: String {
        switch syncEngine.status {
        case .standalone: return settings.coreRole == .core ? "externaldrive.fill.badge.checkmark" : "internaldrive"
        case .offline: return "icloud.slash"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .synced: return syncEngine.pendingCount == 0 ? "checkmark.icloud" : "arrow.up.circle.dotted"
        case .failed: return "exclamationmark.icloud"
        }
    }

    nonisolated private static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "at \(formatter.string(from: date))"
    }

    // MARK: - Lifecycle

    func setup() {
        VoiceAppHints.refresh()
        // Before the welcome has explained them, start-up doesn't trigger
        // system permission requests on its own.
        edgeRuntime.promptsForPermissions = settings.didCompleteWelcome
        HotkeyService.promptsForMissingPermissionsOnFirstStart = settings.didCompleteWelcome
        edgeRuntime.setup()
        // Models load when a dictation starts (key down), not at launch.
        coreHost.onSessionStarted = { [weak self] in self?.prepareModelsForDictation() }
        // Prune anything past 14 days, then surface
        // whatever's left — no modal, just the menu item/Settings list.
        recoveryService.pruneAndRefreshOnLaunch()
        // From here on, `activeTakeIds` (and therefore the
        // recovery list) is kept current by lifecycle events, never by a
        // view reading `recoverableTakes`.
        updateRecoveryActiveTakeIds()
        armRecoveryLifecycleObserver()

        // Prompt capture (typed, connectors, remote servers) shares the one
        // hotkey tap. It isn't part of the Edge↔Core protocol, so it's
        // wired to `EdgeRuntime`'s hotkey service directly.
        let capture = PromptCaptureCenter.shared
        capture.saveHandler = { [weak self] prompt in
            guard let self else { return }
            try await self.saveCapturedPrompt(prompt)
        }
        capture.start()
        let hotkey = edgeRuntime.hotkeyService
        hotkey.onTypingActivity = { activity in
            MainActor.assumeIsolated { PromptCaptureCenter.shared.handleTyping(activity) }
        }
        hotkey.onMouseDown = {
            MainActor.assumeIsolated { PromptCaptureCenter.shared.handleMouseDown() }
        }

        // Piggy-backs on `EdgeRuntime`'s 5s runtime-health tick.
        edgeRuntime.onHealthTick = { [weak self] in
            self?.ensureEdgeConnectionAlive()
        }

        wireSetupDirectory()
        applyRole()
    }

    // MARK: - Setup picture (Settings › Your Macs)

    /// What this Mac knows about the whole setup: built here in Core and
    /// standalone role, received from the Core in Edge role.
    var setupSnapshot: SetupSnapshot? { edgeRuntime.setupSnapshot }

    private func wireSetupDirectory() {
        coreHost.onEdgesChanged = { [weak self] edges in
            guard let self, self.settings.coreRole != .edge else { return }
            self.setupDirectory.update(edges: edges, coreEdgeId: self.localEdgeId)
        }
        setupDirectory.onChange = { [weak self] snapshot in
            self?.coreHost.setupSnapshot = snapshot
            self?.edgeRuntime.applySetupSnapshot(snapshot)
        }
        let inventory = LocalModelInventory.shared
        inventory.onChange = { [weak self] models in self?.edgeRuntime.localModels = models }
        inventory.start()
        let speech = LocalSpeechService.shared
        speech.onChange = { [weak self] models in self?.edgeRuntime.speechModels = models }
        edgeRuntime.speechModels = speech.installed
        observeSetupSettings()
    }

    /// Re-checks the speech servers when their addresses or the cleanup
    /// choice change.
    private func observeSetupSettings() {
        withObservationTracking {
            _ = settings.serverURL
            _ = settings.setupRoutingJSON
            _ = settings.refineLevel
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeSetupSettings()
                if self.settings.coreRole != .edge { self.setupDirectory.settingsChanged() }
            }
        }
    }

    /// Shows `snapshot` in Settings as if the Core had sent it (snapshot
    /// tests and previews).
    func showSetupSnapshot(_ snapshot: SetupSnapshot) {
        edgeRuntime.applySetupSnapshot(snapshot)
    }

    // MARK: - Add a Mac

    var pendingJoin: CoreServer.PairRequest? { coreHost.pendingJoin }
    var isAcceptingNewMacs: Bool { (coreHost.acceptingNewMacsUntil ?? .distantPast) > Date() }

    /// Lets other Macs ask to join for ten minutes (or stops, with false).
    /// Makes this Mac the main Mac first if it was on its own.
    func acceptNewMacs(_ on: Bool) {
        if on, settings.coreRole == .standalone {
            settings.coreRole = .core
            applyRole()
        }
        coreHost.coreName = edgeRuntime.edgeName
        coreHost.acceptNewMacs(for: on ? 600 : nil)
    }

    func answerJoin(approve: Bool) {
        coreHost.answerJoin(approve: approve)
    }

    var pairingProblem: String? {
        if case .pairingRequired(let message) = edgeIssue { return message }
        return nil
    }

    var removalError: String?

    /// Called only after the removal confirmation on the main Mac.
    func forgetMachine(_ id: EdgeID) {
        guard settings.coreRole != .edge, id != localEdgeId,
              setupDirectory.snapshot?.machine(id) != nil else { return }
        do {
            try coreHost.revokeAccess(for: id)
            setupDirectory.forget(id)
            removalError = nil
        } catch {
            removalError = "Dictator couldn’t save the new connection details. No Mac was removed. Check access to Dictator’s files and try again."
        }
    }

    /// Watchdog for the watchdog: the Edge link once sat dead for a whole
    /// day with no socket, no drop line and no reconnect — whatever wedged
    /// it, the cure is the same. If the role says Edge but there is either
    /// no connection object at all (a token read that never came back, a
    /// stale role wiring) or one that has been completely silent for far
    /// longer than its own 10 s keepalive could allow, re-apply the role,
    /// which rebuilds the connection from scratch. Runs on the 5 s health
    /// tick; never fires while the connection's own backoff loop is alive
    /// (every attempt refreshes `lastActivityShared`).
    private static let edgeLivenessLimit: TimeInterval = 90
    private var edgeConnectionStartedAt: Date?
    private var lastEdgeLivenessRecovery: Date = .distantPast

    private func ensureEdgeConnectionAlive() {
        guard settings.coreRole == .edge else { return }
        if edgeConnection?.requiresPairing == true { return }
        let now = Date()
        guard now.timeIntervalSince(lastEdgeLivenessRecovery) > Self.edgeLivenessLimit else { return }
        let quietSince: Date
        if let connection = edgeConnection {
            quietSince = max(connection.lastActivityShared, edgeConnectionStartedAt ?? .distantPast)
        } else {
            switch edgeIssue {
            case .noAddressConfigured, .noPairingToken, .invalidAddress, .pairingRequired:
                return // nothing to retry until settings change
            case .versionMismatch:
                return // the connection keeps retrying; nothing to rebuild until an app is updated
            case .unreachable(let reason) where reason == Self.coreIdentityChangedMessage:
                return // needs an explicit "Forget This Core"
            case .unreachable, .none:
                quietSince = edgeConnectionStartedAt ?? now
            }
        }
        let quietFor = now.timeIntervalSince(quietSince)
        guard quietFor > Self.edgeLivenessLimit else { return }
        lastEdgeLivenessRecovery = now
        SyncDiagnostics.log("edge: link quiet for \(Int(quietFor))s (\(edgeConnection == nil ? "no connection" : "silent connection")), rebuilding")
        applyRole()
    }

    func retrySetup() {
        edgeRuntime.retrySetup()
    }

    /// macOS reclaims everything else at quit, but a CLI the user started
    /// from Datasets would outlive the app.
    func cancelCLIOnQuit() {
        datasetStore?.cancelCLI()
    }

    // MARK: - Role wiring (standalone / core / edge)

    /// Re-applies this Mac's role and connection at setup or after a connection
    /// edit. Shared recording preferences also reach the broker through the
    /// settings observer, without rebuilding the connection.
    func applyRole() {
        applyMicOwnerPreference()
        applyHandsFree()
        edgeRuntime.roleForHealth = settings.coreRole
        syncEngine.setEdgeRole(settings.coreRole == .edge)

        // Every deferred closure/callback created from here on
        // captures this generation; anything still pending from an earlier
        // `applyRole()` becomes a no-op the moment it runs.
        roleGeneration += 1
        let generation = roleGeneration
        pendingLocalEdgeSwitch = nil

        if settings.coreRole != .edge {
            leaveEdgeRoleIfNeeded()
        }

        if settings.coreRole == .edge {
            setupDirectory.stop()
        } else {
            setupDirectory.start()
            setupDirectory.update(edges: coreHost.connectedEdges, coreEdgeId: localEdgeId)
        }

        switch settings.coreRole {
        case .standalone:
            stopWatchingTailscale()
            endEdgeConnection()
            attachLocalEdgeIfNeeded()
            coreHost.stopListening()
        case .core:
            endEdgeConnection()
            attachLocalEdgeIfNeeded()
            startCoreListeningIfPossible()
            startWatchingTailscale()
        case .edge:
            stopWatchingTailscale()
            coreHost.stopListening()
            runWhenIdle(generation: generation) { [weak self] in
                self?.beginEdgeConnection(generation: generation)
            }
        }
        // "Your Shortcuts" is filled on the main Mac when it starts (when a shortcut uses it).
        Task { await VoiceLaunchActing.refreshYourShortcuts(force: false) }
    }

    /// A role change out of Edge must never leave a remote phase
    /// behind. While the (still-open, about-to-be-torn-down) connection is
    /// live, tell the Core this Edge is bailing out of any in-flight session
    /// — best-effort; the Core will also notice the disconnect on its own —
    /// then reset this runtime's own view of the session before the local
    /// edge is reattached. Transitions into Core while a remote session
    /// exists can't happen (this machine wasn't listening); transitions out
    /// of Core are allowed to cancel remote sessions via
    /// `coreHost.stopListening()` — see the Computers tab help text.
    private func leaveEdgeRoleIfNeeded() {
        guard let connection = edgeConnection else { return }
        // Only cancel a session that's actually live on the
        // remote broker — `isLocalEdgeAttached` true means any non-idle
        // phase belongs to a genuinely live standalone-fallback dictation
        // (mid-connect, or the Core has no reachable transport at all right
        // now), which every non-edge branch of `applyRole()` just keeps
        // running on `coreHost` — nothing to cancel here, it finishes on
        // its own. Only when the local edge is already detached (this
        // runtime's session state belongs to `connection`, about to be torn
        // down) is there a live remote session that needs an explicit
        // cancel before the transport under it disappears.
        guard !isLocalEdgeAttached else { return }
        if edgeRuntime.phase != .idle {
            connection.send(.hotkeyCancel)
            edgeRuntime.resetSession(reason: "leaving Edge role")
        }
    }

    private func applyMicOwnerPreference() {
        let id = settings.micOwnerEdgeID.trimmingCharacters(in: .whitespacesAndNewlines)
        coreHost.micOwnerPreference = id.isEmpty ? nil : id
    }

    /// Re-applies `settings.hotkeyHandsFree` onto `coreHost.handsFree`,
    /// which broadcasts it to every connected Edge (see `CoreHost.handsFree`).
    /// Called from `applyRole()` and directly by `GeneralSettingsPage` on
    /// every change to the setting. In Edge role this machine's own hotkey
    /// still reads `edgeRuntime.handsFree` (mirrored from the Core's
    /// `config`, not this local copy) — `coreHost.handsFree` only matters
    /// here for the standalone fallback (see `beginEdgeConnection`'s
    /// idle-deferred local-edge reattachment).
    func applyHandsFree() {
        coreHost.handsFree = settings.hotkeyHandsFree
    }

    /// The welcome's microphone step.
    func requestMicrophoneAccess(completion: (@MainActor (Bool) -> Void)? = nil) {
        edgeRuntime.requestMicrophoneAccess(completion: completion)
    }

    /// The welcome is done: from now on start-up may ask for what's missing.
    func welcomeCompleted() {
        edgeRuntime.promptsForPermissions = true
        retrySetup()
    }

    /// Settings › General changed the key that starts dictation on this Mac;
    /// the running listener uses it from the next press.
    func applyDictationKey() {
        edgeRuntime.hotkeyService.triggers = AppSettings.shared.hotkeyTriggers
    }

    /// The main Mac has gone quiet: take the connection down now and attach
    /// this Mac's own broker, without waiting for the keepalive to notice.
    private func switchToThisMac(dropping connection: CoreConnection) {
        isEdgeConnected = false
        edgeIssue = .unreachable("no answer from main Mac")
        edgeRuntime.resetSession(reason: "main Mac not answering")
        edgeRuntime.isMainMacLive = nil
        edgeRuntime.onMainMacUnreachable = nil
        attachLocalEdgeIfNeeded()
        settingsMirror.stop()
        syncEngine.detach()
        connection.dropAsUnreachable()
    }

    private func attachLocalEdgeIfNeeded() {
        guard !isLocalEdgeAttached else { return }
        coreHost.attachLocalEdge(edgeRuntime)
        isLocalEdgeAttached = true
    }

    private func detachLocalEdgeIfNeeded() {
        guard isLocalEdgeAttached else { return }
        coreHost.detachLocalEdge()
        isLocalEdgeAttached = false
    }

    /// Core role: when this Mac's Tailscale address appears or changes (Tailscale
    /// started after Dictator, or was restarted), start listening again. Never
    /// restarts a listener that is already on the current address, so connected
    /// Macs aren't dropped.
    private func startWatchingTailscale() {
        guard tailscaleWatcher == nil else { return }
        let watcher = TailscaleAddressWatcher(
            needsRetry: { [weak self] in
                guard let self else { return false }
                return self.settings.coreRole == .core && self.coreHost.listeningAddress == nil
            },
            onChange: { [weak self] address in
                guard let self, self.settings.coreRole == .core else { return }
                let boundHost = self.coreHost.listeningAddress?.split(separator: ":").first.map(String.init)
                if address != boundHost { self.startCoreListeningIfPossible() }
            }
        )
        tailscaleWatcher = watcher
        coreHost.onListenerFailed = { [weak self] in self?.tailscaleWatcher?.rearm() }
        watcher.start()
    }

    private func stopWatchingTailscale() {
        tailscaleWatcher?.stop()
        tailscaleWatcher = nil
        coreHost.onListenerFailed = nil
    }

    private func startCoreListeningIfPossible() {
        coreHost.coreName = edgeRuntime.edgeName
        guard let address = TailscaleInterface.currentAddress() else {
            coreHost.stopListening()
            coreHost.listenerWarning = "no Tailscale address found"
            return
        }
        do {
            let token = try LocalSecret.sharedToken(fileName: "core-pairing.token")
            try coreHost.startListening(bindHost: address, token: token)
        } catch {
            coreHost.listenerWarning = error.localizedDescription
        }
    }

    private func endEdgeConnection() {
        edgeConnection?.disconnect()
        edgeConnection = nil
        isEdgeConnected = false
        edgeIssue = nil
        settingsMirror.stop()
        syncEngine.detach()
    }

    /// Standalone fallback lives here: the local edge stays (or becomes)
    /// attached to `coreHost` until `onConnected` actually fires, and comes
    /// back the moment `onDisconnected` does.
    ///
    /// Every callback below re-checks `generation == self.roleGeneration`
    /// and `connection === self.edgeConnection` before touching any shared
    /// state — a callback queued by this specific connection can
    /// otherwise run after a later `applyRole()`/`beginEdgeConnection()` has
    /// already moved on, and act on state (or `nil` out closures) that no
    /// longer belongs to it.
    private func beginEdgeConnection(generation: Int) {
        guard generation == roleGeneration else { return }
        endEdgeConnection()
        attachLocalEdgeIfNeeded()
        edgeConnectionStartedAt = Date()

        let address = settings.coreAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            edgeIssue = .noAddressConfigured
            return
        }
        guard let url = Self.coreURL(for: address) else {
            edgeIssue = .invalidAddress
            return
        }

        // Read the pairing token file off the main thread, then finish
        // wiring on the main actor if this role generation is still current.
        edgeIssue = .unreachable("reading pairing token")
        Task.detached(priority: .userInitiated) { [weak self] in
            let token = try? PairingCredentialStore.token(forCore: address)
            await MainActor.run {
                guard let self, generation == self.roleGeneration else { return }
                guard let token, !token.isEmpty else {
                    self.edgeIssue = .noPairingToken
                    return
                }
                self.openEdgeConnection(generation: generation, address: address, url: url, token: token)
            }
        }
    }

    private func openEdgeConnection(generation: Int, address: String, url: URL, token: String) {
        guard generation == roleGeneration, edgeConnection == nil else { return }

        // Pin the Core's identity the first time this address
        // ever connects successfully, and require later connects to match
        // it — `CoreConnection` is responsible for comparing `expectedCoreId`
        // against the `welcome.coreId` it receives and dropping the
        // connection with reason `"core identity changed"` on a mismatch.
        let expectedCoreId = Self.pairedCoreId(forAddress: address)
        let connection = CoreConnection(
            url: url,
            edgeId: edgeRuntime.edgeId,
            name: edgeRuntime.edgeName,
            token: token,
            capabilities: edgeRuntime.capabilities(),
            expectedCoreId: expectedCoreId, credentialAddress: address
        )
        connection.onConnected = { [weak self, weak connection] coreId, _ in
            Task { @MainActor in
                guard let self, let connection, self.isCurrent(connection, generation: generation) else { return }
                self.edgeDidConnect(connection, coreId: coreId, address: address, generation: generation)
            }
        }
        connection.onDisconnected = { [weak self, weak connection] reason in
            Task { @MainActor in
                guard let self, let connection, self.isCurrent(connection, generation: generation) else { return }
                self.edgeDidDisconnect(connection, reason: reason)
            }
        }
        connection.onSpeechJob = { [weak self, weak connection] job, audio in
            guard let self, let connection, self.isCurrent(connection, generation: generation) else { return }
            self.edgeRuntime.runSpeechJob(job, audio: audio)
        }
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection, self.isCurrent(connection, generation: generation) else { return }
            // `CoreConnection.onMessage` forwards `.pong` too — ignore it.
            if case .pong = message { return }
            // The Core's store changed (its own dictation, another Edge's
            // upload, a Settings edit): replicate. Never part of the session.
            if case .repoChanged(let change) = message {
                self.syncEngine.remoteChanged(change)
                if change == .settings { self.settingsMirror.remoteChanged() }
                return
            }
            // Session frames count only while the main Mac is the active transport.
            self.edgeRuntime.handleRemote(message)
        }

        edgeConnection = connection
        edgeConnectionStartedAt = Date()
        connection.connect()
    }

    /// Whether `connection` is still this Mac's connection to its main Mac
    /// for role `generation`; callbacks from a replaced one are dropped.
    private func isCurrent(_ connection: CoreConnection, generation: Int) -> Bool {
        generation == roleGeneration && connection === edgeConnection
    }

    private func edgeDidConnect(_ connection: CoreConnection, coreId: String, address: String, generation: Int) {
        isEdgeConnected = true
        edgeIssue = nil
        if Self.pairedCoreId(forAddress: address) == nil {
            Self.setPairedCoreId(coreId, forAddress: address)
        }
        // Replication and the settings mirror start the moment the
        // handshake is up — they never touch the live session, so
        // unlike the transport swap below they need no idle gate.
        let client = CoreSyncClient(transport: connection)
        syncEngine.attach(client: client)
        settingsMirror.start(settings: RemoteCoreSettingsRepository(client: client))
        SyncDiagnostics.log("edge: connected to core \(coreId.prefix(8))")
        // On every (re)connect, ask the Core about any
        // of this machine's `uploaded` checkpoints whose outcome
        // this Edge might have missed (disconnected right after
        // handing off the audio, before the idle broadcast landed).
        edgeRuntime.queryOutcomesForUploadedCheckpoints()
        // A fresh `welcome` means the Core sent no
        // session state (it only broadcasts state to edges already
        // known to a session) — but that's only actually stale if
        // this runtime's current session belongs to the remote
        // broker (`isLocalEdgeAttached == false`, meaning this
        // runtime was mid-session against the Core, over a
        // transport that no longer exists, before the drop). If the
        // local edge is still attached, any non-idle phase is a
        // genuinely live standalone-fallback dictation — the whole
        // reason `beginEdgeConnection` keeps it attached through the
        // connect attempt — and resetting it here would cancel a
        // live capture out from under the user. Leave it alone;
        // `runWhenIdle` below defers the transport/repo swap until
        // it naturally goes idle.
        if !isLocalEdgeAttached, edgeRuntime.phase != .idle {
            edgeRuntime.resetSession(reason: "reconnected to Core with no session state")
        }
        // Only swap the local edge over to the remote transport once
        // any in-flight session on this machine has gone idle.
        runWhenIdle(generation: generation) { [weak self, weak connection] in
            guard let self, let connection, self.isCurrent(connection, generation: generation) else { return }
            self.routeEdgeRuntime(through: connection, generation: generation)
        }
    }

    /// Sends this Mac's dictation frames, audio and capability changes to
    /// the main Mac over `connection` instead of to this Mac's own broker.
    private func routeEdgeRuntime(through connection: CoreConnection, generation: Int) {
        detachLocalEdgeIfNeeded()
        edgeRuntime.send = { [weak self, weak connection] message in
            // A refused or failed send is never silent: a key press is
            // retried on this Mac, a lost upload is explained.
            // Name the gesture now: a late failure for an older press is ignored.
            let gesture = self?.edgeRuntime.pendingStart?.id
            let failed: () -> Void = { Task { @MainActor in self?.edgeRuntime.remoteSendFailed(message, gesture: gesture) } }
            if connection?.send(message, onFailure: failed) != true { failed() }
        }
        edgeRuntime.sendAudio = { [weak self, weak connection] header, data in
            let failed: () -> Void = { Task { @MainActor in self?.edgeRuntime.remoteAudioSendFailed() } }
            if connection?.sendAudio(header: header, data: data, onFailure: failed) != true { failed() }
        }
        edgeRuntime.isMainMacLive = { [weak connection] in connection?.isLive ?? false }
        edgeRuntime.onMainMacUnreachable = { [weak self, weak connection] in
            guard let self, let connection, self.isCurrent(connection, generation: generation) else { return }
            self.switchToThisMac(dropping: connection)
        }
        // While connected remotely, capability changes forward to
        // the Core over this connection — the local-edge case is
        // handled by `CoreHost.attachLocalEdge` itself, which
        // re-subscribes this same callback the next time the local
        // edge is attached.
        edgeRuntime.onCapabilitiesChanged = { [weak self, weak connection] caps in
            guard let self, let connection, self.isCurrent(connection, generation: generation) else { return }
            connection.updateCapabilities(caps)
        }
    }

    private func edgeDidDisconnect(_ connection: CoreConnection, reason: String?) {
        isEdgeConnected = false
        if connection.requiresPairing {
            edgeIssue = .pairingRequired(reason ?? CoreConnection.pairingRequiredMessage)
        } else if let mismatch = ProtocolMismatch(reason: reason) {
            edgeIssue = .versionMismatch(mismatch)
        } else {
            edgeIssue = (reason == "core identity changed")
                ? .unreachable(Self.coreIdentityChangedMessage)
                : .unreachable(reason)
        }
        // Reset before re-attaching the local edge — no
        // idle-deferral needed for this path, since the transport
        // that a live session depended on is already gone.
        // Only a session that belongs to the remote broker is stale; a
        // dictation already running on this Mac (the fallback, which a
        // failed retry must not cut off) is left alone.
        if !isLocalEdgeAttached {
            edgeRuntime.resetSession(reason: reason ?? "Core connection lost", connectionLost: true)
        }
        edgeRuntime.isMainMacLive = nil
        edgeRuntime.onMainMacUnreachable = nil
        attachLocalEdgeIfNeeded()
        // A press the main Mac never answered is replayed here (or
        // reported), now that this Mac's own broker is attached.
        edgeRuntime.resolvePendingStartAfterDisconnect()
        settingsMirror.stop()
        syncEngine.detach()
        SyncDiagnostics.log("edge: disconnected (\(reason ?? "no reason"))")
    }

    /// Only a Tailscale-reachable address is accepted for an Edge's Core —
    /// either a `100.64.0.0/10` IPv4 literal (optionally `:port`), or a
    /// MagicDNS `*.ts.net` hostname (optionally `:port`). Anything else (a
    /// LAN IP, a public hostname, an explicit scheme/URL) is rejected before
    /// a socket is ever opened, so a mistyped address can never send the
    /// pairing token or audio off the tailnet. `static` (rather than
    /// `private static`) and internal so `DictatorViewModelRoleTests` can
    /// exercise it directly.
    nonisolated static func coreURL(for address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return nil }

        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts[0])
        let explicitPort = parts.count > 1 ? String(parts[1]) : nil

        guard TailscaleInterface.isTailscaleAddress(host) || TailscaleInterface.isTailnetName(host) else {
            return nil
        }
        if let explicitPort {
            guard let port = UInt16(explicitPort), port > 0 else { return nil }
        }

        let authority = explicitPort != nil ? trimmed : "\(host):\(EdgeProtocol.corePort)"
        return URL(string: "ws://\(authority)")
    }

    // MARK: - Core identity pinning

    private static let coreIdentityChangedMessage = "Core identity changed — re-pair in Settings"
    private static let pairedCoreIdsDefaultsKey = "pairedCoreIds"

    private static func pairedCoreId(forAddress address: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: pairedCoreIdsDefaultsKey) as? [String: String] ?? [:]
        return map[address]
    }

    private static func setPairedCoreId(_ coreId: String, forAddress address: String) {
        var map = UserDefaults.standard.dictionary(forKey: pairedCoreIdsDefaultsKey) as? [String: String] ?? [:]
        map[address] = coreId
        UserDefaults.standard.set(map, forKey: pairedCoreIdsDefaultsKey)
    }

    private static func forgetPairedCoreId(forAddress address: String) {
        var map = UserDefaults.standard.dictionary(forKey: pairedCoreIdsDefaultsKey) as? [String: String] ?? [:]
        map.removeValue(forKey: address)
        UserDefaults.standard.set(map, forKey: pairedCoreIdsDefaultsKey)
    }

    /// "Forget this Core": clears the pinned identity and the saved
    /// pairing token for `address` so the next connect attempt
    /// starts fresh and accepts whatever Core answers (until it's re-pinned
    /// on the next successful connect). Exposed for `ConnectionDetailsView`.
    func forgetCore(at address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Self.forgetPairedCoreId(forAddress: trimmed)
        try? PairingCredentialStore.delete(forCore: trimmed)
        applyRole()
    }

    /// Runs `action` now if this machine's session is idle, otherwise defers
    /// it until `edgeRuntime.phase` next reaches `.idle` — switching the
    /// local↔remote transport mid-session would otherwise cut a live
    /// recording/processing/insert out from under itself. `generation` is
    /// re-checked when the deferred action finally runs: a role
    /// change that happened while this was pending must not run a stale
    /// action.
    private func runWhenIdle(generation: Int, _ action: @escaping () -> Void) {
        guard generation == roleGeneration else { return }
        if edgeRuntime.phase == .idle {
            action()
            return
        }
        pendingLocalEdgeSwitch = action
        observePendingRoleSwitch(generation: generation)
    }

    private func observePendingRoleSwitch(generation: Int) {
        withObservationTracking {
            _ = edgeRuntime.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.roleGeneration, let pending = self.pendingLocalEdgeSwitch else { return }
                if self.edgeRuntime.phase == .idle {
                    self.pendingLocalEdgeSwitch = nil
                    pending()
                } else {
                    self.observePendingRoleSwitch(generation: generation)
                }
            }
        }
    }

    // MARK: - Model preparation at key down

    /// Where a dictation's speech will go, decided the way `transcribe`
    /// decides it, so the warm call reaches the server that will do the work
    /// and carries the refine level it will receive.
    struct SpeechRoute: Equatable {
        /// The speech server that will transcribe, nil when speech runs in the app.
        var serverURL: String?
        /// The level the server will receive (`.exact` when clean-up is
        /// relayed to another Mac, so the server doesn't load a clean-up model).
        var serverRefineLevel: RefineLevel
        /// A clean-up model this Mac's own Ollama will be asked to run.
        var cleanup: (machine: EdgeID, model: String)?

        static func == (a: SpeechRoute, b: SpeechRoute) -> Bool {
            a.serverURL == b.serverURL && a.serverRefineLevel == b.serverRefineLevel
                && a.cleanup?.machine == b.cleanup?.machine && a.cleanup?.model == b.cleanup?.model
        }
    }

    /// Pure routing decision behind `prepareModelsForDictation`.
    static func speechRoute(
        refineLevel: RefineLevel,
        firstSource: SetupRouting.SpeechSource?, chosenCleanup: (machine: EdgeID, model: String)?,
        fallbackCleanup: (machine: EdgeID, model: String)?
    ) -> SpeechRoute {
        if let server = firstSource?.serverURL {
            let relay = refineLevel != .exact ? chosenCleanup : nil
            return SpeechRoute(serverURL: server, serverRefineLevel: relay == nil ? refineLevel : .exact, cleanup: relay)
        }
        return SpeechRoute(serverURL: nil, serverRefineLevel: refineLevel,
                           cleanup: refineLevel != .exact ? fallbackCleanup : nil)
    }

    /// Runs on the Core at key down, whichever Mac was pressed. Starts
    /// loading the speech server's models (and this Mac's own clean-up model
    /// when clean-up runs here) while the user is still speaking. Never
    /// blocks or delays recording; failures are ignored.
    private func prepareModelsForDictation() {
        let route = Self.speechRoute(
            refineLevel: settings.refineLevel,
            firstSource: speechSourcesInOrder().first,
            chosenCleanup: chosenCleanup(),
            fallbackCleanup: cleanupTarget()
        )
        if let server = route.serverURL {
            transcriptionService.warmUp(serverURL: server, refineLevel: route.serverRefineLevel)
        }
        if let cleanup = route.cleanup, cleanup.machine == localEdgeId {
            OllamaClient.preload(model: cleanup.model)
        }
    }

    // MARK: - CoreHost closures (transcribe / recordHistory)

    /// Wraps `TranscriptionService.transcribe`, sending the dictionary, the
    /// active speech binding's setup (or the custom prompt when there is
    /// none), and the settings-selected server/refine level.
    ///
    /// `rawOnly` (Teach) runs the same speech path with the same shortcut
    /// hints, but returns the words exactly as heard: no clean-up, no
    /// dictionary replacements, and no note of which model was used.
    private func transcribe(_ header: AudioTakeHeader, _ data: Data, rawOnly: Bool = false, sourcesOverride: [SetupRouting.SpeechSource]? = nil, postProcess: Bool = true) async throws -> (text: String, inferenceMs: Int?, rawText: String?) {
        // Capture the initiator before any await. Recovery has no matching live session.
        let requestFromOtherMac = coreHost.session.map { $0.id == header.sessionId && $0.initiator != localEdgeId } ?? false
        let audio = CapturedAudio(
            data: data,
            durationSeconds: header.durationSeconds,
            sampleRate: header.sampleRate,
            frameCount: header.frameCount
        )
        let dictionaryEntries = await loadDictionaryEntries()
        let dictionary = Self.activeDictionary(dictionaryEntries)
        // Shortcut mode: the words come back as spoken (no clean-up yet),
        // with the shortcut names as extra prompt words, so the Core can
        // match the start of them (`resolveVoiceCommand`).
        let voiceCommandSession = rawOnly || (coreHost.session?.id == header.sessionId && coreHost.session?.voiceCommandMode == true)
        let hintInput = await vocabularyHintInput(
            entries: dictionaryEntries, forVoiceCommandSession: voiceCommandSession,
            destinationBundleID: coreHost.session.flatMap { $0.id == header.sessionId ? $0.destinationBundleID : nil }
        )
        let vocabulary = VocabularyHint.orderedTerms(hintInput)
        let model = await polishModelLabel()
        let level = settings.refineLevel
        if !rawOnly, polishBySession[header.sessionId] == nil {
            if polishBySession.count > 200 { polishBySession.removeAll() } // sessions that never recorded
            polishBySession[header.sessionId] = CleanupRecord(
                model: model, firstAfterLoad: modelsUsedSinceLaunch.insert(model).inserted,
                level: voiceCommandSession ? nil : level)
        }
        // Who applies the dictionary: the speech server only for a plain
        // dictation with no relayed clean-up. For raw passes (Teach, shortcut
        // words, recovery) it is sent nothing; the finishing step applies it once.
        let serverOwnsReplacements = postProcess && !voiceCommandSession
        let languages = settings.dictationLanguages
        let sources = sourcesOverride ?? speechSourcesInOrder()
        guard !sources.isEmpty else {
            throw DictationFailure(DictationAlert(
                title: "Dictation isn’t set up yet",
                detail: "Nothing is set up to turn your speech into text. Add a speech model to one of your Macs in Settings › Your Macs.",
                action: .macs
            ))
        }
        // Cleanup on a Mac chosen in Your Macs: the server returns the words
        // as spoken and the cleanup is relayed there.
        let relay = postProcess && level != .exact && !voiceCommandSession ? chosenCleanup() : nil
        let serverRefine: RefineLevel = postProcess && relay == nil && !voiceCommandSession ? level : .exact
        let done: (source: SetupRouting.SpeechSource, index: Int, value: SpeechAttempt)
        do {
            // Any failure moves to the next source; a source that takes the
            // audio and never answers is dropped after a limit scaled to the
            // recording (SpeechSourceChain).
            done = try await SpeechSourceChain.run(
                sources: sources,
                audioSeconds: header.durationSeconds,
                reach: { source, timeout in
                    if let server = source.serverURL { try await TranscriptionService.checkReachable(serverURL: server, timeout: timeout) }
                },
                attempt: { [self] source, limit in
                    if let server = source.serverURL {
                        let result = try await transcriptionService.transcribe(
                            audio: audio, serverURL: server, refineLevel: serverRefine,
                            // The server applies replacements only when nothing after it will.
                            dictionary: serverOwnsReplacements && relay == nil ? dictionary : [], languages: languages,
                            vocabularyHint: hintInput, timeout: limit
                        )
                        return SpeechAttempt(text: rawOnly ? (result.rawText ?? result.text) : result.text, inferenceMs: result.inferenceMs, fromServer: true, rawText: result.rawText,
                                             cleanupOutcome: result.cleanupOutcome, cleanupMs: result.cleanupMs)
                    }
                    guard let machine = source.machineId, let speechModel = source.model else { throw TranscriptionError.invalidResponse }
                    let started = Date()
                    let raw: String
                    if RecoverySpeechPlan.runsOnThisMac(machine: machine, localEdgeId: localEdgeId) {
                        // A model on this Mac runs right here: no broker needed.
                        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                        raw = try await LocalSpeechService.shared.transcribe(speechModel, samples: samples, languages: languages, vocabulary: vocabulary)
                    } else {
                        raw = try await coreHost.runSpeech(
                            on: machine, model: speechModel, audio: data, sampleRate: header.sampleRate,
                            languages: languages, vocabulary: vocabulary, timeout: limit
                        )
                    }
                    return SpeechAttempt(text: raw, inferenceMs: Int(Date().timeIntervalSince(started) * 1000), fromServer: false)
                },
                onFallback: { source, error in
                    HotkeyService.recordDiagnostics("speech: \(source.serverURL ?? source.model ?? "source") failed (\(error.localizedDescription)), trying the next one")
                }
            )
        } catch let failed as SpeechSourceChain.Failure {
            throw failure(for: failed.error, source: failed.source, requestFromOtherMac: requestFromOtherMac)
        }
        if done.index > 0 { HotkeyService.recordDiagnostics("speech: used \(done.source.serverURL ?? done.source.model ?? "a source") (not the first choice)") }
        let attempt = done.value
        if attempt.fromServer {
            guard let relay else {
                polishBySession[header.sessionId]?.outcome = attempt.cleanupOutcome
                polishBySession[header.sessionId]?.ms = attempt.cleanupMs
                return (attempt.text, attempt.inferenceMs, attempt.rawText ?? attempt.text)
            }
            let started = Date()
            let cleaned = await cleanUp(attempt.text, dictionary: dictionary, machine: relay.machine, model: relay.model,
                                        level: level, session: header.sessionId)
            return (cleaned, attempt.inferenceMs.map { $0 + Int(Date().timeIntervalSince(started) * 1000) }, attempt.rawText ?? attempt.text)
        }
        // Recovery on a connected Mac finishes the words once, through the main Mac.
        if !postProcess { return (attempt.text, attempt.inferenceMs, attempt.rawText ?? attempt.text) }
        // Words as heard: the clean-up (which applies the dictionary itself) or
        // one direct pass does the replacements, never both. Teach keeps the
        // words exactly as heard.
        if rawOnly { return (attempt.text, attempt.inferenceMs, attempt.rawText ?? attempt.text) }
        let target = level != .exact && !voiceCommandSession ? cleanupTarget() : nil
        if target == nil, level != .exact, !voiceCommandSession { polishBySession[header.sessionId]?.outcome = .unavailable }
        let text = voiceCommandSession ? attempt.text : await TextFinisher.finish(
            attempt.text, dictionary: dictionary,
            cleanUp: target.map { target in { await self.cleanUp($0, dictionary: dictionary, machine: target.machine, model: target.model, level: level, session: header.sessionId) } }
        )
        return (text, attempt.inferenceMs, attempt.rawText ?? attempt.text)
    }

    /// What one speech source returned, before any clean-up.
    private struct SpeechAttempt {
        let text: String
        let inferenceMs: Int?
        let fromServer: Bool
        var rawText: String? = nil
        var cleanupOutcome: CleanupOutcome? = nil
        var cleanupMs: Int? = nil
    }

    /// A dictation is under way, on this Mac or any Mac it serves. A main Mac's
    /// broker holds every Mac's session, so this covers someone speaking into
    /// another Mac; a connected Mac knows its own from the session updates.
    var dictationInProgress: Bool {
        coreHost?.session != nil || edgeRuntime?.hasDictationInProgress == true
    }

    /// Recovery ("Turn Into Text"): the same speech sources, in the same
    /// order, as live dictation, including speech built into the app.
    func recoverTranscribe(_ original: CapturedAudio) async throws -> TranscriptionResult {
        let audio = RecoverySpeechPlan.speechReady(original)
        let header = AudioTakeHeader(sessionId: "recovery-\(UUID().uuidString)", sampleRate: audio.sampleRate,
                                     frameCount: audio.frameCount, durationSeconds: audio.durationSeconds, byteCount: audio.data.count)
        let sources = speechSourcesInOrder()
        let steps = RecoverySpeechPlan.steps(
            role: settings.coreRole, sources: sources,
            localEdgeId: localEdgeId, connectedToMainMac: edgeConnection != nil && isEdgeConnected
        )
        let finishViaMainMac = !RecoverySpeechPlan.sourcesPostProcess(role: settings.coreRole)
        var lastError: Error?
        var configurationError: Error?
        for step in steps {
            do {
                var raw: TranscriptionResult
                switch step {
                case .sources(let stepSources):
                    let result = try await transcribe(header, audio.data, sourcesOverride: stepSources, postProcess: !finishViaMainMac)
                    raw = TranscriptionResult(text: result.text, inferenceMs: result.inferenceMs, rawText: result.rawText)
                case .mainMac:
                    guard let connection = edgeConnection else { continue }
                    // Known limit: this restarts the main Mac's whole source chain, so the
                    // exact source order is not kept across steps (ordering and time only).
                    // The main Mac may try every source, each with a connect check
                    // and its own processing limit; cover all of them.
                    let perSource = SpeechSourceChain.connectTimeout + SpeechSourceChain.processingLimit(audioSeconds: audio.durationSeconds)
                    let text = try await connection.transcribe(
                        audio: audio.data, sampleRate: audio.sampleRate, durationSeconds: audio.durationSeconds,
                        timeout: perSource * Double(max(1, sources.count)) + 10
                    )
                    raw = TranscriptionResult(text: text, inferenceMs: nil)
                }
                guard finishViaMainMac else { return raw }
                // Every connected-Mac result is finished exactly once, here.
                let dictionary = await loadDictionary()
                let target = cleanupTarget()
                let connection = edgeConnection
                let finished = await RecoverySpeechPlan.finishDelegated(
                    raw.text, role: settings.coreRole, dictionary: dictionary, refineLevel: settings.refineLevel,
                    askMainMac: connection.map { connection in { try await connection.cleanUpText($0, useAI: $1) } },
                    cleanUp: target.map { target in { await self.cleanUp($0, dictionary: dictionary, machine: target.machine, model: target.model, level: self.settings.refineLevel) } }
                )
                return TranscriptionResult(text: finished, inferenceMs: raw.inferenceMs, rawText: raw.rawText ?? raw.text)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                let alert = (error as? DictationFailure)?.alert ?? DictationAlert.speechConfigurationFailure(error)
                if configurationError == nil, let alert, alert.action == .advanced {
                    configurationError = DictationFailure(alert)
                }
            }
        }
        if let configurationError { throw configurationError }
        if let lastError { throw lastError }
        throw RecoveryTranscribeError(message: "Nothing is set up to turn this recording into text, or the main Mac isn’t connected. Check Settings › Your Macs.")
    }

    struct RecoveryTranscribeError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Teach: a recording made in the Teach sheet, as words, through the main
    /// Mac's speech path. On a connected Mac that asks the main Mac; on the
    /// main Mac it is the same function. Nothing is pasted or saved.
    func teachTranscribe(_ audio: CapturedAudio) async throws -> String {
        if settings.coreRole == .edge {
            guard let connection = edgeConnection, isEdgeConnected else {
                throw CoreHost.RemoteWorkError.failed("This Mac isn’t connected to your main Mac right now.")
            }
            return try await connection.transcribe(audio: audio.data, sampleRate: audio.sampleRate, durationSeconds: audio.durationSeconds)
        }
        let header = AudioTakeHeader(sessionId: "teach", sampleRate: audio.sampleRate, frameCount: audio.frameCount,
                                     durationSeconds: audio.durationSeconds, byteCount: audio.data.count)
        return try await coreHost.transcribeForTeach(header: header, audio: audio.data)
    }

    /// Voice launch: matches what was said (as spoken, before clean-up)
    /// against the shortcut patterns. On a match, dictionary replacements
    /// apply to every text slot and only the shortcut's clean-up slot is
    /// cleaned up, then the steps are rendered into a plan for the target
    /// Mac. No match keeps everything, cleaned up as usual, with a notice.
    func resolveVoiceCommand(sessionId: SessionID, transcript: String) async -> VoiceCommandResolution {
        let frontmostApp = coreHost.takeCommandAppBundleID(sessionId: sessionId)
        let dictionary = await loadDictionary()
        // The words arrive as heard (no replacements yet). This is the one place
        // they are applied: by the clean-up, or directly when there is none.
        func cleaned(_ text: String) async -> String {
            let target = settings.refineLevel != .exact ? cleanupTarget() : nil
            return await TextFinisher.finish(
                text, dictionary: dictionary,
                cleanUp: target.map { target in { await self.cleanUp($0, dictionary: dictionary, machine: target.machine, model: target.model) } })
        }
        let config = settings.voiceLaunch
        let outcome = VoiceLaunchEngine.match(transcript, in: config, frontmostAppBundleID: frontmostApp)
        guard case .matched(var match) = outcome else {
            let heard = String(transcript.split(whereSeparator: { $0.isWhitespace }).prefix(2).joined(separator: " "))
                .trimmingCharacters(in: VoiceLaunchText.edgeCharacters)
            var title = "No command called “\(heard)”"
            if case .noMatch(.tie(let names)) = outcome {
                title = "More than one command fits “\(heard)”"
                HotkeyService.recordDiagnostics("voicelaunch: tie between \(names.joined(separator: ", "))")
            }
            var detail = "Your words are on the clipboard."
            var nearMiss: VoiceNearMiss?
            if case .noMatch(.noneMatched) = outcome, let miss = VoiceLaunchEngine.nearMiss(for: transcript, in: config, frontmostAppBundleID: frontmostApp) {
                nearMiss = miss
                if miss.kind == .entry {
                    title = "Heard “\(miss.heard)”"
                    detail = "Your words are on the clipboard. Choose who you meant to run “\(miss.commandName ?? "the command")”."
                    HotkeyService.recordDiagnostics("voicelaunch: near miss, name not found in \(miss.listName ?? "a list")")
                } else {
                    HotkeyService.recordDiagnostics("voicelaunch: near miss, no shortcut starts with those words")
                }
            }
            let alert: DictationAlert
            if case .noMatch(.tie(let names)) = outcome {
                alert = .voiceCommandTie(heard: transcript.trimmingCharacters(in: .whitespacesAndNewlines), names: names)
            } else {
                alert = DictationAlert(title: title, detail: detail, tone: .notice)
            }
            let text = await cleaned(transcript)
            return VoiceCommandResolution(text: text, plan: nil, notice: alert.encoded, nearMiss: nearMiss)
        }
        for (name, value) in match.slots {
            guard case .text(let raw) = value else { continue }
            match.slots[name] = .text(name == match.voiceCommand.cleanUpSlot ? await cleaned(raw) : CleanupPrompt.applyReplacements(raw, dictionary: dictionary))
        }
        let plan = VoiceLaunchEngine.render(match, in: config)
        HotkeyService.recordDiagnostics("voicelaunch: matched \(match.voiceCommand.name), \(plan.steps.count) steps, \(plan.mainText.count) chars in the main text")
        return VoiceCommandResolution(text: plan.mainText, plan: plan, notice: nil)
    }

    /// Says in plain words why speech couldn't be turned into text, for the
    /// alert on the Mac the user dictated on.
    private func failure(for error: Error, source: SetupRouting.SpeechSource, requestFromOtherMac: Bool) -> DictationFailure {
        let snapshot = setupDirectory.snapshot ?? setupSnapshot
        let mainName = snapshot?.machines.first(where: \.isCore)?.name
        let serverMac = source.serverURL.flatMap { url in
            ([snapshot?.speech].compactMap { $0 } + (snapshot?.backups ?? [])).first { $0.address == url }
        }
        let serverName = serverMac.flatMap { snapshot?.machineName($0.machineId) }
        if let alert = DictationAlert.speechConfigurationFailure(
            error, requestFromOtherMac: requestFromOtherMac, mainMacName: mainName,
            serverMacName: serverMac?.machineId == localEdgeId ? nil : serverName,
            canReconnect: settings.coreRole == .edge && !isEdgeConnected
        ) { return DictationFailure(alert) }
        let place: String
        if let id = source.machineId {
            place = snapshot?.machineName(id) ?? "your other Mac"
        } else if let serverName {
            place = serverName
        } else {
            place = "the speech server"
        }
        let kept = "What you said is kept in History & Privacy, to turn into text later."
        if !NetworkStatus.shared.isOnline, source.machineId != localEdgeId {
            return DictationFailure(DictationAlert(
                title: "This Mac is offline",
                detail: "Your speech couldn’t be sent to \(place) to be turned into text. \(kept)",
                action: .history
            ))
        }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                return DictationFailure(DictationAlert(title: "\(place.capitalizedFirst) took too long to answer",
                                                       detail: "It may be busy or asleep. \(kept)", action: .history))
            }
            if Self.isUnreachable(urlError) {
                return DictationFailure(DictationAlert(title: BrandVoice.cantReach(place),
                                                       detail: "Check that it’s on, awake and connected to Tailscale. \(kept)", action: .macs))
            }
        }
        if case CoreHost.RemoteWorkError.notConnected = error {
            return DictationFailure(DictationAlert(title: "\(place.capitalizedFirst) isn’t connected",
                                                   detail: "Check that it’s on and Dictator is open there. \(kept)", action: .macs))
        }
        if case SpeechChainError.stalled = error {
            return DictationFailure(DictationAlert(title: "\(place.capitalizedFirst) took too long to answer",
                                                   detail: "It may be busy or asleep. \(kept)", action: .history))
        }
        if case CoreHost.RemoteWorkError.timedOut = error {
            return DictationFailure(DictationAlert(title: "\(place.capitalizedFirst) took too long to answer",
                                                   detail: "It may be busy or asleep. \(kept)", action: .history))
        }
        if case TranscriptionError.serverError(let code, _) = error {
            return DictationFailure(DictationAlert(title: "\(place.capitalizedFirst) couldn’t turn your speech into text",
                                                   detail: "It answered with an error (\(code)) instead of text. \(kept)", action: .history))
        }
        return DictationFailure(DictationAlert(title: "Dictator couldn’t turn your speech into text",
                                               detail: "\(error.localizedDescription) \(kept)", action: .history))
    }

    /// The cleanup Mac and model chosen in Your Macs, if any.
    private func chosenCleanup() -> (machine: EdgeID, model: String)? {
        let routing = settings.setupRouting
        guard let machine = routing.cleanupMachineId, let model = routing.cleanupModel else { return nil }
        return (machine, model)
    }

    /// Who cleans up text that didn't come from the speech server: the
    /// chosen cleanup Mac, else the speech server's own cleanup model on
    /// its Mac (through that Mac's Ollama), when it's online.
    private func cleanupTarget() -> (machine: EdgeID, model: String)? {
        if let chosen = chosenCleanup() { return chosen }
        guard let snapshot = setupDirectory.snapshot ?? setupSnapshot, let speech = snapshot.speech,
              let model = speech.cleanupModel, let id = speech.cleanupMachineId ?? speech.machineId,
              let machine = snapshot.machine(id), machine.online, machine.localModels?.contains(model) == true else { return nil }
        return (id, model)
    }

    /// Cleans up `text` with `model` on `machine`. Anything going wrong
    /// leaves the words exactly as spoken. Dictation passes the chosen level
    /// and its session; workflows and Shortcuts keep to ordinary clean-up,
    /// because their words often go on to be matched or sent.
    func cleanUp(_ text: String, dictionary: [[String: String]], machine: EdgeID, model: String,
                 level: RefineLevel = .medium, session: SessionID? = nil) async -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let started = Date()
        let run = await CleanupPrompt.run(text, dictionary: dictionary, model: model, languages: settings.dictationLanguages, level: level) { job in
            do {
                return try await coreHost.runCleanup(on: machine, job: job)
            } catch {
                HotkeyService.recordDiagnostics("cleanup: on \(machine) failed (\(error.localizedDescription)); used the words as spoken")
                throw error
            }
        }
        switch run.outcome {
        case .rejected: HotkeyService.recordDiagnostics("cleanup: output read as a reply, used the words as spoken")
        case .fellBack: HotkeyService.recordDiagnostics("cleanup: polished output failed its check, used ordinary clean-up")
        case .applied, .unavailable: break
        }
        if let session {
            polishBySession[session]?.outcome = run.outcome
            polishBySession[session]?.ms = Int(Date().timeIntervalSince(started) * 1000)
        }
        return run.text
    }

    /// Runs a sample through a cleanup model (Add an AI model › try it).
    func tryCleanup(sample: String, machine: EdgeID, model: String) async throws -> (text: String, seconds: Double) {
        let started = Date()
        let request = CleanupPrompt.job(for: sample, dictionary: [], model: model, languages: settings.dictationLanguages)
        // Connected to a main Mac, this Mac can only try its own models.
        let output = settings.coreRole == .edge && machine == localEdgeId
            ? try await OllamaClient.chat(request.job, timeout: 120)
            : try await coreHost.runCleanup(on: machine, job: request.job, timeout: 120)
        return (CleanupPrompt.finish(prepared: request.prepared, output: output).text, Date().timeIntervalSince(started))
    }

    /// The bundled sample recording and what it says.
    static let speechSample: (audio: Data, text: String)? = {
        guard let url = Bundle.main.url(forResource: "folders", withExtension: "pcm", subdirectory: "SpeechSample"),
              let data = try? Data(contentsOf: url) else { return nil }
        return (data, "Please bring three blue folders.")
    }()

    /// Runs the sample recording through a speech model (Add an AI model › try it).
    func trySpeech(machine: EdgeID, model: String) async throws -> (text: String, seconds: Double) {
        guard let sample = Self.speechSample else { throw LocalSpeechService.SpeechError.failed("The sample recording is missing.") }
        let started = Date()
        let text: String
        if settings.coreRole == .edge && machine == localEdgeId {
            let samples = sample.audio.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            text = try await LocalSpeechService.shared.transcribe(model, samples: samples, languages: ["en"], vocabulary: [])
        } else {
            text = try await coreHost.runSpeech(on: machine, model: model, audio: sample.audio, sampleRate: 16_000, languages: ["en"], vocabulary: [], timeout: 300)
        }
        return (text, Date().timeIntervalSince(started))
    }

    /// Starts a model download on a Mac in the setup (main Mac only).
    func pullModel(on machine: EdgeID, model: String, onProgress: @escaping (ModelPullProgress) -> Void) throws {
        try coreHost.pullModel(on: machine, model: model, onProgress: onProgress)
    }

    /// Speech sources in order, any the last check found unreachable (a
    /// server not answering, a Mac that's off) moved to the end, so a Mac
    /// that's off doesn't cost a timeout before the next one is tried.
    private func speechSourcesInOrder() -> [SetupRouting.SpeechSource] {
        let sources = settings.speechSources
        guard let snapshot = setupDirectory.snapshot else { return sources }
        let services = [snapshot.speech].compactMap { $0 } + snapshot.backups
        let downServers = Set(services.filter { !$0.reachable }.map(\.address))
        func isDown(_ source: SetupRouting.SpeechSource) -> Bool {
            if let url = source.serverURL { return downServers.contains(url) }
            if let id = source.machineId { return snapshot.machine(id)?.online != true }
            return true
        }
        return sources.filter { !isDown($0) } + sources.filter(isDown)
    }

    private static func isUnreachable(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
         .notConnectedToInternet, .timedOut, .secureConnectionFailed].contains(error.code)
    }

    /// Wraps `saveEntry`, mapping the wire-level `InsertDestination` back to
    /// the `DestinationSnapshot` persistence already understands. The
    /// initiator (whichever Edge pressed the hotkey) becomes the row's
    /// `originEdgeId`.
    /// The model that polishes a take: the active speech setup's cleanup
    /// model, `none` for "Exactly As Spoken", else the server's polish model
    /// (read once from its `/health`).
    private func polishModelLabel() async -> String {
        if settings.refineLevel == .exact { return "none" }
        if settings.setupRouting.cleanupMachineId != nil, let model = settings.setupRouting.cleanupModel { return model }
        if let serverPolishModel { return serverPolishModel }
        if let base = try? SpeechEndpoint.validated(settings.serverURL),
           let data = try? await TranscriptionService.healthData(at: base.appendingPathComponent("health")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let model = json["polish_model"] as? String, !model.isEmpty {
            serverPolishModel = model
            return model
        }
        return "server default"
    }

    private func recordHistory(_ sessionId: SessionID, _ text: String, _ duration: Double, _ inferenceMs: Int?, _ destination: InsertDestination?, initiator: EdgeID) async throws {
        let heard = heardBySession.removeValue(forKey: sessionId) ?? text
        let polish = polishBySession.removeValue(forKey: sessionId)
        let metrics = EntryMetrics(
            latencyMs: destination?.releaseToInsertMs,
            polishModel: polish?.model,
            firstTakeAfterLoad: polish?.firstAfterLoad,
            cleanupLevel: polish?.level?.rawValue,
            cleanupOutcome: polish?.outcome?.rawValue,
            cleanupMs: polish?.ms
        )
        let snapshot = destination.map {
            DestinationSnapshot(
                appBundleId: $0.bundleId,
                appName: $0.appName,
                url: $0.url,
                insertionMethod: $0.insertionMethod,
                context: CaptureContext(
                    toolID: $0.toolId,
                    appBundleID: $0.bundleId,
                    appName: $0.appName,
                    webHost: $0.webHost,
                    url: $0.url,
                    remoteHost: $0.remoteHost,
                    workingDirectory: $0.workingDirectory
                )
            )
        }
        do {
            try await saveEntry(
                text: text,
                duration: duration,
                inferenceMs: inferenceMs,
                modality: "voice",
                source: "dictator",
                destination: snapshot,
                originEdgeId: initiator,
                metrics: metrics,
                entryID: UUID(uuidString: sessionId), heardText: heard
            )
        } catch {
            reportPersistenceIssue(error)
            throw error
        }
    }

    // MARK: - Persistence

    /// Every dictation and typed prompt — this Mac's own, a remote Edge's
    /// session this Core ran, a recovered take — lands in this Mac's store, synchronously
    /// and locally, so nothing is ever lost to a bad moment on the network.
    /// In Edge role the row starts pending and `HistorySyncEngine` uploads
    /// it (idempotently, by id) the moment a Core is reachable.
    private func saveEntry(
        text: String,
        duration: Double,
        inferenceMs: Int?,
        modality: String = "voice",
        source: String = "dictator",
        destination: DestinationSnapshot? = nil,
        surfaceHost: String? = nil,
        originEdgeId: EdgeID? = nil,
        metrics: EntryMetrics = EntryMetrics(),
        entryID: UUID? = nil, heardText: String? = nil
    ) async throws {
        var record = HistoryRecordDTO(
            text: text,
            durationSeconds: duration,
            inferenceMs: inferenceMs,
            modality: modality,
            source: source,
            destinationAppBundleId: destination?.appBundleId,
            destinationAppName: destination?.appName,
            destinationURL: destination?.url,
            insertionMethod: destination?.insertionMethod,
            surfaceHost: surfaceHost ?? destination?.context?.webHost,
            originEdgeId: originEdgeId ?? edgeRuntime.edgeId,
            attribution: PromptAttribution(
                toolId: destination?.context?.toolID,
                captureSource: modality == "voice" ? CaptureSource.voice.rawValue : nil,
                remoteHost: destination?.context?.remoteHost,
                surfaceLabel: destination?.context.map { $0.label() },
                workingDirectory: destination?.context?.workingDirectory
            )
        )
        record.id = entryID
        record.heardText = heardText ?? (modality == "voice" ? text : nil)
        record.metrics = metrics
        try await repositoryHub.current.history.record(record)
        if modality == "voice" { queueDictionaryUsage(text) }
    }

    private func queueDictionaryUsage(_ text: String) {
        guard settings.coreRole != .edge else { return }
        Task { @MainActor [weak self] in
            guard let self, self.settings.coreRole != .edge,
                  let entries = try? await self.repositoryHub.current.dictionary.entries() else { return }
            self.dictionaryUsage.record(text: text, entries: entries)
        }
    }

    /// A prompt from the capture layer (typed, a tool hook, a history file,
    /// a remote server) becomes a history row on this Mac, like any
    /// dictation — replication takes it to the Core.
    private func saveCapturedPrompt(_ prompt: CapturedPrompt) async throws {
        let context = prompt.context
        var record = HistoryRecordDTO(
            text: prompt.text,
            durationSeconds: 0,
            inferenceMs: nil,
            modality: "typed",
            source: prompt.source == .keystrokes || prompt.source == .composer ? "typed" : "connector",
            destinationAppBundleId: context.appBundleID,
            destinationAppName: context.appName ?? context.toolID.flatMap { ToolCatalog.shared.tool(id: $0)?.name },
            destinationURL: context.url,
            insertionMethod: prompt.source.rawValue,
            surfaceHost: context.webHost,
            originEdgeId: edgeRuntime.edgeId,
            attribution: PromptAttribution(
                toolId: context.toolID,
                captureSource: prompt.source.rawValue,
                remoteHost: context.remoteHost,
                surfaceLabel: context.label(),
                workingDirectory: context.workingDirectory,
                sessionId: prompt.sessionID
            )
        )
        record.metrics.typingSeconds = prompt.typingSeconds
        record.timestamp = prompt.timestamp
        try await repositoryHub.current.history.record(record)
    }

    /// One recognition hint for server, local WhisperKit and Apple routes,
    /// including Voice launch and Teach. Metadata comes from the mirrored dictionary.
    func vocabularyHintInput(forVoiceCommandSession: Bool, destinationBundleID: String?) async -> VocabularyHintInput {
        await vocabularyHintInput(entries: await loadDictionaryEntries(), forVoiceCommandSession: forVoiceCommandSession, destinationBundleID: destinationBundleID)
    }

    /// Built from entries the caller already loaded, so a dictation reads the
    /// dictionary once. Installed apps come from caches; nothing here scans
    /// the disk while someone waits for their words.
    func vocabularyHintInput(entries: [DictionaryEntryDTO], forVoiceCommandSession: Bool, destinationBundleID: String?) async -> VocabularyHintInput {
        // Every app name matters when commanding, and only crowds out
        // someone's own words and fields in ordinary dictation.
        if forVoiceCommandSession { VoiceAppHints.refresh() }
        return VocabularyHint.vocabularyHintInput(entries: entries, ownerNames: [NSFullUserName()],
            voiceLaunch: VoiceLaunchEngine.hintWords(settings.voiceLaunch, appNames: forVoiceCommandSession ? VoiceAppHints.names : []),
            forVoiceCommandSession: forVoiceCommandSession, automatic: settings.vocabularyPacksAutomatic,
            on: settings.vocabularyPacksOn, off: settings.vocabularyPacksOff,
            installedBundleIDs: await InstalledApps.bundleIDs(), destinationBundleID: destinationBundleID,
            languages: settings.dictationLanguages)
    }

    /// Explicit History correction: same safety filters, immediate rule.
    @discardableResult
    func learnCorrection(heard: String, corrected: String, entryID: UUID?, selection: HistoryCorrectionSpan? = nil) async -> String {
        await receiveCorrection(CorrectionReport(heard: heard, corrected: corrected, entryID: entryID, explicit: true, selection: selection))
    }

    private func receiveCorrection(_ report: CorrectionReport) async -> String {
        let notSaved = "The correction wasn’t saved. Try again."
        guard RepoServer.validate(.correction(report)) == nil else { return notSaved }
        if report.explicit != true, let context = report.context,
           !settings.correctionObservationAllowed(for: context) { return "" }
        if report.explicit != true && !settings.learnFromCorrections { return "Learning is off." }
        if settings.coreRole == .edge {
            // Ephemeral observation: never an outbox item or offline typed log.
            guard let edgeConnection, isEdgeConnected else { return notSaved }
            let keepSentence = report.explicit == true || (report.context.map { settings.captureDecision(for: $0, modality: "typed").isSave } ?? false)
            do {
                var outcome: CorrectionOutcome?
                for filtered in CorrectionLearningService.reports(report, keepSentence: keepSentence, languages: settings.dictationLanguages) {
                    outcome = try await CoreSyncClient(transport: edgeConnection).learnCorrection(filtered)
                }
                return outcome?.message ?? "Your main Mac received the correction but didn’t report whether it was saved."
            } catch { return "The correction wasn’t saved: \(error.localizedDescription)" }
        }
        do {
            let outcome = try await correctionLearning.receive(report, repositories: repositoryHub.current, settings: settings)
            return outcome.message
        } catch {
            SyncDiagnostics.log("dictionary: learning-save failed count=1")
            return "The correction wasn’t saved: \(error.localizedDescription)"
        }
    }

    func flushDictionaryUsageOnQuit() {
        editWatcher.cancel()
        dictionaryUsage.flush()
    }

    private func loadDictionary() async -> [[String: String]] {
        Self.activeDictionary(await loadDictionaryEntries())
    }

    private func loadDictionaryEntries() async -> [DictionaryEntryDTO] {
        do {
            return try await repositoryHub.current.dictionary.entries()
        } catch {
            reportPersistenceIssue(error)
            return []
        }
    }

    private static func activeDictionary(_ entries: [DictionaryEntryDTO]) -> [[String: String]] {
        DictionaryWords.matching(entries)
    }

    func reportPersistenceIssue(_ message: String) {
        persistenceWarning = message
        NSLog("[Persistence] %@", message)
    }

    private func reportPersistenceIssue(_ error: Error) {
        SyncDiagnostics.log("history: save failed: \(error.localizedDescription)")
        reportPersistenceIssue("Dictator couldn’t save this to History: \(error.localizedDescription)")
    }
}

// MARK: - Shortcuts app actions (Dictate, Clean up text, Run a Command)

extension DictatorViewModel {
    /// What `ShortcutsBridge` uses to reach this Mac's speech path, clean-up,
    /// history and Voice launch. See `DictatorIntents.swift`.
    fileprivate func makeShortcutsServices() -> ShortcutsBridgeServices {
        ShortcutsBridgeServices(
            config: { AppSettings.shared.voiceLaunch },
            listen: { [weak self] in
                guard let self else { throw ShortcutsBridgeError.notReady }
                return try await self.listenForShortcuts()
            },
            finish: { [weak self] text, useAI in
                guard let self else { throw ShortcutsBridgeError.notReady }
                return try await self.finishTextForShortcuts(text, useAI: useAI)
            },
            cleanupAllowed: { AppSettings.shared.refineLevel != .exact },
            cleanupAvailable: { [weak self] in self?.cleanupTarget() != nil },
            saveHistory: { [weak self] record in
                guard let self else { return }
                do {
                    try await self.repositoryHub.current.history.record(record)
                    if record.modality == "voice" { self.queueDictionaryUsage(record.text) }
                } catch { self.reportPersistenceIssue(error) }
            },
            originEdgeId: { [weak self] in self?.edgeRuntime.edgeId },
            runPlan: { [weak self] plan, answered in
                guard let self else { return .stopped(DictationAlert(title: "Dictator isn’t ready yet", detail: "Open Dictator and try again.")) }
                let progress = self.edgeRuntime.launchProgress
                progress.begin(plan)
                let result = await VoiceLaunchExecutor.run(plan, trigger: .otherApp, progress: { progress.apply($0) }, answered: answered)
                progress.end()
                return result
            }
        )
    }

    /// Records one take on this Mac and turns it into words through the main
    /// Mac's speech path, the way Teach does: the same silence endpointer
    /// (2 s of quiet, with its countdown), but a 2-minute limit. The
    /// dictating badge is shown while it records. Nothing is pasted.
    fileprivate func listenForShortcuts() async throws -> ShortcutsHeard {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            throw ShortcutsBridgeError("Dictator can’t use the microphone. Allow it in System Settings › Privacy & Security › Microphone, then try again.")
        }
        if settings.coreRole == .edge {
            guard edgeConnection != nil, isEdgeConnected else {
                throw ShortcutsBridgeError("This Mac isn’t connected to your main Mac right now, so Dictator can’t turn your speech into text. Check that the main Mac is on, then try again.")
            }
        } else if speechSourcesInOrder().isEmpty {
            throw ShortcutsBridgeError("Dictation isn’t set up yet. Add a speech model to one of your Macs in Dictator › Settings › Your Macs, then try again.")
        }
        guard edgeRuntime.phase == .idle else {
            throw ShortcutsBridgeError("Dictator is busy with a dictation. Try again in a moment.")
        }

        let indicator = edgeRuntime.indicator
        let session = VoiceTeachSession(takeCount: 1)
        session.endpointer.maxSeconds = Self.shortcutsRecordingLimit
        session.onPhase = { phase in
            switch phase {
            case .recording: indicator.show()
            case .transcribing: indicator.showProcessing()
            case .ready: indicator.hide()
            }
        }
        session.onTick = { [silence = session.endpointer.silenceSeconds] level, silenceProgress, secondsLeft in
            indicator.updateLevel(level)
            if let silenceProgress {
                indicator.setCountdown(max(1, Int((silence * (1 - silenceProgress)).rounded(.up))))
            } else if secondsLeft <= 5 {
                indicator.setCountdown(secondsLeft)
            } else {
                indicator.setCountdown(nil)
            }
        }
        SoundService.playStart()
        await withTaskCancellationHandler {
            await session.record()
        } onCancel: {
            Task { @MainActor in session.cancel() }
        }
        indicator.hide()
        if Task.isCancelled { throw ShortcutsBridgeError.cancelled }
        guard let text = session.transcripts.first else {
            if let message = session.message { throw ShortcutsBridgeError(ShortcutsBridge.plain(message: message)) }
            throw ShortcutsBridgeError.cancelled
        }
        return ShortcutsHeard(text: text, seconds: session.lastAudioSeconds)
    }

    /// The two-minute limit, as for a dictation.
    fileprivate static let shortcutsRecordingLimit: TimeInterval = 120

    /// Dictionary replacements, then the clean-up model when asked, on the
    /// main Mac (asked over the connection from a connected Mac).
    fileprivate func finishTextForShortcuts(_ text: String, useAI: Bool) async throws -> String {
        do {
            if settings.coreRole == .edge {
                guard let connection = edgeConnection, isEdgeConnected else {
                    throw ShortcutsBridgeError("This Mac isn’t connected to your main Mac right now. Check that the main Mac is on, then try again.")
                }
                return try await connection.cleanUpText(text, useAI: useAI)
            }
            return try await coreHost.cleanUpTextForShortcuts(text, useAI: useAI)
        } catch let error as ShortcutsBridgeError {
            throw error
        } catch {
            throw ShortcutsBridgeError(ShortcutsBridge.plain(error))
        }
    }

    /// On the main Mac: the work behind a connected Mac's request, and this
    /// Mac's own.
    fileprivate func cleanUpTextForShortcuts(_ text: String, useAI: Bool) async throws -> String {
        let dictionary = await loadDictionary()
        // Dictate keeps the words as they are when no clean-up is chosen;
        // the Clean up text action checks first and says so.
        let target = useAI ? cleanupTarget() : nil
        return await TextFinisher.finish(
            text, dictionary: dictionary,
            cleanUp: target.map { target in { await self.cleanUp($0, dictionary: dictionary, machine: target.machine, model: target.model) } })
    }
}

// MARK: - Workspace launch across Macs

extension DictatorViewModel: WorkspaceFleet {
    var localWorkspaceMacID: String? { WorkspaceMacIdentity.key(forSetupID: localEdgeId) }

    var workspaceMacs: [WorkspaceMacOption] {
        let machines = (settings.coreRole == .edge ? setupSnapshot : setupDirectory.snapshot)?.machines ?? []
        return machines.map {
            WorkspaceMacOption(id: WorkspaceMacIdentity.key(forSetupID: $0.id), name: $0.name,
                               online: $0.id == localEdgeId || ($0.online && (settings.coreRole != .edge || isEdgeConnected)))
        }
    }

    var otherMacNames: [String] {
        switch settings.coreRole {
        case .core:
            return coreHost.connectedEdges.filter { $0.id != coreHost.localEdgeID }.map(\.name).sorted()
        case .edge:
            guard isEdgeConnected else { return [] }
            return (setupSnapshot?.machines ?? []).filter { $0.online && $0.id != localEdgeId }.map(\.name).sorted()
        case .standalone:
            return []
        }
    }

    func rememberEverywhere() async throws -> (layouts: [String: WorkspaceSavedLayout], unanswered: [String], busy: [String]) {
        if settings.coreRole == .edge {
            guard let connection = edgeConnection, isEdgeConnected else { throw WorkspaceLaunchError.unavailable("This Mac isn't connected to your main Mac.") }
            return try await connection.rememberWorkspaceEverywhere()
        }
        return await coreHost.rememberWorkspaceEverywhere()
    }

    func runElsewhere(routineID: String, undo: Bool, operationID: String?) async throws -> [WorkspaceRunReport] {
        if settings.coreRole == .edge {
            guard let connection = edgeConnection, isEdgeConnected else { throw WorkspaceLaunchError.unavailable("This Mac isn't connected to your main Mac.") }
            return try await connection.runWorkspaceRoutineElsewhere(routineID, undo: undo, operationID: operationID)
        }
        return await coreHost.runWorkspaceRoutine(routineID, undo: undo, operationID: operationID, except: coreHost.localEdgeID)
    }
}

/// Shared-settings edits can arrive through repositories or directly from a
/// Settings view. Report direct main-Mac edits through the hub; only its
/// settings revision observer broadcasts, preserving the repository path and
/// preventing connected Macs from echoing adopted settings back to the main Mac.
@MainActor
final class CoreSettingsChangeObserver {
    private let settings: AppSettings
    private let hub: RepositoryHub
    private let applySettings: () -> Void
    private let broadcast: () -> Void

    init(settings: AppSettings, hub: RepositoryHub, applySettings: @escaping () -> Void = {}, broadcast: @escaping () -> Void) {
        self.settings = settings
        self.hub = hub
        self.applySettings = applySettings
        self.broadcast = broadcast
        armRevision()
        armLocalSettings()
    }

    private func armRevision() {
        withObservationTracking {
            _ = hub.settingsVersion
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.armRevision()
                guard self.settings.coreRole == .core else { return }
                self.broadcast()
            }
        }
    }

    private func armLocalSettings() {
        withObservationTracking {
            // Every mirrored setting, including ones edited directly by their feature views.
            _ = settings.mirroredSettings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.armLocalSettings()
                if self.settings.coreRole != .edge { self.applySettings() }
                guard self.settings.coreRole == .core else { return }
                self.hub.notifyExternalChange(.settings)
            }
        }
    }
}
