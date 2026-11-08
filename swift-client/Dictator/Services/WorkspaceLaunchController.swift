import AppKit
import Observation

/// The other Macs, for routines that remember or place windows or open tabs.
/// The main Mac does the asking; a connected Mac goes through it.
@MainActor
protocol WorkspaceFleet: AnyObject {
    /// Names of the other Macs connected right now (empty when there are none).
    var otherMacNames: [String] { get }
    var workspaceMacs: [WorkspaceMacOption] { get }
    var localWorkspaceMacID: String? { get }
    /// Every connected Mac's layout (this one included), keyed by `WorkspaceMacIdentity`,
    /// and the names of Macs that didn't answer.
    func rememberEverywhere() async throws -> (layouts: [String: WorkspaceSavedLayout], unanswered: [String], busy: [String])
    /// Has every other connected Mac run (or undo) a routine on its own windows.
    /// `operationID` names the run, so an Undo only reverses that run.
    func runElsewhere(routineID: String, undo: Bool, operationID: String?) async throws -> [WorkspaceRunReport]
}

extension WorkspaceFleet {
    var workspaceMacs: [WorkspaceMacOption] { [] }
    var localWorkspaceMacID: String? { nil }
}

@MainActor
@Observable
final class WorkspaceLaunchController {
    static let shared = WorkspaceLaunchController(adapter: NativeWorkspaceLaunchAdapter())
    private(set) var status = ""
    private(set) var previewLines: [String] = []
    /// Temporary findings from each routine's latest preview or run; never saved.
    private var routinesWithOtherDesktopWindows: Set<String> = []

    func hasWindowsOnAnotherDesktop(routineID: String) -> Bool {
        routinesWithOtherDesktopWindows.contains(routineID)
    }

    private func recordDesktopFinding(_ snapshot: WorkspaceSnapshot, routineID: String) {
        if (snapshot.skipped ?? []).contains(where: { $0.reason == .otherSpace && $0.count > 0 }) {
            routinesWithOtherDesktopWindows.insert(routineID)
        } else {
            routinesWithOtherDesktopWindows.remove(routineID)
        }
    }
    /// The screens and where windows land, for the page to draw. Set by Preview and Run.
    private(set) var previewPicture: WorkspacePreviewPicture?
    /// The routine the preview belongs to, so the page can offer to run it.
    private(set) var previewRoutineID: String?
    private(set) var canRestore = false
    private(set) var isBusy = false
    private(set) var isAccessibilityGranted = false
    private(set) var hotkeyWarnings: [String] = []
    /// Routine id to a plain reason its shortcut is not working (for example another app owns it).
    private(set) var hotkeyFailures: [String: String] = [:]
    private(set) var commandHotkeyFailures: [String: String] = [:]
    private(set) var isRemembering = false
    /// When this Mac started noticing which apps are used (nil while no routine is on).
    /// Only use seen since then counts towards "Hide apps you haven't used".
    private(set) var trackingStartedAt: Date?
    /// The last run stopped partway, so Undo matters more than usual.
    private(set) var lastRunStoppedPartway = false
    /// The run whose changes Undo reverses on this Mac (nil when there are none).
    private(set) var recoveryOrigin: WorkspaceRunOrigin?

    /// Reaches the other Macs for remembered layouts, app placements and tab sets. Nil means this Mac only.
    @ObservationIgnored var fleet: WorkspaceFleet?
    /// This Mac's name as the other Macs see it.
    @ObservationIgnored var macName: () -> String = { Host.current().localizedName ?? "This Mac" }
    /// Injected in tests so synthetic runs never write the person's log.
    @ObservationIgnored var diagnostics: (String) -> Void = { HotkeyService.recordDiagnostics($0) }
    /// The clock, replaceable in tests.
    @ObservationIgnored var now: () -> Date = Date.init
    private(set) var lastRunReachedOtherMacs = false
    /// The other Macs this Mac's last run also reached, for the Undo label.
    private(set) var lastRunOtherMacs: [String] = []
    @ObservationIgnored private var lastRunRoutineID: String?
    /// The id of this Mac's last run, sent with it to the other Macs and
    /// again with its Undo.
    @ObservationIgnored private var lastRunOperationID: String?

    @ObservationIgnored private let adapter: WorkspaceLaunchAdapter
    @ObservationIgnored private let hotkeys: WorkspaceHotkeyRegistering
    @ObservationIgnored private var hotkeyCoordinator: WorkspaceHotkeyCoordinator?
    private(set) var isRecordingShortcut = false
    @ObservationIgnored private var recovery = WorkspaceRecovery()
    @ObservationIgnored private var tracker = WorkspaceTabWindowTracker()
    @ObservationIgnored private var trackedFrames: [String: WorkspaceWindow] = [:]
    @ObservationIgnored private var displays: [WorkspaceDisplay] = []
    @ObservationIgnored private let parkedStore: WorkspaceParkedStore
    @ObservationIgnored private var crashRecords: [WorkspaceParkedRecord] = []
    @ObservationIgnored private var returnRequested = false
    @ObservationIgnored private var rescueScheduled = false
    private(set) var parkedWindowCount = 0
    @ObservationIgnored private var recoveryOpenedApps = false
    @ObservationIgnored private var recoveryTabsOpened = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var permissionObserver: NSObjectProtocol?
    @ObservationIgnored private var lastActivatedAt: [String: Date] = [:]
    @ObservationIgnored private var previousAppID: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let macID: () -> String

    init(adapter: WorkspaceLaunchAdapter, settings: AppSettings = .shared, macID: @escaping () -> String = { WorkspaceMacIdentity.current },
         hotkeys: WorkspaceHotkeyRegistering? = nil, parkedStore: WorkspaceParkedStore? = nil) {
        self.hotkeys = hotkeys ?? WorkspaceHotkeyRegistry()
        self.adapter = adapter
        self.settings = settings
        self.macID = macID
        let underTest = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let defaultURL = underTest
            ? FileManager.default.temporaryDirectory.appendingPathComponent("DictatorTests-\(UUID().uuidString)/workspace-parked.json")
            : URL.applicationSupportDirectory.appendingPathComponent("Dictator/workspace-parked.json")
        self.parkedStore = parkedStore ?? WorkspaceParkedStore(url: defaultURL)
    }

    func start() {
        guard !started else { return }
        started = true
        crashRecords = parkedStore.load()
        scheduleRescue()
        hotkeys.onTrigger = { [weak self] id in
            guard let self, !self.isRecordingShortcut else { return }
            self.run(routineID: id, trigger: "keyboard")
        }
        hotkeys.onCommandTrigger = { [weak self] id in
            guard let self, !self.isRecordingShortcut,
                  let command = self.settings.voiceLaunch.commands.first(where: { $0.id == id }) else { return }
            Task { @MainActor in
                guard !self.isRecordingShortcut else { return }
                await VoiceCommandTriggerController.shared.run(command, trigger: .keyboard)
            }
        }
        let coordinator = WorkspaceHotkeyCoordinator(registry: hotkeys,
            routines: { [settings] in settings.workspaceLaunch.routines },
            commands: { [settings] in settings.voiceLaunch.commands })
        coordinator.onRegistration = { [weak self] registration in self?.recordHotkeyRegistration(registration) }
        hotkeyCoordinator = coordinator
        coordinator.start()
        syncConfiguration()
        observeSettings()
        if !crashRecords.isEmpty {
            let token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshPermission() }
            }
            permissionObserver = token
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.workspaceLaunchJSON
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.observeSettings()
                self.syncConfiguration()
            }
        }
    }

    private func syncConfiguration() {
        if settings.workspaceLaunch.routines.contains(where: \.enabled) {
            beginTracking()
        } else {
            stopTracking()
        }
    }

    private func recordHotkeyRegistration(_ registration: WorkspaceHotkeyRegistry.Registration) {
        hotkeyFailures = registration.failures
        commandHotkeyFailures = registration.commandFailures
        if let general = registration.general.first {
            for command in settings.voiceLaunch.commands where command.enabled && command.hotkey != nil {
                commandHotkeyFailures[command.id] = commandHotkeyFailures[command.id] ?? general
            }
        }
        hotkeyWarnings = registration.general + settings.workspaceLaunch.routines.compactMap { routine in
            registration.failures[routine.id].map { "\(routine.name): \($0). Choose another shortcut." }
        }
    }

    /// Called when the shortcut recorder starts listening: turns off every routine
    /// shortcut and dictation start. Always pair with `endShortcutRecording()`.
    func beginShortcutRecording() {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true
        hotkeyCoordinator?.suspend()
        HotkeyService.isRecordingWorkspaceShortcut = true
    }

    /// Safe to call on every exit path (it does nothing when not recording).
    func endShortcutRecording() {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        HotkeyService.isRecordingWorkspaceShortcut = false
        hotkeyCoordinator?.resume()
    }

    /// Track app activation events only while there is an enabled routine.
    /// No titles, contents, keyboard input, polling, or model inference.
    private func beginTracking() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared
        let now = self.now()
        trackingStartedAt = now
        for app in workspace.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier { lastActivatedAt[id] = now }
        }
        previousAppID = workspace.frontmostApplication?.bundleIdentifier
        if previousAppID == Bundle.main.bundleIdentifier { previousAppID = nil }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier else { return }
                Task { @MainActor in
                    guard let self, !self.observers.isEmpty else { return }
                    if name == NSWorkspace.didTerminateApplicationNotification {
                        self.lastActivatedAt.removeValue(forKey: id)
                        if self.previousAppID == id { self.previousAppID = nil }
                    } else {
                        self.lastActivatedAt[id] = self.now()
                        if name == NSWorkspace.didActivateApplicationNotification, id != Bundle.main.bundleIdentifier {
                            self.previousAppID = id
                        }
                    }
                }
            }
            observers.append(token)
        }
    }

    private func stopTracking() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        lastActivatedAt.removeAll()
        previousAppID = nil
        trackingStartedAt = nil
    }

    /// Whether this Mac has what the routine needs to run or preview.
    func canRun(_ routine: WorkspaceRoutine) -> Bool { isAccessibilityGranted || routine.onlyOpensTabs(macID: macID(), aliases: macAliases) }
    func refreshPermission() {
        isAccessibilityGranted = adapter.isAccessibilityGranted
        if isAccessibilityGranted && !crashRecords.isEmpty { scheduleRescue() }
    }
    func requestPermission() {
        adapter.requestPermission()
        refreshPermission()
        if !isAccessibilityGranted { status = "In System Settings › Privacy & Security › Accessibility, turn on Dictator, then come back here." }
    }

    @discardableResult
    func saveRoutine(_ routine: WorkspaceRoutine) -> Bool {
        var routine = routine
        for index in routine.actions.indices {
            routine.actions[index].remembered = routine.actions[index].remembered?.mapValues { layout in
                var saved = layout
                saved.browsers = nil
                saved.captureError = nil
                return saved
            }
        }
        guard settings.workspaceLaunchJSON.isEmpty || WorkspaceLaunchConfig.decodeForEditing(settings.workspaceLaunchJSON) != nil else {
            status = "Dictator couldn't read your saved routines and left them as they were."
            return false
        }
        var config = settings.workspaceLaunch
        if let index = config.routines.firstIndex(where: { $0.id == routine.id }) {
            config.routines[index] = routine
        } else {
            config.routines.append(routine)
        }
        if let key = routine.hotkey, let problem = VoiceCommandHotkeys.conflict(key, commands: settings.voiceLaunch.commands) {
            status = problem
            return false
        }
        guard config.encoded() != nil else {
            status = config.validate().first ?? "This routine is too large to save."
            return false
        }
        guard settings.updateWorkspaceLaunch({ $0 = config }) else { return false }
        clearPreview()
        status = "Saved \(routine.name)."
        return true
    }

    var savedSettingsWarning: String? {
        let raw = settings.workspaceLaunchJSON
        guard !raw.isEmpty, WorkspaceLaunchConfig.decode(raw) == nil else { return nil }
        if WorkspaceLaunchConfig.decodeForEditing(raw) != nil {
            return "Some saved shortcuts are no longer supported and were removed. Those routines are off. Edit each one to choose a new shortcut, then turn it on."
        }
        return "Dictator couldn't read your saved routines and left them as they were."
    }

    var canClearUnreadableSettings: Bool {
        !settings.workspaceLaunchJSON.isEmpty && WorkspaceLaunchConfig.decodeForEditing(settings.workspaceLaunchJSON) == nil
    }

    func resetSavedRoutines() {
        // Explicit reset also clears stale links when the routine JSON is unreadable.
        let ids = Set(settings.voiceLaunch.commands.flatMap { $0.steps }
            .filter { $0.kind == .runWorkspace }.compactMap(\.workspaceId))
        settings.updateVoiceLaunch { voice in
            for id in ids { VoiceWorkspaceLink.remove(id, from: &voice) }
        }
        settings.workspaceLaunchJSON = WorkspaceLaunchConfig.empty.encoded() ?? ""
        clearPreview()
        status = "Saved routines cleared."
    }

    func deleteRoutine(id: String) {
        guard settings.updateWorkspaceLaunch({ $0.routines.removeAll { $0.id == id } }) else {
            status = "Dictator couldn't read your saved routines and left them as they were."
            return
        }
        clearPreview()
        status = "Routine deleted."
    }

    func preview(routineID: String) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false; scheduleRescue(); adapter.retainWindows(ids: recovery.windowIDs.union(tracker.windowIDs)) }
            do {
                let (routine, snapshot, plan) = try await prepare(routineID: routineID, preview: true)
                recordDesktopFinding(snapshot, routineID: routine.id)
                showPreview(plan, snapshot: snapshot, routineID: routine.id)
                let placements = routine.actions.flatMap { $0.placements ?? [] }.filter { !$0.isLocal(macID(), aliases: macAliases) }
                for name in Set(placements.map(\.macName)).sorted() {
                    previewLines.append("On \(name): " + placements.filter { $0.macName == name }.map(\.description).joined(separator: "; "))
                }
                let remembered = routine.actions.compactMap(\.remembered).flatMap { layouts in
                    layouts.filter { !placementIsLocal($0.key) }.map(\.value.macName)
                }.filter { name in !placements.contains { $0.macName == name } }
                let rememberedNames = Array(Set(remembered)).sorted()
                if !rememberedNames.isEmpty { previewLines.append("Run also puts the windows back on \(WorkspaceWords.list(rememberedNames)).") }
                status = BrandVoice.previewOnly
            } catch {
                clearPreview()
                status = error.localizedDescription
            }
        }
    }

    func run(routineID: String, trigger: String = "click") {
        guard !isBusy else {
            _ = rejectedRun(routineID: routineID, trigger: trigger, summary: Self.captureBusyMessage, failure: Self.captureBusyMessage)
            return
        }
        isBusy = true
        let operationID = UUID().uuidString
        Task { @MainActor in _ = await performRun(routineID: routineID, fanOut: true, from: nil, operationID: operationID, trigger: trigger) }
    }

    /// Shares the normal run and fleet fan-out, but returns only after they finish.
    /// The voice executor can then stop on an actual failure, or continue in order.
    func runAwaiting(routineID: String) async throws {
        guard !isBusy else {
            _ = rejectedRun(routineID: routineID, trigger: "voice", summary: Self.captureBusyMessage, failure: Self.captureBusyMessage)
            throw WorkspaceLaunchError.unavailable(Self.captureBusyMessage)
        }
        isBusy = true
        let operationID = UUID().uuidString
        let outcome = await performRun(routineID: routineID, fanOut: true, from: nil, operationID: operationID, trigger: "voice")
        if let failure = outcome.failure { throw WorkspaceLaunchError.unavailable(failure) }
    }

    /// Runs a routine on this Mac (the caller has set `isBusy`) and, when it
    /// has steps for other Macs and `fanOut` is set, asks those Macs to run
    /// their steps at the same time. Returns what happened here,
    /// without the routine's name, for a Mac that asked from elsewhere.
    private func performRun(routineID: String, fanOut: Bool, from: String?, operationID: String?, trigger: String = "remote") async -> WorkspaceRunOutcome {
        let operationID = operationID ?? UUID().uuidString
        let startedAt = adapter.monotonicTime
        let frontBundleID = adapter.frontmostBundleID == adapter.dictatorBundleID ? previousAppID : adapter.frontmostBundleID
        let routine = settings.workspaceLaunch.routines.first { $0.id == routineID }
        let containsTabs = routine?.actions.contains(where: \.isTabStep) == true
        var counts = WorkspaceRunCounts()
        var localFailure: String?
        logStart(routineID: routineID, operationID: operationID, undo: false, from: from, trigger: trigger)
        defer {
            logEnd(routineID: routineID, operationID: operationID, undo: false, startedAt: startedAt, counts: counts, failure: localFailure, redactFailure: containsTabs)
            isBusy = false
            scheduleRescue()
            adapter.retainWindows(ids: recovery.windowIDs.union(tracker.windowIDs))
        }
        let others = fanOut ? routine.map { otherMacs(in: $0) } ?? [] : []
        let ownsUndo = routine?.hasWindowSteps == true || routine?.showOnly == true
        if ownsUndo {
            lastRunRoutineID = routineID
            lastRunOperationID = operationID
            lastRunStoppedPartway = false
        }
        let elsewhere: Task<Result<[WorkspaceRunReport], Error>, Never>? = others.isEmpty || fleet == nil ? nil : Task { @MainActor in
            do { return .success(try await self.fleet!.runElsewhere(routineID: routineID, undo: false, operationID: operationID)) } catch { return .failure(error) }
        }
        var outcome: String
        var failureMessage: String?
        let lateTabs = routine?.tabActions(afterLastWindowStep: true).flatMap { $0.tabSets ?? [] }
            .contains { $0.isLocal(macID(), aliases: macAliases) } == true
        let stoppedTabsNote = "Tabs after that step didn't open because the routine stopped."
        do {
            // Recompute at execution time: never apply stale preview handles.
            refreshPermission()
            guard let configured = routine, configured.enabled else { throw WorkspaceLaunchError.unavailable("This routine is off. Turn it on to run it.") }
            guard isAccessibilityGranted || configured.onlyOpensTabs(macID: macID(), aliases: macAliases) else { throw WorkspaceLaunchError.unavailable("Allow Dictator to move windows first (step 1).") }
            let origin = WorkspaceRunOrigin(operationID: operationID, routineID: routineID, routineName: configured.name, fromMac: from)
            var shown: [String] = [], showingNotes: [String] = []
            // A browser hidden by another group has to show to bring its window
            // back, even in a routine that hides nothing itself.
            let appsToShow = configured.showsOnlyItsWindows(macID: macID(), aliases: macAliases)
                ? configured.groupApps(macID: macID(), aliases: macAliases)
                : Array(Set(tracker.windows.values.filter { $0.routineID == routineID }.map(\.bundleID))).sorted()
            do {
                for id in appsToShow {
                    do { if try await adapter.showApp(bundleID: id) { shown.append(id) } }
                    catch { showingNotes.append("An app in this routine couldn't be shown.") }
                }
                if !shown.isEmpty {
                    recovery = WorkspaceRecovery(shownBundleIDs: shown, frontBundleID: frontBundleID)
                    recoveryOrigin = origin
                    recoveryOpenedApps = false
                    recoveryTabsOpened = false
                    canRestore = true
                }
            }
            let opened = await WorkspaceLaunchExecutor.openMissing(in: configured, macID: macID(), aliases: macAliases,
                                                                 macName: macName(), adapter: adapter)
            var tabs = await WorkspaceLaunchExecutor.openTabSets(in: configured, macID: macID(), aliases: macAliases,
                macName: macName(), adapter: adapter, deadline: startedAt + VoiceLaunchReadiness.workspaceRunBudget - 10, afterLastWindowStep: false,
                tracker: tracker, routines: settings.workspaceLaunch.routines)
            acceptTabs(tabs)
            if !tabs.moved.isEmpty {
                recovery = WorkspaceRecovery(windows: tabs.moved, shownBundleIDs: shown, frontBundleID: frontBundleID)
                recoveryOrigin = origin
                canRestore = true
            }
            var openedApps = opened.opened.union(tabs.started)
            counts.appsOpened = openedApps.count
            counts.tabsOpened = tabs.tabsOpened > 0 ? tabs.tabsOpened : nil
            // Tabs can't be undone, so opening only tabs leaves the Undo of an
            // earlier run in place.
            if !opened.opened.isEmpty {
                recovery = WorkspaceRecovery(windows: tabs.moved, shownBundleIDs: shown, frontBundleID: frontBundleID)
                recoveryOpenedApps = !openedApps.isEmpty
                recoveryTabsOpened = tabs.tabsOpened > 0
                recoveryOrigin = origin
                canRestore = true
            }
            var prepared = try await prepare(routineID: routineID, configured: configured, unavailableApps: opened.unavailable, appNotes: opened.notesByApp)
            let candidates = WorkspaceLaunchExecutor.windowsToBringBack(in: configured, snapshot: prepared.1, macID: macID(), aliases: macAliases)
            counts.record(prepared.1.skipped ?? [])
            // Preserve the existing 60-second run budget, including the extra
            // capture. Leave two seconds for recapture and five for movement.
            let preparationDeadline = startedAt + VoiceLaunchReadiness.workspaceRunBudget - 7
            let broughtBack = await WorkspaceLaunchExecutor.bringBack(candidates, adapter: adapter, deadline: preparationDeadline)
            counts.windowsBroughtBack = broughtBack.windows.count
            // Save before recapturing: even a capture failure must leave Undo.
            if !broughtBack.windows.isEmpty || !opened.opened.isEmpty || !shown.isEmpty || !tabs.moved.isEmpty {
                recovery = WorkspaceRecovery(windows: tabs.moved + broughtBack.windows, shownBundleIDs: shown, frontBundleID: frontBundleID)
                recoveryOpenedApps = !openedApps.isEmpty
                recoveryTabsOpened = tabs.tabsOpened > 0
                recoveryOrigin = origin
                canRestore = !recovery.isEmpty || !opened.opened.isEmpty
            }
            if !candidates.isEmpty {
                prepared = try await prepare(routineID: routineID, configured: configured, unavailableApps: opened.unavailable,
                                             appNotes: opened.notesByApp.merging(broughtBack.notes) { $0 + " " + $1 })
            }
            let (_, snapshot, preparedPlan) = prepared
            var plan = preparedPlan
            plan.addNotes(tabs.notes + showingNotes)
            recordDesktopFinding(snapshot, routineID: routineID)
            showPreview(plan, snapshot: snapshot, routineID: nil)
            counts.skips = [:]
            counts.record(snapshot.skipped ?? [])
            for app in configured.actions.filter({ $0.kind == .arrangeWindows && !$0.isTabStep }).flatMap({ $0.localApps(macID(), aliases: macAliases) }) {
                if !snapshot.windows.contains(where: { $0.bundleID == app.id }) && !(snapshot.skipped ?? []).contains(where: { $0.bundleID == app.id }) {
                    let reason = adapter.isAppRunning(bundleID: app.id) ? "noWindow" : "closed"
                    counts.skips[reason, default: [:]][app.id] = 1
                }
            }
            var result = await WorkspaceLaunchExecutor.applyCooperatively(plan, snapshot: snapshot, adapter: adapter, deadline: startedAt + VoiceLaunchReadiness.workspaceRunBudget) { id in
                self.lastActivatedAt[id] == snapshot.applications.first { $0.bundleID == id }?.lastActivatedAt
            }
            for operation in plan.operations {
                if case .moveWindow(let id, let frame) = operation, result.movedWindowIDs.contains(id),
                   var window = trackedFrames[id] {
                    window.frame = frame
                    trackedFrames[id] = window
                }
            }
            plan.addNotes(result.notes)
            let hiddenCount = result.recovery.hiddenBundleIDs.count
            if hiddenCount > 0, configured.showsOnlyItsWindows(macID: macID(), aliases: macAliases) {
                plan.addNotes([hiddenCount == 1 ? "Hid 1 other app." : "Hid \(hiddenCount) other apps."])
            }
            // Save apply recovery before the next capture or tab launch can fail.
            if !result.recovery.isEmpty || !shown.isEmpty || !tabs.moved.isEmpty || !broughtBack.windows.isEmpty {
                recovery = result.recovery.merging(originals: tabs.moved + broughtBack.windows, shown: shown, front: frontBundleID)
                recoveryOrigin = origin
                canRestore = true
            }
            if configured.showsOnlyItsWindows(macID: macID(), aliases: macAliases) {
                let parked = await parkOtherGroups(for: configured, usable: usableApps(in: snapshot, for: configured))
                result.completed += parked.completed
                result.movedWindowIDs.formUnion(parked.movedWindowIDs)
                plan.addNotes(parked.notes)
                for window in parked.recovery.windows where !result.recovery.windowIDs.contains(window.id) {
                    result.recovery.windows.append(window)
                }
            }
            if let stack = result.stack {
                diagnostics(stack.diagnostic)
                plan.addNotes(stack.notes)
            }
            if result.failures.isEmpty {
                let late = await WorkspaceLaunchExecutor.openTabSets(in: configured, macID: macID(), aliases: macAliases,
                    macName: macName(), adapter: adapter, deadline: startedAt + VoiceLaunchReadiness.workspaceRunBudget,
                    afterLastWindowStep: true, tracker: tracker, routines: settings.workspaceLaunch.routines)
                tabs.merge(late)
                acceptTabs(late)
            } else if lateTabs {
                plan.addNotes([stoppedTabsNote])
            }
            openedApps.formUnion(tabs.started)
            counts.appsOpened = openedApps.count
            counts.tabsOpened = tabs.tabsOpened > 0 ? tabs.tabsOpened : nil
            plan.addNotes(tabs.notes)
            counts.windowsMoved = result.movedWindowIDs.union(tabs.movedWindowIDs).count
            if !result.recovery.isEmpty || !broughtBack.windows.isEmpty || !opened.opened.isEmpty || !shown.isEmpty || !tabs.moved.isEmpty {
                recovery = result.recovery.merging(originals: tabs.moved + broughtBack.windows, shown: shown, front: frontBundleID)
                recoveryOpenedApps = !openedApps.isEmpty
                recoveryTabsOpened = tabs.tabsOpened > 0
                recoveryOrigin = origin
                canRestore = !recovery.isEmpty || !opened.opened.isEmpty
            }
            if tabs.tabsOpened > 0, result.completed > 0 || counts.windowsBroughtBack > 0 || !result.failures.isEmpty {
                plan.addNotes(["Opened \(WorkspaceTabWords.count(tabs.tabsOpened))."])
            }
            if !result.failures.isEmpty { lastRunStoppedPartway = !result.recovery.isEmpty }
            (outcome, failureMessage) = Self.summary(of: result, plan: plan, tabs: tabs, windowsBroughtBack: counts.windowsBroughtBack)
            if tabs.tabsOpened == 0,
               configured.actions.flatMap({ $0.tabSets ?? [] }).contains(where: { $0.isLocal(macID(), aliases: macAliases) }) {
                failureMessage = ([failureMessage, tabs.failure(macName: macName())].compactMap { $0 }).joined(separator: " ")
                if failureMessage?.isEmpty == true { failureMessage = nil }
            }
        } catch {
            outcome = error.localizedDescription
            failureMessage = outcome
            if lateTabs { outcome += "\n" + stoppedTabsNote }
        }
        localFailure = failureMessage
        status = "\(macName()): " + outcome
        // Keep the existing fleet Undo route for every requested remote run,
        // even a reply that timed out after it may already have moved windows.
        if ownsUndo {
            lastRunReachedOtherMacs = elsewhere != nil
            lastRunOtherMacs = elsewhere != nil ? others : []
        }
        failureMessage = await reportOtherMacs(elsewhere, others: others, routine: routine,
                                               routineID: routineID, operationID: operationID, failure: failureMessage)
        return WorkspaceRunOutcome(summary: outcome, failure: failureMessage, counts: counts)
    }

    /// Adds each other Mac's report, or why it wasn't reached, to `status`
    /// and returns `failure` with theirs added.
    private func reportOtherMacs(_ elsewhere: Task<Result<[WorkspaceRunReport], Error>, Never>?, others: [String],
                                 routine: WorkspaceRoutine?, routineID: String, operationID: String, failure: String?) async -> String? {
        var failureMessage = failure
        var reportedRemoteNames = Set<String>()
        if let elsewhere {
            switch await elsewhere.value {
            case .success(let reports):
                reportedRemoteNames = Set(reports.map(\.macName))
                for report in reports {
                    if report.counts?.skips[WorkspaceSkipReason.otherSpace.rawValue]?.values.contains(where: { $0 > 0 }) == true {
                        routinesWithOtherDesktopWindows.insert(routineID)
                    }
                    logRemote(report, routineID: routineID, operationID: operationID, undo: false)
                    status += "\n" + report.macName + ": " + report.summary
                }
                let failures = reports.compactMap { safeRemoteFailure($0, routine: routine) }
                if !failures.isEmpty { failureMessage = ([failureMessage].compactMap { $0 } + failures).joined(separator: " ") }
            case .failure(let error):
                let message = "Your other Macs weren't reached: \(error.localizedDescription)"
                status += " " + message
                failureMessage = failureMessage ?? message
            }
            // A tab-only run has no reversible remote window changes either.
            let hasRemoteWindowSteps = routine?.actions.contains { action in
                (action.remembered ?? [:]).keys.contains { !placementIsLocal($0) }
                    || (action.placements ?? []).contains { !$0.isLocal(macID(), aliases: macAliases) }
            } ?? false
            canRestore = canRestore || hasRemoteWindowSteps || (routine?.showOnly == true && !others.isEmpty)
        }
        if let routine {
            // A disconnected Mac is absent from the fleet's replies. Name its apps,
            // including when there is no connection to the main Mac at all.
            let reached = reportedRemoteNames
            for other in others where !reached.contains(other) {
                let apps = routine.actions.flatMap { $0.placements ?? [] }.filter { $0.macName == other && !$0.isLocal(macID(), aliases: macAliases) }.map(\.appName)
                let names = Array(Set(apps)).sorted()
                let hasTabs = routine.actions.flatMap { $0.tabSets ?? [] }.contains { $0.macName == other && !$0.isLocal(macID(), aliases: macAliases) }
                let hasRemembered = routine.actions.compactMap(\.remembered).contains { layouts in
                    layouts.contains { !placementIsLocal($0.key) && $0.value.macName == other }
                }
                var missed: [String] = []
                if !names.isEmpty { missed.append("\(WorkspaceWords.list(names)) \(names.count == 1 ? "wasn't" : "weren't") placed") }
                if hasRemembered || (!hasTabs && names.isEmpty) { missed.append("its windows weren't restored") }
                if hasTabs { missed.append("its tabs didn't open") }
                let message = "\(other) wasn't reached, so " + WorkspaceWords.list(missed) + "."
                status += "\n" + message
                logRemote(.init(macName: other, summary: message, failure: "not reached"), routineID: routineID, operationID: operationID, undo: false)
                failureMessage = ([failureMessage].compactMap { $0 } + [message]).joined(separator: " ")
            }
        }
        return failureMessage
    }

    /// What the run did on this Mac, and the failure that's safe to
    /// repeat in a voice alert (plan notes can name browser profiles).
    private static func summary(of result: WorkspaceExecutionResult, plan: WorkspacePlan, tabs: WorkspaceTabRun,
                                windowsBroughtBack: Int) -> (outcome: String, failure: String?) {
        if let failure = result.failures.first {
            let advice = result.recovery.isEmpty ? "No windows moved." : "Some windows moved and the rest didn't. Press Undo to put back every window that moved."
            let stopped = "stopped after \(result.completed) of \(plan.operations.count) changes. \(failure) \(advice)"
            return (([stopped] + plan.notes).joined(separator: "\n"), stopped)
        }
        let summary: String
        if result.completed > 0 { summary = "done, \(result.completed == 1 ? "1 change" : "\(result.completed) changes")." }
        else if windowsBroughtBack > 0 { summary = "brought back \(windowsBroughtBack) windows." }
        else if tabs.tabsOpened > 0 { summary = "opened \(WorkspaceTabWords.count(tabs.tabsOpened))." }
        else if tabs.windowsReused > 0 { summary = "brought back \(tabs.windowsReused == 1 ? "1 browser window" : "\(tabs.windowsReused) browser windows")." }
        else if result.stack?.liftedIDs.isEmpty == false { summary = "done." }
        else if !tabs.slowBrowsers.isEmpty { summary = "no tab openings were confirmed." }
        else { summary = "no changes were made." }
        return (([summary] + plan.notes).joined(separator: "\n"), nil)
    }

    private func safeRemoteFailure(_ report: WorkspaceRunReport, routine: WorkspaceRoutine?) -> String? {
        guard let failure = report.failure else { return nil }
        guard let routine, routine.actions.contains(where: \.isTabStep) else { return "\(report.macName): \(failure)" }
        let names = Array(Set(routine.actions.flatMap { $0.tabSets ?? [] }
            .filter { $0.macName == report.macName }.map(\.browserName))).sorted()
        guard !names.isEmpty, (report.counts?.tabsOpened ?? 0) == 0 else {
            return "Workspaces couldn't finish on \(report.macName). Check this routine in Workspaces."
        }
        // Older peers can return notes containing profile names. Regenerate the
        // failure from browser names, preserving uncertainty for slow requests.
        return failure.contains("so its tabs may still appear.")
            ? WorkspaceTabWords.slow(browsers: names, macName: report.macName)
            : WorkspaceTabWords.failure(browsers: names, macName: report.macName)
    }

    private func rejectedRun(routineID: String, operationID: String? = nil, undo: Bool = false, from: String? = nil,
                             trigger: String = "remote", summary: String, failure: String? = nil) -> WorkspaceRunOutcome {
        let operationID = operationID ?? UUID().uuidString
        logStart(routineID: routineID, operationID: operationID, undo: undo, from: from, trigger: trigger)
        let counts = WorkspaceRunCounts()
        logEnd(routineID: routineID, operationID: operationID, undo: undo, startedAt: adapter.monotonicTime, counts: counts, failure: failure)
        return WorkspaceRunOutcome(summary: summary, failure: failure, counts: counts)
    }

    private func logStart(routineID: String, operationID: String, undo: Bool, from: String?, trigger: String) {
        diagnostics("workspace: start mac=\(macID()) name=\(macName()) routine=\(routineID) op=\(operationID.prefix(8)) undo=\(undo) origin=\(from.map { "remote:" + $0 } ?? "here") trigger=\(trigger)")
    }

    private func diagnosticFailure(_ failure: String?, routineID: String, redact: Bool = false) -> String {
        guard let failure else { return "none" }
        if redact || settings.workspaceLaunch.routines.first(where: { $0.id == routineID })?.actions.contains(where: \.isTabStep) == true {
            return "reported"
        }
        return failure
    }

    private func logEnd(routineID: String, operationID: String, undo: Bool, startedAt: TimeInterval, counts: WorkspaceRunCounts, failure: String?, redactFailure: Bool = false) {
        diagnostics("workspace: end mac=\(macID()) name=\(macName()) routine=\(routineID) op=\(operationID.prefix(8)) undo=\(undo) duration=\(String(format: "%.3f", max(0, adapter.monotonicTime - startedAt))) \(counts.diagnostic) failure=\(diagnosticFailure(failure, routineID: routineID, redact: redactFailure))")
    }

    private func logRemote(_ report: WorkspaceRunReport, routineID: String, operationID: String, undo: Bool) {
        let reached = report.failure != "didn't answer in time." && report.failure != "not reached"
        diagnostics("workspace: remote mac=\(macID()) routine=\(routineID) op=\(operationID.prefix(8)) undo=\(undo) target=\(report.macName) reached=\(reached) \(report.counts?.diagnostic ?? "counts=unavailable") failure=\(diagnosticFailure(report.failure, routineID: routineID, redact: true))")
    }

    func restoreLastReset() {
        guard !isBusy, canRestore else { return }
        refreshPermission()
        guard isAccessibilityGranted else {
            status = "Allow Dictator to move windows (step 1) before undoing."
            _ = rejectedRun(routineID: lastRunRoutineID ?? "unknown", operationID: lastRunOperationID, undo: true, trigger: "click", summary: status, failure: status)
            return
        }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false; scheduleRescue(); adapter.retainWindows(ids: recovery.windowIDs.union(tracker.windowIDs)) }
            let reachOthers = lastRunReachedOtherMacs
            let requestedOthers = lastRunOtherMacs
            lastRunReachedOtherMacs = false
            lastRunOtherMacs = []
            status = macName() + ": " + (await restoreHere()).summary
            if reachOthers, let fleet, let routineID = lastRunRoutineID {
                do {
                    let reports = try await fleet.runElsewhere(routineID: routineID, undo: true, operationID: lastRunOperationID)
                    for report in reports {
                        status += "\n" + report.macName + ": " + report.summary
                        logRemote(report, routineID: routineID, operationID: lastRunOperationID ?? "unknown", undo: true)
                    }
                    for other in requestedOthers where !reports.contains(where: { $0.macName == other }) {
                        logRemote(.init(macName: other, summary: "not reached", failure: "not reached"), routineID: routineID, operationID: lastRunOperationID ?? "unknown", undo: true)
                    }
                } catch {
                    status += "\nYour other Macs weren't reached: \(error.localizedDescription)"
                    for other in requestedOthers {
                        logRemote(.init(macName: other, summary: "not reached", failure: "not reached"), routineID: routineID, operationID: lastRunOperationID ?? "unknown", undo: true)
                    }
                }
            }
        }
    }

    private func restoreHere(from: String? = nil) async -> WorkspaceRunOutcome {
        let routineID = recoveryOrigin?.routineID ?? lastRunRoutineID ?? "unknown"
        let operationID = recoveryOrigin?.operationID ?? lastRunOperationID ?? UUID().uuidString
        let startedAt = adapter.monotonicTime
        var counts = WorkspaceRunCounts()
        var failure: String?
        logStart(routineID: routineID, operationID: operationID, undo: true, from: from, trigger: from == nil ? "click" : "remote")
        let containsTabs = recoveryTabsOpened
        defer { logEnd(routineID: routineID, operationID: operationID, undo: true, startedAt: startedAt, counts: counts, failure: failure, redactFailure: containsTabs) }
        let openedNote = (recoveryOpenedApps ? " Apps opened by this run stay open." : "")
            + (recoveryTabsOpened ? " Tabs opened by this run stay open." : "")
        recoveryOpenedApps = false
        recoveryTabsOpened = false
        guard !recovery.isEmpty else { canRestore = false; recoveryOrigin = nil; return WorkspaceRunOutcome(summary: "Nothing to undo on this Mac." + openedNote, counts: counts) }
        let restoredApps = !recovery.hiddenBundleIDs.isEmpty || !recovery.shownBundleIDs.isEmpty
        let result = await WorkspaceLaunchExecutor.restoreCooperatively(recovery, adapter: adapter)
        for var window in recovery.windows where result.movedWindowIDs.contains(window.id) {
            if let frame = WorkspaceGeometry.restorationFrame(for: window, displays: displays) { window.frame = frame }
            trackedFrames[window.id] = window
            tracker.markReturned(windowID: window.id)
        }
        let trackedApps = Set(tracker.windows.values.map(\.bundleID))
        if !trackedApps.isEmpty, let snapshot = try? await adapter.capture(lastActivatedAt: lastActivatedAt,
            excluding: protectedIDs, preferredFrontmostBundleID: nil,
            windowBundleIDs: trackedApps, applicationBundleIDs: trackedApps) {
            updateTracking(snapshot, capturedApps: trackedApps)
        } else { saveParkedRecords() }
        counts.windowsMoved = result.movedWindowIDs.count
        counts.windowsMinimized = recovery.windows.filter { $0.isMinimized && result.movedWindowIDs.contains($0.id) }.count
        failure = result.failures.first
        recovery = result.recovery
        if recovery.isEmpty { recoveryOrigin = nil }
        canRestore = !recovery.isEmpty
        lastRunStoppedPartway = false
        clearPreview()
        let summary = (result.failures.isEmpty
            ? (restoredApps ? "Apps and windows are back where they were." : "Windows are back where they were.")
            : "Restored \(result.completed) changes. \(result.failures.first ?? "Some windows could not be restored.") \(canRestore ? "You can retry the remaining changes." : "Closed or restarted apps cannot be restored.")") + openedNote
        return WorkspaceRunOutcome(summary: summary, failure: failure, counts: counts)
    }

    /// What Undo would put back, and where, for the page.
    var undoSummary: String? {
        guard canRestore else { return nil }
        var places = recovery.isEmpty && !recoveryOpenedApps ? [] : ["this Mac"]
        places += lastRunReachedOtherMacs ? lastRunOtherMacs : []
        guard !places.isEmpty else { return nil }
        let run: String?
        if let origin = recoveryOrigin, !recovery.isEmpty {
            run = origin.fromMac.map { "\(origin.routineName) (run from \($0))" } ?? origin.routineName
        } else {
            run = settings.workspaceLaunch.routines.first { $0.id == lastRunRoutineID }?.name
        }
        let appsChanged = !recovery.hiddenBundleIDs.isEmpty || !recovery.shownBundleIDs.isEmpty
        let line = appsChanged ? "Undo brings back the apps and windows \(run ?? "the last run") changed on \(WorkspaceWords.list(places))."
            : "Undo puts back the windows \(run ?? "the last run") moved on \(WorkspaceWords.list(places))."
        return line + (recoveryOpenedApps ? " Apps opened by this run stay open." : "")
            + (recoveryTabsOpened ? " Tabs opened by this run stay open." : "")
    }

    // MARK: Remembered layouts

    /// Every other Mac named by a routine, including ones currently offline.
    func otherMacs(in routine: WorkspaceRoutine) -> [String] {
        let here = macID()
        let names = routine.actions.compactMap(\.remembered).flatMap { $0.filter { $0.key != here && !macAliases.contains($0.key) }.map(\.value.macName) }
        let placed = routine.actions.flatMap { $0.placements ?? [] }.filter { !$0.isLocal(here, aliases: macAliases) }.map(\.macName)
        let tabs = routine.actions.flatMap { $0.tabSets ?? [] }.filter { !$0.isLocal(here, aliases: macAliases) }.map(\.macName)
        return Array(Set(names + placed + tabs)).sorted()
    }

    private var macAliases: Set<String> { Set([fleet?.localWorkspaceMacID].compactMap { $0 }) }

    var placementMacs: [WorkspaceMacOption] {
        let local = WorkspaceMacOption(id: fleet?.localWorkspaceMacID ?? macID(), name: macName(), online: true, isCurrent: true)
        return [local] + (fleet?.workspaceMacs ?? []).filter { !macAliases.contains($0.id) && $0.id != local.id }
    }

    func placementIsLocal(_ id: String) -> Bool { id == macID() || macAliases.contains(id) }

    /// Discovery is temporary editor state; nothing is added to shared settings.
    func placementDisplays() async throws -> [String: WorkspaceSavedLayout] {
        guard !isBusy else { throw WorkspaceLaunchError.unavailable(Self.captureBusyMessage) }
        guard let fleet else { return [:] }
        let result = try await fleet.rememberEverywhere()
        guard result.busy.isEmpty else {
            throw WorkspaceLaunchError.unavailable("Monitors on \(WorkspaceWords.list(result.busy)) are not available right now because a routine is running.")
        }
        return result.layouts
    }

    /// Wait for a deferred Bring back during a run; QuitGuard bounds this to two seconds.
    func returnParkedWindowsBeforeQuit() async {
        await returnParkedWindows()
        while isBusy || returnRequested {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Includes crash recovery, so quitting also waits when launch rescue is pending.
    var hasParkedWindows: Bool { parkedWindowCount > 0 || !crashRecords.isEmpty || tracker.windows.values.contains(where: \.returnPending) || isBusy }

    private func acceptTabs(_ tabs: WorkspaceTabRun) {
        tracker = tabs.tracker
        trackedFrames.merge(tabs.observed) { _, new in new }
        trackedFrames = trackedFrames.filter { tracker.windowIDs.contains($0.key) }
        if !tabs.displays.isEmpty { displays = tabs.displays }
        let previouslyTracked = tracker.windows.values.filter {
            $0.returnPending || $0.parked || trackedFrames[$0.windowID].map { WorkspaceParking.isParked($0.frame, displays: displays) } == true
        }
        tracker.prune(liveWindowIDs: nil, routines: settings.workspaceLaunch.routines)
        for orphan in previouslyTracked where tracker.window(forSet: orphan.setID) == nil {
            tracker.record(orphan)
            returnRequested = true
        }
        saveParkedRecords()
    }

    private func updateTracking(_ snapshot: WorkspaceSnapshot, capturedApps: Set<String>) {
        displays = snapshot.displays
        let unknown = Set(snapshot.applications.filter(\.isHidden).map(\.bundleID))
            .union((snapshot.skipped ?? []).map(\.bundleID))
        let unobserved = tracker.windows.values.filter {
            $0.returnPending || !capturedApps.contains($0.bundleID) || unknown.contains($0.bundleID) || !snapshot.notes.isEmpty
        }.map(\.windowID)
        let live = Set(snapshot.windows.map(\.id)).union(unobserved)
        // Deleted sets still have to come home before their handles are released.
        let orphans = tracker.windows.values.filter {
            $0.returnPending || live.contains($0.windowID) && ($0.parked || trackedFrames[$0.windowID].map {
                WorkspaceParking.isParked($0.frame, displays: displays)
            } == true)
        }
        tracker.prune(liveWindowIDs: live, routines: settings.workspaceLaunch.routines)
        for orphan in orphans where tracker.window(forSet: orphan.setID) == nil {
            tracker.record(orphan)
            returnRequested = true
        }
        for window in snapshot.windows { trackedFrames[window.id] = window }
        trackedFrames = trackedFrames.filter { tracker.windowIDs.contains($0.key) }
        saveParkedRecords()
    }

    @discardableResult
    private func saveParkedRecords(adding records: [WorkspaceParkedRecord] = []) -> Bool {
        let parked = tracker.windows.values.sorted { $0.setID < $1.setID }.filter {
            $0.parked || trackedFrames[$0.windowID].map { WorkspaceParking.isParked($0.frame, displays: displays) } == true
        }
        parkedWindowCount = parked.count
        return parkedStore.save(crashRecords + parked.compactMap { tracked in
            guard let home = tracked.home, let frame = trackedFrames[tracked.windowID]?.frame else { return nil }
            return WorkspaceParkedRecord(bundleID: tracked.bundleID, home: home, savedAt: now(),
                                         parkedAt: .init(x: frame.x, y: frame.y))
        } + records)
    }

    private func usableApps(in snapshot: WorkspaceSnapshot, for routine: WorkspaceRoutine, preview: Bool = false) -> Set<String> {
        var usable = Set(snapshot.windows.filter {
            !$0.isMinimized && WorkspaceGeometry.hasReachableTitlebar($0.frame, on: snapshot.displays.map(\.visibleFrame))
        }.map(\.bundleID))
        usable.formUnion(tracker.windows.values.filter { $0.routineID == routine.id && !$0.returnPending }.map(\.bundleID))
        if preview {
            usable.formUnion(routine.actions.flatMap { $0.tabSets ?? [] }.filter {
                $0.isLocal(macID(), aliases: macAliases)
            }.map(\.browserBundleID))
        }
        return usable
    }

    private func parkOtherGroups(for routine: WorkspaceRoutine, usable: Set<String>) async -> WorkspaceExecutionResult {
        var result = WorkspaceExecutionResult()
        let group = Set(routine.groupApps(macID: macID(), aliases: macAliases)).intersection(usable)
        for var tracked in tracker.others(than: routine.id, in: group) {
            guard !tracked.returnPending, let window = trackedFrames[tracked.windowID],
                  !WorkspaceParking.isParked(window.frame, displays: displays),
                  let target = WorkspaceParking.frame(for: window.frame, displays: displays) else { continue }
            // A window macOS pushed back on screen is still parked, and the spot
            // it was pushed to isn't its home.
            let home = tracked.parked ? tracked.home ?? window.frame : window.frame
            let record = WorkspaceParkedRecord(bundleID: tracked.bundleID, home: home, savedAt: now(),
                                              parkedAt: .init(x: target.x, y: target.y))
            // Nothing changes in memory or on screen until recovery is durable.
            guard saveParkedRecords(adding: [record]) else {
                result.notes.append("A browser window stayed showing because Dictator couldn't save its place.")
                break
            }
            tracked.home = home
            tracked.parked = true
            tracker.record(tracked)
            var original = window; original.frame = home
            result.recovery.windows.append(original)
            var parked = window; parked.frame = target
            trackedFrames[window.id] = parked
            do {
                let landed = try await adapter.parkWindow(id: window.id, at: target)
                if WorkspaceParking.isParked(landed, displays: displays) {
                    parked.frame = landed
                    trackedFrames[window.id] = parked
                    result.movedWindowIDs.insert(window.id)
                    result.completed += 1
                } else {
                    // macOS held it on screen, so a half-parked window would be
                    // neither here nor there. Put it back where it was.
                    do {
                        try await adapter.moveWindow(id: window.id, to: home)
                        trackedFrames[window.id] = original
                        tracker.markReturned(windowID: window.id)
                        result.recovery.windows.removeAll { $0.id == window.id }
                        result.notes.append("A browser window stayed showing because macOS wouldn't move it out of the way.")
                    } catch {
                        // Still away from home, so Undo, Bring back and the record stay.
                        parked.frame = landed
                        trackedFrames[window.id] = parked
                        result.notes.append("A browser window couldn't be put out of the way. Bring back can restore it.")
                    }
                }
            } catch {
                // AX can fail after changing a position: keep the home and recovery.
                result.notes.append("A browser window couldn't be put out of the way. Bring back can restore it.")
            }
            saveParkedRecords()
        }
        return result
    }

    private func scheduleRescue() {
        guard !rescueScheduled, !isBusy, adapter.isAccessibilityGranted,
              returnRequested || !crashRecords.isEmpty else { return }
        rescueScheduled = true
        Task { @MainActor in
            defer { rescueScheduled = false }
            await returnParkedWindows()
        }
    }

    /// Puts every parked window back. A request made during a run is serviced
    /// after that run releases its handles.
    func returnParkedWindows() async {
        guard !isBusy else { returnRequested = true; return }
        guard adapter.isAccessibilityGranted else { return }
        returnRequested = false
        isBusy = true
        defer {
            isBusy = false
            adapter.retainWindows(ids: recovery.windowIDs.union(tracker.windowIDs))
        }
        await rescueAfterCrash()
        guard !Task.isCancelled else { return }
        let apps = Set(tracker.windows.values.map(\.bundleID))
        if !apps.isEmpty, let snapshot = try? await adapter.capture(lastActivatedAt: lastActivatedAt, excluding: protectedIDs,
            preferredFrontmostBundleID: nil, windowBundleIDs: apps, applicationBundleIDs: apps) {
            updateTracking(snapshot, capturedApps: apps)
        }
        for tracked in tracker.windows.values.sorted(by: { $0.setID < $1.setID }) {
            guard !Task.isCancelled, var window = trackedFrames[tracked.windowID],
                  tracked.parked || WorkspaceParking.isParked(window.frame, displays: displays), let home = tracked.home else { continue }
            window.frame = home
            // A parked window's captured display is the tiny sliver, not its home screen.
            window.displayID = nil
            guard let frame = WorkspaceGeometry.restorationFrame(for: window, displays: displays) else { continue }
            do {
                try await adapter.moveWindow(id: window.id, to: frame)
                window.frame = frame
                trackedFrames[window.id] = window
                tracker.markReturned(windowID: window.id)
                if tracked.returnPending { tracker.forget(setID: tracked.setID) }
                saveParkedRecords()
            } catch { status = "Some windows couldn't come back. Try Bring back again." }
        }
        returnRequested = false
        saveParkedRecords()
    }

    private func rescueAfterCrash() async {
        guard !crashRecords.isEmpty, adapter.isAccessibilityGranted else { return }
        let apps = Set(crashRecords.map(\.bundleID))
        var shown: [String] = []
        for id in apps.subtracting(protectedIDs).sorted() {
            if (try? await adapter.showApp(bundleID: id)) == true { shown.append(id) }
        }
        await moveParkedWindowsHome(apps: apps)
        for id in shown { try? await adapter.rehideApp(bundleID: id) }
    }

    private func moveParkedWindowsHome(apps: Set<String>) async {
        guard let snapshot = try? await adapter.capture(lastActivatedAt: [:], excluding: protectedIDs,
            preferredFrontmostBundleID: nil, windowBundleIDs: apps, applicationBundleIDs: apps) else { return }
        displays = snapshot.displays
        guard displays.contains(where: { $0.visibleFrame.isUsable }) else { return }
        let windows = snapshot.windows.filter { WorkspaceParking.isParked($0.frame, displays: displays) }
        // Consider all qualifying pairs together, so the closest record gets
        // the window first and neither a record nor a window can be used twice.
        var matches: [(record: Int, window: Int, distance: Double)] = []
        for (r, record) in crashRecords.enumerated() {
            guard !snapshot.applications.contains(where: { $0.bundleID == record.bundleID && $0.isHidden }),
                  !(snapshot.skipped ?? []).contains(where: { $0.bundleID == record.bundleID }), snapshot.notes.isEmpty else { continue }
            for (w, window) in windows.enumerated() where window.bundleID == record.bundleID {
                let corner = WorkspaceParking.frame(for: window.frame, displays: displays)
                let points = [record.parkedAt, corner.map { WorkspacePoint(x: $0.x, y: $0.y) }].compactMap { $0 }
                let distance = points.map { hypot(window.frame.x - $0.x, window.frame.y - $0.y) }.min() ?? .infinity
                // Measured: macOS stops windows 31 to 40 points short of the corner.
                if distance <= 64 { matches.append((r, w, distance)) }
            }
        }
        matches.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.record != $1.record { return $0.record < $1.record }
            return $0.window < $1.window
        }
        var usedRecords = Set<Int>(), usedWindows = Set<Int>(), restoredRecords = Set<Int>()
        for match in matches {
            guard !Task.isCancelled else { break }
            guard !usedRecords.contains(match.record), !usedWindows.contains(match.window) else { continue }
            usedRecords.insert(match.record); usedWindows.insert(match.window)
            var window = windows[match.window]
            window.frame = crashRecords[match.record].home
            window.displayID = nil
            guard let frame = WorkspaceGeometry.restorationFrame(for: window, displays: displays) else { continue }
            do {
                try await adapter.moveWindow(id: window.id, to: frame)
                restoredRecords.insert(match.record)
            } catch { /* Keep the original record for the next recovery trigger. */ }
        }
        let pending = crashRecords.enumerated().compactMap { index, record -> WorkspaceParkedRecord? in
            guard !restoredRecords.contains(index) else { return nil }
            // Failed moves still have a matching window. Unmatched records wait
            // for slow launches, but legacy records have no reliable age.
            if usedRecords.contains(index) { return record }
            guard let savedAt = record.savedAt, now().timeIntervalSince(savedAt) < 24 * 60 * 60 else { return nil }
            return record
        }
        crashRecords = pending
        if crashRecords.isEmpty, let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
            self.permissionObserver = nil
        }
        saveParkedRecords()
    }

    /// Browsers each Mac has, keyed like `placementMacs`. A Mac that is absent
    /// is offline or too old to say.
    func availableBrowsers() async -> [String: [WorkspaceBrowserInfo]] {
        let local = await adapter.installedBrowsers()
        var result = [placementMacs[0].id: local]
        if fleet != nil, let layouts = try? await placementDisplays() {
            for mac in placementMacs where !mac.isCurrent {
                let layout = layouts[mac.id] ?? layouts.values.first { $0.macName == mac.name }
                if let browsers = layout?.browsers { result[mac.id] = browsers }
            }
        }
        return result
    }

    /// Names of the other Macs connected right now.
    var otherConnectedMacs: [String] { fleet?.otherMacNames ?? [] }

    static let captureBusyMessage = "Workspaces is busy with another routine. Try again when it finishes."

    /// This Mac's windows as they are now.
    func captureLayout(allowEmpty: Bool = false) async throws -> (layout: WorkspaceSavedLayout, notes: [String]) {
        guard !isBusy else { throw WorkspaceLaunchError.unavailable(Self.captureBusyMessage) }
        isBusy = true
        defer { adapter.retainWindows(ids: recovery.windowIDs.union(tracker.windowIDs)); isBusy = false; scheduleRescue() }
        refreshPermission()
        guard isAccessibilityGranted else { throw WorkspaceLaunchError.unavailable("Allow Dictator to move windows first (step 1).") }
        let apps = adapter.runningBundleIDs.subtracting(protectedIDs)
        let snapshot = try await adapter.capture(lastActivatedAt: lastActivatedAt, excluding: protectedIDs, preferredFrontmostBundleID: nil,
                                                 windowBundleIDs: apps, applicationBundleIDs: apps)
        updateTracking(snapshot, capturedApps: apps)
        var remembered = snapshot
        // Only Dictator's own parked windows: a person's window that happens to
        // sit off-screen is still theirs to remember.
        let parkedIDs = Set(tracker.windows.values.filter(\.parked).map(\.windowID))
        remembered.windows.removeAll { parkedIDs.contains($0.id) || (tracker.windowIDs.contains($0.id) && WorkspaceParking.isParked($0.frame, displays: snapshot.displays)) }
        let result = WorkspaceSavedLayout.make(snapshot: remembered, macName: macName())
        guard allowEmpty || !result.layout.windows.isEmpty else {
            throw WorkspaceLaunchError.unavailable("There are no open windows to remember on \(macName()).")
        }
        return result
    }

    /// Remembers where the windows are on this Mac and, with `everywhere`,
    /// on every other connected Mac. Returns the layouts keyed by Mac, or
    /// nil (with `status` saying why) when nothing could be remembered.
    func rememberLayouts(everywhere: Bool) async -> [String: WorkspaceSavedLayout]? {
        guard !isRemembering else { return nil }
        guard !isBusy else { status = Self.captureBusyMessage; return nil }
        isRemembering = true
        defer { isRemembering = false }
        status = ""
        var layouts: [String: WorkspaceSavedLayout] = [:]
        var notes: [String] = []
        if everywhere, let fleet, !fleet.otherMacNames.isEmpty {
            do {
                let result = try await fleet.rememberEverywhere()
                layouts = result.layouts.filter { !$0.value.windows.isEmpty }
                notes += result.layouts.values.sorted { $0.macName < $1.macName }.compactMap { layout in
                    layout.captureError.map { "\(layout.macName): \($0)" }
                }
                if !result.busy.isEmpty {
                    notes.append("\(WorkspaceWords.list(result.busy)) \(result.busy.count == 1 ? "is" : "are") busy with a routine, so no windows were remembered there.")
                }
                if !result.unanswered.isEmpty {
                    notes.append("\(WorkspaceWords.list(result.unanswered)) didn't answer, so \(result.unanswered.count == 1 ? "it was" : "they were") left out.")
                }
            } catch {
                notes.append("Your other Macs couldn't be reached (\(error.localizedDescription)), so only this Mac was remembered.")
            }
        }
        if layouts[macID()] == nil {
            do {
                let local = try await captureLayout()
                layouts[macID()] = local.layout
                notes += local.notes
            } catch {
                if layouts.isEmpty { status = ([error.localizedDescription] + notes).joined(separator: " "); return nil }
                notes.append(error.localizedDescription)
            }
        }
        let counts = layouts.values.sorted { $0.macName < $1.macName }.map { "\($0.windows.count) on \($0.macName)" }
        status = (["Remembered windows: \(WorkspaceWords.list(counts))."] + notes).joined(separator: " ")
        return layouts.mapValues { layout in
            var saved = layout
            saved.browsers = nil
            saved.captureError = nil
            return saved
        }
    }

    /// Asked by the main Mac: capture this Mac's windows, screens and browsers.
    func answerCaptureRequest() async -> (macID: String?, layout: WorkspaceSavedLayout?, error: String?) {
        do {
            var layout = try await captureLayout(allowEmpty: true).layout
            layout.browsers = await adapter.installedBrowsers()
            return (macID(), layout, nil)
        } catch {
            let message = error.localizedDescription
            // Busy replies must remain layout-free: the fleet recognizes their
            // error before considering layouts, and no handles are touched.
            guard message != Self.captureBusyMessage else { return (macID(), nil, message) }
            let layout = WorkspaceSavedLayout(macName: macName(), capturedAt: now(), screens: [], windows: [],
                browsers: await adapter.installedBrowsers(), captureError: message)
            return (macID(), layout, message)
        }
    }

    /// Asked by the main Mac on behalf of the Mac called `from`: run (or undo)
    /// a routine here. Empty when the routine has no steps for this Mac.
    func answerRunRequest(routineID: String, undo: Bool, from: String, operationID: String? = nil) async -> String {
        await answerRunReport(routineID: routineID, undo: undo, from: from, operationID: operationID).summary
    }

    func answerRunReport(routineID: String, undo: Bool, from: String, operationID: String? = nil) async -> WorkspaceRunOutcome {
        if undo {
            guard canRestore, (!recovery.isEmpty || recoveryOpenedApps), !isBusy else {
                return rejectedRun(routineID: routineID, operationID: operationID, undo: true, from: from, summary: isBusy ? Self.captureBusyMessage : "", failure: isBusy ? Self.captureBusyMessage : nil)
            }
            // Only the asking Mac's own run of this routine is undone here. A
            // newer run (from this Mac or any other) owns this Mac's Undo now.
            guard let origin = recoveryOrigin, origin.isUndoable(routineID: routineID, from: from, operationID: operationID) else {
                let newer = recoveryOrigin.map { "\($0.routineName) ran here after your run" } ?? "Its windows changed after your run"
                return rejectedRun(routineID: routineID, operationID: operationID, undo: true, from: from, summary: "kept its windows as they are: \(newer), so there was nothing of yours left to undo.")
            }
            isBusy = true
            defer { isBusy = false; scheduleRescue(); adapter.retainWindows(ids: recovery.windowIDs.union(tracker.windowIDs)) }
            let outcome = await restoreHere(from: from)
            status = macName() + ": " + outcome.summary
            return outcome
        }
        guard let routine = settings.workspaceLaunch.routines.first(where: { $0.id == routineID }) else {
            return rejectedRun(routineID: routineID, operationID: operationID, from: from, summary: "doesn't have this routine yet. Give it a moment to arrive, then try again.", failure: "doesn't have this routine yet. Give it a moment to arrive, then try again.")
        }
        guard routine.actions.contains(where: { $0.localLayout(macID(), aliases: macAliases) != nil || ($0.placements ?? []).contains { $0.isLocal(macID(), aliases: macAliases) } || ($0.tabSets ?? []).contains { $0.isLocal(macID(), aliases: macAliases) } }) else { return rejectedRun(routineID: routineID, operationID: operationID, from: from, summary: "") }
        guard !isBusy else { return rejectedRun(routineID: routineID, operationID: operationID, from: from, summary: "was busy with another routine.", failure: "was busy with another routine.") }
        isBusy = true
        return await performRun(routineID: routineID, fanOut: false, from: from, operationID: operationID)
    }

    private var protectedIDs: Set<String> {
        Bundle.main.bundleIdentifier.map { Set([$0]) } ?? []
    }

    private func prepare(routineID: String, preview: Bool = false, configured: WorkspaceRoutine? = nil, unavailableApps: Set<String> = [], appNotes: [String: String] = [:]) async throws -> (WorkspaceRoutine, WorkspaceSnapshot, WorkspacePlan) {
        refreshPermission()
        guard let routine = configured ?? settings.workspaceLaunch.routines.first(where: { $0.id == routineID }), routine.enabled else {
            throw WorkspaceLaunchError.unavailable("This routine is off. Turn it on to preview or run it.")
        }
        guard isAccessibilityGranted || routine.onlyOpensTabs(macID: macID(), aliases: macAliases) else { throw WorkspaceLaunchError.unavailable("Allow Dictator to move windows first (step 1).") }
        let actual = adapter.frontmostBundleID
        let preferred = actual == Bundle.main.bundleIdentifier ? previousAppID : actual
        let localActions = routine.actions.filter { !$0.isTabStep }.map { action -> WorkspaceAction in
            var local = action
            local.bundleIDs = action.localApps(macID(), aliases: macAliases).map(\.id)
            return local
        }
        let groups = routine.showsOnlyItsWindows(macID: macID(), aliases: macAliases)
        var windowBundleIDs = Set(localActions.filter { $0.kind == .arrangeWindows }.flatMap(\.bundleIDs))
        if routine.actions.contains(where: { $0.kind == .centerLastWindow }), let preferred { windowBundleIDs.insert(preferred) }
        if isAccessibilityGranted {
            windowBundleIDs.formUnion(tracker.windows.values.map(\.bundleID))
        }
        if groups { windowBundleIDs.formUnion(routine.groupApps(macID: macID(), aliases: macAliases)) }
        var applicationBundleIDs = Set(localActions.flatMap(\.bundleIDs)).union(windowBundleIDs)
        if groups { applicationBundleIDs.formUnion(adapter.runningBundleIDs) }
        // A routine that only opens tabs reads no windows at all.
        var snapshot = routine.onlyOpensTabs(macID: macID(), aliases: macAliases) ? WorkspaceSnapshot(capturedAt: now()) : try await adapter.capture(
            lastActivatedAt: lastActivatedAt, excluding: protectedIDs, preferredFrontmostBundleID: preferred,
            windowBundleIDs: windowBundleIDs, applicationBundleIDs: applicationBundleIDs)
        if !routine.onlyOpensTabs(macID: macID(), aliases: macAliases) {
            updateTracking(snapshot, capturedApps: windowBundleIDs)
        }
        let otherIDs = Set(tracker.windows.values.filter { $0.routineID != routine.id }.map(\.windowID))
        snapshot.windows.removeAll { otherIDs.contains($0.id) }
        snapshot.skipped = (snapshot.skipped ?? []).filter { windowBundleIDs.contains($0.bundleID) }
        // A capture limit or an excluded app is not evidence that it is closed.
        // Keep running-state evidence even when no AX windows were captured.
        for app in routine.actions.filter({ !$0.isTabStep }).flatMap({ $0.localApps(macID(), aliases: macAliases) })
            where !snapshot.applications.contains(where: { $0.bundleID == app.id }) && adapter.isAppRunning(bundleID: app.id) {
            snapshot.applications.append(.init(bundleID: app.id, name: app.name))
        }
        // Activation events can arrive during the background capture.
        for index in snapshot.applications.indices {
            snapshot.applications[index].lastActivatedAt = lastActivatedAt[snapshot.applications[index].bundleID]
        }
        var protected = protectedIDs.union([adapter.dictatorBundleID]).union(routine.keepVisible ?? [])
        if let preferred { protected.insert(preferred) }
        let focus = groups ? WorkspacePlanner.focusPlan(routine: routine, macID: macID(), aliases: macAliases,
            running: adapter.runningBundleIDs, hidden: Set(snapshot.applications.filter(\.isHidden).map(\.bundleID)),
            protected: protectedIDs.union([adapter.dictatorBundleID]), frontmost: adapter.frontmostBundleID,
            usable: usableApps(in: snapshot, for: routine, preview: preview)) : nil
        var windowRoutine = routine
        windowRoutine.actions.removeAll { $0.isTabStep }
        var plan = WorkspacePlanner.plan(routine: windowRoutine, snapshot: snapshot, protectedBundleIDs: protected, macID: macID(), macAliases: macAliases, preview: preview, unavailableApps: unavailableApps, appNotes: appNotes, focusPlan: focus)
        if preview {
            let browsers = await adapter.installedBrowsers()
            for set in routine.actions.flatMap({ $0.tabSets ?? [] }) {
                let blocked = set.isLocal(macID(), aliases: macAliases)
                    ? WorkspaceTabWords.blocked(set, browsers: browsers, macName: macName(), preview: true) : nil
                plan.notes.append(blocked ?? WorkspaceTabWords.preview(set))
            }
        }
        if let minutes = routine.actions.filter({ $0.kind == .hideIdleApps }).map(\.idleMinutes).min(),
           let note = WorkspaceIdleWords.note(trackingSince: trackingStartedAt, idleMinutes: minutes, now: now()) {
            plan.notes.append(note)
        }
        return (routine, snapshot, plan)
    }

    private func showPreview(_ plan: WorkspacePlan, snapshot: WorkspaceSnapshot, routineID: String?) {
        let picture = WorkspacePreviewPicture.make(plan: plan, snapshot: snapshot)
        previewPicture = picture
        previewRoutineID = routineID
        previewLines = (picture.lines.isEmpty ? ["Nothing needs to move right now."] : picture.lines) + plan.notes
    }

    func clearPreview() {
        previewLines = []
        previewPicture = nil
        previewRoutineID = nil
    }
}
