import Foundation

/// Collects hook records the local `dictator-capture` shim drops into
/// `~/.dictator/spool`: parses each, hands it on, and deletes the file only
/// once it's stored or deliberately skipped (a failed save leaves it for the
/// next pass). Wakes on directory changes, with a slow poll as a safety net.
@MainActor
final class LocalSpoolWatcher {
    typealias Handler = @MainActor (CapturedPrompt) async -> Bool
    private let spoolURL: URL
    private let onPrompt: Handler
    private var scanning = false
    private var source: DispatchSourceFileSystemObject?
    private var pollTask: Task<Void, Never>?
    private var scanScheduled = false

    init(home: String = NSHomeDirectory(), onPrompt: @escaping Handler) {
        spoolURL = URL(fileURLWithPath: home).appendingPathComponent(ConnectorInstaller.spoolRelativePath)
        self.onPrompt = onPrompt
    }

    func start() {
        stop()
        try? FileManager.default.createDirectory(at: spoolURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(spoolURL.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleScan() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.scanScheduled = false
            await self.scan()
        }
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: spoolURL.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = spoolURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            let id = String(name.dropLast(5))
            var handled = true
            if data.count < 40_000_000,
               let prompt = ConnectorParsers.parseSpoolRecord(data, id: id, remoteHost: nil, catalog: .shared) {
                handled = await onPrompt(prompt)
            }
            // Unparseable or non-human records are dropped; a failed save
            // keeps the file for the next pass.
            if handled { try? fm.removeItem(at: url) }
        }
    }
}

/// Reads tools' own history files for tools set to "Read the tool's history
/// file" — no change to the tool's configuration. Starts at the end of each
/// file when switched on (no backfill of old prompts) and remembers its
/// offsets across launches.
@MainActor
final class TranscriptWatcher {
    private let home: String
    private let onPrompt: LocalSpoolWatcher.Handler
    private var polling = false
    private var pollTask: Task<Void, Never>?
    private var offsets: [String: Int]
    private var enabledAt: [String: Date]
    private(set) var toolIDs: Set<String> = []

    init(home: String = NSHomeDirectory(), onPrompt: @escaping LocalSpoolWatcher.Handler) {
        self.home = home
        self.onPrompt = onPrompt
        offsets = UserDefaults.standard.dictionary(forKey: "transcriptOffsets") as? [String: Int] ?? [:]
        enabledAt = UserDefaults.standard.dictionary(forKey: "transcriptEnabledAt") as? [String: Date] ?? [:]
    }

    /// Tools whose history files should be followed.
    func setTools(_ ids: Set<String>) {
        let added = ids.subtracting(toolIDs)
        toolIDs = ids
        for id in added where enabledAt[id] == nil {
            enabledAt[id] = Date()
            // Skip everything already in the files.
            if let tool = ToolCatalog.shared.tool(id: id) { markExistingAsRead(tool) }
        }
        for id in enabledAt.keys where !ids.contains(id) { enabledAt.removeValue(forKey: id) }
        persist()
        if ids.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        } else if pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.poll()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    static func isAvailable(for tool: ToolDefinition) -> Bool {
        tool.connector?.transcript != nil
    }

    private func files(for tool: ToolDefinition) -> [URL] {
        guard let transcript = tool.connector?.transcript else { return [] }
        let base = URL(fileURLWithPath: home).appendingPathComponent(transcript.path)
        guard let glob = transcript.glob else { return [base] }
        // `<dir>/*/<rest>` — one level of conversation folders.
        let parts = glob.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "*" else { return [] }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let horizon = Date().addingTimeInterval(-6 * 3_600)
        return dirs.compactMap { dir in
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard modified > horizon else { return nil }
            let file = dir.appendingPathComponent(parts[1])
            return fm.fileExists(atPath: file.path) ? file : nil
        }
    }

    private func markExistingAsRead(_ tool: ToolDefinition) {
        for file in files(for: tool) {
            offsets[file.path] = fileSize(file)
        }
    }

    private func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    static let maxChunk = 16_000_000

    func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        let catalog = ToolCatalog.shared
        for id in toolIDs {
            guard let tool = catalog.tool(id: id), let format = tool.connector?.transcript?.format else { continue }
            for file in files(for: tool) {
                let size = fileSize(file)
                var offset = offsets[file.path] ?? {
                    // A conversation file that appeared after capture was
                    // switched on is read from its start.
                    let created = (try? FileManager.default.attributesOfItem(atPath: file.path)[.creationDate]) as? Date
                    return (created ?? .distantPast) > (enabledAt[id] ?? .distantFuture) ? 0 : size
                }()
                if size < offset { offset = 0 } // truncated or replaced
                offsets[file.path] = offset
                guard size > offset else { continue }
                let start = offset
                let path = file.path
                // Disk read off the main actor.
                let data: Data = await Task.detached(priority: .utility) {
                    guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
                    defer { try? handle.close() }
                    try? handle.seek(toOffset: UInt64(start))
                    return (try? handle.read(upToCount: min(size - start, TranscriptWatcher.maxChunk))) ?? Data()
                }.value
                guard let lastNewline = data.lastIndex(of: 0x0A) else {
                    // A single line bigger than a whole chunk can't be a
                    // prompt record we can use; skip past it.
                    if data.count >= Self.maxChunk { offsets[file.path] = start + data.count }
                    continue
                }
                // Only complete lines; a half-written last line waits.
                var cursor = start
                var lineStart = data.startIndex
                while lineStart <= lastNewline {
                    let lineEnd = data[lineStart...lastNewline].firstIndex(of: 0x0A)!
                    let line = data[lineStart..<lineEnd]
                    if !line.isEmpty, let prompt = parse(Data(line), format: format, file: file, toolID: id) {
                        guard await onPrompt(prompt) else { break } // retry from this line next poll
                    }
                    cursor += line.count + 1
                    lineStart = lineEnd + 1
                }
                offsets[file.path] = cursor
            }
        }
        persist()
    }

    private func parse(_ line: Data, format: String, file: URL, toolID: String) -> CapturedPrompt? {
        switch format {
        case "claude-history":
            return ConnectorParsers.parseClaudeHistoryLine(line, toolID: toolID)
        case "codex-history":
            return ConnectorParsers.parseCodexHistoryLine(line, toolID: toolID)
        case "agy-brain":
            // …/brain/<conversation>/.system_generated/logs/transcript_full.jsonl
            let conversation = file.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
            return ConnectorParsers.parseAntigravityLine(line, conversation: conversation, toolID: toolID)
        default:
            return nil
        }
    }

    private func persist() {
        // Drop offsets of files no longer followed so the map stays small.
        if offsets.count > 500 {
            let keep = Set(toolIDs.flatMap { id in ToolCatalog.shared.tool(id: id).map(files(for:)) ?? [] }.map(\.path))
            offsets = offsets.filter { keep.contains($0.key) }
        }
        UserDefaults.standard.set(offsets, forKey: "transcriptOffsets")
        UserDefaults.standard.set(enabledAt, forKey: "transcriptEnabledAt")
    }
}
