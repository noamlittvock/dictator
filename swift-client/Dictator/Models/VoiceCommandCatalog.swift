import Foundation

/// Words the Core sends to the target Mac when they didn't make a shortcut
/// (`insert.shortcut`). The target keeps them on the clipboard and shows
/// the notice.
struct VoiceCommandDelivery: Codable, Equatable {
    var text: String
    /// A plain-language alert (`DictationAlert.encoded`) to show on arrival.
    var notice: String?
    /// The words were close to a shortcut: show a fix-it notice while
    /// keeping the words on the clipboard.
    var nearMiss: VoiceNearMiss?
}

/// The ready-made lists and shortcuts in `shared/shortcut-catalog.json`.
struct VoiceCommandCatalog: Decodable {
    struct ListSeed: Decodable, Equatable {
        var name: String
        var fields: [String]
    }

    /// The plain-words card for a template in the simple Voice launch view.
    struct Card: Decodable, Equatable {
        /// "WhatsApp a person". Nil for an alternative that has no card of its own.
        var title: String?
        /// A sentence to say, shown with its words coloured by role.
        var example: String?
        /// The one question turning the card on asks: "whatsapp" or "projects".
        var ask: String?
        /// The template this is another way of doing; the two share one card.
        var variantOf: String?
        /// The heading the card sits under (an id from `groups`).
        var group: String?
        /// What happens, in one plain sentence. A variant's line is shown while it is the one in use.
        var does: String?
        /// Apps whose icon stands for the card when one is installed, before the website's icon.
        var apps: [String]?
        /// The website whose icon stands for the card when its action isn't a web page.
        var site: String?
    }

    /// A heading in the simple Voice launch view.
    struct Group: Decodable, Equatable {
        var id: String
        var title: String
    }

    struct Template: Decodable, Identifiable, Equatable {
        var id: String
        var name: String
        var pattern: String
        var cleanUpSlot: String?
        var steps: [VoiceStep]
        /// Set when the template needs step types the app doesn't run yet.
        var hidden: Bool?
        /// How the simple Voice launch view shows this template, if it does.
        var card: Card?

        /// A fresh shortcut for this template.
        func makeCommand() -> VoiceCommand {
            VoiceCommand(name: name, pattern: pattern, cleanUpSlot: cleanUpSlot,
                                steps: steps.map { var s = $0; s.id = UUID().uuidString; return s }, templateId: id)
        }
    }

    static let defaultAllowedLinkSchemes = ["http", "https", "mailto", "whatsapp", "sms"]

    var version: Int
    var allowedLinkSchemes: [String]
    var groups: [Group]?
    var lists: [ListSeed]
    var templates: [Template]

    private enum CodingKeys: String, CodingKey {
        case version, groups, lists, templates
        case allowedLinkSchemes = "allowed_link_schemes"
    }

    /// Ready-made templates that can be added (not hidden).
    var available: [Template] { templates.filter { $0.hidden != true } }

    /// Adds a template's shortcut, and any list it names that doesn't exist yet.
    @discardableResult
    func add(_ template: Template, to config: inout VoiceLaunchConfig) -> String? {
        let family = VoiceCards.family(of: template.card?.variantOf ?? template.id, catalog: self)
        if let conflict = config.patternConflict(template.pattern, template: template, family: family, catalog: self) { return conflict }
        if let existing = config.voiceCommand(matchingPattern: template.pattern),
           let index = config.commands.firstIndex(where: { $0.id == existing.id }) {
            config.commands[index].enabled = true
            return nil
        }
        if case .success(let parsed) = VoicePattern.parse(template.pattern) {
            for name in parsed.slots.compactMap(\.list) where config.list(named: name) == nil {
                let seed = lists.first { VoiceLaunchText.normalizedWords($0.name) == VoiceLaunchText.normalizedWords(name) }
                config.lists.append(VoiceList(name: seed?.name ?? name, fields: seed?.fields ?? []))
            }
        }
        config.commands.append(template.makeCommand())
        return nil
    }

    static let shared: VoiceCommandCatalog = {
        guard let url = Bundle.main.url(forResource: "shortcut-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(VoiceCommandCatalog.self, from: data) else {
            return VoiceCommandCatalog(version: 0, allowedLinkSchemes: defaultAllowedLinkSchemes, groups: nil, lists: [], templates: [])
        }
        return catalog
    }()
}
