#!/bin/sh
# Install Dictator on this Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/noamlittvock/dictator/main/install.sh | sh
#   sh install.sh [--yes] [--help]
#
# Steps (each asked about when run in a terminal; --yes or a pipe takes the defaults):
#   1. Check this is an Apple silicon Mac on macOS 14 or later.
#   2. Download Dictator-<version>-macOS-arm64.zip from the latest GitHub release
#      (or use DICTATOR_ASSET=/path/to/Dictator.app, a .zip, or a folder holding one).
#   3. Verify the downloaded release's signature and Apple's approval, then put it
#      in /Applications (DICTATOR_INSTALL_DIR to change). Keep its quarantine and
#      Developer ID signature. DICTATOR_ASSET is a local build and may be ad hoc.
#   4. Optional: Ollama, for clean-up models (Homebrew if present, else the download page).
#   5. Optional: Tailscale, only if you will connect more than one Mac.
#   6. Open Dictator. Its welcome asks for the Microphone, Accessibility and Input
#      Monitoring permissions and downloads the speech model you choose.
#      (DICTATOR_NO_LAUNCH=1 skips this.)
#
# GITHUB_TOKEN is sent to the GitHub API when set; it is needed while the repository is private.
set -eu

REPO="noamlittvock/dictator"
# TeamIdentifier verified from the first Developer ID signed build.
EXPECTED_TEAM_ID="8GUV9GH4CN"
INSTALL_DIR="${DICTATOR_INSTALL_DIR:-/Applications}"
ASSET="${DICTATOR_ASSET:-}"
YES=0

for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --help|-h) sed -n '2,20p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Ask y/N when there is a terminal to ask; Enter means yes.
ask() {
  if [ "$YES" = 1 ] || ! [ -t 0 ]; then return 0; fi
  printf '%s [Y/n] ' "$1"
  read -r answer || answer=""
  case "$answer" in n|N|no|NO|No) return 1 ;; *) return 0 ;; esac
}
# Ask y/N for an optional step; Enter means no.
ask_optional() {
  if [ "$YES" = 1 ] || ! [ -t 0 ]; then return 1; fi
  printf '%s [y/N] ' "$1"
  read -r answer || answer=""
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

quit_dictator() {
  # SIGTERM, not an Apple event, so this works over SSH without Automation
  # permission. Dictator holds its exit until any dictation finishes, on this
  # Mac or a Mac it serves; the wait is longer than its own limit.
  pkill -TERM -x Dictator 2>/dev/null || true
  waited=0
  while pgrep -x Dictator >/dev/null 2>&1 && [ "$waited" -lt "${DICTATOR_QUIT_WAIT:-190}" ]; do
    [ "$waited" = 3 ] && echo "Waiting for a dictation to finish before quitting Dictator..."
    sleep 1
    waited=$((waited + 1))
  done
  if pgrep -x Dictator >/dev/null 2>&1; then
    pkill -KILL -x Dictator 2>/dev/null || true
    sleep 1
  fi
}

say "Dictator. Voice to Power."
say ""

# 1. This Mac.
[ "$(uname -s)" = "Darwin" ] || fail "Dictator runs on macOS."
[ "$(uname -m)" = "arm64" ] || fail "Dictator needs an Apple silicon Mac."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "Dictator needs macOS 14 or later (this Mac runs $(sw_vers -productVersion))."
say "This Mac: macOS $(sw_vers -productVersion), Apple silicon."

# 2. The app.
work=$(mktemp -d "${TMPDIR:-/tmp}/dictator-install.XXXXXX")
staged=""
trap 'rm -rf "$work" "$staged"' EXIT

app=""
if [ -n "$ASSET" ]; then
  case "$ASSET" in
    *.zip) ditto -x -k "$ASSET" "$work/unzipped" ;;
    *) mkdir -p "$work/unzipped" && cp -R "${ASSET%/}" "$work/unzipped/" ;;
  esac
  app=$(find "$work/unzipped" -maxdepth 3 -name Dictator.app -type d | head -n 1)
  [ -n "$app" ] || fail "no Dictator.app found in $ASSET"
  say "Using local build: $ASSET (local signing; not checked by Apple)."
else
  ask "Download the latest Dictator release from GitHub?" || exit 0
  auth=""
  [ -n "${GITHUB_TOKEN:-}" ] && auth="Authorization: Bearer $GITHUB_TOKEN"
  release=$(curl -fsSL ${auth:+-H "$auth"} -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest") \
    || fail "could not read the latest release (private repository? set GITHUB_TOKEN)."
  tag=$(printf '%s' "$release" | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
  # The asset's own API URL (…/releases/assets/<id>) sits in the same object as its name.
  asset_id=$(printf '%s' "$release" | tr -d '\n' | sed 's/},{/}\n{/g' | grep '"name": *"Dictator-[^"]*-macOS-arm64.zip"' | sed -n 's/.*"url": *"[^"]*\/releases\/assets\/\([0-9]*\)".*/\1/p' | head -n 1)
  [ -n "$asset_id" ] || fail "release $tag has no Dictator-*-macOS-arm64.zip."
  say "Downloading Dictator ${tag}…"
  curl -fsSL ${auth:+-H "$auth"} -H "Accept: application/octet-stream" -o "$work/Dictator.zip" \
    "https://api.github.com/repos/$REPO/releases/assets/$asset_id" || fail "download failed."
  ditto -x -k "$work/Dictator.zip" "$work/unzipped"
  app=$(find "$work/unzipped" -maxdepth 2 -name Dictator.app -type d | head -n 1)
  [ -n "$app" ] || fail "the download holds no Dictator.app."
fi

# Validate downloads before changing the installed app. Never repair a release's
# signature or bypass Gatekeeper by removing its download quarantine.
verify_release() {
  codesign --verify --deep --strict "$1" || fail "This download's signature could not be verified. Download a signed Dictator release again."
  spctl --assess --type execute "$1" || fail "macOS did not approve this download. Use a notarized Dictator release."
  team=$(codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [ -n "$team" ] && [ "$team" != "not set" ] || fail "This download has no Developer ID team. Download a signed Dictator release."
  if [ -n "$EXPECTED_TEAM_ID" ] && [ "$team" != "$EXPECTED_TEAM_ID" ]; then
    fail "This download's signing team does not match Dictator's expected team. Do not install it; download the official release again."
  fi
}
if [ -z "$ASSET" ]; then verify_release "$app"; fi

# 3. Install.
dest="$INSTALL_DIR/Dictator.app"
ask "Install Dictator to $INSTALL_DIR?" || exit 0
mkdir -p "$INSTALL_DIR"
# Copied in full beside the destination first, so a failed copy (a full disk,
# say) leaves the working app alone. No .app name, or Launch Services sees a rival.
staged="$INSTALL_DIR/.dictator-update.$$"
cp -R "$app" "$staged" || fail "couldn't copy Dictator into $INSTALL_DIR. Your current Dictator is untouched."
if [ -d "$dest" ]; then
  old_identity=$(codesign -d -r- "$dest" 2>&1 | sed -n '/^designated =>/p' || true)
  new_identity=$(codesign -d -r- "$app" 2>&1 | sed -n '/^designated =>/p' || true)
  if [ "$old_identity" != "$new_identity" ]; then
    say "The signing identity is changing. macOS will ask for Microphone, Accessibility and Input Monitoring access again on this Mac."
  fi
  if pgrep -x Dictator >/dev/null 2>&1 && [ "$INSTALL_DIR" = "/Applications" ]; then
    say "Quitting the running Dictator…"
    quit_dictator
  fi
  previous="$INSTALL_DIR/.dictator-previous.$$"
  mv "$dest" "$previous"
  if ! mv "$staged" "$dest"; then
    mv "$previous" "$dest"
    fail "couldn't put the new Dictator in place. Your current Dictator is back where it was."
  fi
  rm -rf "$previous"
else
  mv "$staged" "$dest"
fi
staged=""
if [ -n "$ASSET" ]; then
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
  if ! codesign --verify --deep --strict "$dest" >/dev/null 2>&1; then
    say "Signing this local build for this Mac…"
    codesign --force --deep --sign - "$dest"
  fi
  codesign --verify --deep --strict "$dest" || fail "the installed app's signature does not verify."
else
  verify_release "$dest"
fi
version=$(defaults read "$dest/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
say "Installed Dictator $version at $dest."

# 4. Ollama, for clean-up models.
if command -v ollama >/dev/null 2>&1 || [ -d /Applications/Ollama.app ]; then
  say "Ollama is already installed; choose a clean-up model in Dictator's settings."
elif ask_optional "Install Ollama, so Dictator can clean up your words with a local model? (Optional; Dictator works without it.)"; then
  if command -v brew >/dev/null 2>&1; then
    brew install --cask ollama || say "Homebrew could not install Ollama; get it from https://ollama.com/download"
  else
    say "Opening https://ollama.com/download (Ollama is a separate app; install it, then pick a model in Dictator)."
    open "https://ollama.com/download" 2>/dev/null || true
  fi
fi

# 5. Tailscale, for a fleet.
if [ -d /Applications/Tailscale.app ] || command -v tailscale >/dev/null 2>&1; then
  say "Tailscale is installed; Dictator's Your Macs page can connect your other Macs."
elif ask_optional "Will you connect more than one Mac? Dictator links them over Tailscale. Open its download page?"; then
  open "https://tailscale.com/download/mac" 2>/dev/null || true
fi

# 6. Open.
say ""
say "Next: choose a dictation key in Welcome (Right Option by default), allow Microphone,"
say "Accessibility and Input Monitoring in System Settings > Privacy & Security, and choose"
say "a speech model to download. Hold the key, speak and release to turn speech into text."
say "To remove it later: uninstall.sh from this repository, or drag Dictator out of Applications."
if [ "${DICTATOR_NO_LAUNCH:-0}" = 1 ] || [ "$INSTALL_DIR" != "/Applications" ]; then
  say "Not opening the app (DICTATOR_NO_LAUNCH or a custom install folder)."
else
  ask "Open Dictator now?" && open "$dest"
fi
