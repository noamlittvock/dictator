# Speech server

Optional Python inference service for Dictator: Whisper through MLX, then clean-up through local Ollama. Models can also [run inside the app](../docs/architecture-dictation.md), so you don't need this server for a single-Mac setup.

The server binds only to its Mac's Tailscale address on port 7878. It starts with models unloaded, warms them at key press and unloads after five idle minutes. If clean-up can't become ready within five seconds, it returns the transcript with dictionary replacements (`X-Polish: unavailable`).

[Setup](#running-it) · [API](#endpoints) · [Configuration](#configuration) · [Tests](#tests)

## Endpoints

It listens only on the Mac's Tailscale address, port 7878, and refuses to start without one.

`POST /transcribe` and `POST /warm` require `Authorization: Bearer <key>`. A wrong or missing key returns an empty 401 before processing. `GET /health` needs no key and never reveals it.

### Keys

Startup reads `DICTATION_TOKEN_FILE`, defaulting to `~/Library/Application Support/Dictator/speech-server.token`. A missing file is created atomically with a random key and 0600 permissions. Empty or unreadable files prevent startup.

The app reads that local file without overwriting it. A key pasted in **Settings › Advanced › Speech server key** is saved separately in `speech-server-remote.token` with 0600 permissions. Keys never enter logs, history, UserDefaults or shared settings.

Requests to loopback or this Mac's own interface addresses use the local key only. Other hosts use the pasted remote key, falling back to the local key. If you override `DICTATION_TOKEN_FILE`, give the app the same override. Remote backup servers must accept the same remote key.

Live dictation from connected Macs is sent by the main Mac, so configure its key too. Connected Macs need a key for direct recovery when the main Mac is away.

### Rotate a key

Removing a Mac rotates its pairing credential, **not this speech-server key**. A removed Mac with a copied key can still call the server. To revoke it:

1. Delete the server's key file on the server Mac.
2. Restart the managed server with `launchctl bootout`, then `launchctl bootstrap`. It creates a fresh key. Never start a second copy by hand.
3. Use **Settings › Advanced › Copy Key** on that Mac and paste it into the requesting Macs' Speech server key setting. Without the app, read the server's key file privately.
4. Update remote backups to accept the replacement. Don't give it to the removed Mac.

The server Mac reads its new local key automatically. Saved history is unchanged.

### Addresses

HTTPS accepts any host. HTTP accepts only loopback, Tailscale IPv4 (`100.64.0.0/10`), Tailscale IPv6 (`fd7a:115c:a1e0::/48`) and `.ts.net` names. Redirects are refused. Missing keys and invalid addresses produce an explained failure with recovery audio retained; configured backups can still supply text.

### Requests

| Endpoint | What it does |
|---|---|
| `POST /transcribe` | Body: 16 kHz mono float32 little-endian PCM (up to 120 s). Headers: `X-Sample-Rate`, `X-Frame-Count`, optional `X-Refine-Level` (`exact` skips clean-up, `strong` polishes, anything else is ordinary clean-up), `X-Dictation-Languages` (comma-separated ISO codes; empty means automatic; omitted keeps the deployment default), `X-Dictionary` (base64 JSON list of `{pattern, replacement}`), `X-Vocabulary-Hint` (base64 JSON object `{"terms": ["word"]}` for recognition). Returns plain UTF-8 by default, or `{"text": "…", "raw": "…"}` when `Accept: application/json` is sent, with timing in `X-Inference-Ms`. After clean-up, `X-Polish` says what happened (`polished`, `fallback` when a rejected polish was replaced by ordinary clean-up, `rejected`, `unavailable` or `raw`), `X-Polish-Level` echoes the level and `X-Polish-Ms` gives the time. |
| `GET /health` | `status` is `ok` whenever the server can do a dictation, including with no model loaded; it is `ollama_unavailable` when Ollama can't be reached (checked at most every 30 s). Also the speech model, the clean-up model actually in use, the Ollama address, and what is in memory now (`asr_loaded`, `polish_loaded`, `*_loading`). It never loads a model or counts as activity. The app checks it every 20 seconds. |
| `POST /warm` | Optional `X-Refine-Level` (a missing header means clean-up is needed). Returns at once, and starts loading Whisper, plus the clean-up model unless the level is `exact`, in the background. Counts as activity. The app calls it when the key goes down. |

## Configuration

Environment variables, set in the LaunchAgent:

| Variable | Default | Meaning |
|---|---|---|
| `DICTATION_ASR_MODEL` | `mlx-community/whisper-small-mlx` | Whisper model. |
| `DICTATION_LANGUAGES` | `en,he` | Default languages Whisper may choose among when a request omits `X-Dictation-Languages` (comma-separated ISO codes; empty = any). |
| `DICTATION_OLLAMA_URL` | `http://127.0.0.1:11434` | Ollama for clean-up. |
| `DICTATION_POLISH_MODEL` | `gemma4:e2b-it-qat` | Clean-up model. |
| `DICTATION_IDLE_UNLOAD_S` | `300` | Seconds without a dictation or `/warm` before the models unload. Whisper is dropped by the server; the clean-up model by Ollama, which is sent this as its `keep_alive` on every call. |
| `DICTATION_TEXT_ONLY_POLISH` | `1` | With a local Ollama, use a text-only copy of the clean-up model when it has an image/audio projector (see below). `0` uses the model as configured. |
| `DICTATION_KEEP_TAKES` | `0` | Keeps no new audio or text by default. Above `0`, stores recent audio and text (WAV plus JSON, in `~/Library/Application Support/Dictator/Takes`) regardless of the app's history setting. Existing takes are left alone when disabled. |
| `DICTATION_TOKEN_FILE` | `~/Library/Application Support/Dictator/speech-server.token` | Local key file for `/transcribe` and `/warm`; created 0600 if missing. Empty or unreadable files prevent startup. |

Memory: MLX's cache of freed buffers is capped at 64 MB and cleared after every transcription (uncapped it grew to several GB for a 459 MB model, with no speed gain). If the clean-up model carries a vision/audio projector (`gemma4:e2b-it-qat` does, about 1 GB that clean-up never uses), the first load derives `<model>-text` from it with `ollama create`: the same weights minus the projector, so nothing is downloaded or copied. It is used only after `/api/show` confirms it lacks vision and audio; on any failure the configured model is used. `/health` reports the model in use as `polish_model`.

The clean-up prompt, explicit command preparation, and the check that the model preserved the transcript instead of answering are in `inference.py`. The Mac app has a verbatim copy in `CleanupPrompt.swift` for clean-up that runs elsewhere; change both together.

## Running it

It runs under the LaunchAgent `dev.noamlitt.dictation.server`. `launchd/dictation-server.plist.template` has the definition; fill in its `__REPO__` and `__HOME__` placeholders (the comment at its top shows the `sed` line) before installing.

**Upgrade order: install the updated app first on every Mac that sends speech requests, then restart the server.** Apps that send no key cannot authenticate. Same-Mac requests read the key automatically; configure it in Advanced on other requesting Macs.

```bash
scripts/server-bootstrap.sh --dry-run   # show the setup steps
scripts/server-bootstrap.sh             # Python environment, Whisper model, clean-up model
launchctl bootout gui/$(id -u)/dev.noamlitt.dictation.server
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.noamlitt.dictation.server.plist
```

Setting up, restarting and downloading models are deliberate deployment steps. Manage the service only through `launchctl`, and never start a second copy by hand.

## Tests

```bash
.venv/bin/python -m pytest tests --ignore=tests/test_quality_golden.py
```

`test_quality_golden.py` runs the real models against `shared/golden-audio` and needs `jiwer`.
