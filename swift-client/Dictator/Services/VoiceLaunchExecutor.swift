import AppKit
import ApplicationServices
import Foundation

/// Runs a resolved voice launch plan on the Mac the words would land on.
/// Steps run in order and stop at the first failure; nothing runs after a
/// failure. A problem comes back as an alert, and the main words are left on
/// the clipboard so nothing said is lost.
@MainActor
enum VoiceLaunchExecutor {
    enum Result {
        case done
        case stopped(DictationAlert)
        /// The user pressed Esc at a "Sending in 3 s" pause. Not a problem.
        case cancelled(DictationAlert)
    }

    static let pollInterval: TimeInterval = 0.25

    /// The steps this build can run.
    nonisolated static let supportedKinds: Set<VoiceStep.Kind> = Set(VoiceStep.Kind.allCases)

    struct Failure: Error { var alert: DictationAlert }
    private struct Cancelled: Error {}

    /// The app the chain is working with, so a wait knows what to look for.
    struct Context {
        var appBundleId: String?
        var appName: String?
    }

    /// How the user cancelled: nothing was sent and the words are kept.
    static let cancelAlert = DictationAlert(
        title: "Cancelled. Nothing was sent",
        detail: "Your words were copied to the clipboard.", action: nil, tone: .notice)

    /// A cancel after an earlier step opened a chat with the message filled
    /// in (or typed it): the draft stays there, unsent. Cancelling can't
    /// take it back, so say so rather than imply it's gone.
    static func cancelAlert(draftLeftIn app: String) -> DictationAlert {
        DictationAlert(
            title: "Cancelled. Nothing was sent",
            detail: "\(app) may still show the message, filled in but not sent. Your words were copied to the clipboard.",
            action: nil, tone: .notice)
    }

    /// Steps after which something of the message can stay on screen.
    static func leavesSomethingOpen(_ step: VoiceStep) -> Bool {
        switch step.kind {
        case .openLink: true
        case .typeText: !(step.text ?? "").isEmpty
        default: false
        }
    }

    /// `releasedAt`: when the user let go of the key, for the total time.
    /// `progress`: told as each step starts, finishes or fails.
    /// `answered`: told each Shortcut's answer as it comes in (the Shortcuts
    /// action "Run a Command" returns the last one).
    /// `trigger`: how the command was started.
    static func run(_ plan: VoiceLaunchPlan, releasedAt: Date? = nil, services injected: VoiceLaunchServices? = nil,
                    trigger: VoiceCommandTrigger = .voice,
                    activity: CommandActivity? = nil,
                    progress: ((VoiceLaunchProgress.Event) -> Void)? = nil,
                    answered: ((VoiceShortcutAnswer) -> Void)? = nil) async -> Result {
        let activity = activity ?? .shared
        let run = await activity.begin(plan)
        let result = await execute(plan, releasedAt: releasedAt, services: injected ?? .live, progress: progress, answered: answered)
        activity.finish(run, plan: plan, trigger: trigger, result: result)
        return result
    }

    private static func execute(_ plan: VoiceLaunchPlan, releasedAt: Date?, services: VoiceLaunchServices,
                                progress: ((VoiceLaunchProgress.Event) -> Void)?,
                                answered: ((VoiceShortcutAnswer) -> Void)?) async -> Result {
        let started = Date()
        if let unsupported = plan.steps.first(where: { !supportedKinds.contains($0.kind) }) {
            HotkeyService.recordDiagnostics("voicelaunch: \(plan.commandName) not run, needs \(unsupported.kind.rawValue)")
            return keep(plan.mainText, services, DictationAlert(
                title: "This command needs a newer Dictator",
                detail: "It uses an action (“\(unsupported.kind.label)”) that this version of Dictator can’t run yet. Nothing was sent. Your words are on the clipboard.",
                action: nil))
        }
        if let missing = plan.missingDetail {
            HotkeyService.recordDiagnostics("voicelaunch: \(plan.commandName) not run, a detail it needs is empty")
            return keep(plan.mainText, services, DictationAlert(
                title: missing,
                detail: "Add it in Commands › People. Nothing was opened or sent. Your words are on the clipboard.",
                action: nil))
        }
        var context = Context()
        // Steps that already left something on screen (a chat with the
        // message filled in, typed text), so a cancel can say what stays.
        var leftOpen = false
        // Answers of Shortcuts that already ran, for the steps that use them.
        var answers: [String: VoiceRenderValue] = [:]
        for (index, planned) in plan.steps.enumerated() {
            let step = VoiceStepRenderer.resolve(planned, answers: answers, mac: services.macName())
            let stepStart = Date()
            progress?(.stepStarted(index))
            do {
                let answer = try await perform(step, next: plan.steps.dropFirst(index + 1).first, context: &context, services: services) {
                    progress?(.countdown(index, $0))
                }
                if let answer {
                    answers[step.answerKey] = answer.renderValue
                    answered?(answer)
                }
                if leavesSomethingOpen(step) { leftOpen = true }
                HotkeyService.recordDiagnostics("voicelaunch: step \(index + 1)/\(plan.steps.count) \(step.kind.rawValue) ok \(ms(since: stepStart))ms")
                progress?(.stepDone(index))
            } catch is CancellationError {
                progress?(.stepCancelled(index))
                if !plan.mainText.isEmpty { services.setClipboard(plan.mainText) }
                return .cancelled(DictationAlert(title: "Command cancelled",
                    detail: "The running command was stopped. Earlier actions may already have finished. Your words are on the clipboard.",
                    action: nil, tone: .notice))
            } catch is Cancelled {
                HotkeyService.recordDiagnostics("voicelaunch: step \(index + 1)/\(plan.steps.count) \(step.kind.rawValue) cancelled \(ms(since: stepStart))ms")
                progress?(.stepCancelled(index))
                HotkeyService.recordDiagnostics("voicelaunch: stopped after \(ms(since: releasedAt ?? started))ms")
                return cancel(plan.mainText, services, draftLeftIn: leftOpen ? (context.appName ?? "The app") : nil)
            } catch let failure as Failure {
                HotkeyService.recordDiagnostics("voicelaunch: step \(index + 1)/\(plan.steps.count) \(step.kind.rawValue) failed \(ms(since: stepStart))ms")
                progress?(.stepFailed(index))
                HotkeyService.recordDiagnostics("voicelaunch: stopped after \(ms(since: releasedAt ?? started))ms")
                return keep(plan.mainText, services, failure.alert)
            } catch {
                progress?(.stepFailed(index))
                return keep(plan.mainText, services, DictationAlert(title: "The command stopped", detail: "Your words are on the clipboard.", action: nil))
            }
        }
        HotkeyService.recordDiagnostics("voicelaunch: total \(ms(since: releasedAt ?? started))ms (\(releasedAt == nil ? "from start" : "from key release")) \(plan.steps.count) steps")
        return .done
    }

    private static func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    /// Returns the Shortcut's answer for a step that gives one.
    private static func perform(_ step: VoiceStep, next: VoiceStep?, context: inout Context, services: VoiceLaunchServices,
                                countdown: @escaping (Int) -> Void) async throws -> VoiceShortcutAnswer? {
        switch step.kind {
        case .openLink:
            try openLink(step, context: &context)
            try await waitForOpenedAppIfNeeded(next: next, context: context, services: services)
        case .openApp:
            try await openApp(step, context: &context, services: services)
            try await waitForOpenedAppIfNeeded(next: next, context: context, services: services)
        case .runWorkspace:
            try await runWorkspace(step, services: services)
        case .waitForTextField:
            try await requireAccessibility(services)
            // Nothing to type after it: opening was the whole job.
            if let next, next.kind == .typeText, next.deferred == nil, (next.text ?? "").isEmpty { return nil }
            try await waitForTextField(step, context: &context, services: services)
        case .typeText: try await typeText(step, context: context, services: services)
        case .runInTerminal:
            if step.background == true { try await runInBackground(step, services: services) }
            else { try runInTerminal(step, services: services) }
        case .confirm:
            guard await services.confirm(step.seconds ?? VoiceStep.defaultConfirmSeconds, countdown) else { throw Cancelled() }
        case .pressKey:
            try await requireAccessibility(services)
            try pressKey(step, context: context, services: services)
        case .runAppleShortcut: return try await VoiceLaunchActing.runAppleShortcut(step, services: services)
        case .webhook: try await VoiceLaunchActing.sendWebhook(step, session: services.session)
        case .appendToFile: try VoiceLaunchActing.appendLine(step, now: services.now())
        }
        return nil
    }

    private static func waitsForOpenedApp(_ step: VoiceStep) -> Bool {
        [.waitForTextField, .typeText, .pressKey].contains(step.kind)
    }

    static func waitForOpenedAppIfNeeded(next: VoiceStep?, context: Context, services: VoiceLaunchServices) async throws {
        guard let next, waitsForOpenedApp(next) else { return }
        try await requireAccessibility(services)
        try await waitForFrontmost(context: context, services: services)
    }

    static func requireAccessibility(_ services: VoiceLaunchServices) async throws {
        guard services.isAccessibilityTrusted() else {
            throw Failure(alert: DictationAlert(title: "Dictator needs Accessibility access",
                detail: "Turn it on in System Settings › Privacy & Security › Accessibility. Your words are on the clipboard.",
                action: .accessibilityPrivacy))
        }
    }

    static func waitForFrontmost(context: Context, services: VoiceLaunchServices) async throws {
        guard let expected = context.appBundleId else { return }
        var elapsed: TimeInterval = 0
        while elapsed < 10 {
            if services.frontmostBundleId() == expected { return }
            await services.sleep(.milliseconds(Int(pollInterval * 1000)))
            elapsed += pollInterval
        }
        throw Failure(alert: DictationAlert(title: "\(context.appName ?? "The app") didn’t come to the front",
                                            detail: "Your words are on the clipboard.", action: nil))
    }

    // MARK: pressKey

    /// Only into the app the chain is working with, so a key never lands in
    /// whatever else came to the front during the pause.
    private static func pressKey(_ step: VoiceStep, context: Context, services: VoiceLaunchServices) throws {
        if let expected = context.appBundleId, services.frontmostBundleId() != expected {
            throw Failure(alert: VoiceLaunchActing.problem("\(context.appName ?? "The app") isn’t in front", "Nothing was sent."))
        }
        guard services.pressKey(step.key ?? "") else {
            throw Failure(alert: VoiceLaunchActing.problem("Dictator couldn’t press the key",
                                                           "It needs Accessibility access. Nothing was sent."))
        }
    }

    // MARK: openLink

    /// A scheme this feature may open, checked again here because the plan
    /// arrives over the network.
    static func isAllowedLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return VoiceCommandCatalog.shared.allowedLinkSchemes.contains(scheme)
    }

    private static func openLink(_ step: VoiceStep, context: inout Context) throws {
        guard let url = URL(string: step.link ?? ""), isAllowedLink(url), NSWorkspace.shared.open(url) else {
            throw Failure(alert: DictationAlert(
                title: "The command’s web address didn’t open",
                detail: "Check its address in Commands. Your words are on the clipboard.", action: .dictation))
        }
        if let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            context.appBundleId = Bundle(url: app)?.bundleIdentifier
            context.appName = displayName(app)
        }
    }

    // MARK: openApp

    private static func openApp(_ step: VoiceStep, context: inout Context, services: VoiceLaunchServices) async throws {
        let target = step.bundleId ?? ""
        if target.isEmpty {
            let spoken = step.text ?? ""
            let apps = await services.installedApps()
            let matches = VoiceNameResolver.matches(spoken, in: apps.map(\.name))
            guard matches.count == 1 else {
                let title = matches.isEmpty
                    ? "No app called “\(spoken)” on \(services.macName().isEmpty ? "this Mac" : services.macName())"
                    : "More than one app is called “\(spoken)”: \(matches.map { apps[$0].name }.joined(separator: ", "))"
                throw Failure(alert: DictationAlert(title: title, detail: "Your words are on the clipboard.", action: nil))
            }
            let app = apps[matches[0]]
            guard await services.openNamedApp(app.url) else { throw Failure(alert: appDidNotOpen(app.name, services: services)) }
            context.appBundleId = app.bundleID
            context.appName = app.name
            return
        }
        let workspace = NSWorkspace.shared
        var appURL: URL?
        var opensURL: URL?
        if target.contains("://") || target.lowercased().hasPrefix("mailto:") {
            if let url = URL(string: target), isAllowedLink(url) {
                opensURL = url
                appURL = workspace.urlForApplication(toOpen: url)
            }
        } else {
            appURL = workspace.urlForApplication(withBundleIdentifier: target)
        }
        guard let appURL else { throw Failure(alert: appNotFound(target, services: services)) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            if let opensURL {
                try await workspace.open([opensURL], withApplicationAt: appURL, configuration: configuration)
            } else {
                try await workspace.openApplication(at: appURL, configuration: configuration)
            }
        } catch {
            // The app is installed but didn't start: say so, not "install it".
            throw Failure(alert: appDidNotOpen(displayName(appURL), services: services))
        }
        context.appBundleId = Bundle(url: appURL)?.bundleIdentifier ?? (target.contains("://") ? nil : target)
        context.appName = displayName(appURL)
    }

    private static func runWorkspace(_ step: VoiceStep, services: VoiceLaunchServices) async throws {
        let spoken = step.text ?? ""
        let routines = services.workspaceRoutines()
        let matches = step.workspaceId.map { id in routines.indices.filter { routines[$0].id == id } }
            ?? VoiceNameResolver.matches(spoken, in: routines.map(\.name))
        guard matches.count == 1 else {
            let title = matches.isEmpty
                ? "No routine called “\(spoken)” on \(services.macName().isEmpty ? "this Mac" : services.macName())"
                : "More than one routine is called “\(spoken)”: \(matches.map { routines[$0].name }.joined(separator: ", "))"
            throw Failure(alert: DictationAlert(title: title, detail: "Check the routine names in Workspaces. Your words are on the clipboard.", action: nil))
        }
        guard routines[matches[0]].enabled else {
            throw Failure(alert: DictationAlert(title: "This routine is off. Turn it on to run it.", detail: "Your words are on the clipboard.", action: nil))
        }
        do { try await services.runWorkspace(routines[matches[0]].id) }
        catch { throw Failure(alert: DictationAlert(title: error.localizedDescription, detail: "Your words are on the clipboard.", action: nil)) }
    }

    static func appNotFound(_ bundleId: String, services: VoiceLaunchServices) -> DictationAlert {
        let app = VoiceAppNames.name(for: bundleId)
            ?? ToolCatalog.shared.hostApps.first(where: { $0.bundleIDs.contains(bundleId) })?.name
            ?? bundleId.split(separator: ".").last.map(String.init) ?? bundleId
        let mac = services.macName().isEmpty ? "this Mac" : services.macName()
        return DictationAlert(title: "\(app) isn’t on \(mac)",
            detail: "Install it on this Mac, or run the command from a Mac that has it. Your words are on the clipboard.", action: nil)
    }

    static func appDidNotOpen(_ app: String, services: VoiceLaunchServices) -> DictationAlert {
        let mac = services.macName().isEmpty ? "this Mac" : services.macName()
        return DictationAlert(title: "Couldn’t open \(app) on \(mac)",
            detail: "Try opening it yourself, then run the command again. Your words are on the clipboard.", action: nil)
    }

    private static func displayName(_ appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: waitForTextField

    private static func waitForTextField(_ step: VoiceStep, context: inout Context, services: VoiceLaunchServices) async throws {
        // A step can name the app it expects (WhatsApp, say).
        if let expected = step.bundleId, !expected.isEmpty {
            context.appBundleId = expected
            context.appName = VoiceAppNames.name(for: expected) ?? context.appName
        }
        let timeout = step.seconds ?? VoiceStep.defaultWaitSeconds
        // Time spent asking a slow app counts too: the wait ends on whichever
        // is later reached, the clock or the number of polls.
        let started = services.now()
        var slept: TimeInterval = 0
        while max(slept, services.now().timeIntervalSince(started)) < timeout {
            let front = services.frontmostBundleId()
            if (context.appBundleId == nil || front == context.appBundleId), focusedElementIsEditable() { return }
            await services.sleep(.milliseconds(Int(pollInterval * 1000)))
            slept += pollInterval
        }
        throw Failure(alert: DictationAlert(
            title: "Couldn’t find a place to type in \(context.appName ?? "that app")",
            detail: "Your words are on the clipboard. Click where you want them and press ⌘V.", action: nil))
    }

    /// True when the focused element takes typing: a text field, text area,
    /// combo box or search field, or anything whose value can be set.
    static func focusedElementIsEditable() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }
        let element = focusedRef as! AXUIElement
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        if [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) { return true }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    // MARK: typeText

    static func typeText(_ step: VoiceStep, context: Context, services: VoiceLaunchServices) async throws {
        let text = step.text ?? ""
        guard !text.isEmpty else { return }
        try await requireAccessibility(services)
        if let expected = context.appBundleId, services.frontmostBundleId() != expected {
            throw Failure(alert: VoiceLaunchActing.problem("\(context.appName ?? "The app") isn’t in front", "Nothing was typed."))
        }
        // The paste checks the app again right before ⌘V; once it reports
        // .pasted the words are in, and a later key press checks again itself.
        let outcome = await services.pasteText(text, context.appBundleId)
        if case .clipboardOnly(let reason, let needsAccessibility) = outcome {
            throw Failure(alert: .clipboardOnly(reason: reason, needsAccessibility: needsAccessibility))
        }
    }

    // MARK: runInTerminal

    private static func runInBackground(_ step: VoiceStep, services: VoiceLaunchServices) async throws {
        let task = Task { try await VoiceLaunchActing.runBackgroundCommand(step, services: services) }
        let token = VoiceLaunchEscapeWatch.register { task.cancel() }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            task.cancel()
            return nil
        }
        defer {
            VoiceLaunchEscapeWatch.unregister(token)
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        try await withTaskCancellationHandler {
            try await task.value
            if task.isCancelled { throw CancellationError() }
        } onCancel: { task.cancel() }
    }

    private static func runInTerminal(_ step: VoiceStep, services: VoiceLaunchServices) throws {
        let folder = step.folder ?? ""
        let path = (folder as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure(alert: folderNotFound(folder, macName: services.macName()))
        }
        let command = step.command ?? ""
        let range = NSRange(command.startIndex..., in: command)
        let chosen = ToolCatalog.shared.hostApps.first { $0.id == AppSettings.shared.voiceCommandTerminalApp && $0.kind == .terminal }
        let terminal = chosen
        if let terminal, !terminal.runsScripts {
            throw Failure(alert: DictationAlert(title: "\(terminal.name) can’t start a coding assistant for Dictator on \(services.macName().isEmpty ? "this Mac" : services.macName())",
                                                detail: "Your words are on the clipboard.", action: nil))
        }
        let terminalBundle = terminal.flatMap { VoiceLaunchReadiness.terminalBundle(for: $0, appInstalled: services.appInstalled) }
        let appURL = terminalBundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        guard let terminalBundle, let appURL else {
            let name = terminal?.name ?? AppSettings.shared.voiceCommandTerminalApp
            throw Failure(alert: DictationAlert(title: "\(name) isn’t on \(services.macName().isEmpty ? "this Mac" : services.macName())",
                                                detail: "Your words are on the clipboard.", action: nil))
        }
        guard command.count <= 200, VoiceLaunchConfig.terminalCommandAllowed.firstMatch(in: command, range: range) != nil,
              let script = writeScript(folder: path, command: command, argument: step.argument ?? "") else {
            throw Failure(alert: DictationAlert(title: "Dictator couldn’t open a terminal", detail: "Your words are on the clipboard.", action: nil))
        }
        let workspace = NSWorkspace.shared
        workspace.open([script.file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { try? FileManager.default.removeItem(at: script.directory) }
        }
        // The script deletes itself first; this only sweeps the empty folder.
        let directory = script.directory
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { try? FileManager.default.removeItem(at: directory) }
    }

    nonisolated static func folderNotFound(_ folder: String, macName: String) -> DictationAlert {
        let mac = macName.isEmpty ? "this Mac" : macName
        return DictationAlert(title: "That folder isn’t on \(mac)",
            detail: "“\(folder)” wasn’t found here. Your words are on the clipboard. Check the folder in Commands.", action: .dictation)
    }

    /// A `.command` file (owner-only) in a private folder.
    private static func writeScript(folder: String, command: String, argument: String) -> (directory: URL, file: URL)? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-shortcut-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("Dictator command.command")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let contents = ShellQuote.terminalScript(folder: folder, command: command, argument: argument)
            guard FileManager.default.createFile(atPath: file.path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o700]) else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            return (directory, file)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    // MARK: shared

    private static func keep(_ text: String, _ services: VoiceLaunchServices, _ alert: DictationAlert) -> Result {
        if !text.isEmpty { services.setClipboard(text) }
        return .stopped(alert)
    }

    private static func cancel(_ text: String, _ services: VoiceLaunchServices, draftLeftIn app: String?) -> Result {
        if !text.isEmpty { services.setClipboard(text) }
        return .cancelled(app.map { cancelAlert(draftLeftIn: $0) } ?? cancelAlert)
    }
}
