import AppKit
import Observation
import SwiftUI

/// The card that follows a voice launch: the shortcut's name, then each
/// step with a tick as it finishes. Sits where the dictation badge and
/// `DictationAlert` cards appear, in the same dark style.
@MainActor
@Observable
final class VoiceLaunchProgressModel {
    var progress: VoiceLaunchProgress?
}

struct VoiceLaunchProgressView: View {
    let model: VoiceLaunchProgressModel

    var body: some View {
        if let progress = model.progress {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                if let phrase = progress.phrase {
                    SpokenPhraseView(segments: phrase, fontSize: 13, textColor: .dsPanelText, captionColor: .dsPanelTextSecondary,
                                     keyTextColor: .dsPanelBackground, symbolColor: .dsPanelAccent)
                } else {
                    Text(progress.commandName)
                        .font(.dsSection)
                        .foregroundStyle(Color.dsPanelText)
                }
                ForEach(Array(progress.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: DSSpace.xs) {
                        icon(row.state).frame(width: 14)
                        VStack(alignment: .leading, spacing: DSSpace.hair) {
                            Text(row.text)
                                .font(.dsBodyMedium)
                                .foregroundStyle(row.state == .waiting ? Color.dsPanelTextSecondary : Color.dsPanelText)
                                .fixedSize(horizontal: false, vertical: true)
                            if let note = row.note {
                                Text(note).font(.dsSecondaryMedium).foregroundStyle(Color.dsPanelWarning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .frame(width: 330, alignment: .leading)
            .padding(DSSpace.m)
            .dsPanel()
            .padding(DSSpace.xs)
        }
    }

    @ViewBuilder private func icon(_ state: VoiceLaunchProgress.State) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle").font(.dsIconSmall).foregroundStyle(Color.dsPanelTextSecondary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark").font(.dsIconSmall).foregroundStyle(Color.dsPanelSuccess)
        case .cancelled: Image(systemName: "hand.raised.fill").font(.dsIconSmall).foregroundStyle(Color.dsPanelTextSecondary)
        case .failed: Image(systemName: "xmark").font(.dsIconSmall).foregroundStyle(Color.dsPanelWarning)
        }
    }
}

@MainActor
final class VoiceLaunchProgressController {
    private let model = VoiceLaunchProgressModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// Shows the shortcut and its steps, all waiting.
    func begin(_ plan: VoiceLaunchPlan) {
        hideTask?.cancel()
        let pattern = AppSettings.shared.voiceLaunch.commands.first { $0.id == plan.commandId }?.pattern
        model.progress = VoiceLaunchProgress(plan: plan, pattern: pattern)
        let host = NSHostingView(rootView: VoiceLaunchProgressView(model: model))
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        panel.contentView = host
        place(panel, size: size, raised: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func apply(_ event: VoiceLaunchProgress.Event) {
        model.progress?.apply(event)
    }

    /// Leaves the result on screen a moment. After a failure the alert card
    /// takes the usual place, so this one moves above it.
    func end() {
        guard let panel, let progress = model.progress else { return }
        if progress.hasFailed, let host = panel.contentView { place(panel, size: host.fittingSize, raised: true) }
        hideTask?.cancel()
        let seconds: Double = progress.hasFailed ? 6 : 1.5
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        model.progress = nil
    }

    private func place(_ panel: NSPanel, size: NSSize, raised: Bool) {
        guard let screen = IndicatorWindowController.activeScreen() else { return }
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 24 + (raised ? 120 : 0), width: size.width, height: size.height), display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel.floatingNotice()
        panel.ignoresMouseEvents = true
        return panel
    }
}
