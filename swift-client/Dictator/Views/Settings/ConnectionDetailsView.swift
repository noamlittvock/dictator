import AppKit
import SwiftUI

/// Cross-machine handoff: pick this install's role and, for Core/Edge,
/// manage the pairing that lets another Mac join. Reads/drives
/// `DictatorViewModel.shared` directly — the same instance the running app
/// uses — since this pane has no other route to the live `EdgeRuntime`/
/// `CoreHost` (see the note on `DictatorViewModel.shared`).
struct ConnectionDetailsView: View {
    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared

    @State private var coreTokenRevealed = false
    @State private var coreToken = ""
    @State private var edgeAddressDraft = ""
    @State private var edgeTokenDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.l) {
            SettingsGroup(title: "Role") {
                Picker("Role", selection: roleBinding) {
                    Text("On its own").tag(CoreRole.standalone)
                    Text("Main Mac (others connect to it)").tag(CoreRole.core)
                    Text("Connected to a main Mac").tag(CoreRole.edge)
                }
                .pickerStyle(.radioGroup)
                .font(.dsBody)

                Text(viewModel.connectionSummary.text)
                    .font(.dsBody)
                    .foregroundStyle(Color.dsTextSecondary)

                // Switching roles is allowed to end a dictation in progress
                // on other computers — Core → other role stops listening
                // (and any remote session with it); Edge → other role sends
                // a best-effort cancel first, but doesn't wait for it.
                Text("Changing this ends any dictation in progress on your other Macs.")
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextTertiary)
            }

            switch settings.coreRole {
            case .standalone:
                EmptyView()
            case .core:
                coreSection
            case .edge:
                edgeSection
            }
        }
        .onAppear {
            edgeAddressDraft = settings.coreAddress
            loadCoreToken()
            loadEdgeToken()
        }
    }

    private var roleBinding: Binding<CoreRole> {
        Binding(
            get: { settings.coreRole },
            set: { newValue in
                settings.coreRole = newValue
                viewModel.applyRole()
            }
        )
    }

    // MARK: - Core role

    @ViewBuilder
    private var coreSection: some View {
        SettingsGroup(title: "This Mac's Address") {
            if let address = viewModel.listeningAddress {
                Text(address)
                    .font(.dsMono)
                    .textSelection(.enabled)
            } else {
                Text(viewModel.listenerWarning ?? "Other Macs can’t connect to this Mac yet.")
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsWarning)
            }
        }

        SettingsGroup(title: "Pairing Token") {
            SettingsLabeledControl(
                "Token",
                help: "The secret another Mac needs to connect here. Or use Your Macs › Add a Mac, which copies the address and token together."
            ) {
                HStack(spacing: DSSpace.xs) {
                    Text(coreTokenRevealed ? coreToken : String(repeating: "•", count: max(coreToken.count, 8)))
                        .font(.dsMono)
                        .textSelection(.enabled)
                    Button(coreTokenRevealed ? "Hide" : "Reveal") {
                        coreTokenRevealed.toggle()
                    }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(coreToken, forType: .string)
                    }
                    .disabled(coreToken.isEmpty)
                }
            }
        }

        SettingsGroup(title: "Shared History") {
            Text("This Mac holds the main copy of your history, dictionary and settings. Every connected Mac keeps its own copy and syncs with this one.")
                .font(.dsSecondary)
                .foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsGroup(title: "Connected Macs") {
            if viewModel.connectedEdges.isEmpty {
                DSEmptyState(title: "No other Macs connected.")
            } else {
                ForEach(sortedEdges(viewModel.connectedEdges), id: \.id) { edge in
                    HStack(spacing: DSSpace.xs) {
                        Text(edge.id == viewModel.localEdgeId ? "\(edge.name) (This Mac)" : edge.name)
                            .font(.dsBodyMedium)
                            .foregroundStyle(Color.dsTextPrimary)
                        if edge.caps.hasMic {
                            Image(systemName: "mic.fill").font(.dsIcon)
                                .foregroundStyle(Color.dsTextSecondary)
                                .help("Has a microphone")
                        }
                        Spacer()
                        Text(String(edge.id.prefix(8)))
                            .font(.dsMonoCaption)
                            .foregroundStyle(Color.dsTextTertiary)
                    }
                }
            }
        }
    }

    private func sortedEdges(_ edges: [BrokerEdgeInfo]) -> [BrokerEdgeInfo] {
        edges.sorted { $0.id < $1.id }
    }

    private func loadCoreToken() {
        coreToken = (try? LocalSecret.sharedToken(fileName: "core-pairing.token")) ?? ""
    }

    // MARK: - Edge role

    @ViewBuilder
    private var edgeSection: some View {
        SettingsGroup(title: "Main Mac") {
            SettingsLabeledControl("Address", help: "The main Mac’s Tailscale address.") {
                TextField("100.x.y.z", text: $edgeAddressDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitEdgeAddress)
            }

            SettingsLabeledControl("Pairing token", help: "Shown in Advanced on the main Mac.") {
                SecureField("Pairing token", text: $edgeTokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitEdgeToken)
            }

            HStack(spacing: DSSpace.xs) {
                Button("Connect") {
                    commitEdgeAddress()
                    commitEdgeToken()
                }

                // Clears the pinned Core identity and the stored pairing
                // token for this address — needed to reconnect
                // after a legitimate Core re-pair (new install, restored
                // machine) once "Core identity changed" has pinned the old one.
                Button("Forget This Main Mac") {
                    forgetCore()
                }
            }
        }

        SettingsGroup(title: "Status") {
            Text(viewModel.connectionSummary.text)
                .font(.dsBody)
                .foregroundStyle(Color.dsTextSecondary)
        }

        SettingsGroup(title: "History Sync") {
            SyncStatusLine(viewModel: viewModel, loading: false)

            Text("Entries kept in History are saved on this Mac first, then synced with your main Mac when connected.")
                .font(.dsSecondary)
                .foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DSSpace.s) {
                SettingsStat(label: "Waiting to upload", value: "\(viewModel.syncPendingCount)")
                SettingsStat(label: "Last sync", value: viewModel.lastSyncAt.map(Self.timeString) ?? "never")
            }

            if let summary = viewModel.lastSyncSummary {
                Text(summary)
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextSecondary)
            }
        }
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func forgetCore() {
        let address = settings.coreAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        viewModel.forgetCore(at: address)
        edgeTokenDraft = ""
    }

    private func loadEdgeToken() {
        let address = settings.coreAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        edgeTokenDraft = (try? PairingCredentialStore.token(forCore: address)) ?? ""
    }

    private func commitEdgeAddress() {
        settings.coreAddress = edgeAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.applyRole()
    }

    /// Saved straight to `PairingCredentialStore` (a private file) — never
    /// to `AppSettings`/`UserDefaults`.
    private func commitEdgeToken() {
        let address = settings.coreAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = edgeTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !token.isEmpty else { return }
        try? PairingCredentialStore.save(token: token, forCore: address)
        viewModel.applyRole()
    }
}

/// Small label/value pair for the sync group.
private struct SettingsStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.hair) {
            Text(label)
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
            Text(value)
                .font(.dsMono.monospacedDigit())
                .foregroundStyle(Color.dsTextPrimary)
        }
    }
}
