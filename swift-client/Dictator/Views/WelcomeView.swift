import AVFoundation
import AppKit
import SwiftUI

/// First-run welcome: dictation first. Shows the key, explains each
/// permission before macOS asks for it (one at a time, only when the person
/// clicks Allow), shows whether dictation is ready, and only then offers
/// the optional typed history, off by default. Speech setup reuses the model chooser.
struct WelcomeView: View {
    /// `true` when the person chose to set up typed history next.
    let onFinish: (_ wantsTypedHistory: Bool) -> Void

    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared
    @State private var permissions = WelcomePermissions.current()
    @State private var showSpeechSetup = false
    @State private var wantsTypedHistory = false
    @State private var fields = WelcomeFieldsSelection()
    @State private var fieldsSaved = false

    private var localMachine: SetupSnapshot.Machine {
        SetupSnapshot.Machine(
            id: viewModel.localEdgeId, name: Host.current().localizedName ?? "This Mac",
            profile: MachineProfile.current, hasMic: true, online: true, lastSeen: Date(), isCore: settings.coreRole != .edge, localModels: nil,
            speechModels: LocalSpeechService.shared.installed, appleSpeech: LocalSpeechService.appleAvailable
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { welcomeContent }
            Rectangle().fill(Color.dsDivider).frame(height: 1)
            VStack(alignment: .leading, spacing: DSSpace.s) {
                VStack(alignment: .leading, spacing: DSSpace.hair) {
                    Toggle("Also choose apps where my typing is saved", isOn: $wantsTypedHistory)
                        .font(.dsBody)
                    Text("Optional. Nothing you type is kept until you choose apps.")
                        .font(.dsSecondary)
                        .foregroundStyle(Color.dsTextSecondary)
                }
                HStack(spacing: DSSpace.xs) {
                    Spacer()
                    Button(wantsTypedHistory ? "Choose apps…" : (DictationReadiness.current(viewModel: viewModel).ready ? BrandVoice.startDictating : "Finish setup later")) {
                        finish(wantsTypedHistory: wantsTypedHistory)
                    }
                    .buttonStyle(DictationReadiness.current(viewModel: viewModel).ready ? .dsPrimary : .dsSecondary)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(DSSpace.l)
        }
        .frame(width: DSSheetWidth.standard.points, height: 680)
        .background(Color.dsBgContent)
        .foregroundStyle(Color.dsTextPrimary)
        .font(.dsBody)
        .tint(Color.dsAccent)
        .buttonStyle(.dsSecondary)
        .sheet(isPresented: $showSpeechSetup) {
            AddModelSheet(machine: localMachine, initialJob: .speech)
        }
        .task {
            fields.load(from: settings)
            // macOS doesn't announce permission changes; check while open.
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            WelcomeBrandHeader()
            welcomeSteps.padding(DSSpace.l)
        }
    }

    private var welcomeSteps: some View {
        VStack(alignment: .leading, spacing: DSSpace.l) {
            step(number: 1, done: true, title: "Your dictation key") {
                HStack(spacing: DSSpace.xs) {
                    Text("Hold this key while you talk:")
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                    DictationKeysRecorder()
                }
            }

            step(number: 2, done: permissions.microphone && permissions.inputMonitoring && permissions.accessibility, title: "Three permissions, asked one at a time") {
                VStack(alignment: .leading, spacing: 0) {
                    permissionRow(
                        "Microphone", why: "So Dictator can hear you while you hold the key.",
                        granted: permissions.microphone, canRequest: permissions.microphoneCanRequest, settingsAnchor: "Privacy_Microphone"
                    ) {
                        viewModel.requestMicrophoneAccess { _ in refresh() }
                    }
                    permissionRow(
                        "Input Monitoring", why: "So Dictator notices when you press the dictation key.",
                        granted: permissions.inputMonitoring, settingsAnchor: "Privacy_ListenEvent"
                    ) {
                        HotkeyService.requestInputMonitoringPrompt()
                    }
                    permissionRow(
                        "Accessibility", why: "So Dictator can type your words into the app you’re using.",
                        granted: permissions.accessibility, settingsAnchor: "Privacy_Accessibility"
                    ) {
                        HotkeyService.requestAccessibilityPrompt()
                    }
                }
            }

            step(number: 3, done: DictationReadiness.current(viewModel: viewModel, includeRecordingAccess: false).ready, title: "Turn your speech into text") {
                let status = DictationReadiness.current(viewModel: viewModel, includeRecordingAccess: false)
                Label(status.ready ? BrandVoice.speechReady : status.text, systemImage: status.ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.dsBody)
                    .foregroundStyle(status.ready ? Color.dsTextPrimary : Color.dsWarning)
                    .fixedSize(horizontal: false, vertical: true)
                if !status.ready {
                    Text("Choose a speech model for this Mac. Dictator suggests one that fits, then shows its download progress.")
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set up speech…") { showSpeechSetup = true }
                        .controlSize(.large)
                }
                if CleanupStatus.evaluate(refineLevel: settings.refineLevel, routing: settings.setupRouting, snapshot: viewModel.setupSnapshot) == .notSetUp {
                    Text("Clean-up is optional and needs an AI model; add one later in Your Macs.")
                        .font(.dsSecondary)
                        .foregroundStyle(Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            step(number: 4, done: fieldsSaved, title: "Which fields apply? Optional") {
                if fieldsSaved {
                    Text("You can change your fields in Dictionary.")
                        .font(.dsBody).foregroundStyle(Color.dsTextSecondary)
                } else {
                    Text("Dictator works without choosing a field. Choose any you use.")
                        .font(.dsBody).foregroundStyle(Color.dsTextSecondary)
                    DictionaryFieldChips(on: $fields.on, off: $fields.off, automatic: false)
                    HStack(spacing: DSSpace.s) {
                        Button("Skip") { fields.finish(use: false, settings: settings); fieldsSaved = true }
                            .buttonStyle(.dsQuiet)
                        Button("Use these fields") {
                            fields.finish(use: true, settings: settings)
                            fieldsSaved = true
                        }
                    }
                    .controlSize(.regular)
                }
            }
            if DictationReadiness.current(viewModel: viewModel).ready {
                WelcomeCommandStep()
            }
        }
    }

    private func refresh() {
        let latest = WelcomePermissions.current()
        guard latest != permissions else { return }
        let keyAccessNewlyGranted = (latest.inputMonitoring && !permissions.inputMonitoring)
            || (latest.accessibility && !permissions.accessibility)
        permissions = latest
        // A newly granted permission takes effect without relaunching.
        if keyAccessNewlyGranted { viewModel.retrySetup() }
    }

    private func finish(wantsTypedHistory: Bool) {
        // Finishing the welcome also accepts any chips already chosen. Skip
        // leaves the existing selection alone, including mirrored settings.
        if !fieldsSaved { fields.finish(use: true, settings: settings) }
        settings.didCompleteWelcome = true
        viewModel.welcomeCompleted()
        onFinish(wantsTypedHistory)
    }

    @ViewBuilder
    private func step<Content: View>(number: Int, done: Bool = false, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: DSSpace.s) {
            DSStepBadge(number: number, done: done)
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text(title)
                    .font(.dsSection)
                    .foregroundStyle(Color.dsTextPrimary)
                content()
            }
        }
    }

    private func permissionRow(
        _ name: String, why: String, granted: Bool, canRequest: Bool = true, settingsAnchor: String, request: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: DSSpace.xs) {
            Image(systemName: granted ? "checkmark" : "circle.fill")
                .font(granted ? .dsIcon : .dsIconSmall)
                .foregroundStyle(granted ? Color.dsSuccess : Color.dsTextTertiary)
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                Text(name)
                    .font(.dsBodyMedium)
                    .foregroundStyle(Color.dsTextPrimary)
                Text(why)
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DSSpace.xs)
            if granted {
                Text("Allowed")
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextSecondary)
            } else {
                HStack(spacing: DSSpace.xs) {
                    if canRequest { Button("Allow…", action: request) }
                    // Keyboard permissions expose no denied/not-yet-asked
                    // distinction. Keep a direct route when a prompt can't help.
                    if !canRequest || settingsAnchor != "Privacy_Microphone" {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.dsLink)
                    }
                }
            }
        }
        .padding(.vertical, DSSpace.s)
    }
}

/// What macOS currently allows, read without asking for anything.
struct WelcomePermissions: Equatable {
    var microphone: Bool
    var inputMonitoring: Bool
    var accessibility: Bool
    // Keep the request state in this snapshot so a denial refreshes the row
    // even though `microphone` remains false.
    var microphoneCanRequest = true

    var firstMissingSettingsAnchor: String? {
        if !microphone { return "Privacy_Microphone" }
        if !inputMonitoring { return "Privacy_ListenEvent" }
        if !accessibility { return "Privacy_Accessibility" }
        return nil
    }

    static func current() -> WelcomePermissions {
        WelcomePermissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            inputMonitoring: HotkeyService.isInputMonitoringGranted,
            accessibility: HotkeyService.isAccessibilityGranted,
            microphoneCanRequest: AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        )
    }
}

@MainActor struct WelcomeFieldsSelection {
    var on: [String] = []
    var off: [String] = []

    mutating func load(from settings: AppSettings) {
        on = settings.vocabularyPacksOn
        off = settings.vocabularyPacksOff
    }

    func finish(use: Bool, settings: AppSettings) {
        guard use else { return }
        settings.vocabularyPacksOn = on
        settings.vocabularyPacksOff = off
    }
}
