import AppKit
import AVFoundation
import Network
import SwiftUI

/// A problem with a dictation, said plainly: what went wrong, what to do,
/// and (optionally) where to fix it. Shown by `DictationAlertController`
/// on the Mac the user pressed the key on.
struct DictationAlert: Equatable {
    enum Action: String, Equatable {
        case general, macs, dictation, history, advanced, voiceLaunch
        case microphonePrivacy, accessibilityPrivacy

        var title: String {
            switch self {
            case .general: "Open Settings"
            case .macs: "Open Your Macs"
            case .dictation: "Open Dictation Settings"
            case .voiceLaunch: "Open Commands"
            case .history: "Open History & Privacy"
            case .advanced: "Open Advanced Settings"
            case .microphonePrivacy, .accessibilityPrivacy: "Open System Settings"
            }
        }
    }

    enum Tone { case problem, notice }

    var title: String
    var detail: String
    var action: Action?
    var tone: Tone = .problem

    static func voiceCommandTie(heard: String, names: [String]) -> DictationAlert {
        DictationAlert(title: "More than one command fits “\(heard)”",
                       detail: "\(names.map { "“\($0)”" }.joined(separator: ", ")) fit these words. Turn one off or change what you say in Commands. Your words are on the clipboard.",
                       action: .voiceLaunch, tone: .notice)
    }

    // MARK: Carried in `SessionOutcome.failed(message:)`

    /// Failure messages built by the Core are "title\ndetail" with an
    /// optional third line "action:<name>"; anything else (an older peer)
    /// is shown as the detail of a generic title.
    var encoded: String {
        ([title, detail] + (action.map { ["action:\($0.rawValue)"] } ?? [])).joined(separator: "\n")
    }

    static func decode(failure message: String) -> DictationAlert {
        let lines = message.components(separatedBy: "\n")
        guard lines.count >= 2 else {
            return DictationAlert(title: "Dictation didn’t work", detail: message)
        }
        var action: Action?
        if lines.count >= 3, lines[2].hasPrefix("action:") {
            action = Action(rawValue: String(lines[2].dropFirst("action:".count)))
        }
        return DictationAlert(title: lines[0], detail: lines[1], action: action)
    }

    // MARK: Common problems

    /// Actionable speech configuration errors take precedence if every backup also fails.
    /// `serverMacName` is the Mac the key comes from, when the setup knows it.
    /// `canReconnect` is for a connected Mac that lost its main Mac, which
    /// normally answers for it, so reconnecting fixes this without any key.
    static func speechConfigurationFailure(
        _ error: Error, requestFromOtherMac: Bool = false, mainMacName: String? = nil,
        serverMacName: String? = nil, canReconnect: Bool = false
    ) -> DictationAlert? {
        // Direct recovery can ask the main Mac over the existing string-error reply.
        // Preserve its encoded alert without adding a new wire field or message type.
        if case RepositoryError.unavailable(let message) = error {
            let alert = decode(failure: message)
            if alert.action == .advanced { return alert }
        }
        if case TranscriptionError.authenticationRequired = error {
            let location = mainMacName.map { "the main Mac (\($0))" } ?? "the main Mac"
            let copy = "copy its key in Settings › Advanced on \(serverMacName ?? "the Mac that runs the speech server")"
            let kept = "Your recording is kept in History & Privacy so you can try again."
            let steps = requestFromOtherMac
                ? "On that Mac, \(copy), then paste it in Settings › Advanced on \(location)."
                : canReconnect
                    ? "Reconnect this Mac to your main Mac, or \(copy) and paste it in Settings › Advanced here."
                    : "On that Mac, \(copy), then paste it in Settings › Advanced here."
            return DictationAlert(title: "The speech server needs its key", detail: "\(steps) \(kept)",
                                  action: requestFromOtherMac ? nil : .advanced)
        }
        if error is SpeechEndpointError || error is ServiceEndpointError {
            return DictationAlert(title: "Check the speech server address",
                                  detail: "\(error.localizedDescription) Your recording is kept in History & Privacy so you can try again.",
                                  action: .advanced)
        }
        return nil
    }

    static func microphoneOnAnotherMac() -> DictationAlert {
        DictationAlert(title: "This Mac has no microphone",
                       detail: "Dictator only listens through another Mac if you choose it. Pick one under Mac that records in Settings › Your Macs.",
                       action: .macs)
    }

    static func dictationStillFinishing() -> DictationAlert {
        DictationAlert(title: "Still finishing your last dictation",
                       detail: "Nothing was recorded from that press. Wait a moment, then press the key again.")
    }

    static func noMicrophone() -> DictationAlert {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            return DictationAlert(
                title: "Dictator can’t use the microphone",
                detail: "Allow it in System Settings › Privacy & Security › Microphone, then try again.",
                action: .microphonePrivacy
            )
        }
        return DictationAlert(
            title: "No microphone found",
            detail: "Connect a microphone, or check which one is chosen in Settings › General.",
            action: .general
        )
    }

    static func cancelled(_ reason: CancelReason) -> DictationAlert? {
        switch reason {
        case .user:
            return nil
        case .noAudio:
            return DictationAlert(title: BrandVoice.nothingHeard,
                                  detail: "The microphone didn’t pick anything up. Check that the right one is chosen in Settings › General.",
                                  action: .general)
        case .micLost:
            return DictationAlert(title: BrandVoice.microphoneStopped,
                                  detail: "Check the microphone, then retry in History & Privacy. What was recorded is kept there.",
                                  action: .history)
        case .initiatorLost, .targetLost:
            return DictationAlert(title: "Lost the connection to your other Mac",
                                  detail: "What was recorded is kept in History & Privacy. Check that both Macs are on and connected to Tailscale.",
                                  action: .history)
        case .watchdog:
            return .recordingLimitReached
        }
    }

    static let recordingLimitReached = DictationAlert(
        title: "Recording stopped at 2 minutes",
        detail: "What you said was kept and is being turned into text. Start another dictation to keep going.",
        tone: .notice
    )

    static let nothingHeard = DictationAlert(
        title: "No words were heard",
        detail: "Try again a little closer to the microphone.",
        tone: .notice
    )

    static func clipboardOnly(reason: String, needsAccessibility: Bool) -> DictationAlert {
        if needsAccessibility {
            return DictationAlert(title: "Your words are on the clipboard",
                                  detail: "Dictator needs Accessibility permission to type it for you. Paste it with ⌘V for now.",
                                  action: .accessibilityPrivacy, tone: .notice)
        }
        return DictationAlert(title: "Your words are on the clipboard",
                              detail: "Dictator couldn’t type it for you this time. Paste it with ⌘V where you want it.",
                              tone: .notice)
    }

    @MainActor
    func perform() {
        switch action {
        case .general: AppNavigation.shared.openSettings(.general)
        case .macs: AppNavigation.shared.openSettings(.macs)
        case .dictation: AppNavigation.shared.openSettings(.dictation)
        case .voiceLaunch:
            AppNavigation.shared.mainSelection = .voiceLaunch
            AppNavigation.shared.mainWindowRequests += 1
        case .history: AppNavigation.shared.openSettings(.history)
        case .advanced: AppNavigation.shared.openSettings(.advanced)
        case .microphonePrivacy:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case .accessibilityPrivacy:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case nil:
            break
        }
    }
}

/// Whether this Mac has a network connection at all.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.satisfied = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "dev.noamlitt.dictator.network-status"))
    }

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied
    }
}

// MARK: - On screen

/// Shows a `DictationAlert` as a card at the bottom of the screen the
/// pointer is on, where the dictation badge appears. Clicking it opens the
/// place to fix the problem; it goes away by itself after a few seconds.
@MainActor
final class DictationAlertController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private(set) var current: DictationAlert?

    func show(_ alert: DictationAlert) {
        current = alert
        HotkeyService.recordDiagnostics("alert shown: \(alert.title)")
        let view = DictationAlertView(alert: alert,
                                      onAction: { [weak self] in
                                          alert.perform()
                                          self?.hide()
                                      },
                                      onClose: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = self.panel ?? .floatingNotice()
        panel.contentView = host
        if let screen = IndicatorWindowController.activeScreen() {
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 24, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        hideTask?.cancel()
        let seconds: Double = alert.action == nil ? 5 : 9
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
        current = nil
    }
}

extension NSPanel {
    /// A borderless card above every app and on every Space that never takes
    /// focus from the app being dictated into: the shape of every alert and
    /// notice Dictator shows.
    static func floatingNotice() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

struct DictationAlertView: View {
    let alert: DictationAlert
    let onAction: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DSSpace.s) {
            Image(systemName: alert.tone == .problem ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.dsIconLarge)
                .foregroundStyle(alert.tone == .problem ? Color.dsPanelWarning : Color.dsPanelTextSecondary)
                .padding(.top, DSSpace.hair)
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text(alert.title)
                    .font(.dsSection)
                    .foregroundStyle(Color.dsPanelText)
                Text(alert.detail)
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsPanelTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = alert.action {
                    Button(action: onAction) {
                        Text(action.title).foregroundStyle(Color.dsPanelAccent)
                    }
                    .buttonStyle(.dsLink)
                    .padding(.top, DSSpace.hair)
                }
            }
            .frame(width: 330, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.dsIconSmall).foregroundStyle(Color.dsPanelTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(DSSpace.m)
        .dsPanel()
        .padding(DSSpace.xs)
    }
}

/// A dictation failure whose message is a `DictationAlert` (it travels to
/// the Mac the user dictated on inside `SessionOutcome.failed`).
struct DictationFailure: Error, LocalizedError {
    let alert: DictationAlert
    init(_ alert: DictationAlert) { self.alert = alert }
    var errorDescription: String? { alert.encoded }
}
