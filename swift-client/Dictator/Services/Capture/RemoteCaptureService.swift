import Foundation
import Observation

/// Captures prompts from AI tools that run on other machines — Linux
/// servers, cloud boxes, a Mac without Dictator — that the user reaches over
/// SSH. Enabling a host installs `dictator-capture` and the tools' hooks
/// there (over the user's own SSH, shown step by step); Dictator then
/// collects the spooled prompts on a timer. Nothing listens on the server,
/// no port is opened, no credential is stored.
@MainActor
@Observable
final class RemoteCaptureService {
    struct Host: Codable, Identifiable, Equatable, Sendable {
        var id: String { alias }
        var alias: String
        var enabled: Bool
        var home: String?
        /// Tools whose hooks Dictator installed there.
        var installedToolIDs: [String]
        /// Tools found there at the last check.
        var detectedToolIDs: [String]
        var shimVersion: String?
        var lastPull: Date?
        var lastError: String?
        var lastPromptCount: Int
    }

    struct Probe: Equatable, Sendable {
        var home: String
        var detectedToolIDs: [String]
        var shimVersion: String?
        var system: String
    }

    private(set) var hosts: [Host] = []
    /// Hosts from `~/.ssh/config`, for the "Add a server" picker.
    private(set) var configuredAliases: [String] = []
    private(set) var busy: Set<String> = []
    private(set) var progress: [String: String] = [:]

    @ObservationIgnored private let runner: SSHRunner
    @ObservationIgnored private let onPrompt: LocalSpoolWatcher.Handler
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var backoffUntil: [String: Date] = [:]
    static let pullInterval: TimeInterval = 60
    private static let defaultsKey = "remoteCaptureHosts"

    init(runner: SSHRunner = SSHRunner(), onPrompt: @escaping LocalSpoolWatcher.Handler) {
        self.runner = runner
        self.onPrompt = onPrompt
        load()
        configuredAliases = Self.sshConfigAliases()
    }

    func start() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.pullAll()
                try? await Task.sleep(for: .seconds(Self.pullInterval))
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    func host(_ alias: String) -> Host? {
        hosts.first { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }
    }

    /// Whether prompts typed into an SSH session to `remote` are already
    /// captured exactly by this host's hooks.
    func isCapturing(remote: String?) -> Bool {
        guard let remote, let host = host(remote) else { return false }
        return host.enabled && !host.installedToolIDs.isEmpty
    }

    func refreshConfiguredAliases() {
        configuredAliases = Self.sshConfigAliases()
    }

    // MARK: - Setup

    /// Connects, reports what's there, changes nothing.
    func probe(_ alias: String) async throws -> Probe {
        let catalog = ToolCatalog.shared
        var checks: [String] = []
        for tool in catalog.tools where tool.connector?.supportsHook == true {
            var tests = tool.signatures.configDirs.map { "[ -e \"$HOME\"/\(SSHRunner.quote($0)) ]" }
            tests += tool.signatures.processNames.map { "command -v \(SSHRunner.quote($0)) >/dev/null 2>&1" }
            guard !tests.isEmpty else { continue }
            checks.append("if \(tests.joined(separator: " || ")); then echo \(SSHRunner.quote("tool=" + tool.id)); fi")
        }
        let script = """
        PATH="$PATH:$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin"
        echo "home=$HOME"
        echo "system=$(uname -sm 2>/dev/null)"
        v=$("$HOME/\(ConnectorInstaller.shimRelativePath)" version 2>/dev/null) && echo "shim=$v"
        \(checks.joined(separator: "\n"))
        """
        setProgress(alias, "Connecting…")
        defer { setProgress(alias, nil) }
        let output = try await runner.run(host: alias, script: script)
        return Self.parseProbe(output.stdout)
    }

    nonisolated static func parseProbe(_ stdout: String) -> Probe {
        var probe = Probe(home: "", detectedToolIDs: [], shimVersion: nil, system: "")
        for line in stdout.split(separator: "\n").map(String.init) {
            if line.hasPrefix("home=") { probe.home = String(line.dropFirst(5)) }
            if line.hasPrefix("system=") { probe.system = String(line.dropFirst(7)) }
            if line.hasPrefix("shim=") { probe.shimVersion = String(line.dropFirst(5)) }
            if line.hasPrefix("tool=") { probe.detectedToolIDs.append(String(line.dropFirst(5))) }
        }
        return probe
    }

    /// Installs the shim and the chosen tools' hooks on `alias`.
    func enable(_ alias: String, toolIDs: [String]) async throws {
        guard !busy.contains(alias) else { return }
        busy.insert(alias)
        defer { busy.remove(alias); setProgress(alias, nil) }

        let probe = try await probe(alias)
        guard !probe.home.isEmpty else { throw SSHRunner.Failure.other("The server didn't report a home directory.") }
        let access = RemoteConfigFileAccess(host: alias, homeDirectory: probe.home, runner: runner)
        setProgress(alias, "Installing the capture helper…")
        try await ConnectorInstaller.installShim(on: access, script: try ConnectorInstaller.bundledShim())

        var installed: [String] = host(alias)?.installedToolIDs ?? []
        var failures: [String] = []
        for id in toolIDs {
            guard let tool = ToolCatalog.shared.tool(id: id) else { continue }
            setProgress(alias, "Adding the \(tool.name) hook…")
            do {
                try await ConnectorInstaller.install(tool, on: access)
                if !installed.contains(id) { installed.append(id) }
            } catch {
                failures.append("\(tool.name): \(error.localizedDescription)")
            }
        }
        upsert(Host(
            alias: alias,
            enabled: true,
            home: probe.home,
            installedToolIDs: installed,
            detectedToolIDs: probe.detectedToolIDs,
            shimVersion: ConnectorInstaller.bundledShimVersion(),
            lastPull: host(alias)?.lastPull,
            lastError: failures.isEmpty ? nil : failures.joined(separator: "\n"),
            lastPromptCount: host(alias)?.lastPromptCount ?? 0
        ))
        await pull(alias)
    }

    /// Collects what's left, removes the hooks and the shim.
    func disable(_ alias: String) async throws {
        guard let existing = host(alias), !busy.contains(alias) else { return }
        busy.insert(alias)
        defer { busy.remove(alias); setProgress(alias, nil) }
        await pullNow(existing)
        if let home = existing.home {
            let access = RemoteConfigFileAccess(host: alias, homeDirectory: home, runner: runner)
            for id in existing.installedToolIDs {
                guard let tool = ToolCatalog.shared.tool(id: id) else { continue }
                setProgress(alias, "Removing the \(tool.name) hook…")
                try await ConnectorInstaller.uninstall(tool, on: access)
            }
            try await access.delete(ConnectorInstaller.shimRelativePath)
        }
        hosts.removeAll { $0.alias == alias }
        save()
    }

    // MARK: - Collecting

    func pullAll() async {
        for host in hosts where host.enabled {
            if let until = backoffUntil[host.alias], until > Date() { continue }
            await pull(host.alias)
        }
    }

    func pull(_ alias: String) async {
        guard let host = host(alias) else { return }
        await pullNow(host)
    }

    private func pullNow(_ host: Host) async {
        let shim = "\"$HOME\"/\(SSHRunner.quote(ConnectorInstaller.shimRelativePath))"
        do {
            let output = try await runner.run(host: host.alias, script: "[ -x \(shim) ] && \(shim) drain", timeout: 60)
            var ids: [String] = []
            var count = 0
            for line in output.stdout.split(separator: "\n") {
                guard let space = line.firstIndex(of: " ") else { continue }
                let id = String(line[..<space])
                guard id.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" }) else { continue }
                let json = Data(line[line.index(after: space)...].utf8)
                var handled = true
                if let prompt = ConnectorParsers.parseSpoolRecord(json, id: "\(host.alias):\(id)", remoteHost: host.alias, catalog: .shared) {
                    handled = await onPrompt(prompt)
                    if handled { count += 1 }
                }
                // Acknowledge (delete on the server) only what's stored or
                // deliberately skipped; a failed save is collected again.
                if handled { ids.append(id) }
            }
            for chunk in stride(from: 0, to: ids.count, by: 200) {
                let batch = ids[chunk..<min(chunk + 200, ids.count)].joined(separator: " ")
                _ = try await runner.run(host: host.alias, script: "\(shim) ack \(batch)")
            }
            update(host.alias) {
                $0.lastPull = Date()
                $0.lastError = nil
                $0.lastPromptCount += count
            }
            backoffUntil[host.alias] = nil
        } catch {
            update(host.alias) { $0.lastError = error.localizedDescription }
            backoffUntil[host.alias] = Date().addingTimeInterval(300)
        }
    }

    // MARK: - SSH config

    /// Concrete `Host` aliases from `~/.ssh/config` (and its `Include`s,
    /// one level): patterns with wildcards or negations are skipped.
    nonisolated static func sshConfigAliases(home: String = NSHomeDirectory()) -> [String] {
        let base = URL(fileURLWithPath: home).appendingPathComponent(".ssh")
        var files = [base.appendingPathComponent("config")]
        var aliases: [String] = []
        var index = 0
        while index < files.count, index < 20 {
            let file = files[index]
            index += 1
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                let lower = line.lowercased()
                if lower.hasPrefix("include ") {
                    for pattern in line.dropFirst(8).split(separator: " ") {
                        var path = String(pattern)
                        if path.hasPrefix("~/") { path = home + "/" + path.dropFirst(2) }
                        else if !path.hasPrefix("/") { path = base.appendingPathComponent(path).path }
                        files.append(contentsOf: expandGlob(path))
                    }
                } else if lower.hasPrefix("host ") || lower.hasPrefix("host\t") {
                    for name in line.dropFirst(5).split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                        let alias = String(name)
                        guard !alias.contains("*"), !alias.contains("?"), !alias.hasPrefix("!") else { continue }
                        if !aliases.contains(alias) { aliases.append(alias) }
                    }
                }
            }
        }
        return aliases
    }

    nonisolated private static func expandGlob(_ pattern: String) -> [URL] {
        guard pattern.contains("*") || pattern.contains("?") else { return [URL(fileURLWithPath: pattern)] }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { i in
            result.gl_pathv[i].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }

    // MARK: - Persistence

    private func upsert(_ host: Host) {
        if let index = hosts.firstIndex(where: { $0.alias == host.alias }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        save()
    }

    private func update(_ alias: String, _ change: (inout Host) -> Void) {
        guard let index = hosts.firstIndex(where: { $0.alias == alias }) else { return }
        change(&hosts[index])
        save()
    }

    private func setProgress(_ alias: String, _ message: String?) {
        progress[alias] = message
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([Host].self, from: data) else { return }
        hosts = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
