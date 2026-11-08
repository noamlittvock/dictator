#!/usr/bin/env bash
# Build and sign Dictator.app with the stable local cert.
#
# Pairs with install-app.sh, which installs the result on any Mac (it doesn't
# need Xcode or this signing identity).
#
# Signing with a fixed self-signed cert (vs. adhoc "Sign to Run Locally")
# keeps the app's designated requirement constant across rebuilds. It has no
# Apple Team ID, so Dictator's own App Intents remain disabled in this build.
# Changing signing category requires an explicit deployment/TCC transition.
# The fixed local requirement is:
#   identifier "dev.noamlitt.dictator" and certificate leaf = H"<cert>"
# so the Accessibility / Microphone TCC grants persist — no more re-granting
# after every build. Create the cert once via Keychain Access → Certificate
# Assistant → Create a Certificate (name "Dictator Local Code Signing",
# Self-Signed Root, Code Signing).
#
# Prints the signed app's path as the last line of stdout, prefixed
# "BUILT_APP=", so callers (dev-install.sh, or an operator copying the app to
# another Mac) can parse it without re-deriving SYMROOT themselves.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_DIR="$PROJECT_DIR/swift-client"
XCODEPROJ="$SWIFT_DIR/Dictator.xcodeproj"
SYMROOT="${DICTATOR_BUILD_DIR:-$HOME/Library/Caches/Dictator Build}/Build/Products"
BUILT_APP="$SYMROOT/Debug/Dictator.app"
ENTITLEMENTS="$SWIFT_DIR/Dictator/Dictator.entitlements"
CERT_NAME="Dictator Local Code Signing"
BUNDLE_ID="dev.noamlitt.dictator"

# Resolve a valid code-signing identity (certificate + private key), not merely
# a same-named certificate. A stale certificate named "Dictator Local Signing"
# also exists in this keychain and has no usable signing identity; selecting it
# makes rebuilds fail or drift to a different requirement, invalidating TCC.
CERT_SHA=$(security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db \
  | awk -v name="$CERT_NAME" 'length($2) == 40 && index($0, "\"" name "\"") { print $2; exit }')
if [[ -z "${CERT_SHA:-}" ]]; then
  echo "error: valid signing identity '$CERT_NAME' not found in login keychain." >&2
  echo "create it: Keychain Access > Certificate Assistant > Create a Certificate" >&2
  exit 1
fi
echo "signing identity: $CERT_NAME ($CERT_SHA)"

echo "== build =="
xcodebuild -project "$XCODEPROJ" -target Dictator -configuration Debug \
  SYMROOT="$SYMROOT" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" DICTATOR_DISPLAY_NAME=Dictator build | tail -1

echo "== sign =="
codesign --force --deep --sign "$CERT_SHA" --entitlements "$ENTITLEMENTS" "$BUILT_APP"
DESIGNATED_REQUIREMENT=$(codesign -d -r- "$BUILT_APP" 2>&1 | grep -i designated)
echo "$DESIGNATED_REQUIREMENT"
if ! grep -qi "$CERT_SHA" <<<"$DESIGNATED_REQUIREMENT"; then
  echo "error: signed app requirement does not contain expected identity $CERT_SHA" >&2
  exit 1
fi

# Never hand an opt-in App Intents build to an installer with a signing
# identity that the system cannot validate. Check the current three actions
# and provider in the final metadata, and the final signature, not an
# environment variable, build setting or claimed entitlement.
INTENTS_METADATA="$BUILT_APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
INTENTS_ADVERTISED=0
for intent in DictateIntent CleanUpTextIntent RunVoiceLaunchShortcutIntent; do
  DISCOVERABLE=$(/usr/bin/plutil -extract "actions.$intent.isDiscoverable" raw -o - "$INTENTS_METADATA")
  case "$DISCOVERABLE" in
    true) INTENTS_ADVERTISED=1 ;;
    false) ;;
    *) echo "error: could not verify App Intents availability for $intent." >&2; exit 1 ;;
  esac
done
AUTOSHORTCUTS=$(/usr/bin/plutil -extract autoShortcuts json -o - "$INTENTS_METADATA" | tr -d '[:space:]')
if [[ "$AUTOSHORTCUTS" != "[]" ]]; then INTENTS_ADVERTISED=1; fi
if [[ "$INTENTS_ADVERTISED" == "1" ]]; then
  SIGNING_TEAM=$(codesign -dv --verbose=4 "$BUILT_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  if [[ -z "$SIGNING_TEAM" || "$SIGNING_TEAM" == "not set" ]]; then
    echo "error: this build advertises Dictator App Intents but its signed app has no Team ID." >&2
    echo "  disable DICTATOR_ENABLE_APP_INTENTS, or plan a genuine Apple-team signing transition." >&2
    exit 1
  fi
  if ! codesign --verify --strict --test-requirement '=anchor apple generic' "$BUILT_APP"; then
    echo "error: App Intents were enabled without an Apple-validated signing identity." >&2
    exit 1
  fi
  echo "App Intents signing prerequisite verified for team $SIGNING_TEAM; native Shortcuts testing is still required."
else
  echo "Dictator actions in Apple Shortcuts are unavailable in this locally signed build."
fi

echo "BUILT_APP=$BUILT_APP"
