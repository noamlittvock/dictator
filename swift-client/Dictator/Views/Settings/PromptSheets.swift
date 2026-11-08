import AppKit
import SwiftUI

// MARK: - First-run step: typed history

/// "Also keep what you type?" — one optional step, shown once per Mac (and
/// from Settings › History & Privacy › Choose Apps). Dictation is the product;
/// this only adds places whose typing the user wants in their History.
/// Nothing is pre-selected on first run.
struct PromptSetupView: View {
    let onDone: () -> Void
    @State private var center = PromptCaptureCenter.shared
    @State private var chatOn = false
    @State private var codingOn = false
    @State private var chatSelected: Set<String> = []
    @State private var codingSelected: Set<String> = []
    @State private var useHooks = true
    @State private var didLoad = false
    @State private var isApplying = false
    @State private var showAllChat = false
    /// Per-tool outcome of exact-capture setup. Non-empty only
    /// when at least one tool failed; the sheet then shows what worked,
    /// what didn't, Retry, and an explicit Continue.
    @State private var setupResults: [ConnectorSetupResult] = []
    @State private var retrying: Set<String> = []

    private var catalog: ToolCatalog { .shared }

    private var chatTools: [ToolDefinition] {
        catalog.tools.filter { $0.category == .chat && !ToolCatalog.isCustomTool(id: $0.id) }
    }

    private var codingTools: [ToolDefinition] {
        catalog.tools.filter { ($0.category == .agent || $0.category == .editor) && !ToolCatalog.isCustomTool(id: $0.id) }
    }

    private var installedCoding: [ToolDefinition] {
        codingTools.filter { center.statuses[$0.id]?.installed == true }
    }

    private var hookFiles: [String] {
        guard codingOn, useHooks else { return [] }
        var files: [String] = []
        for tool in installedCoding where codingSelected.contains(tool.id) && tool.connector?.supportsHook == true {
            if let path = tool.connector?.hookConfig { files.append("~/" + path) }
            if tool.connector?.hookFormat == "codex-hooks" { files.append("~/.codex/config.toml") }
        }
        return files
    }

    var body: some View {
        if setupResults.isEmpty {
            choicesBody
        } else {
            resultsBody
        }
    }

    private var choicesBody: some View {
        DSSheet(title: "Also keep what you type?", height: 600) {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                Text("Optional. Dictator can keep your dictation. It can also keep messages you send in a few places, so you can find those messages in History. Nothing you type is kept unless you choose it here or later in Settings › History & Privacy › Choose Apps.")
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !didLoad {
                    HStack(spacing: DSSpace.xs) { ProgressView().controlSize(.small); Text("Looking at this Mac…").font(.dsSecondary) }
                } else {
                    categoryCard(
                        isOn: $chatOn,
                        symbol: "bubble.left.and.bubble.right",
                        title: "Chat & assistants",
                        detail: "What you send to ChatGPT, Claude, Gemini and other assistants, in their apps and websites."
                    ) {
                        let shown = showAllChat ? chatTools : chatTools.filter { ["chatgpt", "claude", "gemini", "perplexity"].contains($0.id) || center.statuses[$0.id]?.installed == true }
                        ForEach(shown) { checkbox($0, in: $chatSelected) }
                        if !showAllChat, shown.count < chatTools.count {
                            Button("Show \(chatTools.count - shown.count) more") { showAllChat = true }
                                .buttonStyle(.dsLink)
                        }
                    }
                    if !installedCoding.isEmpty || codingOn {
                        categoryCard(
                            isOn: $codingOn,
                            symbol: "terminal",
                            title: "Terminal & coding tools",
                            detail: "Prompts you give coding agents and editor assistants — in any terminal or editor, and on servers you add later."
                        ) {
                            ForEach(installedCoding) { checkbox($0, in: $codingSelected) }
                            HStack(spacing: DSSpace.m) {
                                VStack(alignment: .leading, spacing: DSSpace.hair) {
                                    Text("Capture exactly (recommended)").font(.dsBodyMedium)
                                    Text(hookFiles.isEmpty
                                         ? "Adds a small hook to each tool's settings; a backup of every file is kept."
                                         : "Adds a small hook to \(hookFiles.joined(separator: ", ")). A backup of each is kept; undo any time.")
                                        .settingsHelpText()
                                }
                                Spacer(minLength: 0)
                                Toggle("Capture exactly (recommended)", isOn: $useHooks)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                            .padding(.top, DSSpace.xxs)
                        }
                    }
                    HStack(alignment: .top, spacing: DSSpace.s) {
                        Image(systemName: "plus.app").font(.dsIcon)
                            .foregroundStyle(Color.dsTextTertiary)
                            .frame(width: 20)
                        Text("Somewhere else — a notes app, a writing site? Add it any time in Settings › History & Privacy › Choose Apps.")
                            .font(.dsSecondary)
                            .foregroundStyle(Color.dsTextTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Label("Dictator skips password boxes, and can hide passwords and keys it recognizes.", systemImage: "lock")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }
        } leadingActions: {
            Button("Skip") {
                AppSettings.shared.didCompletePromptSetup = true
                onDone()
            }
            .buttonStyle(.dsQuiet)
        } actions: {
            if isApplying { ProgressView().controlSize(.small) }
            Button(chatOn || codingOn ? "Keep Typed History" : "Done") {
                isApplying = true
                Task {
                    var chosen = Set<String>()
                    if chatOn { chosen.formUnion(chatSelected) }
                    if codingOn {
                        chosen.formUnion(codingSelected)
                        // Coding tools not on this Mac yet are kept too —
                        // they may run on a server, or be installed later.
                        chosen.formUnion(codingTools.filter { center.statuses[$0.id]?.installed != true }.map(\.id))
                    }
                    let results = await center.completeSetup(selected: chosen, useHooks: useHooks)
                    isApplying = false
                    if results.allSatisfy(\.succeeded) {
                        onDone()
                    } else {
                        setupResults = results
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.dsPrimary)
            .tint(Color.dsAccent)
            .disabled(!didLoad || isApplying)
        }
        .task {
            await center.refreshStatuses()
            guard !didLoad else { return }
            let settings = AppSettings.shared
            chatSelected = Set(chatTools.map(\.id))
            codingSelected = Set(installedCoding.map(\.id))
            if settings.didCompletePromptSetup {
                // Re-run: start from the current choices.
                let chatNow = chatTools.filter { center.isOn($0.id) }.map(\.id)
                let codingNow = codingTools.filter { center.isOn($0.id) }.map(\.id)
                chatOn = !chatNow.isEmpty
                codingOn = !codingNow.isEmpty
                if chatOn { chatSelected = Set(chatNow) }
                if codingOn { codingSelected = Set(codingNow).intersection(installedCoding.map(\.id)) }
            }
            didLoad = true
        }
    }

    /// Shown when some tools couldn't be set up for exact capture: names
    /// each one with why, offers Retry, and lets the user continue
    /// knowingly. Typing in a failed tool is still kept from the keyboard
    /// (best effort) until it's set up.
    private var resultsBody: some View {
        let failed = setupResults.filter { !$0.succeeded }
        return DSSheet(title: failed.isEmpty ? "Everything is set up" : "Some tools weren’t set up", height: 600) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                Text(failed.isEmpty
                     ? "Typed history is on for the places you chose."
                     : "Typed history is on for the places you chose, but exact capture couldn’t be added to \(failed.count == 1 ? failed[0].toolName : "\(failed.count) tools"). Until it is, what you type there is kept from the keyboard, which can miss things in terminals.")
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(setupResults) { result in
                    HStack(alignment: .top, spacing: DSSpace.s) {
                        Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").font(.dsIcon)
                            .foregroundStyle(result.succeeded ? Color.dsSuccess : Color.dsWarning)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: DSSpace.hair) {
                            Text(result.toolName).font(.dsBodyMedium)
                            Text(result.error ?? "Set up for exact capture.")
                                .font(.dsSecondary)
                                .foregroundStyle(Color.dsTextTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if !result.succeeded {
                            if retrying.contains(result.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Retry") { retry(result) }
                            }
                        }
                    }
                }
                Text("You can set these up later in Settings › History & Privacy › Choose Apps.")
                    .font(.dsCaption)
                    .foregroundStyle(Color.dsTextTertiary)
                    .padding(.top, DSSpace.xxs)
            }
        } actions: {
            Button(failed.isEmpty ? "Done" : "Continue Without Them") {
                center.finishSetup()
                onDone()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.dsPrimary)
            .tint(Color.dsAccent)
            .disabled(!retrying.isEmpty)
        }
    }

    private func retry(_ result: ConnectorSetupResult) {
        retrying.insert(result.id)
        Task {
            let updated = await center.retryConnector(result)
            if let index = setupResults.firstIndex(where: { $0.id == result.id }) {
                setupResults[index] = updated
            }
            retrying.remove(result.id)
        }
    }

    private func categoryCard<Items: View>(
        isOn: Binding<Bool>,
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder items: () -> Items
    ) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                HStack(alignment: .top, spacing: DSSpace.s) {
                    HStack(alignment: .top, spacing: DSSpace.s) {
                        Image(systemName: symbol).font(.dsIcon)
                            .foregroundStyle(isOn.wrappedValue ? Color.dsAccent : Color.dsTextSecondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: DSSpace.hair) {
                            Text(title).font(.dsBodyMedium)
                            Text(detail)
                                .font(.dsSecondary)
                                .foregroundStyle(Color.dsTextTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Toggle(title, isOn: isOn)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if isOn.wrappedValue {
                    VStack(alignment: .leading, spacing: DSSpace.xxs) { items() }
                        .padding(.leading, DSSpace.xl)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func checkbox(_ tool: ToolDefinition, in selection: Binding<Set<String>>) -> some View {
        HStack(spacing: DSSpace.m) {
            HStack(spacing: DSSpace.xs) {
                Text(tool.name).font(.dsBodyMedium)
                Text(caption(tool)).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            }
            Spacer(minLength: 0)
            Toggle(tool.name, isOn: Binding(
                get: { selection.wrappedValue.contains(tool.id) },
                set: { on in if on { selection.wrappedValue.insert(tool.id) } else { selection.wrappedValue.remove(tool.id) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    private func caption(_ tool: ToolDefinition) -> String {
        switch tool.category {
        case .agent: tool.connector?.supportsHook == true ? "" : "keyboard only"
        case .chat: [center.statuses[tool.id]?.installed == true && !tool.signatures.bundleIDs.isEmpty ? "app" : nil, tool.signatures.domains.first]
            .compactMap { $0 }.joined(separator: " · ")
        case .editor: "chat panel"
        }
    }
}

// MARK: - Capture method

struct CaptureMethodSheet: View {
    let tool: ToolDefinition
    let onDone: () -> Void
    @State private var center = PromptCaptureCenter.shared
    @State private var choice: CaptureMethod = .keystrokes
    @State private var isApplying = false

    var body: some View {
        DSSheet(title: "How should Dictator capture \(tool.name) on this Mac?", width: .standard) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                ForEach(center.availableMethods(for: tool), id: \.self) { method in
                    Button {
                        choice = method
                    } label: {
                        HStack(alignment: .top, spacing: DSSpace.s) {
                            Image(systemName: choice == method ? "largecircle.fill.circle" : "circle").font(.dsIcon)
                                .foregroundStyle(choice == method ? Color.dsAccent : Color.dsTextTertiary)
                            VStack(alignment: .leading, spacing: DSSpace.hair) {
                                HStack(spacing: DSSpace.xs) {
                                    Text(method.title).font(.dsBodyMedium)
                                    if method == center.recommendedMethod(for: tool) {
                                        DSBadge(text: "Recommended", tone: .accent)
                                    }
                                }
                                Text(detail(method))
                                    .font(.dsSecondary)
                                    .foregroundStyle(Color.dsTextTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let error = center.lastConnectorError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.dsSecondary)
                        .foregroundStyle(Color.dsWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button("Cancel", action: onDone)
            if isApplying { ProgressView().controlSize(.small) }
            Button("Use \(choice.title)") {
                isApplying = true
                Task {
                    await center.setMethod(choice, for: tool)
                    isApplying = false
                    if center.lastConnectorError == nil { onDone() }
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.dsPrimary)
            .tint(Color.dsAccent)
        }
        .onAppear { choice = center.statuses[tool.id]?.method ?? center.recommendedMethod(for: tool) }
    }

    private func detail(_ method: CaptureMethod) -> String {
        switch method {
        case .hook:
            var files = ["~/" + (tool.connector?.hookConfig ?? "")]
            if tool.connector?.hookFormat == "codex-hooks" { files.append("~/.codex/config.toml") }
            return "Exact, wherever you run it on this Mac. Adds one hook to \(files.joined(separator: " and ")); a backup is kept."
        case .transcript:
            return "Exact. Reads ~/\(tool.connector?.transcript?.path ?? "its history file") as you go. Changes nothing."
        case .keystrokes:
            return tool.category == .agent
                ? "No setup. Rebuilt from your keystrokes — pasted and edited text can be off."
                : "No setup. Reads the text box when you send."
        }
    }
}

// MARK: - Add a server

struct AddServerSheet: View {
    let initialAlias: String
    let onDone: () -> Void

    private enum Step: Equatable {
        case choose
        case checking
        case pick(RemoteCaptureService.Probe)
        case installing
        case done(String)
        case failed(String)
    }

    @State private var center = PromptCaptureCenter.shared
    @State private var alias = ""
    @State private var step: Step = .choose
    @State private var chosenTools: Set<String> = []

    var body: some View {
        DSSheet(title: "Capture prompts from a server") {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                content
            }
        } actions: {
            sheetActions
        }
        .onAppear {
            alias = initialAlias
            center.remote.refreshConfiguredAliases()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .choose:
            Text("Use the name you type after `ssh`. Dictator connects with your own SSH keys; it never asks for or stores a password.")
                .settingsHelpText()
            HStack(spacing: DSSpace.xs) {
                TextField("Server (e.g. build-box or me@10.0.0.5)", text: $alias)
                    .textFieldStyle(.roundedBorder)
                if !center.remote.configuredAliases.isEmpty {
                    Menu("From SSH Config") {
                        ForEach(center.remote.configuredAliases, id: \.self) { name in
                            Button(name) { alias = name }
                        }
                    }
                    .fixedSize()
                }
            }
        case .checking:
            HStack(spacing: DSSpace.xs) { ProgressView().controlSize(.small); Text("Connecting to \(alias)…") }
        case .pick(let probe):
            if probe.detectedToolIDs.isEmpty {
                Text("No supported coding agents were found on \(alias)\(probe.system.isEmpty ? "" : " (\(probe.system))"). Install one there, then check again.")
                    .settingsHelpText()
            } else {
                Text("Found on \(alias)\(probe.system.isEmpty ? "" : " (\(probe.system))"). Dictator will add a small hook to each one you choose there, keeping a backup of every file it changes.")
                    .settingsHelpText()
                ForEach(probe.detectedToolIDs, id: \.self) { id in
                    HStack(spacing: DSSpace.m) {
                        Text(ToolCatalog.shared.tool(id: id)?.name ?? id).font(.dsBodyMedium)
                        Spacer(minLength: 0)
                        Toggle(ToolCatalog.shared.tool(id: id)?.name ?? id, isOn: Binding(
                            get: { chosenTools.contains(id) },
                            set: { on in if on { chosenTools.insert(id) } else { chosenTools.remove(id) } }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
        case .installing:
            HStack(spacing: DSSpace.xs) {
                ProgressView().controlSize(.small)
                Text(center.remote.progress[alias] ?? "Setting up \(alias)…")
            }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.dsSuccess)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            DSEmptyState(symbol: "exclamationmark.triangle", title: message)
        }
    }

    @ViewBuilder
    private var sheetActions: some View {
        switch step {
        case .choose:
            buttons(primary: "Check Server", enabled: SSHRunner.isValidHost(alias.trimmingCharacters(in: .whitespaces))) { check() }
        case .checking, .installing:
            buttons(primary: nil, enabled: false) {}
        case .pick(let probe):
            if probe.detectedToolIDs.isEmpty {
                buttons(primary: "Check Again", enabled: true) { check() }
            } else {
                buttons(primary: "Enable Capture", enabled: !chosenTools.isEmpty) { install() }
            }
        case .done:
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.dsPrimary)
        case .failed:
            buttons(primary: "Try Again", enabled: true) { step = .choose }
        }
    }

    @ViewBuilder
    private func buttons(primary: String?, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button("Cancel", action: onDone)
        if let primary {
            Button(primary, action: action)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.dsPrimary)
                .disabled(!enabled)
        }
    }

    private func check() {
        alias = alias.trimmingCharacters(in: .whitespaces)
        step = .checking
        Task {
            do {
                let probe = try await center.remote.probe(alias)
                let settings = AppSettings.shared
                chosenTools = Set(probe.detectedToolIDs.filter { settings.surfacePolicy.isToolOn($0) || ToolCatalog.shared.tool(id: $0)?.defaultOn == true })
                step = .pick(probe)
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    private func install() {
        step = .installing
        let tools = Array(chosenTools)
        Task {
            do {
                try await center.remote.enable(alias, toolIDs: tools)
                for id in tools where !center.isOn(id) { center.setTool(id, on: true) }
                center.notices.resolve { $0.kind == .remote && $0.remoteHost?.caseInsensitiveCompare(alias) == .orderedSame }
                let names = tools.compactMap { ToolCatalog.shared.tool(id: $0)?.name }.joined(separator: ", ")
                if let error = center.remote.host(alias)?.lastError {
                    step = .failed(error)
                } else {
                    step = .done("Done. Prompt capture is set up for \(names) on \(alias).")
                }
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Add an exception

struct AddExceptionSheet: View {
    let onDone: () -> Void

    private enum Target: String, CaseIterable, Identifiable {
        case app = "App"
        case website = "Website"
        case server = "Server"
        case tool = "Tool"
        var id: String { rawValue }
    }

    @State private var action = "save"
    @State private var target: Target = .app
    @State private var appBundleID = ""
    @State private var text = ""
    @State private var toolID = ""
    @State private var modality = "typed"

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        DSSheet(title: "Add an exception", width: .compact) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                Picker("", selection: $action) {
                    Text("Always save").tag("save")
                    Text("Never save").tag("ignore")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("From", selection: $target) {
                    ForEach(Target.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch target {
                case .app:
                    HStack(spacing: DSSpace.xs) {
                        Picker("App", selection: $appBundleID) {
                            Text("Choose…").tag("")
                            ForEach(runningApps, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                        }
                        Button("Browse…") { browseApp() }
                    }
                case .website:
                    TextField("Website (e.g. notion.so)", text: $text).textFieldStyle(.roundedBorder)
                case .server:
                    TextField("Server name (* matches anything, e.g. work-*)", text: $text).textFieldStyle(.roundedBorder)
                case .tool:
                    Picker("Tool", selection: $toolID) {
                        Text("Choose…").tag("")
                        ForEach(ToolCatalog.shared.tools) { Text($0.name).tag($0.id) }
                    }
                }
                Picker("Applies to", selection: $modality) {
                    Text("Typing").tag("typed")
                    Text("Dictation").tag("voice")
                    Text("Both").tag("both")
                }
                .pickerStyle(.segmented)
            }
        } actions: {
            Button("Cancel", action: onDone)
            Button("Add") { add() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.dsPrimary)
                .tint(Color.dsAccent)
                .disabled(pattern.isEmpty)
        }
    }

    private var pattern: String {
        switch target {
        case .app: appBundleID
        case .website: SurfacePolicy.extractHost(from: text.hasPrefix("http") ? text : "https://" + text) ?? ""
        case .server: text.trimmingCharacters(in: .whitespaces)
        case .tool: toolID
        }
    }

    private var kind: String {
        switch target {
        case .app: "app"
        case .website: "domain"
        case .server: "remote"
        case .tool: "tool"
        }
    }

    private func browseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
            appBundleID = id
        }
    }

    private func add() {
        let rule = SurfaceRule(kind: kind, pattern: pattern, action: action, modality: modality)
        AppSettings.shared.updateSurfacePolicy { policy in
            policy.rules.removeAll { $0.kind == rule.kind && $0.pattern == rule.pattern && $0.modality == rule.modality }
            policy.rules.insert(rule, at: 0)
        }
        onDone()
    }
}

// MARK: - Add a tool

struct AddToolSheet: View {
    let onDone: () -> Void

    private enum Kind: String, CaseIterable, Identifiable {
        case command = "Terminal command"
        case app = "Desktop app"
        case website = "Website"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var kind: Kind = .command
    @State private var value = ""
    @State private var error: String?

    var body: some View {
        DSSheet(title: "Add a tool", width: .compact) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                TextField("Name (e.g. My Agent)", text: $name).textFieldStyle(.roundedBorder)
                Picker("", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: DSSpace.xs) {
                    TextField(placeholder, text: $value).textFieldStyle(.roundedBorder)
                    if kind == .app {
                        Button("Browse…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.application]
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            if panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url) {
                                value = bundle.bundleIdentifier ?? ""
                                if name.isEmpty { name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
                            }
                        }
                    }
                }
                Text(help).settingsHelpText()
                if let error { Text(error).font(.dsSecondary).foregroundStyle(Color.dsWarning) }
            }
        } actions: {
            Button("Cancel", action: onDone)
            Button("Add and Switch On") { add() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.dsPrimary)
                .tint(Color.dsAccent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || value.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var placeholder: String {
        switch kind {
        case .command: "Command you run (e.g. myagent)"
        case .app: "App (Browse… or its bundle ID)"
        case .website: "Website (e.g. chat.example.com)"
        }
    }

    private var help: String {
        switch kind {
        case .command: "Prompts typed into it in any terminal — or over SSH — are saved from the keyboard."
        case .app: "Prompts sent from its text box are saved."
        case .website: "Prompts sent on this site, in any browser, are saved."
        }
    }

    private func add() {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let slug = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        var signatures = ToolSignatures()
        let category: ToolCategory
        switch kind {
        case .command:
            signatures.processNames = [URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()]
            category = .agent
        case .app:
            signatures.bundleIDs = [trimmed]
            category = .chat
        case .website:
            guard let host = SurfacePolicy.extractHost(from: trimmed.hasPrefix("http") ? trimmed : "https://" + trimmed) else {
                error = "That doesn't look like a website address."
                return
            }
            signatures.domains = [host]
            category = .chat
        }
        let tool = ToolDefinition(
            id: "custom-\(slug.isEmpty ? UUID().uuidString.prefix(8).lowercased() : slug)",
            name: name.trimmingCharacters(in: .whitespaces),
            category: category,
            signatures: signatures,
            readsComposer: kind != .command
        )
        do {
            try ToolCatalog.saveCustomTool(tool)
            PromptCaptureCenter.shared.setTool(tool.id, on: true)
            Task { await PromptCaptureCenter.shared.refreshStatuses() }
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
