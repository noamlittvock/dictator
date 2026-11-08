import XCTest
@testable import Dictator

/// Pure synthetic values only. No settings singleton, file writes, executor,
/// programs, network, clipboard, microphone or personal data.
final class CommandFileTests: XCTestCase {
    private func fullConfig() -> VoiceLaunchConfig {
        let people = VoiceList(id: "people-structure", name: "People", fields: ["phone", "email"], entries: [
            .init(id: "private-person-id", names: ["Synthetic Person", "Synthetic Alias"], values: ["phone": "000111222", "email": "synthetic@example.invalid"])
        ])
        let projects = VoiceList(id: "projects-structure", name: "Projects", fields: ["folder"], entries: [
            .init(id: "private-project-id", names: ["Synthetic Project"], values: ["folder": "/synthetic/project-private"])
        ])
        let steps: [VoiceStep] = [
            .init(id: "confirm", kind: .confirm, text: "Check {words}", seconds: 3),
            .init(id: "link", kind: .openLink, link: "https://example.invalid/private-page?q={words}"),
            .init(id: "app", kind: .openApp, bundleId: "com.example.synthetic"),
            .init(id: "workspace", kind: .runWorkspace, text: "Synthetic routine", workspaceId: "synthetic-routine"),
            .init(id: "wait", kind: .waitForTextField, seconds: 8),
            .init(id: "type", kind: .typeText, text: "{words}"),
            .init(id: "key", kind: .pressKey, key: "return"),
            .init(id: "terminal", kind: .runInTerminal, folder: "/synthetic/private-folder", command: "echo", argument: "{words}", background: true),
            .init(id: "shortcut", kind: .runAppleShortcut, text: "{words}", shortcutName: "Synthetic action", inputMode: VoiceStep.inputJSON, timeoutSeconds: 30),
            .init(id: "webhook", kind: .webhook, link: "https://example.invalid/private-hook?token=synthetic-secret"),
            .init(id: "file", kind: .appendToFile, text: "{words}", path: "/synthetic/private-file.txt")
        ]
        return VoiceLaunchConfig(lists: [people, projects], commands: [
            .init(id: "private-command-id", name: "Synthetic command", pattern: "Share {person:People} {project:Projects} {words}", cleanUpSlot: "words", steps: steps, enabled: true,
                  triggerAliases: ["Sharing"], hotkey: .init(keyCode: 12, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.option),
                  runsFromOtherApps: true, onlyInApps: ["com.example.synthetic"]),
            .init(id: "not-selected-id", name: "Not selected", pattern: "Unselected", steps: [.init(kind: .typeText, text: "excluded-command-payload")])
        ])
    }

    private func options(_ config: VoiceLaunchConfig, entries: Bool = false, locations: Bool = false) -> CommandFile.ExportOptions {
        .init(commandIDs: [config.commands[0].id], listsWithEntries: entries ? Set(config.lists.map(\.id)) : [], includeLocations: locations)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func file(commands: [VoiceCommand], lists: [VoiceList] = []) throws -> Data {
        let commandObjects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(commands))
        let listObjects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lists))
        return try JSONSerialization.data(withJSONObject: ["dictatorCommands": 1, "commands": commandObjects, "lists": listObjects])
    }

    private func simple(_ phrase: String = "Synthetic", id: String = "synthetic") -> VoiceCommand {
        .init(id: id, name: "Synthetic command", pattern: phrase, steps: [.init(kind: .typeText, text: "Synthetic text")])
    }

    func testFullSyntheticRoundTripUsesExistingEncodingAndResetsPrivileges() throws {
        let original = fullConfig()
        // A key on a spoken command is invalid in settings, but a hand-edited
        // config must still have it stripped, so the fixture keeps it.
        var withoutKey = original
        withoutKey.commands[0].hotkey = nil
        XCTAssertNil(withoutKey.validate())
        let data = try CommandFile.export(original, options: options(original, entries: true, locations: true))
        let draft = try CommandFile.read(data)
        XCTAssertEqual(draft.lists, original.lists)
        var expected = original.commands[0]
        expected.id = draft.commands[0].id
        expected.enabled = false
        expected.hotkey = nil
        expected.runsFromOtherApps = false
        XCTAssertEqual(draft.commands, [expected])
        XCTAssertNotEqual(draft.commands[0].id, original.commands[0].id)
        let saved = try CommandFile.merging(draft, into: .empty)
        XCTAssertNil(saved.validate())
        XCTAssertFalse(saved.commands[0].enabled)
        XCTAssertNil(saved.commands[0].hotkey)
        XCTAssertFalse(saved.commands[0].runsFromOtherApps)
        XCTAssertNotEqual(saved.commands[0].id, draft.commands[0].id)
        XCTAssertNotEqual(saved.lists[0].id, original.lists[0].id)
        XCTAssertNotEqual(saved.lists[0].entries[0].id, original.lists[0].entries[0].id)
        XCTAssertEqual(saved.commands[0].onlyInApps, ["com.example.synthetic"])
    }

    func testDefaultExportContainsNoneOfTheExcludedValuesAnywhereInBytes() throws {
        let config = fullConfig()
        let data = try CommandFile.export(config, options: options(config))
        let bytes = try XCTUnwrap(String(data: data, encoding: .utf8))
        for excluded in ["hotkey", "runsFromOtherApps", "private-command-id", "not-selected-id", "excluded-command-payload", "private-person-id", "Synthetic Person", "Synthetic Alias", "000111222", "synthetic@example.invalid", "private-project-id", "Synthetic Project", "project-private", "private-page", "private-folder", "private-file", "private-hook", "synthetic-secret"] {
            XCTAssertFalse(bytes.contains(excluded), excluded)
        }
        let root = try object(data)
        XCTAssertEqual(root["dictatorCommands"] as? Int, 1)
        let commands = try XCTUnwrap(root["commands"] as? [[String: Any]])
        XCTAssertNil(commands[0]["id"])
        XCTAssertNil(commands[0]["hotkey"])
        XCTAssertNil(commands[0]["runsFromOtherApps"])
        XCTAssertEqual(commands[0]["onlyInApps"] as? [String], ["com.example.synthetic"])
        let draft = try CommandFile.read(data)
        XCTAssertEqual(draft.lists.map(\.name), ["People", "Projects"])
        XCTAssertEqual(draft.lists.map(\.fields), [["phone", "email"], ["folder"]])
        XCTAssertTrue(draft.lists.allSatisfy { $0.entries.isEmpty })
        XCTAssertEqual(draft.commands[0].steps.filter(CommandFile.needsValue).count, 4)
        XCTAssertThrowsError(try CommandFile.merging(draft, into: .empty)) { XCTAssertEqual($0 as? CommandFile.Problem, .unfinished) }
    }

    func testListOptInIsPerListAndLocationsHaveOneIndependentChoice() throws {
        let config = fullConfig()
        var choice = options(config, locations: true)
        choice.listsWithEntries = [config.lists[0].id]
        let data = try CommandFile.export(config, options: choice)
        let draft = try CommandFile.read(data)
        XCTAssertEqual(draft.lists[0].entries, config.lists[0].entries)
        XCTAssertTrue(draft.lists[1].entries.isEmpty)
        XCTAssertEqual(draft.commands[0].steps.first { $0.kind == .webhook }?.link, config.commands[0].steps.first { $0.kind == .webhook }?.link)
        XCTAssertNil(try object(data)["hotkey"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-command-id"))
    }

    func testLocationsPreviewIncludesFullEmbeddedValuesAndSelectedEntryDetails() throws {
        var config = fullConfig()
        config.commands[0].steps.append(.init(kind: .typeText, text: "See https://example.invalid/embedded and /synthetic/embedded"))
        let preview = try CommandFile.locations(in: config, options: options(config, entries: true))
        for marker in ["private-page", "private-hook", "private-folder", "private-file", "project-private", "synthetic@example.invalid", "embedded"] {
            XCTAssertTrue(preview.contains { $0.contains(marker) }, marker)
        }
        let data = try CommandFile.export(config, options: options(config, entries: true))
        let bytes = String(decoding: data, as: UTF8.self)
        for marker in ["private-page", "private-hook", "private-folder", "private-file", "project-private", "synthetic@example.invalid", "embedded"] {
            XCTAssertFalse(bytes.contains(marker), marker)
        }
    }

    func testOnlyReferencedListsAreExported() throws {
        var config = fullConfig()
        config.lists.append(.init(name: "Unused", entries: [.init(names: ["Unused private entry"])]))
        let data = try CommandFile.export(config, options: options(config, entries: true, locations: true))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Unused"))
    }

    func testUntrustedPrivilegeFieldsCannotEnableAnything() throws {
        let command = fullConfig().commands[0]
        let data = try file(commands: [command], lists: fullConfig().lists)
        let a = try CommandFile.read(data)
        let b = try CommandFile.read(data)
        XCTAssertFalse(a.commands[0].enabled)
        XCTAssertNil(a.commands[0].hotkey)
        XCTAssertFalse(a.commands[0].runsFromOtherApps)
        XCTAssertNotEqual(a.commands[0].id, command.id)
        XCTAssertNotEqual(a.commands[0].id, b.commands[0].id)
        var forged = a
        forged.commands[0].enabled = true
        forged.commands[0].hotkey = command.hotkey
        forged.commands[0].runsFromOtherApps = true
        let result = try CommandFile.merging(forged, into: .empty)
        XCTAssertFalse(result.commands[0].enabled)
        XCTAssertNil(result.commands[0].hotkey)
        XCTAssertFalse(result.commands[0].runsFromOtherApps)
    }

    func testUnknownTopLevelKeysAreIgnoredAndNewerFormatIsRefusedFirst() throws {
        var root = try object(file(commands: [simple()]))
        root["future"] = ["ignored": true]
        XCTAssertEqual(try CommandFile.read(JSONSerialization.data(withJSONObject: root)).commands.count, 1)
        root["dictatorCommands"] = 2
        root["commands"] = "not readable yet"
        XCTAssertThrowsError(try CommandFile.read(JSONSerialization.data(withJSONObject: root))) {
            XCTAssertEqual($0 as? CommandFile.Problem, .newer)
            XCTAssertEqual($0.localizedDescription, "This file needs a newer Dictator.")
        }
    }

    func testUnknownStepKindIsNewerWithoutChangingExistingConfig() throws {
        let existing = VoiceLaunchConfig(commands: [simple()])
        let before = existing
        var root = try object(file(commands: [simple()]))
        var commands = try XCTUnwrap(root["commands"] as? [[String: Any]])
        commands[0]["steps"] = [["kind": "futureSyntheticKind"]]
        root["commands"] = commands
        XCTAssertThrowsError(try CommandFile.read(JSONSerialization.data(withJSONObject: root))) {
            XCTAssertEqual($0 as? CommandFile.Problem, .newer)
        }
        XCTAssertEqual(existing, before)
    }

    func testMalformedAndOversizeFilesAreRefused() throws {
        for text in ["", "not JSON", "[]", "{}", #"{"dictatorCommands":true,"commands":[],"lists":[]}"#, #"{"dictatorCommands":1.5,"commands":[],"lists":[]}"#, #"{"dictatorCommands":0,"commands":[],"lists":[]}"#, #"{"dictatorCommands":1,"commands":{},"lists":[]}"#, #"{"dictatorCommands":1,"commands":[{"steps":[{}]}],"lists":[]}"#] {
            XCTAssertThrowsError(try CommandFile.read(Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try CommandFile.read(Data(repeating: 32, count: CommandFile.maxBytes + 1))) {
            XCTAssertEqual($0 as? CommandFile.Problem, .tooLarge)
        }
        let valid = try file(commands: [simple()])
        let atLimit = valid + Data(repeating: 32, count: CommandFile.maxBytes - valid.count)
        XCTAssertEqual(try CommandFile.read(atLimit).commands.count, 1)
    }

    func testLimitsAndValidationAreNotBypassedByDisabledCommands() throws {
        let tooManyCommands = (0...VoiceLaunchConfig.maxCommands).map { simple("Synthetic \($0)", id: "c\($0)") }
        let tooManyLists = (0...VoiceLaunchConfig.maxLists).map { VoiceList(name: "List \($0)") }
        let tooManyEntries = (0...VoiceLaunchConfig.maxEntriesPerList).map { VoiceListEntry(names: ["Entry \($0)"]) }
        var tooManySteps = simple()
        tooManySteps.steps = (0...VoiceLaunchConfig.maxStepsPerCommand).map { _ in .init(kind: .typeText, text: "Synthetic") }
        var tooLong = simple()
        tooLong.steps[0].text = String(repeating: "s", count: VoiceLaunchConfig.maxTextLength + 1)
        var invalidScheme = simple()
        invalidScheme.steps = [.init(kind: .openLink, link: "synthetic-invalid:hello")]
        var missingList = simple("Synthetic {person:Missing}")
        missingList.steps = [.init(kind: .typeText, text: "{person}")]
        var unconfirmed = simple()
        unconfirmed.steps = [.init(kind: .pressKey, key: "return")]
        for (commands, lists) in [(tooManyCommands, []), ([simple()], tooManyLists), ([simple()], [VoiceList(name: "Synthetic", entries: tooManyEntries)]), ([tooManySteps], []), ([tooLong], []), ([invalidScheme], []), ([missingList], []), ([unconfirmed], [])] {
            XCTAssertThrowsError(try CommandFile.read(file(commands: commands, lists: lists)))
        }
    }

    func testListsMergeByNameWithoutOverwritingNamesAliasesValuesOrIDs() throws {
        let oldEntry = VoiceListEntry(id: "existing-entry", names: ["Synthetic", "Existing alias"], values: ["phone": "000"])
        let oldList = VoiceList(id: "existing-list", name: "People", fields: ["phone"], entries: [oldEntry])
        let existing = VoiceLaunchConfig(lists: [oldList])
        let imported = VoiceList(name: " PEOPLE ", fields: ["phone", "email"], entries: [
            .init(id: oldEntry.id, names: ["Existing alias", "Imported alias"], values: ["phone": "999"]),
            .init(id: "second-entry", names: ["New synthetic"], values: ["email": "new@example.invalid"])
        ])
        let draft = try CommandFile.read(file(commands: [simple()], lists: [imported]))
        let saved = try CommandFile.merging(draft, into: existing)
        XCTAssertEqual(existing.lists, [oldList])
        XCTAssertEqual(saved.lists.count, 1)
        XCTAssertEqual(saved.lists[0].id, oldList.id)
        XCTAssertEqual(saved.lists[0].name, oldList.name)
        XCTAssertEqual(saved.lists[0].fields, ["phone", "email"])
        XCTAssertEqual(saved.lists[0].entries.count, 2)
        XCTAssertEqual(saved.lists[0].entries[0], oldEntry)
        XCTAssertNotEqual(saved.lists[0].entries[1].id, oldEntry.id)
    }

    func testMergeChecksCombinedLimitsAtomically() throws {
        let existing = VoiceLaunchConfig(commands: (0..<VoiceLaunchConfig.maxCommands).map { simple("Existing \($0)", id: "e\($0)") })
        let before = existing
        let draft = try CommandFile.read(file(commands: [simple("New phrase")]))
        XCTAssertThrowsError(try CommandFile.merging(draft, into: existing))
        XCTAssertEqual(existing, before)
        let entries = (0..<VoiceLaunchConfig.maxEntriesPerList).map { VoiceListEntry(names: ["Entry \($0)"]) }
        let lists = VoiceLaunchConfig(lists: [.init(name: "People", entries: entries)])
        let incoming = try CommandFile.read(file(commands: [simple()], lists: [.init(name: "People", entries: [.init(names: ["Extra synthetic"])])]))
        XCTAssertThrowsError(try CommandFile.merging(incoming, into: lists))
        XCTAssertEqual(lists.lists[0].entries.count, VoiceLaunchConfig.maxEntriesPerList)
    }

    func testPhraseClashesAreVisibleOffAndRequireResolutionBeforeSave() throws {
        var existingCommand = simple("Synthetic", id: "existing")
        existingCommand.enabled = false
        let existing = VoiceLaunchConfig(commands: [existingCommand])
        var draft = try CommandFile.read(file(commands: [simple("SYNTHETIC.")]))
        XCTAssertNotNil(CommandFile.clash(for: draft.commands[0], among: existing.commands))
        XCTAssertFalse(draft.commands[0].enabled)
        XCTAssertThrowsError(try CommandFile.merging(draft, into: existing))
        draft.commands[0].pattern = "New phrase"
        XCTAssertNil(CommandFile.clash(for: draft.commands[0], among: existing.commands))
        XCTAssertEqual(try CommandFile.merging(draft, into: existing).commands.map(\.enabled), [false, false])
        draft.commands[0].triggerAliases = ["Synthetic"]
        XCTAssertNotNil(CommandFile.clash(for: draft.commands[0], among: existing.commands))
        XCTAssertThrowsError(try CommandFile.merging(draft, into: existing))
    }

    func testHostileStringsAreFlaggedAndShownWithVisibleControlCharacters() throws {
        for text in ["synthetic\u{200B}value", "synthetic\u{202E}value", "synthetic\u{0000}value", "synthetic\u{FEFF}value"] {
            XCTAssertFalse(CommandFile.warnings(in: text).isEmpty)
            XCTAssertTrue(CommandFile.visible(text).contains("[U+"))
        }
        for text in ["syntheti\u{0441}", "https://ex\u{0430}mple.invalid", "Synthetic שלום", "Աա ქართული"] {
            XCTAssertTrue(CommandFile.warnings(in: text).contains { $0.contains("writing systems") })
        }
        XCTAssertTrue(CommandFile.warnings(in: "Synthetic English 123").isEmpty)
        XCTAssertTrue(CommandFile.warnings(in: "שלום עולם").isEmpty)
        XCTAssertFalse(CommandFile.warnings(in: VoiceStep(kind: .typeText, text: "synthetic\u{200B}value")).isEmpty)
        var invalid = simple()
        invalid.steps = [.init(kind: .runInTerminal, folder: "/synthetic", command: "syntheti\u{0441}")]
        XCTAssertThrowsError(try CommandFile.read(file(commands: [invalid])))
        let harmless = simple("Synthetic\u{200B}")
        let draft = try CommandFile.read(file(commands: [harmless]))
        XCTAssertFalse(draft.commands[0].enabled)
        XCTAssertFalse(CommandFile.warnings(in: draft.commands[0].pattern).isEmpty)
    }

    func testEveryActingStepShowsFullDetailsAndCheckThis() {
        for step in fullConfig().commands[0].steps {
            XCTAssertEqual(CommandFile.checkThis(step), ![VoiceStep.Kind.confirm, .waitForTextField].contains(step.kind))
            let details = CommandFile.details(step)
            for value in [step.link, step.path, step.folder, step.command, step.argument, step.text, step.shortcutName, step.shortcutId].compactMap({ $0 }) {
                XCTAssertTrue(details.contains(CommandFile.visible(value)), value)
            }
        }
        XCTAssertTrue(CommandFile.details(.init(kind: .runInTerminal, folder: "/synthetic")).contains(VoiceLaunchConfig.defaultAgentCommand))
        XCTAssertTrue(CommandFile.details(.init(kind: .runInTerminal, folder: "/synthetic", command: "echo", background: true)).contains("In the background"))
    }

    func testDuplicateReviewIDsAreRefused() throws {
        var command = simple()
        command.steps = [.init(id: "same", kind: .typeText, text: "One"), .init(id: "same", kind: .typeText, text: "Two")]
        XCTAssertThrowsError(try CommandFile.read(file(commands: [command])))
        let duplicateEntries = VoiceList(name: "Synthetic", entries: [.init(id: "same", names: ["One"]), .init(id: "same", names: ["Two"])])
        XCTAssertThrowsError(try CommandFile.read(file(commands: [simple()], lists: [duplicateEntries])))
        XCTAssertThrowsError(try CommandFile.read(file(commands: [simple()], lists: [.init(id: "same", name: "One"), .init(id: "same", name: "Two")])))
    }

    func testBlankedProgramCannotSilentlyUseTheDefaultProgram() throws {
        var command = simple()
        command.steps = [.init(kind: .runInTerminal, folder: "/synthetic", command: "/synthetic/program")]
        let config = VoiceLaunchConfig(commands: [command])
        let data = try CommandFile.export(config, options: .init(commandIDs: [command.id]))
        var draft = try CommandFile.read(data)
        draft.commands[0].steps[0].folder = "/synthetic"
        XCTAssertTrue(CommandFile.needsValue(draft.commands[0].steps[0]))
        XCTAssertThrowsError(try CommandFile.merging(draft, into: .empty))
        draft.commands[0].steps[0].command = "echo"
        XCTAssertEqual(try CommandFile.merging(draft, into: .empty).commands[0].steps[0].command, "echo")
    }

    func testRuntimeOnlyDeferredStepsAreRefused() throws {
        var root = try object(file(commands: [simple()]))
        var commands = try XCTUnwrap(root["commands"] as? [[String: Any]])
        commands[0]["steps"] = [["kind": "typeText", "text": "Synthetic", "deferred": [:]]]
        root["commands"] = commands
        XCTAssertThrowsError(try CommandFile.read(JSONSerialization.data(withJSONObject: root)))
    }
}
