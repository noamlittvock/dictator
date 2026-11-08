import AppKit
import ApplicationServices
import Foundation

// The acting steps of a voice launch: asking first, key presses, Apple
// Shortcuts, web requests and files. The pieces that touch the outside
// world are injected (`VoiceLaunchServices`) so tests never do.

struct VoiceLaunchProcessResult: Equatable {
    var status: Int32
    var timedOut: Bool
    /// Captured output is never logged for background commands.
    var stdout: String = ""
    var stderr: String = ""
}

/// Runs a program with an argument array (no shell). Nil when it can't start.
typealias VoiceLaunchProcessRunner = (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async -> VoiceLaunchProcessResult?

/// Everything a chain touches outside itself.
struct VoiceLaunchServices {
    /// Counts down `seconds`, calling `tick` with the whole seconds left.
    /// True to continue, false when the user pressed Esc.
    var confirm: @MainActor (_ seconds: Double, _ tick: @escaping (Int) -> Void) async -> Bool
    var setClipboard: (String) -> Void
    /// Posts a key press to the frontmost app; false if it couldn't.
    var pressKey: (_ key: String) -> Bool
    var frontmostBundleId: () -> String?
    var runProcess: VoiceLaunchProcessRunner
    var session: URLSession
    var now: () -> Date
    /// This Mac's name, for the input given to a Shortcut.
    var macName: () -> String = { "" }
    /// A line for `hotkey.log`.
    var log: (String) -> Void = { _ in }
    // Defaults suit tests; `live` passes the real ones.
    var isAccessibilityTrusted: () -> Bool = { true }
    var sleep: (Duration) async -> Void = { _ in }
    var pasteText: (String, String?) async -> PasteService.Outcome = { _, _ in .pasted }
    var appInstalled: (String) -> Bool = { _ in true }
    var installedApps: () async -> [VoiceInstalledApp] = { [] }
    var openNamedApp: @MainActor (URL) async -> Bool = { _ in false }
    var workspaceRoutines: @MainActor () -> [WorkspaceRoutine] = { [] }
    var runWorkspace: @MainActor (String) async throws -> Void = { _ in
        throw WorkspaceLaunchError.unavailable("Workspaces isn’t ready on this Mac.")
    }

    @MainActor static var live: VoiceLaunchServices {
        VoiceLaunchServices(
            confirm: { seconds, tick in await VoiceLaunchActing.liveConfirm(seconds: seconds, tick: tick) },
            setClipboard: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            pressKey: { VoiceLaunchActing.postKey($0) },
            frontmostBundleId: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            runProcess: VoiceLaunchActing.liveRunProcess,
            session: VoiceLaunchActing.makeSession(),
            now: { Date() },
            macName: { Host.current().localizedName ?? "" },
            log: { HotkeyService.recordDiagnostics($0) },
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            sleep: { try? await Task.sleep(for: $0) },
            pasteText: { text, expectedBundleID in
                await Task.detached { PasteService.paste(text, expectedBundleID: expectedBundleID) }.value
            },
            appInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
            installedApps: { await VoiceInstalledApps.load() },
            openNamedApp: { url in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                do { try await NSWorkspace.shared.openApplication(at: url, configuration: configuration); return true }
                catch { return false }
            },
            workspaceRoutines: { AppSettings.shared.workspaceLaunch.routines },
            runWorkspace: { try await WorkspaceLaunchController.shared.runAwaiting(routineID: $0) })
    }
}

/// Esc presses seen by `HotkeyService`'s tap, for the countdown. That tap
/// already exists, so this needs no new permission.
///
/// Each countdown registers its own handler under its own token and removes
/// only that one, so two launches that overlap never share (or clear) each
/// other's cancel. Esc cancels every countdown showing: it never sends.
enum VoiceLaunchEscapeWatch {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [UUID: () -> Void] = [:]

    @discardableResult
    static func register(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        lock.lock(); handlers[token] = handler; lock.unlock()
        return token
    }

    static func unregister(_ token: UUID) {
        lock.lock(); handlers[token] = nil; lock.unlock()
    }

    /// True while a countdown owns Esc.
    static var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !handlers.isEmpty
    }

    /// Cancels every countdown showing. True when one did, so the caller
    /// can keep that Esc from also reaching the app in front.
    @discardableResult
    static func fire() -> Bool {
        lock.lock(); let current = Array(handlers.values); lock.unlock()
        current.forEach { $0() }
        return !current.isEmpty
    }
}

/// Counts down a "Sending in 3 s" pause. The clock and the cancel check are
/// passed in so it can be tested without waiting.
enum VoiceLaunchCountdown {
    static let tickMilliseconds = 100
    static let maximumSeconds = 30.0

    static func run(seconds: Double, sleep: (Duration) async -> Void, isCancelled: () -> Bool, tick: (Int) -> Void) async -> Bool {
        // A step from another Mac skips this Mac's validation; a confirmation
        // must never crash here, or pass without its pause.
        let bounded = seconds.isFinite ? min(max(seconds, 0), maximumSeconds) : VoiceStep.defaultConfirmSeconds
        let total = Int((bounded * 1000).rounded()) / tickMilliseconds
        var left = total
        var lastShown = -1
        while left > 0 {
            if isCancelled() { return false }
            let shown = Int((Double(left * tickMilliseconds) / 1000).rounded(.up))
            if shown != lastShown { tick(shown); lastShown = shown }
            await sleep(.milliseconds(tickMilliseconds))
            left -= 1
        }
        return !isCancelled()
    }

    /// "Sending in 3 s — Esc to cancel"
    static func label(_ secondsLeft: Int) -> String { BrandVoice.countdown(secondsLeft) }
}

enum VoiceLaunchActing {
    // MARK: pressKey

    struct KeyPress: Equatable {
        var keyCode: CGKeyCode
        var command: Bool
    }

    static func keyPress(for key: String) -> KeyPress? {
        switch key {
        case "return": KeyPress(keyCode: 36, command: false)
        case "cmdReturn": KeyPress(keyCode: 36, command: true)
        case "tab": KeyPress(keyCode: 48, command: false)
        case "escape": KeyPress(keyCode: 53, command: false)
        default: nil
        }
    }

    private static let keySource = CGEventSource(stateID: .privateState)

    /// Needs Accessibility, which dictation already asks for.
    static func postKey(_ key: String) -> Bool {
        guard AXIsProcessTrusted(), let press = keyPress(for: key),
              let down = CGEvent(keyboardEventSource: keySource, virtualKey: press.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: keySource, virtualKey: press.keyCode, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = press.command ? .maskCommand : []
            event.setIntegerValueField(.eventSourceUserData, value: PasteService.syntheticEventTag)
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    // MARK: confirm

    @MainActor static func liveConfirm(seconds: Double, tick: @escaping (Int) -> Void) async -> Bool {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func cancel() { lock.lock(); value = true; lock.unlock() }
            var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let flag = Flag()
        let token = VoiceLaunchEscapeWatch.register { flag.cancel() }
        // The tap covers every app; this covers Dictator's own windows. The
        // Esc that cancels is used up here, so it doesn't also close a sheet.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            flag.cancel()
            return nil
        }
        defer {
            VoiceLaunchEscapeWatch.unregister(token)
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        return await VoiceLaunchCountdown.run(
            seconds: seconds,
            sleep: { try? await Task.sleep(for: $0) },
            isCancelled: { flag.isCancelled },
            tick: tick)
    }

    // MARK: runAppleShortcut

    static let shortcutsExecutable = "/usr/bin/shortcuts"
    static let shortcutTimeout: TimeInterval = VoiceStep.defaultShortcutTimeout
    /// The most of the Shortcut's error text written to `hotkey.log`.
    static let logLimit = 500

    /// The argument array for `shortcuts run`; the name or identifier is one
    /// argument, never parsed by a shell. The answer comes back as plain text.
    static func shortcutRunArguments(target: String, inputPath: String, outputPath: String) -> [String] {
        ["run", target, "--input-path", inputPath, "--output-path", outputPath, "--output-type", "public.plain-text"]
    }

    static func listArguments() -> [String] { ["list", "--show-identifiers"] }
    static func viewArguments(name: String) -> [String] { ["view", name] }

    /// The identifier when there is one, else the name.
    static func runTarget(_ step: VoiceStep) -> String {
        let id = (step.shortcutId ?? "").trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? (step.shortcutName ?? "") : id
    }

    /// A private (0700) folder for one run: an input file and an answer file.
    struct ShortcutFiles {
        var directory: URL
        var input: URL
        var output: URL
    }

    static func makeShortcutFiles(input text: String, fileName: String, fileManager: FileManager = .default) throws -> ShortcutFiles {
        let directory = fileManager.temporaryDirectory.appendingPathComponent("dictator-shortcut-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(fileName)
        guard fileManager.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            try? fileManager.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        return ShortcutFiles(directory: directory, input: file, output: directory.appendingPathComponent("output.txt"))
    }

    /// Runs the Shortcut and returns its answer (empty when it gave none).
    /// A step that used JSON input is given `input.json`, else `input.txt`.
    @discardableResult
    static func runAppleShortcut(_ step: VoiceStep, services: VoiceLaunchServices) async throws -> VoiceShortcutAnswer {
        let name = step.shortcutName ?? ""
        let timeout = step.timeoutSeconds ?? VoiceStep.defaultShortcutTimeout
        // A name from the sentence never starts an option of `shortcuts`.
        guard !runTarget(step).hasPrefix("-") else {
            throw VoiceLaunchExecutor.Failure(alert: problem("Couldn’t run “\(name)”", "A Shortcut name can’t start with a dash. Nothing was run."))
        }
        let files: ShortcutFiles
        do {
            files = try makeShortcutFiles(input: step.text ?? "", fileName: step.sendsEverything ? "input.json" : "input.txt")
        } catch {
            throw VoiceLaunchExecutor.Failure(alert: problem("Couldn’t run “\(name)”", "Dictator couldn’t prepare what to give it. Nothing was run."))
        }
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let result = await services.runProcess(shortcutsExecutable,
                                               shortcutRunArguments(target: runTarget(step), inputPath: files.input.path, outputPath: files.output.path),
                                               timeout)
        guard let result else {
            throw VoiceLaunchExecutor.Failure(alert: problem("Couldn’t run “\(name)”", "The Shortcuts app couldn’t be started on this Mac."))
        }
        if result.timedOut || result.status != 0 {
            let snippet = logSnippet(result.stderr)
            services.log("voicelaunch: shortcut “\(name)” \(result.timedOut ? "timed out after \(Int(timeout))s" : "exited \(result.status)")\(snippet.isEmpty ? "" : ": " + snippet)")
            throw VoiceLaunchExecutor.Failure(alert: shortcutFailure(name: name, result: result, timeout: timeout))
        }
        let (answer, truncated) = VoiceShortcutAnswer.read(from: files.output)
        if truncated { services.log("voicelaunch: shortcut “\(name)” answer cut to \(VoiceShortcutAnswer.maxBytes) bytes") }
        return answer
    }

    /// Error text for `hotkey.log`: one line, cut short.
    static func logSnippet(_ text: String, limit: Int = logLimit) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// What went wrong, in plain words. The raw error text never shows.
    static func shortcutFailure(name: String, result: VoiceLaunchProcessResult, timeout: TimeInterval) -> DictationAlert {
        if result.timedOut {
            return problem("“\(name)” didn’t finish in time", "It was stopped after \(Int(timeout)) seconds. You can allow more time in its settings.")
        }
        let text = result.stderr.lowercased()
        if text.contains("find shortcut") || text.contains("couldn’t find") && text.contains("shortcut") || text.contains("no shortcut")
            || text.contains("not found") {
            return problem("This Mac doesn’t have the Shortcut “\(name)”", "Shortcuts usually sync through iCloud, but not always. Open the Shortcuts app on this Mac to check.")
        }
        if text.contains("not allowed") || text.contains("not authorized") || text.contains("permission") || text.contains("denied")
            || text.contains("privacy") {
            return problem("Shortcuts isn’t allowed to run “\(name)”", "Check System Settings › Privacy & Security, and allow Dictator to control Shortcuts.")
        }
        return problem("“\(name)” stopped with an error", "Open it in the Shortcuts app and run it once to see what went wrong.")
    }

    /// Asks the Shortcuts app for the Shortcuts on this Mac. Nil when it
    /// can't be asked or answers with an error.
    static func listShortcuts(services: VoiceLaunchServices) async -> [AppleShortcutInfo]? {
        guard let result = await services.runProcess(shortcutsExecutable, listArguments(), 15), !result.timedOut, result.status == 0 else {
            return nil
        }
        return VoiceShortcutList.parse(result.stdout)
    }

    /// The Shortcuts to put in "Your Shortcuts", or nil to leave the list as
    /// it is: on a Mac connected to a main Mac (the main Mac fills it), when
    /// nothing uses it and it wasn't asked for (`force`), or when the
    /// Shortcuts app can't be asked (the list from before stays).
    static func fetchYourShortcuts(role: CoreRole, config: VoiceLaunchConfig, force: Bool,
                                   services: VoiceLaunchServices) async -> [AppleShortcutInfo]? {
        guard role != .edge else { return nil }
        let used = config.commands.contains { voiceCommand in
            guard case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern) else { return false }
            return parsed.slots.compactMap(\.list)
                .contains { VoiceLaunchText.normalizedWords($0) == VoiceLaunchText.normalizedWords(VoiceCards.shortcutsList) }
        }
        guard force || used else { return nil }
        return await listShortcuts(services: services)
    }

    /// Fills "Your Shortcuts" on the main Mac. Returns false when there is
    /// nothing new to show (or this Mac isn't the main Mac).
    @MainActor @discardableResult
    static func refreshYourShortcuts(force: Bool, settings: AppSettings = .shared, services: VoiceLaunchServices? = nil) async -> Bool {
        guard let list = await fetchYourShortcuts(role: settings.coreRole, config: settings.voiceLaunch, force: force, services: services ?? .live) else { return false }
        var changed = false
        settings.updateVoiceLaunch { config in
            let before = config
            VoiceYourShortcuts.merge(list, into: &config)
            changed = config != before
        }
        return changed
    }

    /// Shows one Shortcut in the Shortcuts app.
    static func viewShortcut(name: String, services: VoiceLaunchServices) async -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"),
              let result = await services.runProcess(shortcutsExecutable, viewArguments(name: name), 10) else { return false }
        return !result.timedOut && result.status == 0
    }

    // MARK: background command

    /// Recheck on the executing Mac, including plans received from a peer.
    static func runBackgroundCommand(_ step: VoiceStep, services: VoiceLaunchServices) async throws {
        let command = step.command ?? ""
        let range = NSRange(command.startIndex..., in: command)
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, command.count <= 200,
              VoiceLaunchConfig.terminalCommandAllowed.firstMatch(in: command, range: range) != nil else {
            throw VoiceLaunchExecutor.Failure(alert: problem("The command isn’t valid", "Enter a command using letters, numbers and simple punctuation in Commands."))
        }
        let timeout = step.timeoutSeconds ?? VoiceStep.defaultBackgroundTimeout
        guard VoiceStep.backgroundTimeoutAllowed(timeout) else {
            throw VoiceLaunchExecutor.Failure(alert: problem("The command time limit isn’t valid", "Choose between 1 and 600 seconds in Commands."))
        }
        let folder = step.folder ?? ""
        let path = (folder as NSString).expandingTildeInPath
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            throw VoiceLaunchExecutor.Failure(alert: VoiceLaunchExecutor.folderNotFound(folder, macName: services.macName()))
        }
        try Task.checkCancellation()
        let started = services.now()
        let result = await services.runProcess("/bin/zsh", ShellQuote.backgroundArguments(folder: path, command: command, argument: step.argument ?? ""), timeout)
        try Task.checkCancellation()
        guard let result else {
            throw VoiceLaunchExecutor.Failure(alert: problem("Couldn’t start the command", "Check its command and folder in Commands."))
        }
        services.log("voicelaunch: exited \(result.status) \(Int(max(0, services.now().timeIntervalSince(started)) * 1000))ms")
        if result.timedOut {
            throw VoiceLaunchExecutor.Failure(alert: problem("The command didn’t finish in time", "It was stopped after \(Int(timeout)) seconds. You can allow more time in Commands."))
        }
        if result.status != 0 {
            let snippet = logSnippet(result.stderr, limit: 300)
            throw VoiceLaunchExecutor.Failure(alert: problem("The command failed (exit status \(result.status))",
                "Check its command in Commands." + (snippet.isEmpty ? "" : " " + snippet)))
        }
    }

    // MARK: webhook

    static let webhookTimeout: TimeInterval = 10

    static func webhookRequest(_ step: VoiceStep) -> URLRequest? {
        guard let url = URL(string: step.link ?? ""), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: webhookTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((step.text ?? "{}").utf8)
        return request
    }

    static func sendWebhook(_ step: VoiceStep, session: URLSession) async throws {
        let host = URL(string: step.link ?? "")?.host ?? "that address"
        guard let request = webhookRequest(step) else {
            throw VoiceLaunchExecutor.Failure(alert: problem("The web address isn’t valid", "Check it in Commands. Nothing was sent."))
        }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode
                throw VoiceLaunchExecutor.Failure(alert: problem("\(host) didn’t accept it",
                    code.map { "It answered with an error (\($0))." } ?? "It sent back something unexpected."))
            }
        } catch let failure as VoiceLaunchExecutor.Failure {
            throw failure
        } catch {
            throw VoiceLaunchExecutor.Failure(alert: problem("Couldn’t reach \(host)", "Check your connection and the address. Dictator gives up after 10 seconds."))
        }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = webhookTimeout
        configuration.timeoutIntervalForResource = webhookTimeout
        return URLSession(configuration: configuration)
    }

    // MARK: appendToFile

    /// One line: `2026-09-29 14:05:09 | text`. Line breaks in the text become spaces.
    static func logLine(_ text: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let flat = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return "\(formatter.string(from: date)) | \(flat)\n"
    }

    static func appendLine(_ step: VoiceStep, now: Date, timeZone: TimeZone = .current, fileManager: FileManager = .default) throws {
        let path = ((step.path ?? "") as NSString).expandingTildeInPath
        let file = URL(fileURLWithPath: path)
        let name = file.lastPathComponent
        guard VoiceLaunchConfig.isAppendablePath(path) else {
            throw VoiceLaunchExecutor.Failure(alert: problem("Dictator won’t add to “\(name)”", "That’s a file your Mac or its apps run or depend on. Nothing was added."))
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: file.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VoiceLaunchExecutor.Failure(alert: problem("That folder isn’t on this Mac", "The folder for “\(name)” wasn’t found here. Nothing was added."))
        }
        var line = Data(logLine(step.text ?? "", at: now, timeZone: timeZone).utf8)
        do {
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else { throw CocoaError(.fileWriteInvalidFileName) }
                let handle = try FileHandle(forUpdating: file)
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                if end > 0 {
                    try handle.seek(toOffset: end - 1)
                    if try handle.read(upToCount: 1) != Data("\n".utf8) { line = Data("\n".utf8) + line }
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                guard fileManager.createFile(atPath: path, contents: line, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
        } catch {
            throw VoiceLaunchExecutor.Failure(alert: problem("Couldn’t add to “\(name)”", "Dictator couldn’t write to that file."))
        }
    }

    // MARK: shared

    static func problem(_ title: String, _ detail: String) -> DictationAlert {
        DictationAlert(title: title, detail: detail + " Your words are on the clipboard.", action: nil)
    }

    // MARK: live process

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var timedOut = false
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
        var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    }

    /// Collects what a program prints, up to a limit.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        let limit: Int
        init(limit: Int) { self.limit = limit }
        func add(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// Owns a separate process group from spawn through completion. Killing the
    /// group also closes pipes held by children, so cancellation cannot hang.
    private final class BackgroundProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var stopped = false
        private var finished = false
        private var timedOut = false

        func launch(_ spawn: (inout pid_t) -> Int32) -> Int32 {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return ECANCELED }
            return spawn(&pid)
        }

        func stop(timedOut: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            stopped = true
            self.timedOut = timedOut
            if pid > 0 { kill(-pid, SIGKILL) }
        }

        func waitForExit(status: inout Int32) {
            lock.lock(); let child = pid; lock.unlock()
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        }

        func complete() -> Bool {
            lock.lock(); defer { lock.unlock() }
            // Do not leave child processes behind when their command exits.
            if pid > 0 { kill(-pid, SIGKILL) }
            finished = true
            pid = 0
            return timedOut
        }
    }

    /// No app credentials or provider tokens cross into a background command.
    static func backgroundEnvironment(_ source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let keys = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
        var environment = source.filter { keys.contains($0.key) }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }

    private static func runBackgroundProcess(_ arguments: [String], _ timeout: TimeInterval) async -> VoiceLaunchProcessResult? {
        let control = BackgroundProcess()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let pipe = Pipe()
                    let capture = Capture(limit: 16 * 1024)
                    let reader = DispatchGroup()
                    reader.enter()
                    DispatchQueue.global().async {
                        while let data = try? pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty { capture.add(data) }
                        try? pipe.fileHandleForReading.close()
                        reader.leave()
                    }
                    var actions: posix_spawn_file_actions_t?
                    var attributes: posix_spawnattr_t?
                    func unavailable() {
                        _ = control.complete()
                        try? pipe.fileHandleForWriting.close()
                        reader.wait()
                        continuation.resume(returning: nil)
                    }
                    guard posix_spawn_file_actions_init(&actions) == 0 else { unavailable(); return }
                    defer { posix_spawn_file_actions_destroy(&actions) }
                    guard posix_spawnattr_init(&attributes) == 0 else { unavailable(); return }
                    defer { posix_spawnattr_destroy(&attributes) }
                    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
                          posix_spawnattr_setpgroup(&attributes, 0) == 0,
                          posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
                          posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
                          posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) == 0 else {
                        unavailable(); return
                    }
                    let argv = (["/bin/zsh"] + arguments).map { strdup($0) } + [nil]
                    let env = backgroundEnvironment().map { strdup("\($0.key)=\($0.value)") } + [nil]
                    defer { argv.forEach { free($0) }; env.forEach { free($0) } }
                    let launched = control.launch { pid in
                        argv.withUnsafeBufferPointer { args in
                            env.withUnsafeBufferPointer { environment in
                                posix_spawn(&pid, "/bin/zsh", &actions, &attributes,
                                            UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: environment.baseAddress!))
                            }
                        }
                    }
                    try? pipe.fileHandleForWriting.close()
                    guard launched == 0 else {
                        _ = control.complete()
                        reader.wait()
                        continuation.resume(returning: nil)
                        return
                    }
                    let deadline = DispatchWorkItem { control.stop(timedOut: true) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    var status: Int32 = 0
                    control.waitForExit(status: &status)
                    let timedOut = control.complete()
                    deadline.cancel()
                    reader.wait()
                    let code = status & 0x7f
                    let exitStatus = code == 0 ? (status >> 8) & 0xff : 128 + code
                    continuation.resume(returning: VoiceLaunchProcessResult(status: exitStatus, timedOut: timedOut, stderr: capture.text))
                }
            }
        } onCancel: { control.stop() }
    }

    static func liveRunProcess(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async -> VoiceLaunchProcessResult? {
        if executable == "/bin/zsh" { return await runBackgroundProcess(arguments, timeout) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let out = Capture(limit: 256 * 1024)
        let err = Capture(limit: 16 * 1024)
        outPipe.fileHandleForReading.readabilityHandler = { out.add($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { err.add($0.availableData) }
        let once = Once()
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? outPipe.fileHandleForReading.readToEnd() { out.add(rest) }
                if let rest = try? errPipe.fileHandleForReading.readToEnd() { err.add(rest) }
                if once.first() {
                    continuation.resume(returning: VoiceLaunchProcessResult(status: finished.terminationStatus, timedOut: once.didTimeOut,
                                                                           stdout: out.text, stderr: err.text))
                }
            }
            do { try process.run() } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if once.first() { continuation.resume(returning: nil) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { once.markTimedOut(); process.terminate() }
            }
        }
    }
}


struct VoiceInstalledApp: Equatable, Sendable {
    var name: String
    var url: URL
    var bundleID: String? = nil
}

enum VoiceInstalledApps {
    static func scan(roots: [URL] = [URL(fileURLWithPath: "/Applications"),
                                   URL(fileURLWithPath: "/System/Applications"),
                                   URL(fileURLWithPath: "/System/Applications/Utilities"),
                                   FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]) -> [VoiceInstalledApp] {
        let fm = FileManager.default
        func children(_ folder: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        var seen = Set<URL>()
        var apps: [VoiceInstalledApp] = []
        func collect(_ url: URL) {
            guard url.pathExtension.lowercased() == "app",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  seen.insert(url.resolvingSymlinksInPath()).inserted else { return }
            let name = fm.displayName(atPath: url.path)
            apps.append(VoiceInstalledApp(name: name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name,
                                          url: url, bundleID: Bundle(url: url)?.bundleIdentifier))
        }
        for root in roots {
            for child in children(root) {
                if child.pathExtension.lowercased() == "app" { collect(child) }
                else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    children(child).forEach(collect)
                }
            }
        }
        return apps.sorted { ($0.name, $0.url.path) < ($1.name, $1.url.path) }
    }

    static func load(scanApps: @escaping @Sendable () -> [VoiceInstalledApp] = { scan() }) async -> [VoiceInstalledApp] {
        await Task.detached(priority: .utility) { scanApps() }.value
    }
}

/// Warmed during setup, never enumerated in a key-down handler. A recognition
/// can use the previous snapshot while the next one is being read off-thread.
@MainActor
enum VoiceAppHints {
    private(set) static var names: [String] = []
    private static var refreshing = false
    static func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            names = await VoiceInstalledApps.load().map(\.name)
            refreshing = false
        }
    }
}
