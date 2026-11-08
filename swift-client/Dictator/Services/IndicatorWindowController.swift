import AppKit
import QuartzCore
import SwiftUI

/// Borderless window that never steals focus - safe for an LSUIElement menu bar app.
final class FloatingIndicatorWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Borderless floating window on the active screen.
/// Shows a poster-style microphone badge, bolts firing with the voice, while the walkie-talkie hotkey is held.
@MainActor
final class IndicatorWindowController {
    private var window: FloatingIndicatorWindow?
    private let model = WalkieTalkieIndicatorModel()
    private let overlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    /// Phase the visible window is laid out for — `nil` while hidden — so
    /// `followPointer()` can re-place it in the same style when the pointer
    /// moves to another screen mid-session.
    private var visiblePhase: WalkieTalkieIndicatorPhase?

    /// Shows "Stopping in N…" beside the badge while recording; `nil` clears
    /// it. Only affects a visible, recording indicator.
    func setCountdown(_ seconds: Int?) {
        let active = seconds != nil && visiblePhase == .recording
        let changedLayout = (model.countdown != nil) != active
        model.countdown = active ? seconds : nil
        if changedLayout { resizeAndPosition(for: .recording, animated: false) }
    }

    func prepare() {
        if window == nil { build() }
        model.setRecording()
        resizeAndPosition(for: .recording, animated: false)
        window?.orderOut(nil)
    }

    /// Whether the indicator is showing voice launch mode right now.
    var showsVoiceLaunch: Bool { model.voiceLaunch }

    /// Repeating this mid-recording is fine: it's how voice launch mode
    /// appears the moment the chord is caught, and how the Mac the pointer
    /// moves to picks it up.
    func show(voiceLaunch: Bool = false) {
        if window == nil { build() }
        model.setRecording()
        model.voiceLaunch = voiceLaunch
        visiblePhase = .recording
        resizeAndPosition(for: .recording, animated: false)
        window?.orderFrontRegardless()
        window?.displayIfNeeded()
    }

    func showProcessing() {
        if window == nil { build() }
        model.setProcessing()
        // Animate only when staying on the same screen: an animated frame
        // change across displays is unreliable, and a jump is what the user
        // expects there anyway.
        let stayingOnScreen = window.map { Self.activeScreen()?.frame.contains($0.frame.origin) ?? false } ?? false
        visiblePhase = .processing
        model.countdown = nil
        resizeAndPosition(for: .processing, animated: stayingOnScreen)
        window?.orderFrontRegardless()
        window?.displayIfNeeded()
    }

    func hide() {
        visiblePhase = nil
        model.countdown = nil
        window?.orderOut(nil)
        model.reset()
    }

    /// Re-places a visible indicator on the screen the pointer is on now.
    /// Driven by `EdgeRuntime` from the throttled mouse-movement hook, so
    /// the meter/spinner follows the pointer between this Mac's screens the
    /// same way it follows it between Macs. No-op while hidden or when the
    /// pointer is still on the window's screen.
    func followPointer() {
        // Compared by frame, not by `NSScreen` identity — AppKit hands out
        // fresh `NSScreen` instances often enough that an identity check
        // misfires both ways.
        guard let phase = visiblePhase, let window, let frame = targetFrame(for: phase), window.frame != frame else { return }
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        Self.logPlacement("follow phase=\(phase)", requested: frame, window: window)
    }

    func updateLevel(_ level: Float) {
        model.push(level)
    }

    private func build() {
        let size = WalkieTalkieIndicatorView.size(for: model.phase)
        let host = NSHostingView(rootView: WalkieTalkieIndicatorView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor

        let w = FloatingIndicatorWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.contentView = host
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = overlayLevel
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.hidesOnDeactivate = false
        w.setContentSize(size)
        window = w
    }

    private func rebuild() {
        window?.orderOut(nil)
        window = nil
    }

    /// Where the indicator belongs for `phase`: bottom-centre of the screen
    /// the pointer is on right now.
    private func targetFrame(for phase: WalkieTalkieIndicatorPhase) -> NSRect? {
        guard let screen = Self.activeScreen() else { return nil }
        let size = WalkieTalkieIndicatorView.size(for: phase, label: model.hasLabel)
        let visible = screen.visibleFrame
        return NSRect(x: visible.midX - size.width / 2, y: visible.minY + 12, width: size.width, height: size.height)
    }

    private func resizeAndPosition(for phase: WalkieTalkieIndicatorPhase, animated: Bool) {
        guard let window, let frame = targetFrame(for: phase) else {
            NSLog("[Indicator] position skipped - window=%d screen=%d",
                  self.window != nil ? 1 : 0, NSScreen.screens.isEmpty ? 0 : 1)
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
        Self.logPlacement("position phase=\(phase) animated=\(animated)", requested: frame, window: window)
    }

    /// Placement diagnostics into hotkey.log (the unified log drops this
    /// app's NSLog output on current macOS): where the pointer is, which
    /// screen was chosen, and the frame AppKit actually applied.
    private static func logPlacement(_ what: String, requested: NSRect, window: NSWindow) {
        let mouse = livePointerLocation()
        let chosen = activeScreen().map { "\($0.localizedName) \(NSStringFromRect($0.frame))" } ?? "none"
        HotkeyService.recordDiagnostics(
            "indicator \(what) mouse=\(NSStringFromPoint(mouse)) screen=[\(chosen)] requested=\(NSStringFromRect(requested)) applied=\(NSStringFromRect(window.frame)) onScreen=\(window.screen?.localizedName ?? "nil")"
        )
    }

    /// Live pointer position in AppKit screen coordinates. Deliberately not
    /// `NSEvent.mouseLocation`: in this app (no windows that receive mouse
    /// events) it lagged one screen crossing behind — it only refreshed on
    /// the window-server round-trip inside `setFrame`, so every
    /// `followPointer()` placed the indicator on the screen the pointer had
    /// just left. `CGEvent(source:)` asks the window server directly.
    static func livePointerLocation() -> NSPoint {
        // The tap's last event location is the only reading that is current
        // at the moment a screen crossing is handled; `CGEvent(source:)`
        // showed the same one-crossing lag as `NSEvent.mouseLocation`.
        guard let cg = PointerLocationTracker.shared.current ?? CGEvent(source: nil)?.location,
              let primary = NSScreen.screens.first else {
            return NSEvent.mouseLocation
        }
        // CG is top-left origin of the primary display; AppKit is bottom-left.
        return NSPoint(x: cg.x, y: primary.frame.height - cg.y)
    }

    /// The screen the pointer is on, where the indicator and notices appear.
    static func activeScreen() -> NSScreen? {
        let mouseLocation = livePointerLocation()
        return NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

}
