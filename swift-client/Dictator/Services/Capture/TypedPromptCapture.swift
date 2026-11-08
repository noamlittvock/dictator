import AppKit
import Carbon
import Foundation

/// Typed-prompt capture from the keyboard, for surfaces no connector covers:
/// chat apps and websites (exact, by reading the text box on submit),
/// editor chat panels, and terminals running a tool without a hook.
///
/// Buffer first, decide at submit. Keys are collected for any surface that
/// could matter; *which* tool / machine it was, and whether that is saved,
/// is decided when the prompt is submitted — against a surface resolved off
/// the main thread — so the first keystrokes typed into a fresh terminal tab
/// are never lost to a slow lookup. Apps that can't be a prompt surface
/// (mail, Slack, documents) are never buffered at all, unless the user
/// turned on "Everything else I type" or added the app themselves.
@MainActor
final class TypedPromptCapture {
    private let settings: AppSettings
    private let recorder: PromptRecorder
    private let notices: NoticedSurfaceStore
    /// Tool ids whose prompts a connector on this Mac already captures.
    private let connectorCovers: (String) -> Bool
    /// Remote hosts whose tools are captured by remote hooks.
    private let remoteCovers: (String) -> Bool

    private struct Draft {
        var text = ""
        var bundleID: String?
        var pid: pid_t?
        var startedAt = Date()
        var lastEdit = Date()
        /// Time actually spent typing: the gaps between keys, leaving out
        /// pauses longer than `typingPauseLimit`.
        var activeSeconds: TimeInterval = 0
        /// Characters that arrived by paste (Dictator's own dictation lands
        /// as a paste): a mostly pasted draft has no typing time.
        var pastedCharacters = 0

        /// Composing time, when the draft was really typed.
        var typingSeconds: Double? {
            guard activeSeconds > 0, pastedCharacters * 5 < max(text.count, 1) else { return nil }
            return activeSeconds
        }
        /// Keys went to a terminal waiting for a password (echo off) while
        /// this draft was typed: it is never saved.
        var sawSecretInput = false
    }

    private var drafts: [String: Draft] = [:]
    private var currentKey: String?
    private var resolution: SurfaceResolution?
    private var resolving = false
    private var pendingSubmit: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var secureInputNoticed = Set<String>()
    private let maxDraft = 16_000
    private let draftExpiry: TimeInterval = 20 * 60
    static let typingPauseLimit: TimeInterval = 30

    init(
        settings: AppSettings = .shared,
        recorder: PromptRecorder,
        notices: NoticedSurfaceStore,
        connectorCovers: @escaping (String) -> Bool,
        remoteCovers: @escaping (String) -> Bool
    ) {
        self.settings = settings
        self.recorder = recorder
        self.notices = notices
        self.connectorCovers = connectorCovers
        self.remoteCovers = remoteCovers
    }

    func start() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontmostChanged() }
        }
        frontmostChanged()
    }

    func stop() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        drafts.removeAll()
    }

    // MARK: - Tap input

    func handle(_ activity: TypingActivity) {
        // Typed history off (the default): not a single key is held.
        guard settings.persistHistory, !settings.isPromptCapturePaused(),
              settings.surfacePolicy.allowsAnyTypedSave else {
            drafts.removeAll()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, let key = surfaceKey(app) else { return }
        guard isWorthBuffering(bundleID: app.bundleIdentifier) else { return }
        // macOS turns this on for password boxes. Whatever is held from
        // around one is not a prompt.
        if IsSecureEventInputEnabled() {
            drafts[key] = nil
            return
        }
        if currentKey != key {
            currentKey = key
            resolution = nil
        }
        refreshResolutionIfStale(app)

        var draft = drafts[key] ?? Draft(bundleID: app.bundleIdentifier, pid: app.processIdentifier)
        if Date().timeIntervalSince(draft.lastEdit) > draftExpiry { draft = Draft(bundleID: app.bundleIdentifier, pid: app.processIdentifier) }
        let gap = Date().timeIntervalSince(draft.lastEdit)
        if drafts[key] != nil, gap <= Self.typingPauseLimit { draft.activeSeconds += gap }
        draft.lastEdit = Date()
        // Checked while the keys arrive — by the time Return is processed,
        // sudo / ssh / gpg have read the line and turned echo back on.
        if let tty = resolution?.context.tty, resolution?.context.subSurface == .terminal,
           ProcessTable.isPasswordPrompt(ttyName: tty) {
            draft.sawSecretInput = true
        }

        switch activity {
        case .text(let string):
            draft.text.append(string)
        case .softNewline:
            draft.text.append("\n")
        case .deleteBackward:
            if !draft.text.isEmpty { draft.text.removeLast() }
        case .paste:
            if let pasted = NSPasteboard.general.string(forType: .string) {
                draft.text.append(pasted)
                draft.pastedCharacters += pasted.count
            }
        case .caretOrSelectionChanged:
            break
        case .newline:
            if ToolCatalog.shared.hostApp(bundleID: app.bundleIdentifier)?.kind == .terminal,
               let tty = SurfaceResolver.activeTTY(appPID: app.processIdentifier, table: .snapshot()),
               let name = ProcessTable.ttyName(tty), ProcessTable.isPasswordPrompt(ttyName: name) {
                draft.sawSecretInput = true
            }
            drafts[key] = draft
            submit(key: key)
            return
        }
        if draft.text.count > maxDraft { draft.text = String(draft.text.suffix(maxDraft)) }
        drafts[key] = draft
    }

    /// A click may be the Send button of a chat composer: if the composer
    /// empties right after, what it held was submitted.
    func handleMouseDown() {
        guard settings.persistHistory, !settings.isPromptCapturePaused(),
              let app = NSWorkspace.shared.frontmostApplication, let key = surfaceKey(app),
              let draft = drafts[key], !draft.text.isEmpty,
              readsComposer(bundleID: app.bundleIdentifier) else { return }
        guard let before = SurfaceResolver.focusedComposerText() else { return }
        pendingSubmit?.cancel()
        pendingSubmit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled else { return }
            let after = SurfaceResolver.focusedComposerText()
            if after == nil || after!.count < before.count / 2 {
                self.commit(key: key, text: before, source: .composer)
            }
        }
    }

    // MARK: - Submit

    private func submit(key: String) {
        guard let draft = drafts[key] else { return }
        if SurfaceResolver.focusedFieldIsSecure() {
            drafts[key] = nil
            return
        }
        let isBrowser = ToolCatalog.shared.hostApp(bundleID: draft.bundleID)?.kind == .browser
        let composerText = isBrowser || readsComposer(bundleID: draft.bundleID) ? SurfaceResolver.focusedComposerText() : nil
        guard let composerText else {
            if Self.keepsKeystrokes(isBrowser: isBrowser, savesEverything: savesEverything(bundleID: draft.bundleID)) {
                commit(key: key, text: draft.text, source: .keystrokes)
            } else {
                drafts[key] = nil
            }
            return
        }
        // Return may have been a line break in a composer that sends with
        // ⌘Return: confirm the box actually emptied before recording.
        pendingSubmit?.cancel()
        pendingSubmit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            let after = SurfaceResolver.focusedComposerText()
            if let after, after.count >= composerText.count - 1, after.hasPrefix(String(composerText.prefix(20))) {
                self.drafts[key]?.text.append("\n")
                return
            }
            self.commit(key: key, text: composerText, source: .composer)
        }
    }

    /// A browser has one draft for every field of every tab, so its keystrokes
    /// can include what was typed into a sign-in form elsewhere. Only the text
    /// box itself is a prompt there, unless the user asked to save everything.
    static func keepsKeystrokes(isBrowser: Bool, savesEverything: Bool) -> Bool {
        !isBrowser || savesEverything
    }

    private func savesEverything(bundleID: String?) -> Bool {
        settings.surfacePolicy.defaultTyped == "save" || hasSaveOverride(CaptureContext(appBundleID: bundleID))
    }

    private func commit(key: String, text: String, source: CaptureSource) {
        guard let draft = drafts.removeValue(forKey: key), !draft.sawSecretInput else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let bundleID = draft.bundleID
        let appName = NSRunningApplication(processIdentifier: draft.pid ?? 0)?.localizedName
        let pid = draft.pid
        let submittedAt = Date()
        let typingSeconds = source == .keystrokes ? draft.typingSeconds : (draft.pastedCharacters == 0 ? draft.typingSeconds : nil)
        // Resolve now (the foreground program is still the one that got the
        // prompt), off the main thread, then decide.
        Task.detached(priority: .userInitiated) { [weak self] in
            let resolved = DestinationSnapshot.resolve(bundleID: bundleID, appName: appName, pid: pid)
            await MainActor.run {
                self?.finish(text: trimmed, source: source, resolution: resolved, at: submittedAt, typingSeconds: typingSeconds)
            }
        }
    }

    private func finish(text: String, source: CaptureSource, resolution: SurfaceResolution, at date: Date, typingSeconds: Double? = nil) {
        var context = resolution.context
        var text = text
        if context.subSurface == .terminal, resolution.isPasswordPrompt { return }
        // A connector may deliver this same prompt exactly; it takes the
        // typing time from here.
        if let typingSeconds { recorder.noteTyping(text: text, seconds: typingSeconds, at: date) }

        if context.subSurface == .terminal {
            if resolution.isShell {
                // `claude "fix the tests"` typed at a shell prompt is a prompt.
                guard let inline = Self.inlinePrompt(fromCommandLine: text, catalog: .shared) else { return }
                context.toolID = inline.toolID
                text = inline.prompt
            }
        }
        if context.subSurface == .codeEditor { return }

        if let remote = context.remoteHost {
            if remoteCovers(remote) { return }
            if !notices.isDismissed(kind: .remote, context: context) {
                notices.note(.remote, context: context, label: "Typing over SSH to \(remote)")
            }
            // Without a known tool, what's typed into a remote shell is
            // commands, not prompts.
            guard context.toolID != nil else { return }
        } else if let toolID = context.toolID, connectorCovers(toolID) {
            return
        }

        guard context.toolID != nil || settings.surfacePolicy.defaultTyped == "save" || hasSaveOverride(context) else {
            return
        }

        recorder.submit(CapturedPrompt(
            text: text,
            source: source,
            context: context,
            timestamp: date,
            sessionID: nil,
            dedupeKey: nil,
            typingSeconds: typingSeconds
        ))
    }

    // MARK: - Surface helpers

    private func surfaceKey(_ app: NSRunningApplication) -> String? {
        guard let bundle = app.bundleIdentifier else { return nil }
        // Terminals: one draft per session (the tty is resolved lazily, so
        // key by app and let the commit-time resolution attribute it).
        return "\(bundle)#\(app.processIdentifier)"
    }

    /// Worth holding keystrokes for: an AI tool's own app, a terminal /
    /// editor / browser (whose sessions and tabs may be AI tools), or any app
    /// the user asked to save everything from.
    private func isWorthBuffering(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if bundleID == Bundle.main.bundleIdentifier { return false }
        let catalog = ToolCatalog.shared
        if catalog.tool(forBundleID: bundleID) != nil || catalog.hostApp(bundleID: bundleID) != nil { return true }
        if settings.surfacePolicy.defaultTyped == "save" { return true }
        return hasSaveOverride(CaptureContext(appBundleID: bundleID))
    }

    private func hasSaveOverride(_ context: CaptureContext) -> Bool {
        settings.surfacePolicy.rules.contains { rule in
            SurfacePolicy.norm(rule.action) == "save"
                && SurfacePolicy.norm(rule.modality) != "voice"
                && SurfacePolicy.matches(rule: rule, context: context, catalog: .shared)
        }
    }

    private func readsComposer(bundleID: String?) -> Bool {
        let catalog = ToolCatalog.shared
        if let tool = catalog.tool(forBundleID: bundleID), tool.readsComposer, tool.category == .chat { return true }
        guard let resolution else { return false }
        switch resolution.context.subSurface {
        case .web, .chatPanel, .app:
            return resolution.context.toolID.flatMap { catalog.tool(id: $0)?.readsComposer } ?? false
        default:
            return false
        }
    }

    /// Only needed to know whether Return should read a chat text box, so it
    /// can be a little stale; attribution itself is resolved fresh at submit.
    /// (A browser lookup is an AppleScript round trip — never per keystroke.)
    private func refreshResolutionIfStale(_ app: NSRunningApplication) {
        if let resolution, Date().timeIntervalSince(resolution.resolvedAt) < 8 { return }
        guard !resolving else { return }
        resolving = true
        let bundleID = app.bundleIdentifier
        let name = app.localizedName
        let pid = app.processIdentifier
        Task.detached(priority: .utility) { [weak self] in
            let resolved = DestinationSnapshot.resolve(bundleID: bundleID, appName: name, pid: pid)
            await MainActor.run {
                guard let self else { return }
                self.resolving = false
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                    self.resolution = resolved
                }
            }
        }
    }

    private func frontmostChanged() {
        resolution = nil
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else { return }
        let catalog = ToolCatalog.shared
        if let tool = catalog.tool(forBundleID: bundleID), tool.readsComposer {
            let pid = app.processIdentifier
            DispatchQueue.global(qos: .utility).async { SurfaceResolver.enableElectronAccessibility(pid: pid) }
        }
        // Terminal "Secure Keyboard Entry" hides every keystroke from
        // Dictator; say so once instead of silently capturing nothing.
        if catalog.hostApp(bundleID: bundleID)?.kind == .terminal, IsSecureEventInputEnabled(),
           secureInputNoticed.insert(bundleID).inserted {
            let context = CaptureContext(appBundleID: bundleID, appName: app.localizedName, subSurface: .terminal)
            if !notices.isDismissed(kind: .secureInput, context: context) {
                notices.note(.secureInput, context: context, label: "\(app.localizedName ?? bundleID) has Secure Keyboard Entry on")
            }
        }
        // Forget drafts nobody came back to.
        let cutoff = Date().addingTimeInterval(-draftExpiry)
        drafts = drafts.filter { $0.value.lastEdit > cutoff }
    }

    // MARK: - Inline prompts at a shell

    /// `claude "fix the flaky test"`, `codex exec 'add docs'`, `gemini -p
    /// "…"` typed at a shell prompt → (tool, prompt). Nil for anything else.
    nonisolated static func inlinePrompt(fromCommandLine line: String, catalog: ToolCatalog) -> (toolID: String, prompt: String)? {
        let words = shellWords(line)
        guard let first = words.first,
              let tool = catalog.tool(forCommandWords: [first]) else { return nil }
        var rest = Array(words.dropFirst())
        // Skip flags and known subcommands; what's left is the prompt.
        let subcommands: Set<String> = ["exec", "run", "chat", "ask", "e"]
        while let head = rest.first, head.hasPrefix("-") || subcommands.contains(head) {
            rest.removeFirst()
            // `-m model`, `--model x`: a flag followed by a plain value.
            if head.hasPrefix("-"), !head.contains("="), ["-m", "--model", "-c", "--config", "--cwd", "-C", "--profile"].contains(head), !rest.isEmpty {
                rest.removeFirst()
            }
        }
        let prompt = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard prompt.split(separator: " ").count >= 2 else { return nil }
        return (tool.id, prompt)
    }

    /// Minimal POSIX-ish word splitting with single and double quotes.
    nonisolated static func shellWords(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        var escape = false
        for char in line {
            if escape {
                current.append(char)
                escape = false
                continue
            }
            if char == "\\", quote != "'" {
                escape = true
                inWord = true
                continue
            }
            if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
                continue
            }
            if char == "'" || char == "\"" {
                quote = char
                inWord = true
                continue
            }
            if char.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
                continue
            }
            current.append(char)
            inWord = true
        }
        if inWord { words.append(current) }
        return words
    }
}
