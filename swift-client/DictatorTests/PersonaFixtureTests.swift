import XCTest
@testable import Dictator

/// The handoff's test personas as synthetic fixtures: their screens, the way
/// they speak shortcuts, and apps their Macs may lack. Coordinates are
/// visible frames, top-left origin, y down (as the snapshot stores them).
final class PersonaFixtureTests: XCTestCase {
    private struct Desk {
        var name: String
        var displays: [WorkspaceDisplay]
        /// Expected display id per choice; nil note = no fallback note expected.
        var expected: [WorkspaceDisplayChoice: (id: String, note: Bool)]
    }

    private func screen(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                        main: Bool = false, builtIn: Bool? = nil) -> WorkspaceDisplay {
        WorkspaceDisplay(id: id, name: id, visibleFrame: WorkspaceRect(x: x, y: y, width: w, height: h), isMain: main, isBuiltIn: builtIn)
    }

    private var desks: [Desk] {
        let single = { (name: String, w: Double, h: Double) -> Desk in
            Desk(name: name, displays: [self.screen("d1", 0, 25, w, h, main: true, builtIn: true)], expected: [
                .main: ("d1", false), .left: ("d1", true), .right: ("d1", true), .top: ("d1", true),
                .bottom: ("d1", true), .largest: ("d1", false), .builtIn: ("d1", false)])
        }
        return [
            // Fleet operator (Theo): the travelling MacBook Pro, usually alone.
            single("theo travelling MacBook Pro", 1512, 957),
            // Fleet operator: "leftbook", built-in to the left of a 4K main screen, bottoms aligned.
            Desk(name: "theo leftbook", displays: [
                screen("d1", -1728, 1068, 1728, 1092, builtIn: true),
                screen("d2", 0, 25, 3840, 2135, main: true, builtIn: false),
            ], expected: [
                .main: ("d2", false), .left: ("d1", false), .right: ("d2", false),
                .top: ("d2", true), .bottom: ("d2", true), .largest: ("d2", false), .builtIn: ("d1", false)]),
            // Bilingual single-Mac user: a MacBook Air and nothing else.
            single("bilingual MacBook Air", 1470, 931),
            // Multi-monitor desk: main, a smaller screen to its left, another stacked above main.
            Desk(name: "desk with three screens", displays: [
                screen("d1", 0, 25, 2560, 1415, main: true, builtIn: false),
                screen("d2", -1920, 205, 1920, 1055, builtIn: false),
                screen("d3", 0, -1415, 2560, 1415, builtIn: false),
            ], expected: [
                .main: ("d1", false), .left: ("d2", false), .right: ("d1", false),
                .top: ("d3", false), .bottom: ("d1", false), .largest: ("d1", false), .builtIn: ("d1", true)]),
            // The same person's laptop, undocked.
            single("undocked laptop", 1512, 957),
            // Two equal screens side by side.
            Desk(name: "two side by side", displays: [
                screen("d1", 0, 25, 2560, 1415, main: true),
                screen("d2", 2560, 25, 2560, 1415),
            ], expected: [
                .main: ("d1", false), .left: ("d1", false), .right: ("d2", false),
                .top: ("d1", true), .bottom: ("d1", true), .largest: ("d1", false), .builtIn: ("d1", true)]),
            // A laptop with a bigger screen stacked above it, centred.
            Desk(name: "stacked pair", displays: [
                screen("d1", 0, 25, 1512, 957, main: true, builtIn: true),
                screen("d2", -524, -1415, 2560, 1415, builtIn: false),
            ], expected: [
                .main: ("d1", false), .left: ("d1", true), .right: ("d1", true),
                .top: ("d2", false), .bottom: ("d1", false), .largest: ("d2", false), .builtIn: ("d1", false)]),
        ]
    }

    func testEveryPersonaDeskResolvesEveryScreenChoiceAndExplainsFallbacks() {
        for desk in desks {
            for (choice, want) in desk.expected {
                let got = WorkspaceDisplayResolver.resolve(choice, displays: desk.displays, pointer: nil)
                XCTAssertEqual(got.display?.id, want.id, "\(desk.name): \(choice)")
                XCTAssertEqual(got.note != nil, want.note, "\(desk.name): \(choice) note \(got.note ?? "nil")")
            }
        }
    }

    func testARoutineSavedOnTheDeskRunsOnTheUndockedLaptopWithAPlainNote() {
        let routine = WorkspaceRoutine(name: "Focus", actions: [WorkspaceAction(kind: .arrangeWindows, bundleIDs: ["app.editor"], display: .right)])
        let laptop = WorkspaceSnapshot(displays: [screen("d1", 0, 25, 1512, 957, main: true, builtIn: true)],
            windows: [WorkspaceWindow(id: "w", bundleID: "app.editor", frame: WorkspaceRect(x: 10, y: 40, width: 800, height: 600))],
            frontmostWindowID: "w")
        let plan = WorkspacePlanner.plan(routine: routine, snapshot: laptop, protectedBundleIDs: [])
        XCTAssertFalse(plan.operations.isEmpty, "the window is still arranged on the one screen")
        XCTAssertTrue(plan.notes.contains { $0.contains("one screen") }, "\(plan.notes)")
    }

    // MARK: How they speak

    private let people = VoiceList(id: "people", name: "People", fields: ["phone"], entries: [
        VoiceListEntry(id: "yossi", names: ["יוסי"], values: ["phone": "+972 52 000"]),
        VoiceListEntry(id: "noa", names: ["Noa"], values: ["phone": "+972 50 000"]),
    ])

    private func voiceCommand(_ name: String, _ pattern: String, aliases: [String] = []) -> VoiceCommand {
        VoiceCommand(id: name, name: name, pattern: pattern, cleanUpSlot: nil,
                            steps: [VoiceStep(kind: .openLink, link: "https://x.test/")], enabled: true, triggerAliases: aliases)
    }

    private func matched(_ said: String, _ commands: [VoiceCommand]) -> VoiceLaunchMatch? {
        if case .matched(let m) = VoiceLaunchEngine.match(said, in: VoiceLaunchConfig(lists: [people], commands: commands)) { return m }
        return nil
    }

    func testBilingualUserSendsInHebrewWithAFillerAndAPrefixLetter() {
        let send = voiceCommand("send", "שלח {person:People} {message}")
        let m = matched("אממ שלח ליוסי אני מאחר עשר דקות", [send])
        guard case .entry(_, let entry)? = m?.slots["person"] else { return XCTFail("should match") }
        XCTAssertEqual(entry.id, "yossi")
        guard case .text(let message)? = m?.slots["message"] else { return XCTFail() }
        XCTAssertEqual(message, "אני מאחר עשר דקות")
    }

    func testBilingualUserMixesAnEnglishNameIntoAHebrewSentence() {
        let send = voiceCommand("send", "שלח {person:People} {message}")
        guard case .entry(_, let entry)? = matched("שלח Noa מגיעה בשמונה", [send])?.slots["person"] else { return XCTFail() }
        XCTAssertEqual(entry.id, "noa")
    }

    func testFleetOperatorsLongSpokenPromptKeepsEveryWordAfterTheTrigger() {
        let agent = voiceCommand("agent", "Claude Code now {prompt}", aliases: ["cloud code now"])
        let prompt = "on leftbook rebuild the iOS target, then open the preview on localhost three thousand and tell me what broke, um, and don't touch main"
        guard case .text(let text)? = matched("um so cloud code now " + prompt, [agent])?.slots["prompt"] else { return XCTFail() }
        XCTAssertEqual(text, prompt)
    }

    // MARK: Apps their Macs may not have

    @MainActor
    func testFleetOperatorsUncataloguedAppIsReportedByNameOnTheMacThatLacksIt() {
        let services = VoiceLaunchServices(confirm: { _, _ in true }, setClipboard: { _ in }, pressKey: { _ in true },
            frontmostBundleId: { nil }, runProcess: { _, _, _ in nil }, session: URLSession(configuration: .ephemeral),
            now: { Date(timeIntervalSince1970: 0) }, macName: { "leftbook" })
        let plan = VoiceLaunchPlan(commandId: "t3", commandName: "T3 Code", slots: [],
                                   steps: [VoiceStep(kind: .openApp, bundleId: "com.t3tools.t3code")], mainText: "fix the build")
        let problems = VoiceLaunchReadiness.problems(for: plan, services: services, appInstalled: { _ in false }, folderExists: { _ in true })
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("leftbook"), problems[0])
    }
}
