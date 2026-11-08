import XCTest
@testable import Dictator

/// "Your Shortcuts" and the Run a Shortcut card. Synthetic only: the
/// `shortcuts` program is never run; a mock stands in.
@MainActor
final class VoiceYourShortcutsTests: XCTestCase {
    private let catalog: VoiceCommandCatalog = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/shortcut-catalog.json")
        return try! JSONDecoder().decode(VoiceCommandCatalog.self, from: Data(contentsOf: url))
    }()

    private final class Log { var lines: [String] = [] }

    private func services(log: Log = Log(), run: @escaping VoiceLaunchProcessRunner) -> VoiceLaunchServices {
        VoiceLaunchServices(
            confirm: { _, tick in tick(3); return true },
            setClipboard: { _ in }, pressKey: { _ in true }, frontmostBundleId: { nil },
            runProcess: run, session: URLSession(configuration: .ephemeral),
            now: { Date(timeIntervalSince1970: 0) }, macName: { "Test Mac" }, log: { log.lines.append($0) })
    }

    private let idA = "1B2C3D4E-0000-1111-2222-333344445555"
    private let idB = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private let idC = "CCCCCCCC-1111-2222-3333-444444444444"

    private func infos() -> [AppleShortcutInfo] {
        [AppleShortcutInfo(name: "lights", identifier: idA), AppleShortcutInfo(name: "lights off", identifier: idB),
         AppleShortcutInfo(name: "Reminder für Jürgen", identifier: idC)]
    }

    private func configWithCard(_ mode: ShortcutRunMode = .pause, shortcuts: [AppleShortcutInfo]? = nil) -> VoiceLaunchConfig {
        var config = VoiceLaunchConfig()
        VoiceCards.turnOn("run-shortcut", in: &config, catalog: catalog, shortcutMode: mode)
        XCTAssertTrue(VoiceYourShortcuts.merge(shortcuts ?? infos(), into: &config, catalog: catalog))
        return config
    }

    private func plan(_ sentence: String, _ config: VoiceLaunchConfig) throws -> VoiceLaunchPlan {
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: sentence, in: config) else { throw XCTSkip("no plan for \(sentence)") }
        return plan
    }

    // MARK: List refresh parsing

    func testListParsingKeepsSpacesUnicodeAndDropsDuplicates() {
        let output = """
        Lights off (\(idA))
        Lights off (\(idA))
        Reminder für Jürgen (\(idB))
        שלום עולם (\(idC))
        Plain name
        Same name (\(idA.replacingOccurrences(of: "1", with: "2")))
        Same name (\(idB.replacingOccurrences(of: "A", with: "B")))

        """
        let list = VoiceShortcutList.parse(output)
        XCTAssertEqual(list.filter { $0.name == "Lights off" }.count, 1)
        XCTAssertTrue(list.contains { $0.name == "Reminder für Jürgen" && $0.identifier == idB })
        XCTAssertTrue(list.contains { $0.name == "שלום עולם" && $0.identifier == idC })
        XCTAssertTrue(list.contains { $0.name == "Plain name" && $0.identifier == nil })
        XCTAssertEqual(list.filter { $0.name == "Same name" }.count, 2)
    }

    func testMergeFillsTheListWithNamesAndIdentifiersAndDropsSameNamedTwins() {
        var config = VoiceLaunchConfig()
        let twins = [AppleShortcutInfo(name: "Same name", identifier: idA), AppleShortcutInfo(name: "same  NAME", identifier: idB),
                     AppleShortcutInfo(name: "Reminder für Jürgen", identifier: idC)]
        XCTAssertTrue(VoiceYourShortcuts.merge(twins, into: &config, catalog: catalog))
        let entries = VoiceYourShortcuts.entries(in: config)
        XCTAssertEqual(entries.map(\.displayName), ["Same name", "Reminder für Jürgen"])
        XCTAssertEqual(entries[0].values, ["identifier": idA])
        XCTAssertEqual(config.list(named: "your shortcuts")?.fields, ["identifier"])
        XCTAssertNil(config.validate(allowedSchemes: catalog.allowedLinkSchemes))
    }

    func testRefreshKeepsAliasesByIdentifierEvenWhenARenameHappensAndDropsGoneOnes() {
        var config = configWithCard()
        let id = VoiceYourShortcuts.entries(in: config).first { $0.displayName == "lights off" }!.id
        let listId = config.list(named: "Your Shortcuts")!.id
        XCTAssertNil(config.addEntryAlias("light soff", listId: listId, entryId: id))
        // Renamed in the Shortcuts app, another one gone, a new one added.
        let after = [AppleShortcutInfo(name: "lights out", identifier: idB), AppleShortcutInfo(name: "new one", identifier: "DDDDDDDD-1111-2222-3333-444444444444")]
        XCTAssertTrue(VoiceYourShortcuts.merge(after, into: &config, catalog: catalog))
        let entries = VoiceYourShortcuts.entries(in: config)
        XCTAssertEqual(entries.map(\.displayName), ["lights out", "new one"])
        XCTAssertEqual(entries[0].id, id)
        XCTAssertEqual(entries[0].names, ["lights out", "light soff"])
    }

    func testAnAliasThatBecomesAnotherShortcutsNameIsDropped() {
        var config = configWithCard()
        let list = config.list(named: "Your Shortcuts")!
        let lightsOff = list.entries.first { $0.displayName == "lights off" }!
        XCTAssertNil(config.addEntryAlias("lamps", listId: list.id, entryId: lightsOff.id))
        VoiceYourShortcuts.merge(infos() + [AppleShortcutInfo(name: "Lamps", identifier: "EEEEEEEE-1111-2222-3333-444444444444")], into: &config, catalog: catalog)
        XCTAssertEqual(VoiceYourShortcuts.entries(in: config).first { $0.displayName == "lights off" }?.names, ["lights off"])
    }

    func testRefreshCapsTheListAtTheLimit() {
        var config = VoiceLaunchConfig()
        let many = (0..<(VoiceLaunchConfig.maxEntriesPerList + 20)).map { AppleShortcutInfo(name: "Shortcut number \($0)", identifier: nil) }
        XCTAssertTrue(VoiceYourShortcuts.merge(many, into: &config, catalog: catalog))
        XCTAssertEqual(VoiceYourShortcuts.entries(in: config).count, VoiceLaunchConfig.maxEntriesPerList)
    }

    // MARK: When the list is refreshed

    func testOnlyTheMainMacFillsTheListAndOnlyWhenUsedOrAsked() async {
        var calls = 0
        let run: VoiceLaunchProcessRunner = { _, args, _ in
            calls += 1
            XCTAssertEqual(args, ["list", "--show-identifiers"])
            return VoiceLaunchProcessResult(status: 0, timedOut: false, stdout: "One (\(self.idA))\n", stderr: "")
        }
        let unused = VoiceLaunchConfig()
        let used = configWithCard()
        let edge = await VoiceLaunchActing.fetchYourShortcuts(role: .edge, config: used, force: true, services: services(run: run))
        XCTAssertNil(edge)
        let idle = await VoiceLaunchActing.fetchYourShortcuts(role: .core, config: unused, force: false, services: services(run: run))
        XCTAssertNil(idle)
        XCTAssertEqual(calls, 0)
        let onLaunch = await VoiceLaunchActing.fetchYourShortcuts(role: .core, config: used, force: false, services: services(run: run))
        XCTAssertEqual(onLaunch?.map(\.name), ["One"])
        let opened = await VoiceLaunchActing.fetchYourShortcuts(role: .standalone, config: unused, force: true, services: services(run: run))
        XCTAssertEqual(opened?.map(\.name), ["One"])
        XCTAssertEqual(calls, 2)
    }

    func testAFailedRefreshLeavesTheListAsItWas() async {
        let config = configWithCard()
        let failed = await VoiceLaunchActing.fetchYourShortcuts(role: .core, config: config, force: true,
                                                                services: services(run: { _, _, _ in VoiceLaunchProcessResult(status: 1, timedOut: false) }))
        XCTAssertNil(failed)
        let missing = await VoiceLaunchActing.fetchYourShortcuts(role: .core, config: config, force: true, services: services(run: { _, _, _ in nil }))
        XCTAssertNil(missing)
    }

    // MARK: Matching

    func testTheLongestNameWins() throws {
        let config = configWithCard()
        let off = try plan("Shortcut lights off", config)
        XCTAssertEqual(off.slots.first { $0.name == "which" }?.value, "lights off")
        XCTAssertEqual(off.slots.first { $0.name == "words" }?.value, "")
        let just = try plan("Shortcut lights", config)
        XCTAssertEqual(just.slots.first { $0.name == "which" }?.value, "lights")
        let more = try plan("Shortcut lights off in the kitchen", config)
        XCTAssertEqual(more.slots.first { $0.name == "which" }?.value, "lights off")
        XCTAssertEqual(more.slots.first { $0.name == "words" }?.value, "in the kitchen")
        let umlaut = try plan("shortcut reminder für jürgen call him", config)
        XCTAssertEqual(umlaut.slots.first { $0.name == "which" }?.fields?["identifier"], idC)
    }

    func testThePlanRunsTheMatchedShortcutByIdentifierWithEverythingSaid() throws {
        let plan = try plan("Shortcut lights off now please", configWithCard())
        let run = try XCTUnwrap(plan.steps.last)
        XCTAssertEqual(run.kind, .runAppleShortcut)
        XCTAssertEqual(run.shortcutName, "lights off")
        XCTAssertEqual(run.shortcutId, idB)
        XCTAssertTrue(run.sendsEverything)
        XCTAssertEqual(VoiceLaunchActing.runTarget(run), idB)
        // The JSON is built on the Mac that runs it, from everything said.
        let ready = VoiceStepRenderer.resolve(run, answers: [:], mac: "Test Mac")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((ready.text ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(object["shortcut"] as? String, "lights off")
        XCTAssertEqual(object["said"] as? String, "Shortcut lights off now please")
        XCTAssertEqual((object["values"] as? [String: Any])?["words"] as? String, "now please")
    }

    func testANameThatLooksLikeAnOptionIsNeverPassedToShortcuts() async {
        var config = VoiceLaunchConfig()
        VoiceCards.turnOn("run-shortcut", in: &config, catalog: catalog, shortcutMode: .rightAway)
        XCTAssertTrue(VoiceYourShortcuts.merge([AppleShortcutInfo(name: "-h", identifier: nil)], into: &config, catalog: catalog))
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: "Shortcut -h", in: config) else { return XCTFail() }
        var ran = false
        let result = await VoiceLaunchExecutor.run(plan, services: services(run: { _, _, _ in ran = true; return VoiceLaunchProcessResult(status: 0, timedOut: false) }))
        guard case .stopped = result else { return XCTFail("\(result)") }
        XCTAssertFalse(ran)
    }

    // MARK: Aliases on this list

    func testAnAddedWayToSayAShortcutMatchesAndTravelsWithTheSetting() throws {
        var config = configWithCard()
        let list = config.list(named: "Your Shortcuts")!
        let lights = list.entries.first { $0.displayName == "lights off" }!
        XCTAssertNil(config.addEntryAlias("light switch off", listId: list.id, entryId: lights.id))
        let heard = try plan("Shortcut light switch off", config)
        XCTAssertEqual(heard.slots.first { $0.name == "which" }?.value, "lights off")
        XCTAssertEqual(heard.steps.last?.shortcutId, idB)
        // The setting is what is mirrored: encode and decode keeps the way to say it.
        let copy = try XCTUnwrap(VoiceLaunchConfig.decode(config.encoded()))
        XCTAssertEqual(VoiceYourShortcuts.entries(in: copy).first { $0.displayName == "lights off" }?.names, ["lights off", "light switch off"])
        // Another Shortcut's name can't become an alias.
        XCTAssertEqual(config.addEntryAlias("lights", listId: list.id, entryId: lights.id), .takenByEntry("lights"))
    }

    func testCheckNameWorksOnThisListAndNamesGoToWhisper() {
        var config = configWithCard()
        let list = config.list(named: "Your Shortcuts")!
        let lights = list.entries.first { $0.displayName == "lights off" }!
        let outcome = VoiceCheckName.outcome(heard: ["light soff", "lights off"], entryId: lights.id, in: list)
        XCTAssertEqual(outcome.toSave, ["light soff"])
        XCTAssertEqual(VoiceCheckName.save(outcome, listId: list.id, entryId: lights.id, in: &config), ["light soff"])
        let hints = VoiceLaunchEngine.hintWords(config)
        XCTAssertTrue(hints.contains("lights off"))
        XCTAssertTrue(hints.contains("Reminder für Jürgen"))
        XCTAssertTrue(hints.contains("light soff"))
    }

    func testANearMissOnAShortcutNameOffersDidYouMean() throws {
        let config = configWithCard()
        guard case .nearMiss(let miss) = VoiceLaunchEngine.plan(for: "Shortcut remindr fur jurgen", in: config) else {
            return XCTFail("expected a near miss")
        }
        XCTAssertEqual(miss.kind, .entry)
        XCTAssertEqual(miss.slotName, "which")
        XCTAssertTrue(miss.candidates.contains { $0.name == "Reminder für Jürgen" })
    }

    // MARK: The card

    func testTheCardIsOffByDefaultAndTurnsOnWithThePauseByDefault() throws {
        let cards = VoiceCards.cards(in: VoiceLaunchConfig(), catalog: catalog)
        let card = try XCTUnwrap(cards.first { $0.id == "run-shortcut" })
        XCTAssertFalse(card.isOn)
        XCTAssertFalse(card.isAdded)
        XCTAssertEqual(card.ask, .shortcuts)
        XCTAssertEqual(card.title, "Run a Shortcut")
        XCTAssertEqual(card.pattern, "Shortcut {which:Your Shortcuts} {words}")

        var config = VoiceLaunchConfig()
        VoiceCards.turnOn("run-shortcut", in: &config, catalog: catalog)
        XCTAssertEqual(VoiceCards.shortcutMode(in: config, catalog: catalog), .pause)
        XCTAssertEqual(config.commands.count, 1)
        XCTAssertEqual(config.commands[0].steps.map(\.kind), [.confirm, .runAppleShortcut])
        XCTAssertEqual(config.commands[0].steps[0].seconds, 3)
        XCTAssertNotNil(config.list(named: "Your Shortcuts"))
        XCTAssertNil(config.validate(allowedSchemes: catalog.allowedLinkSchemes))
        XCTAssertTrue(VoiceCards.cards(in: config, catalog: catalog).first { $0.id == "run-shortcut" }!.isOn)
    }

    func testRightAwayHasNoPauseAndSwitchingKeepsTheWaysOfStartingIt() throws {
        var config = VoiceLaunchConfig()
        VoiceCards.turnOn("run-shortcut", in: &config, catalog: catalog, shortcutMode: .rightAway)
        XCTAssertEqual(VoiceCards.shortcutMode(in: config, catalog: catalog), .rightAway)
        XCTAssertEqual(config.commands[0].steps.map(\.kind), [.runAppleShortcut])
        XCTAssertEqual(config.commands[0].pattern, "Shortcut {which:Your Shortcuts} {words}")
        XCTAssertNil(config.validate(allowedSchemes: catalog.allowedLinkSchemes))
        config.commands[0].triggerAliases = ["short cut"]
        VoiceCards.setShortcutMode(.pause, in: &config, catalog: catalog)
        XCTAssertEqual(config.commands.count, 1)
        XCTAssertEqual(config.commands[0].triggerAliases, ["short cut"])
        XCTAssertEqual(config.commands[0].steps.map(\.kind), [.confirm, .runAppleShortcut])
        XCTAssertNil(config.validate(allowedSchemes: catalog.allowedLinkSchemes))
    }

    func testTurningTheCardOffKeepsItAndOffMeansNoMatch() throws {
        var config = configWithCard()
        VoiceCards.turnOff("run-shortcut", in: &config, catalog: catalog)
        XCTAssertFalse(config.commands[0].enabled)
        XCTAssertTrue(VoiceCards.cards(in: config, catalog: catalog).first { $0.id == "run-shortcut" }!.isAdded)
        if case .plan = VoiceLaunchEngine.plan(for: "Shortcut lights off", in: config) { XCTFail("a card that is off must not run") }
        VoiceCards.turnOn("run-shortcut", in: &config, catalog: catalog)
        XCTAssertTrue(config.commands[0].enabled)
        XCTAssertEqual(config.commands.count, 1)
    }

    func testThePauseComesBeforeTheShortcutRuns() async throws {
        let plan = try plan("Shortcut lights off", configWithCard(.pause))
        var events: [String] = []
        var services = services(run: { _, _, _ in events.append("run"); return VoiceLaunchProcessResult(status: 0, timedOut: false) })
        services.confirm = { _, _ in events.append("pause"); return false }
        let cancelled = await VoiceLaunchExecutor.run(plan, services: services)
        guard case .cancelled = cancelled else { return XCTFail("\(cancelled)") }
        XCTAssertEqual(events, ["pause"])
        services.confirm = { _, _ in events.append("pause"); return true }
        events = []
        let done = await VoiceLaunchExecutor.run(plan, services: services)
        guard case .done = done else { return XCTFail("\(done)") }
        XCTAssertEqual(events, ["pause", "run"])
    }

    func testTheExampleSentenceIsColouredByRole() {
        let empty = VoiceCards.cards(in: VoiceLaunchConfig(), catalog: catalog).first { $0.id == "run-shortcut" }!
        let segments = VoiceCards.segments(for: empty, config: VoiceLaunchConfig())
        XCTAssertEqual(segments.map(\.text), ["Shortcut", "lights off"])
        XCTAssertEqual(segments.map(\.role), [.opens, .which])
        // With Shortcuts listed, the first one stands in.
        let config = configWithCard()
        let card = VoiceCards.cards(in: config, catalog: catalog).first { $0.id == "run-shortcut" }!
        XCTAssertEqual(VoiceCards.segments(for: card, config: config).map(\.text), ["Shortcut", "lights"])
    }

    // MARK: A Shortcut this Mac doesn't have

    func testAMissingShortcutFailsInPlainWords() async throws {
        let plan = try plan("Shortcut lights off", configWithCard(.rightAway))
        let log = Log()
        let result = await VoiceLaunchExecutor.run(plan, services: services(log: log, run: { _, args, _ in
            XCTAssertEqual(args.first, "run")
            XCTAssertEqual(args[1], self.idB)
            return VoiceLaunchProcessResult(status: 1, timedOut: false, stdout: "", stderr: "Error: Couldn’t find shortcut “lights off”")
        }))
        guard case .stopped(let alert) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(alert.title, "This Mac doesn’t have the Shortcut “lights off”")
        XCTAssertFalse(alert.title.contains("Error"))
    }
}
