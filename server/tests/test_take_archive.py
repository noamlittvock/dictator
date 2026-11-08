"""Diagnostics and the rolling take archive."""
from __future__ import annotations

import json
import wave

import numpy as np
import pytest
from fastapi.testclient import TestClient

from server import inference
from server import server as api


def test_audio_diagnostics_levels():
    silent = inference.audio_diagnostics(np.zeros(1600, dtype=np.float32))
    assert silent["rms_dbfs"] <= -180 and silent["clipped_ratio"] == 0.0
    tone = (0.5 * np.sin(np.linspace(0, 200 * np.pi, 16000))).astype(np.float32)
    d = inference.audio_diagnostics(tone)
    assert -10 < d["rms_dbfs"] < -8 and -6.5 < d["peak_dbfs"] < -5.5
    clipped = inference.audio_diagnostics(np.ones(1000, dtype=np.float32))
    assert clipped["clipped_ratio"] == 1.0


def test_asr_diagnostics_reports_fallback_temperature_and_worst_segment():
    result = {"language": "en", "segments": [
        {"temperature": 0.0, "avg_logprob": -0.3, "compression_ratio": 1.2, "no_speech_prob": 0.01},
        {"temperature": 0.6, "avg_logprob": -1.4, "compression_ratio": 1.9, "no_speech_prob": 0.4},
    ]}
    d = inference.asr_diagnostics(result)
    assert d == {"language": "en", "segments": 2, "temperature": 0.6, "min_avg_logprob": -1.4,
                 "max_compression_ratio": 1.9, "max_no_speech_prob": 0.4}
    assert inference.asr_diagnostics({"segments": []})["temperature"] == 0.0


def test_transcribe_detailed_carries_raw_text_and_rejection(monkeypatch):
    monkeypatch.setattr(inference, "transcribe_audio_with_diagnostics",
                        lambda audio, sr, *a, **kw: ("what is the time question mark", {"language": "en", "temperature": 0.0}))
    monkeypatch.setattr(inference, "_polish_expires", inference.time.monotonic() + 60)
    monkeypatch.setattr(inference, "_start_loader", lambda *a, **kw: None)
    monkeypatch.setattr(inference, "_ollama_chat", lambda messages, max_tokens: "It is currently 3 pm in your timezone.")
    detail = inference.transcribe_detailed(np.zeros(16000, dtype=np.float32), 16000)
    assert detail["raw"] == "what is the time question mark"
    assert detail["text"] == "what is the time?"
    assert detail["rejected"] is True and detail["polish"] == "rejected"

    monkeypatch.setattr(inference, "_ollama_chat", lambda messages, max_tokens: "What is the time?")
    detail = inference.transcribe_detailed(np.zeros(16000, dtype=np.float32), 16000)
    assert detail["text"] == "What is the time?"
    assert detail["rejected"] is False and detail["polish"] == "polished"

    detail = inference.transcribe_detailed(np.zeros(16000, dtype=np.float32), 16000, polish=False)
    assert detail["text"] == "what is the time question mark"
    assert detail["polished"] is False and detail["polish"] == "raw"

    monkeypatch.setattr(inference, "transcribe_audio_with_diagnostics",
                        lambda audio, sr, *a, **kw: ("", {"language": "en"}))
    detail = inference.transcribe_detailed(np.zeros(16000, dtype=np.float32), 16000)
    assert detail["text"] == "" and detail["polish"] == "raw"

    monkeypatch.setattr(inference, "transcribe_audio_with_diagnostics",
                        lambda audio, sr, *a, **kw: ("ship it", {"language": "en"}))
    monkeypatch.setattr(inference, "_ollama_chat",
                        lambda messages, max_tokens: (_ for _ in ()).throw(
                            inference.PolishBackendError("connection refused")))
    detail = inference.transcribe_detailed(
        np.zeros(16000, dtype=np.float32), 16000,
        dictionary=[{"pattern": "ship it", "replacement": "ship this"}],
    )
    assert detail["text"] == "ship this"
    assert detail["polish"] == "unavailable" and detail["rejected"] is False


def test_transcribe_reports_polish_outcome_header_and_diagnostics(monkeypatch):
    detail = {
        "raw": "ship it",
        "text": "ship this",
        "asr": {"language": "en"},
        "audio": {},
        "polished": True,
        "rejected": False,
        "polish": "unavailable",
    }
    telemetry = []
    monkeypatch.setattr(inference, "transcribe_detailed", lambda *args, **kwargs: detail)
    monkeypatch.setattr(api, "KEEP_TAKES", 0)
    monkeypatch.setattr(api, "_record_telemetry", lambda **kwargs: telemetry.append(kwargs))

    response = TestClient(api.app, headers={"Authorization": "Bearer synthetic-speech-key"}).post(
        "/transcribe",
        content=np.zeros(160, dtype="<f4").tobytes(),
        headers={"X-Sample-Rate": "16000", "X-Frame-Count": "160"},
    )

    assert response.status_code == 200
    assert response.text == "ship this"
    assert response.headers["X-Polish"] == "unavailable"
    assert telemetry[0]["diagnostics"]["polish"] == "unavailable"


def test_request_preserves_current_mode_and_dictionary(monkeypatch):
    seen = {}
    def detailed(audio, sample_rate, **kwargs):
        seen.update(kwargs)
        return {"text": "legacy", "raw": "legacy", "asr": {}, "audio": {}, "polished": False, "rejected": False}
    monkeypatch.setattr(inference, "transcribe_detailed", detailed)
    monkeypatch.setattr(api, "KEEP_TAKES", 0)
    monkeypatch.setattr(api, "_record_telemetry", lambda **kwargs: None)
    response = TestClient(api.app, headers={"Authorization": "Bearer synthetic-speech-key"}).post("/transcribe", content=np.zeros(160, dtype="<f4").tobytes(), headers={
        "X-Sample-Rate": "16000", "X-Frame-Count": "160", "X-Refine-Level": "exact",
    })
    assert response.status_code == 200 and response.text == "legacy"
    assert seen == {"dictionary": [], "polish": False, "level": "exact"}


def test_non_finite_audio_rejected(monkeypatch):
    monkeypatch.setattr(inference, "transcribe_detailed", lambda *a, **kw: pytest.fail("Invalid audio"))
    response = TestClient(api.app, headers={"Authorization": "Bearer synthetic-speech-key"}).post("/transcribe", content=np.array([np.nan], dtype="<f4").tobytes(),
                                        headers={"X-Sample-Rate": "16000", "X-Frame-Count": "1"})
    assert response.status_code == 422


def test_archive_keeps_last_n_takes(tmp_path, monkeypatch):
    monkeypatch.setattr(api, "TAKES_DIR", tmp_path / "Takes")
    monkeypatch.setattr(api, "KEEP_TAKES", 3)
    audio = (0.1 * np.sin(np.linspace(0, 100 * np.pi, 8000))).astype(np.float32)
    for i in range(5):
        detail = {"raw": f"raw {i}", "text": f"text {i}", "polished": True, "rejected": False,
                  "asr": {"language": "en", "temperature": 0.0}, "audio": inference.audio_diagnostics(audio)}
        api._archive_take(audio, 16000, detail, {"refine_level": "medium", "sample_rate": 16000})
    folders = sorted(p for p in (tmp_path / "Takes").iterdir() if p.is_dir())
    assert len(folders) == 3
    sidecar = json.loads((folders[-1] / "take.json").read_text())
    assert sidecar["raw_transcript"] == "raw 4" and sidecar["text"] == "text 4"
    assert sidecar["asr"]["language"] == "en" and "rms_dbfs" in sidecar["audio"]
    with wave.open(str(folders[-1] / "audio.wav")) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()) == (1, 2, 16000, 8000)
    assert oct((folders[-1] / "audio.wav").stat().st_mode & 0o777) == "0o600"


def test_archive_resamples_and_is_disabled_at_zero(tmp_path, monkeypatch):
    monkeypatch.setattr(api, "TAKES_DIR", tmp_path / "Takes")
    monkeypatch.setattr(api, "KEEP_TAKES", 1)
    audio = np.zeros(44100, dtype=np.float32)
    api._archive_take(audio, 44100, {"raw": "", "text": ""}, {})
    folder = next(p for p in (tmp_path / "Takes").iterdir())
    with wave.open(str(folder / "audio.wav")) as w:
        assert w.getframerate() == 16000 and abs(w.getnframes() - 16000) < 50
    monkeypatch.setattr(api, "KEEP_TAKES", 0)
    monkeypatch.setattr(api, "TAKES_DIR", tmp_path / "Never")
    api._archive_take(audio, 16000, {"raw": "", "text": ""}, {})
    assert not (tmp_path / "Never").exists()


def test_disabled_archive_leaves_existing_takes_untouched(tmp_path, monkeypatch):
    monkeypatch.setattr(api, "TAKES_DIR", tmp_path)
    monkeypatch.setattr(api, "KEEP_TAKES", 0)
    existing = tmp_path / "old-take"
    existing.mkdir()
    (existing / "take.json").write_text('{"text":"synthetic old take"}')
    api._archive_take(np.zeros(160, dtype=np.float32), 16000, {"text": "new"}, {})
    assert list(tmp_path.iterdir()) == [existing]
    assert (existing / "take.json").read_text() == '{"text":"synthetic old take"}'


def test_response_says_what_clean_up_did(monkeypatch):
    def detailed(audio, sample_rate, **kwargs):
        return {"text": "Polished.", "raw": "polished", "asr": {}, "audio": {}, "polished": True, "rejected": False,
                "polish": "fallback", "polish_ms": 812}
    monkeypatch.setattr(inference, "transcribe_detailed", detailed)
    monkeypatch.setattr(api, "KEEP_TAKES", 0)
    monkeypatch.setattr(api, "_record_telemetry", lambda **kwargs: None)
    response = TestClient(api.app, headers={"Authorization": "Bearer synthetic-speech-key"}).post("/transcribe", content=np.zeros(160, dtype="<f4").tobytes(), headers={
        "X-Sample-Rate": "16000", "X-Frame-Count": "160", "X-Refine-Level": "strong",
    })
    assert response.headers["X-Polish"] == "fallback"
    assert response.headers["X-Polish-Level"] == "strong"
    assert response.headers["X-Polish-Ms"] == "812"
