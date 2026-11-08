import XCTest
@testable import Dictator

@MainActor
final class WorkspaceLaunchSettingsTests: XCTestCase {
    func testWireCompatibilityAndEmptyPatch() throws {
        let old = Data(#"{"refineLevel":"medium","customSystemPrompt":"","persistHistory":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CoreSettingsDTO.self, from: old).workspaceLaunchJSON)
        XCTAssertTrue(CoreSettingsPatch().isEmpty)
        let patch = CoreSettingsPatch(workspaceLaunchJSON: try XCTUnwrap(WorkspaceLaunchConfig.empty.encoded()))
        XCTAssertFalse(patch.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(CoreSettingsPatch.self, from: JSONEncoder().encode(patch)), patch)
    }

    func testServerRejectsInvalidOrOversizedDefinitions() throws {
        let valid = try XCTUnwrap(WorkspaceLaunchConfig.empty.encoded())
        XCTAssertNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(workspaceLaunchJSON: valid))))
        for invalid in ["", "not json", #"{"version":2,"routines":[]}"#,
                        String(repeating: "x", count: RepoRequestLimits.maxWorkspaceLaunchJSONBytes + 1)] {
            XCTAssertNotNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(workspaceLaunchJSON: invalid))))
        }
        let key = WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.option | WorkspaceHotkey.control)
        let actions = [WorkspaceAction(kind: .centerLastWindow)]
        let duplicate = WorkspaceLaunchConfig(routines: [WorkspaceRoutine(name: "One", hotkey: key, actions: actions),
            WorkspaceRoutine(name: "Two", hotkey: key, actions: [WorkspaceAction(kind: .centerLastWindow)])])
        XCTAssertFalse(duplicate.validate().isEmpty)
        XCTAssertFalse(WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.shift).isValid)
        XCTAssertTrue(WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.control | WorkspaceHotkey.option).isValid)
        XCTAssertFalse(WorkspaceHotkey(keyCode: 53, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.option).isValid)
        XCTAssertFalse(WorkspaceHotkey(keyCode: 53, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.option | WorkspaceHotkey.shift).isValid)
        XCTAssertFalse(WorkspaceHotkey(keyCode: 61, modifiers: WorkspaceHotkey.command).isValid)
        XCTAssertFalse(WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.command | 1).isValid)
    }

    func testMalformedSavedDefinitionsAreNeverSilentlyOverwritten() {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        settings.workspaceLaunchJSON = "malformed-saved-routines"
        XCTAssertFalse(settings.updateWorkspaceLaunch { $0.routines = [] })
        XCTAssertEqual(settings.workspaceLaunchJSON, "malformed-saved-routines")
        XCTAssertFalse(WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.control).isValid)
        XCTAssertFalse(WorkspaceHotkey(keyCode: 15, modifiers: WorkspaceHotkey.option).isValid)
        XCTAssertFalse(WorkspaceHotkey(keyCode: 12, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.shift).isValid)
    }

    func testInvalidLocalPatchDoesNotMutateExistingFields() async throws {
        let settings = AppSettings.shared
        let saved = settings.customSystemPrompt
        let savedReset = settings.workspaceLaunchJSON
        defer { settings.customSystemPrompt = saved; settings.workspaceLaunchJSON = savedReset }
        let repo = LocalCoreSettingsRepository()
        do {
            try await repo.set(CoreSettingsPatch(customSystemPrompt: "must not apply", workspaceLaunchJSON: "broken"))
            XCTFail("Invalid definitions should be rejected")
        } catch {}
        XCTAssertEqual(settings.customSystemPrompt, saved)
        XCTAssertEqual(settings.workspaceLaunchJSON, savedReset)
    }
}

extension WorkspaceLaunchSettingsTests {
    func testRoutineEditsUpdateSharedVoiceSettingsAndPreserveCustomWork() throws {
        let settings = AppSettings.shared
        let savedVoice = settings.voiceLaunchJSON
        let savedWorkspaces = settings.workspaceLaunchJSON
        defer { settings.voiceLaunchJSON = savedVoice; settings.workspaceLaunchJSON = savedWorkspaces }
        settings.voiceLaunchJSON = VoiceLaunchConfig.empty.encoded()
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig.empty.encoded())
        var routine = WorkspaceRoutine(id: "stable", name: "Writing", actions: [.init(kind: .centerLastWindow)])
        XCTAssertTrue(settings.updateWorkspaceLaunch { $0.routines = [routine] })
        settings.updateVoiceLaunch {
            XCTAssertNil(VoiceWorkspaceLink.add(workspaceId: routine.id, name: routine.name, phrase: "Start writing", id: "voice", to: &$0))
            var custom = VoiceWorkspaceLink.draft(workspaceId: routine.id, name: "My custom name", phrase: "Other words", id: "custom")
            custom.steps.append(.init(kind: .typeText, text: "Keep this"))
            $0.commands.append(custom)
        }
        routine.name = "Drafting"
        XCTAssertTrue(settings.updateWorkspaceLaunch { $0.routines = [routine] })
        XCTAssertEqual(settings.voiceLaunch.commands.map(\.name), ["Drafting", "My custom name"])
        XCTAssertEqual(settings.voiceLaunch.commands[0].pattern, "Start writing")
        routine.enabled = false
        XCTAssertTrue(settings.updateWorkspaceLaunch { $0.routines = [routine] })
        XCTAssertTrue(settings.voiceLaunch.commands[0].enabled, "Routine off is independent of its voice shortcut")
        XCTAssertTrue(settings.updateWorkspaceLaunch { $0.routines.removeAll() })
        XCTAssertEqual(settings.voiceLaunch.commands.map(\.id), ["custom"])
        XCTAssertEqual(settings.voiceLaunch.commands[0].steps.map(\.kind), [.typeText])
    }

    func testLinkedVoiceConfigUsesExistingSettingsWireAndRepository() async throws {
        let settings = AppSettings.shared
        let saved = settings.voiceLaunchJSON
        defer { settings.voiceLaunchJSON = saved }
        var voice = VoiceLaunchConfig.empty
        XCTAssertNil(VoiceWorkspaceLink.add(workspaceId: "routine-on-another-mac", name: "Writing", phrase: "Start writing", to: &voice))
        let patch = CoreSettingsPatch(voiceLaunchJSON: voice.encoded())
        XCTAssertNil(RepoServer.validate(.settingsSet(patch)))
        let roundTrip = try JSONDecoder().decode(CoreSettingsPatch.self, from: JSONEncoder().encode(patch))
        try await LocalCoreSettingsRepository().set(roundTrip)
        XCTAssertEqual(VoiceWorkspaceLink.find("routine-on-another-mac", in: settings.voiceLaunch)?.steps[0].workspaceId, "routine-on-another-mac")
        // A later settings delivery preserves the same optional nested ID.
        let dto = CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: true, voiceLaunchJSON: settings.voiceLaunchJSON)
        let received = try JSONDecoder().decode(CoreSettingsDTO.self, from: JSONEncoder().encode(dto))
        XCTAssertEqual(VoiceLaunchConfig.decode(try XCTUnwrap(received.voiceLaunchJSON)), voice)
    }
}
