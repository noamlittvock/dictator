import Foundation

/// Reads a terminal's foreground job — the argv of each process in it — and
/// says what the user is talking to: an AI tool, a remote machine (and the
/// tool on it, when the command line names one), a multiplexer to look
/// through, or just a shell. Pure, so every rule here is unit-tested.
enum CommandLineClassifier {
    struct Process: Equatable {
        var executable: String
        var argv: [String]

        var name: String {
            let base = URL(fileURLWithPath: argv.first ?? executable).lastPathComponent
            return base.hasPrefix("-") ? String(base.dropFirst()) : base
        }
    }

    enum Multiplexer: Equatable {
        /// tmux client; `socketArgs` are its `-L name` / `-S path` options,
        /// needed to ask the right server which pane it shows.
        case tmux(executable: String, socketArgs: [String])
        case screen
    }

    struct Result: Equatable {
        var toolID: String?
        var remoteHost: String?
        /// The program the user is talking to (`claude`, `ssh`, `vim`).
        var program: String?
        /// Nothing but a shell in the foreground: typing is shell commands.
        var isShell = false
        var multiplexer: Multiplexer?
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login"]

    static func classify(_ job: [Process], catalog: ToolCatalog) -> Result {
        var result = Result()
        // Deepest process last: it is what actually owns the keyboard.
        for process in job.reversed() {
            let name = process.name.lowercased()

            if let remote = remoteDestination(process, catalog: catalog) {
                result.remoteHost = remote.host
                result.toolID = remote.toolID
                result.program = name
                return result
            }
            if name == "tmux" {
                result.multiplexer = .tmux(executable: process.executable, socketArgs: tmuxSocketArgs(process.argv))
                result.program = "tmux"
                return result
            }
            if name == "screen" {
                result.multiplexer = .screen
                result.program = "screen"
                return result
            }
            if let tool = catalog.tool(forProcess: process.executable, arguments: process.argv) {
                result.toolID = tool.id
                result.program = name
                return result
            }
        }
        if let leaf = job.last {
            let name = leaf.name.lowercased()
            result.program = name
            result.isShell = shells.contains(name)
        } else {
            result.isShell = true
        }
        return result
    }

    // MARK: - Remote sessions

    struct Remote: Equatable {
        var host: String
        var toolID: String?
    }

    /// `ssh`, `mosh`, `et`, `autossh`, `kitten ssh`, `docker exec`, `kubectl
    /// exec`… → where the keys really go, and the tool when the remote
    /// command line names one (`ssh box claude`).
    static func remoteDestination(_ process: Process, catalog: ToolCatalog) -> Remote? {
        let name = process.name.lowercased()
        let args = Array(process.argv.dropFirst())
        switch name {
        case "ssh", "autossh":
            return parseSSH(args, catalog: catalog)
        case "mosh":
            // mosh [options] [--] host [command...]
            let words = args.filter { !$0.hasPrefix("-") }
            guard let host = words.first else { return nil }
            return Remote(host: stripUser(host), toolID: catalog.tool(forCommandWords: Array(words.dropFirst()))?.id)
        case "mosh-client":
            return nil // the `mosh` wrapper above it names the host
        case "et":
            let words = args.filter { !$0.hasPrefix("-") }
            guard let host = words.first else { return nil }
            return Remote(host: stripUser(host.split(separator: ":").first.map(String.init) ?? host), toolID: nil)
        case "kitten", "kitty":
            guard args.first == "ssh" else { return nil }
            return parseSSH(Array(args.dropFirst()), catalog: catalog)
        case "docker", "podman", "nerdctl":
            guard let verb = args.first, verb == "exec" || verb == "run" || verb == "attach" else { return nil }
            let words = args.dropFirst().filter { !$0.hasPrefix("-") }
            guard let target = words.first else { return nil }
            return Remote(host: "container \(target)", toolID: catalog.tool(forCommandWords: Array(words.dropFirst()))?.id)
        case "kubectl", "oc":
            guard args.first == "exec" else { return nil }
            let words = args.dropFirst().filter { !$0.hasPrefix("-") }
            guard let pod = words.first else { return nil }
            let command = args.firstIndex(of: "--").map { Array(args[($0 + 1)...]) } ?? []
            return Remote(host: "pod \(pod)", toolID: catalog.tool(forCommandWords: command)?.id)
        case "devcontainer":
            guard args.first == "exec" else { return nil }
            return Remote(host: "dev container", toolID: catalog.tool(forCommandWords: args.dropFirst().filter { !$0.hasPrefix("-") })?.id)
        default:
            return nil
        }
    }

    /// OpenSSH options that take a value (`-p 22`, `-i key`).
    private static let sshOptionsWithValue: Set<Character> = ["B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m", "O", "o", "P", "p", "Q", "R", "S", "W", "w"]

    static func parseSSH(_ args: [String], catalog: ToolCatalog) -> Remote? {
        var index = 0
        var loginName: String?
        var host: String?
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                index += 1
                break
            }
            if arg.hasPrefix("-"), arg.count >= 2 {
                // Flags may be bundled (`-tt`, `-4vp22`): the first flag that
                // takes a value consumes the rest of the word or the next arg.
                let flags = Array(arg.dropFirst())
                var consumedNext = false
                for (offset, flag) in flags.enumerated() where sshOptionsWithValue.contains(flag) {
                    let rest = String(flags[(offset + 1)...])
                    let value = rest.isEmpty ? (index + 1 < args.count ? args[index + 1] : nil) : rest
                    if flag == "l" { loginName = value }
                    if flag == "o", let value, value.lowercased().hasPrefix("hostname=") {
                        // Keep the alias the user typed; it's more meaningful.
                    }
                    consumedNext = rest.isEmpty
                    break
                }
                index += consumedNext ? 2 : 1
                continue
            }
            host = arg
            index += 1
            break
        }
        guard let destination = host else { return nil }
        _ = loginName
        let command = Array(args[min(index, args.count)...])
        return Remote(host: stripUser(destination), toolID: catalog.tool(forCommandWords: command)?.id)
    }

    static func stripUser(_ destination: String) -> String {
        var host = destination
        if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            return String(host[host.index(after: host.startIndex)..<close])
        }
        if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon]) // ssh://host:port
        }
        return host
    }

    static func tmuxSocketArgs(_ argv: [String]) -> [String] {
        var result: [String] = []
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if (arg == "-L" || arg == "-S"), index + 1 < argv.count {
                result += [arg, argv[index + 1]]
                index += 2
                continue
            }
            if arg.hasPrefix("-L") || arg.hasPrefix("-S"), arg.count > 2 {
                result += [String(arg.prefix(2)), String(arg.dropFirst(2))]
            }
            index += 1
        }
        return result
    }

    // MARK: - Editors

    /// What part of an editor has keyboard focus, judged from the focused
    /// element's Accessibility ancestry. `classes` is every ancestor's
    /// `AXDOMClassList` (VS Code and its forks are Chromium: the DOM shows
    /// through), `descriptions` their roles/descriptions/titles.
    static func editorSubSurface(classes: [String], descriptions: [String]) -> CaptureContext.SubSurface? {
        let lowerClasses = classes.map { $0.lowercased() }
        let lowerDescriptions = descriptions.map { $0.lowercased() }

        if lowerClasses.contains(where: { $0.contains("xterm") || $0 == "terminal-wrapper" || $0.contains("integrated-terminal") })
            || lowerDescriptions.contains(where: { $0.hasPrefix("terminal") || $0.contains(" terminal") }) {
            return .terminal
        }
        let chatMarkers = ["interactive-session", "interactive-input", "chat-widget", "chat-input", "chat-editor",
                           "aichat", "composer-bar", "composer", "cascade", "agent-panel", "inline-chat", "copilot-chat",
                           "chat-view", "chatview", "ai-chat"]
        let editorMarkers = ["monaco-editor", "editor-instance", "editor-group-container", "native-edit-context", "inputarea"]
        // Chat panels embed Monaco too, so the chat markers win over the
        // editor ones; DOM classes are more trustworthy than descriptions.
        if lowerClasses.contains(where: { cls in chatMarkers.contains { cls.contains($0) } }) {
            return .chatPanel
        }
        if lowerClasses.contains(where: { cls in editorMarkers.contains { cls.contains($0) } }) {
            return .codeEditor
        }
        if lowerDescriptions.contains(where: { $0.contains("chat input") || $0.contains("chat message") || $0.contains("ask anything") || $0.contains("prompt") }) {
            return .chatPanel
        }
        if lowerDescriptions.contains(where: { $0.contains("editor content") }) {
            return .codeEditor
        }
        return nil
    }
}
