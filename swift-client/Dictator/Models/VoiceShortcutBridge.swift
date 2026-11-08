import Foundation

// The pure parts of the Apple Shortcuts bridge: rendering a step's templates
// (on the Core, or later on the Mac that runs the chain, once an earlier
// Shortcut has answered), the JSON handed to a Shortcut, reading its answer,
// and reading the list of Shortcuts. No I/O here; `VoiceLaunchActing` does that.

// MARK: - Values a template can use

/// What a reference in a template resolves to.
enum VoiceRenderValue: Equatable {
    case text(String)
    /// A list entry, or a Shortcut's answer: a display text and named details.
    case entry(name: String, fields: [String: String])

    init(_ slot: VoiceSlotValue) {
        switch slot {
        case .text(let value): self = .text(value)
        case .entry(_, let entry): self = .entry(name: entry.displayName, fields: entry.values)
        }
    }

    init(_ slot: VoicePlanSlot) {
        if let fields = slot.fields { self = .entry(name: slot.value, fields: fields) } else { self = .text(slot.value) }
    }
}

/// A step whose text needs an earlier Shortcut's answer, or that builds its
/// input on the Mac that runs it. Carried in the plan: the templates as
/// written and the values already known. The step's own text fields are
/// left empty, so a Mac that can't render them never runs half a template.
struct VoiceDeferred: Codable, Equatable {
    var slots: [VoicePlanSlot]
    /// Field name (`link`, `text`, `folder`, `argument`) to its template.
    var templates: [String: String]
    var cleanUpSlot: String?
    /// Everything the person said, before clean-up.
    var said: String
}

// MARK: - Rendering

enum VoiceStepRenderer {
    struct Context {
        var slots: [String: VoiceRenderValue] = [:]
        /// Answers of earlier Shortcuts, by `VoiceStep.answerKey`.
        var answers: [String: VoiceRenderValue] = [:]
        var cleanUpSlot: String?
        var said = ""
        var mac = ""
        /// "Try it": an answer that doesn't exist yet reads as "(its answer)".
        var placeholderAnswers = false
    }

    static let placeholder = "(its answer)"

    /// The template fields a kind of step has, by name.
    static func templateFields(of step: VoiceStep) -> [String: String] {
        switch step.kind {
        case .openLink: ["link": step.link ?? ""]
        case .typeText, .confirm, .appendToFile: ["text": step.text ?? ""]
        case .runWorkspace: step.workspaceId == nil ? ["text": step.text ?? ""] : [:]
        case .openApp: (step.bundleId ?? "").isEmpty ? ["text": step.text ?? ""] : [:]
        case .runAppleShortcut: step.sendsEverything ? [:] : ["text": step.text ?? ""]
        case .runInTerminal: ["folder": step.folder ?? "", "argument": step.argument ?? ""]
        case .waitForTextField, .pressKey, .webhook: [:]
        }
    }

    static func usesAnswer(_ template: String) -> Bool {
        VoiceTemplate.segments(template).contains {
            if case .reference(let slot, _) = $0 { return slot.hasPrefix(VoiceStep.answerPrefix) }
            return false
        }
    }

    /// True when the step can't be rendered on the Core.
    static func needsDeferral(_ step: VoiceStep) -> Bool {
        if step.kind == .runAppleShortcut, step.sendsEverything { return true }
        return templateFields(of: step).values.contains(where: usesAnswer)
    }

    /// The step as the plan carries it: templates moved into `deferred`.
    static func deferring(_ step: VoiceStep, slots: [VoicePlanSlot], cleanUpSlot: String?, said: String) -> VoiceStep {
        var out = step
        let templates = templateFields(of: step)
        out.deferred = VoiceDeferred(slots: slots, templates: templates, cleanUpSlot: cleanUpSlot, said: said)
        for field in templates.keys {
            switch field {
            case "link": out.link = ""
            case "text": out.text = ""
            case "folder": out.folder = ""
            case "argument": out.argument = ""
            default: break
            }
        }
        return out
    }

    /// A Shortcut named by the sentence ("{which}") gets its real name and
    /// identifier, on the Core, whatever else is left for later.
    static func resolvingTarget(_ step: VoiceStep, context: Context) -> VoiceStep {
        guard step.kind == .runAppleShortcut else { return step }
        var out = step
        if VoiceStep.isTemplate(step.shortcutName) { out.shortcutName = raw(step.shortcutName ?? "", context) }
        if VoiceStep.isTemplate(step.shortcutId) { out.shortcutId = raw(step.shortcutId ?? "", context) }
        return out
    }

    /// The step ready to run: rendered now if it was deferred.
    static func resolve(_ step: VoiceStep, answers: [String: VoiceRenderValue], mac: String, placeholderAnswers: Bool = false) -> VoiceStep {
        guard let deferred = step.deferred else { return step }
        var slots: [String: VoiceRenderValue] = [:]
        for slot in deferred.slots { slots[slot.name] = VoiceRenderValue(slot) }
        let context = Context(slots: slots, answers: answers, cleanUpSlot: deferred.cleanUpSlot, said: deferred.said,
                              mac: mac, placeholderAnswers: placeholderAnswers)
        var out = render(step, templates: deferred.templates, context: context)
        out.deferred = nil
        return out
    }

    /// Renders the templates of one step with each value encoded for where
    /// it is used: percent-encoded in a link, raw in text and in the folder
    /// and argument of a terminal step (which the terminal script quotes as
    /// one word), and as JSON in the input given to a Shortcut. The webhook
    /// body is built by the engine.
    static func render(_ step: VoiceStep, templates: [String: String] = [:], context: Context) -> VoiceStep {
        func template(_ field: String, _ original: String?) -> String { templates[field] ?? original ?? "" }
        var out = step
        switch step.kind {
        case .openLink: out.link = link(template("link", step.link), context)
        case .pressKey, .webhook: break
        case .openApp:
            if (step.bundleId ?? "").isEmpty { out.text = raw(template("text", step.text), context) }
        case .waitForTextField: out.seconds = step.seconds ?? VoiceStep.defaultWaitSeconds
        case .typeText, .appendToFile: out.text = raw(template("text", step.text), context)
        case .runWorkspace:
            // Keep the spoken words for a missing-link failure on the target Mac.
            out.text = step.workspaceId == nil ? raw(template("text", step.text), context) : context.said
        case .runInTerminal:
            out.folder = raw(template("folder", step.folder), context)
            out.argument = raw(template("argument", step.argument), context)
            let command = (step.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            out.command = command.isEmpty ? VoiceLaunchConfig.defaultAgentCommand : command
        case .confirm:
            out.text = raw(template("text", step.text), context)
            out.seconds = step.seconds ?? VoiceStep.defaultConfirmSeconds
        case .runAppleShortcut:
            if step.sendsEverything {
                out.text = VoiceShortcutInput.json(shortcut: step.shortcutName ?? "", said: context.said, values: context.slots, mac: context.mac)
            } else {
                out.text = raw(template("text", step.text), context)
            }
        }
        return out
    }

    private static func resolve(_ template: String, _ context: Context,
                                encode: (_ raw: String, _ slot: String, _ isText: Bool) -> String) -> String {
        var out = ""
        for segment in VoiceTemplate.segments(template) {
            switch segment {
            case .text(let text), .invalid(let text): out += text
            case .reference(let slot, let field):
                switch context.slots[slot] ?? context.answers[slot] {
                case .text(let value)?: out += encode(value, slot, true)
                case .entry(let name, let fields)?: out += encode(field.map { fields[$0] ?? "" } ?? name, slot, false)
                case nil:
                    if context.placeholderAnswers, slot.hasPrefix(VoiceStep.answerPrefix) { out += encode(placeholder, slot, false) }
                }
            }
        }
        return out
    }

    private static func raw(_ template: String, _ context: Context) -> String {
        resolve(template, context) { value, _, _ in value }
    }

    private static func link(_ template: String, _ context: Context) -> String {
        resolve(template, context) { value, slot, isText in
            // A trailing full stop or comma from the recognizer isn't part
            // of a search. Clean-up decides its own punctuation.
            let text = isText && slot != context.cleanUpSlot ? VoiceLaunchText.trimTrailingPunctuation(value) : value
            return VoiceLaunchLink.encodeQueryComponent(text)
        }
    }
}

// MARK: - What a Shortcut is given

enum VoiceShortcutInput {
    /// `{ "shortcut", "said", "values", "mac" }`. Free text is a string; a
    /// list entry is an object with its name and details. Unicode is kept.
    static func json(shortcut: String, said: String, values: [String: VoiceRenderValue], mac: String) -> String {
        var object: [String: Any] = [:]
        for (name, value) in values {
            switch value {
            case .text(let text): object[name] = text
            case .entry(let display, let fields):
                var entry: [String: Any] = fields
                entry["name"] = display
                object[name] = entry
            }
        }
        let root: [String: Any] = ["shortcut": shortcut, "said": said, "values": object, "mac": mac]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - What a Shortcut answers

struct VoiceShortcutAnswer: Equatable {
    static let maxBytes = 64 * 1024

    var text: String
    /// The keys of the answer when it is a JSON object.
    var keys: [String: String]

    var renderValue: VoiceRenderValue { .entry(name: text, fields: keys) }

    /// The answer for output text. A JSON object also gives its keys.
    static func parse(_ output: String) -> VoiceShortcutAnswer {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return VoiceShortcutAnswer(text: text, keys: [:])
        }
        var keys: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let string as String: keys[key] = string
            case is NSNull: keys[key] = ""
            case let number as NSNumber:
                // A JSON true/false is a Bool; everything else prints as it is.
                keys[key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            default:
                if JSONSerialization.isValidJSONObject(["v": value]),
                   let nested = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
                   let string = String(data: nested, encoding: .utf8) { keys[key] = string }
            }
        }
        return VoiceShortcutAnswer(text: text, keys: keys)
    }

    /// Reads at most 64 KB of the output file; nil answer when there is none.
    static func read(from file: URL) -> (answer: VoiceShortcutAnswer, truncated: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return (VoiceShortcutAnswer(text: "", keys: [:]), false) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        let truncated = data.count > maxBytes
        return (parse(String(decoding: truncated ? data.prefix(maxBytes) : data, as: UTF8.self)), truncated)
    }
}

// MARK: - The list of Shortcuts

struct AppleShortcutInfo: Equatable, Identifiable {
    var name: String
    var identifier: String?
    var id: String { identifier ?? name }
}

enum VoiceShortcutList {
    /// Lines of `shortcuts list --show-identifiers`: `Name (IDENTIFIER)`.
    static func parse(_ output: String) -> [AppleShortcutInfo] {
        var seen = Set<String>()
        var result: [AppleShortcutInfo] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            var info = AppleShortcutInfo(name: text, identifier: nil)
            if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
                let id = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
                if isIdentifier(id) {
                    info = AppleShortcutInfo(name: String(text[..<open]).trimmingCharacters(in: .whitespaces), identifier: id)
                }
            }
            guard !info.name.isEmpty, seen.insert(info.id).inserted else { continue }
            result.append(info)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isIdentifier(_ text: String) -> Bool {
        text.count >= 8 && text.count <= 64 && text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789ABCDEFabcdef-").contains($0) }
    }

    /// The one to run and to show, given the stored name and identifier.
    static func match(name: String, identifier: String?, in list: [AppleShortcutInfo]) -> AppleShortcutInfo? {
        if let identifier, let byId = list.first(where: { $0.identifier == identifier }) { return byId }
        return list.first { $0.name == name }
    }
}
