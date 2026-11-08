import SwiftUI

struct MainWindowView: View {
    @State private var historyModel = HistoryFeedModel()
    @State private var selectedItem: SidebarItem = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var navigation = AppNavigation.shared
    @State private var settings = AppSettings.shared
    @State private var showWelcome = false

    var body: some View {
        GeometryReader { viewport in
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(selection: $selectedItem)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 220)
            } detail: {
                GeometryReader { detailViewport in
                    detailView
                        .frame(
                            width: detailViewport.size.width,
                            height: detailViewport.size.height,
                            alignment: .topLeading
                        )
                        .clipped()
                        .background(Color.dsBgContent)
                }
            }
            // Keep a detail screen's ideal content size from expanding and
            // vertically centering the entire split view beyond the window.
            .frame(width: viewport.size.width, height: viewport.size.height)
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 820, minHeight: 560)
        .tint(Color.dsAccent)
        .font(.dsBody)
        .buttonStyle(.dsSecondary)
        .onAppear {
            // Dictation first: the optional typed history is offered at the
            // end of the welcome, never on its own at first open.
            if !settings.didCompleteWelcome { showWelcome = true }
            consumeNavigation()
        }
        .onChange(of: navigation.mainSelection) { _, _ in consumeNavigation() }
        .sheet(isPresented: $showWelcome) {
            WelcomeView { wantsTypedHistory in
                showWelcome = false
                if wantsTypedHistory {
                    // Present after this sheet has gone.
                    DispatchQueue.main.async { navigation.showPromptSetup = true }
                }
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $navigation.showPromptSetup) {
            PromptSetupView { navigation.showPromptSetup = false }
        }
    }

    private func consumeNavigation() {
        if let item = navigation.mainSelection {
            selectedItem = item
            navigation.mainSelection = nil
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedItem {
        case .home:
            VStack(spacing: 0) {
                HomeBrandHeader(keys: settings.hotkeyTriggers)
                PromptCaptureSetupBanner().dsPageFrame(.wide)
                HomeRecoveryNotice().dsPageFrame(.wide)
                RecentCommandsView()
                HistoryView(model: historyModel)
            }
        case .datasets:
            DatasetView()
        case .workspaceLaunch:
            WorkspaceLaunchView()
        case .voiceLaunch:
            VoiceLaunchView()
        case .dictionary:
            DictionaryView()
        case .settings:
            SettingsView()
        case .help:
            HelpView()
        }
    }
}

/// Recovery stays visible on Home, including the result after the last take is recovered.
struct HomeRecoveryNotice: View {
    @State private var viewModel = DictatorViewModel.shared

    var body: some View {
        Group {
            if let take = viewModel.recoverableTakes.first {
                RecoveryNoticeCard(count: viewModel.recoverableTakes.count, recordedAt: take.take.metadata.startedAt,
                                   retentionNote: take.retentionNote, busy: viewModel.isRecoveryBusy(take), notice: viewModel.recoveryNotice,
                                   recover: { Task { await viewModel.transcribeRecoveredTake(take) } },
                                   review: { AppNavigation.shared.openSettings(.history) })
            } else if let notice = viewModel.recoveryNotice {
                SettingsNotice(tone: .neutral, text: Text(notice))
                    .padding(.top, DSSpace.s)
            }
        }
        .onAppear { viewModel.refreshRecoverableTakes() }
    }
}

struct RecoveryNoticeCard: View {
    let count: Int
    let recordedAt: Date
    let retentionNote: String
    let busy: Bool
    let notice: String?
    let recover: () -> Void
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Label(BrandVoice.recordingsWaiting(count), systemImage: "waveform.badge.exclamationmark")
                .font(.dsSection)
                .foregroundStyle(Color.dsWarning)
            Text("Latest: \(recordedAt.formatted(date: .abbreviated, time: .shortened)). Turn it into text and copy it to the clipboard. Your history settings still apply.")
                .font(.dsBody)
            Text(retentionNote)
                .font(.dsSecondary)
                .foregroundStyle(Color.dsTextSecondary)
            if let notice { Text(notice).font(.dsBody) }
            HStack(spacing: DSSpace.s) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Turning into text…").font(.dsBody)
                } else {
                    Button("Turn into text", action: recover).buttonStyle(.dsPrimary)
                }
                Button("Review recordings…", action: review)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpace.m)
        .dsCardSurface(border: Color.dsWarning.opacity(0.4))
        .padding(.top, DSSpace.s)
    }
}
