import SwiftUI

/// The menu bar menu. Native on purpose: unlike a panel, a menu leaves the
/// keyboard in the field the user is about to dictate into. Everyday controls
/// sit here; anything that's only sometimes true appears only while it is.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var viewModel: DictatorViewModel
    @State private var settings = AppSettings.shared
    @State private var workspace = WorkspaceLaunchController.shared
    @State private var activity = CommandActivity.shared
    @State private var commandProgress = VoiceLaunchProgressController()
    @State private var commandAlerts = DictationAlertController()

    var body: some View {
        Group {
            Text(statusText)
            noticesSection
            // An inline picker draws its own separators.
            cleanupSection
            workspaceSection
            if let transcription = viewModel.lastTranscription, !transcription.isEmpty {
                Button("Copy Last Dictation") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcription, forType: .string)
                }
            }
            Button(activity.lastPlan.map { "Run Again: \($0.commandName)" } ?? "Run Again") {
                runAgain()
            }
            .disabled(!activity.canRunAgain)
            recoverySection
            typedHistorySection
            Divider()
            Button("Open Dictator") { openMainWindow() }
                .keyboardShortcut("o")
            if UpdateService.shared.isActive {
                Button("Check for Updates…") { UpdateService.shared.checkForUpdates() }
            }
            Button("Settings…") { AppNavigation.shared.openSettings(.general) }
                .keyboardShortcut(",")
            Button("Help") { AppNavigation.shared.openHelp() }
            Divider()
            Button("Quit Dictator") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        // The recovery list is refreshed from this lifecycle event, never
        // from `recoverySection`'s body reading `recoverableTakes`.
        .onAppear { viewModel.refreshRecoverableTakes() }
    }

    private var statusText: String {
        switch viewModel.state {
        case .idle: BrandVoice.ready
        case .needsPermission: "Setup Required"
        case .recording: BrandVoice.recording
        case .processing: BrandVoice.processing
        case .error: "Error"
        }
    }

    // MARK: Notices

    private var permissionMessage: String? {
        if case .needsPermission(let message) = viewModel.state { return message }
        return nil
    }

    private var notices: [MenuBarNotice] {
        var error: String?
        if case .error(let message) = viewModel.state { error = message }
        let center = PromptCaptureCenter.shared
        return MenuBarNotices.make(.init(
            permission: permissionMessage,
            needsAccessibility: viewModel.needsAccessibility,
            accessibilityGranted: HotkeyService.isAccessibilityGranted,
            error: error,
            microphone: viewModel.micWarning,
            storage: viewModel.persistenceWarning,
            insertion: viewModel.insertionWarning,
            connection: viewModel.connectionSummary,
            syncProblem: viewModel.showsSyncInMenu && !viewModel.syncIsHealthy ? viewModel.syncStatusText : nil,
            syncCanRunNow: viewModel.syncCanRunNow,
            cleanupNotSetUp: CleanupStatus.evaluate(refineLevel: settings.refineLevel, routing: settings.setupRouting,
                                                    snapshot: viewModel.setupSnapshot) == .notSetUp,
            unsavedPlaces: settings.surfacePolicy.allowsAnyTypedSave ? center.notices.active.count : 0
        ))
    }

    @ViewBuilder
    private var noticesSection: some View {
        let notices = notices
        if !notices.isEmpty {
            Divider()
            ForEach(notices) { notice in
                Button { perform(notice.fix) } label: { Label(notice.text, systemImage: notice.symbol) }
                if let hint = notice.hint { Text(hint) }
            }
            if permissionMessage != nil || viewModel.micWarning != nil {
                Button("Try Again") { viewModel.retrySetup() }
            }
            if permissionMessage != nil, HotkeyService.isAccessibilityGranted {
                Button("Relaunch Dictator") { relaunchApp() }
            }
        }
    }

    private func perform(_ fix: MenuBarNotice.Fix) {
        switch fix {
        case .privacyPane(let pane):
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        case .retry: viewModel.retrySetup()
        case .settings(let section): AppNavigation.shared.openSettings(section)
        case .syncNow: viewModel.syncNow()
        case .openDictator: openMainWindow()
        }
    }

    private func relaunchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Everyday controls

    private var cleanupSection: some View {
        Picker("Clean-up", selection: $settings.refineLevel) {
            ForEach(RefineLevel.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
    }

    /// Routines run from here exactly as from Workspace launch, with the same
    /// conditions for when they can.
    @ViewBuilder
    private var workspaceSection: some View {
        let routines = settings.workspaceLaunch.routines.filter(\.enabled)
        if !routines.isEmpty || workspace.canRestore {
            Menu("Workspaces") {
                ForEach(routines) { routine in
                    Button(routine.name) { workspace.run(routineID: routine.id) }
                        .disabled(workspace.isBusy || !workspace.isAccessibilityGranted)
                }
                if workspace.canRestore {
                    if !routines.isEmpty { Divider() }
                    Button("Undo Last Run") { workspace.restoreLastReset() }
                        .disabled(workspace.isBusy)
                }
            }
        }
    }

    /// Deleting is permanent, so it's confirmed in History & Privacy rather
    /// than done in one click here.
    @ViewBuilder
    private var recoverySection: some View {
        let takes = viewModel.recoverableTakes
        if !takes.isEmpty {
            Menu("Recover \(takes.count) Unfinished Dictation\(takes.count == 1 ? "" : "s")") {
                ForEach(takes) { take in
                    Menu(recoveryTitle(for: take)) {
                        Button("Turn Into Text") { Task { await viewModel.transcribeRecoveredTake(take) } }
                            .disabled(viewModel.isRecoveryBusy(take))
                        Button("Delete…") { AppNavigation.shared.openSettings(.history) }
                    }
                }
            }
            if let notice = viewModel.recoveryNotice { Text(notice) }
        }
    }

    private func recoveryTitle(for take: RecoveryService.RecoverableTake) -> String {
        let seconds = Int(take.take.durationSeconds)
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: take.take.metadata.startedAt)
        return "\(time) · \(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(take.take.metadata.edgeName)"
    }

    /// Only for someone who turned typed history on.
    @ViewBuilder
    private var typedHistorySection: some View {
        let center = PromptCaptureCenter.shared
        if settings.surfacePolicy.allowsAnyTypedSave {
            if let pause = center.pauseDescription {
                Text(pause)
                Button("Resume Typed History") { center.resume() }
            } else if settings.persistHistory {
                Menu("Pause Typed History") {
                    Button("For 15 Minutes") { center.pause(for: 15 * 60) }
                    Button("For 1 Hour") { center.pause(for: 3_600) }
                    Button("Until I Resume") { center.pause(for: nil) }
                }
            }
        }
    }

    private func runAgain() {
        guard activity.canRunAgain, let plan = activity.lastPlan else { return }
        Task {
            commandProgress.begin(plan)
            let result = await activity.runAgain(progress: { commandProgress.apply($0) })
            commandProgress.end()
            switch result {
            case .stopped(let alert), .cancelled(let alert): commandAlerts.show(alert)
            case .done, nil: break
            }
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
