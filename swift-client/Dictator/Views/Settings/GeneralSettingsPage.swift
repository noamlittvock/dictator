import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

/// Settings › General: starting dictation on this Mac.
struct GeneralSettingsPage: View {
    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared
    @State private var startup = StartupController.shared
    @State private var updates = UpdateService.shared
    @State private var devices: [AudioDevice] = []
    @State private var permissions = WelcomePermissions.current()

    var body: some View {
        SettingsPage(title: "General") {
            statusLine

            SettingsSectionCard(title: "Starting dictation") {
                SettingsRow(title: "Keys that start dictation", detail: "On this Mac. Click, then press any key or combination.") {
                    DictationKeysRecorder()
                }
                SettingsDivider()
                SettingsRow(title: "Keys that run a command", detail: "On this Mac. Add a key to dictation, or use your own.") {
                    CommandKeysRecorder()
                }
                SettingsDivider()
                SettingsRow(title: "How the key works", detail: keyModeDetail) {
                    Picker("How the key works", selection: handsFreeBinding) {
                        Text("Hold while you talk").tag(false)
                        Text("Tap to start, tap to stop").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(viewModel.isConnectedEdgeRole)
                }
            }

            SettingsSectionCard(title: "Microphone") {
                SettingsRow(title: "Microphone to use", detail: microphoneDetail) {
                    Picker("Microphone to use", selection: $settings.audioInputDeviceUID) {
                        Text("Same as your Mac’s sound settings").tag("")
                        ForEach(devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if !DictatorAppIntentsBuild.enabled {
                SettingsSectionCard(title: "Dictator in Apple Shortcuts") {
                    SettingsRow(title: DictatorAppIntentsBuild.unavailableMessage,
                                detail: DictatorAppIntentsBuild.unavailableHelp) { EmptyView() }
                }
            }

            if updates.isActive {
                SettingsSectionCard(title: "Updates") {
                    SettingsRow(title: "Check for updates automatically", detail: "Checks GitHub for new versions on this Mac.") {
                        Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }

            SettingsSectionCard(title: "When this Mac starts", footer: "Dictator starts after you log in, not at the login screen or while this Mac is asleep. Each Mac has its own setting.") {
                SettingsRow(title: "Open Dictator when you log in", detail: startup.message ?? startup.report.summary) {
                    Toggle("Open Dictator when you log in", isOn: Binding(get: { startup.login == .enabled || startup.login == .needsApproval }, set: startup.setLogin))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Show the window when Dictator opens", detail: "When off, Dictator stays in the menu bar.") {
                    Toggle("Show the window when Dictator opens", isOn: Binding(get: { startup.showWindow }, set: startup.setShowWindow))
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Startup on all your Macs", detail: startupExplanation) {
                    Button("Your Macs") { AppNavigation.shared.settingsSection = .macs }
                }
                if startup.login == .needsApproval || startup.login == .unavailable || startup.message != nil {
                    SettingsDivider()
                    SettingsRow(title: "Check macOS Login Items", detail: "macOS needs you to approve Dictator there, on this Mac.") {
                        Button("Open Login Items", action: startup.openLoginSettings)
                    }
                }
            }
        }
        .onAppear {
            permissions = WelcomePermissions.current()
            startup.refresh()
            loadDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions = WelcomePermissions.current()
            startup.refresh()
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusLine: some View {
        let status = DictationReadiness.current(viewModel: viewModel)
        SettingsNotice(tone: status.ready ? .ok : .warning, text: Text(status.text)) {
            if let anchor = permissions.firstMissingSettingsAnchor {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.dsLink)
            } else if hasLocalProblem {
                Button("Try again") { viewModel.retrySetup() }
                    .buttonStyle(.dsLink)
            } else {
                Button("Your Macs") { AppNavigation.shared.settingsSection = .macs }
                    .buttonStyle(.dsLink)
            }
        }
    }

    /// Something on this Mac (microphone or a permission) stops dictation,
    /// which "Try again" can retry right away.
    private var hasLocalProblem: Bool {
        if viewModel.micWarning != nil { return true }
        if case .needsPermission = viewModel.state { return true }
        return false
    }

    // MARK: Key

    // MARK: Key mode

    private var keyModeDetail: String {
        if viewModel.isConnectedEdgeRole, let main = viewModel.setupSnapshot?.mainMacName {
            return "Shared by all your Macs. Change it on \(main)."
        }
        return handsFreeBinding.wrappedValue
            ? "Tap once to start and again to stop. Stops by itself after 2 minutes."
            : "Hold the key down while you talk, and let go when you’re done."
    }

    /// While connected to a main Mac, it owns the mode; the picker shows
    /// its value and is disabled.
    private var handsFreeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isConnectedEdgeRole ? viewModel.effectiveHandsFree : settings.hotkeyHandsFree },
            set: { newValue in
                settings.hotkeyHandsFree = newValue
                viewModel.applyHandsFree()
            }
        )
    }

    // MARK: Microphone

    private var microphoneDetail: String {
        if settings.audioInputDeviceUID.isEmpty,
           let name = AVCaptureDevice.default(for: .audio)?.localizedName {
            return "Right now: \(name)"
        }
        if !settings.audioInputDeviceUID.isEmpty, !devices.contains(where: { $0.uid == settings.audioInputDeviceUID }) {
            return "That microphone isn’t connected. Your Mac’s sound settings are used until it is."
        }
        return "Used whenever you dictate on this Mac."
    }

    private func loadDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        devices = discovery.devices.map { AudioDevice(uid: $0.uniqueID, name: $0.localizedName) }
    }

    private var startupExplanation: String {
        switch settings.coreRole {
        case .core: "Your other Macs share history and settings through this Mac, so keep Dictator open here."
        case .edge: "This Mac reconnects to your main Mac automatically when it becomes available."
        case .standalone: "Keep Dictator open to dictate on this Mac."
        }
    }

}

struct AudioDevice: Identifiable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// One line saying whether dictation works right now and where the speech
/// is turned into text.
struct DictationReadiness {
    let ready: Bool
    let text: String

    @MainActor
    static func current(viewModel: DictatorViewModel, includeRecordingAccess: Bool = true) -> DictationReadiness {
        let settings = AppSettings.shared
        var blocking: String?
        if case .needsPermission(let message) = viewModel.state { blocking = message }
        let model = YourMacsModel(snapshot: viewModel.setupSnapshot, localId: viewModel.localEdgeId, settings: settings,
                                 connectedToMainMac: viewModel.isConnectedEdgeRole,
                                 localSpeechModels: LocalSpeechService.shared.installed,
                                 localCleanupModels: LocalModelInventory.shared.ollamaRunning ? LocalModelInventory.shared.models : nil)
        var machines = model.machines
        // Local downloads are known immediately, even before the next setup report.
        if let index = machines.firstIndex(where: { $0.id == viewModel.localEdgeId }) {
            machines[index].speechModels = LocalSpeechService.shared.installed
        }
        return evaluate(
            snapshot: viewModel.setupSnapshot,
            coreRole: settings.coreRole,
            serverURL: settings.serverURL,
            blockingProblem: includeRecordingAccess ? blocking : nil,
            localRecordingProblem: includeRecordingAccess ? viewModel.micWarning : nil,
            speechSources: model.speechSources, machines: machines,
            permissions: includeRecordingAccess ? WelcomePermissions.current() : nil,
            connectedToMainMac: viewModel.isConnectedEdgeRole, localId: viewModel.localEdgeId
        )
    }

    /// Whether dictation works on this Mac: its own permissions and
    /// microphone first, then where speech becomes text.
    static func evaluate(
        snapshot: SetupSnapshot?,
        coreRole: CoreRole,
        serverURL: String,
        blockingProblem: String?,
        localRecordingProblem: String?,
        speechSources: [SetupRouting.SpeechSource]? = nil,
        machines: [SetupSnapshot.Machine]? = nil,
        permissions: WelcomePermissions? = nil,
        connectedToMainMac: Bool = false,
        localId: EdgeID? = nil
    ) -> DictationReadiness {
        if let permissions {
            let missing = [("Microphone", permissions.microphone), ("Input Monitoring", permissions.inputMonitoring),
                           ("Accessibility", permissions.accessibility)].filter { !$0.1 }.map { $0.0 }
            if !missing.isEmpty {
                return DictationReadiness(ready: false, text: "Allow \(missing.joined(separator: ", ")) in System Settings to dictate on this Mac.")
            }
        }
        if let blockingProblem {
            return DictationReadiness(ready: false, text: "Dictation can’t start on this Mac. \(blockingProblem)")
        }
        let speech = speechReadiness(snapshot: snapshot, coreRole: coreRole, serverURL: serverURL, sources: speechSources, machines: machines,
                                     connectedToMainMac: connectedToMainMac, localId: localId)
        guard let localRecordingProblem else { return speech }
        let others = coreRole == .standalone ? "" : " You can try dictating on another of your Macs."
        return DictationReadiness(ready: false, text: "This Mac can’t record right now. \(localRecordingProblem)\(others)")
    }

    private static func speechReadiness(
        snapshot: SetupSnapshot?, coreRole: CoreRole, serverURL: String,
        sources: [SetupRouting.SpeechSource]?, machines: [SetupSnapshot.Machine]?,
        connectedToMainMac: Bool, localId: EdgeID?
    ) -> DictationReadiness {
        if coreRole == .edge && snapshot == nil {
            return DictationReadiness(ready: false, text: "Checking with your main Mac…")
        }
        let services = [snapshot?.speech].compactMap { $0 } + (snapshot?.backups ?? [])
        let disconnected = coreRole == .edge && !connectedToMainMac
        let configured = sources ?? (services.isEmpty
            ? (serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.server(serverURL)])
            : services.map { .server($0.address) })
        guard !configured.isEmpty else {
            return DictationReadiness(ready: false, text: "Dictation isn’t set up yet. Choose a speech model in Your Macs.")
        }
        for (index, source) in configured.enumerated() {
            let place: String
            if let url = source.serverURL {
                // A direct server might still work, but its last report from
                // the main Mac does not prove that it is reachable now.
                guard !disconnected else { continue }
                guard let service = services.first(where: { $0.address == url }), service.reachable else { continue }
                place = snapshot?.machineName(service.machineId) ?? "the speech server"
            } else {
                guard !disconnected || source.machineId == localId else { continue }
                guard let machine = (machines ?? snapshot?.machines ?? []).first(where: { $0.id == source.machineId }),
                      machine.online, let model = source.model, machine.speechModels?.contains(model) == true else { continue }
                place = machine.name
            }
            if disconnected {
                return DictationReadiness(ready: true, text: "A speech model on \(place) is ready. Dictator can’t check your others until your main Mac reconnects.")
            }
            let text = index == 0
                ? "Ready to dictate. Your voice is turned into text on \(place)."
                : "Ready to dictate using the backup on \(place). Your first choice isn’t available."
            return DictationReadiness(ready: true, text: text)
        }
        if disconnected {
            return DictationReadiness(ready: false, text: "Your main Mac isn’t connected, so Dictator can’t check speech on your other Macs.")
        }
        if snapshot == nil && configured.contains(where: { $0.serverURL != nil }) {
            return DictationReadiness(ready: false, text: "Checking your speech connection…")
        }
        return DictationReadiness(ready: false, text: "Dictator can’t reach any speech model right now. Check your models and connections in Your Macs.")
    }
}

extension SetupSnapshot {
    func machine(_ id: EdgeID?) -> Machine? {
        guard let id else { return nil }
        return machines.first { $0.id == id }
    }

    func machineName(_ id: EdgeID?) -> String? { machine(id)?.name }

    var mainMacName: String? { machines.first(where: \.isCore)?.name }
}
