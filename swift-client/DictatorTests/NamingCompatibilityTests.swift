import XCTest
@testable import Dictator

final class NamingCompatibilityTests: XCTestCase {
    func testStoredSettingsAndVoiceCommandMessagesKeepLegacyKeys() throws {
        // Fixed pre-rename keys: do not generate these fixtures with today's encoder.
        let settings = Data(#"""
        {"refineLevel":"medium","customSystemPrompt":"","persistHistory":true,
         "voiceLaunchJSON":"{\"version\":2,\"lists\":[],\"shortcuts\":[{\"id\":\"command\",\"name\":\"Writing\",\"pattern\":\"Start writing\",\"enabled\":true,\"steps\":[{\"id\":\"voice-step\",\"kind\":\"runWorkspace\",\"workspaceId\":\"routine\"}]}]}",
         "workspaceResetJSON":"{\"version\":1,\"routines\":[{\"id\":\"routine\",\"name\":\"Writing\",\"enabled\":true,\"actions\":[{\"id\":\"workspace-step\",\"kind\":\"centerLastWindow\",\"bundleIDs\":[],\"display\":\"main\",\"layout\":\"quarters\",\"idleMinutes\":180}]}]}"}
        """#.utf8)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let dto = try decoder.decode(CoreSettingsDTO.self, from: settings)
        let patch = try decoder.decode(CoreSettingsPatch.self, from: settings)
        let voice = try XCTUnwrap(VoiceLaunchConfig.decode(try XCTUnwrap(dto.voiceLaunchJSON)))
        let workspace = try XCTUnwrap(WorkspaceLaunchConfig.decode(try XCTUnwrap(dto.workspaceLaunchJSON)))
        XCTAssertEqual(voice.commands.first?.steps.first?.workspaceId, workspace.routines.first?.id)
        XCTAssertEqual(voice.commands.first?.id, "command")
        XCTAssertEqual(workspace.routines.first?.name, "Writing")
        XCTAssertEqual(patch.workspaceLaunchJSON, dto.workspaceLaunchJSON)
        for encoded in [try encoder.encode(dto), try encoder.encode(patch)] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["workspaceResetJSON"] as? String, dto.workspaceLaunchJSON)
            XCTAssertNil(object["workspaceLaunchJSON"])
        }
        let voiceObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(voice)) as? [String: Any])
        XCTAssertNotNil(voiceObject["shortcuts"])
        XCTAssertNil(voiceObject["commands"])

        let state = Data(#"{"sessionId":"session","state":"recording","initiator":"mini","shortcutMode":true}"#.utf8)
        let update = try decoder.decode(SessionStateUpdate.self, from: state)
        XCTAssertEqual(update.voiceCommandMode, true)
        let stateObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(update)) as? [String: Any])
        XCTAssertEqual(stateObject["shortcutMode"] as? Bool, true)
        XCTAssertNil(stateObject["voiceCommandMode"])
        XCTAssertEqual(try EdgeProtocolCodec.decodeEdgeMessage(Data(#"{"v":2,"t":"shortcut.mode","id":"message"}"#.utf8)), .voiceCommandMode())

        let delivery = Data(#"{"v":2,"t":"insert.shortcut","id":"message","sessionId":"session","delivery":{"text":"Start writing"}}"#.utf8)
        XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(delivery), .voiceCommandInsert(sessionId: "session", delivery: VoiceCommandDelivery(text: "Start writing")))
        let plan = Data(#"{"shortcutId":"command","shortcutName":"Writing","slots":[],"steps":[],"mainText":"Start writing"}"#.utf8)
        let decodedPlan = try decoder.decode(VoiceLaunchPlan.self, from: plan)
        let planObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(decodedPlan)) as? [String: Any])
        XCTAssertEqual(decodedPlan.commandId, "command")
        XCTAssertEqual(planObject["shortcutName"] as? String, "Writing")
        XCTAssertNil(planObject["commandName"])
        XCTAssertEqual(SidebarItem.datasets.rawValue, "Usage")
        XCTAssertEqual(SidebarItem.workspaceLaunch.rawValue, "Workspace launch")
    }

    /// Fields added for commands that run without speaking. A command saved
    /// by an older build must load unchanged, and defaults must stay out of
    /// the stored JSON so that the setting does not change on its own.
    func testCommandFieldsAddedLaterAreOptionalAndOmittedByDefault() throws {
        let stored = #"{"id":"c1","name":"Notes","pattern":"notes","steps":[],"enabled":true}"#
        let command = try JSONDecoder().decode(VoiceCommand.self, from: Data(stored.utf8))
        XCTAssertNil(command.hotkey)
        XCTAssertFalse(command.runsFromOtherApps)
        XCTAssertEqual(command.onlyInApps, [])
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(command), encoding: .utf8))
        for key in ["hotkey", "runsFromOtherApps", "onlyInApps"] { XCTAssertFalse(encoded.contains(key), key) }

        var changed = command
        changed.hotkey = WorkspaceHotkey(keyCode: 0, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.option)
        changed.runsFromOtherApps = true
        changed.onlyInApps = ["com.example.app"]
        let decoded = try JSONDecoder().decode(VoiceCommand.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(decoded, changed)

        let step = VoiceStep(kind: .runInTerminal, folder: "/tmp", command: "true", background: true)
        XCTAssertEqual(try JSONDecoder().decode(VoiceStep.self, from: JSONEncoder().encode(step)).background, true)
    }
}
