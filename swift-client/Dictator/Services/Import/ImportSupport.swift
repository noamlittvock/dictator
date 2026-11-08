import Foundation

// Shared parsing helpers for the history import readers: dates, streamed
// line reading, noise filtering, stable hashing and JSON field access.
// Ported from the retired `import-external-history.py` script (`parse_dt`,
// `clean_text`, `is_noise`) so the app and the old script agree.

// MARK: - Dates

enum ImportDates {
    /// Unix seconds or milliseconds (numbers or numeric strings, anything
    /// above 10^10 is milliseconds), or ISO 8601 with or without fractional
    /// seconds, `T` or space between date and time, and `Z`, `±hh:mm`,
    /// `±hhmm`, ` +hh:mm` or no zone (read as UTC).
    static func parse(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return fromUnix(number.doubleValue)
        case let string as String:
            return parse(string: string)
        default:
            return nil
        }
    }

    static func parse(string raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let number = Double(text), text.first.map({ $0.isNumber || $0 == "-" || $0 == "." }) == true {
            return fromUnix(number)
        }
        return parseISO(text)
    }

    /// Files from other tools can hold any number. `Int(_:)` traps out of range.
    static func wholeNumber(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(exactly: value.rounded(.towardZero)) ?? (value < 0 ? Int.min : Int.max)
    }

    /// The year 2100 in milliseconds: nothing later is a real timestamp.
    private static let latestUnix = 4_102_444_800_000.0

    static func fromUnix(_ value: Double) -> Date? {
        guard value.isFinite, value > 0, value < latestUnix else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    /// Hand-rolled so it is fast, thread-safe and needs no formatters.
    static func parseISO(_ text: String) -> Date? {
        let b = Array(text.utf8)
        var i = 0

        func digits(_ count: Int) -> Int? {
            guard i + count <= b.count else { return nil }
            var value = 0
            for k in 0..<count {
                let c = b[i + k]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            i += count
            return value
        }
        func take(_ c: UInt8) -> Bool {
            if i < b.count, b[i] == c { i += 1; return true }
            return false
        }

        guard let year = digits(4), take(45), let month = digits(2), take(45), let day = digits(2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var hour = 0, minute = 0, second = 0
        var fraction = 0.0
        if i < b.count, b[i] == 84 || b[i] == 116 || b[i] == 32 { // T, t, space
            i += 1
            guard let h = digits(2), take(58), let m = digits(2), h < 24, m < 60 else { return nil }
            hour = h; minute = m
            if take(58) {
                guard let s = digits(2), s <= 60 else { return nil }
                second = s
                if i < b.count, b[i] == 46 || b[i] == 44 { // . or ,
                    i += 1
                    var scale = 0.1
                    var any = false
                    while i < b.count, b[i] >= 48, b[i] <= 57 {
                        fraction += Double(b[i] - 48) * scale
                        scale /= 10
                        i += 1
                        any = true
                    }
                    guard any else { return nil }
                }
            }
        }
        while i < b.count, b[i] == 32 { i += 1 }
        var offset = 0
        if i < b.count {
            if b[i] == 90 || b[i] == 122 { // Z, z
                i += 1
            } else if b[i] == 43 || b[i] == 45 { // + -
                let sign = b[i] == 45 ? -1 : 1
                i += 1
                guard let oh = digits(2) else { return nil }
                _ = take(58)
                let om = digits(2) ?? 0
                offset = sign * (oh * 3_600 + om * 60)
            } else {
                return nil
            }
        }
        guard i == b.count else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days * 86_400 + hour * 3_600 + minute * 60 + second - offset) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar
    /// (H. Hinnant's `days_from_civil`).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

// MARK: - Streaming lines

enum ImportLines {
    static let maxLineBytes = 8 * 1_024 * 1_024
    private static let chunkBytes = 1 << 20

    /// Calls `body` with each line (newline stripped, 1-based line number)
    /// without loading the file into memory. Lines longer than
    /// `maxLineBytes` are skipped. `body` returns false to stop early.
    static func forEach(
        in url: URL,
        maxLineBytes: Int = ImportLines.maxLineBytes,
        _ body: (Data, Int) throws -> Bool
    ) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ImportError.unreadable(ImportPaths.display(url))
        }
        defer { try? handle.close() }

        var buffer = Data()
        var skipping = false
        var lineNumber = 0
        while true {
            let chunk: Data
            do {
                // Drain each chunk's Foundation buffers as we go; without
                // this a multi-GB folder stays resident until the read ends.
                chunk = try autoreleasepool { try handle.read(upToCount: chunkBytes) ?? Data() }
            } catch {
                throw ImportError.unreadable(ImportPaths.display(url))
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)

            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 10) {
                if skipping {
                    skipping = false
                } else if buffer.distance(from: start, to: newline) > maxLineBytes {
                    lineNumber += 1
                } else {
                    lineNumber += 1
                    let keepGoing = try autoreleasepool {
                        try body(Data(buffer[start..<newline]), lineNumber)
                    }
                    if !keepGoing { return }
                }
                start = buffer.index(after: newline)
            }
            buffer.removeSubrange(buffer.startIndex..<start)
            if buffer.count > maxLineBytes {
                if !skipping { lineNumber += 1 }
                skipping = true
                buffer.removeAll(keepingCapacity: false)
            }
        }
        if !buffer.isEmpty, !skipping, buffer.count <= maxLineBytes {
            lineNumber += 1
            _ = try autoreleasepool { try body(buffer, lineNumber) }
        }
    }

    static func jsonObject(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    static func contains(_ line: Data, anyOf needles: [Data]) -> Bool {
        needles.contains { line.range(of: $0) != nil }
    }
}

// MARK: - Paths

enum ImportPaths {
    /// `~/…` for paths inside the home folder, for messages.
    static func display(_ url: URL) -> String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func exists(_ url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return (exists, isDirectory.boolValue)
    }

    /// Every regular file under `folder` accepted by `include`, sorted by
    /// path so reads are deterministic.
    static func files(under folder: URL, include: (URL) -> Bool) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            guard include(url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The file to read for an export source: `url` itself, or the first
    /// file named one of `names` inside a chosen folder.
    static func exportFile(_ url: URL, names: [String], hint: String) throws -> URL {
        let state = exists(url)
        guard state.exists else { throw ImportError.notFound(display(url)) }
        guard state.isDirectory else { return url }
        let lowered = Set(names.map { $0.lowercased() })
        let matches = files(under: url) { lowered.contains($0.lastPathComponent.lowercased()) }
        guard let first = matches.first else { throw ImportError.unrecognized(hint) }
        return first
    }

    static func readData(_ url: URL) throws -> Data {
        guard exists(url).exists else { throw ImportError.notFound(display(url)) }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ImportError.unreadable(display(url))
        }
    }
}

// MARK: - Text

enum ImportTextFilter {
    enum Outcome: Equatable {
        case keep(String)
        case empty
        case noise
    }

    // Kept in step with NOISE_PREFIXES / NOISE_CONTAINS / SCAFFOLD_CONTAINS /
    // INJECTION_TAGS in the retired import script, plus a few newer
    // Codex / Claude Code wrappers.
    static let noisePrefixes = [
        "<environment_context>", "<permissions instructions>", "<app-context>",
        "<collaboration_mode>", "<apps_instructions>", "<skills_instructions>",
        "<plugins_instructions>", "<system-reminder>", "<local-command-caveat>",
        "<command-name>", "<developer_context>", "<user_info>", "<subagent_notification>",
        "<user_instructions>", "<instructions>", "<turn_aborted>",
        "# agents.md instructions", "[request interrupted by user",
    ]
    static let noiseContains = [
        "Filesystem sandboxing defines which files can be read or written",
        "You are running inside the Codex",
        "A skill is a set of local instructions",
        "Apps (Connectors) can be explicitly triggered",
    ]
    static let scaffoldContains = [
        "the following is the codex agent history",
        "# in app browser",
        "the user has the in-app browser",
        "## my request for codex",
        "adversarial claim verifier",
        "completeness critic",
        "## source extractor",
        "base directory for this skill",
    ]
    static let injectionTags = [
        "task-notification", "task-id", "tool-use-id", "output-file", "status", "summary",
        "system-reminder", "local-command-stdout", "local-command-caveat",
        "command-name", "command-message", "command-args",
        "bash-input", "bash-stdout", "bash-stderr",
        "environment_context", "developer_context", "user_info", "subagent_notification",
        "apps_instructions", "skills_instructions", "plugins_instructions",
    ]
    static let controlCommands: Set<String> = ["clear", "exit", "quit", "status", "help", "compact", "model"]

    private static let injectionTag = try! NSRegularExpression(
        pattern: "<\\s*/?\\s*(?:" + injectionTags.joined(separator: "|") + ")\\b",
        options: [.caseInsensitive]
    )
    private static let imageTag = try! NSRegularExpression(
        pattern: "<\\s*/?\\s*image\\b[^>]*>",
        options: [.caseInsensitive]
    )

    /// Port of `is_noise`. `strictLength` drops prompts shorter than eight
    /// characters or two words (the script did this for every source but
    /// Wispr Flow; typed one-word replies to an agent aren't prompts).
    static func classify(_ raw: String?, strictLength: Bool = true) -> Outcome {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        if strictLength, text.count < 8 || wordCount(text) < 2 { return .noise }
        let lowered = text.lowercased()
        if noisePrefixes.contains(where: { lowered.hasPrefix($0) }) { return .noise }
        if noiseContains.contains(where: { text.contains($0) }) { return .noise }
        if scaffoldContains.contains(where: { lowered.contains($0) }) { return .noise }
        let range = NSRange(text.startIndex..., in: text)
        if injectionTag.firstMatch(in: text, range: range) != nil { return .noise }
        if imageTag.firstMatch(in: text, range: range) != nil {
            let rest = imageTag.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            if wordCount(rest) < 2 { return .noise }
        }
        if isControlCommand(lowered) { return .noise }
        // Bare slash commands (`/clear`, `/model opus`) drive the tool.
        if ConnectorParsers.cleanPrompt(text) == nil { return .noise }
        return .keep(text)
    }

    /// `/clear`, `/model opus`, or a bare `exit`. (The script's regex also
    /// matched "help me …" without a slash; that was a bug, not kept.)
    static func isControlCommand(_ lowered: String) -> Bool {
        if lowered.hasPrefix("/") {
            let head = lowered.dropFirst().prefix { !$0.isWhitespace }
            return controlCommands.contains(String(head))
        }
        return controlCommands.contains(lowered)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Port of `clean_text`: strings, lists of strings or `{text|content}`
    /// dicts, or a dict holding one of those.
    static func cleanText(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let list as [Any]:
            let parts = list.compactMap { item -> String? in
                if let string = item as? String { return string }
                if let dict = item as? [String: Any] {
                    return (dict["text"] as? String) ?? (dict["content"] as? String) ?? ""
                }
                return nil
            }
            return parts.filter { !$0.isEmpty }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case let dict as [String: Any]:
            return cleanText(dict["content"] ?? dict["text"] ?? dict["message"])
        default:
            return ""
        }
    }

    /// Text blocks only (`type` missing, `text` or `input_text`), as the
    /// script's `extract_claude_message_text` / `extract_codex_content`.
    static func textBlocks(_ value: Any?) -> String {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let list = value as? [Any] else { return "" }
        let parts = list.compactMap { item -> String? in
            if let string = item as? String { return string }
            guard let block = item as? [String: Any] else { return nil }
            let type = block["type"] as? String
            guard type == nil || type == "text" || type == "input_text" else { return nil }
            return (block["text"] as? String) ?? (block["content"] as? String)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Key for "same prompt" comparisons: `DatasetText.normalized`, falling
    /// back to the trimmed lower-cased text for symbol-only prompts.
    static func matchKey(_ text: String) -> String {
        let normalized = DatasetText.normalized(text)
        return normalized.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : normalized
    }
}

// MARK: - Hashing

enum ImportHash {
    /// FNV-1a 64 as 16 hex digits — stable across launches (unlike `Hasher`).
    static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    static func short(_ text: String) -> String { String(hex(text).prefix(12)) }
}

// MARK: - Result building

/// Accumulates prompts and skip counts while a reader walks its input.
struct ImportCollector {
    var result = ImportReadResult()

    /// Filters `raw`; returns the kept text or nil (counting why).
    mutating func accept(_ raw: String?, strictLength: Bool = true) -> String? {
        switch ImportTextFilter.classify(raw, strictLength: strictLength) {
        case .keep(let text): return text
        case .empty: result.skippedEmpty += 1; return nil
        case .noise: result.skippedNoise += 1; return nil
        }
    }

    mutating func append(_ prompt: ImportedPrompt) {
        result.prompts.append(prompt)
    }
}

extension Dictionary where Key == String, Value == Any {
    func importString(_ key: String) -> String? {
        guard let value = self[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func importBool(_ key: String) -> Bool {
        (self[key] as? NSNumber)?.boolValue ?? false
    }

    func importDict(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }
}
