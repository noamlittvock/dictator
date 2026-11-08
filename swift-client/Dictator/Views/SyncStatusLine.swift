import SwiftUI

/// One caption line: where this Mac's history lives relative to the Core
/// and whether anything is still waiting to replicate. Shown at the top of
/// the History feed and the Dictionary, and mirrored in the menu bar.
struct SyncStatusLine: View {
    @Bindable var viewModel: DictatorViewModel
    var loading: Bool

    var body: some View {
        HStack(spacing: DSSpace.xs) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: viewModel.syncSymbol)
                    .font(.dsIconSmall)
            }
            Text(loading ? "Loading…" : viewModel.syncStatusText)
                .font(.dsCaption)
                .lineLimit(1)
            if viewModel.syncCanRunNow {
                Button("Sync Now") { viewModel.syncNow() }
                    .buttonStyle(.dsQuiet)
                    .controlSize(.small)
                    .font(.dsCaptionMedium)
                    .foregroundStyle(Color.dsAccent)
                    .help("Sync this Mac’s history with your main Mac now")
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(viewModel.syncIsHealthy ? Color.dsTextTertiary : Color.dsWarning)
    }
}
