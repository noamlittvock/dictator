"""Load-on-demand contract: prepare, transcribe-waits, idle unload, text-only
clean-up model. mlx-whisper and Ollama are faked; no real model or service is used."""
from __future__ import annotations

import sys
import threading
import time

import numpy as np
import pytest
from fastapi.testclient import TestClient

from server import inference
from server import server as api


class FakeWhisper:
    """Stands in for the mlx_whisper module; a load is the warm-up transcribe."""

    def __init__(self, gate: threading.Event | None = None) -> None:
        self.gate, self.loads, self.decodes = gate, 0, 0
        self.load_started = threading.Event()

    def transcribe(self, audio, **kwargs):
        if len(audio) == 16000 and not np.any(audio):
            self.loads += 1
            self.load_started.set()
            if self.gate:
                self.gate.wait(5)
        else:
            self.decodes += 1
        return {"text": " hello there", "segments": [], "language": "en"}


class FakeOllama:
    def __init__(self, gate: threading.Event | None = None) -> None:
        self.gate, self.loads, self.chats, self.keep_alives = gate, 0, 0, []
        self.load_started = threading.Event()

    def load(self):
        self.loads += 1
        self.load_started.set()
        if self.gate:
            self.gate.wait(5)
        inference._polish_expires = time.monotonic() + inference.IDLE_UNLOAD_S

    def chat(self, messages, max_tokens):
        self.chats += 1
        return "Hello there."


@pytest.fixture
def whisper(monkeypatch):
    fake = FakeWhisper()
    monkeypatch.setitem(sys.modules, "mlx_whisper", fake)
    monkeypatch.setattr(inference, "choose_language", lambda audio, path: ("en", {}))
    return fake


@pytest.fixture
def ollama(monkeypatch):
    fake = FakeOllama()
    monkeypatch.setattr(inference, "_resolve_polish_model", lambda: None)
    monkeypatch.setattr(inference, "_ollama_load", fake.load)
    monkeypatch.setattr(inference, "_ollama_chat", fake.chat)
    return fake


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(api, "_record_telemetry", lambda **kwargs: None)
    monkeypatch.setattr(api, "KEEP_TAKES", 0)
    return TestClient(api.app, headers={"Authorization": "Bearer synthetic-speech-key"})


def _join_loaders():
    for thread in list(inference._loaders.values()):
        thread.join(5)


def _audio_request(client, level=None):
    audio = (np.ones(16000, dtype="<f4") * 0.1).tobytes()
    headers = {"X-Sample-Rate": "16000", "X-Frame-Count": "16000"}
    if level:
        headers["X-Refine-Level"] = level
    return client.post("/transcribe", content=audio, headers=headers)


# --- prepare ---------------------------------------------------------------

def test_startup_loads_nothing(whisper, ollama):
    assert whisper.loads == 0 and ollama.loads == 0
    assert not hasattr(api, "_warm_loop") and not hasattr(inference, "warm_touch")


def test_warm_loads_both_in_background_and_returns_at_once(client, whisper, ollama):
    gate = threading.Event()
    whisper.gate = ollama.gate = gate
    t0 = time.perf_counter()
    response = client.post("/warm")
    assert time.perf_counter() - t0 < 1.0
    assert response.json()["status"] == "ok"
    assert whisper.load_started.wait(5) and ollama.load_started.wait(5)
    assert response.json()["asr_loaded"] is False
    gate.set()
    _join_loaders()
    assert (whisper.loads, ollama.loads) == (1, 1)
    assert inference.residency()["asr_loaded"] and inference.residency()["polish_loaded"]


def test_warm_exact_never_loads_the_cleanup_model(client, whisper, ollama):
    client.post("/warm", headers={"X-Refine-Level": "exact"})
    _join_loaders()
    assert whisper.loads == 1 and ollama.loads == 0


def test_warm_without_header_prepares_cleanup(client, whisper, ollama):
    client.post("/warm")
    _join_loaders()
    assert ollama.loads == 1


def test_duplicate_prepares_do_not_double_load(client, whisper, ollama):
    gate = threading.Event()
    whisper.gate = ollama.gate = gate
    for _ in range(4):
        client.post("/warm")
    gate.set()
    _join_loaders()
    assert (whisper.loads, ollama.loads) == (1, 1)


def test_prepare_does_not_hold_the_execution_lock(client, whisper, ollama):
    whisper.gate = threading.Event()
    client.post("/warm")
    whisper.load_started.wait(5)
    assert api._execution_lock.acquire(blocking=False)
    api._execution_lock.release()
    whisper.gate.set()
    _join_loaders()


def test_prepare_counts_as_activity(client, whisper, ollama, monkeypatch):
    monkeypatch.setattr(inference, "_last_activity", 0.0)
    client.post("/warm")
    assert inference.idle_seconds() < 5
    _join_loaders()


# --- transcribe ------------------------------------------------------------

def test_exact_transcribe_never_loads_the_cleanup_model(client, whisper, ollama):
    response = _audio_request(client, "exact")
    assert response.status_code == 200 and response.text == "hello there"
    time.sleep(0.05)
    assert ollama.loads == 0 and ollama.chats == 0


def test_transcribe_loads_what_is_missing(client, whisper, ollama):
    response = _audio_request(client)
    assert response.text == "Hello there."
    _join_loaders()
    assert whisper.loads == 1 and whisper.decodes == 1 and ollama.loads == 1


def test_transcribe_waits_for_an_in_progress_load_instead_of_starting_another(client, whisper, ollama):
    gate = threading.Event()
    whisper.gate = gate
    client.post("/warm")
    assert whisper.load_started.wait(5)
    threading.Timer(0.3, gate.set).start()
    response = _audio_request(client)  # arrives while Whisper is still loading
    assert response.status_code == 200 and response.text == "Hello there."
    assert whisper.loads == 1


def test_slow_cleanup_load_returns_whisper_words_without_waiting(client, whisper, ollama, monkeypatch):
    gate = threading.Event()
    ollama.gate = gate
    monkeypatch.setattr(inference, "POLISH_READY_WAIT_S", 0.05)
    try:
        client.post("/warm")
        assert ollama.load_started.wait(5)
        started = time.monotonic()
        response = _audio_request(client)
        assert time.monotonic() - started < 1
        assert response.status_code == 200
        assert response.text == "hello there"
        assert response.headers["X-Polish"] == "unavailable"
        assert ollama.chats == 0
    finally:
        gate.set()
        _join_loaders()


# --- idle unload -----------------------------------------------------------

def _resident(monkeypatch, whisper):
    monkeypatch.setattr(inference, "_mlx_whisper", whisper)


def test_idle_unload_drops_whisper_and_its_cache(whisper, monkeypatch):
    holder = type("Holder", (), {"model": object(), "model_path": "x"})
    monkeypatch.setitem(sys.modules, "mlx_whisper.transcribe", type(sys)("t"))
    sys.modules["mlx_whisper.transcribe"].ModelHolder = holder
    released = []
    monkeypatch.setattr(inference, "_release_mlx_memory", lambda: released.append(1))
    _resident(monkeypatch, whisper)
    monkeypatch.setattr(inference, "IDLE_UNLOAD_S", 10.0)
    monkeypatch.setattr(inference, "_last_activity", time.monotonic() - 11)
    assert inference.unload_if_idle() is True
    assert inference._mlx_whisper is None and holder.model is None and released


def test_no_unload_before_the_idle_time(whisper, monkeypatch):
    _resident(monkeypatch, whisper)
    monkeypatch.setattr(inference, "IDLE_UNLOAD_S", 10.0)
    monkeypatch.setattr(inference, "_last_activity", time.monotonic() - 5)
    assert inference.unload_if_idle() is False and inference._mlx_whisper is whisper


def test_no_unload_while_a_request_is_running(whisper, monkeypatch):
    _resident(monkeypatch, whisper)
    monkeypatch.setattr(inference, "IDLE_UNLOAD_S", 10.0)
    with inference.activity():
        monkeypatch.setattr(inference, "_last_activity", time.monotonic() - 100)
        assert inference.unload_if_idle() is False
    assert inference._mlx_whisper is whisper
    assert inference.idle_seconds() < 5  # finishing a request restarts the clock


def test_no_unload_while_a_load_is_in_progress(whisper, monkeypatch):
    _resident(monkeypatch, whisper)
    monkeypatch.setattr(inference, "IDLE_UNLOAD_S", 10.0)
    monkeypatch.setattr(inference, "_last_activity", time.monotonic() - 100)
    with inference._asr_lock:
        assert inference.unload_if_idle() is False
    assert inference._mlx_whisper is whisper


def test_unload_check_never_runs_inference(whisper, monkeypatch):
    _resident(monkeypatch, whisper)
    monkeypatch.setattr(inference, "_last_activity", time.monotonic() - 10_000)
    inference.unload_if_idle()
    assert whisper.loads == 0 and whisper.decodes == 0


def test_every_ollama_call_has_a_finite_keep_alive(monkeypatch):
    sent = []

    def post(url, json=None, **kwargs):
        sent.append(json)
        import httpx
        return httpx.Response(200, json={"message": {"content": "ok"}},
                              request=httpx.Request("POST", url))

    monkeypatch.setattr(inference.httpx, "post", post)
    inference._ollama_load()
    inference._ollama_chat([{"role": "user", "content": "x"}], 8)
    assert len(sent) == 2
    assert all(p["keep_alive"] == f"{int(inference.IDLE_UNLOAD_S)}s" for p in sent)
    assert sent[0]["messages"] == [] and sent[0]["options"]["num_ctx"] == sent[1]["options"]["num_ctx"]
    assert inference._polish_resident()


# --- text-only clean-up model ---------------------------------------------

CAPS_FULL = {"capabilities": ["completion", "vision", "audio"], "modelfile": "FROM /b/sha256-aaa\nFROM /b/sha256-proj\nTEMPLATE x"}
CAPS_TEXT = {"capabilities": ["completion"], "modelfile": "FROM /b/sha256-aaa"}


def _shows(monkeypatch, table):
    monkeypatch.setattr(inference, "_show", lambda model: table[model]() if callable(table[model]) else table[model])


def test_text_only_variant_is_derived_once_and_used(monkeypatch):
    base = inference.POLISH_MODEL
    variant = {}
    created = []
    monkeypatch.setattr(inference, "_show", lambda m: CAPS_FULL if m == base else variant.get("v"))
    monkeypatch.setattr(inference, "_derive_text_only",
                        lambda m, info: (created.append(m), variant.update(v=CAPS_TEXT)))
    inference._resolve_polish_model()
    inference._resolve_polish_model()
    assert created == [base] and inference.polish_model() == f"{base}-text"


def test_existing_text_variant_is_reused_without_creating(monkeypatch):
    base = inference.POLISH_MODEL
    monkeypatch.setattr(inference, "_show", lambda m: CAPS_FULL if m == base else CAPS_TEXT)
    monkeypatch.setattr(inference, "_derive_text_only", lambda *a: pytest.fail("must not re-create"))
    inference._resolve_polish_model()
    assert inference.polish_model() == f"{base}-text"


def test_model_without_projector_is_used_as_is(monkeypatch):
    monkeypatch.setattr(inference, "_show", lambda m: CAPS_TEXT)
    monkeypatch.setattr(inference, "_derive_text_only", lambda *a: pytest.fail("nothing to derive"))
    inference._resolve_polish_model()
    assert inference.polish_model() == inference.POLISH_MODEL


def test_derivation_failure_falls_back_to_the_base_model(monkeypatch):
    monkeypatch.setattr(inference, "_show", lambda m: CAPS_FULL)
    monkeypatch.setattr(inference, "_derive_text_only", lambda *a: (_ for _ in ()).throw(OSError("no manifest")))
    inference._resolve_polish_model()
    assert inference.polish_model() == inference.POLISH_MODEL


def test_variant_that_still_reports_vision_is_not_used(monkeypatch):
    monkeypatch.setattr(inference, "_show", lambda m: CAPS_FULL)
    monkeypatch.setattr(inference, "_derive_text_only", lambda *a: None)
    inference._resolve_polish_model()
    assert inference.polish_model() == inference.POLISH_MODEL


def test_unreachable_ollama_falls_back_and_is_retried(monkeypatch):
    import httpx
    monkeypatch.setattr(inference, "_show", lambda m: (_ for _ in ()).throw(httpx.ConnectError("refused")))
    inference._resolve_polish_model()
    assert inference.polish_model() == inference.POLISH_MODEL and inference._polish_model is None


def test_opt_out_and_remote_ollama_skip_derivation(monkeypatch):
    monkeypatch.setattr(inference, "_show", lambda m: pytest.fail("must not ask Ollama"))
    monkeypatch.setattr(inference, "TEXT_ONLY_POLISH", False)
    inference._resolve_polish_model()
    assert inference.polish_model() == inference.POLISH_MODEL
    monkeypatch.setattr(inference, "_polish_model", None)
    monkeypatch.setattr(inference, "TEXT_ONLY_POLISH", True)
    monkeypatch.setattr(inference, "OLLAMA_URL", "http://mac.example.ts.net:11434")
    inference._resolve_polish_model()
    assert inference.polish_model() == inference.POLISH_MODEL


def test_projector_digest_comes_from_the_manifest(tmp_path, monkeypatch):
    manifest = tmp_path / "manifests" / "registry.ollama.ai" / "library" / "gemma4" / "e2b"
    manifest.parent.mkdir(parents=True)
    manifest.write_text('{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:aaa"},'
                        '{"mediaType":"application/vnd.ollama.image.projector","digest":"sha256:proj"}]}')
    monkeypatch.setenv("OLLAMA_MODELS", str(tmp_path))
    assert inference._projector_digest("gemma4:e2b") == "proj"
