import XCTest
@testable import Dictator

final class VoiceAppScopeTests: XCTestCase {
    private let app = "org.example.editor"
    private let otherApp = "org.example.browser"

    private func command(_ id: String, apps: [String] = [], pattern: String = "Find {words}") -> VoiceCommand {
        VoiceCommand(id: id, name: id, pattern: pattern, steps: [VoiceStep(kind: .typeText, text: "{words}")], onlyInApps: apps)
    }

    private func winner(_ config: VoiceLaunchConfig, app: String?) -> String? {
        guard case .matched(let match) = VoiceLaunchEngine.match("Find a sample", in: config, frontmostAppBundleID: app) else { return nil }
        return match.voiceCommand.id
    }

    func testScopedCommandBeatsGlobalInEitherOrder() {
        let global = command("global")
        let scoped = command("scoped", apps: [app])
        for commands in [[global, scoped], [scoped, global]] {
            let config = VoiceLaunchConfig(commands: commands)
            XCTAssertEqual(winner(config, app: app), "scoped")
            XCTAssertEqual(winner(config, app: otherApp), "global")
            XCTAssertEqual(winner(config, app: nil), "global")
        }
    }

    func testOtherAppAndUnknownAppDoNotMatchScopedCommand() {
        let config = VoiceLaunchConfig(commands: [command("scoped", apps: [app])])
        for context in [otherApp, nil] {
            XCTAssertEqual(VoiceLaunchEngine.match("Find a sample", in: config, frontmostAppBundleID: context), .noMatch(.noneMatched))
            XCTAssertEqual(VoiceLaunchEngine.plan(for: "Find a sample", in: config, frontmostAppBundleID: context), .noMatch(.noneMatched))
        }
        XCTAssertEqual(VoiceLaunchEngine.plan(for: "Find a sample", in: config), .noMatch(.noneMatched))
    }

    func testTwoScopedMatchesRemainATie() {
        let config = VoiceLaunchConfig(commands: [command("global"), command("one", apps: [app]), command("two", apps: [app, otherApp])])
        XCTAssertEqual(VoiceLaunchEngine.match("Find a sample", in: config, frontmostAppBundleID: app), .noMatch(.tie(["one", "two"])))
    }

    func testClashValidationAllowsDisjointScopesAndGlobalFallback() {
        let one = command("one", apps: [app])
        let two = command("two", apps: [otherApp])
        let config = VoiceLaunchConfig(commands: [one, two, command("global")])
        XCTAssertNil(config.validate())
        XCTAssertNil(VoiceBuildProblems.problem(for: config, editing: one))
        XCTAssertNil(VoiceBuildProblems.problem(for: config, editing: two))
    }

    func testClashValidationChecksEveryCommandWithTheSamePattern() {
        let one = command("one", apps: [app])
        let two = command("two", apps: [otherApp])
        let overlap = command("overlap", apps: [app, otherApp])
        let config = VoiceLaunchConfig(commands: [one, two, overlap])
        XCTAssertNotNil(config.validate())
        XCTAssertNotNil(VoiceBuildProblems.problem(for: config, editing: overlap))
        XCTAssertNotNil(VoiceLaunchConfig(commands: [command("one"), command("two")]).validate())
    }

    func testAliasesRespectAppScopeWhenValidatingAndTeaching() {
        var one = command("one", apps: [app])
        var two = command("two", apps: [otherApp], pattern: "Search {words}")
        one.triggerAliases = ["lookup"]
        two.triggerAliases = ["lookup"]
        var config = VoiceLaunchConfig(commands: [one, two])
        XCTAssertNil(config.validate())
        XCTAssertNil(config.addTriggerAlias("Find", toVoiceCommand: "two"))
        config.commands[1].onlyInApps = [app]
        XCTAssertNotNil(config.validate())
    }

    func testAppListValidation() {
        var scoped = command("scoped", apps: (0..<20).map { "org.example.app\($0)" })
        XCTAssertNil(VoiceLaunchConfig(commands: [scoped]).validate())
        scoped.onlyInApps.append("org.example.extra")
        XCTAssertNotNil(VoiceLaunchConfig(commands: [scoped]).validate())
        for invalid in ["Safari", "org..example", "org.example app", ".org.example", "org.example\n"] {
            scoped.onlyInApps = [invalid]
            XCTAssertNotNil(VoiceLaunchConfig(commands: [scoped]).validate(), invalid)
        }
    }

    func testNearMissesExcludeOtherAppsAndUnknownScopes() throws {
        let scoped = command("scoped", apps: [app])
        let global = command("global")
        let config = VoiceLaunchConfig(commands: [scoped, global])
        for context in [otherApp, nil] {
            let miss = try XCTUnwrap(VoiceLaunchEngine.nearMiss(for: "Lookup a sample", in: config, frontmostAppBundleID: context))
            XCTAssertEqual(miss.eligibleCommandIDs, ["global"])
            XCTAssertFalse(miss.offers(scoped))
            XCTAssertTrue(miss.offers(global))
        }
        let miss = try XCTUnwrap(VoiceLaunchEngine.nearMiss(for: "Lookup a sample", in: config, frontmostAppBundleID: app))
        XCTAssertTrue(miss.offers(scoped))
        let old = VoiceNearMiss(kind: .trigger, transcript: "Lookup", heardTrigger: "Lookup")
        XCTAssertFalse(old.offers(scoped))
    }

    func testEntryNearMissUsesOnlyEligibleCommandsAndCanReplayChosenCommand() throws {
        let list = VoiceList(id: "topics", name: "Topics", fields: [], entries: [VoiceListEntry(id: "sample", names: ["Sample"], values: [:])])
        let scoped = command("scoped", apps: [app], pattern: "Find {topic:Topics} {words}")
        var global = scoped
        global.id = "global"
        global.name = "global"
        global.onlyInApps = []
        let config = VoiceLaunchConfig(lists: [list], commands: [global, scoped])
        let onlyScoped = VoiceLaunchConfig(lists: [list], commands: [scoped])
        XCTAssertNil(VoiceLaunchEngine.nearMiss(for: "Find smple text", in: onlyScoped, frontmostAppBundleID: otherApp))
        XCTAssertEqual(VoiceLaunchEngine.nearMiss(for: "Find smple text", in: config, frontmostAppBundleID: nil)?.commandId, "global")
        let miss = try XCTUnwrap(VoiceLaunchEngine.nearMiss(for: "Find smple text", in: config, frontmostAppBundleID: app))
        XCTAssertEqual(miss.kind, .entry)
        XCTAssertEqual(miss.commandId, "scoped")
        let message = CoreMessage.voiceCommandInsert(sessionId: "session", delivery: VoiceCommandDelivery(text: miss.transcript, nearMiss: miss))
        let data = try EdgeProtocolCodec.encode(message)
        XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(data), message)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(app))
        let fix = try VoiceNearMissFix.fixEntry(miss, span: 0, entryId: "sample", in: config).get()
        guard case .plan(let plan) = fix.result else { return XCTFail("Expected the chosen command to be planned") }
        XCTAssertEqual(plan.commandId, "scoped")
    }

    func testOldMessageDecodesAndNewFieldRoundTrips() throws {
        let old = Data(#"{"v":2,"t":"shortcut.mode","id":"old"}"#.utf8)
        XCTAssertEqual(try EdgeProtocolCodec.decodeEdgeMessage(old), .voiceCommandMode())
        let message = EdgeMessage.voiceCommandMode(appBundleId: app)
        let data = try EdgeProtocolCodec.encode(message, id: "new")
        XCTAssertEqual(try EdgeProtocolCodec.decodeEdgeMessage(data), message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["t"] as? String, "shortcut.mode")
        XCTAssertEqual(object["appBundleId"] as? String, app)
        let commandData = try JSONEncoder().encode(command("scoped", apps: [app]))
        XCTAssertEqual(try JSONDecoder().decode(VoiceCommand.self, from: commandData).onlyInApps, [app])
        let defaultData = try JSONEncoder().encode(command("global"))
        let defaultObject = try XCTUnwrap(JSONSerialization.jsonObject(with: defaultData) as? [String: Any])
        XCTAssertNil(defaultObject["onlyInApps"])
    }

    func testBrokerUsesPressingMacAppAndDropsItAfterMatching() {
        let broker = SessionBroker(coreId: "main", clock: { 0 }, makeSessionID: { "session" })
        let caps = EdgeCapabilities(hasMic: true, inputDeviceUID: "synthetic", accessibility: true, inputMonitoring: true, hotkeyMode: "intercept")
        for id in ["pressing", "main"] {
            _ = broker.apply(.edgeConnected(BrokerEdgeInfo(id: id, name: id, caps: caps)))
        }
        _ = broker.apply(.message(.hotkeyDown, from: "pressing"))
        _ = broker.apply(.message(.voiceCommandMode(appBundleId: app), from: "pressing"))
        _ = broker.apply(.message(.voiceCommandMode(appBundleId: otherApp), from: "main"))
        _ = broker.apply(.message(.focusClaim(appBundleId: otherApp), from: "pressing"))
        XCTAssertEqual(broker.takeCommandAppBundleID(sessionId: "session"), app)
        XCTAssertNil(broker.takeCommandAppBundleID(sessionId: "session"))
    }

    func testBrokerKeepsEachPresserAppThroughSettlingInBothModes() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            for coPress in [false, true] {
                let broker = SessionBroker(coreId: "main", clock: { 0 }, makeSessionID: { "session" })
                let caps = EdgeCapabilities(hasMic: true, inputDeviceUID: "synthetic", accessibility: true, inputMonitoring: true, hotkeyMode: "intercept")
                for id in ["pressing", "main"] {
                    _ = broker.apply(.edgeConnected(BrokerEdgeInfo(id: id, name: id, caps: caps)))
                }
                _ = broker.apply(.message(.pointerPresence, from: "main"))
                _ = broker.apply(.message(gesture, from: "pressing"))
                XCTAssertNil(broker.session)
                _ = broker.apply(.message(.voiceCommandMode(appBundleId: app), from: "pressing"))
                if coPress {
                    _ = broker.apply(.message(gesture, from: "main"))
                    XCTAssertEqual(broker.session?.initiator, "main")
                    XCTAssertNil(broker.session?.commandAppBundleID)
                    _ = broker.apply(.message(.voiceCommandMode(appBundleId: otherApp), from: "main"))
                } else {
                    _ = broker.apply(.pressSettled(1))
                    XCTAssertEqual(broker.session?.initiator, "pressing")
                }
                XCTAssertEqual(broker.takeCommandAppBundleID(sessionId: "session"), coPress ? otherApp : app)
            }
        }
    }

    func testCapturePrecedesUIAndSurvivesShiftJoiningTheHold() {
        let service = HotkeyService()
        service.dictationKeyIsDown = { true }
        var frontmost = app
        service.frontmostAppBundleID = { frontmost }
        service.onStart = { frontmost = "org.example.dictator" }
        var captured: String?
        service.onVoiceCommandMode = { [weak service] in captured = service?.commandAppBundleID }
        service.applyModifierState(rightHeld: true, shiftHeld: false)
        service.applyModifierState(rightHeld: true, shiftHeld: true)
        XCTAssertEqual(captured, app)
        XCTAssertNil(service.commandAppBundleID)
        service.applyModifierState(rightHeld: false, shiftHeld: false)
    }
}
