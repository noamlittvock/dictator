"""Shared fixtures: every test starts with nothing resident and a fresh idle clock."""
from __future__ import annotations

import time

import pytest

from server import inference
from server import server as api


@pytest.fixture(autouse=True)
def clean_inference_state(monkeypatch):
    monkeypatch.setattr(api.app.state, "speech_token", "synthetic-speech-key", raising=False)
    monkeypatch.setattr(inference, "_mlx_whisper", None)
    monkeypatch.setattr(inference, "_polish_expires", 0.0)
    monkeypatch.setattr(inference, "_polish_model", None)
    monkeypatch.setattr(inference, "_active", 0)
    monkeypatch.setattr(inference, "_last_activity", time.monotonic())
    monkeypatch.setattr(inference, "_loaders", {})
    monkeypatch.setattr(inference, "_mlx_configured", True)  # never touch real MLX
    monkeypatch.setattr(inference, "_release_mlx_memory", lambda: None)
    monkeypatch.setattr(api, "_ollama_check", (0.0, False))


def pytest_report_header(config):
    return f"Speech server under test: {api.__file__}; inference: {inference.__file__}"
