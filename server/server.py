"""FastAPI inference server.

POST /transcribe — accepts raw float32 PCM (16 kHz mono) over the
Tailnet, returns UTF-8 text or JSON when requested. Wires the two-stage Whisper + Gemma
polish adapter from `server.inference`. Nothing is loaded at startup:
`POST /warm` (the app calls it at hotkey press) loads the models in the
background while the user speaks, a request loads what's missing, and a
timer unloads Whisper after `DICTATION_IDLE_UNLOAD_S` of quiet.

See server/README.md for the endpoints and configuration.
"""
from __future__ import annotations

import asyncio
import base64
import hmac
import json
import logging
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

import httpx
import numpy as np
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, PlainTextResponse, Response

from server import inference


PORT = 7878
MAX_DURATION_S = 120
MIN_SAMPLE_RATE = 8000
MAX_SAMPLE_RATE = 48000

# JSONL telemetry. Per-request line on every successful
# /transcribe; rolling p50/p95/p99 over the last 100 inference_ms values
# emitted every 10th request so speed regressions are visible without
# offline analysis.
TELEMETRY_LOG_PATH = Path.home() / "Library" / "Logs" / "dictation-server.log"
ROLLING_WINDOW = 100
ROLLING_INTERVAL = 10
# Cached answer to "is Ollama reachable?" for /health, which the app polls
# every 20 s. Only /api/version is called: it never loads a model.
OLLAMA_CHECK_TTL_S = 30.0
_ollama_check: tuple[float, bool] = (0.0, False)
_ollama_check_lock = threading.Lock()

_telemetry_lock = threading.Lock()
_inference_window: deque[int] = deque(maxlen=ROLLING_WINDOW)
_request_counter = 0

# Tailscale assigns IPv4 from 100.64.0.0/10 (RFC 6598 CGNAT).
_TAILSCALE_CGNAT = re.compile(
    r"^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}$"
)

logger = logging.getLogger("dictation.server")


def _load_token() -> str:
    """Publish a complete owner-only key atomically, without replacing a winner."""
    path = Path(os.environ.get(
        "DICTATION_TOKEN_FILE",
        str(Path.home() / "Library" / "Application Support" / "Dictator" / "speech-server.token"),
    )).expanduser()
    try:
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd, temporary = tempfile.mkstemp(prefix=".speech-server-", dir=path.parent)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as stream:
                    stream.write(secrets.token_urlsafe(32))
                    stream.flush()
                    os.fsync(stream.fileno())
                try:
                    os.link(temporary, path)
                except FileExistsError:
                    pass  # Another startup published its complete key first.
            finally:
                os.unlink(temporary)
        token = path.read_text(encoding="utf-8").strip()
        if not token:
            raise ValueError("empty key")
        os.chmod(path, 0o600)
        return token
    except (OSError, UnicodeError, ValueError):
        raise RuntimeError(
            "The speech server could not read or create its key. Check DICTATION_TOKEN_FILE "
            "and its permissions; the key file must contain a key. Refusing to start."
        ) from None


@asynccontextmanager
async def _lifespan(app: FastAPI):
    app.state.speech_token = None
    app.state.speech_token = _load_token()
    try:
        yield
    finally:
        app.state.speech_token = None


def _authorized(request: Request) -> bool:
    token = getattr(request.app.state, "speech_token", None)
    supplied = request.headers.get("Authorization", "")
    return bool(token) and hmac.compare_digest(
        supplied.encode("utf-8"), f"Bearer {token}".encode("utf-8")
    )


async def _read_body(request: Request, limit: int) -> bytes:
    """The request body, stopping as soon as it passes `limit` bytes, so the
    frame count bounds memory rather than whatever the caller chooses to send."""
    body = bytearray()
    async for chunk in request.stream():
        body += chunk
        if len(body) > limit:
            break
    return bytes(body)


def _parse_languages_header(raw: str | None) -> tuple[str, ...] | None:
    """Optional per-request ISO language codes; omitted clients keep deployment defaults."""
    if raw is None:
        return None
    if len(raw) > 256:
        raise HTTPException(status_code=422, detail="Too many dictation languages.")
    codes = [code.strip().lower() for code in raw.split(",") if code.strip()]
    if len(codes) > 32 or any(not re.fullmatch(r"[a-z]{2,3}", code) for code in codes):
        raise HTTPException(status_code=422, detail="Use ISO language codes for dictation languages.")
    return tuple(dict.fromkeys(codes))


def _parse_dictionary_header(raw: str | None) -> list[dict[str, str]]:
    if not raw:
        return []
    # Clients base64-encode the JSON — raw JSON in a header arrives mangled
    # when entries contain non-ASCII (Hebrew patterns).
    try:
        payload = json.loads(base64.b64decode(raw, validate=True).decode("utf-8"))
    except (ValueError, RecursionError):  # invalid base64 (including non-ASCII), UTF-8 or JSON
        raise HTTPException(status_code=400, detail="X-Dictionary must be base64-encoded JSON")
    if not isinstance(payload, list):
        raise HTTPException(status_code=400, detail="X-Dictionary must be a list")

    dictionary: list[dict[str, str]] = []
    # A repository page is 200 entries; a dictionary can span many pages.
    # Keep the whole supplied dictionary instead of silently dropping rules.
    for item in payload:
        if not isinstance(item, dict):
            continue
        pattern = str(item.get("pattern", "")).strip()
        replacement = str(item.get("replacement", "")).strip()
        if pattern:
            dictionary.append({"pattern": pattern, "replacement": replacement})
    return dictionary


def _parse_vocabulary_hint_header(raw: str | None) -> list[str]:
    if not raw:
        return []
    try:
        payload = json.loads(base64.b64decode(raw, validate=True).decode("utf-8"))
    except (ValueError, RecursionError):  # invalid base64 (including non-ASCII), UTF-8 or JSON
        raise HTTPException(status_code=400, detail="X-Vocabulary-Hint must be base64-encoded JSON")
    if not isinstance(payload, dict) or not isinstance(payload.get("terms"), list):
        raise HTTPException(status_code=400, detail="X-Vocabulary-Hint must contain a terms list")
    if any(not isinstance(term, str) for term in payload["terms"]):
        raise HTTPException(status_code=400, detail="X-Vocabulary-Hint terms must be strings")
    return [term.strip() for term in payload["terms"] if term.strip()]


def _utc_iso8601() -> str:
    """RFC 3339 / ISO 8601 UTC timestamp with millisecond precision."""
    return (
        datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    )


def _append_jsonl(record: dict) -> None:
    line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
    TELEMETRY_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(TELEMETRY_LOG_PATH, "a", encoding="utf-8") as f:
        f.write(line + "\n")


# --- Take archive -----------------------------------------------------------
# The last `KEEP_TAKES` dictations are kept as 16 kHz WAV + a JSON sidecar
# (raw Whisper text, polished text, recogniser and level diagnostics) under
# `~/Library/Application Support/Dictator/Takes/`, owner-only. This is what
# makes "that one came out garbled" answerable after the fact — replay the
# audio, see whether Whisper fell back to sampling, see the input level —
# and it doubles as a dataset for evaluating recognisers on real speech.
# `DICTATION_KEEP_TAKES=0` disables it.
KEEP_TAKES = int(os.environ.get("DICTATION_KEEP_TAKES", "0"))
TAKES_DIR = Path(os.environ.get(
    "DICTATION_TAKES_DIR",
    str(Path.home() / "Library" / "Application Support" / "Dictator" / "Takes"),
))
_takes_lock = threading.Lock()


def _write_wav_16k(path: Path, audio: np.ndarray) -> None:
    import wave
    clipped = np.clip(audio, -1.0, 1.0)
    pcm = (clipped * 32767.0).astype("<i2").tobytes()
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(pcm)
    os.chmod(path, 0o600)


def _archive_take(audio: np.ndarray, sample_rate: int, detail: dict, request_info: dict) -> None:
    """Store one take and prune to `KEEP_TAKES`. Never raises."""
    if KEEP_TAKES <= 0:
        return
    try:
        with _takes_lock:
            TAKES_DIR.mkdir(parents=True, exist_ok=True)
            os.chmod(TAKES_DIR, 0o700)
            # Microseconds keep folder names ordered even for takes that land
            # within the same second; the random tail avoids collisions.
            stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
            folder = TAKES_DIR / f"{stamp}-{uuid.uuid4().hex[:6]}"
            folder.mkdir(mode=0o700)
            if sample_rate != 16000:
                audio = inference._resample_to_16k(audio, sample_rate)
            _write_wav_16k(folder / "audio.wav", audio)
            sidecar = {
                "ts": _utc_iso8601(),
                "duration_s": round(len(audio) / 16000, 3),
                "raw_transcript": detail.get("raw", ""),
                "text": detail.get("text", ""),
                "polished": detail.get("polished"),
                "polish_rejected": detail.get("rejected"),
                "asr": detail.get("asr"),
                "audio": detail.get("audio"),
                "request": request_info,
                "asr_model": inference.WHISPER_MLX_REPO,
                "polish_model": inference.polish_model(),
            }
            with open(folder / "take.json", "w", encoding="utf-8") as fh:
                json.dump(sidecar, fh, ensure_ascii=False, indent=2)
            os.chmod(folder / "take.json", 0o600)
            folders = sorted(p for p in TAKES_DIR.iterdir() if p.is_dir())
            for stale in folders[:-KEEP_TAKES] if len(folders) > KEEP_TAKES else []:
                shutil.rmtree(stale, ignore_errors=True)
    except Exception as exc:  # noqa: BLE001 — the archive must never break a dictation
        logger.warning("take archive failed: %s", exc)


def _record_telemetry(
    *,
    frame_count: int,
    duration_s: float,
    inference_ms: int,
    output_chars: int,
    diagnostics: dict | None = None,
) -> None:
    """Append the per-request JSONL line and, every ROLLING_INTERVAL
    requests, a rolling-stats line over the last ROLLING_WINDOW samples.

    Telemetry must never break the user's transcription. Disk failures
    are logged and swallowed.
    """
    global _request_counter
    with _telemetry_lock:
        _inference_window.append(inference_ms)
        _request_counter += 1
        emit_stats = _request_counter % ROLLING_INTERVAL == 0
        samples = list(_inference_window) if emit_stats else None

    try:
        _append_jsonl(
            {
                "ts": _utc_iso8601(),
                "frame_count": frame_count,
                "duration_s": round(duration_s, 3),
                "inference_ms": inference_ms,
                "output_chars": output_chars,
                "model": inference.polish_model(),
                **(diagnostics or {}),
            }
        )
        if samples:
            arr = np.asarray(samples, dtype=np.float64)
            _append_jsonl(
                {
                    "ts": _utc_iso8601(),
                    "type": "rolling_stats",
                    "n": len(samples),
                    "p50": int(round(float(np.percentile(arr, 50)))),
                    "p95": int(round(float(np.percentile(arr, 95)))),
                    "p99": int(round(float(np.percentile(arr, 99)))),
                }
            )
    except OSError as exc:
        logger.warning("telemetry write failed: %s", exc)


def resolve_tailscale_ip() -> str | None:
    """Return this host's Tailscale IPv4 address, or None if not joined.

    Prefers the `tailscale` CLI (definitive). Falls back to ifconfig
    parsing if the CLI is unavailable so launchd is not coupled to
    Homebrew's PATH.
    """
    for tailscale_bin in ("/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"):
        try:
            result = subprocess.run(
                [tailscale_bin, "ip", "-4"],
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                ip = line.strip()
                if _TAILSCALE_CGNAT.match(ip):
                    return ip

    try:
        result = subprocess.run(
            ["/sbin/ifconfig"], capture_output=True, text=True, timeout=5
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    for raw in result.stdout.splitlines():
        line = raw.strip()
        if line.startswith("inet "):
            ip = line.split()[1]
            if _TAILSCALE_CGNAT.match(ip):
                return ip
    return None


app = FastAPI(lifespan=_lifespan)
_execution_lock = threading.Lock()


def _ollama_reachable() -> bool:
    global _ollama_check
    with _ollama_check_lock:
        checked_at, ok = _ollama_check
        if time.monotonic() - checked_at < OLLAMA_CHECK_TTL_S and checked_at:
            return ok
        try:
            ok = httpx.get(f"{inference.OLLAMA_URL}/api/version", timeout=2.0).status_code == 200
        except httpx.HTTPError:
            ok = False
        _ollama_check = (time.monotonic(), ok)
        return ok


@app.get("/health")
def health():
    """Never loads a model and never counts as activity. Models unloaded but
    loadable is `ok`; only an unreachable Ollama makes it not ok."""
    state = inference.readiness()
    reachable = _ollama_reachable()
    return {"status": "ok" if reachable else "ollama_unavailable", "ollama_reachable": reachable, **state}


@app.post("/warm")
async def warm(request: Request):
    """Prepare for a dictation. The client calls this at hotkey *press* (fire
    and forget); Whisper always, and the clean-up model unless
    `X-Refine-Level: exact`, start loading in the background while the user
    speaks. Returns at once with what is resident or loading, and counts as
    activity. A missing header means clean-up is needed."""
    if not _authorized(request):
        return Response(status_code=401)
    level = (request.headers.get("X-Refine-Level") or "medium").strip().lower()
    state = inference.prepare(polish=level != "exact")
    return {"status": "ok", **state}


def _execute(audio, sample_rate, dictionary, refine_level, languages=None, vocabulary_hint=None):
    # A canceled HTTP client does not cancel its worker thread. Keep the lease
    # until inference actually ends.
    _execution_lock.acquire()
    try:
        with inference.language_scope(languages):
            detail = inference.transcribe_detailed(audio, sample_rate, dictionary=dictionary,
                                                   polish=refine_level != "exact",
                                                   level=refine_level,
                                                   **({"vocabulary_hint": vocabulary_hint} if vocabulary_hint else {}))
            _archive_take(audio, sample_rate, detail, {"refine_level": refine_level, "sample_rate": sample_rate})
            return detail
    finally:
        _execution_lock.release()


@app.post("/transcribe")
async def transcribe(request: Request) -> Response:
    if not _authorized(request):
        return Response(status_code=401)
    sr_raw = request.headers.get("X-Sample-Rate")
    fc_raw = request.headers.get("X-Frame-Count")
    if sr_raw is None or fc_raw is None:
        raise HTTPException(
            status_code=400, detail="missing X-Sample-Rate or X-Frame-Count"
        )
    try:
        sample_rate = int(sr_raw)
    except ValueError:
        raise HTTPException(status_code=400, detail="X-Sample-Rate must be an integer")
    if not (MIN_SAMPLE_RATE <= sample_rate <= MAX_SAMPLE_RATE):
        raise HTTPException(
            status_code=400,
            detail=f"X-Sample-Rate out of range [{MIN_SAMPLE_RATE},{MAX_SAMPLE_RATE}]",
        )
    try:
        frame_count = int(fc_raw)
    except ValueError:
        raise HTTPException(status_code=400, detail="X-Frame-Count must be an integer")
    if frame_count <= 0:
        raise HTTPException(status_code=400, detail="X-Frame-Count must be > 0")

    # Duration check fires on headers alone, before reading the body.
    # Otherwise an over-limit payload returns 400 (length-mismatch) when the
    # caller sends short junk, masking the real failure mode.
    # Whole numbers only: an arbitrarily long header overflows a float.
    if frame_count > MAX_DURATION_S * sample_rate:
        raise HTTPException(status_code=413, detail=f"audio length > {MAX_DURATION_S} seconds")

    expected = frame_count * 4
    body = await _read_body(request, expected)
    if len(body) != expected:
        raise HTTPException(
            status_code=400,
            detail=f"body length {len(body)} != X-Frame-Count*4 ({expected})",
        )

    # Little-endian float32 PCM (M-series macOS is LE so this
    # is also the native byte order; explicit dtype guards against future
    # cross-arch clients). `.copy()` makes the array writable in case
    # mlx-whisper mutates it; `frombuffer` returns a read-only view.
    audio = np.frombuffer(body, dtype="<f4").copy()
    if not np.isfinite(audio).all():
        raise HTTPException(status_code=422, detail="Audio must contain finite samples.")

    dictionary = _parse_dictionary_header(request.headers.get("X-Dictionary"))
    vocabulary_hint = _parse_vocabulary_hint_header(request.headers.get("X-Vocabulary-Hint"))

    # "exact" skips the Ollama polish stage — raw Whisper + dictionary only.
    refine_level = (request.headers.get("X-Refine-Level") or "medium").strip().lower()

    t0 = time.perf_counter()
    detail = await asyncio.to_thread(
        _execute,
        audio,
        sample_rate,
        dictionary, refine_level,
        _parse_languages_header(request.headers.get("X-Dictation-Languages")),
        vocabulary_hint,
    )
    inference_ms = int(round((time.perf_counter() - t0) * 1000))

    text = detail["text"]
    diagnostics = None
    extra_headers = {}
    if detail:
        asr, levels = detail.get("asr") or {}, detail.get("audio") or {}
        diagnostics = {
            "raw_chars": len(detail.get("raw", "")),
            "polish_rejected": bool(detail.get("rejected")),
            "asr_language": asr.get("language"),
            "asr_temperature": asr.get("temperature"),
            "asr_min_avg_logprob": asr.get("min_avg_logprob"),
            "asr_max_no_speech_prob": asr.get("max_no_speech_prob"),
            "rms_dbfs": levels.get("rms_dbfs"),
            "peak_dbfs": levels.get("peak_dbfs"),
            "clipped_ratio": levels.get("clipped_ratio"),
        }
        if "vocabulary_hint_terms" in asr:
            diagnostics["vocabulary_hint_terms"] = asr["vocabulary_hint_terms"]
        if detail.get("polish") is not None:
            diagnostics["polish"] = detail["polish"]
        if detail.get("polish") is not None:
            extra_headers["X-Polish"] = str(detail["polish"])
            extra_headers["X-Polish-Level"] = refine_level
        if detail.get("polish_ms") is not None:
            extra_headers["X-Polish-Ms"] = str(detail["polish_ms"])
    _record_telemetry(
        frame_count=frame_count,
        duration_s=frame_count / sample_rate,
        inference_ms=inference_ms,
        output_chars=len(text),
        diagnostics=diagnostics,
    )

    # Existing clients keep their plain-text response. New clients request
    # JSON so they can retain the recognizer's words before replacements.
    if "application/json" in request.headers.get("Accept", ""):
        return JSONResponse({"text": text, "raw": detail.get("raw") if detail else None},
                            headers={"X-Inference-Ms": str(inference_ms), **extra_headers})
    return PlainTextResponse(
        text,
        headers={"X-Inference-Ms": str(inference_ms),
                 **extra_headers},
    )


def _idle_loop() -> None:
    """Background thread: unloads Whisper once dictation has been quiet for
    `IDLE_UNLOAD_S`. Only compares timestamps; it never runs inference and
    never touches the execution lock."""
    interval = max(1.0, min(30.0, inference.IDLE_UNLOAD_S / 4))
    while True:
        time.sleep(interval)
        try:
            inference.unload_if_idle()
        except Exception:
            logger.exception("idle unload failed")


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout,
    )
    ip = resolve_tailscale_ip()
    if ip is None:
        logger.error(
            "No Tailscale interface found (no 100.64.0.0/10 IPv4). "
            "Run `tailscale up` and re-launch. Exiting."
        )
        sys.exit(1)

    # Nothing is loaded here: the server binds at once and the models load
    # on /warm or on the first request, then unload after IDLE_UNLOAD_S.
    inference._configure_mlx()
    threading.Thread(target=_idle_loop, daemon=True, name="idle-unload").start()
    logger.info("Models load on demand and unload after %.0fs idle", inference.IDLE_UNLOAD_S)

    logger.info("Binding to Tailscale IP %s:%d", ip, PORT)
    uvicorn.run(app, host=ip, port=PORT, log_level="info")


if __name__ == "__main__":
    main()
