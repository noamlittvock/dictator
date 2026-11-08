import Foundation

// Spoken values inside text and links. On screen they are coloured bubbles
// with plain names ("message", "person's phone"); underneath they stay the
// `{slot}` / `{slot.field}` references the engine fills in.

/// One value an action can use: something from the sentence.
struct InsertableValue: Equatable, Identifiable {
    enum Kind: Equatable { case words, someone, detail, answer }

    /// What is stored in the text: `{message}`, `{person.phone}`.
    var template: String
    /// What the bubble says: "message", "person's phone".
    var name: String
    var kind: Kind

    var id: String { template }

    /// "message", "person", "person's phone", "project folder".
    static func friendlyName(slot: String, field: String?) -> String {
        let base = slot.hasPrefix(VoiceStep.answerPrefix) ? "answer" : slot.replacingOccurrences(of: "_", with: " ")
        guard let field, !field.isEmpty else { return base }
        let detail = field.replacingOccurrences(of: "_", with: " ")
        return field.lowercased() == "folder" ? "\(base) folder" : "\(base)’s \(detail)"
    }

    /// Everything the sentence offers: each of your words, each person or
    /// project, and each detail that list keeps; then the answer of each
    /// Apple Shortcut in `before` (the actions ahead of this one) and the
    /// parts of that answer the action lists.
    static func available(pattern: String, config: VoiceLaunchConfig, before: [VoiceStep] = []) -> [InsertableValue] {
        var result: [InsertableValue] = []
        if case .success(let parsed) = VoicePattern.parse(pattern) {
            for slot in parsed.slots {
                if let listName = slot.list {
                    result.append(InsertableValue(template: "{\(slot.name)}", name: friendlyName(slot: slot.name, field: nil), kind: .someone))
                    for field in config.list(named: listName)?.fields ?? [] {
                        result.append(InsertableValue(template: "{\(slot.name).\(field)}", name: friendlyName(slot: slot.name, field: field), kind: .detail))
                    }
                } else {
                    result.append(InsertableValue(template: "{\(slot.name)}", name: friendlyName(slot: slot.name, field: nil), kind: .words))
                }
            }
        }
        for step in before where step.kind == .runAppleShortcut {
            result.append(InsertableValue(template: "{\(step.answerKey)}", name: step.answerName, kind: .answer))
            for key in step.answerDetails ?? [] {
                result.append(InsertableValue(template: "{\(step.answerKey).\(key)}", name: "\(step.answerName)’s \(key)", kind: .answer))
            }
        }
        return result
    }
}

enum ValueText {
    enum Part: Equatable {
        case text(String)
        case value(InsertableValue)
    }

    /// Text and values, in order. A value the sentence no longer offers still
    /// becomes a bubble, so nothing is lost.
    static func parts(_ template: String, values: [InsertableValue]) -> [Part] {
        var result: [Part] = []
        for segment in VoiceTemplate.segments(template) {
            switch segment {
            case .text(let text), .invalid(let text):
                result.append(.text(text))
            case .reference(let slot, let field):
                let key = field.map { "{\(slot).\($0)}" } ?? "{\(slot)}"
                if let known = values.first(where: { $0.template == key }) {
                    result.append(.value(known))
                } else if slot.hasPrefix(VoiceStep.answerPrefix) {
                    // An answer this action can't see any more: still a bubble.
                    let base = values.first(where: { $0.template == "{\(slot)}" })?.name ?? "answer"
                    result.append(.value(InsertableValue(template: key, name: field.map { "\(base)’s \($0)" } ?? base, kind: .answer)))
                } else {
                    result.append(.value(InsertableValue(template: key, name: InsertableValue.friendlyName(slot: slot, field: field),
                                                         kind: field == nil ? .words : .detail)))
                }
            }
        }
        return result
    }

    /// The stored text. Curly brackets typed by hand are dropped, so the only
    /// references are the ones inserted as bubbles.
    static func template(_ parts: [Part]) -> String {
        parts.map { part in
            switch part {
            case .text(let text): text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            case .value(let value): value.template
            }
        }.joined()
    }

    /// The text in plain words for a summary: "Hi the person, the message".
    static func plain(_ template: String, values: [InsertableValue] = []) -> String {
        parts(template, values: values).map { part in
            switch part {
            case .text(let text): text
            case .value(let value): "the " + value.name
            }
        }.joined()
    }
}

/// "Search the site for the word TEST, then paste the address here."
enum ExampleAddress {
    static let sampleWord = "TEST"

    enum Outcome: Equatable {
        case converted(String)
        /// The sample word isn't in the address.
        case notFound
        case notAnAddress
    }

    /// Puts `value` (the stored reference, like `{message}`) where the sample
    /// word is: written plainly in any capitals, or as percent-encoded letters.
    static func convert(_ pasted: String, sampleWord: String = ExampleAddress.sampleWord, value: String) -> Outcome {
        let address = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = address.firstIndex(of: ":"), colon != address.startIndex,
              address[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
              !address.contains("{"), !address.contains("}"), !address.contains(" ") else { return .notAnAddress }
        // Each letter may be written as itself or as its percent-encoded form,
        // in any capitals, so TEST, test and %54%45%53%54 all count.
        let letters = sampleWord.map { character -> String in
            let forms = Set([String(character), String(character).uppercased(), String(character).lowercased()])
            let alternatives = forms.flatMap { form in
                [NSRegularExpression.escapedPattern(for: form)] + form.utf8.map { String(format: "%%%02X", $0) }
            }
            return "(?:" + Set(alternatives).sorted().joined(separator: "|") + ")"
        }
        guard let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])" + letters.joined() + "(?![A-Za-z0-9])",
                                                   options: [.caseInsensitive]) else { return .notFound }
        let range = NSRange(address.startIndex..., in: address)
        let found = regex.firstMatch(in: address, range: range) != nil
        let result = regex.stringByReplacingMatches(in: address, range: range,
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: value))
        return found ? .converted(result) : .notFound
    }
}
