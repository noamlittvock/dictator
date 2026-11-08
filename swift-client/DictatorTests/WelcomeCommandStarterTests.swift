import XCTest
@testable import Dictator

final class WelcomeCommandStarterTests: XCTestCase {
    private func catalog() throws -> VoiceCommandCatalog {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(VoiceCommandCatalog.self, from: Data(contentsOf: root.appendingPathComponent("shared/shortcut-catalog.json")))
    }

    func testStarterUsesOnlySafeCatalogTemplatesAndTheExampleReallyPlans() throws {
        var config = VoiceLaunchConfig.empty
        XCTAssertTrue(WelcomeCommandStarter.add(to: &config, catalog: try catalog()))
        XCTAssertEqual(config.commands.compactMap(\.templateId), ["open-app", "google", "youtube"])
        XCTAssertTrue(config.commands.allSatisfy(\.enabled))
        XCTAssertTrue(config.lists.isEmpty)
        for step in config.commands.flatMap(\.steps) {
            XCTAssertTrue([VoiceStep.Kind.openApp, .openLink].contains(step.kind))
            XCTAssertFalse(step.isActing)
            XCTAssertNil(step.command)
            XCTAssertNil(step.argument)
            XCTAssertNil(step.deferred)
            if step.kind == .openLink {
                let url = try XCTUnwrap(URL(string: try XCTUnwrap(step.link)))
                XCTAssertEqual(url.scheme, "https")
                XCTAssertTrue(["www.google.com", "www.youtube.com"].contains(url.host ?? ""))
            }
        }
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: WelcomeCommandStarter.phrase, in: config) else {
            return XCTFail("The Welcome phrase must really match")
        }
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.kind, .openApp)
        XCTAssertEqual(plan.steps.first?.text, "Safari")
        guard case .matched = VoiceTryItResult.result(for: WelcomeCommandStarter.phrase, in: config) else {
            return XCTFail("Welcome reuses the Try it matcher")
        }
    }

    func testExistingCommandsAreUnchangedEvenWhenDisabled() throws {
        for enabled in [true, false] {
            var config = VoiceLaunchConfig(commands: [VoiceCommand(id: "existing", name: "Fixture", pattern: "Fixture",
                                                                  steps: [VoiceStep(kind: .confirm, seconds: 0)], enabled: enabled)])
            let original = config
            XCTAssertFalse(WelcomeCommandStarter.add(to: &config, catalog: try catalog()))
            XCTAssertEqual(config, original)
        }
    }

    func testRepeatedStarterSetupIsANoOpAndKeepsExistingLists() throws {
        var config = VoiceLaunchConfig(lists: [VoiceList(id: "list", name: "Fixtures")])
        let catalog = try catalog()
        XCTAssertTrue(WelcomeCommandStarter.add(to: &config, catalog: catalog))
        let original = config
        XCTAssertFalse(WelcomeCommandStarter.add(to: &config, catalog: catalog))
        XCTAssertEqual(config, original)
        XCTAssertEqual(config.lists.map(\.id), ["list"])
    }

    func testMissingOrUnsafeTemplatesLeaveTheConfigUnchanged() throws {
        var catalog = try catalog()
        let index = try XCTUnwrap(catalog.templates.firstIndex { $0.id == "google" })
        catalog.templates[index].steps = [VoiceStep(kind: .typeText, text: "fixture")]
        var config = VoiceLaunchConfig.empty
        XCTAssertFalse(WelcomeCommandStarter.add(to: &config, catalog: catalog))
        XCTAssertEqual(config, .empty)
        catalog.templates.remove(at: index)
        XCTAssertFalse(WelcomeCommandStarter.add(to: &config, catalog: catalog))
        XCTAssertEqual(config, .empty)
    }
}
