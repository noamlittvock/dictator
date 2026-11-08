"""Language choice is restricted to the languages actually spoken here."""
from __future__ import annotations

import numpy as np

from server import inference


def test_picks_best_allowed_language_even_when_detector_prefers_another(monkeypatch):
    monkeypatch.setattr(inference, "ALLOWED_LANGUAGES", ("en", "he"))
    monkeypatch.setattr(inference, "_language_probabilities", lambda audio, path: {"de": 0.61, "en": 0.30, "he": 0.05, "fr": 0.04})
    language, top = inference.choose_language(np.zeros(16000, dtype=np.float32), "model")
    assert language == "en"
    assert list(top) == ["de", "en", "he"]


def test_single_allowed_language_skips_detection(monkeypatch):
    monkeypatch.setattr(inference, "ALLOWED_LANGUAGES", ("he",))
    monkeypatch.setattr(inference, "_language_probabilities", lambda *a: (_ for _ in ()).throw(AssertionError("must not detect")))
    assert inference.choose_language(np.zeros(16000, dtype=np.float32), "model") == ("he", {})


def test_unrestricted_when_list_is_empty_or_detection_fails(monkeypatch):
    monkeypatch.setattr(inference, "ALLOWED_LANGUAGES", ())
    assert inference.choose_language(np.zeros(16000, dtype=np.float32), "model") == (None, {})
    monkeypatch.setattr(inference, "ALLOWED_LANGUAGES", ("en", "he"))
    monkeypatch.setattr(inference, "_language_probabilities", lambda *a: (_ for _ in ()).throw(RuntimeError("boom")))
    assert inference.choose_language(np.zeros(16000, dtype=np.float32), "model") == (None, {})


def test_default_allowed_languages_are_english_and_hebrew():
    assert inference.ALLOWED_LANGUAGES == ("en", "he")


def test_request_languages_override_defaults_restore_and_allow_auto(monkeypatch):
    monkeypatch.setattr(inference, "ALLOWED_LANGUAGES", ("en", "he"))
    monkeypatch.setattr(inference, "_language_probabilities", lambda *args: {"ar": .8, "es": .15, "en": .05})
    audio = np.zeros(10, dtype=np.float32)
    with inference.language_scope(("ar", "es")):
        assert inference.choose_language(audio, "model")[0] == "ar"
        with inference.language_scope(("es",)):
            assert inference.choose_language(audio, "model")[0] == "es"
        assert inference.choose_language(audio, "model")[0] == "ar"
    assert inference.choose_language(audio, "model")[0] == "en"
    with inference.language_scope(()):
        assert inference.choose_language(audio, "model") == (None, {})


def test_http_languages_reach_actual_decode_without_translation(monkeypatch):
    from fastapi.testclient import TestClient
    from server import server as api
    from types import SimpleNamespace
    calls = []
    def decode(audio, **kwargs):
        calls.append(kwargs)
        return {"text": "راجع report mañana شكرا", "segments": [], "language": kwargs["language"]}
    monkeypatch.setattr(inference, "_ensure_asr", lambda: None)
    monkeypatch.setattr(inference, "_mlx_whisper", SimpleNamespace(transcribe=decode))
    monkeypatch.setattr(inference, "_language_probabilities", lambda *args: {"ar": .8, "es": .15, "en": .05})
    monkeypatch.setattr(api, "_archive_take", lambda *args: None)
    monkeypatch.setattr(api, "_record_telemetry", lambda **kwargs: None)
    client = TestClient(api.app, headers={"Authorization": "Bearer synthetic-speech-key"})
    headers = {"X-Sample-Rate": "16000", "X-Frame-Count": "10", "X-Refine-Level": "exact"}
    for requested, expected in [("ar,es", "ar"), (" ES ,es", "es"), (None, "en")]:
        current = dict(headers)
        if requested is not None:
            current["X-Dictation-Languages"] = requested
        response = client.post("/transcribe", headers=current, content=np.zeros(10, dtype="<f4").tobytes())
        assert response.status_code == 200, response.text
        assert response.text == "راجع report mañana شكرا"
        assert calls[-1]["language"] == expected
        assert calls[-1]["task"] == "transcribe"
    for bad in ["english", "ar;es", "a" * 257]:
        response = client.post("/transcribe", headers={**headers, "X-Dictation-Languages": bad}, content=np.zeros(10, dtype="<f4").tobytes())
        assert response.status_code == 422
    assert len(calls) == 3


def test_language_scope_restores_after_failure_and_isolates_worker_threads(monkeypatch):
    import concurrent.futures
    import threading
    import pytest
    monkeypatch.setattr(inference, "ALLOWED_LANGUAGES", ("en",))
    barrier = threading.Barrier(2)
    def run(code):
        with pytest.raises(RuntimeError), inference.language_scope((code,)):
            barrier.wait(timeout=5)
            assert inference.choose_language(np.zeros(10), "model")[0] == code
            raise RuntimeError("synthetic decode failure")
        return inference.choose_language(np.zeros(10), "model")[0]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
        results = list(workers.map(run, ("ar", "es")))
    assert results == ["en", "en"]
