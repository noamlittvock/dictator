# Contributing to Dictator

Changes should fit the [north star](docs/vision.md): Command now, Supervise next, Delegate later. Explain which stage your change serves and what it helps someone do. There are no promised dates for the later stages. Privacy-sensitive behaviour stays opt-in; typed history stays off until the user turns it on.

## Start small

The easiest first contribution is a template in [`shared/shortcut-catalog.json`](shared/shortcut-catalog.json) or a tool in [`shared/tool-catalog.json`](shared/tool-catalog.json). These are data, so you need no Swift. Follow a nearby entry, use made-up examples, and explain how you checked the result. Do not include personal contacts, dictation history or credentials.

## Build

Use an Apple silicon Mac with macOS 14 or later, Xcode 26 or later (for the Apple speech APIs), and [xcodegen](https://github.com/yonaskolb/XcodeGen). From the repository root:

```sh
cd swift-client
xcodegen generate
xcodebuild -project Dictator.xcodeproj -scheme Dictator -destination platform=macOS \
  -derivedDataPath ../.dd -clonedSourcePackagesDirPath ../.spm \
  CODE_SIGNING_ALLOWED=NO -IDEPackageSupportDisableManifestSandbox=YES \
  -IDEPackageSupportDisablePackagePluginSandbox=YES build
```

This compiles without installing the app. See [`docs/development.md`](docs/development.md) for deliberate signing and installation steps. After adding, removing or renaming source files, regenerate the Xcode project and include `swift-client/Dictator.xcodeproj/project.pbxproj` in your change.

## Test

Run the same `xcodebuild` command above with `test` in place of `build`. Hosted tests skip app startup. They do not require microphone access or an installed app.

From the repository root, run the script contracts:

```sh
python3 -m unittest discover -s scripts/tests -v
```

For model-free speech-server tests, use an isolated Python 3.13 environment. Install the web, numeric and test dependencies plus the bundled Whisper tokenizer assets; do not run the server bootstrap or download models:

```sh
python3.13 -m venv server/.venv
server/.venv/bin/python -m pip install \
  fastapi==0.136.1 uvicorn==0.46.0 httpx==0.28.1 \
  numpy==2.4.4 scipy==1.17.1 pytest==9.0.3 pytest-asyncio==1.3.0 tiktoken==0.12.0
server/.venv/bin/python -m pip install --no-deps mlx-whisper==0.4.3
server/.venv/bin/python -m pytest server/tests --ignore=server/tests/test_quality_golden.py
```

The vocabulary tests load the tokenizer module directly, without importing the MLX runtime. The excluded quality suite needs real models and is outside routine tests. All routine tests use synthetic audio and mocked services, never personal recordings, personal history or live services. Report the commands you ran and their actual results in your pull request; say what you could not verify.

## Rules of the road

Read [`AGENTS.md`](AGENTS.md) before changing anything, and the relevant parts of [`docs/architecture.md`](docs/architecture.md) and [`docs/development.md`](docs/development.md). AGENTS.md applies to people and coding agents. In particular:

- Keep each Mac's store local, mirror shared settings, and keep protocol changes compatible.
- Keep listeners within Tailscale and reach remote servers only through the user's SSH.
- Keep shared catalog entries in data files. Change the Python and Swift clean-up prompts and their tests together.
- Installing or launching the app, managing the speech server, downloading models, using a microphone or contacting a live service requires the user's deliberate go-ahead. Routine verification does none of these.
- Keep plans, handoffs, audits, experiments and generated output outside the repository.

Call the app surfaces Commands and Workspaces; a saved layout is a routine. Use Shortcut only for an Apple Shortcut or a keyboard shortcut. Keep internal identifiers and stored names unchanged.

Settings copy must explain what a setting does in plain words, with at most one short line underneath. Use “main Mac”, “connected to a main Mac” and “AI models”; keep ports, tokens and internal role names in Settings › Advanced.

The app has one wording, with its lines in `BrandVoice.swift`. Use direct, fast, confident and dry wording that says what is happening, what happened or what to do next. The person using the Mac has the power. Use the voice for titles, statuses and empty states, with plain instructions underneath. Keep it out of privacy, permissions, typed history, delete confirmations, Datasets, Advanced, People and navigation names. Keep it short and plain. A joke alone does not explain a result.

Keep pull requests focused, explain the user-visible change, and include synthetic reproduction steps for fixes. Never paste personal dictation history into issues, pull requests, logs or screenshots. Report vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md).

Dictator is released under the [MIT License](LICENSE). By contributing, you agree your work is released under it too. The Dictator name, logo and artwork are not covered by that license. If you add a dependency, font or other third-party asset, add its license to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
