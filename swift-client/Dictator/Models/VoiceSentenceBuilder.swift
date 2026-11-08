import Foundation

// The sentence builder behind "What do you say?": opening words followed by
// pieces (a person, a project, the person's own words, a word that starts a
// new part). It builds and reads the same pattern strings the engine matches,
// so nothing here changes how a sentence is understood.

struct SentencePiece: Equatable, Identifiable {
    enum Kind: Equatable {
        /// Someone or something from a list, kept under a short name.
        case list(slot: String, list: String)
        /// What the person says freely, kept under a short name.
        case words(slot: String)
        /// A fixed word that starts a new part, like "subject".
        case marker(String)
    }

    var id: String
    var kind: Kind
    /// The piece may be left out when speaking.
    var canSkip: Bool

    init(id: String = UUID().uuidString, kind: Kind, canSkip: Bool = false) {
        self.id = id
        self.kind = kind
        self.canSkip = canSkip
    }

    /// How the piece is written in the sentence text the engine reads.
    var written: String {
        switch kind {
        case .list(let slot, let list): "{\(slot):\(list)}"
        case .words(let slot): "{\(slot)}"
        case .marker(let words): SentenceBuilder.collapse(words)
        }
    }

    var isMarker: Bool { if case .marker = kind { true } else { false } }
    var isWords: Bool { if case .words = kind { true } else { false } }

    /// The short name a value from this piece goes by.
    var slotName: String? {
        switch kind {
        case .list(let slot, _), .words(let slot): slot
        case .marker: nil
        }
    }
}

struct SentenceBuilder: Equatable {
    var opening: String
    var pieces: [SentencePiece]

    init(opening: String = "", pieces: [SentencePiece] = []) {
        self.opening = opening
        self.pieces = pieces
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Building the sentence text

    /// The text the engine reads. A piece that can be skipped is grouped with
    /// what the engine needs next to it: a word that starts a new part is
    /// grouped with what follows it, and words are grouped with the word that
    /// ends them.
    var pattern: String {
        var out: [String] = []
        let start = Self.collapse(opening)
        if !start.isEmpty { out.append(start) }
        var i = 0
        while i < pieces.count {
            let piece = pieces[i]
            guard piece.canSkip else { out.append(piece.written); i += 1; continue }
            var group = [piece.written]
            var last = piece
            var next = i + 1
            if piece.isMarker, next < pieces.count, !pieces[next].isMarker {
                group.append(pieces[next].written)
                last = pieces[next]
                next += 1
            }
            if last.isWords, next < pieces.count, pieces[next].isMarker {
                group.append(pieces[next].written)
                next += 1
            }
            out.append("[" + group.joined(separator: " ") + "]")
            i = next
        }
        return out.joined(separator: " ")
    }

    /// Reads a sentence text back into pieces. Nil when it can't be shown
    /// exactly, so the editor never rewrites a sentence it doesn't understand.
    init?(pattern text: String) {
        guard case .success(let parsed) = VoicePattern.parse(text), case .literal(let words)? = parsed.parts.first else { return nil }
        var pieces: [SentencePiece] = []
        func piece(_ part: PatternPart) -> SentencePiece? {
            switch part {
            case .literal(let words): SentencePiece(kind: .marker(words.joined(separator: " ")))
            case .listSlot(let name, let list): SentencePiece(kind: .list(slot: name, list: list))
            case .textSlot(let name): SentencePiece(kind: .words(slot: name))
            case .optional: nil
            }
        }
        for part in parsed.parts.dropFirst() {
            if case .optional(let group) = part {
                var made = group.compactMap(piece)
                guard made.count == group.count, !made.isEmpty else { return nil }
                made[0].canSkip = true
                pieces += made
            } else if let made = piece(part) {
                pieces.append(made)
            }
        }
        let candidate = SentenceBuilder(opening: words.joined(separator: " "), pieces: pieces)
        guard case .success(let again) = VoicePattern.parse(candidate.pattern), again == parsed else { return nil }
        self = candidate
    }

    // MARK: Names

    /// A short name safe to use as a value name: letters, digits and _.
    static func slotName(from text: String, avoiding used: Set<String>, fallback: String = "message") -> String {
        var base = String(String.UnicodeScalarView(text.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? $0 : "_"
        }))
        while base.contains("__") { base = base.replacingOccurrences(of: "__", with: "_") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if base.isEmpty { base = fallback }
        var candidate = base
        var n = 2
        while used.contains(candidate.lowercased()) { candidate = "\(base)\(n)"; n += 1 }
        return candidate
    }

    var usedSlots: Set<String> { Set(pieces.compactMap { $0.slotName?.lowercased() }) }

    /// The name a value from this list goes by: person, project, or the list's own name.
    static func slotName(forList list: String) -> String {
        if SpokenPhrase.isPeople(list) { return "person" }
        if VoiceLaunchText.normalizedWords(list) == VoiceLaunchText.normalizedWords(VoiceCards.projectsList) { return "project" }
        return slotName(from: list, avoiding: [], fallback: "thing")
    }

    // MARK: Editing

    mutating func addList(_ list: String) {
        let slot = Self.slotName(from: Self.slotName(forList: list), avoiding: usedSlots, fallback: "thing")
        pieces.append(SentencePiece(kind: .list(slot: slot, list: list)))
    }

    mutating func addWords(named name: String) {
        pieces.append(SentencePiece(kind: .words(slot: Self.slotName(from: name, avoiding: usedSlots))))
    }

    mutating func addMarker(_ word: String) {
        pieces.append(SentencePiece(kind: .marker(Self.collapse(word))))
    }

    mutating func remove(_ id: String) { pieces.removeAll { $0.id == id } }

    /// Moves a piece one place; ignores moves off the ends.
    mutating func move(_ id: String, by offset: Int) {
        guard let index = pieces.firstIndex(where: { $0.id == id }), pieces.indices.contains(index + offset) else { return }
        pieces.swapAt(index, index + offset)
    }

    /// Renames the value a piece goes by; a name already taken gets a number.
    mutating func rename(_ id: String, to name: String) {
        guard let index = pieces.firstIndex(where: { $0.id == id }) else { return }
        var others = usedSlots
        if let current = pieces[index].slotName { others.remove(current.lowercased()) }
        switch pieces[index].kind {
        case .words: pieces[index].kind = .words(slot: Self.slotName(from: name, avoiding: others))
        case .list(_, let list): pieces[index].kind = .list(slot: Self.slotName(from: name, avoiding: others, fallback: "thing"), list: list)
        case .marker: pieces[index].kind = .marker(Self.collapse(name))
        }
    }

    // MARK: Plain words for a problem

    /// What is wrong with the sentence, in plain words, or nil.
    func problem(config: VoiceLaunchConfig) -> String? {
        let start = Self.collapse(opening)
        if start.isEmpty { return VoiceBuildCopy.needOpening }
        if VoiceLaunchText.normalizedWords(start).isEmpty { return VoiceBuildCopy.openingNeedsLetters }
        var names = Set<String>()
        for piece in pieces {
            switch piece.kind {
            case .marker(let words):
                if VoiceLaunchText.normalizedWords(words).isEmpty { return VoiceBuildCopy.markerNeedsWord }
            case .list(let slot, let list):
                if config.list(named: list) == nil { return VoiceBuildCopy.missingList(list) }
                if !names.insert(slot.lowercased()).inserted { return VoiceBuildCopy.duplicateName(slot) }
            case .words(let slot):
                if !names.insert(slot.lowercased()).inserted { return VoiceBuildCopy.duplicateName(slot) }
            }
        }
        let text = pattern
        if text.count > 300 { return VoiceBuildCopy.sentenceTooLong }
        if case .failure(let error) = VoicePattern.parse(text) { return Self.plain(error) }
        return nil
    }

    static func plain(_ error: PatternError) -> String {
        if error.message.contains("fixed word right after") { return VoiceBuildCopy.wordsNeedMarker }
        if error.message.contains("needs a word after it") { return VoiceBuildCopy.skippedWordsNeedMarker }
        if error.message.contains("must start with a word") { return VoiceBuildCopy.needOpening }
        if error.message.contains("used twice") { return VoiceBuildCopy.duplicateNames }
        return VoiceBuildCopy.sentenceNotReady
    }

    // MARK: Example

    /// A sentence someone could say, for the live preview.
    static func exampleValues(pattern: String, config: VoiceLaunchConfig) -> [String: String] {
        guard case .success(let parsed) = VoicePattern.parse(pattern) else { return [:] }
        var values: [String: String] = [:]
        for slot in parsed.slots {
            if let listName = slot.list {
                if let name = config.list(named: listName)?.entries.first?.displayName, !name.isEmpty {
                    values[slot.name] = name
                } else if VoiceLaunchText.normalizedWords(listName) == VoiceLaunchText.normalizedWords(VoiceCards.projectsList) {
                    values[slot.name] = "my project"
                } else {
                    values[slot.name] = "something"
                }
            } else {
                switch slot.name.lowercased() {
                case "query", "search": values[slot.name] = "best pizza"
                case "subject", "title": values[slot.name] = "Lunch tomorrow"
                default: values[slot.name] = "running late"
                }
            }
        }
        return values
    }

    /// The example as coloured pieces. Skippable pieces are shown too.
    static func exampleSegments(pattern: String, config: VoiceLaunchConfig) -> [PhraseSegment] {
        SpokenPhrase.segments(pattern: pattern, values: exampleValues(pattern: pattern, config: config))
    }

    /// "WhatsApp Noam running late".
    static func exampleSentence(pattern: String, config: VoiceLaunchConfig) -> String {
        exampleSegments(pattern: pattern, config: config).map(\.text).joined(separator: " ")
    }
}
