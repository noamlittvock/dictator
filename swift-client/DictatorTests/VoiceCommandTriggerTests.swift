import Foundation
import Observation
import XCTest
@testable import Dictator

@MainActor
final class VoiceCommandTriggerTests: XCTestCase {
    private func command(id: String = "command-1", name: String = "Example", pattern: String = "Example") -> VoiceCommand {
        VoiceCommand(id: id, name: name, pattern: pattern, steps: [VoiceStep(kind: .openLink, link: "https://example.invalid")])
    }

    @MainActor
    private final class Harness {
        var config: VoiceLaunchConfig
        var paused = false
        var development = false
        var time: TimeInterval = 10
        var notices: [String] = []
        var plans: [VoiceLaunchPlan] = []
        var triggers: [VoiceCommandTrigger] = []
        var approvals: [VoiceLaunchPlan] = []
        var allowed = true
        var onAllow: (() async -> Void)?
        var onExecute: (() async -> Void)?
        var result = VoiceLaunchExecutor.Result.done
        lazy var controller = VoiceCommandTriggerController(services: .init(
            config: { [unowned self] in config }, paused: { [unowned self] in paused },
            developmentBuild: { [unowned self] in development }, now: { [unowned self] in time },
            allow: { [unowned self] plan in approvals.append(plan); await onAllow?(); return allowed },
            execute: { [unowned self] plan, trigger in
                plans.append(plan); triggers.append(trigger); await onExecute?(); return result
            },
            notice: { [unowned self] in notices.append($0) }))
        init(_ command: VoiceCommand) { config = VoiceLaunchConfig(commands: [command]) }
        func start() { controller.finishStarting() }
        func link(_ key: String = "command-1", extra: [URLQueryItem] = []) -> URL {
            var parts = URLComponents()
            parts.scheme = "dictator"; parts.host = "run"
            parts.queryItems = [URLQueryItem(name: "command", value: key)] + extra
            return parts.url!
        }
    }

    func testRenderHasNoSpeechAndOptionalSlotsAreEmpty() throws {
        var command = command(pattern: "Example [with {words}]")
        command.steps = [VoiceStep(kind: .typeText, text: "Saved {words}")]
        let config = VoiceLaunchConfig(commands: [command])
        let plan = try VoiceCommandWithoutSpeech.plan(command, in: config).get()
        XCTAssertTrue(plan.slots.isEmpty)
        XCTAssertEqual(plan.mainText, "")
        XCTAssertEqual(plan.steps.first?.text, "Saved ")
        XCTAssertEqual(plan.commandId, command.id)
    }

    func testDeferredShortcutInputAlsoHasNoSpeech() throws {
        var command = command(pattern: "Example [with {words}]")
        command.steps = [VoiceStep(kind: .runAppleShortcut, text: "{words}", shortcutName: "Synthetic example",
                                   inputMode: VoiceStep.inputJSON, readOnly: true)]
        let plan = try VoiceCommandWithoutSpeech.plan(command, in: .init(commands: [command])).get()
        let step = try XCTUnwrap(plan.steps.first)
        XCTAssertEqual(step.deferred?.said, "")
        XCTAssertEqual(step.deferred?.slots, [])
        let resolved = VoiceStepRenderer.resolve(step, answers: [:], mac: "Synthetic Mac")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((resolved.text ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(object["said"] as? String, "")
    }

    func testRequiredFreeTextListSlotsMalformedAndDisabledAreRefused() {
        for pattern in ["Example {words}", "Example {person:People}", "Example ["] {
            let command = command(pattern: pattern)
            if case .success = VoiceCommandWithoutSpeech.plan(command, in: .init(commands: [command])) {
                XCTFail("Required or malformed spoken part must be refused")
            }
        }
        var disabled = command(); disabled.enabled = false
        if case .success = VoiceCommandWithoutSpeech.plan(disabled, in: .init(commands: [disabled])) { XCTFail("Disabled command") }
    }

    func testKeyboardUsesSharedRenderingAndCorrectTrigger() async {
        let command = command()
        let harness = Harness(command); harness.start()
        let ran = await harness.controller.run(command, trigger: .keyboard)
        XCTAssertTrue(ran)
        XCTAssertEqual(harness.triggers, [.keyboard])
        XCTAssertEqual(harness.plans.first?.slots, [])
    }

    func testLinkRequiresOptInAndEnabledCommand() async {
        let harness = Harness(command()); harness.start()
        await harness.controller.handleURL(harness.link())
        XCTAssertTrue(harness.plans.isEmpty)
        XCTAssertEqual(harness.notices, ["This command does not allow other apps to start it."])
        harness.config.commands[0].runsFromOtherApps = true
        harness.config.commands[0].enabled = false
        harness.time += 3
        await harness.controller.handleURL(harness.link())
        XCTAssertTrue(harness.plans.isEmpty)
        XCTAssertEqual(harness.notices.last, "This command is turned off.")
    }

    func testExtraURLWordsNeverEnterPlanOrNotice() async throws {
        var command = command(pattern: "Example [with {words}]")
        command.runsFromOtherApps = true
        command.steps = [VoiceStep(kind: .typeText, text: "{words}")]
        let harness = Harness(command); harness.start()
        await harness.controller.handleURL(harness.link(extra: [
            .init(name: "words", value: "UNTRUSTED-URL-TEXT"), .init(name: "step", value: "UNTRUSTED-STEP"),
            .init(name: "link", value: "https://untrusted.invalid")]))
        XCTAssertEqual(harness.triggers, [.otherApp])
        let plan = try XCTUnwrap(harness.plans.first)
        XCTAssertEqual(plan.steps.first?.text, "")
        XCTAssertTrue(plan.slots.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        XCTAssertFalse(encoded.contains("UNTRUSTED"))
        XCTAssertTrue(harness.notices.isEmpty)
    }

    func testExactNamesIDsAndAmbiguousNames() async {
        var command = command(name: "Example & layout"); command.runsFromOtherApps = true
        let harness = Harness(command); harness.start()
        await harness.controller.handleURL(harness.link("Example & layout"))
        XCTAssertEqual(harness.plans.count, 1)
        harness.time += 3
        await harness.controller.handleURL(harness.link("example & layout"))
        XCTAssertEqual(harness.plans.count, 1)
        var other = command; other.id = "command-2"
        harness.config.commands.append(other)
        harness.time += 3
        await harness.controller.handleURL(harness.link("Example & layout"))
        XCTAssertEqual(harness.plans.count, 1)
        harness.time += 3
        await harness.controller.handleURL(harness.link())
        XCTAssertEqual(harness.plans.count, 2)
    }

    func testMalformedAndHostileURLsAreIgnored() throws {
        let bad = ["https://run?command=command-1", "dictator://unknown?command=command-1",
                   "dictator://run.invalid?command=command-1", "dictator://person@run?command=command-1",
                   "dictator://run:?command=command-1", "dictator://run:7880?command=command-1", "dictator://run:999999999999999999999?command=command-1",
                   "dictator://run/path?command=command-1", "dictator://run/?command=command-1",
                   "dictator://run?command=command-1#fragment", "dictator://run", "dictator://run?command=",
                   "dictator://run?Command=command-1", "dictator://run?command=one&command=two",
                   "dictator://run?command=line%0Abreak", "dictator://run?command=%00",
                   "dictator://run?command=" + String(repeating: "a", count: 301),
                   "dictator://run?command=command-1&ignored=" + String(repeating: "a", count: 8_192)]
        for raw in bad {
            guard let url = URL(string: raw) else { continue } // Foundation can reject invalid ports first.
            XCTAssertNil(VoiceCommandURL.commandKey(url), "Unexpected accepted URL")
        }
        var named = command(id: "id &?#%שלום")
        named.runsFromOtherApps = true
        let url = try XCTUnwrap(VoiceCommandURL.link(for: named))
        XCTAssertEqual(VoiceCommandURL.commandKey(url), named.id)
    }

    func testRejectedURLsNeverReachExecutor() async throws {
        var command = command(); command.runsFromOtherApps = true
        let harness = Harness(command); harness.start()
        for raw in ["dictator://unknown?command=command-1", "dictator://run?command=%00", "dictator://run?command=missing"] {
            harness.time += 3
            await harness.controller.handleURL(try XCTUnwrap(URL(string: raw)))
        }
        XCTAssertTrue(harness.plans.isEmpty)
        XCTAssertFalse(harness.notices.joined().contains("missing"))
    }

    func testEveryActingKindAndTerminalRequireFreshApproval() async {
        let acting: [VoiceStep] = [VoiceStep(kind: .pressKey, key: "return"),
            VoiceStep(kind: .runAppleShortcut, shortcutName: "Synthetic example"),
            VoiceStep(kind: .webhook, link: "https://example.invalid"),
            VoiceStep(kind: .runInTerminal, folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
                      command: "printf", argument: "synthetic")]
        for step in acting {
            var command = command(); command.runsFromOtherApps = true
            command.steps = [VoiceStep(kind: .confirm, text: "Continue?"), step]
            let harness = Harness(command); harness.start()
            harness.allowed = false
            await harness.controller.handleURL(harness.link())
            XCTAssertEqual(harness.approvals.count, 1)
            XCTAssertTrue(harness.plans.isEmpty)
            harness.allowed = true; harness.time += 3
            await harness.controller.handleURL(harness.link())
            harness.time += 3
            await harness.controller.handleURL(harness.link())
            XCTAssertEqual(harness.approvals.count, 3)
            XCTAssertEqual(harness.plans.count, 2)
            XCTAssertEqual(harness.approvals.first?.commandName, command.name)
        }
    }

    func testReadOnlyShortcutDoesNotNeedExternalApproval() async {
        var command = command(); command.runsFromOtherApps = true
        command.steps = [VoiceStep(kind: .runAppleShortcut, shortcutName: "Synthetic example", readOnly: true)]
        let harness = Harness(command); harness.start()
        await harness.controller.handleURL(harness.link())
        XCTAssertTrue(harness.approvals.isEmpty)
        XCTAssertEqual(harness.plans.count, 1)
    }

    func testBusyDuringDialogAndExecutionIgnoresReentrantLinks() async {
        var command = command(); command.runsFromOtherApps = true
        command.steps = [VoiceStep(kind: .confirm, text: "Continue?"), VoiceStep(kind: .pressKey, key: "return")]
        let harness = Harness(command); harness.start()
        harness.onAllow = {
            XCTAssertTrue(harness.controller.isBusy)
            harness.time += 3
            await harness.controller.handleURL(harness.link())
        }
        harness.onExecute = {
            XCTAssertTrue(harness.controller.isBusy)
            harness.time += 3
            await harness.controller.handleURL(harness.link())
        }
        await harness.controller.handleURL(harness.link())
        XCTAssertEqual(harness.approvals.count, 1)
        XCTAssertEqual(harness.plans.count, 1)
        XCTAssertFalse(harness.controller.isBusy)
    }

    func testRateLimitAlsoBoundsUnknownCommandNotices() async {
        var command = command(); command.runsFromOtherApps = true
        let harness = Harness(command); harness.start()
        await harness.controller.handleURL(harness.link("missing"))
        await harness.controller.handleURL(harness.link("missing"))
        await harness.controller.handleURL(harness.link())
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertTrue(harness.plans.isEmpty)
        harness.time += VoiceCommandTriggerController.minimumLinkInterval
        await harness.controller.handleURL(harness.link())
        XCTAssertEqual(harness.plans.count, 1)
    }

    func testStartupDevelopmentAndPauseGates() async {
        var command = command(); command.runsFromOtherApps = true
        let harness = Harness(command)
        harness.start(); harness.development = true
        await harness.controller.handleURL(harness.link())
        XCTAssertTrue(harness.plans.isEmpty)
        harness.development = false; harness.paused = true
        await harness.controller.handleURL(harness.link())
        XCTAssertTrue(harness.plans.isEmpty)
        XCTAssertTrue(harness.notices.last?.contains("paused") == true)
        harness.paused = false; harness.time += 3
        await harness.controller.handleURL(harness.link())
        XCTAssertEqual(harness.plans.count, 1)
    }

    /// Pause stops typed-history capture, so a keyboard start still runs, as
    /// a routine's does. Only a link waits for it.
    func testKeyboardStartIgnoresPause() async {
        let command = command()
        let harness = Harness(command); harness.start(); harness.paused = true
        let ran = await harness.controller.run(command, trigger: .keyboard)
        XCTAssertTrue(ran)
        XCTAssertEqual(harness.plans.count, 1)
    }

    /// The link that launches Dictator arrives before it has finished starting.
    func testLinkBeforeStartingRunsOnceAfterStarting() async {
        var command = command(); command.runsFromOtherApps = true
        let harness = Harness(command)
        await harness.controller.handleURL(harness.link())
        await harness.controller.handleURL(harness.link())
        XCTAssertTrue(harness.plans.isEmpty)
        harness.start()
        await harness.controller.earlyLinkRun?.value
        XCTAssertEqual(harness.plans.count, 1)
    }

    func testDialogApprovalCannotOutlivePauseOrConfigChange() async {
        for changeConfig in [false, true] {
            var command = command(); command.runsFromOtherApps = true
            command.steps = [VoiceStep(kind: .confirm, text: "Continue?"), VoiceStep(kind: .pressKey, key: "return")]
            let harness = Harness(command); harness.start()
            harness.onAllow = {
                if changeConfig { harness.config.commands[0].runsFromOtherApps = false }
                else { harness.paused = true }
            }
            await harness.controller.handleURL(harness.link())
            XCTAssertTrue(harness.plans.isEmpty)
            XCTAssertFalse(harness.controller.isBusy)
        }
    }

    func testRequiredSpeechStillRefusedWhenOptedIntoLinks() async {
        var command = command(pattern: "Example {words}"); command.runsFromOtherApps = true
        let harness = Harness(command); harness.start()
        await harness.controller.handleURL(harness.link(extra: [.init(name: "words", value: "supplied")]))
        XCTAssertTrue(harness.plans.isEmpty)
        XCTAssertTrue(harness.notices.last?.contains("spoken words") == true)
    }

    func testRemovedStaleCommandAndExecutorFailureAreExplained() async {
        let command = command()
        let harness = Harness(command); harness.start()
        harness.config.commands = []
        let stale = await harness.controller.run(command, trigger: .keyboard)
        XCTAssertFalse(stale)
        harness.config.commands = [command]
        harness.result = .stopped(DictationAlert(title: "Unavailable", detail: "Synthetic failure", action: nil))
        let failed = await harness.controller.run(command, trigger: .keyboard)
        XCTAssertFalse(failed)
        XCTAssertEqual(harness.notices.last, "Unavailable Synthetic failure")
        XCTAssertFalse(harness.controller.isBusy)
    }

    func testHotkeyValidationIncludesCommandsRoutinesAndSpokenRequirements() {
        let key = WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.control | WorkspaceHotkey.option | WorkspaceHotkey.command)
        var first = command(); first.hotkey = key
        var other = command(id: "second", name: "Second", pattern: "Second"); other.hotkey = key
        let duplicate = VoiceLaunchConfig(commands: [first, other])
        XCTAssertEqual(duplicate.validate(), "Two commands cannot share a keyboard shortcut.")
        XCTAssertNotNil(VoiceCommandHotkeys.problem(for: first, commands: [other], routines: [], triggers: .standard))
        let routine = WorkspaceRoutine(name: "Synthetic routine", hotkey: key)
        XCTAssertNotNil(VoiceCommandHotkeys.problem(for: first, commands: [], routines: [routine], triggers: .standard))
        XCTAssertNotNil(VoiceCommandHotkeys.conflict(key, commands: [first]))
        XCTAssertNil(VoiceCommandHotkeys.problem(for: first, commands: [first], routines: [], triggers: .standard))
        first.pattern = "Example {words}"
        XCTAssertNotNil(VoiceLaunchConfig(commands: [first]).validate())
        first.pattern = "Example [with {words}]"
        XCTAssertNil(VoiceLaunchConfig(commands: [first]).validate())
        first.hotkey = WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.command)
        XCTAssertNotNil(VoiceLaunchConfig(commands: [first]).validate())
    }
}

@MainActor
final class CommandHotkeyRegistrationTests: XCTestCase {
    @Observable final class Config {
        var commands: [VoiceCommand] = []
        var routines: [WorkspaceRoutine] = []
    }
    private final class Registry: WorkspaceHotkeyRegistering {
        var onTrigger: ((String) -> Void)?
        var onCommandTrigger: ((String) -> Void)?
        var commands: [VoiceCommand] = []
        var routines: [WorkspaceRoutine] = []
        var registrations = 0
        var clears = 0
        var changed: (() -> Void)?
        func register(_ definitions: [WorkspaceRoutine], commands: [VoiceCommand]) -> WorkspaceHotkeyRegistry.Registration {
            routines = definitions; self.commands = commands; registrations += 1; changed?(); return .init()
        }
        func clear() { clears += 1; commands = []; routines = [] }
    }

    func testObservedConfigChangesRemoveDisabledDeletedAndSpeechDependentKeys() async {
        let source = Config(), registry = Registry()
        let key = WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.control | WorkspaceHotkey.option | WorkspaceHotkey.command)
        let command = VoiceCommand(id: "one", name: "Example", pattern: "Example", steps: [VoiceStep(kind: .openLink, link: "https://example.invalid")], hotkey: key)
        source.commands = [command]
        let coordinator = WorkspaceHotkeyCoordinator(registry: registry, routines: { source.routines }, commands: { source.commands })
        coordinator.start()
        XCTAssertEqual(registry.commands.map(\.id), ["one"])
        let disabled = expectation(description: "Disabled command unregisters")
        registry.changed = { disabled.fulfill() }
        source.commands[0].enabled = false
        await fulfillment(of: [disabled], timeout: 2)
        XCTAssertTrue(registry.commands.isEmpty)
        let enabled = expectation(description: "Enabled command registers")
        registry.changed = { enabled.fulfill() }
        source.commands[0].enabled = true
        await fulfillment(of: [enabled], timeout: 2)
        XCTAssertEqual(registry.commands.map(\.id), ["one"])
        let requiresSpeech = expectation(description: "Required speech unregisters")
        registry.changed = { requiresSpeech.fulfill() }
        source.commands[0].pattern = "Example {words}"
        await fulfillment(of: [requiresSpeech], timeout: 2)
        XCTAssertTrue(registry.commands.isEmpty)
        let deleted = expectation(description: "Deleted command unregisters")
        registry.changed = { deleted.fulfill() }
        source.commands = []
        await fulfillment(of: [deleted], timeout: 2)
        XCTAssertTrue(registry.commands.isEmpty)
        let mirrored = expectation(description: "Replacement mirrored setting registers new keys")
        registry.changed = { mirrored.fulfill() }
        var replacement = command; replacement.id = "two"; replacement.hotkey?.keyCode = 14
        source.commands = [replacement]
        await fulfillment(of: [mirrored], timeout: 2)
        XCTAssertEqual(registry.commands.map(\.id), ["two"])
        XCTAssertEqual(registry.commands.first?.hotkey?.keyCode, 14)
        let routine = expectation(description: "Routine setting refreshes the same registry")
        registry.changed = { routine.fulfill() }
        source.routines = [WorkspaceRoutine(id: "routine", name: "Example routine")]
        await fulfillment(of: [routine], timeout: 2)
        XCTAssertEqual(registry.routines.map(\.id), ["routine"])
        registry.changed = nil
    }

    func testRecorderSuspendsCommandsAndRoutinesUntilItEnds() async {
        let source = Config(), registry = Registry()
        let coordinator = WorkspaceHotkeyCoordinator(registry: registry, routines: { source.routines }, commands: { source.commands })
        coordinator.start(); coordinator.suspend()
        let count = registry.registrations
        source.commands = [VoiceCommand(name: "Synthetic", pattern: "Synthetic", steps: [])]
        coordinator.refresh()
        XCTAssertEqual(registry.registrations, count)
        XCTAssertEqual(registry.clears, 1)
        coordinator.resume()
        XCTAssertEqual(registry.registrations, count + 1)
    }
}
