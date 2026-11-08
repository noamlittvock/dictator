# Architecture

Every Mac runs the same SwiftUI app and owns its own store. A main Mac coordinates sessions and replication; connected Macs record, insert text and run models when asked. The main Mac also has a local client, so one Mac uses the same session path.

## Follow a dictation

1. `HotkeyService` reports the key press to `SessionBroker`.
2. The broker selects the recording Mac and insertion target.
3. `AudioCaptureService` records 16 kHz mono PCM and keeps a recovery checkpoint.
4. The main Mac tries configured speech sources: in-app WhisperKit, Apple speech, or the optional Python server.
5. Ollama cleans up the transcript unless the user skips it. Swift and Python use the same prompt and guards.
6. `PasteService` inserts text and restores the clipboard. Failures keep text or audio for recovery.
7. History is saved when policy allows and replicated between local stores.

[Routing, timeouts, clean-up guards and fallback behavior →](architecture-dictation.md)

## Find the relevant part

| Changing | Reference |
|---|---|
| Pairing, protocol, model inventory, settings or history sync | [Mac connections and sync](architecture-sync.md) |
| Audio, recognition, cleanup or insertion | [Dictation](architecture-dictation.md) |
| Commands, typed history or dataset preparation | [Commands, capture and Datasets](architecture-capture.md) |
| Window planning, tab sets, groups or fleet Undo | [Workspaces](architecture-workspaces.md) |
| Startup, recovery, updates, appearance or uninstall | [App lifecycle](architecture-lifecycle.md) |
| Command file format, URL triggers or Apple Shortcuts | [Integrations](integrations.md) |

## Boundaries

- Stores stay local. Share history through `HistorySyncEngine` and settings through `CoreSettingsMirror`.
- Main-Mac traffic uses protocol v2 on Tailscale port 7880. Speech-server traffic uses port 7878 with a separate key. Ollama stays local.
- New wire fields are optional and unknown message types are ignored. Stored names remain compatible.
- Typed history and dataset delivery need the user's choice. Tests use synthetic data and mocked services.

[AGENTS.md](../AGENTS.md) holds the change rules.

## Names

| Product name | Code name |
|---|---|
| Workspaces | `WorkspaceLaunch*`, `workspaceLaunch` |
| Datasets | `Dataset*`, `.datasets`, `Views/Datasets`, `Services/Datasets` |
| Commands | `VoiceCommand`, `VoiceCommandCatalog`, `VoiceCommandEditor` |
| Main Mac | Core |
| Connected to a main Mac | Edge |

Stored keys, wire fields and paths retain their historical names: `workspaceResetJSON`, `shortcuts`, `shortcutMode`, `shortcutId`, `shortcutName`, `shortcut.mode`, `insert.shortcut`, and the `Usage` archive folder. Explicit coding keys preserve these names; Sidebar raw values remain unchanged. Apple Shortcuts bridge and App Intents identities keep their Shortcuts names. Dictionary usage counters are unrelated to Datasets. SwiftData model and attribute names are unchanged.

Commands = Voice launch in code; Workspaces = Workspace launch in code. Product copy uses Commands and Workspaces; stored names stay unchanged. Legacy App Intent titles and Siri phrases remain unchanged pending native checks with saved Apple Shortcuts.

## Where things live on disk

| What | Where |
|---|---|
| History, dictionary | `~/Library/Application Support/Dictator/Dictator.store` |
| Pairing token (connected Mac) | `~/Library/Application Support/Dictator/pairing/` (0600 files, not the Keychain) |
| Main Mac's pairing token | `~/Library/Application Support/Dictator/core-pairing.token` |
| Local server-owned speech key (app reads only, 0600) | `~/Library/Application Support/Dictator/speech-server.token` (or `DICTATION_TOKEN_FILE`) |
| Pasted remote speech key (local only, 0600) | `~/Library/Application Support/Dictator/speech-server-remote.token` |
| Speech models | `~/Library/Application Support/Dictator/SpeechModels/` |
| Recordings kept after a failure | `~/Library/Application Support/Dictator/Recovery/` |
| Log | `~/Library/Logs/Dictator/hotkey.log` |
| Settings | `UserDefaults`, domain `dev.noamlitt.dictator` |
