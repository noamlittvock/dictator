import SwiftUI

/// History & Privacy › "Saved items from apps you've turned off": finds
/// entries the current settings would no longer keep and deletes exactly
/// those locally. Durable deletion intent reaches updated Macs on sync.
struct CleanUpHistorySheet: View {
    @Environment(\.repositoryHub) private var hub
    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared
    @State private var errorMessage: String?

    // Purge state
    private struct PurgePreviewSummary {
        let localTotal: Int
        let localBySurface: [String: Int]
        /// The exact local entry ids matched at preview time — execute
        /// deletes precisely these, never a recomputed set, and never counts.
        let localEntryIds: [UUID]
        /// The repository identity and history version shown when this
        /// preview was computed; `executePurge` re-validates both.
        let repository: Repositories
        let historyVersion: Int
    }

    @State private var purgePreview: PurgePreviewSummary?
    @State private var isPreviewingPurge = false
    @State private var isPurging = false
    @State private var showPurgeConfirmation = false
    @State private var purgeStatusMessage: String?
    @State private var purgeErrorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DSSheet(title: "Saved items from apps you’ve turned off") {
            purgeSection
        } leadingActions: {
            if let preview = purgePreview, preview.localTotal > 0 {
                Button(role: .destructive) {
                    showPurgeConfirmation = true
                } label: {
                    if isPurging {
                        HStack(spacing: DSSpace.xxs) {
                            ProgressView().controlSize(.small)
                            Text("Deleting…")
                        }
                    } else {
                        Text("Delete These \(preview.localTotal) Items")
                    }
                }
                .buttonStyle(.dsDestructive)
                .disabled(isPreviewingPurge || isPurging)
            }
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .task { await runPurgePreview() }
    }

    // MARK: - Previously Saved History Purge

    private var purgeSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            if isPreviewingPurge && purgePreview == nil {
                HStack(spacing: DSSpace.xs) {
                    ProgressView().controlSize(.small)
                    Text("Looking through your history…").font(.dsBody).foregroundStyle(Color.dsTextSecondary)
                }
            } else if let preview = purgePreview {
                if preview.localTotal == 0 {
                    DSEmptyState(title: "Nothing to clean up. Everything saved comes from apps you still keep.")
                } else {
                    Text("\(preview.localTotal) saved item\(preview.localTotal == 1 ? "" : "s") come\(preview.localTotal == 1 ? "s" : "") from apps you turned off after they were saved.")
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    purgePreviewDetails(preview)
                }
            }

            if let purgeStatusMessage {
                Text(purgeStatusMessage).font(.dsSecondary).foregroundStyle(Color.dsSuccess)
            }
            if let purgeErrorMessage {
                Text(purgeErrorMessage).font(.dsSecondary).foregroundStyle(Color.dsWarning)
            }
        }
        .confirmationDialog(
            "Delete \(purgePreview?.localTotal ?? 0) items from this Mac?",
            isPresented: $showPurgeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await executePurge() }
            }
            Button("Keep Them", role: .cancel) {}
        } message: {
            Text("Deletes them on this Mac. To delete them on your other Macs too, update Dictator on each one and let it reconnect. This can’t be undone.")
        }
    }

    private func purgePreviewDetails(_ preview: PurgePreviewSummary) -> some View {
        let apps = preview.localBySurface.sorted { $0.value > $1.value }
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.key) { index, item in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: DSSpace.xs) {
                        Text(item.key).font(.dsBodyMedium)
                        Spacer()
                        Text("\(item.value)").font(.dsSecondary.monospacedDigit()).foregroundStyle(Color.dsTextSecondary)
                    }
                    .padding(.horizontal, DSSpace.m)
                    .padding(.vertical, DSSpace.s)
                }
            }
        }
        .frame(maxHeight: 220)
        .dsCardSurface()
    }

    // MARK: - Status

    // MARK: - Purge

    /// Scans `entries` (an exhaustive fetch — see `runPurgePreview`) for rows
    /// the current Prompts settings would no longer save.
    private func computeIgnoredLocalEntries(from entries: [DictationEntryDTO]) -> (total: Int, bySurface: [String: Int], entries: [DictationEntryDTO]) {
        var ignored: [DictationEntryDTO] = []
        var bySurface: [String: Int] = [:]

        for entry in entries {
            let host = entry.destinationURL.flatMap { SurfacePolicy.extractHost(from: $0) }
            let bundleID = entry.destinationAppBundleId
            let modality = entry.modality ?? "voice"
            let catalog = ToolCatalog.shared
            let context = CaptureContext(
                toolID: entry.toolId ?? catalog.tool(forHost: host)?.id
                    ?? catalog.tool(forBundleID: bundleID).flatMap { $0.category == .editor ? nil : $0.id },
                appBundleID: bundleID,
                webHost: host,
                remoteHost: entry.remoteHost
            )
            let action = settings.surfacePolicy.decide(context, modality: modality).action
            if action == .ignore {
                ignored.append(entry)
                let label: String
                if let toolID = context.toolID, let tool = catalog.tool(id: toolID) {
                    label = tool.name
                } else if let host, !host.isEmpty {
                    label = host
                } else if let bundleID, !bundleID.isEmpty {
                    label = bundleID
                } else {
                    label = entry.destinationAppName ?? "unknown"
                }
                bySurface[label, default: 0] += 1
            }
        }
        return (ignored.count, bySurface, ignored)
    }

    /// Purge previews scan this Mac's own store and capture exactly the IDs
    /// removed locally. Updated peers apply the durable deletion proof when
    /// they sync; the preview does not claim to inspect another Mac's store.
    @MainActor
    private func runPurgePreview() async {
        guard let hub else { return }
        isPreviewingPurge = true
        purgePreview = nil
        purgeErrorMessage = nil
        purgeStatusMessage = nil
        do {
            // Purge must see the whole store — an exhaustive on-demand
            // fetch, triggered only by this explicit user action.
            let repo = hub.current
            let version = hub.historyVersion
            let allEntries = try await repo.history.allEntries()
            let localComputation = computeIgnoredLocalEntries(from: allEntries)
            purgePreview = PurgePreviewSummary(
                localTotal: localComputation.total,
                localBySurface: localComputation.bySurface,
                localEntryIds: localComputation.entries.map(\.id),
                repository: repo,
                historyVersion: version
            )
        } catch {
            purgeErrorMessage = "Could not read history: \(error.localizedDescription)"
        }
        isPreviewingPurge = false
    }

    /// Deletes exactly the ids captured by `runPurgePreview`, guarded by
    /// the repository identity and history version captured at that same
    /// moment — never a recomputed set against whatever `hub.current` is by
    /// the time this `await`s finish.
    @MainActor
    private func executePurge() async {
        guard let hub, let preview = purgePreview else { return }
        isPurging = true
        purgeErrorMessage = nil
        purgeStatusMessage = nil

        if let error = await HistoryDestructiveAction.delete(
            ids: preview.localEntryIds,
            boundTo: preview.repository,
            hub: hub,
            expectedVersion: preview.historyVersion
        ) {
            purgePreview = nil
            purgeErrorMessage = "History was not deleted: \(error)"
            isPurging = false
            return
        }

        // No explicit `reloadHistory()` here: the repository delete
        // above bumps `hub.historyVersion`, and `.onChange(of: hub?.historyVersion)`
        // already drives the one reload path for "Recently Seen Surfaces".
        purgePreview = nil
        await runPurgePreview()
        purgeStatusMessage = "Deleted \(preview.localEntryIds.count) item\(preview.localEntryIds.count == 1 ? "" : "s") from this Mac."
        isPurging = false
    }
}
