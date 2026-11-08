#!/usr/bin/env bash
# Build, sign, and install Dictator.app in one shot.
#
# Thin wrapper around build-sign.sh (build+sign; needs Xcode and the
# "Dictator Local Code Signing" identity) and install-app.sh (install+launch;
# needs neither). Extra arguments (e.g. --no-launch) are forwarded to
# install-app.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Stream build-sign.sh's own output live (identical to the old one-shot
# script) while also capturing it, so we can pull the BUILT_APP=<path> line
# it prints last without asking it to build twice.
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT
"$SCRIPT_DIR/build-sign.sh" | tee "$BUILD_LOG"

BUILT_APP="$(grep '^BUILT_APP=' "$BUILD_LOG" | tail -1 | sed 's/^BUILT_APP=//')"
if [[ -z "$BUILT_APP" ]]; then
  echo "error: build-sign.sh did not print a BUILT_APP=<path> line" >&2
  exit 1
fi

# Not exec: a successful exec would replace this shell and skip the EXIT trap,
# leaking $BUILD_LOG on every good run.
"$SCRIPT_DIR/install-app.sh" "$BUILT_APP" "$@"
