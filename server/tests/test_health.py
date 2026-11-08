"""Health contract tests. No model loads, downloads, personal audio, or live service."""
from __future__ import annotations

import httpx
import pytest
from fastapi.testclient import TestClient

from server import inference
from server import server as api


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(api, "_record_telemetry", lambda **kwargs: None)
    return TestClient(api.app, headers={"Authorization": "Bearer synthetic-speech-key"})


def _ollama(monkeypatch, up=True):
    calls = []

    def get(url, **kwargs):
        calls.append(url)
        if not up:
            raise httpx.ConnectError("refused")
        return httpx.Response(200, json={"version": "0"})

    monkeypatch.setattr(api.httpx, "get", get)
    return calls


def test_health_ok_with_nothing_loaded(client, monkeypatch):
    """Unloaded but loadable is ok: the app treats anything else as down."""
    _ollama(monkeypatch)
    data = client.get("/health").json()
    assert data["status"] == "ok"
    assert data["asr_loaded"] is False and data["polish_loaded"] is False
    assert data["asr_model"] == inference.WHISPER_MLX_REPO
    assert data["polish_model"] == inference.POLISH_MODEL
    assert data["ollama_url"] == inference.OLLAMA_URL


def test_health_reports_what_is_resident(client, monkeypatch):
    _ollama(monkeypatch)
    monkeypatch.setattr(inference, "_mlx_whisper", object())
    monkeypatch.setattr(inference, "_polish_expires", inference.time.monotonic() + 100)
    monkeypatch.setattr(inference, "_polish_model", "example-text")
    data = client.get("/health").json()
    assert data["asr_loaded"] is True and data["polish_loaded"] is True
    assert data["polish_model"] == "example-text"


def test_health_not_ok_when_ollama_is_down(client, monkeypatch):
    _ollama(monkeypatch, up=False)
    data = client.get("/health").json()
    assert data["status"] != "ok" and data["ollama_reachable"] is False


def test_health_caches_the_ollama_check(client, monkeypatch):
    calls = _ollama(monkeypatch)
    for _ in range(3):
        client.get("/health")
    assert len(calls) == 1


def test_health_never_loads_models_or_touches_the_idle_clock(client, monkeypatch):
    _ollama(monkeypatch)
    monkeypatch.setattr(inference, "_ensure_asr", lambda: pytest.fail("No model loads"))
    monkeypatch.setattr(inference, "_ensure_polish", lambda *a, **kw: pytest.fail("No model loads"))
    monkeypatch.setattr(inference, "transcribe_detailed", lambda *a, **kw: pytest.fail("No inference"))
    monkeypatch.setattr(inference, "_last_activity", 123.0)
    assert client.get("/health").status_code == 200
    assert inference._last_activity == 123.0
    assert inference._loaders == {}


@pytest.mark.parametrize("endpoint", ["/warm", "/transcribe"])
@pytest.mark.parametrize("authorization", [None, "Bearer wrong-key", "Basic synthetic-speech-key", "Bearer "])
def test_protected_endpoints_reject_without_work(endpoint, authorization, monkeypatch):
    monkeypatch.setattr(inference, "prepare", lambda **kw: pytest.fail("No model preparation"))
    monkeypatch.setattr(api, "_execute", lambda *a: pytest.fail("No audio processing"))
    monkeypatch.setattr(api, "_archive_take", lambda *a: pytest.fail("No archive"))
    headers = {} if authorization is None else {"Authorization": authorization}
    response = TestClient(api.app).post(endpoint, headers=headers, content=b"invalid audio")
    assert response.status_code == 401
    assert response.content == b""
    assert "synthetic-speech-key" not in str(response.headers)


def test_uninitialized_server_never_runs_open(monkeypatch):
    monkeypatch.setattr(api.app.state, "speech_token", None)
    response = TestClient(api.app).post("/warm", headers={"Authorization": "Bearer synthetic-speech-key"})
    assert response.status_code == 401 and response.content == b""


def test_health_is_open_and_never_exposes_key(monkeypatch):
    _ollama(monkeypatch)
    response = TestClient(api.app).get("/health")
    assert response.status_code == 200
    assert "synthetic-speech-key" not in response.text
    assert "token" not in response.text and "Authorization" not in response.text


def test_startup_creates_private_key_and_reuses_it(tmp_path, monkeypatch):
    path = tmp_path / "support" / "speech-server.token"
    monkeypatch.setenv("DICTATION_TOKEN_FILE", str(path))
    monkeypatch.setattr(inference, "prepare", lambda **kw: {})
    with TestClient(api.app) as client:
        key = path.read_text()
        assert len(key) == 43
        assert path.stat().st_mode & 0o777 == 0o600
        assert client.post("/warm").status_code == 401
        assert client.post("/warm", headers={"Authorization": f"Bearer {key}"}).status_code == 200
    assert api._load_token() == key
    assert list(path.parent.iterdir()) == [path]


@pytest.mark.parametrize("contents", ["", " \n", "\udcff"])
def test_startup_refuses_empty_or_unreadable_text_key(tmp_path, monkeypatch, contents):
    path = tmp_path / "speech-server.token"
    path.write_bytes(contents.encode("utf-8", errors="surrogateescape"))
    original = path.read_bytes()
    monkeypatch.setenv("DICTATION_TOKEN_FILE", str(path))
    with pytest.raises(RuntimeError, match="Refusing to start"):
        with TestClient(api.app):
            pytest.fail("Must not start")
    assert path.read_bytes() == original


def test_startup_refuses_permission_error_without_logging_key(tmp_path, monkeypatch, caplog):
    path = tmp_path / "speech-server.token"
    path.write_text("do-not-log-this-key")
    monkeypatch.setenv("DICTATION_TOKEN_FILE", str(path))
    monkeypatch.setattr(api.Path, "read_text", lambda *a, **kw: (_ for _ in ()).throw(PermissionError("denied")))
    with pytest.raises(RuntimeError, match="Refusing to start") as failure:
        with TestClient(api.app):
            pytest.fail("Must not start")
    assert "do-not-log-this-key" not in str(failure.value) + caplog.text


def test_key_creation_race_reuses_complete_winner(tmp_path, monkeypatch):
    path = tmp_path / "speech-server.token"
    monkeypatch.setenv("DICTATION_TOKEN_FILE", str(path))
    def publish_winner(*args):
        path.write_text("another-startup-won")
        raise FileExistsError()
    monkeypatch.setattr(api.os, "link", publish_winner)
    assert api._load_token() == "another-startup-won"
    assert list(tmp_path.iterdir()) == [path]
