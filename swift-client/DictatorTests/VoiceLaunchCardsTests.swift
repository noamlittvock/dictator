import XCTest
@testable import Dictator

/// The simple Voice launch view: cards, WhatsApp mode, projects, people,
/// role colouring, Check name. Synthetic only.
final class VoiceLaunchCardsTests: XCTestCase {
    private let catalog: VoiceCommandCatalog = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/shortcut-catalog.json")
        return try! JSONDecoder().decode(VoiceCommandCatalog.self, from: Data(contentsOf: url))
    }()

    private func withDana() -> VoiceLaunchConfig {
        var config = VoiceLaunchConfig()
        XCTAssertNil(VoicePeople.save(PersonDraft(name: "Dana", phone: "+972501234567", email: "dana@example.com"), in: &config, catalog: catalog))
        return config
    }

    // MARK: Cards on and off

    func testCardsListTheReadyMadeThingsInPlainWords() {
        let cards = VoiceCards.cards(in: VoiceLaunchConfig(), catalog: catalog)
        XCTAssertEqual(cards.map(\.title), ["Email a person", "WhatsApp a person", "Search YouTube", "Search Google", "Search Marketplace",
                                           "Ask ChatGPT", "Ask Claude", "Claude Code project", "Run a Shortcut", "Open an app", "Workspaces"])
        XCTAssertTrue(cards.allSatisfy { !$0.isOn && !$0.isAdded && !$0.example.isEmpty })
        XCTAssertEqual(cards.first { $0.id == "whatsapp" }?.ask, .whatsapp)
        XCTAssertEqual(cards.first { $0.id == "claude-code" }?.ask, .projects)
    }

    func testTurningACardOnAndOffEnablesAndDisablesItsVoiceCommand() {
        var config = VoiceLaunchConfig()
        VoiceCards.turnOn("youtube", in: &config, catalog: catalog)
        XCTAssertEqual(config.commands.map(\.templateId), ["youtube"])
        XCTAssertTrue(config.commands[0].enabled)
        XCTAssertTrue(VoiceCards.cards(in: config, catalog: catalog).first { $0.id == "youtube" }!.isOn)
        VoiceCards.turnOff("youtube", in: &config, catalog: catalog)
        XCTAssertEqual(config.commands.count, 1)
        XCTAssertFalse(config.commands[0].enabled)
        let off = VoiceCards.cards(in: config, catalog: catalog).first { $0.id == "youtube" }!
        XCTAssertFalse(off.isOn)
        XCTAssertTrue(off.isAdded)
        VoiceCards.turnOn("youtube", in: &config, catalog: catalog)
        XCTAssertEqual(config.commands.count, 1, "turning it back on doesn't add a second one")
        XCTAssertTrue(config.commands[0].enabled)
    }

    func testYourOwnVoiceCommandsAreCardsToo() {
        var config = VoiceLaunchConfig()
        config.commands = [VoiceCommand(name: "Weather", pattern: "Weather in {city}", steps: [VoiceStep(kind: .openLink, link: "https://w.test/{city}")])]
        let custom = VoiceCards.cards(in: config, catalog: catalog).last!
        XCTAssertTrue(custom.isCustom)
        XCTAssertEqual(custom.title, "Weather in")
        XCTAssertEqual(custom.example, "Weather in I’ll be late")
        VoiceCards.setCustom(custom.id, on: false, in: &config)
        XCTAssertFalse(config.commands[0].enabled)
        // A search-like pattern gets a search example.
        XCTAssertEqual(VoiceCards.sampleSentence(pattern: "Look up {query}", config: config), "Look up pizza")
    }

    func testCardsSitUnderTheCatalogHeadingsThenYourOwn() {
        var config = VoiceLaunchConfig()
        var groups = VoiceCards.groups(VoiceCards.cards(in: config, catalog: catalog), catalog: catalog)
        XCTAssertEqual(groups.map(\.id), ["message", "search", "ask", "mac"])
        XCTAssertEqual(groups.first?.cards.map(\.id), ["email", "whatsapp"])
        for card in groups.flatMap(\.cards) {
            XCTAssertFalse(card.does.isEmpty, card.id)
            XCTAssertTrue(!card.icon.candidates.isEmpty || ["open-app", "open-workspace"].contains(card.id), card.id)
        }
        config.commands.append(VoiceCommand(name: "Notes", pattern: "Note {text}", steps: [VoiceStep(kind: .appendToFile)]))
        groups = VoiceCards.groups(VoiceCards.cards(in: config, catalog: catalog), catalog: catalog)
        XCTAssertEqual(groups.last?.id, VoiceCards.yoursGroup)
        XCTAssertEqual(groups.last?.cards.first?.does, "Adds a line to a file")
        XCTAssertEqual(groups.last?.cards.first?.icon.fallback, .symbol("doc.text"))
    }

    func testWhatsAppCardSaysWhetherItSends() throws {
        var config = VoiceLaunchConfig()
        func line() throws -> String { try XCTUnwrap(VoiceCards.cards(in: config, catalog: catalog).first { $0.id == "whatsapp" }).does }
        XCTAssertTrue(try line().contains("You press Send"))
        VoiceCards.setWhatsAppMode(.sendRightAway, in: &config, catalog: catalog)
        XCTAssertTrue(try line().contains("after 3 seconds"))
        VoiceCards.setWhatsAppMode(.checkFirst, in: &config, catalog: catalog)
        XCTAssertTrue(try line().contains("You press Send"))
    }

    func testIconsComeFromTheAppThenTheWebsite() throws {
        let cards = VoiceCards.cards(in: VoiceLaunchConfig(), catalog: catalog)
        func icon(_ id: String) throws -> VoiceIconSource { try XCTUnwrap(cards.first { $0.id == id }).icon }
        XCTAssertEqual(try icon("youtube"), VoiceIconSource(candidates: [.site("www.youtube.com")], fallback: .letter("Y")))
        XCTAssertEqual(try icon("email").candidates, [.site("mail.google.com")])
        XCTAssertEqual(try icon("whatsapp").candidates, [.app("net.whatsapp.WhatsApp"), .scheme("whatsapp")])
        XCTAssertEqual(try icon("claude-code").candidates, [.site("claude.ai"), .app(VoiceIconSource.terminalApp)])
        XCTAssertEqual(try icon("run-shortcut").candidates, [.app(VoiceIconSource.shortcutsApp)])
        XCTAssertNil(VoiceIconSource.host(of: "https://{site}.com/search?q={query}"))
        XCTAssertNil(VoiceIconSource.host(of: "whatsapp://send?phone=1"))
        XCTAssertEqual(VoiceIconSource.host(of: "https://Example.org:8080/a?b={c}"), "example.org")
        XCTAssertNil(VoiceIconSource.cleanHost("evil.com/../x"))
    }

    func testEveryCardTurnsOnIntoAValidSetting() {
        var config = VoiceLaunchConfig()
        for card in VoiceCards.cards(in: config, catalog: catalog) { VoiceCards.turnOn(card.id, in: &config, catalog: catalog) }
        XCTAssertNil(config.validate(allowedSchemes: catalog.allowedLinkSchemes))
        XCTAssertEqual(config.commands.count, 11)
    }

    // MARK: WhatsApp

    func testWhatsAppModeKeepsExactlyOneVoiceCommandWithNoDuplicatePattern() throws {
        var config = withDana()
        VoiceCards.turnOn("whatsapp", in: &config, catalog: catalog)
        XCTAssertEqual(VoiceCards.whatsAppMode(in: config, catalog: catalog), .checkFirst)
        config.commands[0].triggerAliases = ["what's app"]

        VoiceCards.setWhatsAppMode(.sendRightAway, in: &config, catalog: catalog)
        XCTAssertEqual(config.commands.map(\.templateId), ["whatsapp-send"])
        XCTAssertEqual(config.commands[0].pattern, "WhatsApp {person:People} {message}")
        XCTAssertEqual(config.commands[0].triggerAliases, ["what's app"])
        XCTAssertTrue(config.commands[0].steps.contains { $0.kind == .confirm && $0.seconds == 3 })
        XCTAssertEqual(VoiceCards.whatsAppMode(in: config, catalog: catalog), .sendRightAway)
        XCTAssertNil(config.validate(allowedSchemes: catalog.allowedLinkSchemes))
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: "WhatsApp Dana running late", in: config) else { return XCTFail() }
        XCTAssertEqual(plan.commandName, "WhatsApp and send")
        XCTAssertEqual(plan.steps.map(\.kind), [.openLink, .waitForTextField, .confirm, .pressKey])

        VoiceCards.setWhatsAppMode(.checkFirst, in: &config, catalog: catalog)
        XCTAssertEqual(config.commands.map(\.templateId), ["whatsapp"])
        XCTAssertEqual(config.commands[0].triggerAliases, ["what's app"])
        XCTAssertNil(config.validate(allowedSchemes: catalog.allowedLinkSchemes))
        guard case .plan(let plain) = VoiceLaunchEngine.plan(for: "WhatsApp Dana running late", in: config) else { return XCTFail() }
        XCTAssertEqual(plain.steps.map(\.kind), [.openLink])
    }

    func testTurningWhatsAppOnInSendModeAndOffAgain() {
        var config = VoiceLaunchConfig()
        VoiceCards.turnOn("whatsapp", in: &config, catalog: catalog, whatsAppMode: .sendRightAway)
        XCTAssertEqual(config.commands.map(\.templateId), ["whatsapp-send"])
        XCTAssertEqual(config.lists.map(\.name), ["People"])
        let card = VoiceCards.cards(in: config, catalog: catalog).first { $0.id == "whatsapp" }!
        XCTAssertTrue(card.isOn)
        VoiceCards.turnOff("whatsapp", in: &config, catalog: catalog)
        XCTAssertNil(VoiceCards.whatsAppMode(in: config, catalog: catalog))
        XCTAssertFalse(VoiceCards.cards(in: config, catalog: catalog).first { $0.id == "whatsapp" }!.isOn)
        VoiceCards.turnOn("whatsapp", in: &config, catalog: catalog)
        XCTAssertEqual(config.commands.map(\.templateId), ["whatsapp-send"], "comes back the way it was")
        XCTAssertTrue(config.commands[0].enabled)
    }

    // MARK: Projects

    func testClaudeCodeCardCreatesProjectsFromFolders() {
        var config = VoiceLaunchConfig()
        VoiceCards.addProjects(["/Users/me/Work/dictator", "/Users/me/Work/site/", "/Users/me/Other/dictator", "/Users/me/Work/dictator"], to: &config, catalog: catalog)
        VoiceCards.turnOn("claude-code", in: &config, catalog: catalog)
        let projects = VoiceCards.projects(in: config)
        XCTAssertEqual(projects.map(\.displayName), ["dictator", "site", "dictator 2"])
        XCTAssertEqual(projects[1].values["folder"], "/Users/me/Work/site")
        XCTAssertEqual(config.lists.first { $0.name == "Projects" }?.fields, ["folder"])
        XCTAssertNil(config.validate(allowedSchemes: catalog.allowedLinkSchemes))
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: "Code site fix the login bug", in: config) else { return XCTFail() }
        XCTAssertEqual(plan.steps[0].folder, "/Users/me/Work/site")
        XCTAssertEqual(plan.steps[0].argument, "fix the login bug")
    }

    func testProjectsCanBeRenamedAndRemovedButNotGivenATakenName() {
        var config = VoiceLaunchConfig()
        VoiceCards.addProjects(["/a/one", "/a/two"], to: &config, catalog: catalog)
        let ids = VoiceCards.projects(in: config).map(\.id)
        XCTAssertNil(VoiceCards.renameProject(id: ids[0], to: " Alpha ", in: &config))
        XCTAssertEqual(VoiceCards.projects(in: config)[0].displayName, "Alpha")
        XCTAssertNotNil(VoiceCards.renameProject(id: ids[1], to: "alpha", in: &config))
        XCTAssertNotNil(VoiceCards.renameProject(id: ids[1], to: "  ", in: &config))
        VoiceCards.removeProject(id: ids[1], from: &config)
        XCTAssertEqual(VoiceCards.projects(in: config).map(\.displayName), ["Alpha"])
    }

    // MARK: People

    func testPeopleAreAddedEditedAndBadged() {
        var config = withDana()
        XCTAssertEqual(config.list(named: "People")?.fields, ["phone", "email"])
        var entry = VoicePeople.people(in: config)[0]
        XCTAssertEqual(VoicePeople.badges(entry), ["WhatsApp", "Email"])
        entry.names.append("Danny")
        config.lists[0].entries[0] = entry
        var draft = VoicePeople.draft(entry)
        draft.email = ""
        draft.name = "Dana L"
        XCTAssertNil(VoicePeople.save(draft, in: &config, catalog: catalog))
        let saved = VoicePeople.people(in: config)[0]
        XCTAssertEqual(saved.names, ["Dana L", "Danny"], "other ways to say it are kept")
        XCTAssertEqual(VoicePeople.badges(saved), ["WhatsApp"])
        XCTAssertNotNil(VoicePeople.save(PersonDraft(name: "danny"), in: &config, catalog: catalog))
        XCTAssertNotNil(VoicePeople.save(PersonDraft(name: "  "), in: &config, catalog: catalog))
        VoicePeople.remove(id: saved.id, from: &config)
        XCTAssertTrue(VoicePeople.people(in: config).isEmpty)
    }

    func testAContactBecomesAPersonByFirstName() {
        let draft = VoicePeople.draft(givenName: "Noam", familyName: "Litt", nickname: "", organization: "", phones: ["+1 555", "+2"], emails: ["n@e.com"])
        XCTAssertEqual(draft, PersonDraft(id: nil, name: "Noam", phone: "+1 555", email: "n@e.com"))
        XCTAssertEqual(VoicePeople.draft(givenName: "", familyName: "", nickname: "", organization: "Acme", phones: [], emails: []).name, "Acme")
        XCTAssertEqual(VoicePeople.draft(givenName: " ", familyName: "", nickname: "", organization: "", phones: [], emails: []).name, "")
    }

    // MARK: Role colouring

    func testSegmentsFromAPatternAndAnExample() {
        var config = withDana()
        VoiceCards.turnOn("whatsapp", in: &config, catalog: catalog)
        let card = VoiceCards.cards(in: config, catalog: catalog).first { $0.id == "whatsapp" }!
        XCTAssertEqual(VoiceCards.segments(for: card, config: config), [
            .opens("WhatsApp"), .who("Dana"),
            PhraseSegment(text: "I'll be late", role: .words, label: "your message")])

        let search = VoiceCards.cards(in: config, catalog: catalog).first { $0.id == "youtube" }!
        XCTAssertEqual(VoiceCards.segments(for: search, config: config).last, PhraseSegment(text: "funny cats", role: .words, label: "search"))

        VoiceCards.addProjects(["/x/my app"], to: &config, catalog: catalog)
        XCTAssertEqual(SpokenPhrase.segments(pattern: "Code {project:Projects} {prompt}", sentence: "Code my app fix it", config: config), [
            .opens("Code"), PhraseSegment(text: "my app", role: .which, label: "project"),
            PhraseSegment(text: "fix it", role: .words, label: "your message")])
    }

    func testSegmentsFromAPlanResult() throws {
        var config = withDana()
        VoiceCards.turnOn("email", in: &config, catalog: catalog)
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: "Email Dana subject Hi body See you soon.", in: config) else { return XCTFail() }
        let pattern = try XCTUnwrap(config.commands.first { $0.id == plan.commandId }?.pattern)
        let parts = SpokenPhrase.segments(for: plan, pattern: pattern)
        XCTAssertEqual(parts.map(\.role), [.opens, .who, .plain, .words, .plain, .words])
        XCTAssertEqual(parts.map(\.text), ["Email", "Dana", "subject", "Hi", "body", "See you soon."])
        XCTAssertEqual(parts.map(\.label), ["start word", "who", nil, "your message", nil, "your message"])
        // Without the optional part, it is left out.
        guard case .plan(let short) = VoiceLaunchEngine.plan(for: "Email Dana see you soon", in: config) else { return XCTFail() }
        XCTAssertEqual(SpokenPhrase.segments(for: short, pattern: pattern).map(\.text), ["Email", "Dana", "see you soon"])
        // Progress keeps the phrase for its first line.
        XCTAssertEqual(VoiceLaunchProgress(plan: short, pattern: pattern).phrase?.first, .opens("Email"))
        XCTAssertNil(VoiceLaunchProgress(plan: short).phrase)
    }

    // MARK: Near miss

    func testNearMissShowsTheHeardSentenceWithTheNameAsAQuestion() throws {
        var config = withDana()
        VoiceCards.turnOn("whatsapp", in: &config, catalog: catalog)
        guard case .nearMiss(let miss) = VoiceLaunchEngine.plan(for: "WhatsApp Dano I'll be late", in: config) else { return XCTFail() }
        XCTAssertEqual(SpokenPhrase.segments(for: miss, config: config), [
            .opens("WhatsApp"), .who("Dano?"), PhraseSegment(text: "I'll be late", role: .words, label: "your message")])
        XCTAssertEqual(VoiceNearMissFixView.defaultSpan, 0)
    }

    func testNearMissDefaultsToTheFirstWordWhenTheEndOfTheNameIsUnclear() throws {
        var config = withDana()
        VoiceCards.turnOn("whatsapp", in: &config, catalog: catalog)
        guard case .nearMiss(let miss) = VoiceLaunchEngine.plan(for: "WhatsApp no am I'll be late", in: config) else { return XCTFail() }
        XCTAssertEqual(miss.heardSpans.first, "no")
        let parts = SpokenPhrase.segments(for: miss, config: config)
        XCTAssertEqual(parts[1], .who("no?"))
        XCTAssertEqual(parts[2].text, "am I'll be late")
        let fix = try VoiceNearMissFix.fixEntry(miss, span: VoiceNearMissFixView.defaultSpan, entryId: VoicePeople.people(in: config)[0].id, in: config).get()
        XCTAssertEqual(fix.config.lists[0].entries[0].names, ["Dana", "no"])
    }

    func testTriggerNearMissHasNoSentenceToShow() {
        var config = withDana()
        VoiceCards.turnOn("youtube", in: &config, catalog: catalog)
        guard case .nearMiss(let miss) = VoiceLaunchEngine.plan(for: "what's up cats", in: config) else { return XCTFail() }
        XCTAssertEqual(miss.kind, .trigger)
        XCTAssertTrue(SpokenPhrase.segments(for: miss, config: config).isEmpty)
        XCTAssertEqual(VoiceCards.title(for: config.commands[0], catalog: catalog), "Search YouTube")
    }

    // MARK: Check name

    private func peopleList() -> VoiceList {
        VoiceList(name: "People", fields: ["phone"], entries: [
            VoiceListEntry(id: "noam", names: ["Noam"]), VoiceListEntry(id: "dana", names: ["Dana", "Dano"])])
    }

    func testCheckNameHeardCorrectly() {
        let outcome = VoiceCheckName.outcome(heard: ["noam", "Noam"], entryId: "noam", in: peopleList())
        XCTAssertTrue(outcome.heardCorrectly)
        XCTAssertTrue(outcome.toSave.isEmpty)
        XCTAssertEqual(outcome.message(name: "Noam"), "Got it — Dictator hears Noam correctly.")
    }

    func testCheckNameSavesNewSpellingsAutomatically() {
        var config = VoiceLaunchConfig()
        config.lists = [peopleList()]
        let outcome = VoiceCheckName.outcome(heard: ["norm", "Norm.", "Noam"], entryId: "noam", in: config.lists[0])
        XCTAssertEqual(outcome.toSave, ["norm"], "the same spelling twice is one")
        XCTAssertEqual(outcome.message(name: "Noam"), "Dictator heard “norm”. Saved as another way to say Noam.")
        XCTAssertEqual(VoiceCheckName.save(outcome, listId: config.lists[0].id, entryId: "noam", in: &config), ["norm"])
        XCTAssertEqual(config.lists[0].entries[0].names, ["Noam", "norm"])
        XCTAssertEqual(VoiceCheckName.outcome(heard: ["norm"], entryId: "noam", in: config.lists[0]).message(name: "Noam"),
                       "Got it — Dictator hears Noam correctly.")
    }

    func testCheckNameNeverSavesWhatSoundsLikeSomeoneElse() {
        var config = VoiceLaunchConfig()
        config.lists = [peopleList()]
        let outcome = VoiceCheckName.outcome(heard: ["dano"], entryId: "noam", in: config.lists[0])
        XCTAssertEqual(outcome.conflicts, [.init(heard: "dano", otherName: "Dana")])
        XCTAssertTrue(outcome.toSave.isEmpty)
        XCTAssertEqual(outcome.message(name: "Noam"), "Sounds like Dana too — try saying it more clearly.")
        XCTAssertTrue(VoiceCheckName.save(outcome, listId: config.lists[0].id, entryId: "noam", in: &config).isEmpty)
        XCTAssertEqual(config.lists[0].entries[0].names, ["Noam"])
        // A good version next to a conflicting one is still saved.
        let mixed = VoiceCheckName.outcome(heard: ["norm", "dano"], entryId: "noam", in: config.lists[0])
        XCTAssertEqual(mixed.toSave, ["norm"])
        XCTAssertEqual(mixed.conflicts.count, 1)
    }

    func testCheckNameNothingHeardAndTheFallbackToTheNameAlone() {
        XCTAssertTrue(VoiceCheckName.outcome(heard: [], entryId: "noam", in: peopleList()).nothingHeard)
        let phrase = VoiceTeachPhrase(text: "WhatsApp Noam", leadingWords: ["WhatsApp"])
        XCTAssertEqual(VoiceCheckName.names(from: ["WhatsApp norm", "whatsapp, Noam.", ""], phrase: phrase), ["norm", "noam"])
        XCTAssertNil(VoiceCheckName.names(from: ["What's up norm", "WhatsApp Noam"], phrase: phrase), "the first word wasn't heard: say the name alone")
        XCTAssertEqual(VoiceCheckName.names(from: ["norm", "Noam"], phrase: VoiceTeachPhrase(text: "Noam", leadingWords: [])), ["norm", "noam"])
        XCTAssertEqual(VoiceCheckName.takeCount, 2)
    }

    @MainActor func testACheckNameSessionIsCompleteAfterTwoTakes() {
        XCTAssertFalse(VoiceTeachSession(takeCount: 2).isComplete)
        XCTAssertEqual(VoiceTeachSession().takeCount, VoiceTeach.takeCount)
    }
}


extension VoiceLaunchCardsTests {
    func testNamedCardsHaveOneStepAndNoCleanupOrPause() throws {
        for (id, sentence, kind, text) in [("open-app", "Open Safari", VoiceStep.Kind.openApp, "Safari"),
                                          ("open-workspace", "Workspace writing", .runWorkspace, "writing")] {
            let template = try XCTUnwrap(catalog.templates.first { $0.id == id })
            XCTAssertEqual(template.card?.group, "mac")
            XCTAssertEqual(template.card?.example, sentence)
            XCTAssertNil(template.cleanUpSlot)
            var config = VoiceLaunchConfig()
            catalog.add(template, to: &config)
            guard case .plan(let plan) = VoiceLaunchEngine.plan(for: sentence, in: config) else { return XCTFail() }
            XCTAssertEqual(plan.steps.map(\.kind), [kind])
            XCTAssertEqual(plan.steps.first?.text, text)
        }
    }

    func testEveryCardAddPathReusesAnIdenticalCustomVoiceCommand() throws {
        for id in ["open-app", "open-workspace", "youtube", "whatsapp", "run-shortcut"] {
            let template = try XCTUnwrap(catalog.templates.first { $0.id == id })
            var original = template.makeCommand()
            original.templateId = nil
            original.enabled = false
            // Keep slot/list spelling intact: only the literal changes case.
            original.pattern = "  " + template.pattern.replacingOccurrences(of: template.pattern.components(separatedBy: " ")[0], with: template.pattern.components(separatedBy: " ")[0].uppercased()) + "  "
            for rightAway in [false, true] {
                var config = VoiceLaunchConfig(commands: [original])
                VoiceCards.turnOn(id, in: &config, catalog: catalog, whatsAppMode: rightAway ? .sendRightAway : .checkFirst,
                                  shortcutMode: rightAway ? .rightAway : .pause)
                XCTAssertEqual(config.commands.count, 1, id)
                // WhatsApp and Run a Shortcut rebuild theirs for the chosen mode; there is still only one.
                if id != "whatsapp", id != "run-shortcut" { XCTAssertEqual(config.commands.first?.id, original.id, id) }
                XCTAssertTrue(config.commands[0].enabled, id)
                XCTAssertTrue(VoiceCards.cards(in: config, catalog: catalog).first { $0.id == id }!.isOn)
                VoiceCards.turnOff(id, in: &config, catalog: catalog)
                XCTAssertFalse(config.commands[0].enabled)
            }
            var config = VoiceLaunchConfig(commands: [original])
            catalog.add(template, to: &config)
            catalog.add(template, to: &config)
            XCTAssertEqual(config.commands.count, 1, id)
            XCTAssertTrue(config.commands[0].enabled)
        }
    }
}

extension VoiceLaunchCardsTests {
    func testCardsRejectForeignPatternsWithoutMutatingOrClaimingThem() throws {
        for id in ["open-app", "whatsapp", VoiceCards.runShortcutCard] {
            let template = try XCTUnwrap(catalog.templates.first { $0.id == id })
            for enabled in [false, true] {
                var foreign = VoiceCommand(name: "My old actions", pattern: template.pattern,
                                                  steps: [VoiceStep(kind: .typeText, text: "old actions")])
                foreign.enabled = enabled
                var config = VoiceLaunchConfig()
                config.commands = [foreign]
                let original = config
                let card = try XCTUnwrap(VoiceCards.cards(in: config, catalog: catalog).first { $0.id == id })
                XCTAssertFalse(card.isOn)
                XCTAssertFalse(card.isAdded)
                let expected = "You already have a command that listens for these words: My old actions. Turn it on or change it."
                XCTAssertEqual(VoiceCards.turnOn(id, in: &config, catalog: catalog), expected)
                XCTAssertEqual(config, original)
                XCTAssertEqual(catalog.add(template, to: &config), expected)
                XCTAssertEqual(config, original)
                if id == "whatsapp" {
                    XCTAssertEqual(VoiceCards.setWhatsAppMode(.sendRightAway, in: &config, catalog: catalog), expected)
                } else if id == VoiceCards.runShortcutCard {
                    XCTAssertEqual(VoiceCards.setShortcutMode(.rightAway, in: &config, catalog: catalog), expected)
                }
                XCTAssertEqual(config, original)
                VoiceCards.turnOff(id, in: &config, catalog: catalog)
                XCTAssertEqual(config, original, "A card must never disable someone else's shortcut either")
            }
        }
    }

    func testCardsReuseIdenticalActionsWithFreshStepIDsAndKeepFamilyEdits() throws {
        for id in ["open-app", "whatsapp", VoiceCards.runShortcutCard] {
            let template = try XCTUnwrap(catalog.templates.first { $0.id == id })
            var config = VoiceLaunchConfig()
            var copy = template.makeCommand()
            copy.templateId = nil
            copy.enabled = false
            config.commands = [copy]
            XCTAssertNil(VoiceCards.turnOn(id, in: &config, catalog: catalog))
            XCTAssertEqual(config.commands.count, 1)
            XCTAssertTrue(config.commands[0].enabled)
            XCTAssertTrue(VoiceCards.cards(in: config, catalog: catalog).first { $0.id == id }!.isOn)
            VoiceCards.turnOff(id, in: &config, catalog: catalog)
            XCTAssertFalse(config.commands[0].enabled)
            config.commands[0].templateId = id
            config.commands[0].steps = [VoiceStep(kind: .typeText, text: "my edited template")]
            XCTAssertNil(VoiceCards.turnOn(id, in: &config, catalog: catalog))
            XCTAssertEqual(config.commands.count, 1)
            XCTAssertEqual(config.commands[0].steps[0].text, "my edited template")
        }
    }
}
