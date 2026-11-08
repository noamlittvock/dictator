import XCTest
@testable import Dictator

/// Synthetic only: the `shortcuts` program is never run; a mock stands in.
@MainActor
final class VoiceShortcutBridgeTests: XCTestCase {
    // MARK: Helpers

    private final class Log { var lines: [String] = [] }

    private func services(log: Log = Log(), mac: String = "Test Mac", run: @escaping VoiceLaunchProcessRunner) -> VoiceLaunchServices {
        VoiceLaunchServices(
            confirm: { _, tick in tick(3); return true },
            setClipboard: { _ in },
            pressKey: { _ in true },
            frontmostBundleId: { nil },
            runProcess: run,
            session: URLSession(configuration: .ephemeral),
            now: { Date(timeIntervalSince1970: 0) },
            macName: { mac },
            log: { log.lines.append($0) })
    }

    private func ok(_ answer: String? = nil, stderr: String = "") -> VoiceLaunchProcessRunner {
        { _, args, _ in
            if let answer, let path = args.firstIndex(of: "--output-path").map({ args[$0 + 1] }) { try? answer.write(toFile: path, atomically: true, encoding: .utf8) }
            return VoiceLaunchProcessResult(status: 0, timedOut: false, stdout: "", stderr: stderr)
        }
    }

    private func config(steps: [VoiceStep], pattern: String = "Remind {task}", cleanUp: String? = nil) -> VoiceLaunchConfig {
        VoiceLaunchConfig(lists: [
            VoiceList(name: "People", fields: ["phone"], entries: [VoiceListEntry(names: ["Dana"], values: ["phone": "+972 50"])]),
        ], commands: [VoiceCommand(id: "r", name: "Remind", pattern: pattern, cleanUpSlot: cleanUp, steps: steps)])
    }

    private func shortcutStep(id: String = "s1", readOnly: Bool? = true, text: String? = nil, json: Bool = true) -> VoiceStep {
        VoiceStep(id: id, kind: .runAppleShortcut, text: text, shortcutName: "Remind", inputMode: json ? VoiceStep.inputJSON : nil, readOnly: readOnly)
    }

    private func makePlan(_ sentence: String, _ config: VoiceLaunchConfig) throws -> VoiceLaunchPlan {
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: sentence, in: config) else { throw XCTSkip("no plan") }
        return plan
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: JSON input

    func testInputJSONHasEverythingSaidByName() throws {
        let values: [String: VoiceRenderValue] = [
            "task": .text("call Dana"), "time": .text("5"),
            "person": .entry(name: "Dana", fields: ["phone": "+972…", "email": "d@x.test"]),
        ]
        let json = VoiceShortcutInput.json(shortcut: "Remind", said: "remind me to call Dana at 5", values: values, mac: "Noam's Macbook")
        let root = try object(json)
        XCTAssertEqual(root["shortcut"] as? String, "Remind")
        XCTAssertEqual(root["said"] as? String, "remind me to call Dana at 5")
        XCTAssertEqual(root["mac"] as? String, "Noam's Macbook")
        let parsed = try XCTUnwrap(root["values"] as? [String: Any])
        XCTAssertEqual(parsed["task"] as? String, "call Dana")
        XCTAssertEqual(parsed["person"] as? [String: String], ["name": "Dana", "phone": "+972…", "email": "d@x.test"])
    }

    func testInputJSONKeepsHebrewAndSpecialCharacters() throws {
        let json = VoiceShortcutInput.json(shortcut: "תזכורת", said: "תזכיר לי \"לקנות\" חלב / ביצים", values: ["task": .text("לקנות חלב\nו\"ביצים\"")], mac: "")
        XCTAssertTrue(json.contains("תזכיר לי"), "Hebrew isn't escaped")
        XCTAssertTrue(json.contains("חלב / ביצים"), "slashes aren't escaped")
        let root = try object(json)
        XCTAssertEqual((root["values"] as? [String: String])?["task"], "לקנות חלב\nו\"ביצים\"")
    }

    func testJSONInputUsesTheCleanedValueAndTheRawWords() throws {
        // The Core replaces the cleaned slot before rendering; the raw sentence stays as said.
        var match = try XCTUnwrap({ () -> VoiceLaunchMatch? in
            if case .matched(let m) = VoiceLaunchEngine.match("Remind um call dana at five", in: config(steps: [shortcutStep()], cleanUp: "task")) { return m }
            return nil
        }())
        match.slots["task"] = .text("Call Dana at 5.")
        let plan = VoiceLaunchEngine.render(match, in: config(steps: [shortcutStep()], cleanUp: "task"))
        let step = VoiceStepRenderer.resolve(plan.steps[0], answers: [:], mac: "Mac")
        let root = try object(step.text ?? "")
        XCTAssertEqual(root["said"] as? String, "Remind um call dana at five")
        XCTAssertEqual((root["values"] as? [String: String])?["task"], "Call Dana at 5.")
        XCTAssertNil(step.deferred)
    }

    func testTheRunWritesInputJSONForNewActionsAndTextForOlderOnes() async throws {
        var names: [String] = []
        var contents: [String] = []
        let run: VoiceLaunchProcessRunner = { _, args, _ in
            let path = args[3]
            names.append((path as NSString).lastPathComponent)
            contents.append((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            return VoiceLaunchProcessResult(status: 0, timedOut: false)
        }
        try await VoiceLaunchActing.runAppleShortcut(VoiceStep(kind: .runAppleShortcut, text: "{\"a\":1}", shortcutName: "S", inputMode: "json"), services: services(run: run))
        try await VoiceLaunchActing.runAppleShortcut(VoiceStep(kind: .runAppleShortcut, text: "hello", shortcutName: "S"), services: services(run: run))
        XCTAssertEqual(names, ["input.json", "input.txt"])
        XCTAssertEqual(contents, ["{\"a\":1}", "hello"])
    }

    // MARK: Arguments (no shell)

    func testArgumentsAreArraysAndPreferTheIdentifier() {
        let hostile = "Log; rm -rf ~ $(x) `y` \"z\""
        let byName = VoiceStep(kind: .runAppleShortcut, shortcutName: hostile)
        XCTAssertEqual(VoiceLaunchActing.runTarget(byName), hostile)
        XCTAssertEqual(VoiceLaunchActing.shortcutRunArguments(target: hostile, inputPath: "/tmp/a b/input.json", outputPath: "/tmp/a b/output.txt"),
                       ["run", hostile, "--input-path", "/tmp/a b/input.json", "--output-path", "/tmp/a b/output.txt", "--output-type", "public.plain-text"])
        var byId = byName
        byId.shortcutId = "1B2C3D4E-0000-1111-2222-333344445555"
        XCTAssertEqual(VoiceLaunchActing.runTarget(byId), "1B2C3D4E-0000-1111-2222-333344445555")
        byId.shortcutId = "  "
        XCTAssertEqual(VoiceLaunchActing.runTarget(byId), hostile)
        XCTAssertEqual(VoiceLaunchActing.listArguments(), ["list", "--show-identifiers"])
        XCTAssertEqual(VoiceLaunchActing.viewArguments(name: "A B; c"), ["view", "A B; c"])
        XCTAssertEqual(VoiceLaunchActing.shortcutsExecutable, "/usr/bin/shortcuts")
    }

    func testTheRunUsesPrivateFilesAndRemovesThem() async throws {
        var perms: [String: Int] = [:]
        var dir = ""
        var seen: [String] = []
        let run: VoiceLaunchProcessRunner = { exe, args, timeout in
            seen = [exe] + args + ["\(Int(timeout))"]
            let input = args[3]
            dir = (input as NSString).deletingLastPathComponent
            perms["dir"] = (try? FileManager.default.attributesOfItem(atPath: dir))?[.posixPermissions] as? Int
            perms["input"] = (try? FileManager.default.attributesOfItem(atPath: input))?[.posixPermissions] as? Int
            try? "ok".write(toFile: args[5], atomically: true, encoding: .utf8)
            return VoiceLaunchProcessResult(status: 0, timedOut: false)
        }
        var step = VoiceStep(kind: .runAppleShortcut, text: "x", shortcutName: "Remind", inputMode: "json")
        step.shortcutId = "1B2C3D4E-0000-1111-2222-333344445555"
        step.timeoutSeconds = 60
        let answer = try await VoiceLaunchActing.runAppleShortcut(step, services: services(run: run))
        XCTAssertEqual(answer.text, "ok")
        XCTAssertEqual(perms["dir"], 0o700)
        XCTAssertEqual(perms["input"], 0o600)
        XCTAssertEqual(seen.first, "/usr/bin/shortcuts")
        XCTAssertEqual(seen[2], "1B2C3D4E-0000-1111-2222-333344445555")
        XCTAssertEqual(seen.last, "60")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    func testNewActionsDefaultToJSONAndOldSettingsStayPlainText() throws {
        XCTAssertTrue(VoiceStep.Kind.runAppleShortcut.makeStep().sendsEverything)
        let old = try JSONDecoder().decode(VoiceStep.self, from: Data(#"{"kind":"runAppleShortcut","text":"{q}","shortcutName":"Do it"}"#.utf8))
        XCTAssertFalse(old.sendsEverything)
        XCTAssertNil(old.inputMode)
        XCTAssertNil(old.timeoutSeconds)
        XCTAssertNil(old.readOnly)
        XCTAssertTrue(old.isActing)
        XCTAssertNil(VoiceStepRenderer.templateFields(of: VoiceStep.Kind.runAppleShortcut.makeStep())["text"])
        XCTAssertEqual(VoiceStepRenderer.templateFields(of: old)["text"], "{q}")
        // A plain-text step is not deferred; it renders on the Core as before.
        XCTAssertFalse(VoiceStepRenderer.needsDeferral(old))
        // Stored settings round-trip with the new fields.
        var step = VoiceStep.Kind.runAppleShortcut.makeStep()
        step.shortcutId = "AAAAAAAA-1111"; step.timeoutSeconds = 120; step.readOnly = true; step.answerDetails = ["title"]
        XCTAssertEqual(try JSONDecoder().decode(VoiceStep.self, from: JSONEncoder().encode(step)), step)
    }

    // MARK: Answers

    func testAnswerTextJSONEmptyAndOversize() throws {
        XCTAssertEqual(VoiceShortcutAnswer.parse("  hello\n"), VoiceShortcutAnswer(text: "hello", keys: [:]))
        XCTAssertEqual(VoiceShortcutAnswer.parse(""), VoiceShortcutAnswer(text: "", keys: [:]))
        let json = VoiceShortcutAnswer.parse(#"{"title":"Call Dana","count":3,"done":false,"tags":["a","b"],"none":null}"#)
        XCTAssertEqual(json.keys["title"], "Call Dana")
        XCTAssertEqual(json.keys["count"], "3")
        XCTAssertEqual(json.keys["done"], "false")
        XCTAssertEqual(json.keys["tags"], #"["a","b"]"#)
        XCTAssertEqual(json.keys["none"], "")
        XCTAssertTrue(json.text.hasPrefix("{"))
        // Text that only looks like JSON stays text.
        XCTAssertEqual(VoiceShortcutAnswer.parse("{not json").keys, [:])
        XCTAssertEqual(VoiceShortcutAnswer.parse("[1,2]").keys, [:])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-answer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.txt")
        try String(repeating: "x", count: 70_000).write(to: big, atomically: true, encoding: .utf8)
        let read = VoiceShortcutAnswer.read(from: big)
        XCTAssertTrue(read.truncated)
        XCTAssertEqual(read.answer.text.count, VoiceShortcutAnswer.maxBytes)
        let missing = VoiceShortcutAnswer.read(from: dir.appendingPathComponent("nope.txt"))
        XCTAssertEqual(missing.answer.text, "")
        XCTAssertFalse(missing.truncated)
    }

    func testEmptyAnswerIsNotAFailureAndAnOversizeOneIsLogged() async throws {
        let empty = try await VoiceLaunchActing.runAppleShortcut(shortcutStep(), services: services(run: { _, _, _ in VoiceLaunchProcessResult(status: 0, timedOut: false) }))
        XCTAssertEqual(empty.text, "")
        let log = Log()
        let big = try await VoiceLaunchActing.runAppleShortcut(shortcutStep(), services: services(log: log, run: ok(String(repeating: "y", count: 70_000))))
        XCTAssertEqual(big.text.count, 65_536)
        XCTAssertTrue(log.lines.contains { $0.contains("answer cut") })
    }

    func testAnswerNamesAndBubbles() {
        let step = VoiceStep(id: "ab-12", kind: .runAppleShortcut, shortcutName: "Remind", answerDetails: ["title"])
        XCTAssertEqual(step.answerKey, "answer_ab12")
        XCTAssertEqual(step.answerName, "answer from Remind")
        let later = InsertableValue.available(pattern: "Remind {task}", config: .empty, before: [step])
        XCTAssertEqual(later.map(\.name), ["task", "answer from Remind", "answer from Remind’s title"])
        XCTAssertEqual(later.map(\.kind), [.words, .answer, .answer])
        XCTAssertEqual(InsertableValue.available(pattern: "Remind {task}", config: .empty).map(\.name), ["task"])
        // Bubbles use the plain name; a value that is gone still gets one.
        let parts = ValueText.parts("Hi {answer_ab12.title} {answer_zz}", values: later)
        XCTAssertEqual(parts, [.text("Hi "), .value(later[2]), .text(" "),
                               .value(InsertableValue(template: "{answer_zz}", name: "answer", kind: .answer))])
        XCTAssertEqual(ValueText.plain("{answer_ab12}", values: later), "the answer from Remind")
    }

    // MARK: Deferred rendering

    func testAStepThatUsesAnAnswerIsCarriedAsATemplate() throws {
        let use = VoiceStep(kind: .openLink, link: "https://x.test/?q={answer_s1}&t={task}")
        let plan = try makePlan("Remind call Dana", config(steps: [shortcutStep(), use]))
        let carried = plan.steps[1]
        XCTAssertEqual(carried.link, "", "an older Mac finds nothing to open")
        let deferred = try XCTUnwrap(carried.deferred)
        XCTAssertEqual(deferred.templates["link"], "https://x.test/?q={answer_s1}&t={task}")
        XCTAssertEqual(deferred.slots, [VoicePlanSlot(name: "task", value: "call Dana", fields: nil)])
        XCTAssertNotNil(plan.steps[0].deferred, "the input file is built on the Mac that runs it")
        // A step without an answer is rendered on the Core as before.
        let plainPlan = try makePlan("Remind call Dana", config(steps: [VoiceStep(kind: .typeText, text: "{task}")]))
        XCTAssertEqual(plainPlan.steps[0].text, "call Dana")
        XCTAssertNil(plainPlan.steps[0].deferred)
        // It survives the network.
        let launch = CoreMessage.launchInsert(sessionId: "s", plan: plan)
        XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(EdgeProtocolCodec.encode(launch, id: "1")), launch)
    }

    func testDeferredRenderingUsesTheSameEncodings() throws {
        let answers: [String: VoiceRenderValue] = ["answer_s1": VoiceShortcutAnswer.parse(#"{"title":"a&b #1 שלום"}"#).renderValue]
        func run(_ step: VoiceStep, pattern: String = "Remind {task}", cleanUp: String? = nil, sentence: String = "Remind call, Dana.") throws -> VoiceStep {
            let plan = try makePlan(sentence, config(steps: [shortcutStep(), step], pattern: pattern, cleanUp: cleanUp))
            return VoiceStepRenderer.resolve(plan.steps[1], answers: answers, mac: "M")
        }
        // URL: percent-encoded as a query component, like the Core does. A
        // text slot loses its trailing full stop, unless it is the cleaned one.
        let link = try run(VoiceStep(kind: .openLink, link: "https://x.test/?a={answer_s1.title}&all={answer_s1}&t={task}"))
        XCTAssertEqual(link.link, "https://x.test/?a=a%26b%20%231%20%D7%A9%D7%9C%D7%95%D7%9D&all=%7B%22title%22%3A%22a%26b%20%231%20%D7%A9%D7%9C%D7%95%D7%9D%22%7D&t=call%2C%20Dana")
        let kept = try run(VoiceStep(kind: .openLink, link: "https://x.test/?t={task}&a={answer_s1.title}"), cleanUp: "task")
        XCTAssertTrue(kept.link?.contains("t=call%2C%20Dana.&") == true, kept.link ?? "")
        // Raw for typing and files.
        XCTAssertEqual(try run(VoiceStep(kind: .typeText, text: "Title: {answer_s1.title} / {task}")).text, "Title: a&b #1 שלום / call, Dana.")
        XCTAssertEqual(try run(VoiceStep(kind: .appendToFile, text: "{answer_s1.missing}|")).text, "|")
        // Terminal: raw, then one shell word in the script.
        let terminal = try run(VoiceStep(kind: .runInTerminal, folder: "~/Work", command: "claude", argument: "{answer_s1.title} $(x) 'q'"))
        XCTAssertEqual(terminal.argument, "a&b #1 שלום $(x) 'q'")
        XCTAssertTrue(ShellQuote.terminalScript(folder: "~/Work", command: "claude", argument: terminal.argument ?? "").contains("exec claude 'a&b #1 שלום $(x) '\\''q'\\'''"))
        XCTAssertNil(terminal.deferred)
        // JSON: the input file for a second Shortcut carries what was said.
        let second = VoiceStep(id: "s2", kind: .runAppleShortcut, shortcutName: "Next", inputMode: VoiceStep.inputJSON, readOnly: true)
        let secondPlan = try makePlan("Remind call Dana", config(steps: [shortcutStep(), second]))
        let input = VoiceStepRenderer.resolve(secondPlan.steps[1], answers: answers, mac: "Test Mac")
        let root = try object(input.text ?? "")
        XCTAssertEqual(root["shortcut"] as? String, "Next")
        XCTAssertEqual(root["mac"] as? String, "Test Mac")
        XCTAssertEqual(root["said"] as? String, "Remind call Dana")
    }

    func testTryItShowsAPlaceholderInPlaceOfAnAnswer() throws {
        let plan = try makePlan("Remind call Dana", config(steps: [shortcutStep(), VoiceStep(kind: .typeText, text: "Got {answer_s1}")]))
        XCTAssertEqual(VoiceStepDescription.detail(plan.steps[1]), "Got (its answer)")
        XCTAssertEqual(VoiceStepDescription.detail(plan.steps[0]), "everything you said")
        XCTAssertEqual(VoiceBuildCopy.cardTitle(VoiceStep(kind: .typeText, text: "{answer_s1}")), "Type the answer")
        XCTAssertEqual(VoiceBuildCopy.cardTitle(VoiceStep(kind: .typeText, text: "hi {answer_s1}")), "Type my words")
    }

    // MARK: Running a chain with an answer

    func testAnAnswerFlowsIntoALaterStepOnTheTargetMac() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("log.txt")
        let steps = [shortcutStep(), VoiceStep(kind: .appendToFile, text: "{answer_s1.title} for {task}", path: file.path)]
        let plan = try makePlan("Remind call Dana", config(steps: steps))
        var input: [String: Any] = [:]
        let run: VoiceLaunchProcessRunner = { _, args, _ in
            input = (try? self.object(String(contentsOfFile: args[3], encoding: .utf8))) ?? [:]
            try? #"{"title":"Buy milk"}"#.write(toFile: args[5], atomically: true, encoding: .utf8)
            return VoiceLaunchProcessResult(status: 0, timedOut: false)
        }
        let result = await VoiceLaunchExecutor.run(plan, services: services(mac: "Studio", run: run))
        guard case .done = result else { return XCTFail("\(result)") }
        XCTAssertEqual(input["mac"] as? String, "Studio")
        XCTAssertEqual(input["said"] as? String, "Remind call Dana")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasSuffix(" | Buy milk for call Dana\n"))
    }

    func testAFailedShortcutStopsTheChainAndNothingLaterRuns() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("log.txt")
        let steps = [shortcutStep(), VoiceStep(kind: .appendToFile, text: "{answer_s1}", path: file.path)]
        let plan = try makePlan("Remind call Dana", config(steps: steps))
        let log = Log()
        let result = await VoiceLaunchExecutor.run(plan, services: services(log: log, run: { _, _, _ in
            VoiceLaunchProcessResult(status: 1, timedOut: false, stdout: "", stderr: "Error: Couldn’t find shortcut “Remind”")
        }))
        guard case .stopped(let alert) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(alert.title, "This Mac doesn’t have the Shortcut “Remind”")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Failures in plain words

    func testFailureMessagesArePlainAndRawErrorsOnlyGoToTheLog() async {
        let log = Log()
        let step = VoiceStep(kind: .runAppleShortcut, text: "x", shortcutName: "Remind")
        let cases: [(VoiceLaunchProcessResult, String)] = [
            (VoiceLaunchProcessResult(status: 15, timedOut: true, stdout: "", stderr: ""), "“Remind” didn’t finish in time"),
            (VoiceLaunchProcessResult(status: 1, timedOut: false, stdout: "", stderr: "Error: Couldn’t find shortcut 'Remind'"), "This Mac doesn’t have the Shortcut “Remind”"),
            (VoiceLaunchProcessResult(status: 1, timedOut: false, stdout: "", stderr: "Operation not permitted: denied by TCC"), "Shortcuts isn’t allowed to run “Remind”"),
            (VoiceLaunchProcessResult(status: 1, timedOut: false, stdout: "", stderr: "Error Domain=WFWorkflowErrorDomain Code=4 SECRET-DETAIL"), "“Remind” stopped with an error"),
        ]
        for (result, title) in cases {
            do {
                try await VoiceLaunchActing.runAppleShortcut(step, services: services(log: log, run: { _, _, _ in result }))
                XCTFail("should fail")
            } catch let failure as VoiceLaunchExecutor.Failure {
                XCTAssertEqual(failure.alert.title, title)
                XCTAssertFalse((failure.alert.title + failure.alert.detail).contains("Domain"))
                XCTAssertFalse((failure.alert.title + failure.alert.detail).contains("SECRET-DETAIL"))
                XCTAssertTrue(failure.alert.detail.contains("clipboard"))
            } catch { XCTFail("\(error)") }
        }
        XCTAssertTrue(log.lines.contains { $0.contains("SECRET-DETAIL") })
        XCTAssertTrue(log.lines.contains { $0.contains("timed out after 30s") })
    }

    func testTimeoutFollowsTheActionsChoiceAndLogsAreShort() async {
        var seen: TimeInterval = 0
        var step = VoiceStep(kind: .runAppleShortcut, text: "x", shortcutName: "Remind")
        step.timeoutSeconds = 120
        let log = Log()
        do {
            try await VoiceLaunchActing.runAppleShortcut(step, services: services(log: log, run: { _, _, timeout in
                seen = timeout
                return VoiceLaunchProcessResult(status: 15, timedOut: true, stdout: "", stderr: String(repeating: "e", count: 5_000))
            }))
            XCTFail("should fail")
        } catch let failure as VoiceLaunchExecutor.Failure {
            XCTAssertTrue(failure.alert.detail.contains("120 seconds"))
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(seen, 120)
        XCTAssertLessThan(log.lines.joined().count, 700)
        XCTAssertEqual(VoiceStep.shortcutTimeoutChoices, [10, 30, 60, 120])
        XCTAssertEqual(VoiceStep.defaultShortcutTimeout, 30)
    }

    func testAShortcutThatCannotStartIsAPlainFailure() async {
        do {
            try await VoiceLaunchActing.runAppleShortcut(VoiceStep(kind: .runAppleShortcut, shortcutName: "Remind"), services: services(run: { _, _, _ in nil }))
            XCTFail("should fail")
        } catch let failure as VoiceLaunchExecutor.Failure {
            XCTAssertTrue(failure.alert.title.contains("Remind"))
        } catch { XCTFail("\(error)") }
    }

    // MARK: The picker's list

    func testTheListOfShortcutsIsParsedAndMatched() {
        let output = """
        Remind me (1B2C3D4E-0000-1111-2222-333344445555)
        Text (with parens) (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)
        No identifier here
        Remind me (1B2C3D4E-0000-1111-2222-333344445555)
        תזכורת (FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE)

        Not an id (hello)
        """
        let list = VoiceShortcutList.parse(output)
        XCTAssertEqual(list.map(\.name), ["No identifier here", "Not an id (hello)", "Remind me", "Text (with parens)", "תזכורת"])
        XCTAssertEqual(list.first { $0.name == "Remind me" }?.identifier, "1B2C3D4E-0000-1111-2222-333344445555")
        XCTAssertNil(list.first { $0.name == "No identifier here" }?.identifier)
        XCTAssertEqual(VoiceShortcutList.match(name: "Old name", identifier: "1B2C3D4E-0000-1111-2222-333344445555", in: list)?.name, "Remind me")
        XCTAssertEqual(VoiceShortcutList.match(name: "Text (with parens)", identifier: nil, in: list)?.identifier, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertNil(VoiceShortcutList.match(name: "Gone", identifier: nil, in: list))
    }

    func testRefreshAndOpenUseArgumentArrays() async {
        var calls: [[String]] = []
        let run: VoiceLaunchProcessRunner = { exe, args, _ in
            calls.append([exe] + args)
            return VoiceLaunchProcessResult(status: 0, timedOut: false, stdout: "One (1B2C3D4E-0000-1111-2222-333344445555)\nTwo\n", stderr: "")
        }
        let list = await VoiceLaunchActing.listShortcuts(services: services(run: run))
        XCTAssertEqual(list?.map(\.name), ["One", "Two"])
        let opened = await VoiceLaunchActing.viewShortcut(name: "One; x", services: services(run: run))
        XCTAssertTrue(opened)
        XCTAssertEqual(calls, [["/usr/bin/shortcuts", "list", "--show-identifiers"], ["/usr/bin/shortcuts", "view", "One; x"]])
        let failed = await VoiceLaunchActing.listShortcuts(services: services(run: { _, _, _ in VoiceLaunchProcessResult(status: 1, timedOut: false) }))
        XCTAssertNil(failed)
        let none = await VoiceLaunchActing.listShortcuts(services: services(run: { _, _, _ in nil }))
        XCTAssertNil(none)
        let dash = await VoiceLaunchActing.viewShortcut(name: "-x", services: services(run: run))
        XCTAssertFalse(dash)
    }

    // MARK: Validation

    func testAnAnswerCanOnlyBeUsedAfterItsAction() {
        func problem(_ steps: [VoiceStep]) -> String? { config(steps: steps).validate(allowedSchemes: ["https"]) }
        func plain(_ steps: [VoiceStep]) -> String? {
            let c = config(steps: steps)
            return VoiceBuildProblems.problem(for: c.commands[0], config: c, allowedSchemes: ["https"])
        }
        let type = VoiceStep(kind: .typeText, text: "{answer_s1}")
        XCTAssertNil(problem([shortcutStep(), type]))
        XCTAssertNil(plain([shortcutStep(), type]))
        XCTAssertNotNil(problem([type, shortcutStep()]))
        XCTAssertEqual(plain([type, shortcutStep()]), VoiceBuildCopy.answerTooEarly(1))
        // Its own action can't use its own answer; an unknown answer is unknown.
        XCTAssertNotNil(problem([shortcutStep(text: "{answer_s1}", json: false)]))
        XCTAssertNotNil(problem([shortcutStep(), VoiceStep(kind: .typeText, text: "{answer_nope}")]))
        XCTAssertEqual(plain([shortcutStep(), VoiceStep(kind: .typeText, text: "{answer_nope}")]), VoiceBuildCopy.unknownValue(2, "answer"))
        // Details of an answer are fine, any name.
        XCTAssertNil(problem([shortcutStep(), VoiceStep(kind: .typeText, text: "{answer_s1.title}")]))
        // A second Shortcut can use the first one's answer, not the reverse.
        XCTAssertNil(problem([shortcutStep(), shortcutStep(id: "s2", text: "{answer_s1}", json: false)]))
        XCTAssertNotNil(problem([shortcutStep(id: "s2", text: "{answer_s1}", json: false), shortcutStep()]))
    }

    func testTheCancelPauseRuleAndTheDoesntSendFlag() {
        func problem(_ steps: [VoiceStep]) -> String? { config(steps: steps).validate(allowedSchemes: ["https"]) }
        func plain(_ steps: [VoiceStep]) -> String? {
            let c = config(steps: steps)
            return VoiceBuildProblems.problem(for: c.commands[0], config: c, allowedSchemes: ["https"])
        }
        XCTAssertTrue(shortcutStep(readOnly: nil).isActing)
        XCTAssertFalse(shortcutStep(readOnly: true).isActing)
        XCTAssertNotNil(problem([shortcutStep(readOnly: nil)]))
        XCTAssertEqual(plain([shortcutStep(readOnly: nil)]), VoiceBuildCopy.needCancelPause)
        XCTAssertNil(problem([shortcutStep(readOnly: true)]))
        XCTAssertNil(plain([shortcutStep(readOnly: true)]))
        XCTAssertNil(problem([VoiceStep(kind: .confirm, text: "ok"), shortcutStep(readOnly: nil)]))
        // The flag exempts only the Shortcut: a webhook still needs the pause.
        XCTAssertNotNil(problem([shortcutStep(readOnly: true), VoiceStep(kind: .webhook, link: "https://h.test")]))
        // A new action still gets the pause put in front of it.
        var steps: [VoiceStep] = []
        XCTAssertTrue(steps.addStep(.runAppleShortcut, pattern: "Remind {task}"))
        XCTAssertEqual(steps.map(\.kind), [.confirm, .runAppleShortcut])
    }

    func testValidationOfTheNewFields() {
        func problem(_ edit: (inout VoiceStep) -> Void) -> String? {
            var step = shortcutStep()
            edit(&step)
            return config(steps: [step]).validate(allowedSchemes: ["https"])
        }
        XCTAssertNil(problem { $0.timeoutSeconds = 60; $0.shortcutId = "1B2C3D4E-0000-1111-2222-333344445555"; $0.answerDetails = ["title", "due_date"] })
        XCTAssertNotNil(problem { $0.timeoutSeconds = 45 })
        XCTAssertNotNil(problem { $0.shortcutId = "not an id; rm" })
        XCTAssertNotNil(problem { $0.inputMode = "xml" })
        XCTAssertNotNil(problem { $0.answerDetails = ["a b"] })
        XCTAssertNotNil(problem { $0.shortcutName = "--help" })
    }

    // MARK: Type the answer

    func testTypeTheAnswerActionAndToggle() {
        var steps: [VoiceStep] = []
        XCTAssertFalse(steps.addTypeAnswer(), "no Shortcut, no answer")
        let voiceCommand = shortcutStep()
        steps = [voiceCommand, VoiceStep(kind: .openApp, bundleId: "com.apple.Notes")]
        XCTAssertTrue(steps.addTypeAnswer())
        XCTAssertEqual(steps.last?.text, "{answer_s1}")
        XCTAssertNil(steps.typingAnswer(of: "s1"), "only right after the Shortcut counts for the toggle")
        steps = [voiceCommand]
        steps.setTypingAnswer(of: "s1", true)
        steps.setTypingAnswer(of: "s1", true)
        XCTAssertEqual(steps.count, 2)
        XCTAssertNotNil(steps.typingAnswer(of: "s1"))
        XCTAssertEqual(steps[1].kind, .typeText)
        XCTAssertNil(config(steps: steps).validate(allowedSchemes: ["https"]))
        steps.setTypingAnswer(of: "s1", false)
        XCTAssertEqual(steps.map(\.kind), [.runAppleShortcut])
    }

    func testTypingAnAnswerDoesNothingWhenTheAnswerIsEmpty() throws {
        let plan = try makePlan("Remind call Dana", config(steps: [shortcutStep(), VoiceStep(kind: .typeText, text: "{answer_s1}")]))
        let typed = VoiceStepRenderer.resolve(plan.steps[1], answers: ["answer_s1": VoiceShortcutAnswer.parse("").renderValue], mac: "")
        XCTAssertEqual(typed.text, "")
    }

    // MARK: Older Macs and settings

    func testStoredSettingsFromBeforeStillLoadAndProtocolVersionIsUnchanged() throws {
        let json = #"{"version":2,"lists":[],"shortcuts":[{"id":"a","name":"Log","pattern":"Log {note}","enabled":true,"steps":[{"kind":"confirm","text":"ok"},{"kind":"runAppleShortcut","text":"{note}","shortcutName":"Log it"}]}]}"#
        let config = try XCTUnwrap(VoiceLaunchConfig.decode(json))
        XCTAssertNil(config.validate(allowedSchemes: ["https"]))
        XCTAssertFalse(config.commands[0].steps[1].sendsEverything)
        XCTAssertEqual(EdgeProtocol.version, 2)
        // Unknown-to-them fields are simply ignored by an older Mac's decoder; the step stays a plain shortcut step.
        let plan = try makePlan("Log hi", config)
        XCTAssertEqual(plan.steps[1].text, "hi")
    }
}
