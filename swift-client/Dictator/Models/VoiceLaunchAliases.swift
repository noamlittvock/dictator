import Foundation

// Aliases: other spellings the speech recognizer may produce for a name in a
// list or for the first words of a shortcut. They are exact, normalized
// matches. Nothing here guesses at runtime; edit distance is only ever used
// to order suggestions the user then clicks.

extension VoiceLaunchText {
    /// Words as spoken with their edge punctuation trimmed, lowercased.
    /// "Norm, hi." gives ["norm", "hi"]. Words with no letters are skipped.
    static func heardWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let trimmed = trimLeadingPunctuation(trimTrailingPunctuation(String(raw)))
            return normalizedWord(trimmed) == nil ? nil : trimmed.lowercased()
        }
    }

    /// What two spellings are compared by.
    static func key(_ text: String) -> String { normalizedWords(text).joined(separator: " ") }

    /// Simple edit distance between two strings (insert, delete, replace).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }
}

/// Why a spelling can't be added, in plain words.
enum AliasProblem: Equatable, Error {
    case empty
    /// Already one of this entry's or shortcut's own ways of being said.
    case alreadyKnown
    /// Belongs to another entry in the same list.
    case takenByEntry(String)
    /// Is the start of another shortcut.
    case takenByVoiceCommand(String)

    var message: String {
        switch self {
        case .empty: "There is nothing to say here."
        case .alreadyKnown: "Dictator already knows this one."
        case .takenByEntry(let name): "Already how you say “\(name)”, so it can’t mean anyone else."
        case .takenByVoiceCommand(let name): "Already how “\(name)” starts, so it can’t be another way to say this."
        }
    }
}

// MARK: - Shortcut triggers

extension VoiceCommand {
    /// The leading fixed words of the pattern, as written.
    var triggerWords: [String] {
        guard case .success(let parsed) = VoicePattern.parse(pattern), case .literal(let words)? = parsed.parts.first else { return [] }
        return words
    }

    /// The trigger and its aliases, each as a comparison key.
    var triggerKeys: [String] {
        ([triggerWords.joined(separator: " ")] + triggerAliases).map(VoiceLaunchText.key).filter { !$0.isEmpty }
    }
}

extension VoiceLaunchConfig {
    /// A plain reason when one of this shortcut's aliases is empty or equals
    /// another shortcut's trigger or alias (the shortcut itself is skipped).
    func triggerAliasProblem(in voiceCommand: VoiceCommand) -> String? {
        for alias in voiceCommand.triggerAliases {
            if let problem = triggerProblem(alias, forVoiceCommand: voiceCommand.id, in: commands.filter { $0.id != voiceCommand.id && voiceCommand.appScopeClashes(with: $0) }) {
                if problem == .alreadyKnown { continue }
                return "“\(alias)” can’t be another way to say “\(voiceCommand.name)”. \(problem.message)"
            }
        }
        return nil
    }

    /// Checks `alias` against the other shortcuts' triggers and aliases.
    /// `others` must not include the shortcut being changed.
    func triggerProblem(_ alias: String, forVoiceCommand id: String, in others: [VoiceCommand]) -> AliasProblem? {
        let key = VoiceLaunchText.key(alias)
        guard !key.isEmpty else { return .empty }
        for other in others where other.id != id && other.triggerKeys.contains(key) { return .takenByVoiceCommand(other.name) }
        return nil
    }

    /// Adds a spelling of the shortcut's trigger. Fails, changing nothing,
    /// when it is empty, already known, or another shortcut's.
    @discardableResult
    mutating func addTriggerAlias(_ alias: String, toVoiceCommand id: String) -> AliasProblem? {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return .empty }
        let status = VoiceTeach.triggerStatus(alias, commandId: id, in: commands)
        switch status {
        case .fresh: break
        case .sameAsName: return .alreadyKnown
        case .conflict(let problem): return problem
        }
        commands[index].triggerAliases.append(alias.trimmingCharacters(in: .whitespacesAndNewlines))
        return nil
    }

    /// Adds a spelling of an entry's name. Fails, changing nothing, when it
    /// is empty, already known, or another entry's in the same list.
    @discardableResult
    mutating func addEntryAlias(_ alias: String, listId: String, entryId: String) -> AliasProblem? {
        guard let listIndex = lists.firstIndex(where: { $0.id == listId }),
              let entryIndex = lists[listIndex].entries.firstIndex(where: { $0.id == entryId }) else { return .empty }
        switch VoiceTeach.entryStatus(alias, entryId: entryId, in: lists[listIndex]) {
        case .fresh: break
        case .sameAsName: return .alreadyKnown
        case .conflict(let problem): return problem
        }
        lists[listIndex].entries[entryIndex].names.append(alias.trimmingCharacters(in: .whitespacesAndNewlines))
        return nil
    }
}

// MARK: - Teach

/// What a heard spelling would do if saved.
enum VoiceAliasStatus: Equatable {
    /// A new spelling that can be saved.
    case fresh
    /// The same as a way it is already said (or the name itself).
    case sameAsName
    /// Belongs to something else; can't be saved.
    case conflict(AliasProblem)
}

/// What a Teach sheet is teaching.
enum VoiceTeachTarget: Equatable {
    case entry(list: VoiceList, entryId: String)
    /// `shortcuts` holds the whole set with the one being edited as it is now.
    case trigger(commandId: String, commands: [VoiceCommand])
}

/// What to say for a take, and the words the phrase starts with.
struct VoiceTeachPhrase: Equatable {
    var text: String
    /// The fixed words before the name, as written ("WhatsApp"); empty when
    /// the phrase is just the name.
    var leadingWords: [String]
}

/// What one take gave.
enum VoiceTeachHeard: Equatable {
    /// The words at the name's place (or the whole trigger phrase).
    case alias(String)
    /// The fixed words weren't recognized, so the user says which words are
    /// the name. Every word heard, in order.
    case chooseWords([String])
    case nothing
}

enum VoiceTeach {
    static let takeCount = 4

    // MARK: Phrases

    /// A real phrase for an entry: the first shortcut that uses this list
    /// gives its fixed words up to the name ("WhatsApp Noam"). With none,
    /// just the name.
    static func phrase(for entry: VoiceListEntry, in list: VoiceList, config: VoiceLaunchConfig) -> VoiceTeachPhrase {
        let name = entry.displayName
        let wanted = VoiceLaunchText.normalizedWords(list.name)
        for voiceCommand in config.commands {
            guard case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern) else { continue }
            var lead: [String] = []
            parts: for part in parsed.parts {
                switch part {
                case .literal(let words): lead += words
                case .optional: continue
                case .textSlot: break parts
                case .listSlot(_, let listName):
                    if VoiceLaunchText.normalizedWords(listName) == wanted {
                        return VoiceTeachPhrase(text: (lead + [name]).joined(separator: " "), leadingWords: lead)
                    }
                    break parts
                }
            }
        }
        return VoiceTeachPhrase(text: name, leadingWords: [])
    }

    /// The phrase for a trigger is the trigger itself.
    static func phrase(forTrigger voiceCommand: VoiceCommand) -> VoiceTeachPhrase {
        let words = voiceCommand.triggerWords
        return VoiceTeachPhrase(text: words.joined(separator: " "), leadingWords: words)
    }

    // MARK: Extraction

    /// What a take's transcript says about an entry: the words after the
    /// phrase's fixed words when those were heard right; otherwise the
    /// whole transcript, for the user to pick the name from.
    static func heardForEntry(_ transcript: String, phrase: VoiceTeachPhrase) -> VoiceTeachHeard {
        let all = VoiceLaunchText.heardWords(transcript)
        guard !all.isEmpty else { return .nothing }
        let lead = phrase.leadingWords.compactMap(VoiceLaunchText.normalizedWord)
        let heard = all.compactMap(VoiceLaunchText.normalizedWord)
        if lead.isEmpty { return .alias(all.joined(separator: " ")) }
        if heard.count > lead.count, Array(heard.prefix(lead.count)) == lead {
            return .alias(all.dropFirst(lead.count).joined(separator: " "))
        }
        return .chooseWords(all)
    }

    /// For a trigger, everything heard is the candidate.
    static func heardForTrigger(_ transcript: String) -> VoiceTeachHeard {
        let all = VoiceLaunchText.heardWords(transcript)
        return all.isEmpty ? .nothing : .alias(all.joined(separator: " "))
    }

    /// The words picked (by position) from a transcript, in order.
    static func alias(from words: [String], selected: Set<Int>) -> String {
        words.enumerated().filter { selected.contains($0.offset) }.map(\.element).joined(separator: " ")
    }

    // MARK: Status

    static func entryStatus(_ alias: String, entryId: String, in list: VoiceList) -> VoiceAliasStatus {
        let key = VoiceLaunchText.key(alias)
        guard !key.isEmpty else { return .conflict(.empty) }
        for entry in list.entries where entry.names.contains(where: { VoiceLaunchText.key($0) == key }) {
            return entry.id == entryId ? .sameAsName : .conflict(.takenByEntry(entry.displayName))
        }
        return .fresh
    }

    static func triggerStatus(_ alias: String, commandId: String, in commands: [VoiceCommand]) -> VoiceAliasStatus {
        let key = VoiceLaunchText.key(alias)
        guard !key.isEmpty else { return .conflict(.empty) }
        let scope = commands.first { $0.id == commandId }
        for voiceCommand in commands where voiceCommand.triggerKeys.contains(key) && (scope?.appScopeClashes(with: voiceCommand) ?? true) {
            return voiceCommand.id == commandId ? .sameAsName : .conflict(.takenByVoiceCommand(voiceCommand.name))
        }
        return .fresh
    }

    static func status(_ alias: String, target: VoiceTeachTarget) -> VoiceAliasStatus {
        switch target {
        case .entry(let list, let entryId): entryStatus(alias, entryId: entryId, in: list)
        case .trigger(let id, let commands): triggerStatus(alias, commandId: id, in: commands)
        }
    }

    /// The distinct spellings the takes gave, in the order first heard, each
    /// with what saving it would do. Duplicates (by normalized text) merge.
    static func candidates(from aliases: [String], target: VoiceTeachTarget) -> [(alias: String, status: VoiceAliasStatus)] {
        var seen = Set<String>()
        var result: [(String, VoiceAliasStatus)] = []
        for alias in aliases {
            let key = VoiceLaunchText.key(alias)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append((alias, status(alias, target: target)))
        }
        return result
    }
}
