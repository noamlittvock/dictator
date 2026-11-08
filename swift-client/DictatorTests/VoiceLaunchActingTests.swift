import XCTest
@testable import Dictator

/// Synthetic only: no real key presses, Apple Shortcuts, web requests or clipboard.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data?) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [(URLRequest, Data?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        Self.seen.append((request, body))
        let (status, data) = Self.handler?(request, body) ?? (200, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class VoiceLaunchActingTests: XCTestCase {
    private func mockSession(status: Int = 200) -> URLSession {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = { _, _ in (status, Data()) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @MainActor
    private func services(confirm: Bool = true, session: URLSession? = nil, clipboard: ClipboardBox = ClipboardBox(),
                          keys: KeyBox = KeyBox(), front: String? = nil,
                          run: @escaping VoiceLaunchProcessRunner = { _, _, _ in VoiceLaunchProcessResult(status: 0, timedOut: false) }) -> VoiceLaunchServices {
        VoiceLaunchServices(
            confirm: { _, tick in tick(3); return confirm },
            setClipboard: { clipboard.text = $0 },
            pressKey: { keys.pressed.append($0); return true },
            frontmostBundleId: { front },
            runProcess: run,
            session: session ?? URLSession(configuration: .ephemeral),
            now: { Date(timeIntervalSince1970: 0) })
    }

    final class ClipboardBox { var text: String? }
    final class KeyBox { var pressed: [String] = [] }

    private func tempFile(_ name: String = "notes.txt") -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictator-acting-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name)
    }

    // MARK: pressKey

    func testKeyMapping() {
        XCTAssertEqual(VoiceLaunchActing.keyPress(for: "return"), .init(keyCode: 36, command: false))
        XCTAssertEqual(VoiceLaunchActing.keyPress(for: "cmdReturn"), .init(keyCode: 36, command: true))
        XCTAssertEqual(VoiceLaunchActing.keyPress(for: "tab"), .init(keyCode: 48, command: false))
        XCTAssertEqual(VoiceLaunchActing.keyPress(for: "escape"), .init(keyCode: 53, command: false))
        XCTAssertNil(VoiceLaunchActing.keyPress(for: "f5"))
        XCTAssertTrue(VoiceStep.keys.allSatisfy { VoiceLaunchActing.keyPress(for: $0) != nil })
    }

    // MARK: runAppleShortcut

    func testShortcutArgumentsAreAnArrayWithNoShell() {
        let args = VoiceLaunchActing.shortcutRunArguments(target: "Log; rm -rf ~ $(x)", inputPath: "/tmp/a b/input.txt", outputPath: "/tmp/a b/output.txt")
        XCTAssertEqual(Array(args.prefix(4)), ["run", "Log; rm -rf ~ $(x)", "--input-path", "/tmp/a b/input.txt"])
        XCTAssertEqual(VoiceLaunchActing.shortcutsExecutable, "/usr/bin/shortcuts")
        XCTAssertEqual(VoiceLaunchActing.shortcutTimeout, 30)
    }

    @MainActor
    func testShortcutRunUsesAPrivateInputFileAndRemovesIt() async throws {
        var seenArgs: [String] = []
        var seenExecutable = ""
        var seenTimeout: TimeInterval = 0
        var filePermissions: Int?
        var dirPermissions: Int?
        var content: String?
        var inputPath = ""
        let run: VoiceLaunchProcessRunner = { exe, args, timeout in
            seenExecutable = exe; seenArgs = args; seenTimeout = timeout
            inputPath = args[3]
            filePermissions = (try? FileManager.default.attributesOfItem(atPath: inputPath))?[.posixPermissions] as? Int
            dirPermissions = (try? FileManager.default.attributesOfItem(atPath: (inputPath as NSString).deletingLastPathComponent))?[.posixPermissions] as? Int
            content = try? String(contentsOfFile: inputPath, encoding: .utf8)
            return VoiceLaunchProcessResult(status: 0, timedOut: false)
        }
        let step = VoiceStep(kind: .runAppleShortcut, text: "hello Dana", shortcutName: "Log it")
        try await VoiceLaunchActing.runAppleShortcut(step, services: services(run: run))
        XCTAssertEqual(seenExecutable, "/usr/bin/shortcuts")
        XCTAssertEqual(Array(seenArgs.prefix(3)), ["run", "Log it", "--input-path"])
        XCTAssertEqual(seenTimeout, 30)
        XCTAssertEqual(filePermissions, 0o600)
        XCTAssertEqual(dirPermissions, 0o700)
        XCTAssertEqual(content, "hello Dana")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inputPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (inputPath as NSString).deletingLastPathComponent))
    }

    @MainActor
    func testShortcutNonzeroExitAndTimeoutFail() async {
        let step = VoiceStep(kind: .runAppleShortcut, text: "x", shortcutName: "Nope")
        for result in [VoiceLaunchProcessResult(status: 1, timedOut: false), VoiceLaunchProcessResult(status: 15, timedOut: true)] {
            do {
                try await VoiceLaunchActing.runAppleShortcut(step, services: services(run: { _, _, _ in result }))
                XCTFail("should fail")
            } catch let failure as VoiceLaunchExecutor.Failure {
                XCTAssertTrue(failure.alert.title.contains("Nope"))
                XCTAssertTrue(failure.alert.detail.contains("clipboard"))
            } catch { XCTFail("\(error)") }
        }
    }

    // MARK: webhook

    func testWebhookBodyHasSlotValuesAndListObjects() throws {
        var config = VoiceLaunchConfig()
        config.lists = [VoiceList(name: "People", fields: ["phone"], entries: [VoiceListEntry(names: ["Dana"], values: ["phone": "+972 50"])])]
        config.commands = [VoiceCommand(name: "Notify", pattern: "Notify {person:People} {message}", steps: [
            VoiceStep(kind: .confirm, text: "Sending {message}"),
            VoiceStep(kind: .webhook, link: "https://hooks.example.com/x")])]
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: "Notify Dana see you at 5", in: config) else { return XCTFail() }
        let body = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(plan.steps[1].text).utf8)) as? [String: Any]
        XCTAssertEqual(body?["message"] as? String, "see you at 5")
        let person = body?["person"] as? [String: Any]
        XCTAssertEqual(person?["phone"] as? String, "+972 50")
        XCTAssertEqual(person?["name"] as? String, "Dana")
    }

    @MainActor
    func testWebhookPostsJSONWithTenSecondTimeout() async throws {
        let session = mockSession()
        let step = VoiceStep(kind: .webhook, link: "https://hooks.example.com/x", text: #"{"a":"b"}"#)
        try await VoiceLaunchActing.sendWebhook(step, session: session)
        let (request, body) = try XCTUnwrap(MockURLProtocol.seen.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://hooks.example.com/x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(String(data: try XCTUnwrap(body), encoding: .utf8), #"{"a":"b"}"#)
    }

    @MainActor
    func testWebhookNon2xxIsAFailure() async {
        for status in [301, 404, 500] {
            let session = mockSession(status: status)
            do {
                try await VoiceLaunchActing.sendWebhook(VoiceStep(kind: .webhook, link: "http://hooks.example.com/x", text: "{}"), session: session)
                XCTFail("\(status) should fail")
            } catch let failure as VoiceLaunchExecutor.Failure {
                XCTAssertTrue(failure.alert.detail.contains("(\(status))"), failure.alert.detail)
            } catch { XCTFail("\(error)") }
        }
        let ok = mockSession(status: 204)
        do { try await VoiceLaunchActing.sendWebhook(VoiceStep(kind: .webhook, link: "https://h.example.com", text: "{}"), session: ok) } catch { XCTFail("204 is fine") }
    }

    func testWebhookRefusesOtherSchemes() {
        XCTAssertNil(VoiceLaunchActing.webhookRequest(VoiceStep(kind: .webhook, link: "file:///etc/passwd")))
        XCTAssertNil(VoiceLaunchActing.webhookRequest(VoiceStep(kind: .webhook, link: "whatsapp://send")))
        XCTAssertNotNil(VoiceLaunchActing.webhookRequest(VoiceStep(kind: .webhook, link: "http://a.example.com")))
    }

    // MARK: appendToFile

    func testLogLineFormat() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(VoiceLaunchActing.logLine("Buy milk", at: Date(timeIntervalSince1970: 0), timeZone: utc), "1970-01-01 00:00:00 | Buy milk\n")
        XCTAssertEqual(VoiceLaunchActing.logLine("a\nb\r\n\nc", at: Date(timeIntervalSince1970: 86_400), timeZone: utc), "1970-01-02 00:00:00 | a b c\n")
    }

    func testAppendCreatesThenAppends() throws {
        let file = tempFile()
        let utc = TimeZone(identifier: "UTC")!
        let step = VoiceStep(kind: .appendToFile, text: "one", path: file.path)
        try VoiceLaunchActing.appendLine(step, now: Date(timeIntervalSince1970: 0), timeZone: utc)
        var second = step; second.text = "two"
        try VoiceLaunchActing.appendLine(second, now: Date(timeIntervalSince1970: 60), timeZone: utc)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "1970-01-01 00:00:00 | one\n1970-01-01 00:01:00 | two\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int, 0o600)
    }

    func testAppendStartsANewLineAfterAFileWithoutOne() throws {
        let file = tempFile()
        try "old".write(to: file, atomically: true, encoding: .utf8)
        try VoiceLaunchActing.appendLine(VoiceStep(kind: .appendToFile, text: "new", path: file.path), now: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old\n1970-01-01 00:00:00 | new\n")
    }

    func testAppendFailsWhenTheFolderIsMissing() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)/notes.txt")
        XCTAssertThrowsError(try VoiceLaunchActing.appendLine(VoiceStep(kind: .appendToFile, text: "x", path: missing.path), now: Date())) { error in
            XCTAssertTrue(error is VoiceLaunchExecutor.Failure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    // MARK: confirm

    func testCountdownTicksThenContinues() async {
        var ticks: [Int] = []
        var sleeps = 0
        let ok = await VoiceLaunchCountdown.run(seconds: 3, sleep: { _ in sleeps += 1 }, isCancelled: { false }, tick: { ticks.append($0) })
        XCTAssertTrue(ok)
        XCTAssertEqual(ticks, [3, 2, 1])
        XCTAssertEqual(sleeps, 30)
    }

    func testCountdownStopsWhenCancelled() async {
        var sleeps = 0
        var ticks: [Int] = []
        let ok = await VoiceLaunchCountdown.run(seconds: 3, sleep: { _ in sleeps += 1 }, isCancelled: { sleeps >= 12 }, tick: { ticks.append($0) })
        XCTAssertFalse(ok)
        XCTAssertEqual(sleeps, 12)
        XCTAssertEqual(ticks, [3, 2])
    }

    func testCountdownLabel() {
        XCTAssertEqual(VoiceLaunchCountdown.label(3), BrandVoice.countdown(3))
    }

    @MainActor
    func testCancelStopsTheChainAndPutsTheMainTextOnTheClipboard() async {
        let clipboard = ClipboardBox()
        let keys = KeyBox()
        var ran = 0
        let session = mockSession()
        let plan = VoiceLaunchPlan(commandId: "s", commandName: "Send", slots: [], steps: [
            VoiceStep(kind: .confirm, text: "Sending hi", seconds: 3),
            VoiceStep(kind: .pressKey, key: "return"),
            VoiceStep(kind: .runAppleShortcut, text: "x", shortcutName: "S"),
            VoiceStep(kind: .webhook, link: "https://h.example.com", text: "{}")], mainText: "hi there")
        var events: [VoiceLaunchProgress.Event] = []
        let result = await VoiceLaunchExecutor.run(plan, services: services(confirm: false, session: session, clipboard: clipboard, keys: keys, run: { _, _, _ in ran += 1; return nil }),
                                                   progress: { events.append($0) })
        guard case .cancelled(let alert) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(alert.tone, .notice)
        XCTAssertEqual(clipboard.text, "hi there")
        XCTAssertTrue(keys.pressed.isEmpty)
        XCTAssertEqual(ran, 0)
        XCTAssertTrue(MockURLProtocol.seen.isEmpty)
        XCTAssertEqual(events, [.stepStarted(0), .countdown(0, 3), .stepCancelled(0)])
    }

    @MainActor
    func testConfirmedChainPressesTheKeyAndRunsTheRest() async {
        let clipboard = ClipboardBox()
        let keys = KeyBox()
        var ran = 0
        let plan = VoiceLaunchPlan(commandId: "s", commandName: "Send", slots: [], steps: [
            VoiceStep(kind: .confirm, text: "Sending hi", seconds: 3),
            VoiceStep(kind: .pressKey, key: "return"),
            VoiceStep(kind: .runAppleShortcut, text: "x", shortcutName: "S")], mainText: "hi")
        let result = await VoiceLaunchExecutor.run(plan, services: services(clipboard: clipboard, keys: keys, run: { _, _, _ in ran += 1; return VoiceLaunchProcessResult(status: 0, timedOut: false) }))
        guard case .done = result else { return XCTFail("\(result)") }
        XCTAssertEqual(keys.pressed, ["return"])
        XCTAssertEqual(ran, 1)
        XCTAssertNil(clipboard.text)
    }

    @MainActor
    func testAFailureStopsLaterStepsAndKeepsTheWords() async {
        let clipboard = ClipboardBox()
        let keys = KeyBox()
        let plan = VoiceLaunchPlan(commandId: "s", commandName: "Send", slots: [], steps: [
            VoiceStep(kind: .confirm, text: "ok", seconds: 3),
            VoiceStep(kind: .runAppleShortcut, text: "x", shortcutName: "S"),
            VoiceStep(kind: .pressKey, key: "return")], mainText: "hi")
        let result = await VoiceLaunchExecutor.run(plan, services: services(clipboard: clipboard, keys: keys, run: { _, _, _ in VoiceLaunchProcessResult(status: 1, timedOut: false) }))
        guard case .stopped = result else { return XCTFail("\(result)") }
        XCTAssertTrue(keys.pressed.isEmpty)
        XCTAssertEqual(clipboard.text, "hi")
    }

    // MARK: progress

    func testProgressShowsTheSummaryAndCountdown() {
        let plan = VoiceLaunchPlan(commandId: "s", commandName: "Send", slots: [], steps: [
            VoiceStep(kind: .confirm, text: "Sending to Dana: hi", seconds: 3), VoiceStep(kind: .pressKey, key: "return")], mainText: "hi")
        var progress = VoiceLaunchProgress(plan: plan)
        XCTAssertEqual(progress.rows[0].text, "Sending to Dana: hi")
        progress.apply(.stepStarted(0))
        progress.apply(.countdown(0, 3))
        XCTAssertEqual(progress.rows[0].note, BrandVoice.countdown(3))
        progress.apply(.countdown(0, 2))
        XCTAssertEqual(progress.rows[0].note, BrandVoice.countdown(2))
        progress.apply(.stepDone(0))
        XCTAssertNil(progress.rows[0].note)
        progress.apply(.stepCancelled(1))
        XCTAssertTrue(progress.hasCancelled)
        XCTAssertFalse(progress.hasFailed)
        XCTAssertTrue(progress.isFinished)
    }

    // MARK: editor auto-insert

    func testAddingAnActingStepInsertsAConfirmFirst() {
        var steps: [VoiceStep] = [VoiceStep(kind: .openLink, link: "whatsapp://send?text={message}")]
        let inserted = steps.addStep(.pressKey, pattern: "WhatsApp {person:People} {message}", cleanUpSlot: "message")
        XCTAssertTrue(inserted)
        XCTAssertEqual(steps.map(\.kind), [.openLink, .confirm, .pressKey])
        XCTAssertEqual(steps[1].text, "Sending to {person}: {message}")
        XCTAssertEqual(steps[1].seconds, 3)
    }

    func testNoExtraConfirmWhenOneIsAlreadyEarlier() {
        var steps: [VoiceStep] = [VoiceStep(kind: .confirm, text: "Sure?", seconds: 3)]
        XCTAssertFalse(steps.addStep(.webhook, pattern: "Log {note}"))
        XCTAssertFalse(steps.addStep(.runAppleShortcut, pattern: "Log {note}"))
        XCTAssertEqual(steps.map(\.kind), [.confirm, .webhook, .runAppleShortcut])
    }

    func testQuietStepsDoNotInsertAConfirm() {
        var steps: [VoiceStep] = []
        for kind in [VoiceStep.Kind.openLink, .openApp, .waitForTextField, .typeText, .runInTerminal, .appendToFile] {
            XCTAssertFalse(steps.addStep(kind, pattern: "Log {note}"))
        }
        XCTAssertFalse(steps.contains { $0.kind == .confirm })
        var key = VoiceStep.Kind.pressKey.makeStep(); key.key = "tab"
        XCTAssertFalse(key.isActing)
        XCTAssertFalse(steps.addStep(.confirm, pattern: "Log {note}"))
    }

    func testDefaultSummaries() {
        XCTAssertEqual(VoiceStep.defaultConfirmSummary(pattern: "Log {note}"), "Sending: {note}")
        XCTAssertEqual(VoiceStep.defaultConfirmSummary(pattern: "Email {person:People} [subject {subject} body] {body}", cleanUpSlot: "body"), "Sending to {person}: {body}")
        XCTAssertEqual(VoiceStep.defaultConfirmSummary(pattern: "Ping {person:People}"), "Sending to {person}")
        XCTAssertEqual(VoiceStep.defaultConfirmSummary(pattern: "Go"), "Press Esc to cancel this command.")
        XCTAssertEqual(VoiceStep.defaultConfirmSummary(pattern: "{"), "Press Esc to cancel this command.")
    }

    func testAutoInsertedVoiceCommandValidates() {
        var config = VoiceLaunchConfig()
        config.lists = [VoiceList(name: "People", fields: ["phone"])]
        var voiceCommand = VoiceCommand(name: "Ping", pattern: "Ping {person:People} {message}", steps: [VoiceStep(kind: .openLink, link: "https://e.com/{message}")])
        XCTAssertNil(config.validate(voiceCommand))
        voiceCommand.steps.addStep(.webhook, pattern: voiceCommand.pattern)
        voiceCommand.steps[voiceCommand.steps.count - 1].link = "https://hooks.example.com/x"
        XCTAssertNil(config.validate(voiceCommand))
        var without = voiceCommand; without.steps.removeAll { $0.kind == .confirm }
        XCTAssertNotNil(config.validate(without))
    }

    func testEveryStepKindCanBeAddedAndConfigured() {
        XCTAssertEqual(Set(VoiceStep.Kind.addable()), Set(VoiceStep.Kind.allCases))
    }

    // MARK: catalog

    func testWhatsAppAndSendTemplate() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/shortcut-catalog.json")
        let catalog = try JSONDecoder().decode(VoiceCommandCatalog.self, from: Data(contentsOf: url))
        let template = try XCTUnwrap(catalog.templates.first { $0.id == "whatsapp-send" })
        XCTAssertEqual(template.name, "WhatsApp and send")
        XCTAssertEqual(template.steps.map(\.kind), [.openLink, .waitForTextField, .confirm, .pressKey])
        XCTAssertEqual(template.steps[1].bundleId, "net.whatsapp.WhatsApp")
        XCTAssertEqual(template.steps[2].text, "Sending to {person}: {message}")
        XCTAssertEqual(template.steps[3].key, "return")
        // Added next to plain WhatsApp, it validates and doesn't clash.
        var config = VoiceLaunchConfig()
        for id in ["whatsapp", "whatsapp-send"] { catalog.add(try XCTUnwrap(catalog.templates.first { $0.id == id }), to: &config) }
        XCTAssertNil(config.validate(allowedSchemes: catalog.allowedLinkSchemes))
        config.lists[0].entries = [VoiceListEntry(names: ["Dana"], values: ["phone": "+972501234567"])]
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: "WhatsApp and send Dana running late", in: config) else { return XCTFail() }
        XCTAssertEqual(plan.commandName, "WhatsApp and send")
        XCTAssertEqual(plan.steps[0].link, "whatsapp://send?phone=%2B972501234567&text=running%20late")
        XCTAssertEqual(plan.steps[2].text, "Sending to Dana: running late")
        guard case .plan(let plain) = VoiceLaunchEngine.plan(for: "WhatsApp Dana running late", in: config) else { return XCTFail() }
        XCTAssertEqual(plain.commandName, "WhatsApp")
    }

    // MARK: Cancelling after something was filled in

    @MainActor
    func testCancelAfterTheMessageWasFilledInSendsNothingAndSaysTheDraftStays() async {
        let clipboard = ClipboardBox()
        let keys = KeyBox()
        var pasted: [String] = []
        var services = services(confirm: false, clipboard: clipboard, keys: keys)
        services.pasteText = { text, _ in pasted.append(text); return .pasted }
        let plan = VoiceLaunchPlan(commandId: "s", commandName: "Send", slots: [], steps: [
            VoiceStep(kind: .typeText, text: "hi there"),
            VoiceStep(kind: .confirm, text: "Sending hi", seconds: 3),
            VoiceStep(kind: .pressKey, key: "return")], mainText: "hi there")
        let result = await VoiceLaunchExecutor.run(plan, services: services)
        guard case .cancelled(let alert) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(pasted, ["hi there"], "the draft was made")
        XCTAssertTrue(keys.pressed.isEmpty, "no send step ran")
        XCTAssertEqual(clipboard.text, "hi there")
        XCTAssertNotEqual(alert, VoiceLaunchExecutor.cancelAlert)
        XCTAssertTrue(alert.detail.contains("not sent") && alert.detail.contains("clipboard"), alert.detail)
    }

    @MainActor
    func testCancelBeforeAnythingOpenedSaysOnlyThatNothingWasSent() async {
        let plan = VoiceLaunchPlan(commandId: "s", commandName: "Send", slots: [], steps: [
            VoiceStep(kind: .confirm, text: "ok", seconds: 3), VoiceStep(kind: .pressKey, key: "return")], mainText: "hi")
        let result = await VoiceLaunchExecutor.run(plan, services: services(confirm: false))
        guard case .cancelled(let alert) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(alert, VoiceLaunchExecutor.cancelAlert)
    }

    @MainActor
    func testAPlanMissingADetailRunsNothing() async {
        let clipboard = ClipboardBox()
        let keys = KeyBox()
        var plan = VoiceLaunchPlan(commandId: "s", commandName: "Send", slots: [], steps: [
            VoiceStep(kind: .confirm, text: "ok", seconds: 3), VoiceStep(kind: .pressKey, key: "return")], mainText: "hi")
        plan.missingDetail = "Noa doesn’t have a phone number yet"
        let result = await VoiceLaunchExecutor.run(plan, services: services(clipboard: clipboard, keys: keys))
        guard case .stopped(let alert) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(alert.title, "Noa doesn’t have a phone number yet")
        XCTAssertTrue(keys.pressed.isEmpty)
        XCTAssertEqual(clipboard.text, "hi")
    }

    // MARK: Esc during a pause

    func testOverlappingPausesEachKeepTheirOwnCancel() {
        var first = 0, second = 0
        let a = VoiceLaunchEscapeWatch.register { first += 1 }
        let b = VoiceLaunchEscapeWatch.register { second += 1 }
        VoiceLaunchEscapeWatch.unregister(b) // the second launch finished first
        XCTAssertTrue(VoiceLaunchEscapeWatch.fire())
        XCTAssertEqual(first, 1, "the first pause can still be cancelled")
        XCTAssertEqual(second, 0)
        VoiceLaunchEscapeWatch.unregister(a)
        XCTAssertFalse(VoiceLaunchEscapeWatch.fire())
    }

    func testAppendRefusesFilesThatRunOrMatter() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let hidden = home.appendingPathComponent(".zshrc")
        try Data().write(to: hidden)
        let link = home.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: hidden)
        let refused = [hidden.path, link.path, home.path + "/notes/../.zshrc", home.path + "/.ssh/config",
                       home.path + "/Library/LaunchAgents/x.plist", "/etc/hosts", "/usr/local/bin/x"]
        for path in refused { XCTAssertFalse(VoiceLaunchConfig.isAppendablePath(path, home: home.path), path) }
        XCTAssertTrue(VoiceLaunchConfig.isAppendablePath(home.path + "/log.txt", home: home.path))
        XCTAssertThrowsError(try VoiceLaunchActing.appendLine(VoiceStep(kind: .appendToFile, text: "id", path: link.path), now: Date()))
        XCTAssertEqual(try Data(contentsOf: hidden), Data(), "nothing reaches the file behind the link")
    }

    func testConfirmStepFromAnotherMacCannotCrashOrSkipItsPause() async {
        for seconds in [1e16, .infinity, Double.nan] {
            var ticks = 0
            let finished = await VoiceLaunchCountdown.run(seconds: seconds, sleep: { _ in ticks += 1 }, isCancelled: { false }, tick: { _ in })
            XCTAssertTrue(finished)
            XCTAssertGreaterThan(ticks, 0)
            XCTAssertLessThanOrEqual(ticks, 300)
        }
    }

    func testSpokenWordsNeverBecomeAFlag() {
        let script = ShellQuote.terminalScript(folder: "~/Work", command: "claude", argument: "--dangerously-skip-permissions")
        XCTAssertTrue(script.contains("exec claude ' --dangerously-skip-permissions'"), script)
        XCTAssertTrue(ShellQuote.terminalScript(folder: "~", command: "claude", argument: "fix it").contains("exec claude 'fix it'"))
    }

    func testTerminalCommandCannotCarryALineBreak() {
        let range = { (text: String) in NSRange(text.startIndex..., in: text) }
        XCTAssertNil(VoiceLaunchConfig.terminalCommandAllowed.firstMatch(in: "claude\n", range: range("claude\n")))
        XCTAssertNotNil(VoiceLaunchConfig.terminalCommandAllowed.firstMatch(in: "claude --foo", range: range("claude --foo")))
    }

    // MARK: Background Terminal action

    func testBackgroundDeliversHostileWordsLiterally() async throws {
        let root = tempFile().deletingLastPathComponent()
        let folder = root.appendingPathComponent("folder '\" $(touch \"$MARKER\")\n")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let marker = folder.appendingPathComponent("marker")
        let output = folder.appendingPathComponent("argument.txt")
        let capture = folder.appendingPathComponent("capture")
        try "#!/bin/zsh -f\nprintf '%s' \"$1\" > argument.txt\nprintf '%s' \"$#\" > count.txt\n".write(to: capture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: capture.path)
        let payloads = [#"; touch "$MARKER""#, #"$(touch "$MARKER")"#, #"`touch "$MARKER"`"#,
                        #"'"; touch "$MARKER"; '""#, "first\n; touch \"$MARKER\"\nlast", "--flag", "שלום café 🎙"]
        for payload in payloads {
            var arguments = ShellQuote.backgroundArguments(folder: folder.path, command: "./capture", argument: payload)
            // A marker variable local to this synthetic shell makes even a
            // mistakenly evaluated payload observable, inside this test folder.
            arguments[2] = "MARKER=" + ShellQuote.single(marker.path) + "; " + arguments[2]
            let completed = await VoiceLaunchActing.liveRunProcess("/bin/zsh", arguments, 5)
            let result = try XCTUnwrap(completed)
            XCTAssertEqual(result.status, 0)
            XCTAssertFalse(result.timedOut)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            let expected = payload.hasPrefix("-") ? " " + payload : payload
            XCTAssertEqual(try Data(contentsOf: output), Data(expected.utf8))
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("count.txt"), encoding: .utf8), "1")
        }
        let empty = await VoiceLaunchActing.liveRunProcess("/bin/zsh", ShellQuote.backgroundArguments(folder: folder.path, command: "./capture", argument: ""), 5)
        XCTAssertEqual(empty?.status, 0)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("count.txt"), encoding: .utf8), "0")
    }

    func testBackgroundEnvironmentDropsCredentialsAndKeepsOnlyBasicValues() {
        let environment = VoiceLaunchActing.backgroundEnvironment(["HOME": "/synthetic", "LANG": "en_US.UTF-8",
            "DICTATOR_TOKEN": "synthetic-secret", "OPENAI_API_KEY": "synthetic-key", "ZDOTDIR": "/synthetic", "PATH": "/synthetic"])
        XCTAssertEqual(environment["HOME"], "/synthetic")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(Set(environment.keys), ["HOME", "LANG", "PATH"])
        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testBackgroundValidationRequiresACommandPauseAndBoundedTimeout() {
        var step = VoiceStep(kind: .runInTerminal, folder: "/synthetic", command: "printf", background: true)
        XCTAssertTrue(step.isActing)
        func command(_ step: VoiceStep, pause: Bool = true) -> VoiceCommand {
            VoiceCommand(name: "Example", pattern: "Example {words}", steps:
                (pause ? [VoiceStep(kind: .confirm, text: "Ready?")] : []) + [step])
        }
        let config = VoiceLaunchConfig()
        XCTAssertNil(config.validate(command(step)))
        XCTAssertNotNil(config.validate(command(step, pause: false)))
        for value in [0.0, -1, 601, .infinity, .nan] {
            step.timeoutSeconds = value
            XCTAssertNotNil(config.validate(command(step)))
        }
        for value in [1.0, 60, 600] {
            step.timeoutSeconds = value
            XCTAssertNil(config.validate(command(step)))
        }
        step.timeoutSeconds = nil
        for value in [nil, "", "   "] as [String?] {
            step.command = value
            XCTAssertNotNil(config.validate(command(step)))
        }
        step.background = nil
        XCTAssertFalse(step.isActing)
        XCTAssertNil(config.validate(command(step)))
    }

    @MainActor
    func testBackgroundRechecksCommandAndTimeoutWithoutStartingAProcess() async throws {
        let folder = tempFile().deletingLastPathComponent()
        var calls = 0
        let mock = services(run: { _, _, _ in calls += 1; return nil })
        for command in ["", "printf\n", "printf\ntrue", "printf; true", "printf $(true)"] {
            let step = VoiceStep(kind: .runInTerminal, folder: folder.path, command: command, background: true)
            do { try await VoiceLaunchActing.runBackgroundCommand(step, services: mock); XCTFail("Should refuse") }
            catch is VoiceLaunchExecutor.Failure {} catch { XCTFail("\(error)") }
        }
        for timeout in [0.0, 601, .infinity, .nan] {
            let step = VoiceStep(kind: .runInTerminal, folder: folder.path, command: "printf", timeoutSeconds: timeout, background: true)
            do { try await VoiceLaunchActing.runBackgroundCommand(step, services: mock); XCTFail("Should refuse") }
            catch is VoiceLaunchExecutor.Failure {} catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testBackgroundFailureKeepsWordsAndLogsOnlyStatusAndDuration() async throws {
        let folder = tempFile().deletingLastPathComponent()
        let previousLog = HotkeyService.diagnosticsPath
        HotkeyService.diagnosticsPath = folder.appendingPathComponent("diagnostics.log")
        defer { HotkeyService.diagnosticsPath = previousLog }
        let clipboard = ClipboardBox()
        let keys = KeyBox()
        var logs: [String] = []
        var mock = services(clipboard: clipboard, keys: keys, run: { executable, arguments, timeout in
            XCTAssertEqual(executable, "/bin/zsh")
            XCTAssertEqual(arguments, ShellQuote.backgroundArguments(folder: folder.path, command: "./capture", argument: "synthetic words"))
            XCTAssertEqual(timeout, 60)
            return VoiceLaunchProcessResult(status: 7, timedOut: false, stdout: "private output", stderr: "synthetic error\n" + String(repeating: "x", count: 400))
        })
        mock.log = { logs.append($0) }
        let plan = VoiceLaunchPlan(commandId: "test", commandName: "Example", slots: [], steps: [
            VoiceStep(kind: .runInTerminal, folder: folder.path, command: "./capture", argument: "synthetic words", background: true),
            VoiceStep(kind: .pressKey, key: "return")], mainText: "synthetic words")
        let result = await VoiceLaunchExecutor.run(plan, services: mock)
        guard case .stopped(let alert) = result else { return XCTFail("Expected failure") }
        XCTAssertTrue(alert.title.contains("7"))
        XCTAssertTrue(alert.detail.contains("synthetic error"))
        XCTAssertLessThan(alert.detail.count, 450)
        XCTAssertTrue(alert.detail.contains("clipboard"))
        XCTAssertEqual(clipboard.text, "synthetic words")
        XCTAssertTrue(keys.pressed.isEmpty)
        XCTAssertEqual(logs, ["voicelaunch: exited 7 0ms"])
    }

    @MainActor
    func testBackgroundTimeoutAlertAndCustomLimit() async throws {
        let folder = tempFile().deletingLastPathComponent()
        let step = VoiceStep(kind: .runInTerminal, folder: folder.path, command: "./capture", timeoutSeconds: 600, background: true)
        let mock = services(run: { _, _, timeout in
            XCTAssertEqual(timeout, 600)
            return VoiceLaunchProcessResult(status: 137, timedOut: true, stderr: "private output")
        })
        do { try await VoiceLaunchActing.runBackgroundCommand(step, services: mock); XCTFail("Expected timeout") }
        catch let failure as VoiceLaunchExecutor.Failure {
            XCTAssertTrue(failure.alert.title.contains("time"))
            XCTAssertTrue(failure.alert.detail.contains("600"))
            XCTAssertFalse(failure.alert.detail.contains("private output"))
        }
    }


    /// The child only creates a test-local marker after a short delay. Even
    /// a broken timeout leaves no work outside the test's temporary folder.
    private func backgroundTree(in folder: URL) throws -> [String] {
        let script = folder.appendingPathComponent("tree")
        try "#!/bin/zsh -f\n(/bin/sleep 3; printf done > child-finished.txt) &\nprintf ready > ready.txt\nwait\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return ShellQuote.backgroundArguments(folder: folder.path, command: "./tree", argument: "")
    }

    func testBackgroundTimeoutStopsChildProcesses() async throws {
        let folder = tempFile().deletingLastPathComponent()
        let arguments = try backgroundTree(in: folder)
        let result = await VoiceLaunchActing.liveRunProcess("/bin/zsh", arguments, 1)
        XCTAssertEqual(result?.timedOut, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready.txt").path))
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("child-finished.txt").path))
    }

    func testBackgroundTaskCancellationStopsChildProcesses() async throws {
        let folder = tempFile().deletingLastPathComponent()
        let arguments = try backgroundTree(in: folder)
        let task = Task { await VoiceLaunchActing.liveRunProcess("/bin/zsh", arguments, 5) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready.txt").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready.txt").path))
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result?.timedOut, false)
        XCTAssertNotEqual(result?.status, 0)
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("child-finished.txt").path))
    }

    @MainActor
    func testEscCancelsRunningBackgroundStepAndSkipsLaterActions() async throws {
        let folder = tempFile().deletingLastPathComponent()
        let previousLog = HotkeyService.diagnosticsPath
        HotkeyService.diagnosticsPath = folder.appendingPathComponent("diagnostics.log")
        defer { HotkeyService.diagnosticsPath = previousLog }
        let started = expectation(description: "process started")
        let clipboard = ClipboardBox()
        let keys = KeyBox()
        var processCancelled = false
        let mock = services(clipboard: clipboard, keys: keys, run: { _, _, _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(5)) }
            catch { processCancelled = Task.isCancelled }
            return VoiceLaunchProcessResult(status: 137, timedOut: false)
        })
        let plan = VoiceLaunchPlan(commandId: "test", commandName: "Example", slots: [], steps: [
            VoiceStep(kind: .runInTerminal, folder: folder.path, command: "./capture", background: true),
            VoiceStep(kind: .pressKey, key: "return")], mainText: "synthetic words")
        let task = Task { await VoiceLaunchExecutor.run(plan, services: mock) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(VoiceLaunchEscapeWatch.fire())
        guard case .cancelled(let alert) = await task.value else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(processCancelled)
        XCTAssertTrue(alert.detail.contains("stopped"))
        XCTAssertEqual(clipboard.text, "synthetic words")
        XCTAssertTrue(keys.pressed.isEmpty)
    }

    func testBackgroundHasNoInputAndDiscardsStandardOutput() async throws {
        let folder = tempFile().deletingLastPathComponent()
        let script = folder.appendingPathComponent("capture")
        try "#!/bin/zsh -f\nif read value; then exit 9; fi\nprintf private-output\nprintf synthetic-error >&2\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let result = await VoiceLaunchActing.liveRunProcess("/bin/zsh", ShellQuote.backgroundArguments(folder: folder.path, command: "./capture", argument: ""), 5)
        XCTAssertEqual(result?.status, 0)
        XCTAssertEqual(result?.stdout, "")
        XCTAssertEqual(result?.stderr, "synthetic-error")
    }

}
