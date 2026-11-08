import XCTest
@testable import Dictator

/// Settings › Your Macs: the setup picture the Core builds, invitations,
/// and what the page shows for a given picture.
@MainActor
final class SetupTests: XCTestCase {
    private var savedServerURL = ""
    private var savedRouting = ""
    private var savedRefine: RefineLevel = .medium
    private var savedKnown: Data?

    override func setUp() async throws {
        try await super.setUp()
        let settings = AppSettings.shared
        savedServerURL = settings.serverURL
        savedRouting = settings.setupRoutingJSON
        savedRefine = settings.refineLevel
        savedKnown = UserDefaults.standard.data(forKey: "setupKnownMachines")
        UserDefaults.standard.removeObject(forKey: "setupKnownMachines")
        settings.serverURL = "http://100.64.0.1:7878"
        settings.setupRoutingJSON = ""
        settings.refineLevel = .medium
    }

    override func tearDown() async throws {
        let settings = AppSettings.shared
        settings.serverURL = savedServerURL
        settings.setupRoutingJSON = savedRouting
        settings.refineLevel = savedRefine
        if let savedKnown {
            UserDefaults.standard.set(savedKnown, forKey: "setupKnownMachines")
        } else {
            UserDefaults.standard.removeObject(forKey: "setupKnownMachines")
        }
        try await super.tearDown()
    }

    private func edge(_ id: String, _ name: String, ip: String, product: String, mic: Bool = true, models: [String]? = nil) -> BrokerEdgeInfo {
        var caps = EdgeCapabilities(hasMic: mic, inputDeviceUID: "", accessibility: true, inputMonitoring: true, hotkeyMode: "intercept")
        caps.machine = MachineProfile(productName: product, memoryGB: 32, tailscaleIP: ip)
        caps.localModels = models
        return BrokerEdgeInfo(id: id, name: name, caps: caps)
    }

    private func directory() -> SetupDirectory {
        SetupDirectory(fetchHealth: { url in
            guard url.host == "100.64.0.1" else { return nil }
            return ["status": "ok", "asr_model": "mlx-community/whisper-small-mlx", "polish_model": "gemma4:e2b-it-qat",
                    "ollama_url": "http://127.0.0.1:11434"]
        })
    }

    func testSpeechServerIsMatchedToItsMac() async {
        let setup = directory()
        setup.update(edges: [edge("mini", "Mac mini", ip: "100.64.0.1", product: "Mac mini (2024)", mic: false),
                             edge("mbp", "MacBook Pro", ip: "100.64.0.2", product: "MacBook Pro (14-inch, 2021)")],
                     coreEdgeId: "mini")
        await setup.refreshServices()
        let snapshot = try! XCTUnwrap(setup.snapshot)
        XCTAssertEqual(snapshot.speech?.machineId, "mini")
        XCTAssertEqual(snapshot.speech?.cleanupMachineId, "mini")
        XCTAssertEqual(snapshot.speech?.reachable, true)
        XCTAssertEqual(snapshot.machines.first?.id, "mini", "the main Mac comes first")
        XCTAssertEqual(snapshot.machine("mbp")?.profile?.kind, .laptop)
    }

    func testDisconnectedMacStaysListedUntilForgotten() {
        let setup = directory()
        setup.update(edges: [edge("mini", "Mac mini", ip: "100.64.0.1", product: "Mac mini"),
                             edge("mbp", "MacBook Pro", ip: "100.64.0.2", product: "MacBook Pro")], coreEdgeId: "mini")
        setup.update(edges: [edge("mini", "Mac mini", ip: "100.64.0.1", product: "Mac mini")], coreEdgeId: "mini")
        XCTAssertEqual(setup.snapshot?.machine("mbp")?.online, false)
        setup.forget("mbp")
        XCTAssertNil(setup.snapshot?.machine("mbp"))
        setup.forget("mini")
        XCTAssertNotNil(setup.snapshot?.machine("mini"), "a connected Mac can't be removed")
    }

    func testRemovalConfirmationWarnsForEveryConfiguredSpeechServer() throws {
        var report = snapshot()
        report.machines[2].online = false
        let removed = try XCTUnwrap(report.machine("mbp"))
        let local = SetupDirectory.removalConfirmation(machine: removed, snapshot: report,
                                                       speechAddresses: ["http://localhost:7878"])
        XCTAssertTrue(local.contains("“MacBook Pro” will no longer be able to connect"))
        XCTAssertTrue(local.contains("Off or disconnected: “Mac Studio”"))
        XCTAssertTrue(local.contains("History already on that Mac stays there"))
        XCTAssertTrue(local.contains("Settings › Your Macs › Add a Mac"))
        XCTAssertTrue(local.contains("does not change the speech server key"))
        XCTAssertTrue(local.contains("delete the key file on the server’s Mac and restart the server"))
        XCTAssertTrue(local.contains("Then paste the new key"))
        let remote = SetupDirectory.removalConfirmation(machine: removed, snapshot: report,
                                                        speechAddresses: ["http://100.64.0.9:7878"])
        XCTAssertTrue(remote.contains("does not change the speech server key"))
        XCTAssertTrue(remote.contains("Settings › Advanced › Speech server key"))
        report.speech = nil
        report.backups = []
        for address in ["http://localhost:7878", "http://127.0.0.1:7878", "http://[::1]:7878", "http://100.64.0.1:7878"] {
            XCTAssertTrue(SetupDirectory.removalConfirmation(machine: removed, snapshot: report, speechAddresses: [address]).contains("does not change the speech server key"))
        }
        XCTAssertFalse(SetupDirectory.removalConfirmation(machine: removed, snapshot: report, speechAddresses: [" "]).contains("speech server key"))
        report.backups = [SetupSnapshot.SpeechService(address: "http://100.64.0.3:7878", machineId: "studio",
            reachable: false, speechModel: nil, cleanupModel: nil, cleanupMachineId: nil, checkedAt: Date())]
        XCTAssertTrue(SetupDirectory.removalConfirmation(machine: removed, snapshot: report, speechAddresses: []).contains("does not change the speech server key"))
    }

    func testConnectedMacCanBeForgottenAfterDisconnectWithoutRemovingMainMac() {
        let setup = directory()
        let main = edge("mini", "Main", ip: "100.64.0.1", product: "Mac mini")
        let laptop = edge("mbp", "Laptop", ip: "100.64.0.2", product: "MacBook Pro")
        setup.update(edges: [main, laptop], coreEdgeId: "mini")
        setup.forget("mbp")
        XCTAssertNotNil(setup.snapshot?.machine("mbp"), "revocation must disconnect first")
        setup.update(edges: [main], coreEdgeId: "mini")
        setup.forget("mbp")
        XCTAssertNil(setup.snapshot?.machine("mbp"))
        setup.update(edges: [], coreEdgeId: "mini")
        setup.forget("mini")
        XCTAssertNotNil(setup.snapshot?.machine("mini"))
    }

    func testChosenCleanupMacOverridesTheServers() async {
        AppSettings.shared.updateSetupRouting { $0.cleanupMachineId = "mbp"; $0.cleanupModel = "gemma3:4b" }
        let setup = directory()
        setup.update(edges: [edge("mini", "Mac mini", ip: "100.64.0.1", product: "Mac mini"),
                             edge("mbp", "MacBook Pro", ip: "100.64.0.2", product: "MacBook Pro", models: ["gemma3:4b"])], coreEdgeId: "mini")
        await setup.refreshServices()
        XCTAssertEqual(setup.snapshot?.speech?.cleanupMachineId, "mbp")
        XCTAssertEqual(setup.snapshot?.speech?.cleanupModel, "gemma3:4b")
    }

    func testUnreachableServerIsReported() async {
        AppSettings.shared.serverURL = "http://100.64.0.7:7878"
        let setup = directory()
        setup.update(edges: [edge("mini", "Mac mini", ip: "100.64.0.1", product: "Mac mini")], coreEdgeId: "mini")
        await setup.refreshServices()
        XCTAssertEqual(setup.snapshot?.speech?.reachable, false)
        XCTAssertNil(setup.snapshot?.speech?.machineId)
    }

    func testUnsafeSavedSpeechAddressIsRetainedWithoutHealthRequest() async {
        let address = "http://100.64.0.1.evil.example:7878"
        AppSettings.shared.serverURL = address
        let setup = SetupDirectory(fetchHealth: { _ in
            XCTFail("Unsafe speech addresses must not be probed")
            return nil
        })
        await setup.refreshServices()
        XCTAssertEqual(setup.snapshot?.speech?.address, address)
        XCTAssertEqual(setup.snapshot?.speech?.reachable, false)
    }

    // MARK: Clean-up configuration and automatic model activation

    func testRefineLevelsLoad() throws {
        // AppSettings and the settings mirror use the same load rule.
        XCTAssertEqual(RefineLevel.storedValue("light"), .medium)
        XCTAssertEqual(try JSONDecoder().decode(RefineLevel.self, from: Data("\"light\"".utf8)), .medium)
        // Polished keeps the wire value older Macs already read as `medium`.
        XCTAssertEqual(RefineLevel.polished.rawValue, "strong")
        XCTAssertEqual(RefineLevel.storedValue("strong"), .polished)
        XCTAssertEqual(try JSONDecoder().decode(RefineLevel.self, from: Data("\"strong\"".utf8)), .polished)
        XCTAssertEqual(RefineLevel.storedValue("exact"), .exact)
        XCTAssertEqual(RefineLevel.storedValue("medium"), .medium)
        XCTAssertNil(RefineLevel.storedValue("unknown"))
        XCTAssertEqual(RefineLevel.allCases, [.exact, .medium, .polished])
    }

    func testCleanupStatusDistinguishesSkippedReadyMissingAndUnknown() {
        var report = snapshot()
        report.speech?.cleanupModel = nil
        XCTAssertEqual(CleanupStatus.evaluate(refineLevel: .exact, routing: SetupRouting(), snapshot: nil), .skipped)
        XCTAssertEqual(CleanupStatus.evaluate(refineLevel: .medium, routing: SetupRouting(), snapshot: nil), .unknown)
        XCTAssertEqual(CleanupStatus.evaluate(refineLevel: .medium, routing: SetupRouting(), snapshot: report), .notSetUp)
        report.speech = nil
        XCTAssertEqual(CleanupStatus.evaluate(refineLevel: .medium, routing: SetupRouting(), snapshot: report), .notSetUp)
        let chosen = SetupRouting(cleanupMachineId: "mbp", cleanupModel: "gemma")
        XCTAssertEqual(CleanupStatus.evaluate(refineLevel: .medium, routing: chosen, snapshot: report), .ready)
        XCTAssertEqual(CleanupStatus.evaluate(refineLevel: .medium, routing: chosen, snapshot: nil), .unknown)
        XCTAssertEqual(CleanupStatus.evaluate(refineLevel: .exact, routing: chosen, snapshot: snapshot()), .skipped)
        XCTAssertEqual(CleanupStatus.evaluate(refineLevel: .medium,
            routing: SetupRouting(cleanupMachineId: "mbp"), snapshot: nil), .unknown)
    }

    func testServerThatCleansUpItselfIsConfiguredWithoutAMacRelay() {
        var report = snapshot()
        report.speech?.machineId = nil
        report.speech?.cleanupMachineId = nil
        report.machines = []
        XCTAssertEqual(CleanupStatus.evaluate(refineLevel: .medium, routing: SetupRouting(), snapshot: report), .ready)
        XCTAssertFalse(ModelSetupPolicy.shouldActivate(job: .cleanup, speechSources: servers, routing: SetupRouting(), snapshot: report))
        // This status describes configuration, not current availability.
        report.speech?.reachable = false
        XCTAssertEqual(CleanupStatus.evaluate(refineLevel: .medium, routing: SetupRouting(), snapshot: report), .ready)
    }

    func testAutomaticActivationOnlyFillsAnUnassignedJob() {
        let empty = SetupRouting()
        XCTAssertTrue(ModelSetupPolicy.shouldActivate(job: .speech, speechSources: [], routing: empty, snapshot: nil))
        for source in [servers[0], .mac("mbp", model: "whisperkit:existing")] {
            XCTAssertFalse(ModelSetupPolicy.shouldActivate(job: .speech, speechSources: [source], routing: empty, snapshot: nil))
        }
        var report = snapshot()
        report.speech?.cleanupModel = nil
        XCTAssertTrue(ModelSetupPolicy.shouldActivate(job: .cleanup, speechSources: servers, routing: empty, snapshot: report))
        XCTAssertTrue(ModelSetupPolicy.shouldActivate(job: .cleanup, speechSources: [], routing: empty, snapshot: nil))
        XCTAssertFalse(ModelSetupPolicy.shouldActivate(job: .cleanup, speechSources: [],
            routing: SetupRouting(cleanupMachineId: "mbp", cleanupModel: "chosen"), snapshot: report))
    }

    func testCompletionActivatesSpeechOnceAndNotYetUndoesIt() {
        let settings = AppSettings.shared
        settings.serverURL = ""
        settings.updateSetupRouting { $0.speechSources = [] }
        let completion = ModelSetupActivation()
        let source = SetupRouting.SpeechSource.mac("mbp", model: "whisperkit:new")
        completion.complete(job: .speech, machine: "mbp", model: "whisperkit:new", settings: settings, snapshot: nil)
        XCTAssertTrue(completion.activated)
        XCTAssertEqual(settings.speechSources, [source])
        // Repeated success callbacks cannot activate again, even after undo.
        completion.undo(settings: settings)
        completion.complete(job: .speech, machine: "mbp", model: "whisperkit:new", settings: settings, snapshot: nil)
        XCTAssertTrue(settings.speechSources.isEmpty)
    }

    func testCompletionRechecksForAChoiceMadeWhileDownloading() {
        let settings = AppSettings.shared
        let completion = ModelSetupActivation()
        let existing = SetupRouting.SpeechSource.mac("mini", model: "whisperkit:existing")
        settings.updateSpeechSources { $0 = [existing] }
        completion.complete(job: .speech, machine: "mbp", model: "whisperkit:new", settings: settings, snapshot: nil)
        XCTAssertFalse(completion.activated)
        XCTAssertTrue(completion.completed)
        XCTAssertEqual(settings.speechSources, [existing])
        completion.undo(settings: settings)
        XCTAssertEqual(settings.speechSources, [existing])
    }

    func testCleanupCompletionPreservesRefineLevelAndNotYetRestoresRouting() {
        let settings = AppSettings.shared
        settings.refineLevel = .exact
        settings.updateSetupRouting { $0.cleanupMachineId = "previous-partial-choice"; $0.languages = ["he"] }
        let completion = ModelSetupActivation()
        var report = snapshot()
        report.speech?.cleanupModel = nil
        completion.complete(job: .cleanup, machine: "mbp", model: "gemma:new", settings: settings, snapshot: report)
        XCTAssertTrue(completion.activated)
        XCTAssertEqual(settings.setupRouting.cleanupMachineId, "mbp")
        XCTAssertEqual(settings.setupRouting.cleanupModel, "gemma:new")
        XCTAssertEqual(settings.refineLevel, .exact)
        completion.undo(settings: settings)
        XCTAssertEqual(settings.setupRouting.cleanupMachineId, "previous-partial-choice")
        XCTAssertNil(settings.setupRouting.cleanupModel)
        XCTAssertEqual(settings.setupRouting.languages, ["he"])
    }

    func testCleanupUndoPreservesALaterChoice() {
        let settings = AppSettings.shared
        let completion = ModelSetupActivation()
        completion.complete(job: .cleanup, machine: "mbp", model: "gemma:new", settings: settings, snapshot: nil)
        settings.updateSetupRouting { $0.cleanupMachineId = "mini"; $0.cleanupModel = "gemma:other" }
        completion.undo(settings: settings)
        XCTAssertEqual(settings.setupRouting.cleanupModel, "gemma:other")
        XCTAssertEqual(settings.setupRouting.cleanupMachineId, "mini")
    }

    func testSpeechSourceDeduplicationKeepsEveryFirstAndBackupLast() {
        let settings = AppSettings.shared
        let added = SetupRouting.SpeechSource.mac("mbp", model: "whisperkit:new")
        settings.updateSpeechSources { $0 = [servers[0], added, servers[1]] }
        settings.updateSpeechSources { $0.insert(added, at: 0) }
        XCTAssertEqual(settings.speechSources, [added, servers[0], servers[1]])
        settings.updateSpeechSources {
            $0.removeAll { $0 == added }
            $0.append(added)
        }
        XCTAssertEqual(settings.speechSources, [servers[0], servers[1], added])
    }

    // MARK: Invitations

    func testInvitationRoundTripsAndRejectsOtherText() {
        let invitation = SetupInvitation(name: "Mac mini", address: "100.64.0.1", token: "secret")
        XCTAssertEqual(SetupInvitation.decode("  " + invitation.encoded + "\n"), invitation)
        XCTAssertNil(SetupInvitation.decode("100.64.0.1"))
        XCTAssertNil(SetupInvitation.decode("dictator-invite:not-base64"))
    }

    func testAnInvitationCanOnlyPointAtTailscale() {
        for address in ["203.0.113.9", "example.com", "127.0.0.1", "100.128.0.1", "100.64.0.1:7880", ""] {
            let invitation = SetupInvitation(name: "Mac", address: address, token: "secret")
            XCTAssertNil(SetupInvitation.decode(invitation.encoded), address)
        }
    }

    // MARK: What Your Macs shows

    private func snapshot(speechReachable: Bool = true, miniOnline: Bool = true, backup: Bool = false) -> SetupSnapshot {
        let now = Date()
        var machines = [
            SetupSnapshot.Machine(id: "mini", name: "Mac mini", profile: nil, hasMic: false, online: miniOnline, lastSeen: now, isCore: true, localModels: ["gemma4:e2b-it-qat"]),
            SetupSnapshot.Machine(id: "mbp", name: "MacBook Pro", profile: nil, hasMic: true, online: true, lastSeen: now, isCore: false, localModels: ["gemma3:4b"]),
        ]
        machines.append(SetupSnapshot.Machine(id: "studio", name: "Mac Studio", profile: nil, hasMic: true, online: true, lastSeen: now, isCore: false, localModels: nil))
        let speech = SetupSnapshot.SpeechService(address: "http://100.64.0.1:7878", machineId: "mini", reachable: speechReachable,
                                                 speechModel: "mlx-community/whisper-small-mlx", cleanupModel: "gemma4:e2b-it-qat",
                                                 cleanupMachineId: "mini", checkedAt: now)
        let backups = backup ? [SetupSnapshot.SpeechService(address: "http://100.64.0.3:7878", machineId: "studio", reachable: true,
                                                              speechModel: "whisper-large", cleanupModel: nil, cleanupMachineId: "studio", checkedAt: now)] : []
        return SetupSnapshot(coreId: "mini", machines: machines, speech: speech, backups: backups, cleanupOn: true, generatedAt: now)
    }

    func testRecordingMacChoicesAndCopyForEveryRole() {
        let settings = AppSettings.shared
        let savedRole = settings.coreRole
        let savedRecorder = settings.micOwnerEdgeID
        defer { settings.coreRole = savedRole; settings.micOwnerEdgeID = savedRecorder }
        for role in [CoreRole.standalone, .core, .edge] {
            settings.coreRole = role
            settings.micOwnerEdgeID = "studio"
            let model = YourMacsModel(snapshot: snapshot(), localId: "mbp", settings: settings, connectedToMainMac: true)
            XCTAssertEqual(model.recordingMachines.map(\.id), ["mbp", "studio"])
            XCTAssertEqual(model.place(for: .record).text, "Mac Studio")
            XCTAssertEqual(model.involved(in: .record), ["studio"])
            XCTAssertTrue(model.caption(for: .record).contains("Mac Studio records"))
            settings.micOwnerEdgeID = ""
            XCTAssertEqual(model.place(for: .record).text, "On the Mac you press the key on")
            XCTAssertEqual(model.caption(for: .record), "Automatic records on the Mac you press the key on. If it has no microphone, Dictator asks first instead of using another Mac.")
        }
    }

    func testRecordingMacChoicesKeepOfflineInventoryAndUseActualLocalMicrophone() {
        let settings = AppSettings.shared
        let savedRole = settings.coreRole
        let savedRecorder = settings.micOwnerEdgeID
        defer { settings.coreRole = savedRole; settings.micOwnerEdgeID = savedRecorder }
        settings.coreRole = .edge
        settings.micOwnerEdgeID = "studio"
        let disconnected = YourMacsModel(snapshot: snapshot(), localId: "mbp", settings: settings,
                                         connectedToMainMac: false, localHasMic: false)
        XCTAssertEqual(disconnected.recordingMachines.map(\.id), ["studio"])
        XCTAssertFalse(disconnected.recordingMachines[0].online)
        XCTAssertTrue(disconnected.place(for: .record).warning)
        XCTAssertTrue(disconnected.caption(for: .record).hasPrefix("Your chosen Mac is unavailable."))
        let noMic = YourMacsModel(snapshot: nil, localId: "local", settings: settings, localHasMic: false)
        XCTAssertTrue(noMic.recordingMachines.isEmpty)
        let mic = YourMacsModel(snapshot: nil, localId: "local", settings: settings, localHasMic: true)
        XCTAssertEqual(mic.recordingMachines.map(\.id), ["local"])
    }

    private let servers: [SetupRouting.SpeechSource] = [.server("http://100.64.0.1:7878"), .server("http://100.64.0.3:7878")]

    func testDisconnectedEdgeCannotTreatPersistedOnlineSnapshotAsCurrentReadiness() throws {
        let settings = AppSettings.shared
        let savedRole = settings.coreRole
        defer { settings.coreRole = savedRole }
        settings.coreRole = .edge
        var old = snapshot(backup: true)
        old.generatedAt = Date(timeIntervalSince1970: 1_000)
        old.speech?.checkedAt = old.generatedAt
        // A persisted report retains its old true bits after the transport is gone.
        let persisted = try JSONDecoder().decode(SetupSnapshot.self, from: JSONEncoder().encode(old))
        XCTAssertTrue(persisted.machine("mini")?.online == true)
        XCTAssertTrue(persisted.speech?.reachable == true)
        let disconnected = YourMacsModel(snapshot: persisted, localId: "mbp", settings: settings,
                                         speechSources: servers, connectedToMainMac: false)
        XCTAssertFalse(disconnected.machines.first(where: { $0.id == "mini" })?.online == true)
        XCTAssertFalse(disconnected.sources.contains(where: \.available))
        XCTAssertFalse(disconnected.cleanupRuns)
        XCTAssertTrue(disconnected.place(for: .save).warning)
        XCTAssertTrue(disconnected.routes(for: .speech).allSatisfy(\.waiting))
        XCTAssertTrue(disconnected.routes(for: nil).allSatisfy(\.waiting))
        let status = DictationReadiness.evaluate(snapshot: persisted, coreRole: .edge, serverURL: servers[0].serverURL!,
            blockingProblem: nil, localRecordingProblem: nil, speechSources: servers,
            machines: persisted.machines, connectedToMainMac: false)
        XCTAssertFalse(status.ready, "a cached successful health check is not current transport evidence")
        XCTAssertTrue(disconnected.sources.allSatisfy(\.statusIsUnverified), "direct servers are unverified, not proven down")
        let remote = try XCTUnwrap(disconnected.machines.first(where: { $0.id == "mini" }))
        XCTAssertEqual(remote.localModels, persisted.machine("mini")?.localModels, "keep cached inventory visible")
        XCTAssertTrue(disconnected.models(on: remote).filter { $0.job == .speech }.allSatisfy { $0.statusIsUnverified && !$0.active })
        XCTAssertEqual(disconnected.snapshot, persisted, "presentation must not rewrite the persisted report")
        XCTAssertEqual(remote.lastSeen, persisted.machine("mini")?.lastSeen)
    }

    func testDisconnectedEdgeUsesCurrentLocalSpeechInventoryAndKeepsRemoteModelsUnavailable() throws {
        let settings = AppSettings.shared
        let savedRole = settings.coreRole
        defer { settings.coreRole = savedRole }
        settings.coreRole = .edge
        var old = snapshot()
        old.machines[0].speechModels = ["whisperkit:remote"]
        old.machines[1].online = false
        old.machines[1].speechModels = ["whisperkit:removed"]
        let local = SetupRouting.SpeechSource.mac("mbp", model: "whisperkit:current")
        let sources: [SetupRouting.SpeechSource] = [.mac("mini", model: "whisperkit:remote"), servers[0], local]
        let model = YourMacsModel(snapshot: old, localId: "mbp", settings: settings, speechSources: sources,
                                 connectedToMainMac: false, localSpeechModels: ["whisperkit:current"])
        XCTAssertEqual(model.sources.filter(\.available).map(\.source), [local])
        XCTAssertEqual(model.activeSpeechMachine, "mbp")
        XCTAssertTrue(model.machines.first(where: { $0.id == "mbp" })?.online == true)
        XCTAssertEqual(model.machines.first(where: { $0.id == "mbp" })?.speechModels, ["whisperkit:current"])
        XCTAssertEqual(model.machines.first(where: { $0.id == "mini" })?.speechModels, ["whisperkit:remote"])
        XCTAssertFalse(model.cleanupRuns, "the cached remote clean-up model is not usable through a disconnected main Mac")
        let status = DictationReadiness.evaluate(snapshot: old, coreRole: .edge, serverURL: "",
            blockingProblem: nil, localRecordingProblem: nil, speechSources: sources, machines: model.machines,
            connectedToMainMac: false, localId: "mbp")
        XCTAssertTrue(status.ready)

        let removed = YourMacsModel(snapshot: old, localId: "mbp", settings: settings,
            speechSources: [.mac("mbp", model: "whisperkit:removed")], connectedToMainMac: false,
            localSpeechModels: ["whisperkit:current"])
        XCTAssertFalse(removed.sources.contains(where: \.available), "a cached installed model cannot override current local inventory")
    }

    func testDisconnectedReadinessCannotUseARemoteModelEvenIfRawCachedMachineIsOnline() {
        var old = snapshot()
        old.machines[0].speechModels = ["whisperkit:remote"]
        let status = DictationReadiness.evaluate(snapshot: old, coreRole: .edge, serverURL: "",
            blockingProblem: nil, localRecordingProblem: nil, speechSources: [.mac("mini", model: "whisperkit:remote")],
            machines: old.machines, connectedToMainMac: false, localId: "mbp")
        XCTAssertFalse(status.ready)
    }

    func testDisconnectedEdgeDoesNotShowALocalDirectServersCachedReportAsAnActiveChip() throws {
        let settings = AppSettings.shared
        let savedRole = settings.coreRole
        defer { settings.coreRole = savedRole }
        settings.coreRole = .edge
        var old = snapshot()
        old.speech?.address = "http://100.64.0.2:7878"
        old.speech?.machineId = "mbp"
        let model = YourMacsModel(snapshot: old, localId: "mbp", settings: settings,
            speechSources: [.server("http://100.64.0.2:7878")], connectedToMainMac: false)
        let own = try XCTUnwrap(model.machines.first(where: { $0.id == "mbp" }))
        XCTAssertTrue(own.online)
        let chip = try XCTUnwrap(model.models(on: own).first(where: { $0.job == .speech }))
        XCTAssertTrue(chip.statusIsUnverified)
        XCTAssertFalse(chip.active)
        XCTAssertTrue(chip.tagIsWarning)
    }

    func testDisconnectedEdgesOwnCleanupUsesCurrentInventoryInsteadOfCachedModelPresence() throws {
        let settings = AppSettings.shared
        let savedRole = settings.coreRole
        defer { settings.coreRole = savedRole }
        settings.coreRole = .edge
        settings.updateSetupRouting { $0.cleanupMachineId = "mbp"; $0.cleanupModel = "gemma3:4b" }
        let old = snapshot()
        let unknown = YourMacsModel(snapshot: old, localId: "mbp", settings: settings,
                                    speechSources: servers, connectedToMainMac: false)
        let own = try XCTUnwrap(unknown.machines.first(where: { $0.id == "mbp" }))
        let chip = try XCTUnwrap(unknown.models(on: own).first(where: { $0.id == "cleanup" }))
        XCTAssertFalse(unknown.cleanupRuns)
        XCTAssertFalse(chip.active)
        XCTAssertTrue(chip.statusIsUnverified)
        let current = YourMacsModel(snapshot: old, localId: "mbp", settings: settings, speechSources: servers,
                                    connectedToMainMac: false, localCleanupModels: ["gemma3:4b"])
        XCTAssertTrue(current.cleanupRuns)
        let currentOwn = try XCTUnwrap(current.machines.first(where: { $0.id == "mbp" }))
        XCTAssertTrue(current.models(on: currentOwn).first(where: { $0.id == "cleanup" })?.active == true)
    }

    func testEdgeStatusFailsClosedWithoutConnectionContextAndRecoversWithAConnectedReport() {
        let settings = AppSettings.shared
        let savedRole = settings.coreRole
        defer { settings.coreRole = savedRole }
        settings.coreRole = .edge
        let report = snapshot()
        let unknown = YourMacsModel(snapshot: report, localId: "mbp", settings: settings, speechSources: servers)
        XCTAssertFalse(unknown.sources.contains(where: \.available))
        let connected = YourMacsModel(snapshot: report, localId: "mbp", settings: settings,
                                      speechSources: servers, connectedToMainMac: true)
        XCTAssertTrue(connected.machines.first(where: { $0.id == "mini" })?.online == true)
        XCTAssertTrue(connected.sources.first?.available == true)
        XCTAssertTrue(connected.cleanupRuns)
        XCTAssertFalse(connected.sources.first?.statusIsUnverified == true)
        let status = DictationReadiness.evaluate(snapshot: report, coreRole: .edge, serverURL: "",
            blockingProblem: nil, localRecordingProblem: nil, speechSources: servers,
            connectedToMainMac: true, localId: "mbp")
        XCTAssertTrue(status.ready)
    }

    func testOfflineSpeechCaptionDoesNotPromiseTranscription() {
        let model = YourMacsModel(snapshot: snapshot(speechReachable: false, miniOnline: false),
                                  localId: "mbp", settings: .shared, speechSources: servers)
        XCTAssertTrue(model.caption(for: nil).contains("Nothing can turn your voice into text"))
        XCTAssertTrue(model.caption(for: .speech).contains("Nothing can turn your voice into text"))
    }

    func testUnverifiedServerIsNotShownAsAvailable() {
        let model = YourMacsModel(snapshot: nil, localId: "local", settings: .shared, speechSources: servers)
        XCTAssertFalse(model.sources.contains(where: \.available))
    }

    func testCatalogNamesCoverServerAndLocalModelIdentifiers() {
        XCTAssertEqual(YourMacsModel.shortName("gemma4:e2b-it-qat"), "Gemma 4 · E2B")
        XCTAssertEqual(YourMacsModel.shortName("mlx-community/whisper-small-mlx"), "Whisper Small")
        XCTAssertEqual(ModelCatalog.name(of: "whisperkit:openai_whisper-small"), "Whisper Small")
        XCTAssertEqual(ModelCatalog.name(of: "custom:latest"), "custom:latest")
    }

    func testSpeechModelOnAMacIsUsedFirstAndTheServerBacksItUp() {
        var snap = snapshot()
        snap.machines[1].speechModels = ["whisperkit:openai_whisper-small", "apple:he-IL"]
        let sources: [SetupRouting.SpeechSource] = [.mac("mbp", model: "whisperkit:openai_whisper-small"), .server("http://100.64.0.1:7878")]
        let model = YourMacsModel(snapshot: snap, localId: "mbp", settings: .shared, speechSources: sources)
        XCTAssertEqual(model.activeSpeechMachine, "mbp")
        XCTAssertEqual(model.place(for: .speech).text, "MacBook Pro")
        let chips = model.models(on: model.machines[1])
        XCTAssertEqual(chips.first?.model, "Whisper Small")
        XCTAssertEqual(chips.first?.actions, [.stopUsingForSpeech])
        XCTAssertEqual(chips.first(where: { $0.rawModel == "apple:he-IL" })?.actions, [.useForSpeech, .useAsSpeechBackup])
        XCTAssertEqual(model.models(on: model.machines[0]).first?.tag, "backup")
        XCTAssertEqual(model.caption(for: .speech), "First choice: MacBook Pro. Backups are tried in this order: Mac mini.")
    }

    func testOfflineSpeechMacHandsOverToTheNextSource() {
        var snap = snapshot()
        snap.machines[2].speechModels = ["whisperkit:openai_whisper-small"]
        snap.machines[2].online = false
        let sources: [SetupRouting.SpeechSource] = [.mac("studio", model: "whisperkit:openai_whisper-small"), .server("http://100.64.0.1:7878")]
        let model = YourMacsModel(snapshot: snap, localId: "mbp", settings: .shared, speechSources: sources)
        XCTAssertEqual(model.activeSpeechMachine, "mini")
        XCTAssertEqual(model.place(for: .speech).text, "Mac mini, for now")
        XCTAssertEqual(model.problem, BrandVoice.backupStandingIn(down: "Mac Studio", backup: "Mac mini"))
    }

    func testDictationRouteGoesToTheSpeechMacAndBack() {
        let model = YourMacsModel(snapshot: snapshot(), localId: "mbp", settings: .shared, speechSources: servers)
        XCTAssertEqual(model.routes(for: nil).map { "\($0.from)>\($0.to)" }, ["mbp>mini", "mini>mbp"])
        XCTAssertEqual(model.place(for: .speech).text, "Mac mini")
        XCTAssertEqual(model.models(on: model.machines[0]).map(\.id), ["speech-0", "cleanup"])
        XCTAssertEqual(model.models(on: model.machines[1]).first?.tag, "not in use")
        XCTAssertNil(model.problem)
    }

    func testBackupStandsInWhenTheSpeechMacIsOff() {
        let model = YourMacsModel(snapshot: snapshot(speechReachable: false, miniOnline: false, backup: true), localId: "mbp", settings: .shared, speechSources: servers)
        XCTAssertEqual(model.activeSpeechMachine, "studio")
        XCTAssertEqual(model.place(for: .speech).text, "Mac Studio, for now")
        XCTAssertTrue(model.place(for: .cleanup).warning)
        XCTAssertEqual(model.routes(for: .speech).first?.to, "studio")
        XCTAssertTrue(model.routes(for: .save).allSatisfy(\.waiting))
        XCTAssertEqual(model.problem, BrandVoice.backupStandingIn(down: "Mac mini", backup: "Mac Studio"))
    }

    func testCleanupOffIsShownAsOff() {
        AppSettings.shared.refineLevel = .exact
        let model = YourMacsModel(snapshot: snapshot(), localId: "mbp", settings: .shared, speechSources: servers)
        XCTAssertEqual(model.place(for: .cleanup).text, "Off: no AI clean-up")
        XCTAssertNil(model.cleanupMachine)
        XCTAssertEqual(model.models(on: model.machines[0]).last?.tag, "off")
    }

    // MARK: - Models load at key down

    func testSpeechRouteWarmsFirstServerWithTheLevelItWillReceive() {
        let server = SetupRouting.SpeechSource.server("http://mini:7878")
        let cleanup = (machine: "mbp", model: "gemma")
        func route(_ level: RefineLevel, chosen: (machine: EdgeID, model: String)? = nil, source: SetupRouting.SpeechSource? = server) -> DictatorViewModel.SpeechRoute {
            DictatorViewModel.speechRoute(refineLevel: level, firstSource: source, chosenCleanup: chosen, fallbackCleanup: nil)
        }
        XCTAssertEqual(route(.medium).serverURL, "http://mini:7878")
        XCTAssertEqual(route(.medium).serverRefineLevel, .medium)
        XCTAssertEqual(route(.exact).serverRefineLevel, .exact)
        // Clean-up relayed to another Mac: the server is told exact.
        XCTAssertEqual(route(.medium, chosen: cleanup).serverRefineLevel, .exact)
        XCTAssertEqual(route(.medium, chosen: cleanup).cleanup?.machine, "mbp")
        XCTAssertNil(route(.exact, chosen: cleanup).cleanup)
    }

    func testSpeechRouteSkipsServerWhenSpeechRunsInApp() {
        let inApp = SetupRouting.SpeechSource.mac("mbp", model: "whisperkit:x")
        let route = DictatorViewModel.speechRoute(refineLevel: .medium, firstSource: inApp, chosenCleanup: nil, fallbackCleanup: ("mbp", "gemma"))
        XCTAssertNil(route.serverURL)
        XCTAssertEqual(route.cleanup?.model, "gemma")
    }

    func testOllamaKeepsModelsFiveMinutes() {
        XCTAssertEqual(OllamaClient.keepAlive, "5m")
    }
}
