import AppKit
import SwiftUI

/// Kept separate from the app restrictions section of the command editor.
struct VoiceCommandTriggersView: View {
    @Binding var command: VoiceCommand
    let config: VoiceLaunchConfig
    private var needsSpeech: Bool { VoiceCommandWithoutSpeech.needsSpokenWords(command) }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                HStack {
                    Text("Keyboard shortcut").font(.dsBodyMedium)
                    Spacer()
                    if !needsSpeech {
                        WorkspaceHotkeyRecorder(hotkey: $command.hotkey) { key in
                            var draft = command
                            draft.hotkey = key
                            return VoiceCommandHotkeys.problem(for: draft, commands: config.commands,
                                routines: AppSettings.shared.workspaceLaunch.routines,
                                triggers: AppSettings.shared.hotkeyTriggers)
                        }
                    } else if command.hotkey != nil {
                        Button("Remove keyboard shortcut") { command.hotkey = nil }
                    }
                }
                Text(needsSpeech ? "This command needs spoken words, so it cannot run from the keyboard." : "Runs this command without speaking.")
                    .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                if command.enabled, command.hotkey != nil,
                   let reason = WorkspaceLaunchController.shared.commandHotkeyFailures[command.id] {
                    Text(reason).font(.dsSecondary).foregroundStyle(Color.dsWarning)
                }
            }
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                HStack(spacing: DSSpace.m) {
                    Text("Let other apps start this").font(.dsBodyMedium)
                    Spacer()
                    Toggle("Let other apps start this", isOn: $command.runsFromOtherApps)
                        .labelsHidden().toggleStyle(.switch)
                }
                Text("Other apps can start it with a dictator:// link.")
                    .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                if command.runsFromOtherApps {
                    if needsSpeech {
                        Text("This command needs spoken words, so a link cannot run it.")
                            .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                    }
                    if let link = VoiceCommandURL.link(for: command) {
                        HStack {
                            Text(link.absoluteString).font(.dsSecondary).textSelection(.enabled)
                                .lineLimit(2).truncationMode(.middle)
                            Button("Copy link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link.absoluteString, forType: .string)
                            }
                        }
                    }
                }
            }
        }
    }
}
