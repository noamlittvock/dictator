import AppKit

/// Quitting waits for a dictation to finish, so an update or a quit never
/// cuts off someone mid-sentence. This Mac may not be the one being spoken
/// into: a main Mac carries every other Mac's dictation.
///
/// Installers ask with SIGTERM rather than an Apple event, which needs
/// Automation permission that a script run over SSH doesn't have. Both end up
/// in `applicationShouldTerminate`.
@MainActor
final class QuitGuard {
    /// Longer than the longest dictation and its processing, and shorter than
    /// the installers' `QUIT_WAIT`, which falls back to SIGKILL.
    static let longestWait: TimeInterval = 180

    private let diagnostics: (String) -> Void

    init(diagnostics: @escaping (String) -> Void = { HotkeyService.recordDiagnostics($0) }) {
        self.diagnostics = diagnostics
    }

    private var signalSource: DispatchSourceSignal?
    private var poweringOff = false
    private var powerObserver: NSObjectProtocol?
    private var waiting = false

    func start() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source
        powerObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poweringOff = true }
        }
    }

    func shouldTerminate(isBusy: @escaping @MainActor () -> Bool,
                         hasParkedWindows: @escaping @MainActor () -> Bool = { false },
                         returnParkedWindows: @escaping @MainActor () async -> Void = {},
                         finished: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        // Logout skips the dictation wait, but still gives parked windows their
        // short restoration budget. Crash records cover an interrupted logout.
        guard (!poweringOff && isBusy()) || hasParkedWindows() else { return .terminateNow }
        guard !waiting else { return .terminateLater }
        waiting = true
        diagnostics("quit: waiting for a dictation to finish")
        Task {
            if !poweringOff {
                let finishedCleanly = await Self.waitUntilIdle(isBusy: isBusy)
                diagnostics("quit: \(finishedCleanly ? "dictation finished" : "gave up waiting")")
            }
            if hasParkedWindows() { await Self.returnWindowsBeforeQuit(returnParkedWindows) }
            finished()
        }
        return .terminateLater
    }

    /// Do not use a task group here: its scope would wait for a stuck AX task
    /// even after cancellation. The timeout resumes the caller independently.
    static func returnWindowsBeforeQuit(_ restore: @escaping @MainActor () async -> Void,
                                        limit: TimeInterval = 2) async {
        await withCheckedContinuation { continuation in
            var replied = false
            var timeout: Task<Void, Never>?
            let work = Task { @MainActor in
                await restore()
                guard !replied else { return }
                replied = true
                timeout?.cancel()
                continuation.resume()
            }
            timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(limit))
                guard !replied else { return }
                replied = true
                work.cancel()
                continuation.resume()
            }
        }
    }

    /// True when the dictation ended, false when `limit` ran out first.
    static func waitUntilIdle(
        isBusy: @MainActor () -> Bool, limit: TimeInterval = longestWait, poll: TimeInterval = 0.25,
        sleep: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) async -> Bool {
        var waited: TimeInterval = 0
        while isBusy() {
            guard waited < limit else { return false }
            await sleep(poll)
            waited += poll
        }
        return true
    }
}
