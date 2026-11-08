import Foundation
import os

/// Runs a POSIX `sh` script on another machine through the user's own SSH
/// setup (`~/.ssh/config`, keys, agent). The script travels on stdin to
/// `sh -s`, so it works whatever the remote login shell is (bash, zsh,
/// fish…). Never prompts: `BatchMode` makes a missing key fail fast with a
/// message the UI can explain.
struct SSHRunner: Sendable {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    enum Failure: LocalizedError, Equatable {
        case invalidHost
        case authentication
        case hostKey
        case unknownHost
        case timeout
        case other(String)

        var errorDescription: String? {
            switch self {
            case .invalidHost:
                "That isn't a valid SSH host name."
            case .authentication:
                "Dictator couldn't sign in without a password. Add an SSH key for this server (ssh-copy-id), or load it into your SSH agent, then try again."
            case .hostKey:
                "This server's key isn't trusted yet. Connect once with ssh in a terminal to confirm it, then try again."
            case .unknownHost:
                "Dictator can't find this host. Check the name, or add it to ~/.ssh/config."
            case .timeout:
                "The server didn't answer in time."
            case .other(let message):
                message
            }
        }
    }

    var executable = "/usr/bin/ssh"
    var connectTimeout = 10

    static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.count < 256
            && host.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
    }

    /// Writing a script to an ssh that already exited (bad host, dead
    /// ControlMaster) would raise SIGPIPE and kill the app.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    func run(host: String, script: String, timeout: TimeInterval = 45) async throws -> Output {
        guard Self.isValidHost(host) else { throw Failure.invalidHost }
        _ = Self.ignoreSIGPIPE
        let controlPath = "/tmp/dictator-ssh-\(getuid())-%C"
        let arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=120",
            "--", host, "sh -s",
        ]
        let output = try await Self.launch(executable: executable, arguments: arguments, stdin: script, timeout: timeout)
        if output.status == 255 {
            throw Self.classify(output.stderr)
        }
        return output
    }

    static func classify(_ stderr: String) -> Failure {
        let text = stderr.lowercased()
        if text.contains("permission denied") || text.contains("too many authentication failures") { return .authentication }
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") { return .hostKey }
        if text.contains("could not resolve hostname") || text.contains("name or service not known") || text.contains("nodename nor servname") { return .unknownHost }
        if text.contains("timed out") || text.contains("connection refused") || text.contains("no route to host") { return .timeout }
        let line = stderr.split(separator: "\n").last.map(String.init) ?? "SSH failed."
        return .other(line.trimmingCharacters(in: .whitespaces))
    }

    static let killGrace: TimeInterval = 2

    static func launch(executable: String, arguments: [String], stdin: String, timeout: TimeInterval) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let input = Pipe()
                let output = Pipe()
                let errors = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure.other("Couldn't start ssh: \(error.localizedDescription)"))
                    return
                }
                // A process can catch SIGTERM and exit 0, or ignore it. Either
                // way the output is partial, so the deadline itself decides.
                let timedOut = OSAllocatedUnfairLock(initialState: false)
                let timer = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.withLock { $0 = true }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                // Write stdin and drain both pipes concurrently so a large
                // script or output never deadlocks on a full pipe buffer.
                let group = DispatchGroup()
                var stdoutData = Data()
                var stderrData = Data()
                group.enter()
                DispatchQueue.global().async {
                    stdoutData = output.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    stderrData = errors.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
                group.wait()
                process.waitUntilExit()
                timer.cancel()
                if timedOut.withLock({ $0 }) || process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: Failure.timeout)
                    return
                }
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self)
                ))
            }
        }
    }

    // MARK: - Script helpers

    /// Single-quoted for POSIX sh (the remote side always runs `sh -s`).
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A heredoc delimiter that cannot occur in `content`.
    static func delimiter(for content: String) -> String {
        var candidate = "DICTATOR_EOF_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        while content.contains(candidate) { candidate += "X" }
        return candidate
    }
}

/// `ConfigFileAccess` on a server, one SSH round trip per operation.
struct RemoteConfigFileAccess: ConfigFileAccess {
    let host: String
    let homeDirectory: String
    var runner = SSHRunner()

    private func path(_ relative: String) -> String {
        "\"$HOME\"/" + SSHRunner.quote(relative)
    }

    /// Rc files can print banners before our output, so results are framed
    /// by a per-call random marker rather than trusted from byte 0; if the
    /// marker never appears, that's an error — never "file missing", which
    /// would lead to overwriting a real config.
    func read(_ relativePath: String) async throws -> String? {
        let marker = "__DICTATOR_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let script = """
        f=\(path(relativePath))
        if [ -f "$f" ]; then printf '%s\\n' '\(marker)_FOUND'; cat "$f"; printf '\\n%s\\n' '\(marker)_END'; else printf '%s\\n' '\(marker)_MISSING'; fi
        """
        let output = try await runner.run(host: host, script: script)
        let text = output.stdout
        if text.contains("\(marker)_MISSING") { return nil }
        guard let start = text.range(of: "\(marker)_FOUND\n"),
              let end = text.range(of: "\n\(marker)_END", options: .backwards),
              start.upperBound <= end.lowerBound else {
            throw SSHRunner.Failure.other("Couldn't read ~/\(relativePath) on \(host) (\(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))). Nothing was changed.")
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    func write(_ relativePath: String, contents: String, backup: Bool, executable: Bool) async throws {
        let body = contents.hasSuffix("\n") ? contents : contents + "\n"
        let delimiter = SSHRunner.delimiter(for: body)
        let script = """
        set -e
        umask 077
        f=\(path(relativePath))
        # Write through a symlink (dotfiles managers) rather than replace it.
        if [ -L "$f" ]; then t=$(readlink -f "$f" 2>/dev/null) && [ -n "$t" ] && f="$t"; fi
        mkdir -p "$(dirname "$f")"
        if [ -f "$f" ]; then
          \(backup ? "cp -p \"$f\" \"$f.dictator-backup\"" : ":")
          cp -p "$f" "$f.dictator-tmp"
        fi
        cat > "$f.dictator-tmp" <<'\(delimiter)'
        \(body)\(delimiter)
        \(executable ? "chmod 700 \"$f.dictator-tmp\"" : ":")
        mv -f "$f.dictator-tmp" "$f"
        echo OK
        """
        let output = try await runner.run(host: host, script: script)
        guard output.stdout.split(separator: "\n").last == "OK" else {
            throw SSHRunner.Failure.other("Couldn't write ~/\(relativePath) on \(host): \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    func delete(_ relativePath: String) async throws {
        _ = try await runner.run(host: host, script: "rm -f \(path(relativePath))")
    }

    func exists(_ relativePath: String) async -> Bool {
        let output = try? await runner.run(host: host, script: "[ -e \(path(relativePath)) ] && echo YES")
        return output?.stdout.contains("YES") == true
    }
}
