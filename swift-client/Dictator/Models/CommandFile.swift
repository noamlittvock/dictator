import CoreFoundation
import Foundation

/// Command files are deliberately separate from the mirrored settings format.
/// These functions only transform values. They never execute steps or save settings.
enum CommandFile {
    static let maxBytes = 1_000_000
    static let version = 1

    enum Problem: String, LocalizedError {
        case tooLarge = "Choose a command file no larger than 1 MB."
        case newer = "This file needs a newer Dictator."
        case malformed = "This command file could not be read. Check the file and try again."
        case invalid = "This command file has invalid commands or lists. Check the file and try again."
        case unfinished = "Fill in the missing values and change any clashing phrases before importing."
        var errorDescription: String? { rawValue }
    }

    struct ExportOptions {
        var commandIDs: Set<String>
        var listsWithEntries: Set<String> = []
        var includeLocations = false
    }

    struct Draft: Identifiable {
        let id = UUID()
        var commands: [VoiceCommand]
        var lists: [VoiceList]
    }

    /// All payloads containing paths or addresses are shown in full before the
    /// single privacy choice is made. This includes locations embedded in text.
    static func locations(in config: VoiceLaunchConfig, options: ExportOptions) throws -> [String] {
        let object = try exportObject(config, options: options)
        return Array(Set(strings(in: object).filter(containsLocation))).sorted()
    }

    /// The sole export function. Encode the existing types, then remove private
    /// command keys rather than changing their settings/wire Codable contract.
    static func export(_ config: VoiceLaunchConfig, options: ExportOptions) throws -> Data {
        var object = try exportObject(config, options: options)
        if !options.includeLocations {
            object = removingLocations(object) as! [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maxBytes else { throw Problem.tooLarge }
        return data
    }

    private static func exportObject(_ config: VoiceLaunchConfig, options: ExportOptions) throws -> [String: Any] {
        let commands = config.commands.filter { options.commandIDs.contains($0.id) }
        let lists = Self.lists(usedBy: commands, in: config.lists).map { list in
            var copy = list
            if !options.listsWithEntries.contains(list.id) { copy.entries = [] }
            return copy
        }
        let encodedCommands = try commands.map { command -> [String: Any] in
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as! [String: Any]
            for key in ["id", "hotkey", "runsFromOtherApps"] { object.removeValue(forKey: key) }
            return object
        }
        return ["dictatorCommands": version, "commands": encodedCommands,
                "lists": try JSONSerialization.jsonObject(with: JSONEncoder().encode(lists))]
    }

    /// Size is checked before JSON parsing. Unknown kinds are detected before
    /// decoding any command and can never fall through to settings.decode.
    static func read(_ data: Data) throws -> Draft {
        guard data.count <= maxBytes else { throw Problem.tooLarge }
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = root["dictatorCommands"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue else { throw Problem.malformed }
        if number.doubleValue > Double(version) { throw Problem.newer }
        guard number.intValue == version, var commands = root["commands"] as? [[String: Any]],
              root["lists"] is [[String: Any]] else { throw Problem.malformed }
        guard commands.count <= VoiceLaunchConfig.maxCommands else { throw Problem.invalid }
        for index in commands.indices {
            guard let steps = commands[index]["steps"] as? [[String: Any]] else { throw Problem.malformed }
            for step in steps {
                guard let kind = step["kind"] as? String else { throw Problem.malformed }
                guard VoiceStep.Kind(rawValue: kind) != nil else { throw Problem.newer }
                // Runtime-only templates have no place in a saved command.
                if step["deferred"] != nil { throw Problem.invalid }
            }
            // Never even decode personal privileges supplied by an untrusted file.
            commands[index]["id"] = UUID().uuidString
            commands[index]["enabled"] = false
            commands[index].removeValue(forKey: "hotkey")
            commands[index].removeValue(forKey: "runsFromOtherApps")
        }
        root["commands"] = commands
        struct Contents: Decodable { var commands: [VoiceCommand]; var lists: [VoiceList] }
        guard let encoded = try? JSONSerialization.data(withJSONObject: root),
              let contents = try? JSONDecoder().decode(Contents.self, from: encoded) else { throw Problem.malformed }
        let draft = Draft(commands: contents.commands, lists: contents.lists)
        try validateFile(draft)
        return draft
    }

    /// Validate list structure and every command independently. Blanked export
    /// values are allowed only in the review draft; confirmation uses the full
    /// existing validator, including its phrase-clash checks.
    private static func validateFile(_ draft: Draft) throws {
        var config = VoiceLaunchConfig(lists: draft.lists)
        guard Set(draft.lists.map(\.id)).count == draft.lists.count,
              draft.lists.allSatisfy({ list in
                  !list.id.isEmpty && Set(list.entries.map(\.id)).count == list.entries.count
                      && list.entries.allSatisfy { !$0.id.isEmpty }
              }), config.validate() == nil else { throw Problem.invalid }
        for command in draft.commands {
            guard Set(command.steps.map(\.id)).count == command.steps.count,
                  command.steps.allSatisfy({ !$0.id.isEmpty }) else { throw Problem.invalid }
            var candidate = command
            for i in candidate.steps.indices {
                if candidate.steps[i].kind == .openLink || candidate.steps[i].kind == .webhook,
                   candidate.steps[i].link == "" { candidate.steps[i].link = "https://example.invalid" }
                if candidate.steps[i].kind == .runInTerminal, candidate.steps[i].folder == "" { candidate.steps[i].folder = "/synthetic" }
                if candidate.steps[i].kind == .appendToFile, candidate.steps[i].path == "" { candidate.steps[i].path = "/synthetic/notes.txt" }
                if candidate.steps[i].kind == .openApp, candidate.steps[i].bundleId == "", (candidate.steps[i].text ?? "").isEmpty {
                    candidate.steps[i].bundleId = "com.example.synthetic"
                }
            }
            config.commands = [candidate]
            guard config.validate() == nil else { throw Problem.invalid }
        }
    }

    /// Builds the complete candidate against the current settings at confirmation.
    /// Throwing leaves the caller's original config untouched.
    static func merging(_ draft: Draft, into existing: VoiceLaunchConfig) throws -> VoiceLaunchConfig {
        guard !draft.commands.flatMap(\.steps).contains(where: needsValue) else { throw Problem.unfinished }
        var result = existing
        for imported in draft.lists {
            if let index = result.lists.firstIndex(where: { VoiceLaunchText.key($0.name) == VoiceLaunchText.key(imported.name) }) {
                for field in imported.fields where !result.lists[index].fields.contains(field) {
                    result.lists[index].fields.append(field)
                }
                for entry in imported.entries {
                    let names = Set(entry.names.map(VoiceLaunchText.key))
                    guard !result.lists[index].entries.contains(where: { !names.isDisjoint(with: $0.names.map(VoiceLaunchText.key)) }) else { continue }
                    var copy = entry
                    copy.id = UUID().uuidString
                    result.lists[index].entries.append(copy)
                }
            } else {
                var copy = imported
                copy.id = UUID().uuidString
                for index in copy.entries.indices { copy.entries[index].id = UUID().uuidString }
                result.lists.append(copy)
            }
        }
        for imported in draft.commands {
            var copy = imported
            copy.id = UUID().uuidString
            copy.enabled = false
            copy.hotkey = nil
            copy.runsFromOtherApps = false
            result.commands.append(copy)
        }
        guard result.validate() == nil else { throw Problem.unfinished }
        return result
    }

    static func clash(for command: VoiceCommand, among others: [VoiceCommand]) -> String? {
        guard case .success(let pattern) = VoicePattern.parse(command.pattern) else { return nil }
        return others.first { other in
            guard other.id != command.id else { return false }
            if !Set(command.triggerKeys).isDisjoint(with: other.triggerKeys) { return true }
            guard case .success(let parsed) = VoicePattern.parse(other.pattern) else { return false }
            return parsed.matchingKey == pattern.matchingKey
        }.map { "Phrase clashes with “\(visible($0.name))”. Change it to import this command." }
    }

    static func needsValue(_ step: VoiceStep) -> Bool {
        switch step.kind {
        case .openLink, .webhook: return (step.link ?? "").isEmpty
        case .runInTerminal: return (step.folder ?? "").isEmpty || step.command == ""
        case .appendToFile: return (step.path ?? "").isEmpty
        case .openApp: return (step.bundleId ?? "").isEmpty && (step.text ?? "").isEmpty
        default: return false
        }
    }

    static func checkThis(_ step: VoiceStep) -> Bool {
        // Opening custom links/apps and running routines can act too.
        ![VoiceStep.Kind.confirm, .waitForTextField].contains(step.kind)
    }

    /// Full raw details alongside the existing summary, never truncated or resolved.
    static func details(_ step: VoiceStep) -> String {
        var fields: [(String, String?)] = [
            ("Address", step.link), ("App", step.bundleId), ("Routine", step.workspaceId),
            ("Text", step.text), ("Key", step.key), ("Folder", step.folder),
            ("Command", step.kind == .runInTerminal ? ((step.command ?? "").isEmpty ? VoiceLaunchConfig.defaultAgentCommand : step.command) : step.command),
            ("Input", step.argument), ("Apple Shortcut", step.shortcutName), ("Apple Shortcut identifier", step.shortcutId),
            ("File", step.path), ("Input format", step.inputMode)
        ]
        if let readOnly = step.readOnly { fields.append(("Marked as read only", readOnly ? "Yes" : "No")) }
        if step.background == true { fields.append(("Runs", "In the background")) }
        if step.sendsEverything { fields.append(("Sends", "Everything said, including list details")) }
        if let seconds = step.seconds { fields.append(("Seconds", String(seconds))) }
        if let seconds = step.timeoutSeconds { fields.append(("Time limit", String(seconds))) }
        if let details = step.answerDetails { fields.append(("Answer details", details.joined(separator: ", "))) }
        return fields.compactMap { name, value in value.map { "\(name): \(visible($0))" } }.joined(separator: "\n")
    }

    static func warnings(in step: VoiceStep) -> [String] {
        let values = [step.link, step.bundleId, step.text, step.folder, step.command, step.argument,
                      step.path, step.shortcutName, step.shortcutId]
        return Array(Set(values.compactMap { $0 }.flatMap { warnings(in: $0) })).sorted()
    }

    static func warnings(in text: String) -> [String] {
        var warnings: [String] = []
        if text.unicodeScalars.contains(where: isInvisible) { warnings.append("Contains invisible or control characters. Check this.") }
        let letters = String(String.UnicodeScalarView(text.unicodeScalars.filter { CharacterSet.letters.contains($0) }))
        // ASCII letters are all Latin, so only other letters can mix scripts.
        guard !letters.unicodeScalars.allSatisfy(\.isASCII) else { return warnings }
        let range = NSRange(letters.startIndex..., in: letters)
        let scripts = scriptChecks.lazy.filter { $0.firstMatch(in: letters, range: range) != nil }.prefix(2).count
        if scripts > 1 { warnings.append("Contains letters from different writing systems. Check this.") }
        return warnings
    }

    // ICU script properties handle more than the common Latin lookalikes.
    // Unsupported newer Unicode scripts are simply skipped on older macOS.
    private static let scriptChecks: [NSRegularExpression] = {
        let names = """
        Latin Greek Cyrillic Armenian Hebrew Arabic Syriac Thaana Nko Samaritan Mandaic
        Devanagari Bengali Gurmukhi Gujarati Oriya Tamil Telugu Kannada Malayalam Sinhala
        Thai Lao Tibetan Myanmar Georgian Hangul Ethiopic Cherokee Canadian_Aboriginal
        Ogham Runic Tagalog Hanunoo Buhid Tagbanwa Khmer Mongolian Limbu Tai_Le New_Tai_Lue
        Buginese Tai_Tham Balinese Sundanese Batak Lepcha Ol_Chiki Braille Glagolitic Coptic
        Tifinagh Hiragana Katakana Bopomofo Han Yi Lisu Vai Bamum Syloti_Nagri Phags_Pa
        Saurashtra Kayah_Li Rejang Javanese Cham Tai_Viet Meetei_Mayek Linear_B Lycian
        Carian Old_Italic Gothic Old_Permic Ugaritic Old_Persian Deseret Shavian Osmanya
        Osage Elbasan Caucasian_Albanian Linear_A Cypriot Imperial_Aramaic Palmyrene
        Nabataean Hatran Phoenician Lydian Meroitic_Hieroglyphs Meroitic_Cursive Kharoshthi
        Old_South_Arabian Old_North_Arabian Manichaean Avestan Inscriptional_Parthian
        Inscriptional_Pahlavi Psalter_Pahlavi Old_Turkic Old_Hungarian Hanifi_Rohingya
        Yezidi Old_Sogdian Sogdian Old_Uyghur Chorasmian Elymaic Brahmi Kaithi Sora_Sompeng
        Chakma Mahajani Sharada Khojki Multani Khudawadi Grantha Newa Tirhuta Siddham Modi
        Takri Ahom Dogra Warang_Citi Dives_Akuru Nandinagari Zanabazar_Square Soyombo
        Pau_Cin_Hau Bhaiksuki Marchen Masaram_Gondi Gunjala_Gondi Makasar Kawi Cuneiform
        Cypro_Minoan Egyptian_Hieroglyphs Anatolian_Hieroglyphs Mro Tangsa Bassa_Vah Pahawh_Hmong
        Medefaidrin Miao Tangut Nushu Khitan_Small_Script Duployan SignWriting Nyiakeng_Puachue_Hmong
        Toto Wancho Nag_Mundari Mende_Kikakui Adlam
        """
        return names.split(whereSeparator: \.isWhitespace).compactMap {
            try? NSRegularExpression(pattern: "\\p{script=\($0)}")
        }
    }()

    /// The lists the commands' phrases name.
    static func lists(usedBy commands: [VoiceCommand], in lists: [VoiceList]) -> [VoiceList] {
        let names = Set(commands.flatMap { command -> [String] in
            guard case .success(let pattern) = VoicePattern.parse(command.pattern) else { return [] }
            return pattern.slots.compactMap(\.list).map(VoiceLaunchText.key)
        })
        return lists.filter { names.contains(VoiceLaunchText.key($0.name)) }
    }

    /// A list entry as shown for review: its names, then each detail.
    static func entryText(_ entry: VoiceListEntry) -> String {
        visible((entry.names + entry.values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }).joined(separator: "\n"))
    }

    static func visible(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            isInvisible(scalar) ? String(format: "[U+%04X]", scalar.value) : String(scalar)
        }.joined()
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .nonspacingMark, .enclosingMark: return true
        case .spaceSeparator: return scalar.value != 0x20
        default: return [0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0].contains(scalar.value)
        }
    }

    private static func containsLocation(_ text: String) -> Bool {
        // Keep the entire value visible rather than pretending a token-level
        // scrub can reliably separate personal paths from arbitrary prose.
        text.range(of: #"(?i)([a-z][a-z0-9+.-]*://|mailto:|[^\s@]+@[^\s@]+\.[^\s@]+|(^|[\s='\"(])(~?/|file:))"#, options: .regularExpression) != nil
    }

    private static func strings(in object: Any) -> [String] {
        if let string = object as? String { return [string] }
        if let array = object as? [Any] { return array.flatMap(strings) }
        if let dictionary = object as? [String: Any] { return dictionary.values.flatMap(strings) }
        return []
    }

    private static func removingLocations(_ object: Any) -> Any {
        if let string = object as? String { return containsLocation(string) ? "" : string }
        if let array = object as? [Any] { return array.map(removingLocations) }
        if let dictionary = object as? [String: Any] { return dictionary.mapValues(removingLocations) }
        return object
    }
}
