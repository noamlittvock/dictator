# Get started

You need an Apple silicon Mac running macOS 14 or later.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/noamlittvock/dictator/main/install.sh | sh
```

Or download the zip from [Releases](https://github.com/noamlittvock/dictator/releases/latest), unzip it and drag Dictator to Applications. The installer verifies the release's signature and Apple notarization, then walks through optional dependencies.

## First dictation

1. Open Dictator and follow the welcome screen. Grant Microphone, Accessibility and Input Monitoring access on this Mac.
2. Choose a Whisper model, or Apple speech recognition on macOS 26+. Model downloads happen once.
3. For clean-up, install Ollama and choose a model. You can also skip AI clean-up.
4. Click a text field, hold **Right Option**, speak and release.

Change the keys or switch to tap-to-start in **Settings › General**. A recording stops at two minutes and transcribes what you said; start another to continue.

## Choose how much to change

- **Clean up the text:** remove fillers and restore punctuation.
- **Polish the text:** also fix grammar and tighten sentences.
- **Skip AI clean-up:** use the speech recognition result.

Click a dictation's result on Home to compare what was heard with what was inserted. Add names and specialist words to the Dictionary, or let Dictator learn them from corrections. [What learning saves](privacy.md).

## If it doesn't work

| Problem | Try |
|---|---|
| The key does nothing | Check Input Monitoring access and the keys in Settings › General. |
| No audio | Check Microphone access and the recording source in Settings › Your Macs. |
| Text isn't inserted | Check Accessibility access and try a normal text field. Some apps restrict insertion. |
| Clean-up is unavailable | Check Ollama and the chosen model. Speech recognition can still return text. |
| Another Mac is offline | Check Tailscale and Settings › Your Macs. A configured backup can take over. |

A failed dictation shows an explanation and keeps the recording for recovery from Home or History & Privacy. Recovery audio expires after 14 days; older recordings may go sooner if storage exceeds 512 MiB.

## Update or uninstall

Configured releases check for updates; change automatic checks in **Settings › General**. Local development builds have no updater.

The repository's `uninstall.sh` removes the app and capture helpers. Removing saved data or the optional speech server is a separate choice. Disable Open at Login in Dictator or review it in System Settings.

Next: [Commands](commands.md) · [Workspaces](workspaces.md) · [Multiple Macs](multiple-macs.md)
