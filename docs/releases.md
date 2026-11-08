# Releases

Signing, notarization and update-feed setup for maintainers. For everyday builds, see [Development](development.md).

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
