# Speech server

A Python service that turns recordings into text on one Mac: Whisper (through MLX) for speech to text, then a clean-up model through the local Ollama. The Mac app sends it audio and pastes what comes back.

The models are in memory only while dictation needs them. The server starts with nothing loaded, the app's `POST /warm` at key press loads them while you speak, and they unload after five quiet minutes (`DICTATION_IDLE_UNLOAD_S`). A dictation after a long idle still works without `/warm`; it just waits for the load (about a second longer).

If Ollama is busy loading the clean-up model, speech recognition still returns the words: the server waits at most five seconds for clean-up to become ready, then sends the Whisper transcript with dictionary replacements. A later dictation can use clean-up once the model is ready. The response's `X-Polish: unavailable` header and server log identify this fallback.

It's one of the places Dictator can turn speech into text. Speech models can also run inside the app on any Mac (see [docs/architecture.md](../docs/architecture.md)); Settings › Your Macs sets the order in which they're tried.

## Endpoints

It listens only on the Mac's Tailscale address, port 7878, and refuses to start without one.

`POST /transcribe` and `POST /warm` require `Authorization: Bearer <key>`; a missing or wrong key returns an empty 401 response before any audio is processed or models are prepared. `GET /health` stays open for reachability checks and never exposes the key.

At startup the server reads `DICTATION_TOKEN_FILE`, defaulting to `~/Library/Application Support/Dictator/speech-server.token`. If missing, it atomically creates a random key with owner-only permissions (0600). An unreadable or empty key file prevents startup; the server never runs without authentication. The key is never logged.

The app only reads that server-owned file; it never creates or overwrites it. A pasted key in Settings › Advanced › Speech server key is saved separately as `~/Library/Application Support/Dictator/speech-server-remote.token`, atomically with owner-only permissions (0600). Neither key is mirrored, logged, saved in history or put in `UserDefaults`. No migration is needed because pasted keys have not shipped yet.

For each request, the app chooses the key using the request host. Loopback and this Mac’s own interface addresses (from `getifaddrs`, including its Tailscale address) use `speech-server.token` only. For any other host it uses `speech-server-remote.token`, falling back to `speech-server.token` when no remote key is saved. Thus `http://100.101.102.103:7878` uses the local server key on the Mac that owns that address. If you override `DICTATION_TOKEN_FILE`, the app must use the same environment override to read the local server key. All remote servers, including backups, must accept the same pasted remote key.

When using a server on another Mac, paste its key on each Mac that sends requests, including the main Mac and any Mac doing direct recovery. Live dictation from a connected Mac is sent by the main Mac, so its key alert names the main Mac and has no button that opens the connected Mac’s settings. Direct recovery on a connected Mac keeps its local settings button.

Removing a Mac in Settings › Your Macs rotates Dictator’s **pairing** token. It does not change the speech server key. A removed or lost Mac may still have a copied key and be able to call the speech server directly, even when that server runs on the main Mac or is configured through loopback. The removal confirmation warns whenever a speech server address is configured.

To change the speech server key:

1. On the server’s Mac, delete its key file: `DICTATION_TOKEN_FILE`, or `~/Library/Application Support/Dictator/speech-server.token` by default.
2. Restart the existing managed speech server with `launchctl bootout` followed by `launchctl bootstrap`. Startup creates a fresh random 0600 key. Do not start a second server by hand.
3. On the server’s Mac, use Settings › Advanced › Copy Key, then paste it in Settings › Advanced › Speech server key on any other Mac that needs it, including the main Mac when it sends requests to another Mac. Connected Macs need it only to reach the server while their main Mac is away; a recording they retry while connected falls back to the main Mac. If the server’s Mac doesn’t run the app, copy the key from its key file. The server’s own Mac reads its new local key automatically.

Backups that use the remote key must accept the same replacement. Keep it private; do not give it to the removed Mac or put it in logs, history or shared settings. Saved history is unchanged.

The app allows `https://` speech addresses with any host. With `http://`, it accepts only loopback, Tailscale IPv4 (`100.64.0.0/10`), Tailscale IPv6 (`fd7a:115c:a1e0::/48`) and names ending in `.ts.net`. For another address, use HTTPS or change it to the server's Tailscale address in Settings › Advanced. Redirects are refused, so neither audio nor the key follows them. A missing key or refused saved address is explained when dictation fails, with the recording kept for recovery; a working backup can still provide text.

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

**Upgrade order: install the updated app first on every Mac that sends speech requests, then restart the server.** The updated app still works with older servers that ignore the header. After the updated server starts, same-Mac requests pick up its key automatically; add the key in Advanced on other requesting Macs before using it there. Older apps cannot authenticate to the updated server. No existing take archive is deleted by this upgrade.

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
