import AppKit
import ApplicationServices
import Darwin
import Foundation

/// What the frontmost surface is, in capture terms.
struct SurfaceResolution: Equatable, Sendable {
    var context: CaptureContext
    /// A terminal waiting for a password (canonical mode, echo off).
    var isPasswordPrompt = false
    /// A terminal with only a shell in the foreground: keys are commands.
    var isShell = false
    /// The foreground program of a terminal (`claude`, `ssh`, `vim`).
    var program: String?
    var resolvedAt = Date()

    static func unknown(bundleID: String?, appName: String?) -> SurfaceResolution {
        SurfaceResolution(context: CaptureContext(appBundleID: bundleID, appName: appName))
    }
}

/// Resolves the frontmost app into a `CaptureContext`: which tool, which
/// part of the app, which machine. Blocking (process table, Accessibility,
/// a browser's AppleScript, tmux) — never call it on the main thread or on
/// the keystroke path; `DestinationSnapshot.resolved` and
/// `TypedPromptCapture` run it on a background queue.
enum SurfaceResolver {
    static func resolve(
        bundleID: String?,
        appName: String?,
        pid: pid_t?,
        catalog: ToolCatalog = .shared
    ) -> SurfaceResolution {
        guard let bundleID, !bundleID.isEmpty else {
            return .unknown(bundleID: nil, appName: appName)
        }
        var resolution = SurfaceResolution.unknown(bundleID: bundleID, appName: appName)
        let host = catalog.hostApp(bundleID: bundleID)
        let ownTool = catalog.tool(forBundleID: bundleID)

        switch host?.kind {
        case .browser:
            resolution.context.subSurface = .web
            if let url = DestinationSnapshot.browserURL(bundleID: bundleID, dialect: host?.urlScript) {
                resolution.context.url = url
                resolution.context.webHost = SurfacePolicy.extractHost(from: url)
                resolution.context.toolID = catalog.tool(forHost: resolution.context.webHost)?.id
            }
        case .terminal:
            if let pid {
                applyTerminal(appPID: pid, to: &resolution, catalog: catalog)
            }
        case .editor:
            if let pid { enableElectronAccessibility(pid: pid) }
            let traits = focusedElementTraits()
            let sub = CommandLineClassifier.editorSubSurface(classes: traits.classes, descriptions: traits.descriptions)
            resolution.context.subSurface = sub
            switch sub {
            case .terminal:
                if let pid { applyTerminal(appPID: pid, to: &resolution, catalog: catalog) }
                resolution.context.subSurface = .terminal
            case .chatPanel:
                if ownTool?.category == .editor { resolution.context.toolID = ownTool?.id }
            default:
                break
            }
        case nil:
            if let ownTool {
                resolution.context.toolID = ownTool.id
                resolution.context.subSurface = .app
                if ownTool.readsComposer, let pid { enableElectronAccessibility(pid: pid) }
            } else if let pid, hasTerminalSessions(appPID: pid) {
                // An app the catalog doesn't know that hosts terminal
                // sessions — a new terminal emulator. Treat it as one.
                applyTerminal(appPID: pid, to: &resolution, catalog: catalog)
            }
        }
        return resolution
    }

    // MARK: - Terminals

    /// How recently a terminal must have read input to count as "the one
    /// being typed into" when the terminal app's own sessions can't be found
    /// in its process tree (iTerm's session servers are reparented).
    static let freshInputWindow: TimeInterval = 20

    static func applyTerminal(appPID: pid_t, to resolution: inout SurfaceResolution, catalog: ToolCatalog) {
        resolution.context.subSurface = .terminal
        let table = ProcessTable.snapshot()
        guard let tty = activeTTY(appPID: appPID, table: table) else { return }
        resolution.context.tty = ProcessTable.ttyName(tty)
        resolveSession(tty: tty, table: table, catalog: catalog, depth: 0, into: &resolution)
    }

    private static func resolveSession(
        tty: dev_t,
        table: ProcessTable,
        catalog: ToolCatalog,
        depth: Int,
        into resolution: inout SurfaceResolution
    ) {
        let job = table.foreground(onTTY: tty).map { entry -> CommandLineClassifier.Process in
            if let args = ProcessTable.arguments(of: entry.pid) {
                return CommandLineClassifier.Process(executable: args.executable, argv: args.argv)
            }
            return CommandLineClassifier.Process(executable: entry.command, argv: [entry.command])
        }
        let result = CommandLineClassifier.classify(job, catalog: catalog)
        if let ttyName = ProcessTable.ttyName(tty) {
            resolution.isPasswordPrompt = ProcessTable.isPasswordPrompt(ttyName: ttyName)
        }

        if case .tmux(let executable, let socketArgs) = result.multiplexer, depth < 2,
           let clientTTY = ProcessTable.ttyName(tty),
           let pane = tmuxPaneTTY(clientTTY: clientTTY, executable: executable, socketArgs: socketArgs) {
            let refreshed = ProcessTable.snapshot()
            resolveSession(tty: pane, table: refreshed, catalog: catalog, depth: depth + 1, into: &resolution)
            if resolution.program == nil { resolution.program = "tmux" }
            return
        }

        resolution.context.toolID = result.toolID
        resolution.context.remoteHost = result.remoteHost
        resolution.program = result.program
        resolution.isShell = result.isShell
        if result.toolID != nil, result.remoteHost == nil,
           let leaf = table.foreground(onTTY: tty).last {
            resolution.context.workingDirectory = workingDirectory(of: leaf.pid)
        }
    }

    /// The terminal session the user is typing into: among the terminal
    /// app's own sessions, the one that most recently read input.
    static func activeTTY(appPID: pid_t, table: ProcessTable) -> dev_t? {
        var candidates = Set(table.descendants(of: appPID).compactMap(\.tty))
        var requireFresh = false
        if candidates.isEmpty {
            // Session servers outside the app's tree (iTerm): consider every
            // local terminal of this user, but only trust one that read
            // input moments ago, and never an incoming SSH login's.
            requireFresh = true
            let uid = getuid()
            candidates = Set(table.entries.filter { $0.uid == uid }.compactMap(\.tty))
            candidates = candidates.filter { tty in
                !table.processes(onTTY: tty).contains { entry in
                    table.ancestors(of: entry.pid).contains { $0.command.hasPrefix("sshd") }
                }
            }
        }
        let now = Date()
        let ranked = candidates.compactMap { tty -> (dev_t, Date)? in
            guard let name = ProcessTable.ttyName(tty),
                  let time = ProcessTable.lastInputTime(ttyName: name) else { return nil }
            return (tty, time)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first else { return nil }
        if requireFresh, now.timeIntervalSince(best.1) > freshInputWindow { return nil }
        return best.0
    }

    static func hasTerminalSessions(appPID: pid_t) -> Bool {
        ProcessTable.snapshot().descendants(of: appPID).contains { $0.tty != nil }
    }

    /// Asks the tmux server which pane a client terminal is showing.
    static func tmuxPaneTTY(clientTTY: String, executable: String, socketArgs: [String]) -> dev_t? {
        let tmux = executable.hasPrefix("/") ? executable : "/usr/bin/env"
        let args = (tmux == "/usr/bin/env" ? ["tmux"] : []) + socketArgs
            + ["list-clients", "-F", "#{client_tty} #{pane_tty}"]
        guard let output = DestinationSnapshot.boundedOutput(executable: tmux, arguments: args, timeout: 1) else {
            return nil
        }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            let client = parts[0].replacingOccurrences(of: "/dev/", with: "")
            guard client == clientTTY else { continue }
            var info = stat()
            if stat(String(parts[1]), &info) == 0 { return info.st_rdev }
        }
        return nil
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    // MARK: - Accessibility

    private static let accessibilityLock = NSLock()
    private static var electronEnabledPIDs = Set<pid_t>()

    /// Electron apps (VS Code and forks, ChatGPT, Claude…) only expose their
    /// web content to Accessibility once a client asks for it.
    static func enableElectronAccessibility(pid: pid_t) {
        accessibilityLock.lock()
        let inserted = electronEnabledPIDs.insert(pid).inserted
        accessibilityLock.unlock()
        guard inserted else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    struct FocusTraits {
        var classes: [String] = []
        var descriptions: [String] = []
    }

    static func focusedElementTraits() -> FocusTraits {
        var traits = FocusTraits()
        guard let focused = focusedElement() else { return traits }
        var element: AXUIElement? = focused
        var level = 0
        while let current = element, level < 40 {
            AXUIElementSetMessagingTimeout(current, 0.1)
            if let classes = copyAttribute(current, "AXDOMClassList") as? [String] {
                traits.classes.append(contentsOf: classes)
            }
            if level < 6 {
                for key in [kAXDescriptionAttribute, kAXRoleDescriptionAttribute, kAXPlaceholderValueAttribute] {
                    if let text = copyAttribute(current, key as String) as? String, !text.isEmpty {
                        traits.descriptions.append(text)
                    }
                }
            }
            element = copyElement(current, kAXParentAttribute as String)
            level += 1
        }
        return traits
    }

    static func focusedElement(timeout: Float = 0.1) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        return copyElement(system, kAXFocusedUIElementAttribute as String)
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Called synchronously from the event tap on Return / click in a chat
    /// app — it has to run before the app clears the box — so every
    /// Accessibility call is capped at `timeout` (worst case two calls).
    /// The focused text box's content, for exact capture of a chat composer
    /// on submit. Nil for secure fields, non-text elements, and anything
    /// implausibly large (a whole document rather than a prompt box).
    static func focusedComposerText(timeout: Float = 0.03) -> String? {
        guard let element = focusedElement(timeout: timeout) else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)
        let subrole = copyAttribute(element, kAXSubroleAttribute as String) as? String
        guard subrole != (kAXSecureTextFieldSubrole as String) else { return nil }
        let role = copyAttribute(element, kAXRoleAttribute as String) as? String
        let textRoles: Set<String> = [kAXTextAreaRole as String, kAXTextFieldRole as String, kAXComboBoxRole as String, "AXWebArea", "AXGroup"]
        guard let role, textRoles.contains(role) else { return nil }
        guard let value = copyAttribute(element, kAXValueAttribute as String) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64_000 else { return nil }
        return trimmed
    }

    /// Whether the focused field is a password box.
    static func focusedFieldIsSecure(timeout: Float = 0.03) -> Bool {
        guard let element = focusedElement(timeout: timeout) else { return false }
        AXUIElementSetMessagingTimeout(element, timeout)
        return copyAttribute(element, kAXSubroleAttribute as String) as? String == kAXSecureTextFieldSubrole as String
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
