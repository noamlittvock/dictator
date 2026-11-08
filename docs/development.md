# Development

Use an Apple silicon Mac with macOS 14+, Xcode 26+ (for Apple speech APIs), and [xcodegen](https://github.com/yonaskolb/XcodeGen). Read [AGENTS.md](../AGENTS.md) before changing code.

## Build

From the repository root:

```sh
cd swift-client
xcodegen generate
xcodebuild -project Dictator.xcodeproj -scheme Dictator -destination platform=macOS \
  -derivedDataPath ../.dd -clonedSourcePackagesDirPath ../.spm \
  CODE_SIGNING_ALLOWED=NO -IDEPackageSupportDisableManifestSandbox=YES \
  -IDEPackageSupportDisablePackagePluginSandbox=YES build
```

This compiles without installing or launching. After adding, removing or renaming source files, regenerate and include `Dictator.xcodeproj/project.pbxproj`. Packages are pinned in `project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Test

Use the build command above with `test` instead of `build`. Hosted tests skip startup, history, hotkeys and microphone access.

From the repository root:

```sh
python3 -m unittest discover -s scripts/tests -v
```

For model-free speech-server tests, create an isolated environment:

```sh
python3.13 -m venv server/.venv
server/.venv/bin/python -m pip install \
  fastapi==0.136.1 uvicorn==0.46.0 httpx==0.28.1 \
  numpy==2.4.4 scipy==1.17.1 pytest==9.0.3 pytest-asyncio==1.3.0 tiktoken==0.12.0
server/.venv/bin/python -m pip install --no-deps mlx-whisper==0.4.3
server/.venv/bin/python -m pytest server/tests --ignore=server/tests/test_quality_golden.py
```

Routine tests use synthetic audio and mocked services. The excluded quality suite needs real models and `jiwer`. Don't run bootstrap, download models or use live services for routine checks.

`SettingsSnapshotTests` writes Settings and alert PNGs to `/tmp/dictator-settings-snaps` only when that directory already exists. See [manual checks](manual-testing.md) for native behavior that mocks cannot verify.

## Run a local build

Installing, launching, recording and managing services are deliberate steps; do them only when requested.

```sh
# In a logged-in desktop session with the login keychain unlocked:
scripts/build-sign.sh
scripts/install-app.sh /path/to/Dictator.app
```

`build-sign.sh` uses the stable “Dictator Local Code Signing” identity. SSH can't normally unlock the login keychain; use the desktop session or a one-shot GUI LaunchAgent. `install-app.sh` backs up the previous build; `--no-launch` skips launch. `scripts/dev-install.sh` combines the two.

Install on the main Mac first, then connected Macs. Grant macOS permissions on each Mac's own screen. Changing signing identity may require permission approval again.

## Keeping development builds out of the live setup

Debug build/test products use the display name **Dictator Dev** and bundle ID `dev.noamlitt.dictator.development`. Outside hosted tests, they exit before history, microphone, hotkeys or startup registration are initialized, unless the developer explicitly supplies `--allow-development-runtime`. To run a development build deliberately, add that argument to the Xcode Run scheme or launch that exact executable with the flag; it has a separate macOS permission identity. Never grant it access just to run unit tests.

The signed build helper overrides the display name to Dictator and the bundle ID to the installed identity. Installation unregisters stale production and development build copies from LaunchServices. Use `/Applications/Dictator.app` or `dev.noamlitt.dictator` for native-app verification, never the ambiguous bare name. Preserve the stable signing identity; an adhoc development permission does not authorize a different adhoc build. If a stray development copy was accidentally launched, quit only that copy and remove/reset only its own permission entry; retain the installed app’s grants.



## Find the code

| Directory | Contents |
|---|---|
| `swift-client/` | SwiftUI Mac app and tests. |
| `server/` | Optional Python speech server. Models can also run in the app. |
| `shared/` | Catalogs, command templates, capture connectors and synthetic fixtures. |
| `scripts/` | Build, signing, installation and server helpers. |

## Diagnose

- App: `~/Library/Logs/Dictator/hotkey.log`. Prefixes include `sync:`, `speech:`, `cleanup:`, `core:` and `edge:`.
- Speech server: `~/Library/Logs/dictation-server.log`, one JSON line per request.

[Architecture](architecture.md) · [Release signing and updates](releases.md) · [Integration contracts](integrations.md) · [Speech server](../server/README.md)
