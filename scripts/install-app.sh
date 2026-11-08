#!/usr/bin/env bash
# Install a signed Dictator.app to /Applications, sweep stale LaunchServices
# / Spotlight registrations, and (unless --no-launch) launch it.
#
# Runs on any Mac, including one with neither Xcode nor the signing identity;
# build-sign.sh does the build+sign half and hands its output to this script.
#
# Accept either build-sign.sh's stable local certificate requirement or a
# verified Apple Developer ID Application signature with a real Team ID.
# Ad hoc builds have neither and cannot preserve TCC grants across installs.
# No certificate/private key is needed on the receiving Mac.
#
# Usage: install-app.sh <path-to-Dictator.app> [--no-launch]
#
#   --no-launch   Skip the final "== launch ==" step. Use this when
#                 installing from another Mac over SSH: TCC prompts (Accessibility
#                 / Input Monitoring / Microphone) can only be answered on
#                 that Mac's own desktop, in its own Aqua session — an SSH
#                 session has no windowserver connection to show a prompt in,
#                 so `open` would just sit there waiting for a grant nobody
#                 can click. Launch the app from that Mac's own desktop
#                 afterward to answer the prompts.
set -euo pipefail

APP=""
NO_LAUNCH=0
for arg in "$@"; do
  case "$arg" in
    --no-launch) NO_LAUNCH=1 ;;
    -*)
      echo "error: unknown flag $arg" >&2
      exit 1
      ;;
    *) APP="$arg" ;;
  esac
done
if [[ -z "$APP" ]]; then
  echo "usage: $(basename "$0") <path-to-Dictator.app> [--no-launch]" >&2
  exit 1
fi
if [[ ! -d "$APP" ]]; then
  echo "error: $APP does not exist" >&2
  exit 1
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

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

BUNDLE_ID="dev.noamlitt.dictator"
LSR="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# Identify the source without assuming Developer ID embeds a certificate hash.
SOURCE_REQUIREMENT=$(codesign -d -r- "$APP" 2>&1 | grep -i designated || true)
CERT_SHA=$(grep -oE 'certificate (leaf|root) = H"[0-9a-fA-F]{40}"' <<<"$SOURCE_REQUIREMENT" \
  | grep -oE '[0-9a-fA-F]{40}' || true)
SOURCE_TEAM=$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ -n "$CERT_SHA" ]]; then
  echo "expected local certificate hash: $CERT_SHA (from $APP)"
elif [[ "$SOURCE_TEAM" =~ ^[A-Z0-9]{10}$ ]] && \
     codesign --verify --strict --test-requirement '=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$APP"; then
  echo "expected Developer ID team: $SOURCE_TEAM (from $APP)"
else
  echo "error: $APP must have a stable local certificate or an Apple-verified Developer ID Application signature." >&2
  echo "  Ad hoc builds are refused. Use build-sign.sh or release.sh first." >&2
  exit 1
fi

INSTALLED="/Applications/Dictator.app"

# Validate the candidate completely before quitting or deleting anything, so a
# corrupt or wrong-bundle-id app can never leave /Applications empty. Also
# refuse to install the installed app over itself: the backup step below
# archives and deletes $INSTALLED, which would destroy the source.
if [[ "$APP" == "$INSTALLED" ]]; then
  echo "error: source and destination are both $INSTALLED; pass the freshly built app instead." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
if ! grep -q "identifier \"$BUNDLE_ID\"" <<<"$SOURCE_REQUIREMENT"; then
  echo "error: $APP's designated requirement does not carry identifier $BUNDLE_ID (a raw Debug build has the .development id):" >&2
  echo "  $SOURCE_REQUIREMENT" >&2
  exit 1
fi

if [[ -d "$INSTALLED" ]]; then
  PREVIOUS_REQUIREMENT=$(codesign -d -r- "$INSTALLED" 2>&1 | grep -i designated || true)
  if [[ "$PREVIOUS_REQUIREMENT" != "$SOURCE_REQUIREMENT" ]]; then
    echo "The signing identity is changing. macOS will ask for Microphone, Accessibility and Input Monitoring access again on this Mac."
  fi
fi

echo "== install =="

# Quit any running copy and prove it is gone. A surviving process keeps
# executing its old inode — if the bundle is replaced underneath it, that inode
# follows the old bundle (e.g. into ~/.Trash) and the stale build keeps owning
# the keyboard while /Applications holds the fixed one. Observed 2026-08-28.
quit_dictator
if pgrep -x Dictator >/dev/null; then
  echo "error: Dictator still running (pid $(pgrep -x Dictator | tr '\n' ' ')); refusing to swap the bundle underneath it." >&2
  exit 1
fi

# Never move the old bundle to ~/.Trash as a backup — a Trash copy keeps its
# LaunchServices registration and competes for the bundle id. Use
# DictatorAppBackups, which LS does not index.
if [[ -d "$INSTALLED" ]]; then
  BACKUP_DIR="$HOME/Library/Application Support/DictatorAppBackups"
  mkdir -p "$BACKUP_DIR"
  touch "$BACKUP_DIR/.metadata_never_index"
  BACKUP_ZIP="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)-preinstall.zip"
  # Archive, never copy: a live .app under Application Support gets picked up by
  # LaunchServices and starts competing for the bundle id.
  ditto -c -k --sequesterRsrc --keepParent "$INSTALLED" "$BACKUP_ZIP"
  echo "backed up previous build -> $BACKUP_ZIP"
fi
# Copied in full beside the destination first, so a failed copy leaves the
# working app alone. No .app name, or Launch Services sees a rival.
STAGED="$(dirname "$INSTALLED")/.dictator-update.$$"
PREVIOUS="$(dirname "$INSTALLED")/.dictator-previous.$$"
trap 'rm -rf "$STAGED"' EXIT
cp -R "$APP" "$STAGED"
if [[ -d "$INSTALLED" ]]; then
  mv "$INSTALLED" "$PREVIOUS"
  if ! mv "$STAGED" "$INSTALLED"; then
    mv "$PREVIOUS" "$INSTALLED"
    echo "error: could not put the new build in place; the previous app is restored" >&2
    exit 1
  fi
  rm -rf "$PREVIOUS"
else
  mv "$STAGED" "$INSTALLED"
fi
codesign --verify --deep --strict "$INSTALLED"
INSTALLED_REQUIREMENT=$(codesign -d -r- "$INSTALLED" 2>&1 | grep -i designated)
if [[ "$INSTALLED_REQUIREMENT" != "$SOURCE_REQUIREMENT" ]]; then
  echo "error: installed app requirement does not match the source signing identity" >&2
  exit 1
fi
if ! grep -q "identifier \"$BUNDLE_ID\"" <<<"$INSTALLED_REQUIREMENT"; then
  echo "error: installed app requirement does not contain identifier $BUNDLE_ID" >&2
  exit 1
fi

# Keep only /Applications/Dictator.app registered with LaunchServices. Every
# build copy shares bundle id dev.noamlitt.dictator; extra registrations
# confuse TCC (Accessibility grants bind to the wrong copy) and Spotlight.
# Development registrations are swept too: resolving the bare name "Dictator"
# must never accidentally launch an adhoc-signed test/build app.
# Sweep every registered path, not just this run's build copy — stale entries
# from raw Xcode builds and Trash backups accumulate otherwise.
"$LSR" -f "$INSTALLED" 2>/dev/null || true
for _ in 1 2 3; do
  stale_found=0
  while IFS= read -r stale; do
    [[ -z "$stale" || "$stale" == "$INSTALLED" ]] && continue
    echo "unregistering stale copy: $stale"
    "$LSR" -u "$stale" 2>/dev/null || true
    stale_found=1
  done < <("$LSR" -dump 2>/dev/null \
    | awk -v id="$BUNDLE_ID" '/^[[:space:]]*path:[[:space:]]/{p=$0; sub(/^[[:space:]]*path:[[:space:]]*/,"",p); sub(/[[:space:]]*\(0x[0-9a-fA-F]+\)[[:space:]]*$/,"",p)} /^[[:space:]]*identifier:[[:space:]]/{ if ($2 == id || $2 == id ".development") print p }' | sort -u)
  [[ "$stale_found" == "0" ]] && break
done

REGISTERED_PATHS=$("$LSR" -dump 2>/dev/null \
  | awk -v id="$BUNDLE_ID" '/^[[:space:]]*path:[[:space:]]/{p=$0; sub(/^[[:space:]]*path:[[:space:]]*/,"",p); sub(/[[:space:]]*\(0x[0-9a-fA-F]+\)[[:space:]]*$/,"",p)} /^[[:space:]]*identifier:[[:space:]]/{ if ($2 == id) print p }' | sort -u)
REGCOUNT=$(printf '%s\n' "$REGISTERED_PATHS" | awk 'NF { count++ } END { print count+0 }')
if [[ "$REGCOUNT" != "1" || "$REGISTERED_PATHS" != "$INSTALLED" ]]; then
  echo "error: registered paths for $BUNDLE_ID are not exactly $INSTALLED:" >&2
  printf '%s\n' "$REGISTERED_PATHS" | sed 's/^/  /' >&2
  exit 1
fi

# Spotlight is a second discovery path independent of LaunchServices. The
# build root is .noindex and raw Debug builds have a development bundle id, so
# the production identifier must resolve to the installed app only.
# Spotlight indexes asynchronously: give it a few seconds, and if it still
# disagrees only warn. LaunchServices (checked above) is what actually
# resolves the bundle id; a stale or empty Spotlight answer must not leave
# the app installed but not running.
mdimport "$INSTALLED" >/dev/null 2>&1 || true
INDEXED_PATHS=""
for _ in 1 2 3 4 5 6; do
  INDEXED_PATHS=$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'c" 2>/dev/null | sort -u)
  [[ "$INDEXED_PATHS" == "$INSTALLED" ]] && break
  sleep 2
done
if [[ "$INDEXED_PATHS" != "$INSTALLED" ]]; then
  echo "warning: Spotlight paths for $BUNDLE_ID are not exactly $INSTALLED (index may lag):" >&2
  printf '%s\n' "${INDEXED_PATHS:-<none>}" | sed 's/^/  /' >&2
fi

if [[ "$NO_LAUNCH" == "1" ]]; then
  echo "== skip launch (--no-launch) =="
  echo "installed $INSTALLED; launch it from this Mac's own desktop to answer"
  echo "any TCC prompts (Accessibility / Input Monitoring / Microphone) — those"
  echo "grants can only be made in a local Aqua session, never over SSH."
  exit 0
fi

echo "== launch =="
open "$INSTALLED"
sleep 3
PIDS=($(pgrep -x Dictator || true))
if [[ "${#PIDS[@]}" != "1" ]]; then
  echo "error: expected exactly one Dictator process, found ${#PIDS[@]}: ${PIDS[*]:-none}" >&2
  exit 1
fi
PID="${PIDS[0]}"

# Assert the live process is executing the bundle we just installed, not a
# leftover inode from a previous one.
IMAGE=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  IMAGE=$(lsof -p "$PID" 2>/dev/null | awk '$4=="txt" && /\/Contents\/MacOS\/Dictator$/ {print $NF; exit}')
  [[ -n "$IMAGE" ]] && break
  sleep 1
done
if [[ "$IMAGE" != "$INSTALLED/Contents/MacOS/Dictator" ]]; then
  echo "error: pid $PID is executing '$IMAGE', not the installed bundle." >&2
  exit 1
fi
echo "installed + running from $IMAGE (pid $PID)"
