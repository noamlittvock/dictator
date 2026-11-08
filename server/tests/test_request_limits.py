"""Bad requests get a clear refusal, never a crash. Synthetic audio and mocks only."""
from __future__ import annotations

import base64
from types import SimpleNamespace

import httpx
import numpy as np
import pytest
from fastapi.testclient import TestClient

from server import inference
from server import server as api


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(api, "_record_telemetry", lambda **kwargs: None)
    monkeypatch.setattr(api, "_archive_take", lambda *args: None)
    monkeypatch.setattr(inference, "_ensure_asr", lambda: None)
    monkeypatch.setattr(inference, "_mlx_whisper", SimpleNamespace(
        transcribe=lambda audio, **kwargs: {"text": "heard", "segments": [], "language": kwargs.get("language")}))
    return TestClient(api.app, raise_server_exceptions=False, headers={"Authorization": "Bearer synthetic-speech-key"})


def transcribe(client, frames=10, sample_rate=16000, body=None, **headers):
    sent = {"X-Sample-Rate": str(sample_rate), "X-Frame-Count": str(frames), "X-Refine-Level": "exact", **headers}
    return client.post("/transcribe", headers=sent, content=np.zeros(10, dtype="<f4").tobytes() if body is None else body)


def test_a_body_larger_than_its_frame_count_is_not_read_whole(monkeypatch):
    class Stream:
        pulled = 0

        async def stream(self):
            for _ in range(1000):
                Stream.pulled += 1
                yield b"x" * 65536

    body = api.asyncio.run(api._read_body(Stream(), 40))
    assert Stream.pulled == 1 and len(body) == 65536


def test_oversized_body_is_refused(client):
    response = transcribe(client, frames=1, body=b"\0" * 1_000_000)
    assert response.status_code == 400


def test_enormous_frame_count_is_too_long_not_a_crash(client):
    assert transcribe(client, frames="9" * 320, body=b"").status_code == 413


@pytest.mark.parametrize("header", ["X-Dictionary", "X-Vocabulary-Hint"])
def test_non_ascii_header_is_refused(client, header):
    response = client.post(
        "/transcribe",
        headers={"X-Sample-Rate": "16000", "X-Frame-Count": "10", "X-Refine-Level": "exact",
                 header.encode(): b"\xff\xfe"},
        content=np.zeros(10, dtype="<f4").tobytes(),
    )
    assert response.status_code == 400


@pytest.mark.parametrize("header", ["X-Dictionary", "X-Vocabulary-Hint"])
def test_deeply_nested_header_is_refused(client, header):
    nested = base64.b64encode(b"[" * 40000).decode()
    assert transcribe(client, **{header: nested}).status_code == 400


@pytest.mark.parametrize("sample_rate", [32000, 44100, 48000])
def test_one_frame_take_still_transcribes(client, sample_rate):
    response = transcribe(client, frames=1, sample_rate=sample_rate, body=np.zeros(1, dtype="<f4").tobytes())
    assert response.status_code == 200, response.text


@pytest.mark.parametrize("reply", [
    httpx.Response(200, text="not json"),
    httpx.Response(200, json={"nothing": True}),
    httpx.Response(200, json={"message": None}),
    httpx.Response(200, json={"message": {"content": None}}),
])
def test_unusable_clean_up_reply_counts_as_a_backend_failure(monkeypatch, reply):
    reply.request = httpx.Request("POST", "http://127.0.0.1:11434/api/chat")
    monkeypatch.setattr(inference.httpx, "post", lambda *args, **kwargs: reply)
    with pytest.raises(inference.PolishBackendError):
        inference._ollama_chat([], max_tokens=8)
