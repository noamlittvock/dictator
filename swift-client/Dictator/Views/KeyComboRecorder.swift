import AppKit
import SwiftUI

/// Click, then press any key or combination. Dictation is off while this
/// listens, so the keys pressed here do nothing else.
struct KeyComboRecorder: View {
    let label: String
    let combo: KeyCombo
    let isDefault: Bool
    let problem: (KeyCombo) -> String?
    let save: (KeyCombo) -> Void
    let reset: () -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var capture = KeyComboCapture()
    @State private var message = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: DSSpace.xxs) {
            HStack(spacing: DSSpace.xs) {
                if !isDefault && !recording {
                    Button { message = ""; reset() } label: {
                        Image(systemName: "arrow.uturn.backward").font(.dsIcon)
                    }
                    .buttonStyle(.dsQuiet)
                    .help("Go back to the usual keys")
                    .accessibilityLabel("Go back to the usual keys")
                }
                Button(action: { recording ? stop() : start() }) {
                    Text(recording ? "Press the keys…" : combo.displayName)
                }
                .accessibilityLabel(label)
                .accessibilityValue(recording ? "Press the keys" : combo.displayName)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsWarning)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func start() {
        message = ""
        capture = KeyComboCapture()
        recording = true
        WorkspaceLaunchController.shared.beginShortcutRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        WorkspaceLaunchController.shared.endShortcutRecording()
    }

    private func handle(_ event: NSEvent) {
        guard recording else { return }
        let key = DictationKey(keyCode: event.keyCode)
        if event.type == .flagsChanged {
            if key.isModifier {
                let isDown = event.modifierFlags.rawValue & UInt(key.deviceFlag.rawValue) != 0
                if let combo = capture.modifier(key.keyCode, isDown: isDown) { finish(combo) }
            } else {
                finish(capture.regularKey(key.keyCode)) // Caps Lock reports here.
            }
        } else if !event.isARepeat {
            let combo = capture.regularKey(key.keyCode)
            if combo == KeyCombo([53]) { stop() } else { finish(combo) }
        }
    }

    private func finish(_ combo: KeyCombo) {
        stop()
        if let issue = problem(combo) {
            message = issue
        } else {
            save(combo)
            message = KeyComboRules.caution(combo) ?? ""
        }
    }
}

/// The keys that start dictation on this Mac.
struct DictationKeysRecorder: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        KeyComboRecorder(label: "Keys that start dictation", combo: settings.dictationKeys, isDefault: settings.dictationKeys == KeyCombo(.rightOption)) { combo in
            KeyComboRules.problem(combo, role: .dictation, dictation: settings.dictationKeys,
                                  customCommands: settings.customCommandKeys, shortcuts: settings.keyboardShortcuts)
        } save: { apply($0) } reset: { apply(KeyCombo(.rightOption)) }
    }

    private func apply(_ combo: KeyCombo) {
        settings.dictationKeys = combo
        DictatorViewModel.shared.applyDictationKey()
    }
}

/// The keys that run a command on this Mac.
struct CommandKeysRecorder: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        KeyComboRecorder(label: "Keys that run a command", combo: settings.hotkeyTriggers.commands, isDefault: settings.customCommandKeys == nil) { combo in
            KeyComboRules.problem(combo, role: .commands, dictation: settings.dictationKeys,
                                  customCommands: settings.customCommandKeys, shortcuts: settings.keyboardShortcuts)
        } save: { apply($0) } reset: { apply(nil) }
    }

    private func apply(_ combo: KeyCombo?) {
        settings.customCommandKeys = combo
        DictatorViewModel.shared.applyDictationKey()
    }
}

extension AppSettings {
    /// The keyboard shortcuts of every routine and command.
    var keyboardShortcuts: [WorkspaceHotkey] {
        workspaceLaunch.routines.compactMap(\.hotkey) + voiceLaunch.commands.compactMap(\.hotkey)
    }
}
