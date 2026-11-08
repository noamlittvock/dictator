import AppKit
import SwiftUI

/// Settings → Typed History: which of the places you type in Dictator also
/// keeps in your History, next to your dictation. Off until the user opts in.
///
/// Grouped by kind of place — chat assistants, terminal & coding tools, apps
/// and sites you add — never by bundle ID: one switch per tool covers it
/// wherever it runs (any terminal, an editor, tmux, over SSH, its app and its
/// website). The coding-tool depth (hooks, servers, capture methods) lives
/// only inside "Terminal & coding tools".
struct PromptsSettingsTab: View {
    @State private var settings = AppSettings.shared
    @State private var center = PromptCaptureCenter.shared
    @State private var setupTool: ToolDefinition?
    @State private var showSetup = false
    @State private var showAddServer = false
    @State private var serverToAdd = ""
    @State private var showAddException = false
    @State private var showAddTool = false
    @State private var expandedLists: Set<String> = []
    @State private var codingExpanded: Bool?
    @State private var confirmRemoveAll = false

    private var catalog: ToolCatalog { .shared }

    var body: some View {
        SettingsStack {
            statusSection
            if isTypedHistoryOn, !center.notices.active.isEmpty { noticedSection }
            chatSection
            codingSection
            appsSection
        }
        .task { await center.refreshStatuses() }
        .sheet(item: $setupTool) { tool in
            CaptureMethodSheet(tool: tool) { setupTool = nil }
        }
        .sheet(isPresented: $showSetup) {
            PromptSetupView { showSetup = false }
        }
        .sheet(isPresented: $showAddServer) {
            AddServerSheet(initialAlias: serverToAdd) { showAddServer = false }
        }
        .sheet(isPresented: $showAddException) {
            AddExceptionSheet { showAddException = false }
        }
        .sheet(isPresented: $showAddTool) {
            AddToolSheet { showAddTool = false }
        }
    }

    // MARK: - Status

    private var onCount: Int {
        catalog.tools.filter { center.isOn($0.id) }.count
    }

    private var isTypedHistoryOn: Bool {
        settings.surfacePolicy.allowsAnyTypedSave
    }

    private var statusSection: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                HStack(alignment: .top, spacing: DSSpace.s) {
                    Image(systemName: statusSymbol)
                        .font(.dsIconHero)
                        .foregroundStyle(statusTint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: DSSpace.hair) {
                        Text(statusTitle)
                            .font(.dsSection)
                            .foregroundStyle(Color.dsTextPrimary)
                        Text(statusDetail)
                            .font(.dsSecondary)
                            .foregroundStyle(Color.dsTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DSSpace.xs)
                }
                HStack(spacing: DSSpace.xs) {
                    if !settings.persistHistory {
                        Button("Turn History On") { settings.persistHistory = true }
                            .buttonStyle(.dsPrimary)
                            .tint(Color.dsAccent)
                    } else if !isTypedHistoryOn {
                        Button("Choose Where…") { showSetup = true }
                            .buttonStyle(.dsPrimary)
                            .tint(Color.dsAccent)
                    } else if center.pauseDescription != nil {
                        Button("Resume") { center.resume() }
                            .buttonStyle(.dsPrimary)
                            .tint(Color.dsAccent)
                    } else {
                        Menu("Pause") {
                            Button("For 15 minutes") { center.pause(for: 15 * 60) }
                            Button("For 1 hour") { center.pause(for: 3_600) }
                            Button("Until I resume") { center.pause(for: nil) }
                        }
                        .fixedSize()
                    }
                    Spacer()
                    if center.isRefreshing { ProgressView().controlSize(.small) }
                }
                if let error = center.lastConnectorError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.dsSecondary)
                        .foregroundStyle(Color.dsWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusSymbol: String {
        if !settings.persistHistory { return "tray.slash" }
        if !isTypedHistoryOn { return "keyboard" }
        if center.pauseDescription != nil { return "pause.circle" }
        return "checkmark.circle"
    }

    private var statusTint: Color {
        if !settings.persistHistory || center.pauseDescription != nil { return Color.dsWarning }
        if !isTypedHistoryOn { return Color.dsTextSecondary }
        return Color.dsSuccess
    }

    private var statusTitle: String {
        if !settings.persistHistory { return "History is off" }
        if !isTypedHistoryOn { return "Typed history is off" }
        if let pause = center.pauseDescription { return pause }
        if onCount == 0 { return "Typed history is on" }
        return onCount == 1 ? "Typed history is on for 1 place" : "Typed history is on for \(onCount) places"
    }

    private var statusDetail: String {
        if !settings.persistHistory {
            return "Saving to History is off. Turn it on in History & Privacy."
        }
        if !isTypedHistoryOn {
            return "Dictator can keep your dictation. It can also keep messages you send in a few places you choose — like a chat assistant — so you can find those messages in History."
        }
        if settings.isPromptCapturePaused() {
            return "New typing isn’t saved until you resume."
        }
        var text = "What you send in the places switched on below is kept in your History, next to your dictation. Nothing else you type is kept."
        if settings.coreRole != .standalone {
            text += " These choices are shared with your other Macs."
        }
        return text
    }

    // MARK: - Typed but not kept

    private var noticedSection: some View {
        SettingsGroup(title: "Typed but not kept") {
            Text("Places you typed in that Dictator recognises but isn't keeping. Only the place is remembered, never the text.")
                .settingsHelpText()
            ForEach(center.notices.active) { notice in
                HStack(alignment: .top, spacing: DSSpace.s) {
                    Image(systemName: noticeSymbol(notice.kind)).font(.dsIcon)
                        .foregroundStyle(Color.dsWarning)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: DSSpace.hair) {
                        Text(notice.label)
                            .font(.dsBodyMedium)
                            .foregroundStyle(Color.dsTextPrimary)
                        Text(noticeDetail(notice))
                            .font(.dsSecondary)
                            .foregroundStyle(Color.dsTextTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DSSpace.xs)
                    noticeAction(notice)
                    Button {
                        center.notices.dismiss(notice)
                    } label: {
                        Image(systemName: "xmark").font(.dsIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dsTextTertiary)
                    .accessibilityLabel("Don't show this again")
                    .help("Don't show this again")
                }
            }
        }
    }

    private func noticeSymbol(_ kind: NoticedSurfaceStore.Kind) -> String {
        switch kind {
        case .toolOff: "keyboard.badge.ellipsis"
        case .remote: "server.rack"
        case .secureInput: "lock.shield"
        case .needsSetup: "wrench.and.screwdriver"
        }
    }

    private func noticeDetail(_ notice: NoticedSurfaceStore.Notice) -> String {
        let seen = notice.count == 1 ? "Seen once" : "Seen \(notice.count) times"
        let when = notice.lastSeen.formatted(.relative(presentation: .named))
        switch notice.kind {
        case .toolOff:
            return "\(seen), last \(when)."
        case .remote:
            return "\(seen), last \(when). Dictator can keep what you send to coding tools on this server — it adds a small hook there over your own SSH."
        case .secureInput:
            return "While Secure Keyboard Entry is on, Dictator can’t see typing. Coding tools you choose can still save messages when History is on and typed history isn’t paused."
        case .needsSetup:
            return "Choose how Dictator keeps it on this Mac."
        }
    }

    @ViewBuilder
    private func noticeAction(_ notice: NoticedSurfaceStore.Notice) -> some View {
        switch notice.kind {
        case .toolOff:
            if let id = notice.toolID, let tool = catalog.tool(id: id) {
                Button("Keep \(tool.name)") {
                    center.setTool(id, on: true)
                    center.notices.resolve(notice)
                    if center.needsSetup(tool) { setupTool = tool }
                }
            }
        case .needsSetup:
            if let id = notice.toolID, let tool = catalog.tool(id: id) {
                Button("Set Up…") { setupTool = tool }
            }
        case .remote:
            if let host = notice.remoteHost, !host.hasPrefix("container "), !host.hasPrefix("pod "), host != "dev container" {
                Button("Set Up \(host)…") {
                    serverToAdd = host
                    showAddServer = true
                }
            }
        case .secureInput:
            EmptyView()
        }
    }

    // MARK: - Chat & assistants

    private var chatSection: some View {
        let all = catalog.tools.filter { $0.category == .chat && !ToolCatalog.isCustomTool(id: $0.id) }
        let popular: Set<String> = ["chatgpt", "claude", "gemini", "perplexity"]
        let visible = all.filter { center.statuses[$0.id]?.installed == true || popular.contains($0.id) || center.isOn($0.id) }
        return VStack(alignment: .leading, spacing: DSSpace.xs) {
            DSSection(title: "Chat & assistants", subtitle: "What you send to them, in their apps and websites")
            toolList(id: "chat", visible: visible, all: all, noun: "assistant")
        }
    }

    // MARK: - Terminal & coding tools

    private var codingTools: [ToolDefinition] {
        catalog.tools.filter { ($0.category == .agent || $0.category == .editor) && !ToolCatalog.isCustomTool(id: $0.id) }
    }

    /// Open by default only for people who have coding tools here, or use them.
    private var isCodingExpanded: Bool {
        codingExpanded ?? (codingTools.contains { center.statuses[$0.id]?.installed == true || center.isOn($0.id) }
            || !center.remote.hosts.isEmpty)
    }

    private var codingSection: some View {
        let all = codingTools
        let visible = all.filter { center.statuses[$0.id]?.installed == true || center.isOn($0.id) }
        return VStack(alignment: .leading, spacing: DSSpace.xs) {
            Button {
                codingExpanded = !isCodingExpanded
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                    DSSection(title: "Terminal & coding tools", subtitle: "Prompts to coding agents and editor assistants — in any terminal, an editor, tmux, or over SSH")
                    Image(systemName: isCodingExpanded ? "chevron.up" : "chevron.down")
                        .font(.dsIconSmall)
                        .foregroundStyle(Color.dsTextTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isCodingExpanded {
                PromptCaptureSetupBanner()
                toolList(id: "coding", visible: visible, all: all, noun: "tool")
                serversCard
                HStack(spacing: DSSpace.xs) {
                    Spacer()
                    Button("Remove Dictator's Hooks from This Mac…") { confirmRemoveAll = true }
                        .buttonStyle(.dsDestructive)
                }
                .confirmationDialog("Remove every hook Dictator added on this Mac?", isPresented: $confirmRemoveAll) {
                    Button("Remove Hooks", role: .destructive) {
                        Task { await center.removeAllLocalHooks() }
                    }
                } message: {
                    Text("Each tool's settings go back to how they were, minus Dictator. Until you set them up again, Dictator saves them from your keystrokes, which is less exact.")
                }
            }
        }
    }

    private var serversCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                Text("Servers").font(.dsSection)
                Text("Use coding tools on another machine over SSH? Dictator adds a small hook there through your own SSH connection and collects what you send every minute. Nothing is opened on the server and no password is stored.")
                    .settingsHelpText()
                ForEach(center.remote.hosts) { host in
                    ServerRow(host: host)
                    Divider().overlay(Color.dsDivider)
                }
                Button {
                    serverToAdd = ""
                    showAddServer = true
                } label: {
                    Label("Add a Server…", systemImage: "plus")
                }
            }
        }
    }

    // MARK: - Tool list

    private func toolList(id: String, visible: [ToolDefinition], all: [ToolDefinition], noun: String) -> some View {
        let hidden = all.filter { tool in !visible.contains { $0.id == tool.id } }
        let expanded = expandedLists.contains(id)
        return DSCard(padding: 0) {
            VStack(spacing: 0) {
                if visible.isEmpty && !expanded {
                    DSEmptyState(title: "None found on this Mac.")
                }
                ForEach(Array((expanded ? visible + hidden : visible).enumerated()), id: \.element.id) { index, tool in
                    if index > 0 { Divider().overlay(Color.dsDivider) }
                    ToolRow(tool: tool, onSetUp: { setupTool = tool })
                }
                if !hidden.isEmpty {
                    Divider().overlay(Color.dsDivider)
                    Button {
                        if expanded { expandedLists.remove(id) } else { expandedLists.insert(id) }
                    } label: {
                        HStack(spacing: DSSpace.xs) {
                            Text(expanded ? "Show fewer" : "\(hidden.count) more \(hidden.count == 1 ? noun : noun + "s")")
                                .font(.dsSecondaryMedium)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.dsIconSmall)
                            Spacer()
                        }
                        .foregroundStyle(Color.dsAccent)
                        .padding(.horizontal, DSSpace.m)
                        .padding(.vertical, DSSpace.s)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Apps & sites you add

    private var appsSection: some View {
        let custom = catalog.tools.filter { ToolCatalog.isCustomTool(id: $0.id) }
        return VStack(alignment: .leading, spacing: DSSpace.xs) {
            DSSection(title: "Apps & sites you add", subtitle: "Anywhere else you want typing kept — a notes app, a writing site")
            DSCard {
                VStack(alignment: .leading, spacing: DSSpace.s) {
                    ForEach(custom) { tool in
                        ToolRow(tool: tool, onSetUp: { setupTool = tool })
                            .padding(.horizontal, -DSSpace.m)
                        Divider().overlay(Color.dsDivider)
                    }
                    HStack(spacing: DSSpace.xs) {
                        Button("Add an App or Site…") { showAddTool = true }
                        Button("Add an Exception…") { showAddException = true }
                        Spacer()
                    }
                    ForEach(Array(settings.surfacePolicy.rules.enumerated()), id: \.offset) { index, rule in
                        HStack(spacing: DSSpace.xs) {
                            DSBadge(text: SurfacePolicy.norm(rule.action) == "save" ? "Keep" : "Never", tone: SurfacePolicy.norm(rule.action) == "save" ? .success : .warning)
                            Text(ExceptionDescription.describe(rule))
                                .font(.dsSecondary)
                            Spacer()
                            Button {
                                settings.updateSurfacePolicy { $0.rules.remove(at: index) }
                            } label: {
                                Image(systemName: "trash").font(.dsIcon)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.dsAccent)
                            .accessibilityLabel("Remove \(ExceptionDescription.describe(rule))")
                            .help("Remove \(ExceptionDescription.describe(rule))")
                        }
                    }
                    Divider().overlay(Color.dsDivider)
                    HStack(spacing: DSSpace.m) {
                        VStack(alignment: .leading, spacing: DSSpace.hair) {
                            Text("Keep everything I type, everywhere").font(.dsBodyMedium)
                            Text("Not recommended: messages, mail and documents would be kept too.")
                                .settingsHelpText()
                        }
                        Spacer(minLength: 0)
                        Toggle("Keep everything I type, everywhere", isOn: Binding(
                            get: { settings.surfacePolicy.defaultTyped == "save" },
                            set: { on in settings.updateSurfacePolicy { $0.defaultTyped = on ? "save" : "ignore" } }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
        }
    }
}

// MARK: - Tool row

private struct ToolRow: View {
    let tool: ToolDefinition
    let onSetUp: () -> Void
    @State private var center = PromptCaptureCenter.shared
    @State private var settings = AppSettings.shared

    private var status: LocalToolStatus? { center.statuses[tool.id] }
    private var isOn: Bool { center.isOn(tool.id) }

    var body: some View {
        HStack(alignment: .center, spacing: DSSpace.s) {
            Image(systemName: tool.displaySymbol)
                .font(.dsIcon)
                .foregroundStyle(isOn ? Color.dsAccent : Color.dsTextTertiary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                HStack(spacing: DSSpace.xs) {
                    Text(tool.name)
                        .font(.dsBodyMedium)
                        .foregroundStyle(Color.dsTextPrimary)
                    if let badge {
                        DSBadge(text: badge.text, tone: badge.tone)
                    }
                }
                Text(detail)
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DSSpace.xs)
            if isOn, center.needsSetup(tool) {
                Button("Set Up…", action: onSetUp)
                    .controlSize(.small)
            }
            menu
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { on in
                    center.setTool(tool.id, on: on)
                    if on, center.needsSetup(tool) { onSetUp() }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, DSSpace.m)
        .padding(.vertical, DSSpace.s)
    }

    private var badge: (text: String, tone: DSBadge.Tone)? {
        guard isOn else { return nil }
        if center.needsSetup(tool) { return ("Needs setup", .warning) }
        switch status?.method {
        case .hook where status?.hookInstalled == true: return ("Exact", .success)
        case .hook: return ("Hook missing", .warning)
        case .transcript: return ("Exact", .success)
        default:
            if tool.category == .chat || tool.category == .editor { return tool.readsComposer ? ("Exact", .success) : nil }
            if tool.category == .agent { return ("Best effort", .neutral) }
            return nil
        }
    }

    private var detail: String {
        var parts: [String] = []
        if !isOn {
            parts.append("Off")
        } else {
            switch status?.method {
            case .hook:
                parts.append(status?.hookInstalled == true
                    ? "Captured by its hook in ~/\(tool.connector?.hookConfig ?? "")"
                    : "Saving from this tool needs setup on this Mac")
            case .transcript:
                parts.append("Read from ~/\(tool.connector?.transcript?.path ?? "its history file")")
            case .keystrokes:
                parts.append(tool.category == .agent ? "From the keyboard (best effort)" : "From the text box when you send")
            case nil:
                switch tool.category {
                case .agent:
                    parts.append(status?.installed == true ? "Found on this Mac" : "Not on this Mac — kept wherever it's set up")
                case .chat:
                    var where_: [String] = []
                    if !tool.signatures.bundleIDs.isEmpty, status?.installed == true { where_.append("its app") }
                    if !tool.signatures.domains.isEmpty { where_.append(tool.signatures.domains.first!) }
                    parts.append(where_.isEmpty ? "From the text box when you send" : "From " + where_.joined(separator: " and "))
                case .editor:
                    parts.append(status?.installed == true ? "Its chat panel (never the code you type)" : "Not on this Mac")
                }
            }
        }
        if let last = center.recorder.lastCaptureByTool[tool.id] {
            var text = "last saved \(last.formatted(.relative(presentation: .named)))"
            if let surface = center.recorder.lastSurfaceByTool[tool.id], surface != tool.name {
                text += " from \(surface.replacingOccurrences(of: " → \(tool.name)", with: ""))"
            }
            parts.append(text)
        }
        if let note = tool.connector?.note, isOn { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var menu: some View {
        let methods = center.availableMethods(for: tool)
        let voiceOff = settings.surfacePolicy.tools?[tool.id]?.voice == false
        Menu {
            if tool.connector != nil, status?.installed == true {
                Section("Capture on this Mac") {
                    ForEach(methods, id: \.self) { method in
                        Button {
                            Task { await center.setMethod(method, for: tool) }
                        } label: {
                            if status?.method == method {
                                Label(method.title, systemImage: "checkmark")
                            } else {
                                Text(method.title)
                            }
                        }
                    }
                }
                if status?.hookInstalled == true {
                    Button("Remove Hook") { Task { await center.removeConnector(tool) } }
                }
            }
            Button(voiceOff ? "Save Dictation into \(tool.name)" : "Don't Save Dictation into \(tool.name)") {
                settings.updateSurfacePolicy { policy in
                    var all = policy.tools ?? [:]
                    var entry = all[tool.id] ?? ToolSwitch(typed: policy.isToolOn(tool.id))
                    entry.voice = voiceOff ? nil : false
                    all[tool.id] = entry
                    policy.tools = all
                }
            }
            if ToolCatalog.isCustomTool(id: tool.id) {
                Divider()
                Button("Remove This Tool", role: .destructive) {
                    center.removeCustomTool(tool)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.dsIcon)
                .foregroundStyle(Color.dsTextTertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Options for \(tool.name)")
        .help("Options for \(tool.name)")
    }
}

// MARK: - Server row

private struct ServerRow: View {
    let host: RemoteCaptureService.Host
    @State private var center = PromptCaptureCenter.shared

    var body: some View {
        HStack(alignment: .top, spacing: DSSpace.s) {
            Image(systemName: "server.rack").font(.dsIcon)
                .foregroundStyle(host.lastError == nil ? Color.dsAccent : Color.dsWarning)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                Text(host.alias)
                    .font(.dsBodyMedium)
                Text(detail)
                    .font(.dsSecondary)
                    .foregroundStyle(host.lastError == nil ? Color.dsTextTertiary : Color.dsWarning)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = center.remote.progress[host.alias] {
                    Text(progress).font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                }
            }
            Spacer()
            if center.remote.busy.contains(host.alias) {
                ProgressView().controlSize(.small)
            } else {
                Button("Collect Now") { Task { await center.remote.pull(host.alias) } }
                    .controlSize(.small)
                Menu {
                    Button("Update Hooks") {
                        Task { try? await center.remote.enable(host.alias, toolIDs: host.installedToolIDs) }
                    }
                    Button("Remove from Server", role: .destructive) {
                        Task { try? await center.remote.disable(host.alias) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.dsIcon)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Options for \(host.alias)")
                .help("Options for \(host.alias)")
            }
        }
    }

    private var detail: String {
        if let error = host.lastError { return error }
        let names = host.installedToolIDs.compactMap { ToolCatalog.shared.tool(id: $0)?.name }
        var text = names.isEmpty ? "No tools set up" : names.joined(separator: ", ")
        if let last = host.lastPull {
            text += " · collected \(last.formatted(.relative(presentation: .named)))"
        }
        if host.lastPromptCount > 0 { text += " · \(host.lastPromptCount) prompts so far" }
        return text
    }
}

// MARK: - Exception descriptions

enum ExceptionDescription {
    static func describe(_ rule: SurfaceRule) -> String {
        let what = target(kind: rule.kind, pattern: rule.pattern)
        switch SurfacePolicy.norm(rule.modality) {
        case "typed": return "\(what) — typing"
        case "voice": return "\(what) — dictation"
        default: return what
        }
    }

    /// What a rule applies to, in plain words.
    static func target(kind: String, pattern: String, catalog: ToolCatalog = .shared) -> String {
        switch SurfacePolicy.norm(kind) {
        case "tool": return catalog.tool(id: pattern)?.name ?? pattern
        case "remote": return "servers matching \(pattern)"
        case "any": return "everything"
        case "app":
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pattern) {
                return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            }
            return DatasetDestinationResolver.displayName(appName: nil, bundle: pattern)
        default: return pattern
        }
    }
}

// Shared by Home, Datasets and Typed History. Reading status never edits a
// tool's files; this button is the local user's consent to run setup.
struct PromptCaptureSetupBanner: View {
    @State private var center = PromptCaptureCenter.shared
    @State private var settings = AppSettings.shared

    var body: some View {
        let pending = center.toolsNeedingSetup
        if settings.persistHistory, !pending.isEmpty {
            DSCard {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    HStack(spacing: DSSpace.s) {
                        Image(systemName: "wrench.and.screwdriver").font(.dsIcon)
                            .foregroundStyle(Color.dsWarning)
                        VStack(alignment: .leading, spacing: DSSpace.hair) {
                            Text(message(pending))
                                .font(.dsBodyMedium)
                            Text(setupMessage(pending))
                                .font(.dsSecondary)
                                .foregroundStyle(Color.dsTextSecondary)
                        }
                        Spacer(minLength: DSSpace.xs)
                        Button("Set up") { Task { await center.setUpAll() } }
                            .buttonStyle(.dsPrimary)
                            .disabled(center.isSettingUp)
                        if center.isSettingUp { ProgressView().controlSize(.small) }
                    }
                    ForEach(center.setupResults.filter { result in
                        !result.succeeded && pending.contains { $0.id == result.toolID }
                    }) { result in
                        Text("Couldn’t set up \(result.toolName). \(result.error ?? "Try again.")")
                            .font(.dsSecondary)
                            .foregroundStyle(Color.dsWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.bottom, DSSpace.s)
            .task { await center.refreshStatuses() }
        }
    }

    private func message(_ tools: [ToolDefinition]) -> String {
        let names = summarized(tools.map(\.name))
        let mac = Host.current().localizedName ?? "this Mac"
        return "\(names) \(tools.count == 1 ? "isn’t" : "aren’t") being saved reliably on \(mac)."
    }

    private func setupMessage(_ tools: [ToolDefinition]) -> String {
        var files: [String] = []
        for tool in tools where center.recommendedMethod(for: tool) == .hook {
            if let path = tool.connector?.hookConfig { files.append("~/" + path) }
            if tool.connector?.hookFormat == "codex-hooks" { files.append("~/.codex/config.toml") }
        }
        var uniqueFiles: [String] = []
        for file in files where !uniqueFiles.contains(file) { uniqueFiles.append(file) }
        guard !uniqueFiles.isEmpty else { return "Set up saving on this Mac." }
        return "Set up adds a small hook to \(summarized(uniqueFiles)). A backup of each file is kept."
    }

    private func summarized(_ items: [String]) -> String {
        var visible = Array(items.prefix(3))
        if items.count > 3 { visible.append("\(items.count - 3) more") }
        return visible.formatted(.list(type: .and))
    }
}
