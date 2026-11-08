import Foundation
import Observation

/// While connected as an Edge, mirrors the Core's shared settings — clean-up, history, recording-Mac choice and surface
/// policy onto `AppSettings.shared` so this machine's UI (and everything that reads those directly, like the persist gate
/// and the typed-prompt capture) sees the Core's settings rather than this Mac's own stale ones. On disconnect, mirroring
/// simply stops — the standalone fallback keeps using whatever values were mirrored last.
///
/// Two directions:
/// - Remote → local: `refresh()` runs once on `start(...)` and again on
///   every `remoteChanged()` (a `repo.changed(.settings)` from the Core).
///   It writes into `AppSettings` and `lastKnown*` in the same synchronous
///   stretch, so the local-edit observer below — however late its deferred
///   `Task` runs — always diffs against the value it just wrote and finds
///   no change, so it never echoes this write back to the Core as a `set`.
///   No local→Core write is ever sent until the first `refresh()` has
///   landed (`baselineEstablished`): an edit that races ahead of that
///   baseline is dropped (the baseline write overwrites it anyway).
/// - Local → remote: `withObservationTracking` on the mirrored
///   `AppSettings` properties re-arms itself after every fire and sends a
///   `CoreSettingsPatch` carrying only whichever field(s) actually differ
///   from `lastKnown*`. One `set` runs at a time, and each one is worked
///   out from the settings as they stand, so an older value can never reach
///   the Core after a newer edit. A failed `set` leaves `lastKnown*`
///   unchanged (so the divergence isn't forgotten), retries once after 1s,
///   and only then surfaces `mirrorWarning`. A refresh that lands during a
///   `set` is put off until it ends: it may predate the edit being sent.
@MainActor
@Observable
final class CoreSettingsMirror {
    private var settingsRepository: CoreSettingsRepository?
    /// Bumped by every `start()`/`stop()` so a deferred callback from an
    /// earlier `start()` can never act on state that no longer belongs to
    /// it. Every `await` below re-checks this immediately on resume.
    private var generation = 0

    private var lastKnownRefineLevel: RefineLevel?
    private var lastKnownCustomSystemPrompt: String?
    private var lastKnownPersistHistory: Bool?
    private var lastKnownSurfacePolicyJSON: String?
    private var lastKnownSetupRoutingJSON: String?
    private var lastKnownVoiceLaunchJSON: String?
    private var lastKnownWorkspaceLaunchJSON: String?
    private var lastKnownLearnFromCorrections: Bool?
    private var lastKnownMicOwnerEdgeID: String?
    private var lastKnownVocabularyPacksAutomatic: Bool?
    private var lastKnownVocabularyPacksOn: [String]?
    private var lastKnownVocabularyPacksOff: [String]?

    private var baselineEstablished = false
    private var refreshInFlight = false
    private var needsRefresh = false
    private var sendInFlight = false
    private var needsSend = false
    private var refreshAfterSend = false

    /// Non-nil once a settings write to the Core has failed even after its
    /// one retry. `DictatorViewModel.roleStatus` surfaces this.
    private(set) var mirrorWarning: String?

    /// Idempotent: calling this while already mirroring restarts cleanly
    /// (`stop()` first) rather than layering a second set of callbacks.
    func start(settings: CoreSettingsRepository) {
        stop()
        generation += 1
        let currentGeneration = generation
        settingsRepository = settings

        Task { @MainActor in
            guard self.generation == currentGeneration else { return }
            await self.refresh(generation: currentGeneration)
        }
        armLocalObserver(generation: currentGeneration)
    }

    /// Stops mirroring — deliberately leaves `AppSettings` at whatever it
    /// last mirrored rather than resetting anything.
    func stop() {
        generation += 1
        settingsRepository = nil
        baselineEstablished = false
        refreshInFlight = false
        needsRefresh = false
        sendInFlight = false
        needsSend = false
        refreshAfterSend = false
        lastKnownRefineLevel = nil
        lastKnownCustomSystemPrompt = nil
        lastKnownPersistHistory = nil
        lastKnownSurfacePolicyJSON = nil
        lastKnownSetupRoutingJSON = nil
        lastKnownVoiceLaunchJSON = nil
        lastKnownWorkspaceLaunchJSON = nil
        lastKnownLearnFromCorrections = nil
        lastKnownMicOwnerEdgeID = nil
        lastKnownVocabularyPacksAutomatic = nil
        lastKnownVocabularyPacksOn = nil
        lastKnownVocabularyPacksOff = nil
        mirrorWarning = nil
    }

    /// The Core said its settings changed (`repo.changed(.settings)`).
    func remoteChanged() {
        let currentGeneration = generation
        guard settingsRepository != nil else { return }
        Task { @MainActor in
            guard self.generation == currentGeneration else { return }
            await self.refresh(generation: currentGeneration)
        }
    }

    // MARK: - Remote → local

    /// Serializes overlapping refreshes — a request that arrives while one
    /// is already in flight just sets `needsRefresh` and lets the in-flight
    /// one loop once more rather than starting a second, racing GET.
    private func refresh(generation: Int) async {
        guard generation == self.generation else { return }
        guard !refreshInFlight else {
            needsRefresh = true
            return
        }
        refreshInFlight = true
        defer { refreshInFlight = false }
        repeat {
            needsRefresh = false
            await refreshOnce(generation: generation)
            guard generation == self.generation else { return }
        } while needsRefresh
    }

    private func refreshOnce(generation: Int) async {
        guard let settingsRepository else { return }
        guard let remote = try? await settingsRepository.get() else { return }
        // The GET's generation is re-checked the moment it resumes — a
        // response that lands after `stop()` (or a fresh `start()`) must
        // never write into `AppSettings`.
        guard generation == self.generation else { return }
        guard !sendInFlight else {
            refreshAfterSend = true
            return
        }
        guard let level = RefineLevel.storedValue(remote.refineLevel) else { return }

        // Only touch a field that's actually different from what
        // `AppSettings` currently shows.
        let settings = AppSettings.shared
        if settings.refineLevel != level {
            settings.refineLevel = level
        }
        if settings.customSystemPrompt != remote.customSystemPrompt {
            settings.customSystemPrompt = remote.customSystemPrompt
        }
        if settings.persistHistory != remote.persistHistory {
            settings.persistHistory = remote.persistHistory
        }
        if let policy = remote.surfacePolicyJSON, !policy.isEmpty, settings.cachedSurfacePolicyJSON != policy {
            settings.cachedSurfacePolicyJSON = policy
        }
        if let routing = remote.setupRoutingJSON, !routing.isEmpty, settings.setupRoutingJSON != routing {
            settings.setupRoutingJSON = routing
        }
        if let launch = remote.voiceLaunchJSON, !launch.isEmpty, settings.voiceLaunchJSON != launch {
            settings.voiceLaunchJSON = launch
        }
        if let reset = remote.workspaceLaunchJSON, WorkspaceLaunchConfig.decode(reset) != nil,
           settings.workspaceLaunchJSON != reset {
            settings.workspaceLaunchJSON = reset
        }
        if let value = remote.vocabularyPacksAutomatic, settings.vocabularyPacksAutomatic != value {
            settings.vocabularyPacksAutomatic = value
        }
        if let ids = remote.vocabularyPacksOn, VocabularyPackCatalog.validSelection(ids), settings.vocabularyPacksOn != ids {
            settings.vocabularyPacksOn = ids
        }
        if let ids = remote.vocabularyPacksOff, VocabularyPackCatalog.validSelection(ids), settings.vocabularyPacksOff != ids {
            settings.vocabularyPacksOff = ids
        }
        lastKnownVocabularyPacksAutomatic = settings.vocabularyPacksAutomatic
        lastKnownVocabularyPacksOn = settings.vocabularyPacksOn
        lastKnownVocabularyPacksOff = settings.vocabularyPacksOff
        if let learn = remote.learnFromCorrections { settings.learnFromCorrections = learn }
        lastKnownLearnFromCorrections = settings.learnFromCorrections
        if let id = remote.micOwnerEdgeID, RepoServer.validateMicOwnerEdgeID(id) == nil,
           settings.micOwnerEdgeID != id {
            settings.micOwnerEdgeID = id
        }
        lastKnownMicOwnerEdgeID = settings.micOwnerEdgeID
        lastKnownWorkspaceLaunchJSON = remote.workspaceLaunchJSON?.isEmpty == true ? "" : settings.workspaceLaunchJSON
        lastKnownRefineLevel = level
        lastKnownCustomSystemPrompt = remote.customSystemPrompt
        lastKnownPersistHistory = remote.persistHistory
        lastKnownSurfacePolicyJSON = remote.surfacePolicyJSON ?? settings.cachedSurfacePolicyJSON
        lastKnownSetupRoutingJSON = remote.setupRoutingJSON ?? settings.setupRoutingJSON
        lastKnownVoiceLaunchJSON = remote.voiceLaunchJSON ?? settings.voiceLaunchJSON
        baselineEstablished = true
        // A Core with no workspace routines yet takes this Mac's.
        if remote.workspaceLaunchJSON?.isEmpty == true && !settings.workspaceLaunch.routines.isEmpty {
            await handleLocalChange(generation: generation)
        }
    }

    // MARK: - Local → remote

    private func armLocalObserver(generation: Int) {
        let settings = AppSettings.shared
        withObservationTracking {
            _ = settings.mirroredSettings
        } onChange: { [weak self] in
            // `withObservationTracking`'s registration is consumed the
            // moment `onChange` fires (it's one-shot) — re-arm before
            // handling so a second local edit landing right after this one
            // is still observed. Deferred via `Task`: `onChange` fires
            // synchronously from inside the property's own setter, before
            // the mutation is fully visible.
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.armLocalObserver(generation: generation)
                await self.handleLocalChange(generation: generation)
            }
        }
    }

    /// Serializes sends the way `refresh` serializes GETs: an edit that lands
    /// during a send is picked up by one more pass.
    private func handleLocalChange(generation: Int) async {
        guard generation == self.generation else { return }
        guard baselineEstablished, settingsRepository != nil else { return }
        guard !sendInFlight else {
            needsSend = true
            return
        }
        sendInFlight = true
        repeat {
            needsSend = false
            await sendCurrentChanges(generation: generation, isRetry: false)
            guard generation == self.generation else { return }
        } while needsSend
        sendInFlight = false
        if refreshAfterSend {
            refreshAfterSend = false
            await refresh(generation: generation)
        }
    }

    /// Sends whatever differs from `lastKnown*` right now. The retry comes
    /// back through here, so it carries the newest values, or nothing if the
    /// user has already put the setting back.
    private func sendCurrentChanges(generation: Int, isRetry: Bool) async {
        guard let settingsRepository else { return }

        let settings = AppSettings.shared
        let newRefineLevel = settings.refineLevel
        let newCustomSystemPrompt = settings.customSystemPrompt
        let newPersistHistory = settings.persistHistory
        let newSurfacePolicyJSON = settings.cachedSurfacePolicyJSON
        let newSetupRoutingJSON = settings.setupRoutingJSON
        let newVoiceLaunchJSON = settings.voiceLaunchJSON
        let newWorkspaceLaunchJSON = settings.workspaceLaunchJSON
        let newMicOwnerEdgeID = settings.micOwnerEdgeID
        let newVocabularyPacksAutomatic = settings.vocabularyPacksAutomatic
        let newVocabularyPacksOn = settings.vocabularyPacksOn
        let newVocabularyPacksOff = settings.vocabularyPacksOff

        var patch = CoreSettingsPatch()
        let newLearn = settings.learnFromCorrections
        if newLearn != lastKnownLearnFromCorrections { patch.learnFromCorrections = newLearn }
        if newRefineLevel != lastKnownRefineLevel {
            patch.refineLevel = newRefineLevel.rawValue
        }
        if newCustomSystemPrompt != lastKnownCustomSystemPrompt {
            patch.customSystemPrompt = newCustomSystemPrompt
        }
        if newPersistHistory != lastKnownPersistHistory {
            patch.persistHistory = newPersistHistory
        }
        if newSurfacePolicyJSON != lastKnownSurfacePolicyJSON, !newSurfacePolicyJSON.isEmpty {
            patch.surfacePolicyJSON = newSurfacePolicyJSON
        }
        if newSetupRoutingJSON != lastKnownSetupRoutingJSON, !newSetupRoutingJSON.isEmpty {
            patch.setupRoutingJSON = newSetupRoutingJSON
        }
        if newVoiceLaunchJSON != lastKnownVoiceLaunchJSON, !newVoiceLaunchJSON.isEmpty {
            patch.voiceLaunchJSON = newVoiceLaunchJSON
        }
        if newWorkspaceLaunchJSON != lastKnownWorkspaceLaunchJSON, WorkspaceLaunchConfig.decode(newWorkspaceLaunchJSON) != nil {
            patch.workspaceLaunchJSON = newWorkspaceLaunchJSON
        }
        if newVocabularyPacksAutomatic != lastKnownVocabularyPacksAutomatic {
            patch.vocabularyPacksAutomatic = newVocabularyPacksAutomatic
        }
        if newVocabularyPacksOn != lastKnownVocabularyPacksOn {
            patch.vocabularyPacksOn = newVocabularyPacksOn
        }
        if newVocabularyPacksOff != lastKnownVocabularyPacksOff {
            patch.vocabularyPacksOff = newVocabularyPacksOff
        }
        if newMicOwnerEdgeID != lastKnownMicOwnerEdgeID {
            patch.micOwnerEdgeID = newMicOwnerEdgeID
        }
        guard !patch.isEmpty else { return }

        do {
            try await settingsRepository.set(patch)
            guard generation == self.generation else { return }
            // `lastKnown*` only advances here, never before the send, so a
            // failure leaves the divergence in place.
            lastKnownRefineLevel = newRefineLevel
            lastKnownCustomSystemPrompt = newCustomSystemPrompt
            lastKnownPersistHistory = newPersistHistory
            lastKnownSurfacePolicyJSON = newSurfacePolicyJSON
            lastKnownSetupRoutingJSON = newSetupRoutingJSON
            lastKnownVoiceLaunchJSON = newVoiceLaunchJSON
            lastKnownWorkspaceLaunchJSON = newWorkspaceLaunchJSON
            lastKnownMicOwnerEdgeID = newMicOwnerEdgeID
            lastKnownVocabularyPacksAutomatic = newVocabularyPacksAutomatic
            lastKnownVocabularyPacksOn = newVocabularyPacksOn
            lastKnownVocabularyPacksOff = newVocabularyPacksOff
            lastKnownLearnFromCorrections = newLearn
            mirrorWarning = nil
        } catch {
            guard generation == self.generation else { return }
            guard !isRetry else {
                mirrorWarning = "Settings sync failed"
                return
            }
            try? await Task.sleep(for: .seconds(1))
            guard generation == self.generation else { return }
            await sendCurrentChanges(generation: generation, isRetry: true)
        }
    }
}
