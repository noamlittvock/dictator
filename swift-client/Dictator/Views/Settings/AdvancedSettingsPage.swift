import SwiftUI

/// Settings › Advanced: the technical details behind Your Macs, for when
/// something needs setting by hand.
struct AdvancedSettingsPage: View {
    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared
    @State private var newBackup = ""
    @State private var backupError: String?
    @State private var speechKey = ""
    @State private var speechKeyNotice: String?

    var body: some View {
        SettingsPage(title: "Advanced", summary: "The details behind Your Macs. You shouldn’t need to change these unless something isn’t working.") {
            SettingsSectionCard(title: "This Mac") {
                SettingsRow(title: "Name shown on your other Macs", detail: "Leave empty to use the Mac’s own name.") {
                    TextField(Host.current().localizedName ?? "This Mac", text: $settings.edgeDisplayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }

            speechServers

            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text("Connection between your Macs")
                    .font(.dsSection)
                ConnectionDetailsView()
            }
        }
    }

    // MARK: Speech servers

    private var speechServers: some View {
        SettingsSectionCard(title: "Turning speech into text", footer: "Dictation tries these in order, skipping any that can’t be reached. Speech models on your Macs are added and ordered in Your Macs.") {
            SettingsRow(title: "Main speech server", detail: validation(settings.serverURL)) {
                TextField(text: $settings.serverURL, prompt: Text(verbatim: "http://100.x.y.z:7878")) { Text(verbatim: "http://100.x.y.z:7878") }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .disabled(settings.coreRole == .edge)
            }
            SettingsDivider()
            if let ownKey = LocalSecret.speechServerKey() {
                SettingsRow(title: "This Mac’s speech server key", detail: "For other Macs that use the speech server on this Mac. Paste it below on those Macs.") {
                    Button("Copy Key") {
                        LocalSecret.copyToClipboard(ownKey)
                        speechKeyNotice = "Key copied. It leaves the clipboard in two minutes."
                    }
                }
                SettingsDivider()
            }
            SettingsRow(title: "Speech server key", detail: "For a speech server on another Mac: copy its key in Advanced on that Mac and paste it here. This Mac’s own key stays unchanged.") {
                HStack(spacing: DSSpace.xs) {
                    SecureField("Paste key", text: $speechKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 80, maxWidth: 200)
                        .onSubmit(saveSpeechKey)
                    Button("Save", action: saveSpeechKey)
                        .fixedSize()
                        .disabled(speechKey.isEmpty)
                }
            }
            if let speechKeyNotice {
                Text(speechKeyNotice).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
            }
            ForEach(Array(settings.speechSources.enumerated()), id: \.offset) { index, source in
                SettingsDivider()
                SettingsRow(title: index == 0 ? "Tried first" : "Then", detail: source.serverURL.flatMap(validation)) {
                    HStack(spacing: DSSpace.xs) {
                        Text(describe(source)).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                        Button("Remove") {
                            settings.updateSpeechSources { $0.remove(at: index) }
                        }
                        .buttonStyle(.dsDestructive)
                        .disabled(settings.speechSources.count == 1)
                    }
                }
            }
            SettingsDivider()
            SettingsRow(title: "Add a speech server", detail: backupError, detailColor: .dsWarning) {
                HStack(spacing: DSSpace.xs) {
                    TextField(text: $newBackup, prompt: Text(verbatim: "http://100.x.y.z:7878")) { Text(verbatim: "http://100.x.y.z:7878") }
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 80, maxWidth: 200)
                        .onSubmit(addBackup)
                    Button("Add", action: addBackup)
                        .fixedSize()
                        .disabled(newBackup.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func describe(_ source: SetupRouting.SpeechSource) -> String {
        if let url = source.serverURL { return "Speech server at \(url)" }
        let mac = viewModel.setupSnapshot?.machineName(source.machineId) ?? "another Mac"
        return "\(ModelCatalog.name(of: source.model ?? "")) on \(mac)"
    }

    private func validation(_ value: String) -> String? {
        if settings.coreRole == .edge { return "Set on your main Mac." }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Not set. Dictation needs a speech server." }
        do {
            _ = try SpeechEndpoint.validated(value)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func addBackup() {
        let raw = newBackup.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = raw.contains("://") ? raw : "http://" + raw
        do {
            _ = try SpeechEndpoint.validated(value, label: "Backup server")
        } catch {
            backupError = error.localizedDescription
            return
        }
        backupError = nil
        settings.updateSpeechSources { $0.append(.server(value)) }
        newBackup = ""
    }

    private func saveSpeechKey() {
        do {
            try LocalSecret.saveSpeechServerKey(speechKey)
            speechKey = ""
            speechKeyNotice = "Key saved on this Mac."
        } catch {
            speechKeyNotice = error.localizedDescription
        }
    }
}
