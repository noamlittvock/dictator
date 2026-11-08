import Foundation

/// What a slot held after matching.
enum VoiceSlotValue: Equatable {
    case text(String)
    case entry(list: String, entry: VoiceListEntry)
}

/// The words matched against one shortcut, before any clean-up.
struct VoiceLaunchMatch: Equatable {
    var voiceCommand: VoiceCommand
    var slots: [String: VoiceSlotValue]
    /// Words consumed by fixed words and list entries.
    var specificity: Int
    /// Everything the person said, before clean-up.
    var said: String = ""
    /// Filler words ("um", "so") skipped before the trigger.
    var skippedFillers: Int = 0
}

/// One slot as the "Try it" box and the notice show it.
struct VoicePlanSlot: Codable, Equatable {
    var name: String
    /// The text, or a list entry's display name.
    var value: String
    /// A list entry's fields.
    var fields: [String: String]?
}

/// A shortcut with every step rendered and encoded, ready to run.
struct VoiceLaunchPlan: Codable, Equatable {
    var commandId: String
    var commandName: String
    var slots: [VoicePlanSlot]
    var steps: [VoiceStep]
    /// The words the user said that carry the message (the clean-up slot,
    /// else the last text slot). Left on the clipboard if the chain stops.
    var mainText: String
    /// Set when a step needs a detail the chosen list entry doesn't have
    /// ("Dana has no phone number"). Nothing runs; this is said instead.
    /// Optional, so a Mac on an older build simply doesn't send it.
    var missingDetail: String? = nil

    private enum CodingKeys: String, CodingKey {
        case commandId = "shortcutId"
        case commandName = "shortcutName"
        case slots, steps, mainText, missingDetail
    }

}

enum NoMatchReason: Equatable {
    case nothingSaid
    case noCommands
    case noneMatched
    /// Two or more different shortcuts fit equally well.
    case tie([String])
}

enum PlanResult: Equatable {
    case plan(VoiceLaunchPlan)
    case noMatch(NoMatchReason)
    /// Nothing ran, but the words were close: a shortcut's fixed words
    /// matched and a name in a list wasn't recognized (or no shortcut
    /// matched at all). The user can fix it with one click.
    case nearMiss(VoiceNearMiss)
}

enum MatchOutcome: Equatable {
    case matched(VoiceLaunchMatch)
    case noMatch(NoMatchReason)
}

/// Deterministic matching and rendering. No model, no I/O.
enum VoiceLaunchEngine {
    // MARK: Whole pipeline

    /// Match, then render without clean-up. Used by "Try it" and the tests;
    /// the Core matches, cleans up the named slot, then renders.
    static func plan(for transcript: String, in config: VoiceLaunchConfig, frontmostAppBundleID: String? = nil) -> PlanResult {
        switch match(transcript, in: config, frontmostAppBundleID: frontmostAppBundleID) {
        case .noMatch(.noneMatched):
            nearMiss(for: transcript, in: config, frontmostAppBundleID: frontmostAppBundleID).map(PlanResult.nearMiss) ?? .noMatch(.noneMatched)
        case .noMatch(let reason): .noMatch(reason)
        case .matched(let match): .plan(render(match, in: config))
        }
    }

    // MARK: Tokens

    struct Token {
        var word: String
        var range: Range<String.Index>
    }

    /// Whitespace-separated words. Each keeps its place in the original
    /// text; words that are only punctuation are skipped.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            if let word = VoiceLaunchText.normalizedWord(String(text[index..<end])) {
                tokens.append(Token(word: word, range: index..<end))
            }
            index = end
        }
        return tokens
    }

    // MARK: Matching

    static func match(_ transcript: String, in config: VoiceLaunchConfig, frontmostAppBundleID: String? = nil) -> MatchOutcome {
        let tokens = tokenize(transcript)
        guard !tokens.isEmpty else { return .noMatch(.nothingSaid) }
        let enabled = config.commands.filter(\.enabled)
        guard !enabled.isEmpty else { return .noMatch(.noCommands) }

        var winners: [VoiceLaunchMatch] = []
        for voiceCommand in enabled where voiceCommand.matchesApp(frontmostAppBundleID) {
            guard case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern),
                  let best = bestMatch(of: parsed, voiceCommand: voiceCommand, tokens: tokens, transcript: transcript, config: config) else { continue }
            winners.append(best)
        }
        guard let top = winners.map(\.specificity).max() else { return .noMatch(.noneMatched) }
        var leaders = winners.filter { $0.specificity == top }
        // A shortcut heard without skipping a filler beats one that needed to
        // ("so {text}" keeps winning "so email Dana").
        if let fewest = leaders.map(\.skippedFillers).min() { leaders = leaders.filter { $0.skippedFillers == fewest } }
        if leaders.contains(where: { !$0.voiceCommand.onlyInApps.isEmpty }) {
            leaders = leaders.filter { !$0.voiceCommand.onlyInApps.isEmpty }
        }
        if leaders.count > 1 { return .noMatch(.tie(leaders.map { $0.voiceCommand.name })) }
        var winner = leaders[0]
        winner.said = transcript
        return .matched(winner)
    }

    private struct State {
        var slots: [String: VoiceSlotValue] = [:]
        var score = 0
    }

    /// How a run of spoken words fit the expected words. Higher is better.
    private enum Fit: Int, Comparable {
        /// The same letters, split or joined differently ("chat gpt" for "ChatGPT").
        case joined
        /// A Hebrew prefix letter on the first word ("ליוסי" for "יוסי").
        case prefixed
        case exact
        static func < (a: Fit, b: Fit) -> Bool { a.rawValue < b.rawValue }
    }

    /// Matches `expected` at `pos`: word for word first, then (for a list
    /// name in Hebrew) with a prefix letter on the first word, then as the
    /// same letters split or joined differently. Deterministic; no guessing.
    private static func fit(_ expected: [String], in tokens: [Token], at pos: Int,
                            allowPrefix: Bool = false) -> (consumed: Int, fit: Fit)? {
        guard !expected.isEmpty, pos < tokens.count else { return nil }
        func restMatches(from first: Int) -> Bool {
            pos + expected.count <= tokens.count
                && (first..<expected.count).allSatisfy { tokens[pos + $0].word == expected[$0] }
        }
        if restMatches(from: 0) { return (expected.count, .exact) }
        var firstWords = [tokens[pos].word]
        if allowPrefix, VoiceLaunchText.isHebrewWord(expected[0]) {
            let spoken = tokens[pos].word
            // Longest prefix first, so the result never depends on set order.
            let prefixes = VoiceLaunchText.hebrewPrefixes.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            for prefix in prefixes where spoken.count > prefix.count && spoken.hasPrefix(prefix) {
                let rest = String(spoken.dropFirst(prefix.count))
                if rest == expected[0], restMatches(from: 1) { return (expected.count, .prefixed) }
                firstWords.append(rest)
            }
        }
        // Of the ways the letters line up, the one using the fewest spoken
        // words wins, leaving the most for the message.
        let target = expected.joined()
        var fewest: Int?
        for first in firstWords {
            var joined = first
            var count = 1
            while true {
                if joined == target { fewest = min(fewest ?? count, count); break }
                guard joined.count < target.count, target.hasPrefix(joined), pos + count < tokens.count else { break }
                joined += tokens[pos + count].word
                count += 1
            }
        }
        return fewest.map { ($0, .joined) }
    }

    private static func bestMatch(of parsed: ParsedPattern, voiceCommand: VoiceCommand, tokens: [Token],
                                  transcript: String, config: VoiceLaunchConfig) -> VoiceLaunchMatch? {
        var best: State?
        var skipped = 0
        var bestFit = Fit.joined
        func value(_ from: Int, _ to: Int, trim: Bool) -> String {
            guard from < to else { return "" }
            let raw = String(transcript[tokens[from].range.lowerBound..<tokens[to - 1].range.upperBound])
            return trim ? VoiceLaunchText.trimTrailingPunctuation(raw) : raw
        }

        func run(_ parts: [PatternPart], _ i: Int, _ pos: Int, _ state: State, _ done: (Int, State) -> Void) {
            guard i < parts.count else { return done(pos, state) }
            switch parts[i] {
            case .literal(let words):
                let expected = words.compactMap(VoiceLaunchText.normalizedWord)
                guard !expected.isEmpty else {
                    run(parts, i + 1, pos, state, done)
                    return
                }
                guard let m = fit(expected, in: tokens, at: pos) else { return }
                var next = state
                next.score += expected.count
                run(parts, i + 1, pos + m.consumed, next, done)

            case .listSlot(let name, let listName):
                guard let list = config.list(named: listName) else { return }
                var longest: (entry: VoiceListEntry, words: Int, consumed: Int, fit: Fit)?
                for entry in list.entries {
                    for alias in entry.names {
                        let words = VoiceLaunchText.normalizedWords(alias)
                        guard let m = fit(words, in: tokens, at: pos, allowPrefix: true) else { continue }
                        // A name heard exactly beats one with a prefix letter,
                        // which beats one split or joined; then the longer name wins.
                        if let cur = longest, (cur.fit, cur.words) >= (m.fit, words.count) { continue }
                        longest = (entry, words.count, m.consumed, m.fit)
                    }
                }
                guard let longest else { return }
                var next = state
                next.slots[name] = .entry(list: list.name, entry: longest.entry)
                next.score += longest.words
                run(parts, i + 1, pos + longest.consumed, next, done)

            case .textSlot(let name):
                var next = state
                if i == parts.count - 1 {
                    // The last slot takes the rest, and may be empty.
                    next.slots[name] = .text(value(pos, tokens.count, trim: false))
                    run(parts, i + 1, tokens.count, next, done)
                } else if case .literal(let marker) = parts[i + 1] {
                    let words = marker.compactMap(VoiceLaunchText.normalizedWord)
                    var end = pos + 1
                    while end <= tokens.count {
                        if fit(words, in: tokens, at: end) != nil {
                            next.slots[name] = .text(value(pos, end, trim: true))
                            run(parts, i + 1, end, next, done)
                            return
                        }
                        end += 1
                    }
                }

            case .optional(let group):
                run(group, 0, pos, state) { p, s in run(parts, i + 1, p, s, done) }
                run(parts, i + 1, pos, state, done)
            }
        }

        // The leading fixed words (the trigger) may also be heard as any of
        // the shortcut's trigger aliases; the rest of the pattern is unchanged.
        // Every spelling scores as the real words would.
        guard case .literal(let lead)? = parsed.parts.first else { return nil }
        let leadWords = lead.compactMap(VoiceLaunchText.normalizedWord)
        var variants = [leadWords]
        for alias in voiceCommand.triggerAliases {
            let words = VoiceLaunchText.normalizedWords(alias)
            if !words.isEmpty, !variants.contains(words) { variants.append(words) }
        }

        var maxLeadingFillers = 0
        while maxLeadingFillers < tokens.count && VoiceLaunchText.fillerWords.contains(tokens[maxLeadingFillers].word) {
            maxLeadingFillers += 1
        }

        // Each start after only filler words ("um", "so") is tried. The most
        // specific match wins; on equal specificity, the fewest skipped.
        for startPos in 0...maxLeadingFillers {
            for variant in variants {
                guard let m = fit(variant, in: tokens, at: startPos) else { continue }
                var state = State()
                state.score = leadWords.count
                run(parsed.parts, 1, startPos + m.consumed, state) { pos, state in
                    guard pos == tokens.count else { return }
                    // Higher specificity wins; then fewer skipped fillers (earlier
                    // starts come first); then a trigger heard exactly over one
                    // heard split or joined.
                    if best == nil || state.score > best!.score
                        || (state.score == best!.score && startPos == skipped && m.fit > bestFit) {
                        best = state; skipped = startPos; bestFit = m.fit
                    }
                }
            }
        }
        guard let best else { return nil }
        return VoiceLaunchMatch(voiceCommand: voiceCommand, slots: best.slots, specificity: best.score, skippedFillers: skipped)
    }

    // MARK: Whisper hints

    /// Every fixed word of an enabled shortcut and every list name and alias.
    static func hintWords(_ config: VoiceLaunchConfig, appNames: [String] = [], limit: Int = 400) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ word: String) {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, result.count < limit, seen.insert(trimmed.lowercased()).inserted else { return }
            result.append(trimmed)
        }
        var usedLists = Set<String>()
        for voiceCommand in config.commands where voiceCommand.enabled {
            guard case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern) else { continue }
            parsed.literalWords.forEach(add)
            voiceCommand.triggerAliases.forEach(add)
            parsed.slots.compactMap(\.list).forEach { usedLists.insert(VoiceLaunchText.normalizedWords($0).joined(separator: " ")) }
        }
        for list in config.lists where usedLists.contains(VoiceLaunchText.normalizedWords(list.name).joined(separator: " ")) {
            for entry in list.entries { entry.names.forEach(add) }
        }
        appNames.forEach(add)
        return result
    }

    // MARK: Rendering

    /// Renders every step with its values encoded for where they are used.
    static func render(_ match: VoiceLaunchMatch, in config: VoiceLaunchConfig) -> VoiceLaunchPlan {
        let voiceCommand = match.voiceCommand
        let slots = match.slots
        let cleanUpSlot = voiceCommand.cleanUpSlot

        let ordered = slotOrder(voiceCommand).compactMap { name -> VoicePlanSlot? in
            switch slots[name] {
            case .text(let value)?: VoicePlanSlot(name: name, value: value, fields: nil)
            case .entry(_, let entry)?: VoicePlanSlot(name: name, value: entry.displayName, fields: entry.values)
            case nil: nil
            }
        }
        // The same rendering the target Mac uses for steps that wait for an
        // earlier Shortcut's answer.
        let context = VoiceStepRenderer.Context(slots: slots.mapValues(VoiceRenderValue.init), cleanUpSlot: cleanUpSlot, said: match.said)
        let steps: [VoiceStep] = voiceCommand.steps.map { original in
            let step = VoiceStepRenderer.resolvingTarget(original, context: context)
            if VoiceStepRenderer.needsDeferral(step) {
                return VoiceStepRenderer.deferring(step, slots: ordered, cleanUpSlot: cleanUpSlot, said: match.said)
            }
            var out = VoiceStepRenderer.render(step, context: context)
            if step.kind == .webhook { out.text = webhookBody(voiceCommand: voiceCommand, slots: slots) }
            return out
        }
        var mainText = ""
        if let cleanUpSlot, case .text(let value)? = slots[cleanUpSlot] {
            mainText = value
        } else if let last = ordered.last(where: { $0.fields == nil }) {
            mainText = last.value
        }
        if mainText.isEmpty, voiceCommand.steps.contains(where: { $0.kind == .runWorkspace && $0.workspaceId != nil }) {
            mainText = match.said
        }
        return VoiceLaunchPlan(commandId: voiceCommand.id, commandName: voiceCommand.name, slots: ordered, steps: steps, mainText: mainText,
                               missingDetail: missingDetail(voiceCommand.steps, slots: slots))
    }

    /// The first detail a step uses (`{person.phone}`) that the chosen entry
    /// leaves empty, in plain words, or nil when everything is there.
    static func missingDetail(_ steps: [VoiceStep], slots: [String: VoiceSlotValue]) -> String? {
        for step in steps {
            for template in VoiceStepRenderer.templateFields(of: step).values {
                for segment in VoiceTemplate.segments(template) {
                    guard case .reference(let slot, let field?) = segment,
                          case .entry(_, let entry)? = slots[slot] else { continue }
                    if (entry.values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return "\(entry.displayName) doesn’t have \(detailName(field)) yet"
                    }
                }
            }
        }
        return nil
    }

    /// "phone" → "a phone number", in the words Settings uses.
    static func detailName(_ field: String) -> String {
        switch field.lowercased() {
        case "phone": "a phone number"
        case "email": "an email address"
        default: "a “\(field)”"
        }
    }

    private static func slotOrder(_ voiceCommand: VoiceCommand) -> [String] {
        guard case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern) else { return [] }
        return parsed.slots.map(\.name)
    }

    /// JSON of all slot values; list slots become objects with their fields.
    static func webhookBody(voiceCommand: VoiceCommand, slots: [String: VoiceSlotValue]) -> String {
        var object: [String: Any] = [:]
        for (name, value) in slots {
            switch value {
            case .text(let text): object[name] = text
            case .entry(_, let entry):
                var fields: [String: Any] = entry.values
                fields["name"] = entry.displayName
                object[name] = fields
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

// MARK: - Encoders

enum VoiceLaunchLink {
    /// Characters that never need escaping in a URL query component.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes `text` so it is safe anywhere in a query string.
    static func encodeQueryComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

enum ShellQuote {
    /// POSIX single-quote escaping: the result is one literal word for any input.
    static func single(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Only the validated command is shell syntax. Folder and spoken words
    /// are positional parameters, including quotes, newlines and substitutions.
    static func backgroundArguments(folder: String, command: String, argument: String) -> [String] {
        let script = "cd -- \"$1\" || exit 1; shift; " + command + " \"$@\""
        var arguments = ["-f", "-c", script, "dictator", folder]
        if !argument.isEmpty { arguments.append(argument.hasPrefix("-") ? " " + argument : argument) }
        return arguments
    }

    /// The `.command` script: deletes itself first, goes to the folder and
    /// runs the command with the argument as one word.
    static func terminalScript(folder: String, command: String, argument: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let program = trimmed.isEmpty ? VoiceLaunchConfig.defaultAgentCommand : trimmed
        // Spoken words are the prompt, never an option: a leading space keeps
        // "--dangerously-skip-permissions" from reaching a tool as a flag, in
        // every tool, where `--` is understood by only some of them.
        let tail = argument.isEmpty ? "" : " " + single(argument.hasPrefix("-") ? " " + argument : argument)
        return """
        #!/bin/zsh -il
        rm -f -- "$0"
        cd -- \(single(folder)) || exit 1
        exec \(program)\(tail)

        """
    }
}

/// What the Core decides for a shortcut-mode dictation: a plan to run, or
/// the words to type with a notice saying why no shortcut ran.
struct VoiceCommandResolution: Equatable {
    var text: String
    var plan: VoiceLaunchPlan?
    var notice: String?
    /// The words were close: the target Mac offers a one-click fix.
    var nearMiss: VoiceNearMiss?
}


/// Exact names on the executing Mac. Spacing and punctuation carry no meaning;
/// a trailing channel label (Beta, for example) and .app are display decoration.
/// No prefix, edit-distance, or model-based fallback is permitted here.
enum VoiceNameResolver {
    static func normalized(_ name: String) -> String {
        var text = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: ")")))
        if text.hasSuffix(".app") { text = String(text.dropLast(4)) }
        text = text.replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
        if text.hasSuffix(".app") { text = String(text.dropLast(4)) }
        return String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Indices preserve distinct installations even when their names are identical.
    static func matches(_ spoken: String, in names: [String]) -> [Int] {
        let key = normalized(spoken)
        guard !key.isEmpty else { return [] }
        return names.indices.filter { normalized(names[$0]) == key }
    }
}
