# App lifecycle

[Architecture overview](architecture.md) · [Development](development.md)

## First use and saved recordings

The welcome screen offers local speech setup through the existing Add an AI model flow, with a memory-based recommendation and explicit download action. Typed history is an unchecked optional next step. Readiness requires this Mac’s recording permissions and either an installed model on an online Mac or a reachable speech server from the configured source list; a configured address alone is not evidence of readiness.

Home shows the count of recoverable recordings, a retry action for the newest, and a link to review all of them in History & Privacy. Each recording shows its removal date from the same 14-day retention constant used by startup pruning. The 512 MiB aggregate limit can remove older recordings sooner. Recovery keeps using the existing local store, history save and clipboard path; it never pastes into the formerly focused app.

## Startup and recovery

Settings › General configures this Mac’s login registration through SMAppService.mainApp and whether opening Dictator shows its window or leaves it in the menu bar. Registration status is read from macOS, including approval needed and unavailable states; errors never optimistically enable the switch. Turning it off leaves the current app running but requires opening it manually after the next login. Startup starts only after that user logs in; it cannot wake, unlock or boot another Mac. No setting silently registers another Mac.

Your Macs › After login lists each Mac’s actual startup report and explains how to configure it on that Mac. StartupReport is optional in EdgeCapabilities and SetupSnapshot.Machine, preserving compatibility with older peers. The normal capability refresh propagates changes. Offline reports are never presented as current. Startup settings remain per install and are deliberately outside CoreSettingsMirror; they are OS permissions, not shared dictation policy. Connections already wait/retry for network availability and main Mac recovery, and local fallback preserves recordings while shared history waits for reconnect.

An explicit --enable-login launch argument enables this installed app’s own registration for setup tooling; ordinary launches never change the user’s choice. It respects macOS approval and logs the resulting status. Hosted tests bypass startup initialization and use injected login operations, never real registration.

A saved recording holds every input channel summed, because the microphone's channel isn't known until the take ends. A retry levels it as live dictation is levelled (`AudioCaptureService.levelled`) before any speech source hears it.

A retry on a connected Mac uses its speech sources in their configured order, then its main Mac if those fail, so it needs no speech server key while connected. `RecoverySpeechPlan.steps` adds that last step whatever the sources are.

Quitting waits for a dictation to finish, for up to three minutes (`QuitGuard`). A main Mac's broker holds every Mac's session, so this covers a dictation on another Mac. It doesn't wait for a logout or shutdown. The installers quit Dictator with SIGTERM, which reaches the same check without Automation permission, and force it only after that wait.

## Updates

`Services/UpdateService.swift` wraps Sparkle’s `SPUStandardUpdaterController`. App startup initializes it only after the hosted-test and development-runtime guards. An empty or unexpanded `SUPublicEDKey` creates no updater, sends no update request and hides both the menu item and General toggle. Configured releases read the GitHub `appcast.xml` release asset and verify update archives with that public key. System profiling is disabled. Automatic checking defaults to on; Sparkle stores the choice in this Mac’s defaults, outside `CoreSettingsMirror`.

Update-path source files:

| File | Responsibility |
|---|---|
| `swift-client/Dictator/Services/UpdateService.swift` | Key gate, updater lifecycle and per-Mac automatic-check preference. |
| `swift-client/DictatorTests/UpdateServiceTests.swift` | No-network updater and UI-gate tests with an injected driver. |
| `scripts/make-appcast.sh` | Local feed generation with Sparkle’s keychain signing tool and minimum macOS verification. |
| `scripts/tests/test_make_appcast.py` | Synthetic archives and mocked generation-tool contracts. |

## App appearance

`DictatorDesignSystem.swift` holds the colour tokens, spacing and radius scales and text roles. `Views/DSComponents.swift` holds the shared frames: pages, tabs, buttons, sheets, empty states, step badges and floating panels. `MainWindowView` sets `.dsSecondary` as the default button style, and `DSSheet` does the same, so a bare `Button` is correct. Anton is for page titles and the brand lockup, and SF is for everything you work with. Settings is a page of the main window with tabs, and ⌘, opens it there. `scripts/tests/test_design_tokens.py` fails on raw fonts, sizes, radii and colours in views. The main window follows the Mac's appearance. `Views/BrandViews.swift` supplies the Home header, welcome artwork and process-local Anton/Jost registration. Home keeps the paginated history feed and recovery notices below its compact header. `Models/HelpLibrary.swift` holds the words of the Help page (`Views/HelpView.swift`) and the "?" brief beside each page title, as data so they can be searched and tested, and `Views/HelpScenes.swift` draws the small animated pictures they show; `AppNavigation.openHelp(topic:)` opens a topic.

Bundled fonts in `Resources/Brand` are Google Fonts' desktop Anton and Jost files under the included SIL Open Font License. `BrandDictate` and `BrandRays` in the asset catalog are lossless PNG exports of the product site's `emblem-1-ink` and `emblem-1-rays` artwork, preserving the capped microphone and distressed rays. Artwork is decorative, does not signal recording or readiness, and is never fetched over the network at runtime.

## Removal on one Mac

`uninstall.sh` reads `hook_config` from the installed bundle's tool catalog before deleting the app. It removes only command/bash handlers containing `dictator-capture`, keeping other settings and hooks with a unique `.dictator-uninstall-backup` beside each changed file. OpenCode's dedicated plugin must match the bundled template; an edited plugin or malformed JSON is left for manual inspection. Copilot's hook JSON is filtered like other hook lists. Codex's shared `[features] hooks` switch is left alone because other hooks may need it. The local `~/.dictator` shim and spool are always removed, even if config cleanup fails.

Data deletion is a separate, default-no choice: it removes the complete `~/Library/Application Support/Dictator` tree (including `Usage` datasets, speech-server `Takes`, `Recovery`, `StoreRecovery`, speech models, the default server-owned `speech-server.token` and pasted `speech-server-remote.token`), app preferences and `~/Library/Logs/Dictator`. An overridden token or archive path is outside that tree and must be handled separately. Removing the optional speech server is another default-no choice, offered only when its LaunchAgent plist exists; it uses `launchctl bootout` and removes the plist, keeping external model caches. `--yes` and noninteractive input keep both data and the server. Open-at-login uses `SMAppService.mainApp`; the script directs users to disable it in the app or review Login Items. Remote SSH hooks, exported dataset copies and macOS permissions require separate removal.
