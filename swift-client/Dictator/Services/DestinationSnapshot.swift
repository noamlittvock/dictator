import AppKit
import Darwin
import Foundation

struct DestinationSnapshot: Sendable {
    let appBundleId: String?
    let appName: String?
    let url: String?
    let insertionMethod: String
    /// Tool / surface attribution (which AI tool, which part of the app,
    /// which remote machine) — see `SurfaceResolver`.
    var context: CaptureContext? = nil

    /// How the text got there, in plain words. Typed prompts store their
    /// capture source here instead, which the entry already describes.
    static func insertionDescription(_ method: String?) -> String? {
        switch method {
        case "paste": "Pasted by Dictator"
        case "import": "Imported from another app"
        default: nil
        }
    }

    /// Resolving the destination is expensive: it reads the process table,
    /// asks Accessibility what has focus, and for a browser runs AppleScript
    /// for the front tab's URL. Callers on the main thread must use
    /// `resolved(insertionMethod:)` — doing this work inline froze the UI once
    /// the hotkey tap began delivering keystrokes from other apps.
    static func resolved(insertionMethod: String) async -> DestinationSnapshot {
        let (bundleID, appName, pid) = await MainActor.run { () -> (String?, String?, pid_t?) in
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.bundleIdentifier, app?.localizedName, app?.processIdentifier)
        }
        return await withCheckedContinuation { continuation in
            resolveQueue.async {
                continuation.resume(
                    returning: snapshot(insertionMethod: insertionMethod, bundleID: bundleID, appName: appName, pid: pid)
                )
            }
        }
    }

    /// Synchronous resolution. Blocks the calling thread — only for callers that
    /// cannot be async and are off the keystroke path.
    static func current(insertionMethod: String) -> DestinationSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        return snapshot(
            insertionMethod: insertionMethod,
            bundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            pid: app?.processIdentifier
        )
    }

    /// Serializes destination probes so cached frontmost-app state and spawned
    /// helper processes cannot race one another.
    private static let resolveQueue = DispatchQueue(
        label: "dev.noamlitt.dictator.destination-snapshot"
    )
    private static let cacheTTL: TimeInterval = 2
    private static let cacheLock = NSLock()
    private static var resolutionCache: (key: String, resolution: SurfaceResolution, at: Date)?

    private static func snapshot(
        insertionMethod: String,
        bundleID: String?,
        appName: String?,
        pid: pid_t?
    ) -> DestinationSnapshot {
        let resolution = resolve(bundleID: bundleID, appName: appName, pid: pid)
        return DestinationSnapshot(
            appBundleId: bundleID,
            appName: appName,
            url: resolution.context.url,
            insertionMethod: insertionMethod,
            context: resolution.context
        )
    }

    /// Short TTL cache. A burst of commits in the same app would otherwise
    /// re-run the whole probe per commit; the destination cannot
    /// meaningfully change within the window.
    static func resolve(bundleID: String?, appName: String?, pid: pid_t?) -> SurfaceResolution {
        guard let bundleID else { return .unknown(bundleID: nil, appName: appName) }
        let key = "\(bundleID)#\(pid ?? 0)"
        cacheLock.lock()
        let hit = resolutionCache
        cacheLock.unlock()
        if let hit, hit.key == key, Date().timeIntervalSince(hit.at) < cacheTTL {
            return hit.resolution
        }
        let resolution = SurfaceResolver.resolve(bundleID: bundleID, appName: appName, pid: pid)
        // Terminal sessions change with a tab switch and are cheap to
        // resolve (no AppleScript): never serve one from the cache.
        guard resolution.context.subSurface != .terminal else { return resolution }
        cacheLock.lock()
        resolutionCache = (key, resolution, Date())
        cacheLock.unlock()
        return resolution
    }

    /// Front tab URL of a browser. `dialect` is the catalog's `url_script`.
    static func browserURL(bundleID: String, dialect: String?) -> String? {
        switch dialect {
        case "chromium":
            return runAppleScript("""
                tell application id "\(bundleID)"
                    if not (exists front window) then return ""
                    return URL of active tab of front window
                end tell
                """, cancellation: nil)
        case "safari":
            return runAppleScript("""
                tell application id "\(bundleID)"
                    if not (exists front document) then return ""
                    return URL of front document
                end tell
                """, cancellation: nil)
        default:
            return nil
        }
    }

    /// A helper process's stdout, or nil after `timeout`.
    static func boundedOutput(executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        runProcess(executable: executable, arguments: arguments, timeout: timeout, cancellation: nil)
    }

    /// `osascript` runs alongside the paste (EdgeRuntime's `pasteAndReport`), but the insert result,
    /// with its destination for history, waits for it, so a hung/slow script delays that report. A
    /// responsive Terminal/iTerm2/browser answers a one-line `tell application
    /// ... get tty/URL` script in well under 200ms; 1s still gives a slow-but-alive app generous headroom
    /// while keeping the worst-case stall short when it hangs (observed in the field: `destination-probe
    /// TIMEOUT executable=/usr/bin/osascript after=2.0s`).
    private static let appleScriptTimeout: TimeInterval = 1

    private static func runAppleScript(
        _ source: String, cancellation: DestinationProbeCancellation?
    ) -> String? {
        guard let output = runProcess(
            executable: "/usr/bin/osascript",
            arguments: ["-e", source],
            timeout: appleScriptTimeout,
            cancellation: cancellation
        ) else { return nil }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static let processTimeout: TimeInterval = 5

    private static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = processTimeout,
        cancellation: DestinationProbeCancellation?
    ) -> String? {
        guard cancellation?.isCancelled != true else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        // An undrained Pipe deadlocks the child as soon as it fills the ~64KB
        // buffer. We never read stderr, so it must not be a Pipe at all.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("[Destination] failed to launch %@: %@", executable, String(describing: error))
            return nil
        }

        guard cancellation?.attach(process) != false else {
            terminateAndEscalate(process)
            process.waitUntilExit()
            return nil
        }

        // Drain before waiting. `ps -axo ... args=` over every process on the
        // machine exceeds the pipe buffer, so waiting for exit first blocks the
        // child on write and this thread on wait — a permanent deadlock that
        // wedged the whole dictation pipeline. readDataToEndOfFile returns when
        // the child closes stdout, after which waitUntilExit returns at once.
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                NSLog("[Destination] %@ exceeded %.0fs; terminating", executable, timeout)
                HotkeyService.recordDiagnostics(
                    "destination-probe TIMEOUT executable=\(executable) after=\(timeout)s"
                )
                terminateAndEscalate(process)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout, execute: watchdog
        )

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        cancellation?.detach(process)

        guard cancellation?.isCancelled != true, process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Test hook for the timeout boundary. Production callers use the fixed
    /// osascript/ps helpers above; tests substitute a TERM-resistant process.
    #if DEBUG
    static func boundedProcessOutputForTesting(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        runProcess(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            cancellation: nil
        )
    }
    #endif
}

private func terminateAndEscalate(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let processID = process.processIdentifier
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
        guard process.isRunning else { return }
        HotkeyService.recordDiagnostics(
            "destination-probe forced kill pid=\(processID) after terminate did not exit"
        )
        _ = Darwin.kill(processID, SIGKILL)
    }
}

private final class DestinationProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private weak var process: Process?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func detach(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if self.process === process { self.process = nil }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        lock.unlock()
        if let runningProcess, runningProcess.isRunning {
            terminateAndEscalate(runningProcess)
        }
    }
}
