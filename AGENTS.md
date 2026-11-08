# Rules for changing Dictator

For people and coding agents. Read [README.md](README.md) for what Dictator is, and [docs/architecture.md](docs/architecture.md) before changing anything it describes. [docs/development.md](docs/development.md) covers building, installing and testing.

## Where work happens

- After adding or removing a source file, regenerate the Xcode project with xcodegen and commit `swift-client/Dictator.xcodeproj/project.pbxproj` with it.
- Keep the repository to current source, tests, test inputs and the docs in `docs/`, including the owner's north star in `docs/vision.md`. The README roadmap and conventional project files (`CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, and issue templates, the pull request template and CI workflows in `.github/`) belong here too. Plans, handoffs, audits, experiments and generated output go outside it.

## Things that need the user's go-ahead

Installing the app, setting up or restarting the speech server, downloading models, running installers, and anything that uses a microphone or a live service are deliberate deployment steps: do them when asked, not as routine work. Manage the speech server only with `launchctl bootout` and `launchctl bootstrap`, never a second copy by hand. macOS permissions can only be granted on each Mac's own screen.

## Tests

Tests use synthetic audio and mocked services only. Never personal recordings, personal history or live services.

## Rules the design depends on

- **Each Mac reads and writes only its own store.** Sharing happens by replication (`HistorySyncEngine`) and by mirrored settings (`CoreSettingsMirror`). A new shared setting goes through the mirror: add it to `CoreSettingsDTO`/`CoreSettingsPatch` as an optional field, validate it in `RepoServer`, and handle it in `LocalCoreSettingsRepository`.
- **Protocol changes stay compatible.** New fields in `EdgeProtocol.swift` are optional, and new message types are ignored by older peers. Bump `EdgeProtocol.version` only for a real break; both sides must then run the same build.
- **Nothing listens beyond Tailscale.** The main Mac and the speech server bind only to the Tailscale address, and join requests come only from Tailscale's range. Ollama is never exposed for dictation; other Macs reach it through Dictator's own connection. Never add a listener on a remote server.
- **Remote servers are reached only through the user's SSH**: `ssh -T -o BatchMode=yes … host 'sh -s'` with the script on stdin, validated hosts (`SSHRunner.isValidHost`), single-quoted paths. Capture hooks print nothing (except a reply a tool requires) and always exit 0.
- **Clean-up is identical everywhere.** `CleanupPrompt.swift` is a verbatim port of the prompt and checks in `server/inference.py`. Change both together, and keep `CleanupPromptTests` and `server/tests/test_polish_guard.py` in step. Both read the Polished cases from `shared/polish-guard-fixtures.json`.
- **Typed history is off until the user turns it on**, and holds no keystrokes while no typed place is on. The one decision point is `AppSettings.captureDecision(for:modality:)`. Offer it as an optional add-on to dictation, not as "AI tools".
- **Datasets prepares data; users choose the analysis.** Filters, cleaning, previews and exports use actual saved history only. Never infer findings, run automatic audits or choose an analysis provider. CLI delivery is an explicit user action; preparation never changes stored history.
- **Data, not code.** Tools and apps go in `shared/tool-catalog.json`, AI models offered in the app in `shared/model-catalog.json`.
- **Product names stay plain.** Use Commands and Workspaces for the app surfaces. A saved layout is a routine. Shortcut means an Apple Shortcut or a keyboard shortcut; internal identifiers and stored names stay unchanged.
- **Settings copy is for non-technical users.** With or without the voice, each label says what the setting does, with at most one short line under it. No ports, tokens or role names outside Settings › Advanced. The roles are "main Mac" and "connected to a main Mac", never Core or Edge. AI models are "AI models", never "brains".
- **Failures are explained.** A dictation that doesn't produce text shows a `DictationAlert` on the Mac the user dictated on, with what to do in plain words, and the recording is kept for recovery.
- **Views use the design system.** Type roles, spacing, radii and colours come from `DictatorDesignSystem.swift`, and pages, tabs, sheets, buttons, empty states and panels come from `Views/DSComponents.swift`. Anton is for page titles and the brand lockup; everything you work with is SF. Every sheet is a `DSSheet` with actions at the bottom right. Don't add a one-off style: add the missing role to the foundation. `scripts/tests/test_design_tokens.py` enforces this.
- **Help says what the app does.** The Help page and the "?" briefs live in `HelpLibrary.swift`. When a feature, label or default changes, change its Help text in the same commit. Help shows first: add a picture in `HelpScenes.swift` before adding words, keep the words short, and leave the voice out.
- **The voice stays useful.** The app has one wording, with its lines in `BrandVoice.swift`. Each line says what is happening, what happened or what to do next, in direct, fast, confident and dry language. The person using the Mac has the power. The voice goes in titles, statuses and empty states, with plain instructions underneath. Keep it out of privacy, permissions, typed history, delete confirmations, Datasets, Advanced and People, and out of navigation names, because messages point to them. Keep it short and plain. A joke alone does not explain a result.
