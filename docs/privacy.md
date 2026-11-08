# History and privacy

Speech recognition and clean-up run on your Macs. History is stored locally on each Mac and replicated with your main Mac when connected.

## What gets saved

You choose where history saving is allowed. Saved dictations can include the speech recognition result, inserted text and a matched correction.

**Typed history starts off.** Enable it only for the apps you want. When hiding secrets is on, recognized passwords and keys are hidden; review any export before sharing it.

**Learning from corrections starts on.** After insertion, Dictator checks the destination field, then checks again when you move on, start another dictation or after 60 seconds. It learns filtered word pairs from edits to the dictated span. This can work with history saving off; full corrected sentences are saved only where your rules permit typed text. Secure and excluded fields are skipped. Pause stops the checks; turn off Learn from corrections to disable them.

## Microphone and recovery audio

The audio engine starts when Dictator opens with microphone permission, so macOS may show microphone use while idle. Idle audio is discarded. Saving or sending audio begins only with an explicit recording action.

Failed dictations keep audio for recovery. Recovery recordings expire after 14 days; the oldest may be removed sooner to stay below 512 MiB.

The optional Python server has a separate `DICTATION_KEEP_TAKES` setting, off by default. Enabling it saves takes regardless of the app's history setting. [Server configuration](../server/README.md#configuration).

## Datasets

Filter saved history by vendor, project or date. Clean and preview it, then export JSONL, JSON or CSV, save a snapshot, or explicitly send a package to your configured CLI.

Dictator prepares the data. You choose the analysis and the tool that runs it. For example, ask your agent which prompts you repeat, then turn useful answers into project rules or commands. Preparation doesn't change stored history.

## What goes online

- Whisper and Ollama model downloads contact their hosts; macOS downloads Apple speech assets.
- Website icons are fetched from the websites themselves.
- Configured releases check GitHub for updates unless automatic checks are off.
- Commands use the websites and services you configure.
- A CLI you send a dataset to may use an external provider.

[Report a security issue privately](../SECURITY.md).
