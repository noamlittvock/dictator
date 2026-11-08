<p align="center">
  <img src=".github/brand/readme/hero.webp" alt="Dictator. Voice to power. An open-source, user-owned command layer for macOS. The Dictator cap sits behind a desk while code and app icons orbit it." width="100%">
</p>

<p align="center">
  <a href="https://noamlitt.com/products/dictator/"><img src=".github/brand/readme/badges/website.svg" alt="Website: noamlitt.com"></a>
  <a href="https://github.com/noamlittvock/dictator/tree/main/docs"><img src=".github/brand/readme/badges/docs.svg" alt="Docs: guides"></a>
  <a href="https://discord.gg/zVk555aYH"><img src=".github/brand/readme/badges/discord.svg" alt="Discord community"></a>
  <a href="LICENSE"><img src=".github/brand/readme/badges/license.svg" alt="License: MIT"></a>
  <a href="https://noamlitt.com/builder"><img src=".github/brand/readme/badges/maker.svg" alt="Built by Noam Litt"></a>
</p>

# Dictator

Local voice control for your Mac. Dictate into any app, launch a project, or put your windows back where you want them.

Hold **Right ⌥**, speak, let go. Clean text lands at your cursor.

- **Dictation.** Whisper or Apple speech recognition, with optional clean-up through Ollama. Runs on your Macs.
- **Commands.** “Open Safari.” “Code pantry fix the login bug.” Your phrases run the actions you configure.
- **Workspaces.** Save a window layout and bring it back by voice, click or keyboard shortcut. Preview first; undo afterward.
- **Several Macs.** Record on the laptop, run models on the mini, keep history in sync over Tailscale. One Mac works too.
- **Datasets.** Filter and export your saved prompts for analysis with a tool you choose. Typed history is opt-in.

## Install

**macOS 14+ · Apple silicon · Free and open source**

```sh
curl -fsSL https://raw.githubusercontent.com/noamlittvock/dictator/main/install.sh | sh
```

Or [download the Mac app](https://github.com/noamlittvock/dictator/releases/latest) and drag it to Applications.

Open Dictator, grant the permissions it asks for, and choose a speech model. For AI clean-up, install Ollama and pick a model in the app. Then hold Right Option and try a sentence.

For commands, turn one on in **Commands** and hold **Right Option + Right Shift**. Both key combinations can be changed in Settings.

[First run and troubleshooting →](docs/getting-started.md)

## Your voice stays on your Macs

Speech recognition and clean-up run locally. You choose what history to save and which apps, if any, can contribute typed prompts. Datasets exports or sends data to your configured CLI only when you ask.

Model downloads and update checks go online, as do the websites and services your commands use. [Privacy details →](docs/privacy.md)

## Docs

[Commands](docs/commands.md) · [Workspaces](docs/workspaces.md) · [Multiple Macs](docs/multiple-macs.md) · [History and Datasets](docs/privacy.md) · [All docs](docs/README.md)

## Where this is going

Command now. Supervise next. Delegate later. Dictator starts with dictation and saved actions; the aim is to launch work, see what needs you, and take over when you want. [The vision](docs/vision.md). No dates promised.

## Contribute

[Build and test](docs/development.md) · [Contributing](CONTRIBUTING.md) · [Issues](https://github.com/noamlittvock/dictator/issues/new/choose) · [Discord](https://discord.gg/zVk555aYH)

Coding agents: start with [AGENTS.md](AGENTS.md).

---

Built by [Noam Litt](https://noamlitt.com/builder). [MIT](LICENSE) for the code; [name and artwork](.github/brand/README.md) reserved. [Third-party notices](THIRD_PARTY_NOTICES.md).
