# Contributing

Small fixes, clearer docs and useful command templates are good places to start. For a larger change, open an issue explaining what it helps someone do. See the [vision](docs/vision.md) for the direction.

## Make a change

1. Read [AGENTS.md](AGENTS.md) and the relevant [architecture](docs/architecture.md) section.
2. Follow [Development](docs/development.md) to build and test.
3. Open a focused PR: describe the behavior change, how you checked it and anything you couldn't verify.

Adding a tool or command template? Follow a nearby entry in `shared/tool-catalog.json` or `shared/shortcut-catalog.json`. No Swift needed. Use made-up examples.

Use synthetic data in tests and bug reports. Keep personal recordings, history, contacts and credentials out of issues, logs and screenshots. [Report vulnerabilities privately](SECURITY.md).

Routine checks don't install the app, use a microphone, download models or start live services. Those steps need a deliberate request.

Contributions use the [MIT License](LICENSE). The name and artwork are reserved. Add third-party dependency and asset licenses to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
