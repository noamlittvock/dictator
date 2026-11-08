import Foundation

/// What clean-up actually did to one dictation. `polishModel` only records
/// which model was asked; this records whether its words were used.
enum CleanupOutcome: String, Codable, Sendable {
    /// The chosen level's result was used.
    case applied
    /// Polishing failed its check, so ordinary clean-up was used instead.
    case fellBack = "fallback"
    /// The AI's result failed its check, so the words were kept.
    case rejected
    /// No clean-up model could be reached, so the words were kept.
    case unavailable

    /// Reads a speech server's `X-Polish` header. `ran` is its `X-Polish-Level`:
    /// a server too old to send one can only have done an ordinary clean-up.
    init?(server polish: String?, requested: RefineLevel, ran: String?) {
        switch polish {
        case "polished": self = requested == .polished && ran != RefineLevel.polished.rawValue ? .fellBack : .applied
        case "fallback": self = .fellBack
        case "rejected": self = .rejected
        case "unavailable": self = .unavailable
        default: return nil
        }
    }
}

/// One dictation's clean-up in plain words, for its history row.
struct CleanupStamp: Equatable {
    let label: String
    /// Why the result isn't what was chosen. Nil when it is.
    let note: String?

    /// Nil for rows that recorded nothing: older rows, typed text and voice commands.
    init?(level: String?, outcome: String?) {
        guard let level = level.flatMap(RefineLevel.storedValue) else { return nil }
        if level == .exact {
            (label, note) = ("As heard", nil)
            return
        }
        switch outcome.flatMap(CleanupOutcome.init(rawValue:)) {
        case .applied: (label, note) = (level == .polished ? "Polished" : "Cleaned up", nil)
        case .fellBack: (label, note) = ("Cleaned up", "Polishing didn’t keep what you said, so this was cleaned up instead.")
        case .rejected: (label, note) = ("Kept as heard", "The AI’s result didn’t match what you said, so your words were kept.")
        case .unavailable: (label, note) = ("Kept as heard", "No clean-up model could be reached, so your words were kept.")
        case nil: return nil
        }
    }

    init?(_ entry: DictationEntryDTO) {
        self.init(level: entry.cleanupLevel, outcome: entry.cleanupOutcome)
    }

    static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.1f s", Double(milliseconds) / 1000)
    }
}

/// One line on how clean-up has been going. Counts only: no advice, no scores.
struct CleanupSummary: Equatable {
    var total = 0
    var asChosen = 0
    var fellBack = 0
    var kept = 0
    var typicalMs: Int?

    /// `entries` newest first; rows with clean-up skipped don't count.
    init(_ entries: [DictationEntryDTO]) {
        var times: [Int] = []
        for entry in entries where entry.cleanupLevel != RefineLevel.exact.rawValue {
            guard let outcome = entry.cleanupOutcome.flatMap(CleanupOutcome.init(rawValue:)) else { continue }
            total += 1
            switch outcome {
            case .applied: asChosen += 1
            case .fellBack: fellBack += 1
            case .rejected, .unavailable: kept += 1
            }
            if let ms = entry.cleanupMs { times.append(ms) }
        }
        if !times.isEmpty { typicalMs = times.sorted()[times.count / 2] }
    }

    var line: String? {
        guard total > 0 else { return nil }
        var parts = ["\(asChosen) as chosen"]
        if fellBack > 0 { parts.append("\(fellBack) cleaned up instead of polished") }
        if kept > 0 { parts.append("\(kept) kept as heard") }
        let time = typicalMs.map { " Usually \(CleanupStamp.seconds($0))." } ?? ""
        return "Last \(total == 1 ? "dictation" : "\(total) dictations"): \(parts.joined(separator: ", ")).\(time)"
    }
}

/// How the typed words differ from the heard ones. Capitals and punctuation
/// are ignored: those change on every take, and hide the changes that matter.
enum WordChanges {
    enum Kind: Equatable { case same, added, removed }

    struct Piece: Equatable {
        let text: String
        let kind: Kind
    }

    static func between(heard: String, typed: String) -> [Piece] {
        func tokens(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
        func key(_ word: String) -> String {
            let letters = word.lowercased().filter { $0.isLetter || $0.isNumber }
            return letters.isEmpty ? word : letters
        }
        let before = tokens(heard)
        let after = tokens(typed)
        let changes = after.map(key).difference(from: before.map(key))
        var removedAt = Set<Int>()
        var addedAt = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, _, _): addedAt.insert(offset)
            }
        }
        var pieces: [Piece] = []
        var old = 0
        var new = 0
        while old < before.count || new < after.count {
            if old < before.count, removedAt.contains(old) {
                pieces.append(Piece(text: before[old], kind: .removed))
                old += 1
            } else if new < after.count, addedAt.contains(new) {
                pieces.append(Piece(text: after[new], kind: .added))
                new += 1
            } else {
                if new < after.count { pieces.append(Piece(text: after[new], kind: .same)) }
                old += 1
                new += 1
            }
        }
        return pieces
    }
}
