import Foundation

// The simple Voice launch view: cards for the ready-made shortcuts, people,
// and projects. Everything here changes the same `VoiceLaunchConfig` the
// advanced editors change; no new setting, and the engine is untouched.

struct VoiceCard: Identifiable, Equatable {
    enum Ask: String, Equatable { case whatsapp, projects, shortcuts }

    /// The template id for a ready-made card, the shortcut's id for your own.
    var id: String
    var title: String
    /// A sentence to say, coloured by role with `SpokenPhrase`.
    var example: String
    var pattern: String
    var isOn: Bool
    var isCustom: Bool
    var ask: Ask?
    /// Set once the shortcut exists, even while it is off.
    var isAdded: Bool
    var commandId: String?
    /// The heading it sits under (a catalog group id); nil for your own.
    var group: String? = nil
    /// What happens, in one plain sentence.
    var does: String = ""
    var icon = VoiceIconSource(candidates: [], fallback: .symbol("waveform"))
}

/// A heading on the Voice launch page and the cards under it.
struct VoiceCardGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var cards: [VoiceCard]
}

enum WhatsAppMode: Equatable {
    /// Opens the chat with the text filled in.
    case checkFirst
    /// Sends after a 3 second pause.
    case sendRightAway
}

enum ShortcutRunMode: Equatable {
    /// Waits 3 seconds, so Esc can cancel it.
    case pause
    /// Runs at once.
    case rightAway
}

/// A person, as the simple view edits one.
struct PersonDraft: Equatable {
    var id: String?
    var name = ""
    var phone = ""
    var email = ""
}

enum VoiceCards {
    static let peopleList = "People"
    static let projectsList = "Projects"
    static let shortcutsList = "Your Shortcuts"
    static let runShortcutCard = "run-shortcut"

    // MARK: Families

    /// The card's own template and the templates that are other ways of doing it.
    static func family(of cardId: String, catalog: VoiceCommandCatalog = .shared) -> [String] {
        [cardId] + catalog.templates.filter { $0.card?.variantOf == cardId }.map(\.id)
    }

    private static func isCardTemplate(_ template: VoiceCommandCatalog.Template) -> Bool {
        template.card?.title != nil && template.card?.variantOf == nil
    }

    /// Every card: the ready-made ones this build can run, then your own shortcuts.
    static func cards(in config: VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared, routines: [WorkspaceRoutine] = []) -> [VoiceCard] {
        var result: [VoiceCard] = []
        var claimed = Set<String>()
        for template in catalog.runnable() where isCardTemplate(template) {
            let ids = family(of: template.id, catalog: catalog)
            claimed.formUnion(ids)
            var existing = config.commands.filter { $0.templateId.map(ids.contains) ?? false }
            if existing.isEmpty, let equivalent = config.voiceCommand(matchingPattern: template.pattern),
               config.owns(equivalent, template: template, family: ids, catalog: catalog) { existing = [equivalent] }
            let card = template.card!
            // The line of the way in use (WhatsApp: check first or send), else the card's own.
            let inUse = existing.first(where: \.enabled) ?? existing.first
            let does = inUse.flatMap { voiceCommand in catalog.templates.first { $0.id == voiceCommand.templateId }?.card?.does } ?? card.does
            result.append(VoiceCard(
                id: template.id, title: card.title ?? template.name, example: card.example ?? "",
                pattern: template.pattern, isOn: existing.contains(where: \.enabled), isCustom: false,
                ask: card.ask.flatMap(VoiceCard.Ask.init), isAdded: !existing.isEmpty, commandId: nil,
                group: card.group, does: does ?? VoiceBuildCopy.summary(of: template.steps),
                icon: .make(apps: card.apps ?? [], site: card.site, steps: template.steps, title: template.name)))
        }
        for voiceCommand in config.commands where !(voiceCommand.templateId.map(claimed.contains) ?? false) {
            result.append(VoiceCard(
                id: voiceCommand.id, title: customTitle(voiceCommand), example: sampleSentence(pattern: voiceCommand.pattern, config: config),
                pattern: voiceCommand.pattern, isOn: voiceCommand.enabled, isCustom: true, ask: nil, isAdded: true, commandId: voiceCommand.id,
                does: VoiceBuildCopy.summary(of: voiceCommand.steps, routines: routines),
                icon: .make(steps: voiceCommand.steps, title: customTitle(voiceCommand))))
        }
        return result
    }

    static let yoursGroup = "yours"

    /// The cards under their headings, in the catalog's order, then your own.
    /// Headings with no cards are left out.
    static func groups(_ cards: [VoiceCard], catalog: VoiceCommandCatalog = .shared) -> [VoiceCardGroup] {
        let headings = catalog.groups ?? []
        var result = headings.map { heading in
            VoiceCardGroup(id: heading.id, title: heading.title, cards: cards.filter { !$0.isCustom && $0.group == heading.id })
        }
        let known = Set(headings.map(\.id))
        let other = cards.filter { !$0.isCustom && !known.contains($0.group ?? "") }
        if !other.isEmpty { result.append(VoiceCardGroup(id: "other", title: "More", cards: other)) }
        result.append(VoiceCardGroup(id: yoursGroup, title: "Made by you", cards: cards.filter(\.isCustom)))
        return result.filter { !$0.cards.isEmpty }
    }

    static func segments(for card: VoiceCard, config: VoiceLaunchConfig) -> [PhraseSegment] {
        guard card.ask == .shortcuts else { return SpokenPhrase.segments(pattern: card.pattern, sentence: card.example, config: config) }
        // The example uses the first Shortcut you have; without any, "lights off" stands in for one.
        var sample = config
        var sentence = card.example
        if let first = VoiceYourShortcuts.entries(in: config).first {
            sentence = "Shortcut \(first.displayName)"
        } else {
            VoiceYourShortcuts.merge([AppleShortcutInfo(name: "lights off", identifier: nil)], into: &sample)
        }
        return SpokenPhrase.segments(pattern: card.pattern, sentence: sentence, config: sample)
    }

    // MARK: Your own shortcuts as cards

    /// What to call a shortcut in plain words: the card's title for a ready-made
    /// one, else its name.
    static func title(for voiceCommand: VoiceCommand, catalog: VoiceCommandCatalog = .shared) -> String {
        guard let id = voiceCommand.templateId, let template = catalog.templates.first(where: { $0.id == id }) else { return voiceCommand.name }
        let primary = template.card?.variantOf.flatMap { variant in catalog.templates.first { $0.id == variant } } ?? template
        return primary.card?.title ?? voiceCommand.name
    }

    /// The first words you say, else the shortcut's name.
    static func customTitle(_ voiceCommand: VoiceCommand) -> String {
        let words = voiceCommand.triggerWords.joined(separator: " ")
        return words.isEmpty ? voiceCommand.name : words
    }

    /// A sentence that fits the pattern, with the first name in each list.
    static func sampleSentence(pattern: String, config: VoiceLaunchConfig) -> String {
        guard case .success(let parsed) = VoicePattern.parse(pattern) else { return pattern }
        var words: [String] = []
        for part in parsed.parts {
            switch part {
            case .literal(let lead): words += lead
            case .listSlot(_, let list):
                words.append(config.list(named: list)?.entries.first?.displayName ?? (SpokenPhrase.isPeople(list) ? "Dana" : "one"))
            case .textSlot(let name):
                words.append(["query", "search"].contains(name.lowercased()) ? "pizza" : "I’ll be late")
            case .optional: break
            }
        }
        return words.joined(separator: " ")
    }

    // MARK: On and off

    static func conflict(for cardId: String, in config: VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared) -> String? {
        guard let template = catalog.templates.first(where: { $0.id == cardId }) else { return nil }
        return config.patternConflict(template.pattern, template: template, family: family(of: cardId, catalog: catalog), catalog: catalog)
    }

    /// Turns a card on: enables its shortcut, adding it first from the ready-made list.
    @discardableResult
    static func turnOn(_ cardId: String, in config: inout VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared,
                       whatsAppMode: WhatsAppMode = .checkFirst, shortcutMode: ShortcutRunMode = .pause) -> String? {
        if let conflict = conflict(for: cardId, in: config, catalog: catalog) { return conflict }
        let ids = family(of: cardId, catalog: catalog)
        if cardId == runShortcutCard, !config.commands.contains(where: { $0.templateId.map(ids.contains) ?? false }) {
            return setShortcutMode(shortcutMode, in: &config, catalog: catalog)
        }
        if cardId == "whatsapp", !config.commands.contains(where: { $0.templateId.map(ids.contains) ?? false }) {
            return setWhatsAppMode(whatsAppMode, in: &config, catalog: catalog)
        }
        var found = false
        for index in config.commands.indices where config.commands[index].templateId.map(ids.contains) ?? false {
            config.commands[index].enabled = true
            found = true
        }
        if !found, let template = catalog.templates.first(where: { $0.id == cardId }) { return catalog.add(template, to: &config) }
        return nil
    }

    static func turnOff(_ cardId: String, in config: inout VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared) {
        let ids = family(of: cardId, catalog: catalog)
        let equivalentID = catalog.templates.first(where: { $0.id == cardId }).flatMap { template in
            config.voiceCommand(matchingPattern: template.pattern).flatMap {
                config.owns($0, template: template, family: ids, catalog: catalog) ? $0.id : nil
            }
        }
        for index in config.commands.indices where (config.commands[index].templateId.map(ids.contains) ?? false) || config.commands[index].id == equivalentID {
            config.commands[index].enabled = false
        }
    }

    /// Your own shortcut's card.
    static func setCustom(_ commandId: String, on: Bool, in config: inout VoiceLaunchConfig) {
        if let index = config.commands.firstIndex(where: { $0.id == commandId }) { config.commands[index].enabled = on }
    }

    // MARK: WhatsApp

    static func whatsAppMode(in config: VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared) -> WhatsAppMode? {
        let sendIds = Set(family(of: "whatsapp", catalog: catalog).filter { $0 != "whatsapp" })
        if config.commands.contains(where: { $0.enabled && ($0.templateId.map(sendIds.contains) ?? false) }) { return .sendRightAway }
        if config.commands.contains(where: { $0.enabled && $0.templateId == "whatsapp" }) { return .checkFirst }
        return nil
    }

    /// Keeps exactly one WhatsApp shortcut, enabled, and says "WhatsApp" in both
    /// modes. The one you leave is removed (its other ways of saying it are
    /// kept), so two shortcuts never share a pattern.
    @discardableResult
    static func setWhatsAppMode(_ mode: WhatsAppMode, in config: inout VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared) -> String? {
        if let conflict = conflict(for: "whatsapp", in: config, catalog: catalog) { return conflict }
        let ids = family(of: "whatsapp", catalog: catalog)
        guard let plain = catalog.templates.first(where: { $0.id == "whatsapp" }) else { return nil }
        let sendTemplate = catalog.templates.first { $0.id != "whatsapp" && ids.contains($0.id) }
        var aliases: [String] = []
        for voiceCommand in config.commands where voiceCommand.templateId.map(ids.contains) ?? false {
            for alias in voiceCommand.triggerAliases where !aliases.contains(alias) { aliases.append(alias) }
        }
        config.commands.removeAll { $0.templateId.map(ids.contains) ?? false }
        var voiceCommand: VoiceCommand
        switch mode {
        case .checkFirst:
            voiceCommand = plain.makeCommand()
        case .sendRightAway:
            guard let sendTemplate else { voiceCommand = plain.makeCommand(); break }
            voiceCommand = sendTemplate.makeCommand()
            voiceCommand.pattern = plain.pattern
        }
        voiceCommand.triggerAliases = aliases
        if let existing = config.voiceCommand(matchingPattern: voiceCommand.pattern), config.owns(existing, template: plain, family: ids, catalog: catalog) {
            config.commands.removeAll { $0.id == existing.id }
        }
        catalog.ensureLists(for: voiceCommand.pattern, in: &config)
        config.commands.append(voiceCommand)
        return nil
    }

    // MARK: Run a Shortcut

    static func shortcutMode(in config: VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared) -> ShortcutRunMode? {
        let now = Set(family(of: runShortcutCard, catalog: catalog).filter { $0 != runShortcutCard })
        if config.commands.contains(where: { $0.enabled && ($0.templateId.map(now.contains) ?? false) }) { return .rightAway }
        if config.commands.contains(where: { $0.enabled && $0.templateId == runShortcutCard }) { return .pause }
        return nil
    }

    /// Keeps exactly one "Shortcut …" shortcut, enabled, with or without the
    /// pause. Its other ways of starting are kept.
    @discardableResult
    static func setShortcutMode(_ mode: ShortcutRunMode, in config: inout VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared) -> String? {
        if let conflict = conflict(for: runShortcutCard, in: config, catalog: catalog) { return conflict }
        let ids = family(of: runShortcutCard, catalog: catalog)
        guard let pause = catalog.templates.first(where: { $0.id == runShortcutCard }) else { return nil }
        let now = catalog.templates.first { $0.id != runShortcutCard && ids.contains($0.id) }
        var aliases: [String] = []
        for voiceCommand in config.commands where voiceCommand.templateId.map(ids.contains) ?? false {
            for alias in voiceCommand.triggerAliases where !aliases.contains(alias) { aliases.append(alias) }
        }
        config.commands.removeAll { $0.templateId.map(ids.contains) ?? false }
        var voiceCommand = (mode == .rightAway ? now : nil).map { $0.makeCommand() } ?? pause.makeCommand()
        voiceCommand.pattern = pause.pattern
        voiceCommand.triggerAliases = aliases
        if let existing = config.voiceCommand(matchingPattern: voiceCommand.pattern), config.owns(existing, template: pause, family: ids, catalog: catalog) {
            config.commands.removeAll { $0.id == existing.id }
        }
        catalog.ensureLists(for: voiceCommand.pattern, in: &config)
        config.commands.append(voiceCommand)
        return nil
    }

    // MARK: Projects

    static func projects(in config: VoiceLaunchConfig) -> [VoiceListEntry] { config.list(named: projectsList)?.entries ?? [] }

    /// Adds a project for each folder (name = the folder's name), skipping folders already there.
    static func addProjects(_ folders: [String], to config: inout VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared) {
        if config.list(named: projectsList) == nil {
            let seed = catalog.lists.first { VoiceLaunchText.normalizedWords($0.name) == VoiceLaunchText.normalizedWords(projectsList) }
            config.lists.append(VoiceList(name: seed?.name ?? projectsList, fields: seed?.fields ?? ["folder"]))
        }
        guard let index = config.lists.firstIndex(where: { VoiceLaunchText.normalizedWords($0.name) == VoiceLaunchText.normalizedWords(projectsList) }) else { return }
        if !config.lists[index].fields.contains("folder") { config.lists[index].fields.append("folder") }
        for folder in folders {
            let path = folder.hasSuffix("/") && folder.count > 1 ? String(folder.dropLast()) : folder
            guard !path.isEmpty, !config.lists[index].entries.contains(where: { $0.values["folder"] == path }) else { continue }
            let base = (path as NSString).lastPathComponent.isEmpty ? "Project" : (path as NSString).lastPathComponent
            var name = base
            var n = 2
            while config.lists[index].entries.contains(where: { $0.names.contains { VoiceLaunchText.key($0) == VoiceLaunchText.key(name) } }) {
                name = "\(base) \(n)"
                n += 1
            }
            config.lists[index].entries.append(VoiceListEntry(names: [name], values: ["folder": path]))
        }
    }

    /// Renames a project; returns a plain reason when the name can't be used.
    static func renameProject(id: String, to name: String, in config: inout VoiceLaunchConfig) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "A project needs a name to say." }
        guard let listIndex = config.lists.firstIndex(where: { VoiceLaunchText.normalizedWords($0.name) == VoiceLaunchText.normalizedWords(projectsList) }),
              let entryIndex = config.lists[listIndex].entries.firstIndex(where: { $0.id == id }) else { return nil }
        let key = VoiceLaunchText.key(trimmed)
        if let other = config.lists[listIndex].entries.first(where: { $0.id != id && $0.names.contains { VoiceLaunchText.key($0) == key } }) {
            return "Already how you say “\(other.displayName)”."
        }
        config.lists[listIndex].entries[entryIndex].names[0] = trimmed
        return nil
    }

    static func removeProject(id: String, from config: inout VoiceLaunchConfig) {
        guard let listIndex = config.lists.firstIndex(where: { VoiceLaunchText.normalizedWords($0.name) == VoiceLaunchText.normalizedWords(projectsList) }) else { return }
        config.lists[listIndex].entries.removeAll { $0.id == id }
    }
}

extension VoiceCommandCatalog {
    /// Adds the lists a pattern names that don't exist yet.
    func ensureLists(for pattern: String, in config: inout VoiceLaunchConfig) {
        guard case .success(let parsed) = VoicePattern.parse(pattern) else { return }
        for name in parsed.slots.compactMap(\.list) where config.list(named: name) == nil {
            let seed = lists.first { VoiceLaunchText.normalizedWords($0.name) == VoiceLaunchText.normalizedWords(name) }
            config.lists.append(VoiceList(name: seed?.name ?? name, fields: seed?.fields ?? []))
        }
    }
}

// MARK: - People

enum VoicePeople {
    static func people(in config: VoiceLaunchConfig) -> [VoiceListEntry] { config.list(named: VoiceCards.peopleList)?.entries ?? [] }

    /// "WhatsApp" when there is a phone number, "Email" when there is an address.
    static func badges(_ entry: VoiceListEntry) -> [String] {
        var result: [String] = []
        if !(entry.values["phone"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { result.append("WhatsApp") }
        if !(entry.values["email"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { result.append("Email") }
        return result
    }

    /// What a person can't be reached by yet, in plain words, or nil when
    /// both a phone number and an email are there. Shown in the list so a
    /// missing detail is found before a shortcut needs it.
    static func missingNote(_ entry: VoiceListEntry) -> String? {
        let hasPhone = badges(entry).contains("WhatsApp")
        let hasEmail = badges(entry).contains("Email")
        switch (hasPhone, hasEmail) {
        case (true, true): return nil
        case (false, true): return "No phone number yet, so WhatsApp can’t reach them."
        case (true, false): return "No email address yet, so Email can’t reach them."
        case (false, false): return "No phone number or email yet, so WhatsApp and Email can’t reach them."
        }
    }

    /// A person from what a contact card holds: the first name you'd say (else a
    /// nickname, last name or company), the first phone number and the first email.
    static func draft(givenName: String, familyName: String, nickname: String, organization: String,
                      phones: [String], emails: [String]) -> PersonDraft {
        let name = [givenName, nickname, familyName, organization]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        return PersonDraft(name: name, phone: phones.first ?? "", email: emails.first ?? "")
    }

    static func draft(_ entry: VoiceListEntry) -> PersonDraft {
        PersonDraft(id: entry.id, name: entry.displayName, phone: entry.values["phone"] ?? "", email: entry.values["email"] ?? "")
    }

    /// Adds or updates a person. Returns a plain reason when it can't be saved.
    static func save(_ draft: PersonDraft, in config: inout VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared) -> String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Type the name you say." }
        var candidate = config
        if candidate.list(named: VoiceCards.peopleList) == nil {
            let seed = catalog.lists.first { VoiceLaunchText.normalizedWords($0.name) == VoiceLaunchText.normalizedWords(VoiceCards.peopleList) }
            candidate.lists.append(VoiceList(name: seed?.name ?? VoiceCards.peopleList, fields: seed?.fields ?? ["phone", "email"]))
        }
        guard let index = candidate.lists.firstIndex(where: { VoiceLaunchText.normalizedWords($0.name) == VoiceLaunchText.normalizedWords(VoiceCards.peopleList) }) else { return nil }
        for field in ["phone", "email"] where !candidate.lists[index].fields.contains(field) { candidate.lists[index].fields.append(field) }
        let key = VoiceLaunchText.key(name)
        if let other = candidate.lists[index].entries.first(where: { $0.id != draft.id && $0.names.contains { VoiceLaunchText.key($0) == key } }) {
            return "You already have “\(other.displayName)”."
        }
        let phone = draft.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = draft.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = draft.id, let entry = candidate.lists[index].entries.firstIndex(where: { $0.id == id }) {
            var names = candidate.lists[index].entries[entry].names
            if names.isEmpty { names = [name] } else { names[0] = name }
            candidate.lists[index].entries[entry].names = names
            candidate.lists[index].entries[entry].values["phone"] = phone
            candidate.lists[index].entries[entry].values["email"] = email
        } else {
            candidate.lists[index].entries.append(VoiceListEntry(names: [name], values: ["phone": phone, "email": email]))
        }
        if let reason = candidate.validate() { return reason }
        config = candidate
        return nil
    }

    static func remove(id: String, from config: inout VoiceLaunchConfig) {
        guard let index = config.lists.firstIndex(where: { VoiceLaunchText.normalizedWords($0.name) == VoiceLaunchText.normalizedWords(VoiceCards.peopleList) }) else { return }
        config.lists[index].entries.removeAll { $0.id == id }
    }
}

// MARK: - Your Shortcuts

/// "Your Shortcuts": the Shortcuts on the main Mac, as a list you can say.
///
/// Stored as an ordinary list in the mirrored voice-launch setting, so the
/// matcher, hints, Teach, Check name and "Did you mean" treat it like People.
/// Only the main Mac fills it (from `shortcuts list`); the names and
/// identifiers are replaced on each refresh, and the ways of saying a name
/// you added are kept, and travel to the other Macs with the setting.
enum VoiceYourShortcuts {
    static let identifierField = "identifier"

    static func entries(in config: VoiceLaunchConfig) -> [VoiceListEntry] { config.list(named: VoiceCards.shortcutsList)?.entries ?? [] }

    static func isYourShortcuts(_ list: VoiceList) -> Bool {
        VoiceLaunchText.normalizedWords(list.name) == VoiceLaunchText.normalizedWords(VoiceCards.shortcutsList)
    }

    /// Makes the list match `shortcuts`. Ways of saying a name that you added
    /// stay with the same Shortcut (by identifier, else by name); a Shortcut
    /// that is gone takes its ways with it. Returns false, changing nothing,
    /// when the result couldn't be saved.
    @discardableResult
    static func merge(_ shortcuts: [AppleShortcutInfo], into config: inout VoiceLaunchConfig, catalog: VoiceCommandCatalog = .shared) -> Bool {
        var candidate = config
        if candidate.list(named: VoiceCards.shortcutsList) == nil {
            let seed = catalog.lists.first { VoiceLaunchText.normalizedWords($0.name) == VoiceLaunchText.normalizedWords(VoiceCards.shortcutsList) }
            candidate.lists.append(VoiceList(name: seed?.name ?? VoiceCards.shortcutsList, fields: seed?.fields ?? [identifierField]))
        }
        guard let index = candidate.lists.firstIndex(where: isYourShortcuts) else { return false }
        if !candidate.lists[index].fields.contains(identifierField) { candidate.lists[index].fields.append(identifierField) }
        let old = candidate.lists[index].entries
        var used = Set<String>()
        var taken = Set<String>()
        var fresh: [VoiceListEntry] = []
        for info in shortcuts {
            let name = String(info.name.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = VoiceLaunchText.normalizedWords(name).joined(separator: " ")
            // Two Shortcuts with the same name can't be told apart by voice: the first stays.
            guard !key.isEmpty, taken.insert(key).inserted else { continue }
            let previous = old.first { !used.contains($0.id) && info.identifier != nil && $0.values[identifierField] == info.identifier }
                ?? old.first { !used.contains($0.id) && $0.displayName == info.name }
            var entry = previous ?? VoiceListEntry(names: [name])
            used.insert(entry.id)
            entry.names[0] = name
            entry.values = info.identifier.map { [identifierField: $0] } ?? [:]
            // An added way of saying it that is now another Shortcut's name goes.
            entry.names = [entry.names[0]] + entry.names.dropFirst().filter { alias in
                let aliasKey = VoiceLaunchText.normalizedWords(alias).joined(separator: " ")
                return !aliasKey.isEmpty && !shortcuts.contains { VoiceLaunchText.normalizedWords($0.name).joined(separator: " ") == aliasKey }
            }
            fresh.append(entry)
        }
        candidate.lists[index].entries = Array(fresh.prefix(VoiceLaunchConfig.maxEntriesPerList))
        if candidate.validate() != nil { return false }
        config = candidate
        return true
    }
}

// MARK: - Check name

/// What "Check name" learned from a few takes of a name. Pure, so the
/// auto-save and conflict rules can be tested.
enum VoiceCheckName {
    static let takeCount = 2

    struct Conflict: Equatable {
        var heard: String
        var otherName: String
    }

    struct Outcome: Equatable {
        /// Every distinct way it was heard.
        var heard: [String] = []
        /// New versions that don't belong to anyone else; these get saved.
        var toSave: [String] = []
        var conflicts: [Conflict] = []
        var heardCorrectly = false
        var nothingHeard = false

        /// The line the sheet shows.
        func message(name: String) -> String {
            if nothingHeard { return "Dictator didn’t hear anything. Try again." }
            var lines: [String] = []
            if !toSave.isEmpty {
                let quoted = toSave.map { "“\($0)”" }.joined(separator: " and ")
                lines.append(toSave.count == 1
                             ? "Dictator heard \(quoted). Saved as another way to say \(name)."
                             : "Dictator heard \(quoted). Saved as other ways to say \(name).")
            } else if conflicts.isEmpty {
                lines.append("Got it — Dictator hears \(name) correctly.")
            }
            if let first = conflicts.first { lines.append("Sounds like \(first.otherName) too — try saying it more clearly.") }
            return lines.joined(separator: " ")
        }
    }

    /// The takes as names, in order, dropping silence. `phrase` has the fixed
    /// words before the name (empty when the name was said alone). Nil when a
    /// take didn't start with those words, so the name should be said alone.
    static func names(from transcripts: [String], phrase: VoiceTeachPhrase) -> [String]? {
        var result: [String] = []
        for transcript in transcripts {
            switch VoiceTeach.heardForEntry(transcript, phrase: phrase) {
            case .alias(let alias): result.append(alias)
            case .chooseWords: return nil
            case .nothing: break
            }
        }
        return result
    }

    static func outcome(heard names: [String], entryId: String, in list: VoiceList) -> Outcome {
        var outcome = Outcome()
        guard !names.isEmpty else { outcome.nothingHeard = true; return outcome }
        for candidate in VoiceTeach.candidates(from: names, target: .entry(list: list, entryId: entryId)) {
            outcome.heard.append(candidate.alias)
            switch candidate.status {
            case .fresh: outcome.toSave.append(candidate.alias)
            case .sameAsName: outcome.heardCorrectly = true
            case .conflict(.takenByEntry(let other)): outcome.conflicts.append(Conflict(heard: candidate.alias, otherName: other))
            case .conflict: break
            }
        }
        return outcome
    }

    /// Saves the new versions. Returns what was saved.
    @discardableResult
    static func save(_ outcome: Outcome, listId: String, entryId: String, in config: inout VoiceLaunchConfig) -> [String] {
        outcome.toSave.filter { config.addEntryAlias($0, listId: listId, entryId: entryId) == nil }
    }
}
