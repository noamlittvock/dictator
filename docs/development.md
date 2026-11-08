# Developing Dictator

## What you need

- macOS 14 or later on Apple silicon, Xcode 16 or later, and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- The Xcode project is generated from `swift-client/project.yml` by xcodegen; the generated project is committed so `xcodebuild` works without it. After adding or removing a source file, run `xcodegen generate` in `swift-client/` and commit the regenerated `project.pbxproj`. Swift packages are pinned in `project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (WhisperKit 1.1.0).
- A code-signing identity. The scripts below use a self-signed identity named "Dictator Local Code Signing" to keep the local permission identity stable (see `scripts/build-sign.sh`). This is sufficient for the ordinary local app, but not for the App Intents connection observed on macOS 27: it has no signing Team ID and `linkd` rejects it. The standard build therefore does not advertise Dictator’s own actions in Apple Shortcuts, Spotlight or Siri.

A local Release build without a certificate (ad hoc signed; install only through the explicit `DICTATOR_ASSET` route):

```bash
cd swift-client && xcodegen generate
xcodebuild -project Dictator.xcodeproj -target Dictator -configuration Release \
  CODE_SIGNING_ALLOWED=NO SYMROOT="$PWD/build" build
codesign --force --deep --sign - --entitlements Dictator/Dictator.entitlements build/Release/Dictator.app
```

## Build, sign and install

```bash
# In a logged-in desktop session:
scripts/build-sign.sh              # build and sign Dictator.app
scripts/install-app.sh <path-to-Dictator.app>   # install and launch
```

- `build-sign.sh` needs the login keychain, which is locked in SSH sessions ("User interaction is not allowed"). Run it in the desktop session; unattended, a one-shot LaunchAgent in `gui/$(id -u)` that runs a small script works.
- `install-app.sh` works on either Mac: it keeps the signing identity stable so macOS permissions (Microphone, Accessibility, Input Monitoring) carry over, and backs up the previous build. Install on the main Mac first, then the others; both sides of a connection must speak the same protocol version.
- `scripts/dev-install.sh` builds, signs and installs in one go.
- macOS permissions can only be granted on each Mac's own screen, never over SSH.

A build without signing (for compiling and tests) works over SSH:

```bash
cd swift-client && xcodegen generate
xcodebuild -project Dictator.xcodeproj -scheme Dictator -destination platform=macOS \
  CODE_SIGNING_ALLOWED=NO build
```

## Public releases: Developer ID and notarization

Public downloads require a **Developer ID Application** certificate and Apple notarization. `install.sh` refuses a download that lacks either. Local development signing and App Intents availability are unchanged. Do not define `DICTATOR_ENABLE_APP_INTENTS` as part of a release; enabling it needs separate native Shortcuts testing.

1. On the Mac that will sign releases, the Apple Developer Program **Account Holder** creates the certificate in **Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application**. The certificate and its private key must be in that Mac’s login keychain. [Apple’s certificate guidance](https://help.apple.com/xcode/mac/current/en.lproj/dev88332a81e.html) limits creation of Developer ID certificates to the Account Holder.
2. Store notary credentials interactively on that same Mac, using your Apple ID, an app-specific password and the actual Team ID when prompted:

   ```sh
   xcrun notarytool store-credentials dictator
   ```

   Keep credentials in the keychain, never in scripts, shell history or the repository. A different profile name can be supplied through `DICTATOR_NOTARY_PROFILE`.
3. In a **logged-in desktop session on the Mac holding the certificate**, with the login keychain unlocked, run:

   ```sh
   scripts/release.sh --skip-notarize  # signing-only check; not for distribution
   scripts/release.sh                  # build, sign, notarize, staple and assess
   ```

   The script selects the single valid Developer ID Application identity in the login keychain. If there is more than one, choose explicitly with `DICTATOR_SIGN_IDENTITY` set to its SHA-1 hash (listed by `security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db`). It fails with setup instructions if the identity or notary profile cannot be used. SSH sessions may not be able to unlock the signing key.

The release command builds arm64 Release with the production bundle ID and display name, using `.dd` for derived data and `.spm` for packages. `DICTATOR_BUILD_DIR` can override the derived-data directory. It enables hardened runtime for this command only, signs nested code inside out with secure timestamps, preserves dependency helper entitlements, and signs Dictator with microphone and Apple Events access. It checks the Developer ID signature, runtime flag, Team ID and signed entitlements before submission. Apple Events access is used by the browser-page probe in `DestinationSnapshot`; the purpose string explains this to the user. No JIT, unsigned-memory or library-validation exceptions are granted.

A successful full run waits for Apple, staples and validates the ticket, checks Gatekeeper, then creates `.dd/releases/Dictator-<built-version>-macOS-arm64.zip` and prints its path and SHA-256. Notary rejections print the submission log. Signing-only mode produces no distribution archive. The script never installs or launches the app and never publishes to GitHub; review and upload are manual. See [Apple’s notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

`EXPECTED_TEAM_ID` in `install.sh` is pinned to `8GUV9GH4CN`, verified from the first Developer ID signed build. Change it only after verifying the actual TeamIdentifier of a deliberately selected signing identity. Review and replace the legacy ad hoc release manually. The final release still needs native testing of microphone capture, browser Automation prompts, terminal commands, local WhisperKit/Core ML recognition, and the update framework on a Mac with the signed build; mocked script tests cannot prove those runtime paths.

Moving from ad hoc or the fixed local certificate to Developer ID changes the app’s signing identity. macOS will ask for **Microphone, Accessibility and Input Monitoring** access again on each Mac’s own screen. The installers report this transition; switching back to local signing can require approval again. Plan this one-time permission reset when deploying the first Developer ID build.

## Tests

| Part | Command | Notes |
|---|---|---|
| Mac app | `xcodebuild … CODE_SIGNING_ALLOWED=NO test` (as above) | Hosted tests skip the app's startup, so they never touch personal history, the microphone or hotkeys. |
| Script contracts | `python3 -m unittest discover -s scripts/tests -v` | Synthetic app metadata, homes and hook configs; mocked signing/build commands, defaults and launchctl. Uninstaller JSON tests use macOS’s bundled JXA. No real home, signing keys or live deployment. |
| Settings screenshots | create `/tmp/dictator-settings-snaps`, then run `SettingsSnapshotTests` | Renders each Settings page and the dictation alerts to PNG files there. Skipped when the folder doesn't exist. |
| Speech server | `server/.venv/bin/python -m pytest server/tests --ignore=server/tests/test_quality_golden.py` | `test_quality_golden.py` needs `jiwer` and the real models. |

Tests use synthetic audio and mocked services only; never personal recordings or live services. `NamingCompatibilityTests` decodes fixed settings and Commands messages with the historical JSON keys and checks encoded keys after internal renames.


## Command files

Commands imports and exports `.json` files with `{ "dictatorCommands": 1, "commands": [...], "lists": [...] }`. Commands and lists use the existing `VoiceCommand` and `VoiceList` fields, except exported commands omit `id`, `hotkey` and `runsFromOtherApps`; `onlyInApps` stays. Import supplies fresh IDs and forces commands off, ignoring supplied launch permissions. Unknown top-level keys are ignored; a higher format or unknown step kind reports “This file needs a newer Dictator.” Files over 1,000,000 bytes or invalid structures are refused without settings changes. No document type is registered.

Export lists referenced by the selected commands. Entries require a separate opt-in per list with details shown first. Paths and addresses, including webhooks and values embedded in text, are shown in full and omitted by default; omission blanks the whole containing value. Review shows phrases, existing step summaries and full action details marked “Check this”, with warnings for mixed scripts and invisible characters. Fill missing values and change clashing phrases before confirmation, as required by the existing shared-settings validator. Lists combine by name, preserving existing entries when any name or alias overlaps. Saving uses the ordinary mirrored settings path. `CommandFileTests` covers the pure transformations, privacy byte exclusions, compatibility, validation limits, hostile strings and atomic merge failures; native panels and connected-Mac delivery need manual checks.

## The speech server

See [server/README.md](../server/README.md). Setting it up, restarting it and downloading its models are deliberate deployment steps.

## Scripts

| Script | What it does |
|---|---|
| `build-sign.sh` | Builds and signs `Dictator.app` (desktop session). |
| `install-app.sh` | Installs a signed app, cleans stale registrations, launches it (`--no-launch` to skip). |
| `dev-install.sh` | `build-sign.sh` then `install-app.sh`, in one step. |
| `server-bootstrap.sh` | Sets up the speech server's Python environment and models on the Mac that runs it. `--dry-run` shows the steps. |
| `install.sh`, `uninstall.sh` (repository root) | Install the released app from GitHub, or remove it with catalog-driven local hook cleanup. Uninstall always removes the shim/spool; data/logs and the optional server require separate default-no choices. `--yes` keeps both. Open-at-login must be disabled in Dictator or reviewed in System Settings. |

## Diagnosing

- `~/Library/Logs/Dictator/hotkey.log`: hotkey, audio, connection (`edge:`/`core:`), sync (`sync:`), speech (`speech:`, `cleanup:`) and alert lines.
- The speech server logs one JSON line per request to `~/Library/Logs/dictation-server.log` on its Mac.

## Keeping development builds out of the live setup

Debug build/test products use the display name **Dictator Dev** and bundle ID `dev.noamlitt.dictator.development`. Outside hosted tests, they exit before history, microphone, hotkeys or startup registration are initialized, unless the developer explicitly supplies `--allow-development-runtime`. To run a development build deliberately, add that argument to the Xcode Run scheme or launch that exact executable with the flag; it has a separate macOS permission identity. Never grant it access just to run unit tests.

The signed build helper overrides the display name to Dictator and the bundle ID to the installed identity. Installation unregisters stale production and development build copies from LaunchServices. Use `/Applications/Dictator.app` or `dev.noamlitt.dictator` for native-app verification, never the ambiguous bare name. Preserve the stable signing identity; an adhoc development permission does not authorize a different adhoc build. If a stray development copy was accidentally launched, quit only that copy and remove/reset only its own permission entry; retain the installed app’s grants.

### Starting a command from other apps

Turn on **Let other apps start this** in the Commands editor and copy its `dictator://run?command=<id>` link. Exact saved names also work when URL-encoded; IDs survive renames. Links cannot supply words, required spoken parts refuse, and acting or Terminal steps ask Allow/Cancel on every run. Busy starts and attempts less than two seconds apart are ignored. The local Pause state also blocks these starts.

`CFBundleURLTypes` registers `dictator` through the normal app bundle. Preserve that plist entry when packaging and sign the bundle normally; no entitlement, helper, listener or App Intents flag is needed. Debug and non-production bundle IDs refuse command triggers even with `--allow-development-runtime`. Native URL delivery, Launch Services selection when multiple builds exist, and the permission dialog still need testing with an installed Release build on each Mac. Unit tests inject configuration, clock, consent, registry and executor; they never open links or execute actions.

## Dictator actions in Apple Shortcuts

The standard self-signed build leaves `DICTATOR_ENABLE_APP_INTENTS` undefined. All three intent types remain available for mocked business-logic tests, but declare `isDiscoverable = false` and the `AppShortcutsProvider` supplies no shortcuts. Settings explains this build’s availability. Running an existing Apple Shortcut from Commands is a separate integration and remains available. Previously saved Shortcuts containing a Dictator action may still fail until their app build meets the system’s validation requirements.

On macOS 27.0, native testing reached the installed production app but `linkd` rejected its mediator connection with “Unable to get teamId” and “requiresValidatedBundle”. This establishes the limitation on that system; it is not a claim about all historical macOS releases. Adding a fabricated Team ID or private entitlement is not a supported repair.

To investigate enabling these actions, first obtain a genuine Apple Development or Developer ID signing identity through [Xcode’s supported team workflow](https://help.apple.com/xcode/mac/current/en.lproj/dev60b6fbbc7.html). A personal team does not itself require a paid membership. Set `DICTATOR_ENABLE_APP_INTENTS` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for that deliberately prepared build, preserve its actual signing entitlements, verify its Team ID and signature, then test the actions end to end in native Shortcuts. The flag enables metadata; it does not prove that a signature or action works.

Changing from the fixed local certificate changes the [designated requirement](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) and can require Microphone, Accessibility and Input Monitoring approval again. Plan that transition before deployment. The current `build-sign.sh` deliberately selects the fixed local certificate and refuses to hand off an enabled App Intents build unless its final signature has a Team ID and validates against Apple’s signing anchor; `install-app.sh` expects its certificate-hash requirement. Neither is a general Apple-team signing/deployment pipeline. Do not re-sign or install with a different identity as a routine rebuild.

## Updates

Sparkle is pinned to 2.10.1 in `swift-client/project.yml`. Obtain the matching Sparkle release tools from its GitHub release. On the release Mac, run `bin/generate_keys --account dictator` once. The private key stays in that Mac’s keychain; back it up securely (the tool’s `-x` option exports it for an encrypted offline backup). Never commit the private key or its export. Keep the same key for future updates.

Set `DICTATOR_SPARKLE_PUBLIC_KEY` in the environment to the printed public key (for this project, `+J7xyuRMkvWE1/xlqH4EObDaaZb3Y6j/1Cbb26cbQ70=`) when running `scripts/release.sh`; a notarized release is refused without it, and `--skip-notarize` allows an empty key for a signing-only check. The script passes it as a build setting, where it expands into `SUPublicEDKey`, and gives each release a rising UTC timestamp as its build number, because Sparkle compares build numbers and would otherwise offer nothing. Leave it empty for all local and development builds: they create no updater, make no update requests and show no update controls. Automatic checks default to on for configured releases; Settings › General changes only this Mac’s Sparkle preference. System profiling and automatic installation are off.

After producing the notarized zip, generate the feed locally:

```bash
SPARKLE_GENERATE_APPCAST=/path/to/Sparkle/bin/generate_appcast \
  scripts/make-appcast.sh /path/to/Dictator.zip v1.2.3 /path/to/output
```

The output directory must exist and contain no `appcast.xml`. The script uses the `dictator` keychain account, reads the minimum macOS version from the zipped app, and verifies the generated feed matches it. The zip must contain one top-level app with a configured public key and an increasing `CFBundleVersion`. It temporarily hard-links the zip beside the original to avoid a second archive copy; Sparkle may cache extracted archives in the release Mac’s user cache. The script assumes its input is already signed and notarized; it does not perform those steps or publish anything.

Upload `appcast.xml` as a release asset alongside the exact zip used to generate it, under the supplied GitHub release tag. Its download URL is pinned to that tag; the app reads the feed at `releases/latest/download/appcast.xml`. Sparkle includes nested XPC services and a relaunch helper: the release signing pipeline must preserve and sign nested code before signing the app. Verify an upgrade with the same Developer ID identity and permissions before shipping.
