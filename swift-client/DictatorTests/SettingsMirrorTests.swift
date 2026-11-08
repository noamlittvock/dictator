import SwiftData
import XCTest
@testable import Dictator

/// Covers `CoreSettingsMirror`'s two directions against a fake
/// `CoreSettingsRepository` — no real `CoreConnection`/socket involved,
/// unlike `CoreServerLoopbackTests`.
/// `AppSettings.shared` is a process-wide singleton over UserDefaults, so
/// every test saves/restores the three properties this mirror touches, same
/// discipline `RepositoriesTests` uses.
@MainActor
final class SettingsMirrorTests: XCTestCase {
    private final class FakeSettingsRepository: CoreSettingsRepository {
        var onChange: (() -> Void)?
        var current: CoreSettingsDTO
        private(set) var setCalls: [CoreSettingsPatch] = []

        /// When set, `get()` suspends on this continuation instead of
        /// returning immediately — lets a test hold a GET open to race a
        /// `stop()` or a local edit against it.
        var pendingGet: CheckedContinuation<CoreSettingsDTO, Never>?
        var blockGets = false

        /// When true, every `set(_:)` throws — for the retry/warning test.
        var failSets = false

        init(_ current: CoreSettingsDTO) {
            self.current = current
        }

        func get() async throws -> CoreSettingsDTO {
            guard blockGets else { return current }
            return await withCheckedContinuation { continuation in
                pendingGet = continuation
            }
        }

        /// Resumes a `get()` currently suspended by `blockGets`, if any.
        func resumePendingGet(with value: CoreSettingsDTO) {
            pendingGet?.resume(returning: value)
            pendingGet = nil
        }

        /// When true, `set(_:)` waits for `resumePendingSet()` — a slow Core.
        var blockSets = false
        var pendingSet: CheckedContinuation<Void, Never>?

        func resumePendingSet() {
            pendingSet?.resume()
            pendingSet = nil
        }

        func set(_ patch: CoreSettingsPatch) async throws {
            setCalls.append(patch)
            if failSets { throw RepositoryError.remote("boom") }
            if blockSets { await withCheckedContinuation { pendingSet = $0 } }
            if let refineLevel = patch.refineLevel { current.refineLevel = refineLevel }
            if let customSystemPrompt = patch.customSystemPrompt { current.customSystemPrompt = customSystemPrompt }
            if let persistHistory = patch.persistHistory { current.persistHistory = persistHistory }
            if let routing = patch.setupRoutingJSON { current.setupRoutingJSON = routing }
            if let value = patch.vocabularyPacksAutomatic { current.vocabularyPacksAutomatic = value }
            if let ids = patch.vocabularyPacksOn { current.vocabularyPacksOn = ids }
            if let ids = patch.vocabularyPacksOff { current.vocabularyPacksOff = ids }
            if let reset = patch.workspaceLaunchJSON { current.workspaceLaunchJSON = reset }
            if let id = patch.micOwnerEdgeID { current.micOwnerEdgeID = id }
        }
    }

    private var savedRefineLevel: RefineLevel = .medium
    private var savedCustomSystemPrompt = ""
    private var savedPersistHistory = false
    private var savedSetupRoutingJSON = ""
    private var savedWorkspaceLaunchJSON = ""
    private var savedVoiceLaunchJSON = ""
    private var savedCoreRole: CoreRole = .standalone
    private var savedMicOwnerEdgeID = ""
    private var savedVocabularyPacksAutomatic = true
    private var savedVocabularyPacksOn: [String] = []
    private var savedVocabularyPacksOff: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        let settings = AppSettings.shared
        savedRefineLevel = settings.refineLevel
        savedCustomSystemPrompt = settings.customSystemPrompt
        savedPersistHistory = settings.persistHistory
        savedSetupRoutingJSON = settings.setupRoutingJSON
        savedWorkspaceLaunchJSON = settings.workspaceLaunchJSON
        savedVoiceLaunchJSON = settings.voiceLaunchJSON
        savedCoreRole = settings.coreRole
        savedMicOwnerEdgeID = settings.micOwnerEdgeID
        savedVocabularyPacksAutomatic = settings.vocabularyPacksAutomatic
        savedVocabularyPacksOn = settings.vocabularyPacksOn
        savedVocabularyPacksOff = settings.vocabularyPacksOff
        settings.refineLevel = .exact
    }

    override func tearDown() async throws {
        let settings = AppSettings.shared
        settings.refineLevel = savedRefineLevel
        settings.customSystemPrompt = savedCustomSystemPrompt
        settings.persistHistory = savedPersistHistory
        settings.setupRoutingJSON = savedSetupRoutingJSON
        settings.workspaceLaunchJSON = savedWorkspaceLaunchJSON
        settings.voiceLaunchJSON = savedVoiceLaunchJSON
        settings.coreRole = savedCoreRole
        settings.micOwnerEdgeID = savedMicOwnerEdgeID
        settings.vocabularyPacksAutomatic = savedVocabularyPacksAutomatic
        settings.vocabularyPacksOn = savedVocabularyPacksOn
        settings.vocabularyPacksOff = savedVocabularyPacksOff
        try await super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition never became true within \(timeout)s")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testCustomToolRemovalMirrorsOnlyItsPolicyEntryWithoutPruningUnknownTools() async throws {
        let settings = AppSettings.shared
        let original = settings.cachedSurfacePolicyJSON
        defer { settings.cachedSurfacePolicyJSON = original }
        settings.updateCachedSurfacePolicy(SurfacePolicy(version: 2, tools: [:]))
        let policy = SurfacePolicy(version: 2, tools: ["custom-qa-removal": ToolSwitch(typed: true, voice: false),
                                                      "unknown-other-mac": ToolSwitch(typed: true)])
        let json = String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
        let fake = FakeSettingsRepository(CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: true,
                                                          surfacePolicyJSON: json))
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }
        mirror.start(settings: fake)
        await waitUntil { settings.cachedSurfacePolicyJSON == json }
        // Persistence is mocked; no live catalog, sockets, connectors or history are touched.
        try CustomToolRemoval.remove(id: "custom-qa-removal", settings: settings, removeFromCatalog: { _ in })
        await waitUntil { fake.setCalls.contains { $0.surfacePolicyJSON != nil } }
        let patch = try XCTUnwrap(fake.setCalls.last(where: { $0.surfacePolicyJSON != nil }))
        let mirrored = try JSONDecoder().decode(SurfacePolicy.self, from: Data(try XCTUnwrap(patch.surfacePolicyJSON).utf8))
        XCTAssertNil(mirrored.tools?["custom-qa-removal"])
        XCTAssertEqual(mirrored.tools?["unknown-other-mac"], ToolSwitch(typed: true))
    }

    // Main-Mac local settings must traverse the real observer, repository hub
    // and CoreHost broadcast path. AppSettings uses its random test-only suite;
    // repositories are in memory, checkpoints disposable, and no socket starts.
    private func assertMainLocalChangeBroadcasts(_ edit: (AppSettings) throws -> Void) async throws {
        let settings = AppSettings.shared
        settings.coreRole = .core
        let container = try ModelContainer(for: Repositories.schema, configurations: [ModelConfiguration(schema: Repositories.schema, isStoredInMemoryOnly: true)])
        let repositories = Repositories.make(container: container)
        let hub = RepositoryHub(current: repositories)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoreSettingsObserver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = CoreHost(coreId: "qa-main", repositories: repositories,
                            transcribe: { _, _ in XCTFail("No transcription expected"); return ("", nil) },
                            recordHistory: { _, _, _, _, _, _ in XCTFail("No recording expected") },
                            checkpointStore: RecordingCheckpointStore(directory: directory))
        let sent = expectation(description: "Settings change broadcast")
        var broadcasts: [CoreMessage] = []
        host.remoteBroadcastOverride = { message in broadcasts.append(message); sent.fulfill() }
        let observer = CoreSettingsChangeObserver(settings: settings, hub: hub) { host.broadcastRepoChanged(.settings) }
        try edit(settings)
        await fulfillment(of: [sent], timeout: 1)
        XCTAssertEqual(hub.settingsVersion, 1)
        XCTAssertEqual(hub.historyVersion, 0)
        XCTAssertEqual(hub.dictionaryVersion, 0)
        XCTAssertEqual(broadcasts, [.repoChanged(.settings)])
        withExtendedLifetime(observer) {}
    }

    func testMainLocalRoutingEditBroadcastsSettingsRevision() async throws {
        try await assertMainLocalChangeBroadcasts { settings in
            settings.setupRoutingJSON = SetupRouting(cleanupMachineId: "qa-mac", cleanupModel: "qa-model", languages: ["es"]).encoded()
        }
    }

    func testMainLocalVoiceWorkflowEditBroadcastsSettingsRevision() async throws {
        try await assertMainLocalChangeBroadcasts { settings in
            settings.voiceLaunchJSON = VoiceLaunchConfig(lists: [VoiceList(name: "QA observer", fields: ["name"])]).encoded()
        }
    }

    func testMainLocalPackEditBroadcastsSettingsRevision() async throws {
        try await assertMainLocalChangeBroadcasts { settings in
            settings.vocabularyPacksAutomatic.toggle()
            settings.vocabularyPacksOn = ["law"]
            settings.vocabularyPacksOff = ["common"]
        }
    }

    func testMainLocalWorkspaceEditBroadcastsSettingsRevision() async throws {
        try await assertMainLocalChangeBroadcasts { settings in
            let config = WorkspaceLaunchConfig(routines: [WorkspaceRoutine(id: "qa-observer", name: "QA observer", enabled: false,
                actions: [WorkspaceAction(id: "qa-center", kind: .centerLastWindow)])])
            settings.workspaceLaunchJSON = try XCTUnwrap(config.encoded())
        }
    }

    func testConnectedAndStandaloneSettingsEditsDoNotEcho() async throws {
        let settings = AppSettings.shared
        let container = try ModelContainer(for: Repositories.schema, configurations: [ModelConfiguration(schema: Repositories.schema, isStoredInMemoryOnly: true)])
        let hub = RepositoryHub(current: Repositories.make(container: container))
        let sent = expectation(description: "No non-main broadcast")
        sent.isInverted = true
        let observer = CoreSettingsChangeObserver(settings: settings, hub: hub) { sent.fulfill() }
        for role in [CoreRole.edge, .standalone] {
            settings.coreRole = role
            settings.setupRoutingJSON = SetupRouting(cleanupMachineId: "qa-\(role.rawValue)").encoded()
            // Also exercise repository revision delivery while this Mac is
            // not the main Mac; it must not turn into an outgoing broadcast.
            hub.notifyExternalChange(.settings)
            await Task.yield()
        }
        await fulfillment(of: [sent], timeout: 0.1)
        XCTAssertEqual(hub.settingsVersion, 2, "Only explicit repository revisions, no local-edit echo")
        withExtendedLifetime(observer) {}
    }

    func testRepositorySettingsOnChangeStillBroadcasts() async throws {
        let settings = AppSettings.shared
        settings.coreRole = .core
        let container = try ModelContainer(for: Repositories.schema, configurations: [ModelConfiguration(schema: Repositories.schema, isStoredInMemoryOnly: true)])
        let repositories = Repositories.make(container: container)
        let hub = RepositoryHub(current: repositories)
        let sent = expectation(description: "Repository callback broadcast")
        var count = 0
        let observer = CoreSettingsChangeObserver(settings: settings, hub: hub) { count += 1; sent.fulfill() }
        // This field already had direct observation; using the repository
        // must keep its onChange subscription and single broadcast path.
        try await repositories.settings.set(CoreSettingsPatch(customSystemPrompt: "QA repository callback"))
        await fulfillment(of: [sent], timeout: 1)
        XCTAssertGreaterThan(hub.settingsVersion, 0)
        XCTAssertEqual(count, 1)
        withExtendedLifetime(observer) {}
    }

    func testRecordingMacMirrorsBothDirectionsAndAutomaticWithoutEcho() async throws {
        let settings = AppSettings.shared
        settings.micOwnerEdgeID = "qa-local"
        let fake = FakeSettingsRepository(CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: true, micOwnerEdgeID: "qa-main-choice"))
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }
        mirror.start(settings: fake)
        await waitUntil { settings.micOwnerEdgeID == "qa-main-choice" }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(fake.setCalls.isEmpty)

        settings.micOwnerEdgeID = "qa-connected-choice"
        await waitUntil { fake.current.micOwnerEdgeID == "qa-connected-choice" }
        XCTAssertEqual(fake.setCalls, [CoreSettingsPatch(micOwnerEdgeID: "qa-connected-choice")])
        settings.micOwnerEdgeID = ""
        await waitUntil { fake.current.micOwnerEdgeID == "" }
        XCTAssertEqual(fake.setCalls.last, CoreSettingsPatch(micOwnerEdgeID: ""))

        fake.current.micOwnerEdgeID = "qa-remote"
        mirror.remoteChanged()
        await waitUntil { settings.micOwnerEdgeID == "qa-remote" }
        fake.current.micOwnerEdgeID = ""
        mirror.remoteChanged()
        await waitUntil { settings.micOwnerEdgeID.isEmpty }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.setCalls.count, 2, "Remote refreshes must not echo")
    }

    func testRecordingMacMissingOrInvalidRemoteValuePreservesLocalChoice() async throws {
        let settings = AppSettings.shared
        settings.micOwnerEdgeID = "qa-local"
        let fake = FakeSettingsRepository(CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: true))
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }
        mirror.start(settings: fake)
        await waitUntil { settings.refineLevel == .medium }
        XCTAssertEqual(settings.micOwnerEdgeID, "qa-local")
        fake.current.micOwnerEdgeID = "invalid\nrecorder"
        fake.current.customSystemPrompt = "refresh complete"
        mirror.remoteChanged()
        await waitUntil { settings.customSystemPrompt == "refresh complete" }
        XCTAssertEqual(settings.micOwnerEdgeID, "qa-local")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(fake.setCalls.isEmpty)
        mirror.stop()
        settings.micOwnerEdgeID = "qa-after-stop"
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(fake.setCalls.isEmpty)
    }

    func testRemoteRecordingMacChangeAppliesToMainBrokerAndBroadcasts() async throws {
        let settings = AppSettings.shared
        settings.coreRole = .core
        settings.micOwnerEdgeID = ""
        let container = try ModelContainer(for: Repositories.schema, configurations: [ModelConfiguration(schema: Repositories.schema, isStoredInMemoryOnly: true)])
        let repositories = Repositories.make(container: container)
        let hub = RepositoryHub(current: repositories)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingMacObserver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = CoreHost(coreId: "qa-main", repositories: repositories,
                            transcribe: { _, _ in XCTFail("No transcription expected"); return ("", nil) },
                            recordHistory: { _, _, _, _, _, _ in XCTFail("No recording expected") },
                            checkpointStore: RecordingCheckpointStore(directory: directory))
        var broadcasts: [CoreMessage] = []
        host.remoteBroadcastOverride = { broadcasts.append($0) }
        let observer = CoreSettingsChangeObserver(settings: settings, hub: hub, applySettings: {
            host.micOwnerPreference = settings.micOwnerEdgeID.isEmpty ? nil : settings.micOwnerEdgeID
        }) { host.broadcastRepoChanged(.settings) }
        let server = RepoServer(repositories: repositories)
        let result = await server.handle(.settingsSet(CoreSettingsPatch(micOwnerEdgeID: "qa-recorder")))
        XCTAssertEqual(result, .ok)
        await waitUntil { host.micOwnerPreference == "qa-recorder" && !broadcasts.isEmpty }
        XCTAssertEqual(broadcasts, [.repoChanged(.settings)])
        let cleared = await server.handle(.settingsSet(CoreSettingsPatch(micOwnerEdgeID: "")))
        XCTAssertEqual(cleared, .ok)
        await waitUntil { host.micOwnerPreference == nil && broadcasts.count == 2 }
        XCTAssertEqual(broadcasts, [.repoChanged(.settings), .repoChanged(.settings)])
        withExtendedLifetime(observer) {}
    }

    func testMainLocalRecordingMacEditBroadcastsSettingsRevision() async throws {
        try await assertMainLocalChangeBroadcasts { $0.micOwnerEdgeID = "qa-main-local" }
    }

    // MARK: - start() adopts the Core's values

    func testStartAdoptsRemoteValues() async {
        let fake = FakeSettingsRepository(
            CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "core prompt", persistHistory: true)
        )
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }

        mirror.start(settings: fake)
        await waitUntil { AppSettings.shared.refineLevel == .medium }

        XCTAssertEqual(AppSettings.shared.refineLevel, .medium)
        XCTAssertEqual(AppSettings.shared.customSystemPrompt, "core prompt")
        XCTAssertEqual(AppSettings.shared.persistHistory, true)
    }

    func testPolishedLevelArrivesFromTheMainMac() async {
        let fake = FakeSettingsRepository(
            CoreSettingsDTO(refineLevel: "strong", customSystemPrompt: "core prompt", persistHistory: true)
        )
        let mirror = CoreSettingsMirror()
        defer {
            mirror.stop()
            AppSettings.shared.refineLevel = .medium
        }

        mirror.start(settings: fake)
        await waitUntil { AppSettings.shared.refineLevel == .polished }

        XCTAssertEqual(AppSettings.shared.refineLevel, .polished)
    }

    func testVocabularyPacksMirrorRoundTripAndExplicitClears() async throws {
        let settings = AppSettings.shared
        settings.vocabularyPacksAutomatic = true
        settings.vocabularyPacksOn = []
        settings.vocabularyPacksOff = []
        let fake = FakeSettingsRepository(CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: false,
            vocabularyPacksAutomatic: false, vocabularyPacksOn: ["medicine"], vocabularyPacksOff: ["common"]))
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }
        mirror.start(settings: fake)
        await waitUntil { settings.vocabularyPacksOn == ["medicine"] }
        XCTAssertFalse(settings.vocabularyPacksAutomatic)
        XCTAssertEqual(settings.vocabularyPacksOff, ["common"])
        XCTAssertTrue(fake.setCalls.isEmpty, "adoption must not echo")

        settings.vocabularyPacksAutomatic = true
        settings.vocabularyPacksOn = []
        settings.vocabularyPacksOff = []
        await waitUntil { fake.current.vocabularyPacksAutomatic == true && fake.current.vocabularyPacksOn == [] && fake.current.vocabularyPacksOff == [] }
        XCTAssertEqual(fake.setCalls.count, 1)
        XCTAssertNil(fake.setCalls.first?.refineLevel)
        XCTAssertEqual(fake.setCalls.first?.vocabularyPacksOn, [])

        fake.current.vocabularyPacksOff = ["software"]
        mirror.remoteChanged()
        await waitUntil { settings.vocabularyPacksOff == ["software"] }
        XCTAssertEqual(fake.setCalls.count, 1)
    }

    func testOlderPeerLeavesPackSettingsAlone() async {
        let settings = AppSettings.shared
        settings.vocabularyPacksAutomatic = false
        settings.vocabularyPacksOn = ["law"]
        settings.vocabularyPacksOff = ["music"]
        let fake = FakeSettingsRepository(CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: false))
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }
        mirror.start(settings: fake)
        await waitUntil { settings.refineLevel == .medium }
        XCTAssertFalse(settings.vocabularyPacksAutomatic)
        XCTAssertEqual(settings.vocabularyPacksOn, ["law"])
        XCTAssertEqual(settings.vocabularyPacksOff, ["music"])
        XCTAssertTrue(fake.setCalls.isEmpty)
    }

    func testPackSettingsRepositoryAndWireValidation() async throws {
        let repository = LocalCoreSettingsRepository()
        let patch = CoreSettingsPatch(vocabularyPacksAutomatic: false, vocabularyPacksOn: ["medicine"], vocabularyPacksOff: ["common"])
        try await repository.set(patch)
        let stored = try await repository.get()
        XCTAssertEqual(stored.vocabularyPacksAutomatic, false)
        XCTAssertEqual(stored.vocabularyPacksOn, ["medicine"])
        XCTAssertEqual(stored.vocabularyPacksOff, ["common"])
        XCTAssertNil(RepoServer.validate(.settingsSet(patch)))
        XCTAssertNotNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(vocabularyPacksOn: ["../bad"]))))
        XCTAssertNotNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(vocabularyPacksOff: ["common", "common"]))))
        do {
            try await repository.set(CoreSettingsPatch(vocabularyPacksAutomatic: true, vocabularyPacksOff: ["INVALID"]))
            XCTFail("invalid selection accepted")
        } catch {}
        XCTAssertFalse(AppSettings.shared.vocabularyPacksAutomatic, "validate before changing any field")
        try await repository.set(CoreSettingsPatch(vocabularyPacksOn: [], vocabularyPacksOff: []))
        let cleared = try await repository.get()
        XCTAssertEqual(cleared.vocabularyPacksOn, [])
        XCTAssertEqual(cleared.vocabularyPacksOff, [])
    }

    func testRetiredWordingFieldIsIgnoredWhenDecodingSettings() throws {
        // Synthesized Decodable reads only CodingKeys; older Macs may still send this key.
        for value in [false, true] {
            let json = "{\"refineLevel\":\"medium\",\"customSystemPrompt\":\"keep this\",\"persistHistory\":true,\"plainEnglish\":\(value)}"
            let data = Data(json.utf8)
            let snapshot = try JSONDecoder().decode(CoreSettingsDTO.self, from: data)
            XCTAssertEqual(snapshot, CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "keep this", persistHistory: true))
            let patch = try JSONDecoder().decode(CoreSettingsPatch.self, from: data)
            XCTAssertEqual(patch, CoreSettingsPatch(refineLevel: "medium", customSystemPrompt: "keep this", persistHistory: true))
            let retiredOnly = try JSONDecoder().decode(CoreSettingsPatch.self, from: Data("{\"plainEnglish\":\(value)}".utf8))
            XCTAssertTrue(retiredOnly.isEmpty)
        }
    }

    func testSettingsWithoutRetiredWordingFieldStillDecode() throws {
        let data = Data(#"{"refineLevel":"medium","customSystemPrompt":"","persistHistory":true}"#.utf8)
        let snapshot = try JSONDecoder().decode(CoreSettingsDTO.self, from: data)
        XCTAssertEqual(snapshot, CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: true))
        XCTAssertTrue(try JSONDecoder().decode(CoreSettingsPatch.self, from: Data("{}".utf8)).isEmpty)

        // Match the older peer's optional field to verify the new encoding remains readable.
        struct OlderSettings: Decodable {
            var refineLevel: String
            var customSystemPrompt: String
            var persistHistory: Bool
            var plainEnglish: Bool?
        }
        for encoded in [try JSONEncoder().encode(snapshot),
                        try JSONEncoder().encode(CoreSettingsPatch(refineLevel: "medium", customSystemPrompt: "", persistHistory: true))] {
            let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNil(keys["plainEnglish"])
            let older = try JSONDecoder().decode(OlderSettings.self, from: encoded)
            XCTAssertEqual(older.refineLevel, "medium")
            XCTAssertEqual(older.customSystemPrompt, "")
            XCTAssertTrue(older.persistHistory)
            XCTAssertNil(older.plainEnglish)
        }
    }

    func testABadPatchChangesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let loaded = PersistenceLoader.load(applicationSupport: root)
        let repositories = Repositories.make(container: try XCTUnwrap(loaded.container))
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = AppSettings.shared.persistHistory
        defer { AppSettings.shared.persistHistory = saved }
        AppSettings.shared.persistHistory = true

        for patch in [CoreSettingsPatch(persistHistory: false, surfacePolicyJSON: "not json"),
                      CoreSettingsPatch(persistHistory: false, setupRoutingJSON: "not json"),
                      CoreSettingsPatch(persistHistory: false, voiceLaunchJSON: "not json")] {
            do {
                try await repositories.settings.set(patch)
                XCTFail("a malformed field must refuse the whole patch")
            } catch {}
            XCTAssertTrue(AppSettings.shared.persistHistory, "the valid field must not have been applied")
        }
    }

    // MARK: - Which Mac does which job

    func testSetupRoutingFollowsTheCoreAndGoesBack() async {
        let core = SetupRouting(cleanupMachineId: "studio", cleanupModel: "gemma3:4b", backupServerURLs: ["http://100.64.0.9:7878"])
        let fake = FakeSettingsRepository(
            CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: true, setupRoutingJSON: core.encoded())
        )
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }
        mirror.start(settings: fake)
        await waitUntil { AppSettings.shared.setupRouting == core }

        AppSettings.shared.updateSetupRouting { $0.cleanupMachineId = nil; $0.cleanupModel = nil }
        await waitUntil { !fake.setCalls.isEmpty }
        let sent = SetupRouting.decode(fake.setCalls.first?.setupRoutingJSON ?? "")
        XCTAssertNil(sent?.cleanupMachineId)
        XCTAssertEqual(sent?.backupServerURLs, ["http://100.64.0.9:7878"])
    }

    func testCoreWithoutWorkspaceSetupTakesThisMacsDefinitions() async throws {
        let local = WorkspaceLaunchConfig(routines: [WorkspaceRoutine(name: "Local", actions: [WorkspaceAction(kind: .centerLastWindow)])])
        let json = try XCTUnwrap(local.encoded())
        AppSettings.shared.workspaceLaunchJSON = json
        let fake = FakeSettingsRepository(CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: false, workspaceLaunchJSON: ""))
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }
        mirror.start(settings: fake)
        await waitUntil { !fake.setCalls.isEmpty }
        XCTAssertEqual(fake.setCalls.first?.workspaceLaunchJSON, json)
        XCTAssertEqual(fake.setCalls.count, 1)
    }

    func testWorkspaceDefinitionsMirrorWithoutEchoAndDeletionIsExplicit() async throws {
        AppSettings.shared.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig.empty.encoded())
        let remote = WorkspaceLaunchConfig(routines: [WorkspaceRoutine(name: "Work", actions: [WorkspaceAction(kind: .centerLastWindow)])])
        let json = try XCTUnwrap(remote.encoded())
        let fake = FakeSettingsRepository(CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: false, workspaceLaunchJSON: json))
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }
        mirror.start(settings: fake)
        await waitUntil { AppSettings.shared.workspaceLaunchJSON == json }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(fake.setCalls.isEmpty)
        AppSettings.shared.updateWorkspaceLaunch { $0.routines = [] }
        await waitUntil { !fake.setCalls.isEmpty }
        XCTAssertEqual(fake.setCalls.count, 1)
        XCTAssertEqual(WorkspaceLaunchConfig.decode(fake.setCalls.first?.workspaceLaunchJSON ?? ""), .empty)
        XCTAssertNil(fake.setCalls.first?.voiceLaunchJSON)
    }

    // MARK: - Local edit → set(patch)

    func testLocalChangeCallsSetWithOnlyTheChangedField() async {
        // setUp starts at .exact, so this wait observes the async baseline
        // before a local edit can race it. Legacy strong becomes medium.
        let fake = FakeSettingsRepository(
            CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: false)
        )
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }

        mirror.start(settings: fake)
        await waitUntil { AppSettings.shared.refineLevel == .medium }

        AppSettings.shared.customSystemPrompt = "edited locally"
        await waitUntil { !fake.setCalls.isEmpty }

        XCTAssertEqual(fake.setCalls.count, 1)
        XCTAssertEqual(fake.setCalls.first?.customSystemPrompt, "edited locally")
        XCTAssertNil(fake.setCalls.first?.refineLevel)
        XCTAssertNil(fake.setCalls.first?.persistHistory)
    }

    // MARK: - Remote change notification → AppSettings updated

    func testRemoteChangeNotificationUpdatesAppSettings() async {
        let fake = FakeSettingsRepository(
            CoreSettingsDTO(refineLevel: "light", customSystemPrompt: "", persistHistory: false)
        )
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }

        mirror.start(settings: fake)
        await waitUntil { AppSettings.shared.refineLevel == .medium }

        fake.current = CoreSettingsDTO(refineLevel: "exact", customSystemPrompt: "changed remotely", persistHistory: true)
        mirror.remoteChanged() // what a `repo.changed(.settings)` frame triggers
        await waitUntil { AppSettings.shared.refineLevel == .exact }

        XCTAssertEqual(AppSettings.shared.customSystemPrompt, "changed remotely")
        XCTAssertEqual(AppSettings.shared.persistHistory, true)
        // The remote-driven write must never be echoed back as a `set`.
        XCTAssertTrue(fake.setCalls.isEmpty)
    }

    // MARK: - stop() ends mirroring

    func testStopEndsMirroringNoMoreCalls() async {
        // The .exact starting level in setUp protects the baseline wait as in
        // `testLocalChangeCallsSetWithOnlyTheChangedField` above.
        let fake = FakeSettingsRepository(
            CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: false)
        )
        let mirror = CoreSettingsMirror()

        mirror.start(settings: fake)
        await waitUntil { AppSettings.shared.refineLevel == .medium }

        mirror.stop()

        AppSettings.shared.customSystemPrompt = "after stop"
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(fake.setCalls.isEmpty, "a local edit after stop() must not reach set(_:)")

        fake.current = CoreSettingsDTO(refineLevel: "exact", customSystemPrompt: "ignored", persistHistory: true)
        mirror.remoteChanged() // the mirror's generation has moved on; this must be ignored
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotEqual(AppSettings.shared.refineLevel, .exact, "a remote change after stop() must not update AppSettings")
    }

    // MARK: - A stale GET response (resolves after stop()) is ignored

    func testStaleGetAfterStopIsIgnored() async {
        let fake = FakeSettingsRepository(
            CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: false)
        )
        fake.blockGets = true
        let mirror = CoreSettingsMirror()

        mirror.start(settings: fake)
        // Give the baseline GET a moment to actually reach `get()` and
        // suspend on the continuation before stopping.
        await waitUntil { fake.pendingGet != nil }

        mirror.stop()
        let refineLevelAtStop = AppSettings.shared.refineLevel

        // The GET finally "arrives" for a Core this mirror is no longer
        // watching — it must be dropped, not applied.
        fake.resumePendingGet(with: CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "stale", persistHistory: true))
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(AppSettings.shared.refineLevel, refineLevelAtStop, "a GET that resolves after stop() must not write into AppSettings")
        XCTAssertNotEqual(AppSettings.shared.customSystemPrompt, "stale")
    }

    // MARK: - An edit racing ahead of the baseline GET is not sent

    func testEarlyLocalEditBeforeBaselineIsNotSent() async {
        let fake = FakeSettingsRepository(
            CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "core value", persistHistory: false)
        )
        fake.blockGets = true
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }

        mirror.start(settings: fake)
        await waitUntil { fake.pendingGet != nil }

        // The baseline GET hasn't landed yet — this edit races ahead of it.
        AppSettings.shared.customSystemPrompt = "raced ahead of baseline"
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(fake.setCalls.isEmpty, "an edit before the baseline GET lands must never be sent")

        // Once the baseline finally lands, it overwrites the racing edit
        // with the Core's actual value, and still never sent a `set`.
        fake.resumePendingGet(with: fake.current)
        await waitUntil { AppSettings.shared.customSystemPrompt == "core value" }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fake.setCalls.isEmpty)
    }

    // MARK: - A failed SET is retried once, then surfaces mirrorWarning

    func testFailedSetIsRetriedOnceThenWarns() async {
        let fake = FakeSettingsRepository(
            CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: false)
        )
        fake.failSets = true
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }

        mirror.start(settings: fake)
        await waitUntil { AppSettings.shared.refineLevel == .medium }
        XCTAssertNil(mirror.mirrorWarning)

        AppSettings.shared.customSystemPrompt = "will fail to sync"
        // First attempt, then a ~1s-later retry — both fail.
        await waitUntil(timeout: 5) { fake.setCalls.count >= 2 }
        XCTAssertEqual(fake.setCalls.count, 2)
        await waitUntil { mirror.mirrorWarning != nil }
        XCTAssertEqual(mirror.mirrorWarning, "Settings sync failed")

        // No further retries beyond the one.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fake.setCalls.count, 2)
    }

    // The retry must carry what the user wants now, not what they wanted a second ago.

    func testRetryNeverRestoresAValueTheUserHasSinceChanged() async {
        let saved = AppSettings.shared.persistHistory
        defer { AppSettings.shared.persistHistory = saved }
        AppSettings.shared.persistHistory = false
        let fake = FakeSettingsRepository(
            CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: false)
        )
        fake.failSets = true
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }
        mirror.start(settings: fake)
        await waitUntil { fake.current.refineLevel == AppSettings.shared.refineLevel.rawValue }
        try? await Task.sleep(nanoseconds: 50_000_000)

        AppSettings.shared.persistHistory = true
        await waitUntil { fake.setCalls.count == 1 }
        // The first send has failed and its retry is waiting: the user turns it back off.
        fake.failSets = false
        AppSettings.shared.persistHistory = false
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(fake.current.persistHistory, false, "history saving must stay off")
        XCTAssertEqual(AppSettings.shared.persistHistory, false)
        XCTAssertEqual(fake.setCalls.count, 1, "nothing differs any more, so nothing is sent")
    }

    func testEditDuringASlowSendIsSentAfterIt() async {
        let saved = AppSettings.shared.persistHistory
        defer { AppSettings.shared.persistHistory = saved }
        AppSettings.shared.persistHistory = false
        let fake = FakeSettingsRepository(
            CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: false)
        )
        let mirror = CoreSettingsMirror()
        defer { mirror.stop() }
        mirror.start(settings: fake)
        await waitUntil { fake.current.refineLevel == AppSettings.shared.refineLevel.rawValue }
        try? await Task.sleep(nanoseconds: 50_000_000)

        fake.blockSets = true
        AppSettings.shared.persistHistory = true
        await waitUntil { fake.pendingSet != nil }
        AppSettings.shared.persistHistory = false
        try? await Task.sleep(nanoseconds: 50_000_000)
        fake.blockSets = false
        fake.resumePendingSet()

        await waitUntil { fake.setCalls.count == 2 }
        XCTAssertEqual(fake.current.persistHistory, false)
        XCTAssertEqual(AppSettings.shared.persistHistory, false)
    }
}

final class SurfacePolicyGateTests: XCTestCase {
    func testDefaultTypedSaveEnablesTypedCapture() {
        let policy = SurfacePolicy(defaultTyped: "save", defaultVoice: "ignore")

        XCTAssertTrue(policy.allowsAnyTypedSave)
    }

    func testTypedOrBothSaveRuleEnablesTypedCapture() {
        let policy = SurfacePolicy(
            defaultTyped: "ignore",
            rules: [
                SurfaceRule(kind: "domain", pattern: "example.com", action: "save", modality: "typed"),
            ]
        )

        XCTAssertTrue(policy.allowsAnyTypedSave)
    }

    func testVoiceOnlySaveDoesNotEnableTypedCapture() {
        let policy = SurfacePolicy(
            defaultTyped: "ignore",
            rules: [
                SurfaceRule(kind: "any", pattern: "*", action: "save", modality: "voice"),
            ]
        )

        XCTAssertFalse(policy.allowsAnyTypedSave)
    }
}
