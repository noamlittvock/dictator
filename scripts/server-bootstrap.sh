#!/usr/bin/env bash
# Provision the dictation server's Python env, ASR model cache, and Ollama
# polish model on the Mac that runs the speech server. Idempotent: each step is
# skipped when it's already satisfied, so re-running is safe.
#
# This is an explicit deployment operation, never routine maintenance — per
# AGENTS.md, installer/microphone/model/live-service operations must not be
# run as part of routine maintenance. Run this only when deliberately
# (re-)provisioning the speech server, and only on the Mac that runs it.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$PROJECT_DIR/server"
VENV_DIR="$SERVER_DIR/.venv"
PYTHON_BIN="${DICTATION_PYTHON:-/opt/homebrew/bin/python3.13}"
ASR_MODEL="${DICTATION_ASR_MODEL:-mlx-community/whisper-small-mlx}"
OLLAMA_URL="${DICTATION_OLLAMA_URL:-http://127.0.0.1:11434}"
POLISH_MODEL="${DICTATION_POLISH_MODEL:-gemma4:e2b-it-qat}"

NO_MODELS=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --no-models) NO_MODELS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      echo "usage: $(basename "$0") [--no-models] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

# Print then, unless --dry-run, run. Used for every step below so --dry-run
# shows the exact commands without touching the machine.
run() {
  echo "+ $*"
  if [[ "$DRY_RUN" == "0" ]]; then
    "$@"
  fi
}

echo "== venv =="
if [[ -x "$VENV_DIR/bin/python" ]]; then
  echo "venv already present at $VENV_DIR"
else
  echo "+ $PYTHON_BIN -m venv $VENV_DIR"
  if [[ "$DRY_RUN" == "0" ]]; then
    if [[ ! -x "$PYTHON_BIN" ]]; then
      echo "error: python not found at $PYTHON_BIN (set DICTATION_PYTHON)" >&2
      exit 1
    fi
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
fi
run "$VENV_DIR/bin/pip" install --upgrade pip
run "$VENV_DIR/bin/pip" install -r "$SERVER_DIR/pinned-versions.txt"

if [[ "$NO_MODELS" == "1" ]]; then
  echo "== models =="
  echo "skipping (--no-models)"
else
  echo "== asr model =="
  # Synthetic audio only (a second of silence) — this just forces mlx-whisper
  # to resolve and cache path_or_hf_repo; it must never touch a mic or real
  # recording (AGENTS.md: tests/tooling use synthetic audio only).
  PY_CODE=$(cat <<PYEOF
import numpy as np, mlx_whisper
mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo="$ASR_MODEL")
PYEOF
)
  run "$VENV_DIR/bin/python" -c "$PY_CODE"

  echo "== ollama polish model =="
  if [[ "$DRY_RUN" == "1" ]]; then
    # --dry-run touches nothing live, including the read-only daemon probe.
    echo "+ locate ollama binary (PATH, /usr/local/bin, /opt/homebrew/bin, app bundle)"
    echo "+ curl $OLLAMA_URL/api/tags"
    echo "+ ollama pull $POLISH_MODEL (skipped if already listed)"
  else
    # Locate the ollama binary the way the app does: PATH, then a fixed
    # set of well-known install locations.
    # An explicit OLLAMA=/path override wins; otherwise PATH, then the
    # well-known locations.
    OLLAMA="${OLLAMA:-$(command -v ollama || true)}"
    for c in /usr/local/bin/ollama /opt/homebrew/bin/ollama /Applications/Ollama.app/Contents/Resources/ollama; do
      [[ -z "$OLLAMA" && -x "$c" ]] && OLLAMA="$c"
    done
    if [[ -z "$OLLAMA" ]]; then
      echo "error: could not find the ollama binary. Set OLLAMA=/path/to/ollama and retry." >&2
      exit 1
    fi
    echo "• ollama: $OLLAMA"

    if ! TAGS_JSON=$(curl -sS -m 3 "$OLLAMA_URL/api/tags" 2>&1); then
      echo "error: ollama daemon not responding at $OLLAMA_URL — start it first." >&2
      echo "  $TAGS_JSON" >&2
      exit 1
    fi
    if grep -qF "\"$POLISH_MODEL\"" <<<"$TAGS_JSON"; then
      echo "model $POLISH_MODEL already pulled"
    else
      run "$OLLAMA" pull "$POLISH_MODEL"
    fi
  fi
fi

echo "== summary =="
echo "venv:      $VENV_DIR"
if [[ "$NO_MODELS" == "1" ]]; then
  echo "asr model: $ASR_MODEL (skipped, --no-models)"
  echo "polish:    $POLISH_MODEL via $OLLAMA_URL (skipped, --no-models)"
else
  echo "asr model: $ASR_MODEL"
  echo "polish:    $POLISH_MODEL via $OLLAMA_URL"
fi
echo
echo "to (re)load the server LaunchAgent, run (not run by this script):"
echo "  launchctl bootout gui/$(id -u)/dev.noamlitt.dictation.server"
echo "  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.noamlitt.dictation.server.plist"
