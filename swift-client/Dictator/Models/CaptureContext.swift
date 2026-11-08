import Foundation

/// Where a prompt was typed or spoken, as far as Dictator could tell.
///
/// The *tool* (`toolID`) is what users switch on and off; everything else is
/// the surface — which app it was typed in, which part of that app, which
/// machine it ultimately ran on — and is recorded so an entry can explain
/// itself and so rare per-surface overrides can match.
struct CaptureContext: Codable, Equatable, Hashable, Sendable {
    enum SubSurface: String, Codable, Sendable {
        /// A terminal session (standalone terminal or an editor's panel).
        case terminal
        /// An editor's code area — never a prompt surface by default.
        case codeEditor = "code-editor"
        /// An editor's chat / agent panel.
        case chatPanel = "chat-panel"
        /// A web page in a browser.
        case web
        /// A desktop app's own window (chat composer).
        case app
    }

    /// Catalog tool id (`claude-code`, `chatgpt`), nil when unknown.
    var toolID: String?
    /// The frontmost app the keys went to (`com.googlecode.iterm2`), or nil
    /// for connector captures that never involved a local app.
    var appBundleID: String?
    var appName: String?
    /// Web host for browser surfaces.
    var webHost: String?
    var url: String?
    var subSurface: SubSurface?
    /// `ssh` / `mosh` / container destination when the tool runs elsewhere.
    var remoteHost: String?
    /// Machine the tool itself ran on (connector captures).
    var toolMachine: String?
    var workingDirectory: String?
    /// Local tty the keys went to (terminal surfaces).
    var tty: String?

    init(
        toolID: String? = nil,
        appBundleID: String? = nil,
        appName: String? = nil,
        webHost: String? = nil,
        url: String? = nil,
        subSurface: SubSurface? = nil,
        remoteHost: String? = nil,
        toolMachine: String? = nil,
        workingDirectory: String? = nil,
        tty: String? = nil
    ) {
        self.toolID = toolID
        self.appBundleID = appBundleID
        self.appName = appName
        self.webHost = webHost
        self.url = url
        self.subSurface = subSurface
        self.remoteHost = remoteHost
        self.toolMachine = toolMachine
        self.workingDirectory = workingDirectory
        self.tty = tty
    }

    /// A human description: "iTerm → ssh build-server → Claude Code".
    func label(catalog: ToolCatalog = .shared) -> String {
        var parts: [String] = []
        if let appName, !appName.isEmpty {
            var app = appName
            if let subSurface, subSurface == .terminal, catalog.hostApp(bundleID: appBundleID)?.kind == .editor {
                app += " terminal"
            } else if subSurface == .codeEditor {
                app += " editor"
            } else if subSurface == .chatPanel {
                app += " chat panel"
            }
            parts.append(app)
        }
        if let webHost { parts.append(webHost) }
        if let remoteHost { parts.append("ssh \(remoteHost)") }
        if let toolMachine, remoteHost == nil, appName == nil { parts.append(toolMachine) }
        if let toolID, let tool = catalog.tool(id: toolID), !parts.contains(tool.name) {
            parts.append(tool.name)
        }
        return parts.isEmpty ? "Unknown app" : parts.joined(separator: " → ")
    }

    /// Stable identity for "Noticed, not saved" — the surface, never the text.
    var noticeKey: String {
        [toolID ?? "-", appBundleID ?? "-", webHost ?? "-", subSurface?.rawValue ?? "-", remoteHost ?? "-"]
            .joined(separator: "|")
    }
}

/// How a prompt reached Dictator. Ordered by fidelity: a connector sees the
/// exact submitted text; keystroke reconstruction is best effort.
enum CaptureSource: String, Codable, Sendable, CaseIterable {
    /// The tool's own prompt-submit hook (`dictator-capture hook …`).
    case hook
    /// The tool's own history / transcript files.
    case transcript
    /// The focused composer's text, read through Accessibility on submit.
    case composer
    /// Rebuilt from keystrokes.
    case keystrokes
    /// Spoken (dictation).
    case voice
    /// Spoken through Dictator's Dictate action in the Shortcuts app.
    case shortcuts

    var fidelity: Int {
        switch self {
        case .hook: 4
        case .transcript: 3
        case .composer: 2
        case .keystrokes: 1
        case .voice: 4
        case .shortcuts: 4
        }
    }

    var isExact: Bool { self != .keystrokes }

    var title: String {
        switch self {
        case .hook: "Exact (sent by the tool’s hook)"
        case .transcript: "Exact (read from the tool’s history)"
        case .composer: "Exact (text box)"
        case .keystrokes: "Best effort (keystrokes)"
        case .voice: "Dictation"
        case .shortcuts: "Dictation (from Shortcuts)"
        }
    }
}
