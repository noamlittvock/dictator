#!/usr/bin/env bash
# Build a Developer ID release. Never installs, launches or publishes the app.
# Run on the certificate-holding Mac's logged-in desktop; see docs/development.md.
# Tools resolve through PATH so script contracts can use mocks without real keys.
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }
SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --help|-h) echo 'usage: scripts/release.sh [--skip-notarize]'; exit 0 ;;
    *) fail "unknown option: $arg" ;;
  esac
done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${DICTATOR_BUILD_DIR:-$ROOT/.dd}"
PACKAGES_DIR="$ROOT/.spm"
APP="$BUILD_DIR/Build/Products/Release/Dictator.app"
ENTITLEMENTS="$ROOT/swift-client/Dictator/Dictator.entitlements"
PROFILE="${DICTATOR_NOTARY_PROFILE:-dictator}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
command -v python3 >/dev/null || fail 'python3 is required (install the Xcode command line tools).'

# Only valid Developer ID Application identities, including a private key.
IDENTITIES=$(security find-identity -v -p codesigning "$KEYCHAIN") \
  || fail 'Could not read the login keychain. Unlock it in this Mac’s desktop session.'
IDENTITIES=$(printf '%s\n' "$IDENTITIES" | awk 'length($2) == 40 && /"Developer ID Application: / { print }')
COUNT=$(printf '%s\n' "$IDENTITIES" | awk 'NF { n++ } END { print n+0 }')
if [[ -n "${DICTATOR_SIGN_IDENTITY:-}" ]]; then
  IDENTITY=$(printf '%s\n' "$IDENTITIES" | python3 -c '
import os, re, sys
wanted = os.environ["DICTATOR_SIGN_IDENTITY"]
matches = [m.group(1) for line in sys.stdin for m in [re.search(r"([A-Fa-f0-9]{40}) \"([^\"]+)\"", line)]
           if m and (m.group(1).lower() == wanted.lower() or m.group(2) == wanted)]
if len(matches) != 1:
    sys.exit("error: DICTATOR_SIGN_IDENTITY must name exactly one valid Developer ID Application identity in the login keychain (use its SHA-1 hash).")
print(matches[0])')
else
  [[ "$COUNT" != 0 ]] || fail 'No Developer ID Application identity found. The Account Holder must create one in Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application on this Mac, then run again in its logged-in desktop session.'
  [[ "$COUNT" == 1 ]] || fail 'More than one Developer ID Application identity found. Run security find-identity -v -p codesigning in the login keychain, then set DICTATOR_SIGN_IDENTITY to the chosen SHA-1 hash.'
  IDENTITY=$(printf '%s\n' "$IDENTITIES" | awk '{print $2}')
fi
if [[ "$SKIP_NOTARIZE" == 0 ]]; then
  xcrun notarytool history --keychain-profile "$PROFILE" --output-format json >/dev/null \
    || fail "Could not use notary profile '$PROFILE'. Run xcrun notarytool store-credentials '$PROFILE' on this Mac, unlock the login keychain, and check your Apple account and network connection."
fi

# project.yml sets this empty, so only an explicit build setting reaches the app.
SPARKLE_KEY="${DICTATOR_SPARKLE_PUBLIC_KEY:-}"
if [[ "$SKIP_NOTARIZE" == 0 && -z "$SPARKLE_KEY" ]]; then
  fail 'Set DICTATOR_SPARKLE_PUBLIC_KEY to the public update key, or this release could never update itself. See docs/development.md.'
fi
# Sparkle compares build numbers, so every release needs a higher one.
BUILD_NUMBER=$(date -u +%Y%m%d%H%M)

echo "== build Release (Developer ID identity $IDENTITY) =="
xcodebuild -project "$ROOT/swift-client/Dictator.xcodeproj" -scheme Dictator \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" -clonedSourcePackagesDirPath "$PACKAGES_DIR" \
  -IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePackagePluginSandbox=YES \
  CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=YES \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" DICTATOR_SPARKLE_PUBLIC_KEY="$SPARKLE_KEY" \
  PRODUCT_BUNDLE_IDENTIFIER=dev.noamlitt.dictator DICTATOR_DISPLAY_NAME=Dictator build
[[ -d "$APP" ]] || fail "Build did not produce $APP."
VERSION=$(python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, re, sys
with open(sys.argv[1], 'rb') as f:
    info = plistlib.load(f)
if info.get('CFBundleIdentifier') != 'dev.noamlitt.dictator' or info.get('CFBundleDisplayName') != 'Dictator':
    sys.exit('error: built app must have the production bundle ID and display name.')
version = info.get('CFBundleShortVersionString', '')
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*(?:[-+][A-Za-z0-9.-]+)?', version):
    sys.exit('error: built app has an invalid release version.')
print(version)
PY
)

WORK=$(mktemp -d "$BUILD_DIR/release-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# Walk real paths only (framework Versions/Current and top-level aliases must
# not be signed twice). Include every Mach-O, even extensionless helpers in
# Resources, and every code bundle. Descendants always precede their container.
python3 - "$APP" >"$WORK/nested" <<'PY'
import os, pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
magic = {bytes.fromhex(h) for h in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
paths = []
for root, dirs, files in os.walk(app, followlinks=False):
    dirs[:] = [d for d in dirs if not (pathlib.Path(root) / d).is_symlink()]
    for name in dirs:
        p = pathlib.Path(root) / name
        if p.suffix in {'.framework', '.xpc', '.app', '.appex'}:
            paths.append(p)
        elif p.suffix == '.bundle':
            # SwiftPM resource-only bundles are sealed by their container; they
            # are not code bundles. Only sign a bundle with its own executable.
            for info_path in (p / 'Contents/Info.plist', p / 'Info.plist'):
                if info_path.is_file():
                    with info_path.open('rb') as f:
                        if plistlib.load(f).get('CFBundleExecutable'):
                            paths.append(p)
                    break
    for name in files:
        p = pathlib.Path(root) / name
        if p.is_symlink():
            continue
        with p.open('rb') as f:
            if f.read(4) in magic:
                paths.append(p)
for p in sorted(paths, key=lambda p: (-len(p.parts), str(p))):
    sys.stdout.buffer.write(os.fsencode(p) + b'\0')
PY
while IFS= read -r -d '' code; do
  # Preserve dependency-specific helper entitlements (e.g. Sparkle's sandboxed
  # XPC services); do not spread Dictator's microphone/Automation permissions.
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --preserve-metadata=entitlements "$code"
done <"$WORK/nested"
codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --deep "$APP"
codesign --verify --strict --test-requirement '=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$APP"
DETAILS=$(codesign -dv --verbose=4 "$APP" 2>&1)
FLAGS=$(printf '%s\n' "$DETAILS" | sed -n 's/^CodeDirectory .*flags=\(0x[0-9a-fA-F]*\).*/\1/p')
[[ "$FLAGS" =~ ^0x[0-9a-fA-F]+$ ]] && (( FLAGS & 0x10000 )) \
  || fail 'Signed app is missing the hardened runtime flag.'
TEAM=$(printf '%s\n' "$DETAILS" | sed -n 's/^TeamIdentifier=//p')
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail 'Signed app has no real TeamIdentifier.'
codesign -d --entitlements :- "$APP" >"$WORK/entitlements.plist"
python3 - "$WORK/entitlements.plist" <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], 'rb') as f:
        entitlements = plistlib.load(f)
except (OSError, plistlib.InvalidFileException, ValueError):
    sys.exit('error: signed app has no readable entitlements plist.')
if not isinstance(entitlements, dict):
    sys.exit('error: signed app has no entitlements dictionary.')
for key in ('com.apple.security.device.audio-input', 'com.apple.security.automation.apple-events'):
    if entitlements.get(key) is not True:
        sys.exit('error: signed app is missing entitlement ' + key)
if entitlements.get('com.apple.security.get-task-allow'):
    sys.exit('error: signed release permits debugging (get-task-allow).')
PY
echo "Verified Developer ID signature, hardened runtime and entitlements (team $TEAM)."
if [[ "$SKIP_NOTARIZE" == 1 ]]; then
  echo 'Signing-only check complete. This app has not been notarized; do not publish it.'
  echo "SIGNED_APP=$APP"
  exit 0
fi

ditto -c -k --keepParent "$APP" "$WORK/submit.zip"
SUBMIT_STATUS=0
xcrun notarytool submit "$WORK/submit.zip" --wait --keychain-profile "$PROFILE" \
  --output-format json >"$WORK/notary.json" || SUBMIT_STATUS=$?
cat "$WORK/notary.json"
STATUS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$WORK/notary.json") \
  || fail "Notarization returned no readable result. Check profile '$PROFILE' with xcrun notarytool store-credentials '$PROFILE' and check your network connection."
if [[ "$SUBMIT_STATUS" != 0 || "$STATUS" != Accepted ]]; then
  SUBMISSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$WORK/notary.json")
  if [[ -n "$SUBMISSION" ]]; then
    xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" || true
  fi
  fail "Notarization was not accepted ($STATUS). Review the log above; no release archive was produced."
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute "$APP"
OUTPUT_DIR="$BUILD_DIR/releases"
mkdir -p "$OUTPUT_DIR"
ARCHIVE="$OUTPUT_DIR/Dictator-$VERSION-macOS-arm64.zip"
# A fresh zip is required: the submitted archive predates the stapled ticket.
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
echo "RELEASE_ARCHIVE=$ARCHIVE"
shasum -a 256 "$ARCHIVE"
echo 'Ready for manual review and publishing. Nothing was uploaded to GitHub.'
