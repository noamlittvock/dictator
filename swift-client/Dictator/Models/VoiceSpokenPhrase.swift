import Foundation

// The words of a spoken sentence, split by what each part does, so every
// screen can show them the same way: the start word, a person or project
// ("who" / "which"), and the person's own words. Pure functions of
// a pattern and either a sentence or the values a plan filled in.

enum PhraseRole: Equatable {
    /// The shortcut's leading words: "WhatsApp".
    case opens
    /// A person from the People list.
    case who
    /// A name from any other list, like a project.
    case which
    /// What the person says freely: a message or a search.
    case words
    /// Fixed words in the middle of a sentence ("subject"). Not coloured.
    case plain
}

struct PhraseSegment: Equatable {
    var text: String
    var role: PhraseRole
    /// The caption under the pill: "start word", "who", "project", "shortcut",
    /// "which", "your message", "search".
    var label: String?

    static func opens(_ text: String) -> PhraseSegment { .init(text: text, role: .opens, label: "start word") }
    static func who(_ text: String) -> PhraseSegment { .init(text: text, role: .who, label: "who") }

    /// The symbol inside a who / which pill, so colour is never the only clue.
    var symbol: String? {
        switch role {
        case .who: "person.fill"
        case .which:
            switch label {
            case "project": "folder.fill"
            case "shortcut": "square.2.layers.3d"
            default: "list.bullet"
            }
        case .opens, .words, .plain: nil
        }
    }
}

enum SpokenPhrase {
    // MARK: Roles and captions

    static func isPeople(_ listName: String) -> Bool { VoiceLaunchText.normalizedWords(listName) == ["people"] }

    static func listSegment(_ text: String, listName: String) -> PhraseSegment {
        let words = VoiceLaunchText.normalizedWords(listName)
        if words == ["people"] { return PhraseSegment(text: text, role: .who, label: "who") }
        if words == VoiceLaunchText.normalizedWords(VoiceCards.projectsList) { return PhraseSegment(text: text, role: .which, label: "project") }
        if words == VoiceLaunchText.normalizedWords(VoiceCards.shortcutsList) { return PhraseSegment(text: text, role: .which, label: "shortcut") }
        return PhraseSegment(text: text, role: .which, label: "which")
    }

    /// "search" for a slot named query or search, else "your message".
    static func wordsLabel(forSlot name: String) -> String {
        ["query", "search"].contains(name.lowercased()) ? "search" : "your message"
    }

    static func wordsSegment(_ text: String, slot: String) -> PhraseSegment {
        PhraseSegment(text: text, role: .words, label: wordsLabel(forSlot: slot))
    }

    // MARK: From the values a plan filled in

    /// The sentence a plan stands for, in pattern order. Parts with no value
    /// (including a whole optional group) are left out.
    static func segments(pattern: String, values: [String: String]) -> [PhraseSegment] {
        guard case .success(let parsed) = VoicePattern.parse(pattern) else { return [] }
        var result: [PhraseSegment] = []
        func has(_ part: PatternPart) -> Bool {
            switch part {
            case .literal: return false
            case .listSlot(let name, _), .textSlot(let name): return !(values[name] ?? "").isEmpty
            case .optional(let group): return group.contains(where: has)
            }
        }
        func walk(_ parts: [PatternPart], top: Bool) {
            for (index, part) in parts.enumerated() {
                switch part {
                case .literal(let words):
                    let text = words.joined(separator: " ")
                    result.append(top && index == 0 ? .opens(text) : PhraseSegment(text: text, role: .plain, label: nil))
                case .listSlot(let name, let list):
                    if let value = values[name], !value.isEmpty { result.append(listSegment(value, listName: list)) }
                case .textSlot(let name):
                    if let value = values[name], !value.isEmpty { result.append(wordsSegment(value, slot: name)) }
                case .optional(let group):
                    if group.contains(where: has) { walk(group, top: false) }
                }
            }
        }
        walk(parsed.parts, top: true)
        return result
    }

    static func segments(for plan: VoiceLaunchPlan, pattern: String) -> [PhraseSegment] {
        segments(pattern: pattern, values: Dictionary(plan.slots.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }))
    }

    // MARK: From a sentence

    /// Lines a sentence up with a pattern. List slots take the longest name
    /// in the list that fits, else one word; a text slot takes everything up
    /// to the next fixed word, or the rest.
    static func segments(pattern: String, sentence: String, config: VoiceLaunchConfig) -> [PhraseSegment] {
        guard case .success(let parsed) = VoicePattern.parse(pattern) else { return [] }
        let tokens = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        var pos = 0
        var result: [PhraseSegment] = []

        func matches(_ words: [String], at start: Int) -> Bool {
            let expected = words.compactMap(VoiceLaunchText.normalizedWord)
            guard start + expected.count <= tokens.count else { return false }
            return expected.indices.allSatisfy { VoiceLaunchText.normalizedWord(tokens[start + $0]) == expected[$0] }
        }
        func nextMarker(_ parts: [PatternPart], after index: Int) -> [String]? {
            if index + 1 < parts.count, case .literal(let words) = parts[index + 1] { return words }
            return nil
        }
        /// Where the words before `marker` end, at least one word long.
        func end(before marker: [String]?) -> Int {
            guard let marker else { return tokens.count }
            var stop = pos + 1
            while stop < tokens.count {
                if matches(marker, at: stop) { return stop }
                stop += 1
            }
            return tokens.count
        }
        func walk(_ parts: [PatternPart], top: Bool) {
            for (index, part) in parts.enumerated() {
                guard pos < tokens.count else { return }
                switch part {
                case .literal(let words):
                    let count = min(words.count, tokens.count - pos)
                    let text = tokens[pos..<pos + count].joined(separator: " ")
                    pos += count
                    result.append(top && index == 0 ? .opens(text) : PhraseSegment(text: text, role: .plain, label: nil))
                case .optional(let group):
                    if case .literal(let words)? = group.first, matches(words, at: pos) { walk(group, top: false) }
                case .listSlot(_, let listName):
                    var length = 0
                    for entry in config.list(named: listName)?.entries ?? [] {
                        for name in entry.names {
                            let words = VoiceLaunchText.normalizedWords(name)
                            if !words.isEmpty, matches(words, at: pos) { length = max(length, words.count) }
                        }
                    }
                    if length == 0 { length = 1 }
                    result.append(listSegment(tokens[pos..<pos + length].joined(separator: " "), listName: listName))
                    pos += length
                case .textSlot(let name):
                    let stop = end(before: nextMarker(parts, after: index))
                    result.append(wordsSegment(tokens[pos..<stop].joined(separator: " "), slot: name))
                    pos = stop
                }
            }
        }
        walk(parsed.parts, top: true)
        return result
    }

    // MARK: A near miss

    /// What was heard, with the unknown name as "norm?" in the who / which
    /// pill. Empty for a near miss on the opening words, which has no sentence to show.
    static func segments(for miss: VoiceNearMiss, config: VoiceLaunchConfig) -> [PhraseSegment] {
        guard miss.kind == .entry, let voiceCommand = config.commands.first(where: { $0.id == miss.commandId }) else { return [] }
        let tokens = miss.transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        let normalized = tokens.map { VoiceLaunchText.normalizedWord($0) ?? "" }
        let variants = [voiceCommand.triggerWords.compactMap(VoiceLaunchText.normalizedWord)]
            + voiceCommand.triggerAliases.map(VoiceLaunchText.normalizedWords)
        let lead = variants.first { !$0.isEmpty && $0.count <= tokens.count && Array(normalized.prefix($0.count)) == $0 }?.count
            ?? max(1, voiceCommand.triggerWords.count)
        let heard = miss.heardSpans.first ?? ""
        let heardCount = max(1, heard.split(whereSeparator: \.isWhitespace).count)
        guard lead < tokens.count else { return [.opens(tokens.joined(separator: " "))] }
        var result = [PhraseSegment.opens(tokens[0..<lead].joined(separator: " "))]
        result.append(listSegment("\(heard)?", listName: miss.listName ?? "People"))
        let restStart = min(tokens.count, lead + heardCount)
        if restStart < tokens.count {
            var slot = "message"
            if case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern), let text = parsed.slots.first(where: { $0.list == nil }) { slot = text.name }
            result.append(wordsSegment(tokens[restStart...].joined(separator: " "), slot: slot))
        }
        return result
    }
}
