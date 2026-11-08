# Integrations

For using commands, start with [Commands](commands.md).

## Command files

Commands imports and exports `.json` files with `{ "dictatorCommands": 1, "commands": [...], "lists": [...] }`. Commands and lists use the existing `VoiceCommand` and `VoiceList` fields, except exported commands omit `id`, `hotkey` and `runsFromOtherApps`; `onlyInApps` stays. Import supplies fresh IDs and forces commands off, ignoring supplied launch permissions. Unknown top-level keys are ignored; a higher format or unknown step kind reports “This file needs a newer Dictator.” Files over 1,000,000 bytes or invalid structures are refused without settings changes. No document type is registered.

Export lists referenced by the selected commands. Entries require a separate opt-in per list with details shown first. Paths and addresses, including webhooks and values embedded in text, are shown in full and omitted by default; omission blanks the whole containing value. Review shows phrases, existing step summaries and full action details marked “Check this”, with warnings for mixed scripts and invisible characters. Fill missing values and change clashing phrases before confirmation, as required by the existing shared-settings validator. Lists combine by name, preserving existing entries when any name or alias overlaps. Saving uses the ordinary mirrored settings path. `CommandFileTests` covers the pure transformations, privacy byte exclusions, compatibility, validation limits, hostile strings and atomic merge failures; native panels and connected-Mac delivery need manual checks.

## Starting a command from other apps

Turn on **Let other apps start this** in the Commands editor and copy its `dictator://run?command=<id>` link. Exact saved names also work when URL-encoded; IDs survive renames. Links cannot supply words, required spoken parts refuse, and acting or Terminal steps ask Allow/Cancel on every run. Busy starts and attempts less than two seconds apart are ignored. The local Pause state also blocks these starts.

`CFBundleURLTypes` registers `dictator` through the normal app bundle. Preserve that plist entry when packaging and sign the bundle normally; no entitlement, helper, listener or App Intents flag is needed. Debug and non-production bundle IDs refuse command triggers even with `--allow-development-runtime`. Native URL delivery, Launch Services selection when multiple builds exist, and the permission dialog still need testing with an installed Release build on each Mac. Unit tests inject configuration, clock, consent, registry and executor; they never open links or execute actions.

## Dictator actions in Apple Shortcuts

The standard self-signed build leaves `DICTATOR_ENABLE_APP_INTENTS` undefined. All three intent types remain available for mocked business-logic tests, but declare `isDiscoverable = false` and the `AppShortcutsProvider` supplies no shortcuts. Settings explains this build’s availability. Running an existing Apple Shortcut from Commands is a separate integration and remains available. Previously saved Shortcuts containing a Dictator action may still fail until their app build meets the system’s validation requirements.

On macOS 27.0, native testing reached the installed production app but `linkd` rejected its mediator connection with “Unable to get teamId” and “requiresValidatedBundle”. This establishes the limitation on that system; it is not a claim about all historical macOS releases. Adding a fabricated Team ID or private entitlement is not a supported repair.

To investigate enabling these actions, first obtain a genuine Apple Development or Developer ID signing identity through [Xcode’s supported team workflow](https://help.apple.com/xcode/mac/current/en.lproj/dev60b6fbbc7.html). A personal team does not itself require a paid membership. Set `DICTATOR_ENABLE_APP_INTENTS` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for that deliberately prepared build, preserve its actual signing entitlements, verify its Team ID and signature, then test the actions end to end in native Shortcuts. The flag enables metadata; it does not prove that a signature or action works.

Changing from the fixed local certificate changes the [designated requirement](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) and can require Microphone, Accessibility and Input Monitoring approval again. Plan that transition before deployment. The current `build-sign.sh` deliberately selects the fixed local certificate and refuses to hand off an enabled App Intents build unless its final signature has a Team ID and validates against Apple’s signing anchor; `install-app.sh` expects its certificate-hash requirement. Neither is a general Apple-team signing/deployment pipeline. Do not re-sign or install with a different identity as a routine rebuild.
