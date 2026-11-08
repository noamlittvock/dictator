# Changelog

All notable changes to Dictator are documented here, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.1.0] - 2026-11-08

The first public release.

### Added

- Choose any key or combination for dictation and for commands in Settings › General and the welcome. Commands can be dictation plus a key, or keys of their own.
- A Help page that shows how Dictator works in small animated pictures, with Basics, a Manual, Advanced topics and an FAQ, searchable as one, and a "?" beside each page title with a quick picture of that page. Help follows your dictation key and opens from the sidebar, the menu bar icon, the Help menu and ⌘?.
- Run a command in the background, with no terminal window. Spoken words reach it only as a quoted argument.
- Keyboard shortcuts for commands that need no spoken words.
- Commands limited to certain apps, so one phrase can do different things in different apps.
- Export and import of commands. Imported commands arrive turned off, and exports leave out personal details unless you choose to include them.
- `dictator://run` links for commands that opt in. Commands that act ask first, every time.
- Recent commands on Home, names and outcomes only, and Run Again in the menu bar.
- A "Try a command" step at the end of Welcome.
- In-app updates: released copies check GitHub for updates unless that is turned off in Settings › General.
- A three-stage roadmap linked to the project vision: Command, Supervise and Delegate.
- An MIT licence, third-party notices shipped in the app, contribution and security reporting guidance, issue and pull request templates, and CI for builds and model-free tests.

### Changed

- One design across the app: shared page titles, tabs, buttons, sheets, cards and spacing, and clearer depth in dark mode.
- Settings is one page with tabs, and ⌘, opens it in the main window.
- Home fits about twice as many dictations in the same height.
- Floating alerts and progress cards use the app's own colours in both themes.
- Direct, descriptive wording throughout.
- New positioning: Voice to Power, the voice-first power tool for Mac.
- Voice launch is now Commands, and Workspace launch is now Workspaces.
- The README uses plain headings.
- Releases are signed with Developer ID and notarized by Apple. The installer checks both, and it no longer strips quarantine or re-signs a download.

### Removed

- The Plain English setting. The app now has one wording.

### Fixed

- Dictator no longer says your words are on the clipboard after typing them into Google Docs or a web app such as T3 Code or ChatGPT. A field that reads the same after a paste no longer counts as a failed paste.
- A dictionary sync that changed nothing no longer keeps the database in memory on macOS 15.

## [1.0.0]

### Added

- On-Mac dictation with Whisper or Apple's speech recognition, optional Ollama clean-up and polish, a dictionary and learned corrections.
- Voice launch for apps, projects, Apple Shortcuts and configurable workflows, with confirmation pauses for actions.
- Workspace routines for app placement, browser tabs, remembered windows and window groups, with preview and undo.
- Standalone and multi-Mac operation over Tailscale, pairing, replicated history and mirrored settings.
- Optional typed history, privacy controls, recovery of failed recordings, and Datasets preparation and explicit exports.
- First-use setup, model selection, installer and uninstaller, and the Dictator voice with a Plain English option.

### Fixed

- Dictation failures now show actionable alerts and preserve recordings for recovery.
- Connection loss, retries and dictation destination handling across Macs.
- Clean-up checks to preserve commands, languages and substantive content; bounded speech-server requests and authenticated access.

This entry summarizes the version 1.0.0 source and its git history; no release date is assigned here.
