import CryptoKit
import Foundation

/// A local, reusable selection. Filter categories are ANDed; destinations and
/// excluded terms use any-match semantics. Limits run after all filters.
struct DatasetQuery: Codable, Equatable, Sendable {
    enum TextMatch: String, Codable, CaseIterable { case contains, allWords, anyWord, regex }
    enum Input: String, Codable, CaseIterable { case all, voice, typed }
    enum Take: String, Codable, CaseIterable, Sendable { case all, newest, oldest, random }
    enum Imports: String, Codable, CaseIterable { case all, captured, imported }
    enum SavedBy: String, Codable, CaseIterable, Sendable {
        case dictation, typedHistory, connectedTool, imported
        var label: String {
            switch self {
            case .dictation: "Dictation"
            case .typedHistory: "Typed history"
            case .connectedTool: "Connected AI tool"
            case .imported: "Imported"
            }
        }
    }
    /// `DatasetDestination` key or `vendor:<name>`.
    var destination: String?
    /// When present, replaces the legacy single destination (including an empty selection).
    var destinations: [String]?
    var excludedDestinations: [String]?
    var excludedText: String?
    var take: Take?
    var takeCount: Int?
    var randomSeed: String?

    var selectedDestinations: [String] {
        (destinations ?? destination.map { [$0] } ?? []).filter { !$0.isEmpty }
    }
    var takeMode: Take { take ?? .all }
    var savedBy: SavedBy?
    var from: Date?
    var through: Date?
    var input: Input = .all
    var imports: Imports = .all
    var website = ""
    var remoteHost = ""
    /// Full directory, rather than a basename shared by unrelated projects.
    var project = ""
    var computer = ""
    var session = ""
    var text = ""
    var textMatch: TextMatch = .contains
    var minimumWords = 0
    var maximumWords = 0

    func validate() throws {
        if takeMode != .all && (takeCount ?? 0) <= 0 {
            throw DatasetFailure.message("Enter a number greater than 0 for how many prompts to take.")
        }
        if let from, let through, from > through { throw DatasetFailure.message("The start date must come before the end date.") }
        if minimumWords < 0 || maximumWords < 0 || maximumWords > 0 && maximumWords < minimumWords {
            throw DatasetFailure.message("Word counts must be 0 or more, and the minimum can't be above the maximum. Use 0 for no upper limit.")
        }
        if textMatch == .regex, !text.isEmpty {
            do { _ = try NSRegularExpression(pattern: text, options: [.caseInsensitive]) }
            catch { throw DatasetFailure.message("The text pattern is not a valid regular expression: \(error.localizedDescription)") }
        }
    }

    func select(_ rows: [DatasetRow]) throws -> [DatasetRow] {
        try selection(rows).rows
    }

    /// Counts matches before limiting; preparation (including empty removal) follows this.
    func selection(_ rows: [DatasetRow]) throws -> (matchedCount: Int, rows: [DatasetRow]) {
        try validate()
        let regex = textMatch == .regex && !text.isEmpty ? try NSRegularExpression(pattern: text, options: [.caseInsensitive]) : nil
        let terms = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let excludedTerms = (excludedText ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let includedPlaces = selectedDestinations
        let excludedPlaces = excludedDestinations ?? []
        func matches(_ key: String, _ destination: DatasetDestination) -> Bool {
            key.hasPrefix("vendor:") ? destination.vendorKey == key : destination.key == key
        }
        let matched = rows.filter { row in
            if let from, row.timestamp < from { return false }
            if let through, row.timestamp > through { return false }
            if input != .all, row.modality.rawValue != input.rawValue { return false }
            if imports == .captured && row.isImported || imports == .imported && !row.isImported { return false }
            let resolved = row.destination ?? .unknown
            if !includedPlaces.isEmpty && !includedPlaces.contains(where: { matches($0, resolved) }) { return false }
            if excludedPlaces.contains(where: { matches($0, resolved) }) { return false }
            if excludedTerms.contains(where: { row.text.range(of: $0, options: [.caseInsensitive]) != nil }) { return false }
            if let savedBy, row.savedBy != savedBy { return false }
            if !website.isEmpty && row.webHost != website { return false }
            if !remoteHost.isEmpty && row.remoteHost != remoteHost { return false }
            if !project.isEmpty && row.workingDirectory != project { return false }
            if !computer.isEmpty && row.originEdgeId != computer { return false }
            if !session.isEmpty && row.sessionId != session { return false }
            if row.wordCount < minimumWords || maximumWords > 0 && row.wordCount > maximumWords { return false }
            if !text.isEmpty {
                switch textMatch {
                case .contains: if row.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
                case .allWords: if !terms.allSatisfy({ row.text.lowercased().contains($0) }) { return false }
                case .anyWord: if !terms.contains(where: { row.text.lowercased().contains($0) }) { return false }
                case .regex:
                    if regex?.firstMatch(in: row.text, range: NSRange(row.text.startIndex..., in: row.text)) == nil { return false }
                }
            }
            return true
        }.sorted(by: Self.chronological)
        let count = takeCount ?? matched.count
        let selected: [DatasetRow]
        switch takeMode {
        case .all: selected = matched
        case .newest: selected = Array(matched.suffix(count))
        case .oldest: selected = Array(matched.prefix(count))
        case .random:
            // Hash once per row. A persisted seed and stable UUID make input order irrelevant.
            let seed = randomSeed ?? "0"
            var ranked: [(row: DatasetRow, hash: String)] = matched.map { row in
                let key = seed + "\n" + row.id.uuidString.lowercased()
                return (row: row, hash: Dataset.hash(Data(key.utf8)))
            }
            ranked.sort { left, right in
                if left.hash == right.hash { return left.row.id.uuidString < right.row.id.uuidString }
                return left.hash < right.hash
            }
            selected = ranked.prefix(count).map { $0.row }.sorted(by: Self.chronological)
        }
        return (matched.count, selected)
    }

    private static func chronological(_ a: DatasetRow, _ b: DatasetRow) -> Bool {
        a.timestamp == b.timestamp ? a.id.uuidString < b.id.uuidString : a.timestamp < b.timestamp
    }
}

enum DatasetFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct DatasetPreparation: Codable, Equatable, Sendable {
    enum Format: String, Codable, CaseIterable { case jsonl, json, csv }
    var format: Format = .jsonl
    var trimWhitespace = true
    var removeEmpty = true
    /// Exact cleaned text + tool/app + directory + session + computer.
    /// Deduplication never silently merges separate sessions or computers.
    var deduplicate = false
    var redactSecrets = true
    var includeContext = true
    var includeTiming = true
    var includeSelection = true
}

struct DatasetRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var timestamp: Date
    var timestampUnixSeconds: Double
    var text: String
    var wordCount: Int
    var storedWordCount: Int
    var input: String
    var imported: Bool
    var tool: String?
    var appID: String?
    var appName: String?
    var website: String?
    var destinationURL: String?
    var project: String?
    var session: String?
    var computer: String?
    var computerName: String?
    var remoteHost: String?
    var captureSource: String?
    var importBatch: String?
    var speakingSeconds: Double?
    var typingSeconds: Double?
    var latencyMilliseconds: Int?
    var cleanupModel: String?
    var firstTakeAfterLoad: Bool?
    var cleanupLevel: String?
    var cleanupOutcome: String?
    var cleanupMilliseconds: Int?
    var recordedInput: String?
    var source: String?
    var surfaceLabel: String?
    var captureReason: String?
    var insertionMethod: String?
    var inferenceMilliseconds: Int?
    /// Resolved destination name ("Claude Code", "Terminal or agent app, tool not recorded", "Telegram").
    var destination: String?
    /// Maker of the AI tool, when the destination is one.
    var vendor: String?
    /// dictation, typedHistory, connectedTool or imported.
    var savedBy: String?
}

struct DatasetManifest: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var createdAt: Date
    var name: String
    var query: DatasetQuery?
    var preparation: DatasetPreparation
    var matchedRecords: Int
    var takenRecords: Int?
    var exportedRecords: Int
    var emptyRemoved: Int
    var duplicatesRemoved: Int
    var recordsChangedByRedaction: Int
    var dataFile: String
    var sha256: String
    var canonicalSHA256: String
    var earliest: Date?
    var latest: Date?
    var queryFromUnixSeconds: Double?
    var queryThroughUnixSeconds: Double?
    var scope = "History available on the exporting Mac, including replicated records. This is not a complete record of computer activity."
}

struct Dataset: Sendable {
    var records: [DatasetRecord]
    var manifest: DatasetManifest
    var data: Data

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func build(rows: [DatasetRow], query: DatasetQuery, preparation: DatasetPreparation,
                      computers: [String: String] = [:], name: String = "Usage", id: UUID = UUID(), now: Date = Date()) throws -> Self {
        let selection = try query.selection(rows)
        let selected = selection.rows
        var records: [DatasetRecord] = []
        var seen = Set<Data>()
        var empty = 0, duplicates = 0, redacted = 0
        let encoder = encoder()
        for row in selected {
            var text = row.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            if preparation.trimWhitespace { text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if preparation.removeEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { empty += 1; continue }
            if preparation.deduplicate {
                let key = try encoder.encode([text, row.toolId ?? row.appBundleId ?? row.appName ?? "", row.workingDirectory ?? "",
                                              row.sessionId ?? "", row.originEdgeId ?? "", row.remoteHost ?? "", row.modality.rawValue])
                if !seen.insert(key).inserted { duplicates += 1; continue }
            }
            func clean(_ value: String?) -> String? { value.map { preparation.redactSecrets ? SecretScrubber.scrub($0) : $0 } }
            let finalText = clean(text) ?? text
            let context = preparation.includeContext
            let timing = preparation.includeTiming
            var record = DatasetRecord(id: row.id.uuidString.lowercased(), timestamp: row.timestamp, timestampUnixSeconds: row.timestamp.timeIntervalSince1970, text: finalText,
                                     wordCount: finalText.split(whereSeparator: \.isWhitespace).count,
                                     storedWordCount: row.wordCount,
                                     input: row.modality.rawValue, imported: row.isImported)
            if context {
                record.tool = clean(row.toolId); record.appID = clean(row.appBundleId); record.appName = clean(row.appName)
                record.website = clean(row.webHost); record.destinationURL = clean(row.destinationURL)
                record.project = clean(row.workingDirectory); record.session = clean(row.sessionId)
                record.computer = clean(row.originEdgeId); record.computerName = clean(row.originEdgeId.flatMap { computers[$0] })
                record.remoteHost = clean(row.remoteHost); record.captureSource = clean(row.captureSource); record.importBatch = clean(row.importBatchId)
                record.recordedInput = clean(row.recordedModality); record.source = clean(row.source)
                record.surfaceLabel = clean(row.surfaceLabel); record.captureReason = clean(row.captureReason); record.insertionMethod = clean(row.insertionMethod)
                record.destination = clean(row.destination.flatMap { $0.kind == .unknown ? nil : $0.name })
                record.vendor = clean(row.destination?.vendor); record.savedBy = row.savedBy.rawValue
            }
            if timing {
                record.speakingSeconds = row.modality == .voice && row.durationSeconds > 0 ? row.durationSeconds : nil
                record.typingSeconds = row.typingSeconds; record.latencyMilliseconds = row.latencyMs
                record.cleanupModel = clean(row.polishModel); record.firstTakeAfterLoad = row.firstTakeAfterLoad
                record.cleanupLevel = clean(row.cleanupLevel); record.cleanupOutcome = clean(row.cleanupOutcome); record.cleanupMilliseconds = row.cleanupMs
                record.inferenceMilliseconds = row.inferenceMs
            }
            // Includes metadata redactions, not just prompt text.
            if preparation.redactSecrets {
                let values = [text] + (context ? [row.toolId, row.appBundleId, row.appName, row.webHost, row.destinationURL, row.workingDirectory, row.sessionId,
                                                 row.originEdgeId, row.originEdgeId.flatMap { computers[$0] }, row.remoteHost, row.captureSource, row.importBatchId,
                                                 row.recordedModality, row.source, row.surfaceLabel, row.captureReason, row.insertionMethod].compactMap { $0 } : [])
                    + (timing ? [row.polishModel].compactMap { $0 } : [])
                if values.contains(where: { SecretScrubber.scrub($0) != $0 }) { redacted += 1 }
            }
            records.append(record)
        }
        let data: Data
        switch preparation.format {
        case .jsonl:
            var output = Data()
            for record in records { output.append(try encoder.encode(record)); output.append(0x0A) }
            data = output
        case .json: data = try encoder.encode(records)
        case .csv: data = try csv(records)
        }
        // Exported query metadata follows the same redaction choice.
        var exportQuery = query
        if preparation.redactSecrets {
            exportQuery.website = SecretScrubber.scrub(query.website); exportQuery.remoteHost = SecretScrubber.scrub(query.remoteHost)
            exportQuery.project = SecretScrubber.scrub(query.project); exportQuery.computer = SecretScrubber.scrub(query.computer)
            exportQuery.session = SecretScrubber.scrub(query.session)
            exportQuery.destination = query.destination.map(SecretScrubber.scrub)
            exportQuery.destinations = query.destinations.map { $0.map(SecretScrubber.scrub) }
            exportQuery.excludedDestinations = query.excludedDestinations.map { $0.map(SecretScrubber.scrub) }
            exportQuery.excludedText = query.excludedText.map(SecretScrubber.scrub)
            exportQuery.randomSeed = query.randomSeed.map(SecretScrubber.scrub)
            exportQuery.text = SecretScrubber.scrub(query.text)
        }
        let manifest = DatasetManifest(id: id, createdAt: now, name: cleanName(name, redact: preparation.redactSecrets), query: preparation.includeSelection ? exportQuery : nil,
                                     preparation: preparation, matchedRecords: selection.matchedCount, takenRecords: selected.count, exportedRecords: records.count,
                                     emptyRemoved: empty, duplicatesRemoved: duplicates, recordsChangedByRedaction: redacted,
                                     dataFile: "records.\(preparation.format.rawValue)", sha256: hash(data), canonicalSHA256: hash(try encoder.encode(records)),
                                     earliest: records.first?.timestamp, latest: records.last?.timestamp,
                                     queryFromUnixSeconds: preparation.includeSelection ? query.from?.timeIntervalSince1970 : nil,
                                     queryThroughUnixSeconds: preparation.includeSelection ? query.through?.timeIntervalSince1970 : nil)
        return Self(records: records, manifest: manifest, data: data)
    }

    private static func cleanName(_ name: String, redact: Bool) -> String { redact ? SecretScrubber.scrub(name) : name }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Quoting preserves multiline text; spreadsheet formula prefixes are escaped.
    private static func csv(_ records: [DatasetRecord]) throws -> Data {
        let columns = ["id", "timestamp", "timestampUnixSeconds", "text", "wordCount", "storedWordCount", "input", "imported", "tool", "appID", "appName", "website", "destinationURL", "project", "session",
                       "computer", "computerName", "remoteHost", "captureSource", "importBatch", "speakingSeconds", "typingSeconds", "latencyMilliseconds", "cleanupModel", "firstTakeAfterLoad", "cleanupLevel", "cleanupOutcome", "cleanupMilliseconds",
                       "recordedInput", "source", "surfaceLabel", "captureReason", "insertionMethod", "inferenceMilliseconds", "destination", "vendor", "savedBy"]
        func quote(_ value: String) -> String {
            let leading = value.trimmingCharacters(in: .whitespacesAndNewlines).first
            let safe = leading.map { "=+-@".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = [columns.joined(separator: ",")]
        for record in records {
            let object = try JSONSerialization.jsonObject(with: encoder().encode(record)) as? [String: Any] ?? [:]
            lines.append(columns.map { key in
                guard let value = object[key] else { return "\"\"" }
                return quote(value as? String ?? String(describing: value))
            }.joined(separator: ","))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// The CLI receives a self-contained JSON envelope regardless of export format.
    func agentInput(instructions: String) throws -> Data {
        struct Envelope: Encodable { var instructions: String; var manifest: DatasetManifest; var records: [DatasetRecord] }
        return try Self.encoder().encode(Envelope(instructions: instructions, manifest: manifest, records: records))
    }

    static let schema = """
    # Dictator Usage package — schema version 1

    records.jsonl: one UTF-8 JSON object per line. records.json: a JSON array.
    records.csv: quoted UTF-8 CSV; formula-leading cells have an apostrophe prefix.
    manifest.json: selection, preparation options, counts, time range and SHA-256 of the exact data file.
    records.json is always included as canonical JSON, with its own canonicalSHA256 in the manifest.
    Dates are ISO 8601 UTC at second precision. Records are chronological with stable history IDs.
    Each record is saved user text, not an assistant reply. Imported text may have unknown provenance.
    Missing JSON fields / blank CSV fields mean not recorded or excluded, never zero.
    id: stable history UUID. timestamp: saved timestamp (1970-01-01 may mean an undated import).
    timestampUnixSeconds retains the original subsecond timestamp; use it for precise ordering and queries.
    text: prepared prompt. wordCount: whitespace-separated words after preparation. storedWordCount: original stored count.
    input: voice or typed. imported: whether added through a history import.
    destination: where the prompt went, by name: the AI tool when known (also from the app or website it went to), else "Terminal or agent app, tool not recorded" or the app's name.
    vendor: the AI tool's maker (Anthropic, OpenAI, Google…). savedBy: dictation, typedHistory, connectedTool or imported.
    tool: recorded tool ID. appID/appName: destination application. website: recorded web host.
    destinationURL: full recorded destination URL, when present (including terminal pseudo-URLs).
    project: full recorded working directory. session: source session ID; no inferred sessions.
    computer/computerName: originating install ID and known name; remoteHost: recorded SSH host.
    captureSource: capture method. importBatch: originating import batch ID.
    speakingSeconds: recording duration. typingSeconds: intervals between keys, pauses over 30s excluded.
    latencyMilliseconds: key release to insertion. cleanupModel: clean-up model, not speech model.
    firstTakeAfterLoad: whether this was the first take after start or model change.
    cleanupLevel: exact (skipped), medium (clean up) or strong (polish). cleanupMilliseconds: time spent in clean-up.
    cleanupOutcome: applied, fallback (polish replaced by clean-up), rejected (AI result not used) or unavailable.
    recordedInput: original modality before voice/typed normalization. source: original history source.
    surfaceLabel/captureReason: recorded destination label and capture-policy reason. insertionMethod: recorded delivery method.
    inferenceMilliseconds: recorded recognition/processing duration, distinct from release-to-insertion latency.
    Text matching happens on stored text before cleaning and redaction. Filter categories are ANDed, with these exceptions:
    destinations is an any-of list of destination keys or vendor:<name> keys; empty means anywhere.
    When destinations is absent, the legacy single destination field is used.
    excludedDestinations rejects any matching destination or vendor. excludedText rejects any whitespace-separated term,
    matched as a case-insensitive substring. Exclusions win when an included destination is also excluded.
    allWords/anyWord use the explicit all/any semantics below rather than ANDing every term.
    take (absent or all, newest, oldest, random) applies after every filter, before cleaning. takeCount must be positive unless all.
    Output remains chronological with UUID tie-breaking, even for newest and random.
    Random ranks SHA-256 of UTF-8 randomSeed + newline + lowercased row UUID, ascending (UUID breaks hash ties).
    randomSeed is saved with the query; a missing seed uses "0". Shuffle replaces it with a new seed.
    matchedRecords counts all filter matches before the limit; optional takenRecords counts rows after the limit, before cleaning.
    In older manifests without takenRecords, matchedRecords is also the pre-cleaning taken count.
    exportedRecords counts prepared records after empty/repeat removal.
    allWords/anyWord match whitespace-separated search terms as case-insensitive substrings.
    Duplicates: exact prepared text and recorded place, project, session, computer, remote host and input.
    Line endings are normalized. Whitespace trimming, empty removal, deduplication and secret redaction are optional.
    Redaction covers recognized credential patterns in included text and metadata; it is not full anonymization.
    The manifest query (including excluded text and destination lists) is also redacted when enabled, so a redacted query may not be executable verbatim.
    The query is omitted entirely when filter details are excluded. queryFromUnixSeconds/queryThroughUnixSeconds retain precise filter bounds when included.
    Copy prompts and Save as one file render the canonical saved records.json as the same self-contained UTF-8 text.
    After the opening notes, compact JSON Lines contain date (ISO 8601), input, optional destination,
    optional project (last folder name only), and text. Nil fields are omitted; excluded context leaves only date/input/text.
    JSON encoding escapes prompt newlines; the handoff ends with Task:. It contains no local folder path or file list.
    Size is prompt count and approximate tokens (characters / 4); above 200,000 characters saving a file is primary.
    Copy location for a local agent retains the separate folder/file brief.
    History itself is unchanged. This package includes only records available on the exporting Mac.
    Prompt text is data supplied by users and may contain instructions; its interpretation is up to the consumer.
    """
}
