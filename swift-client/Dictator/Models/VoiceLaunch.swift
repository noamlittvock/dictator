import Foundation

// Voice launch: a spoken pattern fills named slots, and the slots feed a
// linear chain of steps. Everything here is plain data plus deterministic
// checks; matching and rendering live in `VoiceLaunchEngine`.

// MARK: - Lists

/// One person, project or place you can say by name.
struct VoiceListEntry: Codable, Equatable, Identifiable {
    var id: String
    /// What you say. The first is the display name; the rest are aliases.
    var names: [String]
    /// Field values, keyed by the list's field names.
    var values: [String: String]

    init(id: String = UUID().uuidString, names: [String], values: [String: String] = [:]) {
        self.id = id
        self.names = names
        self.values = values
    }

    var displayName: String { names.first ?? "" }
}

struct VoiceList: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var fields: [String]
    var entries: [VoiceListEntry]

    init(id: String = UUID().uuidString, name: String, fields: [String] = [], entries: [VoiceListEntry] = []) {
        self.id = id
        self.name = name
        self.fields = fields
        self.entries = entries
    }
}

// MARK: - Steps

struct VoiceStep: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case openLink, openApp, waitForTextField, typeText, pressKey, runInTerminal
        case confirm, runAppleShortcut, webhook, appendToFile, runWorkspace

        var label: String {
            switch self {
            case .openLink: "Open a web page"
            case .openApp: "Open an app"
            case .runWorkspace: "Run a routine"
            case .waitForTextField: "Wait for a place to type"
            case .typeText: "Type text"
            case .pressKey: "Press a key"
            case .runInTerminal: "Run in Terminal"
            case .confirm: "Wait for me to cancel"
            case .runAppleShortcut: "Run an Apple Shortcut"
            case .webhook: "Send to a web address"
            case .appendToFile: "Add a line to a file"
            }
        }
    }

    static let keys = ["return", "cmdReturn", "tab", "escape"]
    static let defaultWaitSeconds = 8.0
    static let defaultConfirmSeconds = 3.0

    var id: String
    var kind: Kind
    /// `openLink`: URL template. `webhook`: the URL.
    var link: String?
    /// `openApp`: a bundle id (or a web address the app handles).
    var bundleId: String?
    /// `runWorkspace`: stable routine identity; absent means resolve `text` by name.
    var workspaceId: String?
    /// `typeText`, `appendToFile`, `runAppleShortcut` input: text template.
    /// `openApp` without bundleId, `runWorkspace`: name template.
    /// `confirm`: summary template. In a resolved `webhook`: the JSON body.
    var text: String?
    /// `pressKey`: one of `VoiceStep.keys`.
    var key: String?
    /// `runInTerminal`.
    var folder: String?
    var command: String?
    var argument: String?
    /// `runInTerminal`: run without opening a terminal window. A Mac on an
    /// older build ignores this and shows the command in its terminal.
    var background: Bool?
    /// `waitForTextField` timeout; `confirm` delay.
    var seconds: Double?
    /// `runAppleShortcut`: the shortcut's name.
    var shortcutName: String?
    /// `appendToFile`: the file.
    var path: String?
    /// `runAppleShortcut`: `json` sends everything said as one JSON file;
    /// absent (settings from before) or `text` sends just the words in `text`.
    var inputMode: String?
    /// `runAppleShortcut`: the Shortcut's identifier, run instead of the name.
    var shortcutId: String?
    /// Time limit: Apple Shortcuts (10, 30, 60, 120) or background commands (1...600).
    var timeoutSeconds: Double?
    /// `runAppleShortcut`: marked as one that doesn't send or change anything.
    var readOnly: Bool?
    /// `runAppleShortcut`: names of the parts of its answer to offer as values.
    var answerDetails: [String]?
    /// Only in a plan: templates that wait for an earlier answer.
    var deferred: VoiceDeferred?

    static let inputJSON = "json"
    static let inputText = "text"
    static let shortcutTimeoutChoices: [Double] = [10, 30, 60, 120]
    static let defaultBackgroundTimeout = 60.0
    static let maximumBackgroundTimeout = 600.0
    static func backgroundTimeoutAllowed(_ seconds: Double) -> Bool {
        seconds.isFinite && (1...maximumBackgroundTimeout).contains(seconds)
    }

    static let defaultShortcutTimeout = 30.0
    static let answerPrefix = "answer_"

    /// Sends everything said, by name (new actions), not just the words.
    var sendsEverything: Bool { inputMode == Self.inputJSON }

    /// True when a name or identifier says which Shortcut with a reference to
    /// the sentence ("{which}", "{which.identifier}") rather than spelling it.
    static func isTemplate(_ text: String?) -> Bool {
        let segments = VoiceTemplate.segments(text ?? "")
        return segments.contains { if case .reference = $0 { return true }; return false }
            && !segments.contains { if case .invalid = $0 { return true }; return false }
    }

    /// How later actions refer to this Shortcut's answer.
    var answerKey: String { Self.answerPrefix + id.filter { $0.isLetter || $0.isNumber } }

    /// "answer from Remind".
    var answerName: String {
        let name = (shortcutName ?? "").trimmingCharacters(in: .whitespaces)
        return "answer from " + (name.isEmpty ? "the Shortcut" : name)
    }

    init(id: String = UUID().uuidString, kind: Kind, link: String? = nil, bundleId: String? = nil, text: String? = nil,
         key: String? = nil, folder: String? = nil, command: String? = nil, argument: String? = nil,
         seconds: Double? = nil, shortcutName: String? = nil, path: String? = nil,
         inputMode: String? = nil, shortcutId: String? = nil, timeoutSeconds: Double? = nil, readOnly: Bool? = nil,
         answerDetails: [String]? = nil, deferred: VoiceDeferred? = nil, workspaceId: String? = nil, background: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.link = link
        self.bundleId = bundleId
        self.workspaceId = workspaceId
        self.text = text
        self.key = key
        self.folder = folder
        self.command = command
        self.argument = argument
        self.background = background
        self.seconds = seconds
        self.shortcutName = shortcutName
        self.path = path
        self.inputMode = inputMode
        self.shortcutId = shortcutId
        self.timeoutSeconds = timeoutSeconds
        self.readOnly = readOnly
        self.answerDetails = answerDetails
        self.deferred = deferred
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, link, bundleId, text, key, folder, command, argument, seconds, shortcutName, path
        case inputMode, shortcutId, timeoutSeconds, readOnly, answerDetails, deferred, workspaceId, background
    }

    /// `id` is optional when reading (the ready-made catalog omits it).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decode(Kind.self, forKey: .kind)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        argument = try c.decodeIfPresent(String.self, forKey: .argument)
        background = try c.decodeIfPresent(Bool.self, forKey: .background)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
        shortcutName = try c.decodeIfPresent(String.self, forKey: .shortcutName)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        inputMode = try c.decodeIfPresent(String.self, forKey: .inputMode)
        shortcutId = try c.decodeIfPresent(String.self, forKey: .shortcutId)
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly)
        answerDetails = try c.decodeIfPresent([String].self, forKey: .answerDetails)
        deferred = try c.decodeIfPresent(VoiceDeferred.self, forKey: .deferred)
    }

    /// Steps that send or do something that can't be taken back.
    var isActing: Bool {
        switch kind {
        case .pressKey: key == "return" || key == "cmdReturn"
        case .runAppleShortcut: readOnly != true
        case .webhook: true
        case .runInTerminal: background == true
        default: false
        }
    }

    /// Every template in the step, with a plain name for messages.
    var templates: [String] {
        switch kind {
        case .openLink: [link ?? ""]
        case .waitForTextField, .pressKey: []
        case .openApp: (bundleId ?? "").isEmpty ? [text ?? ""] : []
        case .runWorkspace: workspaceId == nil ? [text ?? ""] : []
        case .typeText, .confirm: [text ?? ""]
        case .runInTerminal: [folder ?? "", argument ?? ""]
        case .runAppleShortcut:
            [text ?? ""] + [shortcutName, shortcutId].compactMap { Self.isTemplate($0) ? $0 : nil }
        case .webhook: []
        case .appendToFile: [text ?? ""]
        }
    }
}

// MARK: - Shortcuts

struct VoiceCommand: Codable, Equatable, Identifiable {
    var id: String
    /// What the list shows.
    var name: String
    /// The readable pattern, e.g. `WhatsApp {person:People} {message}`.
    var pattern: String
    /// The one text slot whose value goes through clean-up.
    var cleanUpSlot: String?
    var steps: [VoiceStep]
    var enabled: Bool
    /// The ready-made template this came from, if any.
    var templateId: String?
    /// Other ways the recognizer may spell the leading fixed words (the
    /// trigger). Matching accepts any of them exactly, after normalizing.
    var triggerAliases: [String]
    /// A keyboard shortcut that runs this command without speaking.
    var hotkey: WorkspaceHotkey?
    /// Other apps may start this through a `dictator://` link. Off unless the
    /// user turns it on for this command.
    var runsFromOtherApps: Bool
    /// Bundle identifiers this command is limited to. Empty means every app.
    var onlyInApps: [String]

    init(id: String = UUID().uuidString, name: String, pattern: String, cleanUpSlot: String? = nil,
         steps: [VoiceStep], enabled: Bool = true, templateId: String? = nil, triggerAliases: [String] = [],
         hotkey: WorkspaceHotkey? = nil, runsFromOtherApps: Bool = false, onlyInApps: [String] = []) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.cleanUpSlot = cleanUpSlot
        self.steps = steps
        self.enabled = enabled
        self.templateId = templateId
        self.triggerAliases = triggerAliases
        self.hotkey = hotkey
        self.runsFromOtherApps = runsFromOtherApps
        self.onlyInApps = onlyInApps
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, pattern, cleanUpSlot, steps, enabled, templateId, triggerAliases
        case hotkey, runsFromOtherApps, onlyInApps
    }

    /// `triggerAliases` is absent in settings saved before it existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        pattern = try c.decode(String.self, forKey: .pattern)
        cleanUpSlot = try c.decodeIfPresent(String.self, forKey: .cleanUpSlot)
        steps = try c.decode([VoiceStep].self, forKey: .steps)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        templateId = try c.decodeIfPresent(String.self, forKey: .templateId)
        triggerAliases = try c.decodeIfPresent([String].self, forKey: .triggerAliases) ?? []
        hotkey = try c.decodeIfPresent(WorkspaceHotkey.self, forKey: .hotkey)
        runsFromOtherApps = try c.decodeIfPresent(Bool.self, forKey: .runsFromOtherApps) ?? false
        onlyInApps = try c.decodeIfPresent([String].self, forKey: .onlyInApps) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(pattern, forKey: .pattern)
        try c.encodeIfPresent(cleanUpSlot, forKey: .cleanUpSlot)
        try c.encode(steps, forKey: .steps)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(templateId, forKey: .templateId)
        if !triggerAliases.isEmpty { try c.encode(triggerAliases, forKey: .triggerAliases) }
        try c.encodeIfPresent(hotkey, forKey: .hotkey)
        if runsFromOtherApps { try c.encode(runsFromOtherApps, forKey: .runsFromOtherApps) }
        if !onlyInApps.isEmpty { try c.encode(onlyInApps, forKey: .onlyInApps) }
    }
}

/// How a command was started, for the Mac's record of recent commands.
enum VoiceCommandTrigger: String, Codable {
    case voice, keyboard, otherApp, runAgain
}

/// The whole shared setting: `{ "version": 2, "lists": …, "shortcuts": … }`.
struct VoiceLaunchConfig: Codable, Equatable {
    static let currentVersion = 2
    static let maxCommands = 100
    static let maxLists = 20
    static let maxEntriesPerList = 500
    static let maxStepsPerCommand = 20
    static let maxTextLength = 2_000

    var version: Int = VoiceLaunchConfig.currentVersion
    var lists: [VoiceList] = []
    var commands: [VoiceCommand] = []

    private enum CodingKeys: String, CodingKey {
        case version, lists
        case commands = "shortcuts"
    }

    static let empty = VoiceLaunchConfig()

    func list(named name: String) -> VoiceList? {
        let wanted = VoiceLaunchText.normalizedWords(name)
        return lists.first { VoiceLaunchText.normalizedWords($0.name) == wanted }
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    /// `nil` when the text isn't a version 2 setting. Unset ("") is empty.
    static func decode(_ json: String) -> VoiceLaunchConfig? {
        if json.isEmpty { return .empty }
        guard let data = json.data(using: .utf8),
              let config = try? JSONDecoder().decode(VoiceLaunchConfig.self, from: data),
              config.version == currentVersion else { return nil }
        return config
    }
}

// MARK: - Text helpers

enum VoiceLaunchText {
    /// Spoken filler words that may be skipped at the start of a sentence.
    static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "ah", "oh", "okay", "ok", "so", "well",
        "אה", "אהה", "אמ", "אממ", "נו", "טוב",
    ]

    /// Hebrew prefix letters that a list entry's first word may carry when spoken.
    static let hebrewPrefixes: Set<String> = [
        "ו", "ה", "ב", "ל", "מ", "ש", "כ",
        "וה", "וב", "ול", "ומ", "וש", "שה", "שב", "של", "מה", "לה", "בה", "כש",
    ]

    /// True when every character in `word` is a Hebrew letter (U+05D0...U+05EA).
    static func isHebrewWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        return word.unicodeScalars.allSatisfy { $0.value >= 0x05D0 && $0.value <= 0x05EA }
    }

    /// Lowercased, punctuation stripped; nil when nothing is left.
    static func normalizedWord(_ token: String) -> String? {
        let kept = token.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let word = String(String.UnicodeScalarView(kept))
        return word.isEmpty ? nil : word
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { normalizedWord(String($0)) }
    }

    static let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    static func trimTrailingPunctuation(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, edgeCharacters.contains(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    static func trimLeadingPunctuation(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, edgeCharacters.contains(first) { scalars.removeFirst() }
        return String(String.UnicodeScalarView(scalars))
    }
}

// MARK: - Patterns

enum PatternPart: Equatable {
    case literal([String])
    case listSlot(name: String, list: String)
    case textSlot(name: String)
    case optional([PatternPart])
}

struct PatternError: Error, Equatable {
    var message: String
}

struct ParsedPattern: Equatable {
    struct Slot: Equatable {
        var name: String
        /// The list's name for a list slot; nil for a text slot.
        var list: String?
    }

    var parts: [PatternPart]

    var slots: [Slot] {
        var result: [Slot] = []
        func walk(_ parts: [PatternPart]) {
            for part in parts {
                switch part {
                case .literal: break
                case .listSlot(let name, let list): result.append(Slot(name: name, list: list))
                case .textSlot(let name): result.append(Slot(name: name, list: nil))
                case .optional(let group): walk(group)
                }
            }
        }
        walk(parts)
        return result
    }

    /// Every fixed word (for the speech recognizer's hints).
    var literalWords: [String] {
        var result: [String] = []
        func walk(_ parts: [PatternPart]) {
            for part in parts {
                switch part {
                case .literal(let words): result.append(contentsOf: words)
                case .optional(let group): walk(group)
                default: break
                }
            }
        }
        walk(parts)
        return result
    }

    /// What the matcher actually hears: the fixed words as spoken, and each
    /// slot as its kind (free text, or which list). Slot names don't count,
    /// so "YouTube {query}" and "YouTube {search}" have the same key.
    var matchingKey: String {
        func walk(_ parts: [PatternPart]) -> [String] {
            parts.map { part in
                switch part {
                case .literal(let words): words.compactMap(VoiceLaunchText.normalizedWord).joined(separator: " ")
                case .listSlot(_, let list): "{list:\(VoiceLaunchText.key(list))}"
                case .textSlot: "{text}"
                case .optional(let group): "[" + walk(group).joined(separator: " ") + "]"
                }
            }
        }
        return walk(parts).joined(separator: " ")
    }
}

enum VoicePattern {
    static func parse(_ text: String) -> Result<ParsedPattern, PatternError> {
        var top: [PatternPart] = []
        var group: [PatternPart] = []
        var inGroup = false
        var word = ""
        var failure: PatternError?

        func fail(_ message: String) { if failure == nil { failure = PatternError(message: message) } }
        func append(_ part: PatternPart) {
            if inGroup { group.append(part) } else { top.append(part) }
        }
        func flush() {
            guard !word.isEmpty else { return }
            defer { word = "" }
            guard VoiceLaunchText.normalizedWord(word) != nil else {
                fail("“\(word)” has no letters to say. Fixed words need letters or digits.")
                return
            }
            if inGroup, case .literal(let words)? = group.last {
                group[group.count - 1] = .literal(words + [word])
            } else if !inGroup, case .literal(let words)? = top.last {
                top[top.count - 1] = .literal(words + [word])
            } else {
                append(.literal([word]))
            }
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count, failure == nil {
            let c = chars[i]
            switch c {
            case _ where c.isWhitespace:
                flush()
            case "[":
                flush()
                if inGroup { fail("Optional parts [ ] can’t be inside each other.") }
                inGroup = true
                group = []
            case "]":
                flush()
                if !inGroup { fail("There is a ] without a [ before it.") }
                else if group.isEmpty { fail("An optional part [ ] can’t be empty.") }
                else { top.append(.optional(group)); inGroup = false; group = [] }
            case "{":
                flush()
                guard let close = chars[i...].firstIndex(of: "}") else { fail("A { is missing its }."); break }
                let body = String(chars[(i + 1)..<close]).trimmingCharacters(in: .whitespaces)
                i = close
                let pieces = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
                guard let name = pieces.first, isSlotName(name) else {
                    fail("A slot name can only use letters, digits and _, like {message}.")
                    break
                }
                if pieces.count == 2 {
                    if pieces[1].isEmpty { fail("{\(name):…} needs the name of a list after the colon.") }
                    else { append(.listSlot(name: name, list: pieces[1])) }
                } else {
                    append(.textSlot(name: name))
                }
            case "}":
                fail("There is a } without a { before it.")
            default:
                word.append(c)
            }
            i += 1
        }
        flush()
        if inGroup, failure == nil { fail("An optional part [ is missing its ].") }
        if let failure { return .failure(failure) }
        return check(ParsedPattern(parts: top))
    }

    private static func isSlotName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }

    /// The structural rules a pattern must follow.
    private static func check(_ pattern: ParsedPattern) -> Result<ParsedPattern, PatternError> {
        guard case .literal? = pattern.parts.first else {
            return .failure(PatternError(message: "A pattern must start with a word you say, like “WhatsApp”."))
        }
        var names = Set<String>()
        for slot in pattern.slots where !names.insert(slot.name.lowercased()).inserted {
            return .failure(PatternError(message: "The name {\(slot.name)} is used twice. Each slot needs its own name."))
        }
        func endMarkers(_ parts: [PatternPart], endsPattern: Bool) -> PatternError? {
            for (index, part) in parts.enumerated() {
                switch part {
                case .textSlot(let name):
                    let isLast = index == parts.count - 1
                    if isLast {
                        if !endsPattern {
                            return PatternError(message: "{\(name)} needs a word after it to show where it ends. Put a fixed word before the ] or move the optional part to the end.")
                        }
                    } else if case .literal = parts[index + 1] {
                        continue
                    } else {
                        return PatternError(message: "{\(name)} needs a fixed word right after it, so Dictator knows where it ends.")
                    }
                case .optional(let group):
                    if let error = endMarkers(group, endsPattern: endsPattern && index == parts.count - 1) { return error }
                default: break
                }
            }
            return nil
        }
        if let error = endMarkers(pattern.parts, endsPattern: true) { return .failure(error) }
        return .success(pattern)
    }
}

// MARK: - Templates

/// `{slot}` and `{slot.field}` references in a step's text.
enum VoiceTemplate {
    enum Segment: Equatable {
        case text(String)
        case reference(slot: String, field: String?)
        case invalid(String)
    }

    static func segments(_ template: String) -> [Segment] {
        var result: [Segment] = []
        var literal = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                guard let close = chars[i...].firstIndex(of: "}") else {
                    result.append(.invalid(String(chars[i...])))
                    literal = ""
                    i = chars.count
                    continue
                }
                if !literal.isEmpty { result.append(.text(literal)); literal = "" }
                let body = String(chars[(i + 1)..<close])
                let pieces = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if pieces.count >= 1, !pieces[0].isEmpty, pieces.allSatisfy({ !$0.isEmpty }),
                   pieces.allSatisfy({ $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" } }) {
                    result.append(.reference(slot: pieces[0], field: pieces.count == 2 ? pieces[1] : nil))
                } else {
                    result.append(.invalid("{" + body + "}"))
                }
                i = close + 1
            } else {
                literal.append(chars[i])
                i += 1
            }
        }
        if !literal.isEmpty { result.append(.text(literal)) }
        return result
    }
}

// MARK: - Validation

extension VoiceLaunchConfig {
    static let terminalCommandAllowed = try! NSRegularExpression(pattern: "^[A-Za-z0-9_./=:@+, -]+\\z")
    static let defaultAgentCommand = "claude"

    /// A line of log text is harmless in a note and a command in `~/.zshrc`.
    /// Checked on the resolved path, again at run time, since a spoken word
    /// can fill in the path and a link can lead anywhere: no hidden files or
    /// folders, nothing in Library, nothing belonging to the system.
    static func isAppendablePath(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        if (resolved as NSString).pathComponents.contains(where: { $0.hasPrefix(".") }) { return false }
        let library = URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/Library/"
        return !([library] + ["/etc/", "/private/etc/", "/System/", "/Library/", "/usr/", "/bin/", "/sbin/"]).contains { resolved.hasPrefix($0) }
    }

    /// A plain-words reason this setting can't be saved, or nil.
    func validate(allowedSchemes: [String] = VoiceCommandCatalog.shared.allowedLinkSchemes) -> String? {
        guard commands.count <= Self.maxCommands else { return "You can have up to \(Self.maxCommands) commands." }
        guard lists.count <= Self.maxLists else { return "You can have up to \(Self.maxLists) lists." }
        var listNames = Set<String>()
        for list in lists {
            let name = VoiceLaunchText.normalizedWords(list.name).joined(separator: " ")
            guard !name.isEmpty else { return "Every list needs a name." }
            guard listNames.insert(name).inserted else { return "There are two lists called “\(list.name)”." }
            guard list.entries.count <= Self.maxEntriesPerList else { return "“\(list.name)” is limited to \(Self.maxEntriesPerList) entries." }
            var fields = Set<String>()
            for field in list.fields {
                guard !field.isEmpty, field.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else {
                    return "Field names in “\(list.name)” can only use letters, digits and _."
                }
                guard fields.insert(field.lowercased()).inserted else { return "“\(list.name)” has the field “\(field)” twice." }
            }
            for entry in list.entries {
                guard entry.names.contains(where: { !VoiceLaunchText.normalizedWords($0).isEmpty }) else {
                    return "Every entry in “\(list.name)” needs a name to say."
                }
                guard entry.names.allSatisfy({ $0.count <= 100 }), entry.values.values.allSatisfy({ $0.count <= Self.maxTextLength }) else {
                    return "An entry in “\(list.name)” is too long."
                }
            }
        }
        var keys = Set<WorkspaceHotkey>()
        for command in commands {
            if let key = command.hotkey, !keys.insert(key).inserted {
                return "Two commands cannot share a keyboard shortcut."
            }
        }
        var patterns: [String: [VoiceCommand]] = [:]
        for voiceCommand in commands {
            if let problem = validate(voiceCommand, allowedSchemes: allowedSchemes) { return problem }
            guard case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern) else { continue }
            let key = parsed.matchingKey
            if let other = patterns[key]?.first(where: { voiceCommand.appScopeClashes(with: $0) }) { return Self.samePatternProblem(voiceCommand, other) }
            patterns[key, default: []].append(voiceCommand)
        }
        return nil
    }

    /// Two shortcuts that would hear the same words: the matcher can't pick
    /// one, so neither would ever run. Names both and gives an example.
    static func samePatternProblem(_ voiceCommand: VoiceCommand, _ other: VoiceCommand) -> String {
        let name = voiceCommand.name.isEmpty ? voiceCommand.pattern : voiceCommand.name
        let otherName = other.name.isEmpty ? other.pattern : other.name
        return "“\(name)” listens for the same words as “\(otherName)” (“\(other.pattern)”), so neither could run. Change the fixed words of one of them."
    }

    func validate(_ voiceCommand: VoiceCommand, allowedSchemes: [String] = VoiceCommandCatalog.shared.allowedLinkSchemes) -> String? {
        let name = voiceCommand.name.isEmpty ? voiceCommand.pattern : voiceCommand.name
        guard !voiceCommand.name.trimmingCharacters(in: .whitespaces).isEmpty else { return "Every command needs a name." }
        if let problem = voiceCommand.appScopeProblem { return problem }
        if let problem = triggerAliasProblem(in: voiceCommand) { return problem }
        guard voiceCommand.pattern.count <= 300 else { return "The pattern for “\(name)” is too long." }
        let parsed: ParsedPattern
        switch VoicePattern.parse(voiceCommand.pattern) {
        case .failure(let error): return "“\(name)”: \(error.message)"
        case .success(let value): parsed = value
        }
        if let key = voiceCommand.hotkey {
            guard key.isValid else { return "Choose a keyboard shortcut with at least two of ⌃ ⌥ ⌘ and a regular key." }
            guard !VoiceCommandWithoutSpeech.needsSpokenWords(voiceCommand) else {
                return "A command that needs spoken words cannot have a keyboard shortcut."
            }
        }
        let slots = parsed.slots
        for slot in slots {
            if let listName = slot.list, list(named: listName) == nil {
                return "“\(name)” uses the list “\(listName)”, which doesn’t exist."
            }
        }
        if let cleanUp = voiceCommand.cleanUpSlot {
            guard let slot = slots.first(where: { $0.name == cleanUp }), slot.list == nil else {
                return "“\(name)” cleans up {\(cleanUp)}, which isn’t a text slot in its pattern."
            }
        }
        guard !voiceCommand.steps.isEmpty else { return "“\(name)” needs at least one step." }
        guard voiceCommand.steps.count <= Self.maxStepsPerCommand else { return "“\(name)” is limited to \(Self.maxStepsPerCommand) steps." }

        var confirmed = false
        var earlier = Set<String>()
        let allAnswers = Set(voiceCommand.steps.filter { $0.kind == .runAppleShortcut }.map(\.answerKey))
        for step in voiceCommand.steps {
            if step.isActing && !confirmed {
                return "“\(name)” has an action that sends or does something for real. Put “Wait for me to cancel” before it."
            }
            if let problem = validate(step, of: name, slots: slots, allowedSchemes: allowedSchemes,
                                      answers: (earlier, allAnswers.subtracting(earlier))) { return problem }
            if step.kind == .confirm { confirmed = true }
            if step.kind == .runAppleShortcut { earlier.insert(step.answerKey) }
        }
        return nil
    }

    /// `answers.earlier`: answers of Shortcuts that run before this step.
    /// `answers.later`: answers of this step and the ones after it.
    private func validate(_ step: VoiceStep, of name: String, slots: [ParsedPattern.Slot], allowedSchemes: [String],
                          answers: (earlier: Set<String>, later: Set<String>)) -> String? {
        func text(_ value: String?, _ what: String) -> String? {
            let value = value ?? ""
            guard value.count <= Self.maxTextLength else { return "The \(what) in “\(name)” is too long." }
            return nil
        }
        // References must name a slot (and, with a field, a list slot that has it).
        for template in step.templates {
            if let problem = text(template, "text") { return problem }
            for segment in VoiceTemplate.segments(template) {
                switch segment {
                case .text: break
                case .invalid(let raw): return "“\(name)” has “\(raw)”, which isn’t a slot. Use {slot} or {slot.field}."
                case .reference(let slotName, let field):
                    guard let slot = slots.first(where: { $0.name == slotName }) else {
                        if slotName.hasPrefix(VoiceStep.answerPrefix) {
                            if answers.earlier.contains(slotName) { continue }
                            if answers.later.contains(slotName) { return "“\(name)” uses an answer before the Apple Shortcut that gives it has run." }
                        }
                        return "“\(name)” uses {\(slotName)}, which isn’t in its pattern."
                    }
                    if let field {
                        guard let listName = slot.list, let list = list(named: listName), list.fields.contains(field) else {
                            return "“\(name)” uses {\(slotName).\(field)}, but that slot has no field called “\(field)”."
                        }
                    }
                }
            }
        }
        switch step.kind {
        case .openLink:
            let template = (step.link ?? "").trimmingCharacters(in: .whitespaces)
            guard let colon = template.firstIndex(of: ":"), !template[..<colon].contains("{") else {
                return "The web address in “\(name)” must start with a scheme like https://."
            }
            let scheme = template[..<colon].lowercased()
            guard allowedSchemes.contains(scheme) else {
                return "The web address in “\(name)” must start with one of: \(allowedSchemes.map { $0 + ":" }.joined(separator: " "))"
            }
        case .openApp:
            guard !(step.bundleId ?? "").trimmingCharacters(in: .whitespaces).isEmpty || !(step.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "“\(name)” needs an app to open." }
            if let problem = text(step.bundleId, "app") { return problem }
        case .runWorkspace:
            if let id = step.workspaceId {
                guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.count <= Self.maxTextLength else { return "“\(name)” needs a saved routine." }
            } else {
                guard !(step.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "“\(name)” needs a routine name." }
            }
        case .waitForTextField:
            if let seconds = step.seconds, !(1...60).contains(seconds) { return "The wait in “\(name)” must be between 1 and 60 seconds." }
        case .typeText:
            break
        case .pressKey:
            guard let key = step.key, VoiceStep.keys.contains(key) else { return "“\(name)” needs a key to press: Return, ⌘Return, Tab or Escape." }
        case .runInTerminal:
            let folder = (step.folder ?? "").trimmingCharacters(in: .whitespaces)
            guard folder.hasPrefix("/") || folder.hasPrefix("~") || folder.hasPrefix("{") else { return "Choose a folder for “\(name)”." }
            let command = (step.command ?? "").trimmingCharacters(in: .whitespaces)
            if step.background == true {
                guard !command.isEmpty else { return "The background action in “\(name)” needs a command." }
                if let seconds = step.timeoutSeconds, !VoiceStep.backgroundTimeoutAllowed(seconds) {
                    return "The command time limit in “\(name)” must be between 1 and 600 seconds."
                }
            }
            if !command.isEmpty {
                let range = NSRange(command.startIndex..., in: command)
                guard command.count <= 200, Self.terminalCommandAllowed.firstMatch(in: command, range: range) != nil else {
                    return "The command for “\(name)” can only use letters, numbers and simple punctuation."
                }
            }
        case .confirm:
            guard !(step.text ?? "").isEmpty else { return "The question in “\(name)” needs some text." }
            if let seconds = step.seconds, !(1...30).contains(seconds) { return "The pause in “\(name)” must be between 1 and 30 seconds." }
        case .runAppleShortcut:
            let shortcutName = (step.shortcutName ?? "").trimmingCharacters(in: .whitespaces)
            guard !shortcutName.isEmpty, shortcutName.count <= 200 else { return "“\(name)” needs the name of an Apple Shortcut." }
            guard !shortcutName.hasPrefix("-") || VoiceStep.isTemplate(shortcutName) else { return "The Apple Shortcut in “\(name)” can’t start with a dash." }
            if let mode = step.inputMode, mode != VoiceStep.inputJSON, mode != VoiceStep.inputText { return "“\(name)” has an unknown way of giving input." }
            if let id = step.shortcutId, !id.isEmpty, !VoiceStep.isTemplate(id), !VoiceShortcutList.isIdentifier(id) { return "The Apple Shortcut in “\(name)” has an invalid identifier." }
            if let seconds = step.timeoutSeconds, !VoiceStep.shortcutTimeoutChoices.contains(seconds) {
                return "The time limit for the Apple Shortcut in “\(name)” must be 10, 30, 60 or 120 seconds."
            }
            if let details = step.answerDetails {
                guard details.count <= 20, details.allSatisfy({ !$0.isEmpty && $0.count <= 50 && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" } }) else {
                    return "The parts of the answer in “\(name)” can only use letters, digits and _."
                }
            }
        case .webhook:
            let link = (step.link ?? "").lowercased()
            guard (link.hasPrefix("https://") || link.hasPrefix("http://")), URL(string: step.link ?? "") != nil, link.count <= Self.maxTextLength else {
                return "The web address to send to in “\(name)” must start with https:// or http://."
            }
        case .appendToFile:
            let path = (step.path ?? "").trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") || path.hasPrefix("~"), path.count <= 1_000 else { return "Choose a file for “\(name)”." }
            guard Self.isAppendablePath(path) else { return "“\(name)” can’t add to that file: your Mac or its apps run or depend on it." }
        }
        return nil
    }
}


extension VoiceCommand {
    static let maxApps = 20

    func matchesApp(_ bundleID: String?) -> Bool {
        onlyInApps.isEmpty || bundleID.map(onlyInApps.contains) == true
    }

    /// A scoped command wins over a global command, so that pair is not a tie.
    func appScopeClashes(with other: VoiceCommand) -> Bool {
        if onlyInApps.isEmpty || other.onlyInApps.isEmpty { return onlyInApps.isEmpty && other.onlyInApps.isEmpty }
        return !Set(onlyInApps).isDisjoint(with: other.onlyInApps)
    }

    var appScopeProblem: String? {
        guard onlyInApps.count <= Self.maxApps else { return "Choose at most 20 apps for a command." }
        guard onlyInApps.allSatisfy({
            $0.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z"#, options: .regularExpression) != nil
        }) else { return "Choose an app with a valid app identifier." }
        return nil
    }
}
