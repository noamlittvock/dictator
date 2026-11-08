import Foundation

// A near miss: nothing ran, but the words were close. Either a shortcut's
// fixed words matched and a name in one of its lists wasn't recognized
// ("WhatsApp norm ..."), or no shortcut matched at all. The engine reports
// what it saw; suggestions are ordered by edit distance but only ever
// offered, never applied without a click.

struct VoiceNearMiss: Codable, Equatable {
    enum Kind: String, Codable { case entry, trigger }

    struct Candidate: Codable, Equatable {
        var entryId: String
        var name: String
    }

    var kind: Kind
    /// Everything that was said, as heard.
    var transcript: String

    // Entry near miss: which shortcut, which slot, what was heard there.
    var commandId: String?
    var commandName: String?
    var slotName: String?
    var listId: String?
    var listName: String?
    /// The words heard at the slot for each span the user may choose; the
    /// first is the default. A second (two words) is offered only when the
    /// slot is followed by a text slot, where the name's end is unclear.
    var heardSpans: [String] = []
    /// Up to three entries of the list, closest first, for the default span.
    var candidates: [Candidate] = []

    // Trigger near miss: what the first words were.
    var heardTrigger: String?
    /// Eligible commands, decided on the main Mac without retaining the app.
    /// Absent on older messages, whose suggestions can only use global commands.
    var eligibleCommandIDs: [String]? = nil

    var heard: String { kind == .entry ? (heardSpans.first ?? "") : (heardTrigger ?? "") }

    private enum CodingKeys: String, CodingKey {
        case kind, transcript, slotName, listId, listName, heardSpans, candidates, heardTrigger, eligibleCommandIDs
        case commandId = "shortcutId"
        case commandName = "shortcutName"
    }

}

extension VoiceLaunchEngine {
    static let maxNearMissCandidates = 3
    static let maxHeardNameWords = 3

    /// The near miss for words no shortcut matched, or nil.
    static func nearMiss(for transcript: String, in config: VoiceLaunchConfig, frontmostAppBundleID: String? = nil) -> VoiceNearMiss? {
        let tokens = tokenize(transcript)
        guard !tokens.isEmpty else { return nil }
        let enabled = config.commands.filter { $0.enabled && $0.matchesApp(frontmostAppBundleID) }
        guard !enabled.isEmpty else { return nil }

        var best: (score: Int, miss: VoiceNearMiss)?
        // Prefer an app-specific suggestion when the missing name fits both
        // it and the global fallback equally well.
        let ordered = enabled.filter { !$0.onlyInApps.isEmpty } + enabled.filter { $0.onlyInApps.isEmpty }
        for voiceCommand in ordered {
            guard case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern),
                  let found = entryMiss(parsed, voiceCommand: voiceCommand, tokens: tokens, transcript: transcript, config: config) else { continue }
            if best == nil || found.score > best!.score { best = found }
        }
        if var best {
            best.miss.eligibleCommandIDs = enabled.map(\.id)
            return best.miss
        }

        let longest = enabled.map { $0.triggerWords.count }.max() ?? 1
        let words = tokens.prefix(max(1, min(2, longest)))
        let heard = VoiceLaunchText.trimTrailingPunctuation(String(transcript[words.first!.range.lowerBound..<words.last!.range.upperBound]))
        return VoiceNearMiss(kind: .trigger, transcript: transcript, heardTrigger: heard, eligibleCommandIDs: enabled.map(\.id))
    }

    /// The trigger spelling to save if the user says this shortcut was meant:
    /// as many of the first words as the shortcut's own trigger has.
    static func triggerAliasCandidate(_ miss: VoiceNearMiss, for voiceCommand: VoiceCommand) -> String? {
        let words = VoiceLaunchText.heardWords(miss.transcript)
        let count = max(1, voiceCommand.triggerWords.count)
        guard words.count >= count else { return nil }
        return words.prefix(count).joined(separator: " ")
    }

    /// Entries of `list` closest to `heard`, closest first; equal distances
    /// keep list order. Ordering only.
    static func rankedEntries(heard: String, in list: VoiceList, limit: Int? = nil) -> [VoiceNearMiss.Candidate] {
        let wanted = VoiceLaunchText.key(heard)
        let ranked = list.entries.enumerated()
            .filter { !$0.element.displayName.isEmpty }
            .map { index, entry -> (Int, Int, VoiceNearMiss.Candidate) in
                let distance = entry.names.map { VoiceLaunchText.editDistance(wanted, VoiceLaunchText.key($0)) }.min() ?? Int.max
                return (distance, index, VoiceNearMiss.Candidate(entryId: entry.id, name: entry.displayName))
            }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
        return limit.map { Array(ranked.prefix($0)) } ?? ranked
    }

    // MARK: Walking a pattern

    /// Pattern parts with each optional group either included or left out.
    private static func expansions(_ parts: [PatternPart]) -> [[PatternPart]] {
        var result: [[PatternPart]] = [[]]
        for part in parts {
            if case .optional(let group) = part {
                let inner = expansions(group)
                result = result.flatMap { prefix in [prefix] + inner.map { prefix + $0 } }
            } else {
                result = result.map { $0 + [part] }
            }
            if result.count > 64 { result = Array(result.prefix(64)) }
        }
        return result
    }

    private static func entryMiss(_ parsed: ParsedPattern, voiceCommand: VoiceCommand, tokens: [Token],
                                  transcript: String, config: VoiceLaunchConfig) -> (score: Int, miss: VoiceNearMiss)? {
        guard case .literal(let lead)? = parsed.parts.first else { return nil }
        let leadWords = lead.compactMap(VoiceLaunchText.normalizedWord)
        var variants = [leadWords]
        for alias in voiceCommand.triggerAliases {
            let words = VoiceLaunchText.normalizedWords(alias)
            if !words.isEmpty, !variants.contains(words) { variants.append(words) }
        }
        guard let variant = variants.first(where: { v in
            v.count <= tokens.count && (0..<v.count).allSatisfy { tokens[$0].word == v[$0] }
        }) else { return nil }

        func text(_ from: Int, _ to: Int) -> String {
            VoiceLaunchText.trimTrailingPunctuation(String(transcript[tokens[from].range.lowerBound..<tokens[to - 1].range.upperBound]))
        }

        var best: (score: Int, miss: VoiceNearMiss)?
        for flat in expansions(Array(parsed.parts.dropFirst())) {
            var pos = variant.count
            var score = leadWords.count
            var index = 0
            walk: while index < flat.count {
                switch flat[index] {
                case .literal(let words):
                    let expected = words.compactMap(VoiceLaunchText.normalizedWord)
                    guard pos + expected.count <= tokens.count,
                          (0..<expected.count).allSatisfy({ tokens[pos + $0].word == expected[$0] }) else { break walk }
                    pos += expected.count
                    score += expected.count

                case .optional:
                    break // expanded away

                case .textSlot:
                    if index == flat.count - 1 { pos = tokens.count; break }
                    guard case .literal(let marker) = flat[index + 1] else { break walk }
                    let words = marker.compactMap(VoiceLaunchText.normalizedWord)
                    var end = pos + 1
                    var found = false
                    while end + words.count <= tokens.count {
                        if (0..<words.count).allSatisfy({ tokens[end + $0].word == words[$0] }) { found = true; break }
                        end += 1
                    }
                    guard found else { break walk }
                    pos = end

                case .listSlot(let name, let listName):
                    guard let list = config.list(named: listName) else { break walk }
                    var longest = 0
                    for entry in list.entries {
                        for alias in entry.names {
                            let words = VoiceLaunchText.normalizedWords(alias)
                            guard !words.isEmpty, pos + words.count <= tokens.count,
                                  (0..<words.count).allSatisfy({ tokens[pos + $0].word == words[$0] }) else { continue }
                            longest = max(longest, words.count)
                        }
                    }
                    if longest > 0 { pos += longest; score += longest; break }

                    // No entry fits here: that is the near miss.
                    guard pos < tokens.count, !list.entries.isEmpty else { break walk }
                    let remaining = tokens.count - pos
                    var spans: [Int]
                    switch index + 1 < flat.count ? flat[index + 1] : nil {
                    case .textSlot?:
                        spans = remaining >= 2 ? [1, 2] : [1]
                    case .literal(let marker)?:
                        let words = marker.compactMap(VoiceLaunchText.normalizedWord)
                        var end = pos + 1
                        var length = 1
                        while end + words.count <= tokens.count, end - pos <= maxHeardNameWords {
                            if (0..<words.count).allSatisfy({ tokens[end + $0].word == words[$0] }) { length = end - pos; break }
                            end += 1
                        }
                        spans = [length]
                    case nil:
                        spans = [min(remaining, maxHeardNameWords)]
                    default:
                        spans = [1]
                    }
                    let heard = spans.map { text(pos, pos + $0) }
                    let miss = VoiceNearMiss(
                        kind: .entry, transcript: transcript,
                        commandId: voiceCommand.id, commandName: voiceCommand.name, slotName: name,
                        listId: list.id, listName: list.name, heardSpans: heard,
                        candidates: rankedEntries(heard: heard[0], in: list, limit: maxNearMissCandidates))
                    if best == nil || score > best!.score { best = (score, miss) }
                    break walk
                }
                index += 1
            }
        }
        return best
    }
}

// MARK: - Fixing a near miss

/// What a click on a near-miss notice does. Pure: the caller stores the
/// new settings and runs the plan.
enum VoiceNearMissFix {
    struct EntryFix: Equatable {
        var config: VoiceLaunchConfig
        /// What the same words do now, with the new spelling saved.
        var result: PlanResult
    }

    /// Saves the words at `span` as another spelling of `entryId` in the
    /// missed list, then plans the same transcript again.
    static func fixEntry(_ miss: VoiceNearMiss, span: Int, entryId: String, in config: VoiceLaunchConfig) -> Result<EntryFix, AliasProblem> {
        guard miss.kind == .entry, let listId = miss.listId, miss.heardSpans.indices.contains(span) else { return .failure(.empty) }
        var updated = config
        if let problem = updated.addEntryAlias(miss.heardSpans[span], listId: listId, entryId: entryId), problem != .alreadyKnown {
            return .failure(problem)
        }
        // The person chose this command's missing name. Replay that command
        // alone, using its already-approved scope, without carrying app context.
        var replay = updated
        replay.commands = updated.commands.filter { $0.id == miss.commandId }
        let app = replay.commands.first?.onlyInApps.first
        return .success(EntryFix(config: updated, result: VoiceLaunchEngine.plan(for: miss.transcript, in: replay, frontmostAppBundleID: app)))
    }

    /// Saves the first words as another way to start `shortcutId`. Nothing runs.
    static func fixTrigger(_ miss: VoiceNearMiss, commandId: String, in config: VoiceLaunchConfig) -> Result<VoiceLaunchConfig, AliasProblem> {
        guard miss.kind == .trigger, let voiceCommand = config.commands.first(where: { $0.id == commandId }),
              miss.offers(voiceCommand),
              let alias = VoiceLaunchEngine.triggerAliasCandidate(miss, for: voiceCommand) else { return .failure(.empty) }
        var updated = config
        if let problem = updated.addTriggerAlias(alias, toVoiceCommand: commandId) { return .failure(problem) }
        return .success(updated)
    }
}

extension VoiceNearMiss {
    func offers(_ command: VoiceCommand) -> Bool {
        eligibleCommandIDs?.contains(command.id) ?? command.onlyInApps.isEmpty
    }
}
