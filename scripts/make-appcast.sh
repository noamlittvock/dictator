#!/bin/bash
# Generate locally; uploading the zip and appcast is a separate release step.
set -euo pipefail

usage() {
    echo "Usage: $0 NOTARIZED_ZIP RELEASE_TAG [OUTPUT_DIRECTORY]" >&2
    echo "Set SPARKLE_GENERATE_APPCAST to Sparkle's generate_appcast executable." >&2
}
fail() { echo "Error: $*" >&2; exit 1; }

if [[ $# -lt 2 || $# -gt 3 ]]; then usage; exit 2; fi
[[ -f "$1" && "$1" == *.zip ]] || fail "Expected an existing notarized .zip release archive."
[[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "Release tag may contain only letters, numbers, dots, underscores and hyphens."
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
tag="$2"
output="${3:-$(dirname "$archive")}"
[[ -d "$output" ]] || fail "Output directory must already exist."
output="$(cd "$output" && pwd)"
[[ ! -e "$output/appcast.xml" ]] || fail "Output appcast.xml already exists; choose an empty output directory."
generator="${SPARKLE_GENERATE_APPCAST:-generate_appcast}"
command -v "$generator" >/dev/null 2>&1 || fail "Cannot find Sparkle generate_appcast; set SPARKLE_GENERATE_APPCAST."

# Inspect only the bundle metadata, without extracting or executing the app.
minimum="$(python3 - "$archive" <<'PY'
import plistlib
import re
import sys
import zipfile

try:
    with zipfile.ZipFile(sys.argv[1]) as archive:
        candidates = [name for name in archive.namelist()
                      if re.fullmatch(r'[^/]+\.app/Contents/Info\.plist', name)]
        if len(candidates) != 1:
            raise ValueError('Release zip must contain exactly one top-level app.')
        info = plistlib.loads(archive.read(candidates[0]))
    minimum = info.get('LSMinimumSystemVersion', '')
    if not isinstance(minimum, str) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', minimum):
        raise ValueError('App must specify a resolved LSMinimumSystemVersion.')
    if not info.get('CFBundleVersion'):
        raise ValueError('App must specify CFBundleVersion.')
    key = info.get('SUPublicEDKey', '').strip()
    if not key or '$(' in key:
        raise ValueError('App must contain its configured Sparkle public key.')
    print(minimum)
except (OSError, ValueError, TypeError, AttributeError, zipfile.BadZipFile) as error:
    sys.exit(f'Error: {error}')
PY
)"

# A hard link stages the single archive without copying a large release zip.
# Keep staging beside the original so the link stays on the same filesystem.
staging="$(mktemp -d "$(dirname "$archive")/.appcast.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ln "$archive" "$staging/$(basename "$archive")"
"$generator" --account dictator \
    --download-url-prefix "https://github.com/noamlittvock/dictator/releases/download/$tag/" \
    --maximum-deltas 0 "$staging"

# generate_appcast derives minimumSystemVersion from the app. Fail rather than
# modifying a generated feed, which may itself carry a Sparkle signature.
python3 - "$staging/appcast.xml" "$minimum" "$tag" "$(basename "$archive")" <<'PY'
import sys
import urllib.parse
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
    ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    items = root.findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one release in the generated appcast.')
    item = items[0]
    if item.findtext(ns + 'minimumSystemVersion') != sys.argv[2]:
        raise ValueError('Generated minimumSystemVersion does not match the app.')
    enclosure = item.find('enclosure')
    if enclosure is None or not enclosure.get(ns + 'edSignature'):
        raise ValueError('Generated appcast has no EdDSA signature; check the release keychain.')
    expected = f'https://github.com/noamlittvock/dictator/releases/download/{sys.argv[3]}/{sys.argv[4]}'
    if urllib.parse.unquote(enclosure.get('url', '')) != expected:
        raise ValueError('Generated download URL does not match the release archive.')
except (OSError, ValueError, ET.ParseError) as error:
    sys.exit(f'Error: {error}')
PY
mv "$staging/appcast.xml" "$output/appcast.xml"
echo "Created $output/appcast.xml (nothing uploaded)."
