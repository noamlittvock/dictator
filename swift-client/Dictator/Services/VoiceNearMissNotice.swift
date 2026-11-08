import AppKit
import SwiftUI

/// The notice shown on the Mac where words would have landed when they were
/// close to a shortcut: what was heard with the unknown name as "norm?",
/// then "Did you mean…?". It stays until
/// the person picks, dismisses it, or a minute passes.
struct VoiceNearMissNoticeView: View {
    let miss: VoiceNearMiss
    let onEntry: (Int, String) -> String?
    let onVoiceCommand: (String) -> String?
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DSSpace.s) {
            Image(systemName: "questionmark.bubble.fill").font(.dsIconLarge).foregroundStyle(Color.dsPanelTextSecondary).padding(.top, DSSpace.hair)
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                // Every near miss keeps the words on the clipboard rather than typing them.
                Text("Your words are on the clipboard.").font(.dsCaption).foregroundStyle(Color.dsPanelTextSecondary)
                VoiceNearMissFixView(miss: miss, onEntry: onEntry, onVoiceCommand: onVoiceCommand)
                    .foregroundStyle(Color.dsPanelText)
                    .buttonStyle(.dsSecondary)
                    .tint(Color.dsPanelAccent)
                Button(action: onClose) {
                    Text("Dismiss").foregroundStyle(Color.dsPanelAccent)
                }
                .buttonStyle(.dsLink)
            }
            .frame(width: 340, alignment: .leading)
        }
        .padding(DSSpace.m)
        .dsPanel()
        .padding(DSSpace.xs)
    }
}

@MainActor
final class VoiceNearMissNoticeController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ miss: VoiceNearMiss,
              onEntry: @escaping (Int, String) -> String?, onVoiceCommand: @escaping (String) -> String?) {
        hideTask?.cancel()
        let view = VoiceNearMissNoticeView(miss: miss, onEntry: onEntry, onVoiceCommand: onVoiceCommand,
                                           onClose: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = self.panel ?? .floatingNotice()
        panel.contentView = host
        if let screen = IndicatorWindowController.activeScreen() {
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 24, width: size.width, height: size.height + 36), display: true)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}
