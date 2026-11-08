import SwiftUI

/// Settings › History & Privacy: what Dictator saves, and anything saved
/// that needs a decision.
struct HistoryPrivacySettingsPage: View {
    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared
    @State private var center = PromptCaptureCenter.shared
    @State private var showCleanUp = false
    /// The recovered recording waiting for the user to confirm its
    /// permanent deletion. Nothing is deleted until they do.
    @State private var pendingDeletion: RecoveryService.RecoverableTake?

    var body: some View {
        SettingsPage(title: "History & Privacy", summary: "History is stored on your own Macs.") {
            SettingsSectionCard(title: "What Dictator saves", footer: settings.persistHistory ? nil : "New dictations and typed messages aren’t added to History.") {
                SettingsRow(title: "Save everything you dictate", detail: "So you can find it again on the Home page.") {
                    Toggle("Save everything you dictate", isOn: dictationBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Also save what you type in apps you choose", detail: "For example, messages you send to ChatGPT. Nothing else you type is saved.") {
                    HStack(spacing: DSSpace.s) {
                        Text(typedSummary)
                            .font(.dsSecondary)
                            .foregroundStyle(Color.dsTextSecondary)
                        Button("Choose Apps") { AppNavigation.shared.settingsSection = .typedApps }
                    }
                }
                .disabled(!settings.persistHistory)
                if settings.persistHistory && settings.surfacePolicy.allowsAnyTypedSave {
                    SettingsDivider()
                    SettingsRow(title: "Stop saving what you type for a while", detail: center.pauseDescription ?? "Your dictation settings stay the same.") {
                        if center.pauseDescription != nil {
                            Button("Resume") { center.resume() }
                        } else {
                            Menu("Pause") {
                                Button("For 15 Minutes") { center.pause(for: 15 * 60) }
                                Button("For 1 Hour") { center.pause(for: 3_600) }
                                Button("Until I Resume") { center.pause(for: nil) }
                            }
                            .fixedSize()
                        }
                    }
                }
            }

            SettingsSectionCard(title: "Privacy", footer: "Dictator skips password boxes, and can’t see typing while Secure Keyboard Entry is on.") {
                SettingsRow(title: "Hide recognized secrets in typed history", detail: "Dictator replaces passwords and keys it recognizes with [redacted].") {
                    Toggle("Hide recognized secrets in typed history", isOn: Binding(
                        get: { settings.surfacePolicy.shouldScrubSecrets },
                        set: { on in settings.updateSurfacePolicy { $0.scrubSecrets = on } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            needsAttention
        }
        .sheet(isPresented: $showCleanUp) { CleanUpHistorySheet() }
        .confirmationDialog(
            pendingDeletion.map { "Delete the recording from \(Self.recordingDate($0))?" } ?? "Delete this recording?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { take in
            Button("Delete Recording", role: .destructive) {
                viewModel.discardRecoveredTake(take)
                pendingDeletion = nil
            }
            Button("Keep It", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("The recording is deleted from this Mac for good and can’t be turned into text afterwards. This can’t be undone.")
        }
        .onAppear { viewModel.refreshRecoverableTakes() }
    }

    /// Dictation saving is the history master switch plus the voice default.
    private var dictationBinding: Binding<Bool> {
        Binding(
            get: { settings.persistHistory && settings.surfacePolicy.defaultVoice == "save" },
            set: { on in
                if on {
                    settings.persistHistory = true
                    if settings.surfacePolicy.defaultVoice != "save" {
                        settings.updateSurfacePolicy { $0.defaultVoice = "save" }
                    }
                } else {
                    settings.persistHistory = false
                }
            }
        )
    }

    private var typedSummary: String {
        guard settings.persistHistory && settings.surfacePolicy.allowsAnyTypedSave else { return "Off" }
        if settings.isPromptCapturePaused() { return "Paused" }
        let count = ToolCatalog.shared.tools.filter { center.isOn($0.id) }.count
        if count == 0 { return "On" }
        return count == 1 ? "On in 1 app" : "On in \(count) apps"
    }

    /// "14 October at 09:12" — the absolute date, so the confirmation
    /// names exactly which recording is about to go.
    static func recordingDate(_ take: RecoveryService.RecoverableTake) -> String {
        let date = take.take.metadata.startedAt
        return "\(date.formatted(.dateTime.day().month(.wide))) at \(date.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Needs attention

    @ViewBuilder
    private var needsAttention: some View {
        let takes = viewModel.recoverableTakes
        SettingsSectionCard(title: takes.isEmpty ? "Tidy up" : "Needs your attention", footer: takes.isEmpty ? nil : "When it starts, Dictator deletes recordings older than \(RecordingCheckpointStore.retentionDays) days, or sooner to keep the total to about 500 MB.") {
            if takes.isEmpty {
                SettingsRow(title: "Saved items from apps you’ve turned off", detail: "Check for anything saved before you turned an app off.") {
                    Button("Review…") { showCleanUp = true }
                }
            } else {
                ForEach(Array(takes.enumerated()), id: \.element.id) { index, take in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(
                        title: "A recording from \(take.take.metadata.startedAt.formatted(.relative(presentation: .named))) wasn’t turned into text",
                        detail: [take.take.metadata.errorMessage, take.retentionNote].compactMap { $0 }.joined(separator: " ")
                    ) {
                        if viewModel.isRecoveryBusy(take) {
                            ProgressView().controlSize(.small)
                        } else {
                            HStack(spacing: DSSpace.xs) {
                                Button("Turn Into Text") { Task { await viewModel.transcribeRecoveredTake(take) } }
                                Button("Delete…", role: .destructive) { pendingDeletion = take }
                                    .buttonStyle(.dsDestructive)
                            }
                        }
                    }
                }
                SettingsDivider()
                SettingsRow(title: "Saved items from apps you’ve turned off", detail: "Check for anything saved before you turned an app off.") {
                    Button("Review…") { showCleanUp = true }
                }
            }
            if let notice = viewModel.recoveryNotice {
                SettingsDivider()
                Text(notice)
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextSecondary)
                    .padding(.horizontal, DSSpace.m)
                    .padding(.vertical, DSSpace.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// History & Privacy › Choose apps: the apps and tools whose typing is saved.
struct TypedAppsSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                AppNavigation.shared.settingsSection = .history
            } label: {
                Label("History & Privacy", systemImage: "chevron.left")
                    .font(.dsSecondary)
            }
            .buttonStyle(.dsLink)
            .dsPageFrame()
            .padding(.top, DSSpace.m)
            DSPageHeader(title: "Apps where typing is saved")
                .dsPageFrame()
                .padding(.top, DSSpace.xs)
            PromptsSettingsTab()
        }
    }
}
