import XCTest
@testable import Dictator

final class VoiceLaunchEditingTests: XCTestCase {
    private let catalog = VoiceCommandCatalog(
        version: 2, allowedLinkSchemes: ["https", "whatsapp"],
        lists: [.init(name: "People", fields: ["phone", "email"])],
        templates: [
            .init(id: "whatsapp", name: "WhatsApp", pattern: "WhatsApp {person:People} {message}", cleanUpSlot: "message",
                  steps: [VoiceStep(kind: .openLink, link: "whatsapp://send?phone={person.phone}&text={message}")]),
            .init(id: "google", name: "Google", pattern: "Google {query}", cleanUpSlot: nil,
                  steps: [VoiceStep(kind: .openLink, link: "https://www.google.com/search?q={query}")]),
            .init(id: "later", name: "Later", pattern: "Later {x}", cleanUpSlot: nil, steps: [VoiceStep(kind: .webhook, link: "https://e.com")]),
        ])

    private func dana() -> VoiceListEntry {
        VoiceListEntry(id: "d", names: ["Dana", "Danny"], values: ["phone": "+972 50", "email": "d@e.com"])
    }

    // MARK: Lists

    func testAddListGivesUniqueNames() {
        var config = VoiceLaunchConfig()
        config.addList(named: "People", fields: ["phone"])
        let second = config.addList(named: " people ")
        XCTAssertEqual(second.name, "people 2")
        XCTAssertEqual(config.lists.count, 2)
        XCTAssertEqual(config.addList(named: "  ").name, "New list")
    }

    func testSavingAListEditsEntriesAndFields() {
        var config = VoiceLaunchConfig()
        var list = config.addList(named: "People", fields: ["phone"])
        list.fields.append("email")
        list.entries.append(dana())
        XCTAssertNil(config.save(list))
        XCTAssertEqual(config.lists[0].entries[0].displayName, "Dana")
        list.entries[0].names = ["Dana", "D"]
        list.entries[0].values["email"] = nil
        XCTAssertNil(config.save(list))
        XCTAssertEqual(config.lists[0].entries[0].names, ["Dana", "D"])
        list.entries.removeAll()
        XCTAssertNil(config.save(list))
        XCTAssertTrue(config.lists[0].entries.isEmpty)
    }

    func testInvalidListIsRefusedAndNothingChanges() {
        var config = VoiceLaunchConfig()
        var list = config.addList(named: "People")
        list.fields = ["bad field"]
        XCTAssertNotNil(config.save(list))
        XCTAssertEqual(config.lists[0].fields, [])
        var other = VoiceList(name: "people")
        other.id = "x"
        XCTAssertNotNil(config.save(other), "two lists with the same name")
        XCTAssertEqual(config.lists.count, 1)
    }

    func testEntryNamesFromText() {
        XCTAssertEqual(VoiceListEntry.names(from: "Dana,  Danny ,, \nD"), ["Dana", "Danny", "D"])
    }

    func testRenamingAListUpdatesPatterns() {
        var config = VoiceLaunchConfig()
        catalog.add(catalog.templates[0], to: &config)
        var list = config.lists[0]
        list.name = "Friends"
        XCTAssertNil(config.save(list))
        XCTAssertEqual(config.commands[0].pattern, "WhatsApp {person:Friends} {message}")
        XCTAssertNil(config.validate(allowedSchemes: ["whatsapp"]))
    }

    func testRemovingAListInUseIsRefused() {
        var config = VoiceLaunchConfig()
        catalog.add(catalog.templates[0], to: &config)
        let id = config.lists[0].id
        let reason = config.removeList(id: id)
        XCTAssertTrue(reason?.contains("WhatsApp") == true)
        XCTAssertEqual(config.lists.count, 1)
        config.commands.removeAll()
        XCTAssertNil(config.removeList(id: id))
        XCTAssertTrue(config.lists.isEmpty)
    }

    func testRemovingAFieldStillUsedIsRefused() {
        var config = VoiceLaunchConfig()
        catalog.add(catalog.templates[0], to: &config)
        var list = config.lists[0]
        list.fields.removeAll { $0 == "phone" }
        XCTAssertTrue(config.save(list)?.contains("phone") == true)
        XCTAssertEqual(config.lists[0].fields, ["phone", "email"])
    }

    // MARK: Ready-made

    func testAddingATemplateCreatesItsListEmptyWithFields() {
        var config = VoiceLaunchConfig()
        catalog.add(catalog.templates[0], to: &config)
        XCTAssertEqual(config.lists.map(\.name), ["People"])
        XCTAssertEqual(config.lists[0].fields, ["phone", "email"])
        XCTAssertTrue(config.lists[0].entries.isEmpty)
        XCTAssertEqual(config.commands.count, 1)
        XCTAssertEqual(config.commands[0].templateId, "whatsapp")
    }

    func testAddingATemplateKeepsAnExistingList() {
        var config = VoiceLaunchConfig()
        config.lists = [VoiceList(name: "people", fields: ["phone", "email"], entries: [dana()])]
        catalog.add(catalog.templates[0], to: &config)
        XCTAssertEqual(config.lists.count, 1)
        XCTAssertEqual(config.lists[0].entries.count, 1)
    }

    func testAddingATemplateWithoutListsAddsNone() {
        var config = VoiceLaunchConfig()
        catalog.add(catalog.templates[1], to: &config)
        XCTAssertTrue(config.lists.isEmpty)
    }

    func testRunnableTemplatesIncludeListOnesAndSkipUnsupportedSteps() {
        XCTAssertEqual(catalog.runnable(supported: [.openLink]).map(\.id), ["whatsapp", "google"])
        XCTAssertEqual(catalog.runnable(supported: [.openLink, .webhook]).map(\.id), ["whatsapp", "google", "later"])
    }

    func testStepMenuIsDrivenBySupportedKinds() {
        XCTAssertEqual(VoiceStep.Kind.addable(supported: [.typeText, .openLink]), [.openLink, .typeText])
        XCTAssertTrue(VoiceStep.Kind.addable().contains(.webhook))
        XCTAssertTrue(VoiceStep.Kind.addable().contains(.runInTerminal))
    }

    func testStepsMove() {
        var steps = [VoiceStep(id: "a", kind: .openApp), VoiceStep(id: "b", kind: .waitForTextField), VoiceStep(id: "c", kind: .typeText)]
        steps.move("c", by: -1)
        XCTAssertEqual(steps.map(\.id), ["a", "c", "b"])
        steps.move("a", by: -1)
        steps.move("b", by: 1)
        XCTAssertEqual(steps.map(\.id), ["a", "c", "b"])
    }

    // MARK: Try it

    private func tryConfig() -> VoiceLaunchConfig {
        var config = VoiceLaunchConfig()
        catalog.add(catalog.templates[0], to: &config)
        catalog.add(catalog.templates[1], to: &config)
        config.lists[0].entries = [dana()]
        return config
    }

    func testTryItMatched() {
        guard case .matched(let name, let slots, let steps) = VoiceTryItResult.result(for: "WhatsApp Dana I'll be late & soon", in: tryConfig()) else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(name, "WhatsApp")
        XCTAssertEqual(slots.map(\.name), ["person", "message"])
        XCTAssertEqual(slots[0].value, "Dana")
        XCTAssertEqual(slots[1].value, "I'll be late & soon")
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].title, "Open a link")
        XCTAssertEqual(steps[0].detail, "whatsapp://send?phone=%2B972%2050&text=I%27ll%20be%20late%20%26%20soon")
    }

    func testTryItNoMatchReasons() {
        XCTAssertEqual(VoiceTryItResult.result(for: "  ", in: tryConfig()), .noMatch(VoiceTryItResult.explain(.nothingSaid)))
        // Words no shortcut starts with are a near miss (with a one-click fix), not a plain "no match".
        guard case .nearMiss(let miss) = VoiceTryItResult.result(for: "hello there", in: tryConfig()) else { return XCTFail() }
        XCTAssertEqual(miss.kind, .trigger)
        XCTAssertFalse(VoiceTryItResult.explain(.noneMatched).isEmpty)
        XCTAssertEqual(VoiceTryItResult.result(for: "Google cats", in: .empty), .noMatch(VoiceTryItResult.explain(.noCommands)))
        XCTAssertTrue(VoiceTryItResult.explain(.tie(["A", "B"])).contains("A, B"))
        // Preview the same no-insertion fallback used by shortcut-mode delivery.
        for reason: NoMatchReason in [.noCommands, .noneMatched, .tie(["A", "B"])] {
            let explanation = VoiceTryItResult.explain(reason)
            XCTAssertTrue(explanation.contains("clipboard"), explanation)
            XCTAssertFalse(explanation.contains("typed"), explanation)
        }
    }

    // MARK: Progress

    private func plan() -> VoiceLaunchPlan {
        VoiceLaunchPlan(commandId: "s", commandName: "Notes", slots: [], steps: [
            VoiceStep(kind: .openApp, bundleId: "com.example.nope"), VoiceStep(kind: .waitForTextField), VoiceStep(kind: .typeText, text: "hi")],
                        mainText: "hi")
    }

    func testProgressStartsWaiting() {
        let progress = VoiceLaunchProgress(plan: plan())
        XCTAssertEqual(progress.commandName, "Notes")
        XCTAssertEqual(progress.rows.map(\.state), [.waiting, .waiting, .waiting])
        XCTAssertFalse(progress.isFinished)
    }

    func testProgressRunsToTheEnd() {
        var progress = VoiceLaunchProgress(plan: plan())
        progress.apply(.stepStarted(0))
        XCTAssertEqual(progress.rows.map(\.state), [.running, .waiting, .waiting])
        for i in 0..<3 { progress.apply(.stepStarted(i)); progress.apply(.stepDone(i)) }
        XCTAssertEqual(progress.rows.map(\.state), [.done, .done, .done])
        XCTAssertTrue(progress.isFinished)
        XCTAssertFalse(progress.hasFailed)
    }

    func testProgressStopsAtAFailure() {
        var progress = VoiceLaunchProgress(plan: plan())
        progress.apply(.stepDone(0))
        progress.apply(.stepStarted(1))
        progress.apply(.stepFailed(1))
        XCTAssertEqual(progress.rows.map(\.state), [.done, .failed, .waiting])
        XCTAssertTrue(progress.hasFailed)
        XCTAssertTrue(progress.isFinished)
        progress.apply(.stepDone(9))
        XCTAssertEqual(progress.rows.count, 3)
    }


    // MARK: New list

    func testANewListIsOnlyAddedWhenItsEditorSaves() {
        var config = VoiceLaunchConfig()
        config.addList(named: "New list")
        let before = config
        let draft = config.newListDraft(named: "New list")
        XCTAssertEqual(draft.name, "New list 2")
        XCTAssertEqual(config, before, "opening the editor (then Cancel) changes nothing")
        var edited = draft
        edited.name = "Places"
        XCTAssertNil(config.save(edited))
        XCTAssertEqual(config.lists.map(\.name), ["New list", "Places"])
    }

    // MARK: Save problem

    func testASaveProblemGoesAwayOnceTheVoiceCommandIsEdited() {
        var voiceCommand = VoiceCommand(id: "s", name: "", pattern: "Google {q}", steps: [VoiceStep(kind: .openLink, link: "https://g.com/{q}")])
        let problem = VoiceSaveProblem("Give it a name.", voiceCommand)
        XCTAssertEqual(problem.message(for: voiceCommand), "Give it a name.")
        voiceCommand.name = "Google"
        XCTAssertNil(problem.message(for: voiceCommand))
    }

    // MARK: People

    func testPeopleSayWhatTheyCantBeReachedBy() {
        XCTAssertNil(VoicePeople.missingNote(dana()))
        XCTAssertEqual(VoicePeople.missingNote(VoiceListEntry(names: ["A"], values: ["email": "a@b.c"])),
                       "No phone number yet, so WhatsApp can’t reach them.")
        XCTAssertNotNil(VoicePeople.missingNote(VoiceListEntry(names: ["A"], values: ["phone": "", "email": " "])))
    }
}

final class VoiceWorkspaceLinkTests: XCTestCase {
    private func linked(_ phrase: String = "Start writing", id: String = "voice", workspace: String = "writing") -> VoiceCommand {
        VoiceWorkspaceLink.draft(workspaceId: workspace, name: "Writing", phrase: phrase, id: id)
    }

    func testAddFindChangeAndRemoveUseRoutineIdentity() throws {
        var config = VoiceLaunchConfig.empty
        XCTAssertNil(VoiceWorkspaceLink.add(workspaceId: "writing", name: "Writing", phrase: "  Start writing  ", id: "voice", to: &config))
        let voiceCommand = try XCTUnwrap(VoiceWorkspaceLink.find("writing", in: config))
        XCTAssertEqual(voiceCommand.name, "Writing")
        XCTAssertEqual(voiceCommand.pattern, "Start writing")
        XCTAssertTrue(voiceCommand.enabled)
        XCTAssertNil(voiceCommand.cleanUpSlot)
        XCTAssertEqual(voiceCommand.steps.map(\.kind), [.runWorkspace])
        XCTAssertEqual(voiceCommand.steps.first?.workspaceId, "writing")
        XCTAssertNil(config.validate())
        XCTAssertNil(VoiceWorkspaceLink.find("other", in: config))
        XCTAssertNil(VoiceWorkspaceLink.changePhrase("Time to write", commandId: "voice", in: &config))
        XCTAssertEqual(VoiceWorkspaceLink.find("writing", in: config)?.pattern, "Time to write")
        VoiceWorkspaceLink.remove("writing", from: &config)
        XCTAssertTrue(config.commands.isEmpty)
    }

    func testInvalidLiteralPhrasesNeverMutateConfig() {
        var config = VoiceLaunchConfig.empty
        for phrase in ["", " \n ", "!!!", "Start {writing}", "Start [writing]", "Start }writing", "Start writing]", String(repeating: "word ", count: 100)] {
            let before = config
            XCTAssertNotNil(VoiceWorkspaceLink.add(workspaceId: "writing", name: "Writing", phrase: phrase, to: &config), phrase)
            XCTAssertEqual(config, before)
        }
        XCTAssertNil(VoiceWorkspaceLink.add(workspaceId: "writing", name: "Writing", phrase: "זמן לכתוב", to: &config))
        let before = config
        XCTAssertNotNil(VoiceWorkspaceLink.changePhrase("Start {writing}", commandId: config.commands[0].id, in: &config))
        XCTAssertEqual(config, before)
    }

    func testConflictsNameTheOtherVoiceCommandIncludingOffAliasesAndSlotSentences() {
        let others = [
            VoiceCommand(name: "My command", pattern: "Start writing", steps: [.init(kind: .typeText, text: "")]),
            VoiceCommand(name: "My command", pattern: "Begin writing", steps: [.init(kind: .typeText, text: "")], enabled: false, triggerAliases: ["Start writing"]),
            VoiceCommand(name: "My command", pattern: "Start writing", steps: [.init(kind: .typeText, text: "")], enabled: false),
            VoiceCommand(name: "My command", pattern: "Begin writing", steps: [.init(kind: .typeText, text: "")], triggerAliases: ["Start writing"]),
            VoiceCommand(name: "My command", pattern: "Start {what}", steps: [.init(kind: .typeText, text: "{what}")]),
        ]
        for other in others {
            var config = VoiceLaunchConfig(version: 2, lists: [], commands: [other])
            let before = config
            let problem = VoiceWorkspaceLink.add(workspaceId: "writing", name: "Writing", phrase: "START writing.", to: &config)
            XCTAssertEqual(problem, other.enabled
                ? "“My command” already listens for those words. Choose different words."
                : "“My command” already uses those words, but it's turned off. Choose different words, or change it in Commands.")
            XCTAssertEqual(config, before)
        }
    }

    func testLimitBlocksAddsButAllowsEditingAtTheLimit() {
        var config = VoiceLaunchConfig.empty
        for i in 0..<VoiceLaunchConfig.maxCommands { config.commands.append(linked("Command \(i)", id: "v\(i)", workspace: "w\(i)")) }
        let before = config
        XCTAssertTrue(VoiceWorkspaceLink.add(workspaceId: "extra", name: "Extra", phrase: "One more", to: &config)?.contains("100") == true)
        XCTAssertEqual(config, before)
        XCTAssertNil(VoiceWorkspaceLink.changePhrase("New words", commandId: "v0", in: &config))
        XCTAssertEqual(config.commands.count, VoiceLaunchConfig.maxCommands)
    }

    func testPhraseEditPreservesAdvancedEditsAndDisabledState() {
        var voiceCommand = linked()
        voiceCommand.enabled = false
        voiceCommand.name = "My display name"
        voiceCommand.triggerAliases = ["Begin writing"]
        voiceCommand.steps.append(.init(kind: .typeText, text: "Hello"))
        var config = VoiceLaunchConfig(version: 2, lists: [], commands: [voiceCommand])
        XCTAssertNil(VoiceWorkspaceLink.changePhrase("Time to write", commandId: voiceCommand.id, in: &config))
        var expected = voiceCommand
        expected.pattern = "Time to write"
        XCTAssertEqual(config.commands, [expected])
    }

    func testRenameAndDeleteAllLinksPreserveOtherActionsAndCustomNames() {
        var custom = linked("Other phrase", id: "custom")
        custom.name = "My name"
        custom.steps.append(.init(kind: .typeText, text: "Hello"))
        let unrelated = linked("Different routine", id: "unrelated", workspace: "other")
        var config = VoiceLaunchConfig(version: 2, lists: [], commands: [linked(), custom, unrelated])
        XCTAssertEqual(VoiceWorkspaceLink.commands(for: "writing", in: config).map(\.id), ["voice", "custom"])
        VoiceWorkspaceLink.rename("writing", from: "Writing", to: "Drafting", in: &config)
        XCTAssertEqual(config.commands.map(\.name), ["Drafting", "My name", "Writing"])
        XCTAssertEqual(config.commands[0].pattern, "Start writing")
        VoiceWorkspaceLink.remove("writing", from: &config)
        XCTAssertEqual(config.commands.map(\.id), ["custom", "unrelated"])
        XCTAssertEqual(config.commands[0].steps.map(\.kind), [.typeText])
        XCTAssertEqual(config.commands[1], unrelated)
    }

    func testRemoveOneLinkLeavesOtherLinksAlone() {
        let second = linked("Second phrase", id: "second")
        var config = VoiceLaunchConfig(version: 2, lists: [], commands: [linked(), second])
        VoiceWorkspaceLink.remove("writing", commandId: "voice", from: &config)
        XCTAssertEqual(config.commands, [second])
    }

    func testIDSurvivesRenderingDeferralAndMainMacDelivery() throws {
        let config = VoiceLaunchConfig(version: 2, lists: [], commands: [linked()])
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: "Start writing.", in: config) else { return XCTFail() }
        XCTAssertEqual(plan.steps.first?.workspaceId, "writing")
        XCTAssertEqual(plan.steps.first?.text, "Start writing.")
        XCTAssertEqual(plan.mainText, "Start writing.")
        let wire = CoreMessage.launchInsert(sessionId: "synthetic", plan: plan)
        XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(EdgeProtocolCodec.encode(wire)), wire)
        let deferred = VoiceStepRenderer.deferring(plan.steps[0], slots: [], cleanUpSlot: nil, said: "Start writing.")
        XCTAssertEqual(VoiceStepRenderer.resolve(deferred, answers: [:], mac: "Test").workspaceId, "writing")
        XCTAssertNil(try JSONDecoder().decode(VoiceStep.self, from: Data(#"{"kind":"runWorkspace","text":"Writing"}"#.utf8)).workspaceId)
        XCTAssertNotNil(VoiceBuildProblems.problem(for: VoiceLaunchConfig.empty, editing: VoiceCommand(name: "Bad", pattern: "Bad", steps: [.init(kind: .runWorkspace)])))
    }

    func testSummariesUseCurrentRoutineNameAndActualKey() {
        let step = VoiceStep(kind: .runWorkspace, text: "Old name", workspaceId: "writing")
        let routines = [WorkspaceRoutine(id: "writing", name: "Drafting", actions: [])]
        XCTAssertEqual(VoiceBuildCopy.summary(step, routines: routines), "Runs routine “Drafting”")
        XCTAssertEqual(VoiceBuildCopy.summary(of: [step], routines: routines), "Runs routine “Drafting”")
        XCTAssertEqual(VoiceBuildCopy.summary(step), "Runs a routine that was removed")
        XCTAssertEqual(VoiceBuildCopy.howToSay(keys: HotkeyTriggers(dictation: KeyCombo(DictationKey(keyCode: 54))).commands, phrase: "Start writing"), "Hold Right ⌘ + Right Shift and say “Start writing”.")
    }
}
