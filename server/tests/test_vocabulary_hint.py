"""Synthetic vocabulary hints; no models, personal data, or live services."""
import base64
import json
from types import SimpleNamespace

import numpy as np
import pytest
from fastapi.testclient import TestClient

from server import inference
from server import server as api


def encoded(value):
    return base64.b64encode(json.dumps(value, ensure_ascii=False).encode()).decode()


def test_header_validates_base64_json_and_shape():
    assert api._parse_vocabulary_hint_header(None) == []
    assert api._parse_vocabulary_hint_header(encoded({"terms": [" שם ", "GitHub", ""]})) == ["שם", "GitHub"]
    for raw in ["%%", "é", encoded([]), encoded({}), encoded({"terms": "words"}), encoded({"terms": [1]}),
                base64.b64encode(b'\xff').decode(), base64.b64encode(b'{').decode()]:
        with pytest.raises(api.HTTPException) as error:
            api._parse_vocabulary_hint_header(raw)
        assert error.value.status_code == 400


def test_frames_and_real_token_budget(monkeypatch):
    # Tokenizer assets ship with mlx-whisper; no model or download is needed.
    # Load the pure tokenizer module directly: importing the package initializes
    # Metal, which is deliberately unavailable in the test sandbox.
    import importlib.metadata
    import importlib.util
    import sys
    path = importlib.metadata.distribution("mlx-whisper").locate_file("mlx_whisper/tokenizer.py")
    spec = importlib.util.spec_from_file_location("dictator_test_tokenizer", path)
    module = importlib.util.module_from_spec(spec)
    monkeypatch.setitem(sys.modules, spec.name, module)
    spec.loader.exec_module(module)
    tokenizer = module.get_tokenizer(multilingual=True, language="he", task="transcribe")
    terms = ["שם ארוך " * 500, "Noa", "GitHub"] + [f"מונח{i}" for i in range(200)]
    for language in ["en", "he", "es", "fr", "de", "ja", None]:
        fitted = inference.fit_vocabulary_hint(terms, language, tokenizer)
        prompt = inference.vocabulary_hint_prompt(fitted, language)
        assert fitted[:2] == ["Noa", "GitHub"]
        assert len(tokenizer.encode(" " + prompt)) <= 200
        assert all(term in terms for term in fitted)
        assert prompt.endswith(".")
    assert inference.vocabulary_hint_prompt(["Noa"], "en") == "Hello. Today we talked about Noa, and more. Thanks."
    assert inference.vocabulary_hint_prompt(["Noa"], "ja") == "Noa."
    assert inference.vocabulary_hint_prompt(["Noa"], "fr-CA").startswith("Bonjour.")


def paused_audio(seconds=70):
    audio = np.full(seconds * 16000, .25, dtype=np.float32)
    for second in (27, 54):
        audio[second * 16000:int((second + .4) * 16000)] = 0
    return audio


def test_long_audio_cuts_only_in_sustained_silence_keeps_every_sample():
    audio = paused_audio()
    windows = list(inference.hinted_audio_windows(audio, 16000))
    assert [offset for offset, _ in windows] == [0, int(27.2 * 16000), int(54.2 * 16000)]
    assert all(len(window) < 30 * 16000 for _, window in windows)
    assert np.concatenate([window for _, window in windows]).tobytes() == audio.tobytes()
    for offset, _ in windows[1:]:
        assert np.all(audio[offset - 1600:offset + 1600] == 0)


@pytest.mark.parametrize("quiet_seconds, amplitude, splits", [
    (.02, 0, False), (.18, 0, False), (.2, 0, True),
    (.4, .0001, True), (.4, .005, False),
])
def test_quiet_speech_and_short_dips_are_not_silence(quiet_seconds, amplitude, splits):
    # A low-amplitude speech-like tone still has energy, including when its
    # individual samples cross zero. Only a sustained silence permits a cut.
    audio = np.full(40 * 16000, .25, dtype=np.float32)
    count = round(quiet_seconds * 16000)
    audio[27 * 16000:27 * 16000 + count] = amplitude * np.cos(np.arange(count) * 2 * np.pi * 180 / 16000)
    windows = list(inference.hinted_audio_windows(audio, 16000))
    assert len(windows) == (2 if splits else 1)
    assert np.concatenate([window for _, window in windows]).tobytes() == audio.tobytes()
    if not splits:
        assert windows[0][1] is audio


@pytest.mark.parametrize("first_pause", [False, True])
def test_any_missing_pause_falls_back_before_decoding(monkeypatch, caplog, first_pause):
    audio = np.full(70 * 16000, .2, dtype=np.float32)
    if first_pause:
        audio[27 * 16000:int(27.4 * 16000)] = 0
    calls = []
    def decode(window, **options):
        assert window is audio
        calls.append(options)
        return {"text": "the whole spoken recording", "language": options["language"], "segments": [
            {"start": 0, "end": 70, "temperature": .4, "avg_logprob": -.7}]}
    mock_asr(monkeypatch, decode)
    monkeypatch.setattr(inference, "_language_probabilities", lambda *a: {"he": .8, "en": .2})
    with caplog.at_level("INFO", logger=inference._log.name), inference.language_scope(("en", "he")):
        text, diagnostics = inference.transcribe_audio_with_diagnostics(audio, 16000, ["PrivateHint"])
    assert text == "the whole spoken recording"
    assert len(calls) == 1
    assert calls[0]["initial_prompt"].startswith("שלום.")
    assert diagnostics["language"] == "he"
    assert diagnostics["language_probs"] == {"he": .8, "en": .2}
    assert diagnostics["language_restricted"] is True
    assert diagnostics["segments"] == 1 and diagnostics["temperature"] == .4
    assert diagnostics["min_avg_logprob"] == -.7
    assert diagnostics["vocabulary_hint_terms"] == 1
    assert [record.getMessage() for record in caplog.records] == ["hint window fallback: recordings=1"]
    assert caplog.records[0].args == (1,)


def mock_asr(monkeypatch, decode):
    monkeypatch.setattr(inference, "_ensure_asr", lambda: None)
    monkeypatch.setattr(inference, "_mlx_whisper", SimpleNamespace(transcribe=decode))
    monkeypatch.setattr(inference, "_hint_tokenizer", lambda language: SimpleNamespace(encode=lambda text: list(text.encode())))
    monkeypatch.setattr(inference, "ALLOWED_LANGUAGES", ("en",))


def test_hint_reaches_every_window_and_aggregates_diagnostics(monkeypatch):
    calls = []
    merged = []
    original_diagnostics = inference.asr_diagnostics
    def capture_diagnostics(result):
        merged.append(result)
        return original_diagnostics(result)
    monkeypatch.setattr(inference, "asr_diagnostics", capture_diagnostics)
    def decode(audio, **options):
        calls.append((audio.copy(), options))
        return {"text": f"part {len(calls)}", "language": options["language"], "segments": [
            {"start": 0, "end": 1, "temperature": len(calls) * .2, "avg_logprob": -len(calls), "no_speech_prob": .1}]}
    mock_asr(monkeypatch, decode)
    audio = paused_audio(65)
    text, diagnostics = inference.transcribe_audio_with_diagnostics(audio, 16000, ["Noa", "GitHub"])
    assert text == "part 1 part 2 part 3"
    assert diagnostics["segments"] == 3
    assert diagnostics["min_avg_logprob"] == -3
    assert diagnostics["temperature"] == pytest.approx(.6)
    assert [segment["start"] for segment in merged[0]["segments"]] == [0, 27.2, 54.2]
    assert [segment["end"] for segment in merged[0]["segments"]] == [1, 28.2, 55.2]
    assert diagnostics["vocabulary_hint_terms"] == 2
    assert "Noa" not in json.dumps(diagnostics)
    assert np.concatenate([window for window, _ in calls]).tobytes() == audio.tobytes()
    for window, options in calls:
        assert len(window) < 30 * 16000
        assert options["initial_prompt"] == "Hello. Today we talked about Noa, GitHub, and more. Thanks."
        assert options["condition_on_previous_text"] is False
        assert options["compression_ratio_threshold"] == 2.4
        assert options["no_speech_threshold"] == .6
    calls.clear()
    inference.transcribe_audio_with_diagnostics(audio, 16000)
    assert len(calls) == 1 and calls[0][0].tobytes() == audio.tobytes()
    assert "initial_prompt" not in calls[0][1]


def test_words_beside_pauses_and_across_original_limit_are_whole_once(monkeypatch):
    audio = paused_audio(65)
    words = [
        (26.8, 27, .1, "before"), (28.8, 29.2, .2, "crossing"),
        (53.8, 54, .3, "next"), (54.4, 54.8, .4, "after"),
    ]
    for start, end, level, _ in words:
        audio[round(start * 16000):round(end * 16000)] = level
    def decode(window, **options):
        recognized = []
        for start, end, level, word in words:
            positions = np.flatnonzero(window == np.float32(level))
            if len(positions):
                # A split word makes either side fail this stub's contract.
                assert len(positions) == round(end * 16000) - round(start * 16000)
                assert positions[-1] - positions[0] + 1 == len(positions)
                recognized.append((positions[0], word))
        return {"text": " ".join(word for _, word in sorted(recognized)),
                "language": options["language"], "segments": []}
    mock_asr(monkeypatch, decode)
    text, _ = inference.transcribe_audio_with_diagnostics(audio, 16000, ["Noa"])
    assert text == "before crossing next after"


def test_language_chosen_before_framing_and_repetition_safeguard(monkeypatch):
    calls = []
    def decode(audio, **options):
        calls.append(options)
        return {"text": "la " * 10, "language": options["language"], "segments": []}
    mock_asr(monkeypatch, decode)
    monkeypatch.setattr(inference, "_language_probabilities", lambda *a: {"he": .8, "en": .2})
    with inference.language_scope(()):
        text, diagnostics = inference.transcribe_audio_with_diagnostics(np.zeros(16000), 16000, ["Noa"])
    assert calls[0]["language"] == "he"
    assert calls[0]["initial_prompt"].startswith("שלום.")
    assert diagnostics["language_restricted"] is False
    assert text == ""


def test_http_hint_is_independent_of_dictionary_and_json_returns_raw(monkeypatch):
    seen = []
    archived = []
    def decode(audio, **options):
        seen.append(options)
        return {"text": "github", "language": options["language"], "segments": []}
    mock_asr(monkeypatch, decode)
    monkeypatch.setattr(api, "_archive_take", lambda audio, sr, detail, info: archived.append(detail))
    monkeypatch.setattr(api, "_record_telemetry", lambda **kwargs: None)
    client = TestClient(api.app, headers={"Authorization": "Bearer synthetic-speech-key"})
    headers = {"X-Sample-Rate": "16000", "X-Frame-Count": "160", "X-Refine-Level": "exact", "Accept": "application/json",
               "X-Vocabulary-Hint": encoded({"terms": ["GitHub"]})}
    body = np.zeros(160, dtype="<f4").tobytes()
    response = client.post("/transcribe", headers=headers, content=body)
    assert response.status_code == 200
    assert response.json() == {"text": "github", "raw": "github"}
    response = client.post("/transcribe", headers={**headers, "X-Dictionary": encoded([{"pattern": "GitHub", "replacement": ""}])}, content=body)
    assert response.json() == {"text": "GitHub", "raw": "github"}
    assert all("GitHub" in options["initial_prompt"] for options in seen)
    assert archived[-1]["asr"]["vocabulary_hint_terms"] == 1
    assert "GitHub" not in json.dumps(archived[-1]["asr"])
    response = client.post("/transcribe", headers={**headers, "X-Vocabulary-Hint": "bad"}, content=body)
    assert response.status_code == 400
    assert len(seen) == 2


@pytest.mark.parametrize("bad_text", ["", "!" * 12, "la " * 10])
def test_empty_or_degenerate_audible_window_keeps_whole_take_recoverable(monkeypatch, bad_text):
    answers = iter([bad_text, "the second part"])
    mock_asr(monkeypatch, lambda audio, **options: {"text": next(answers), "language": "en", "segments": []})
    audio = np.full(40 * 16000, .2, dtype=np.float32)
    audio[27 * 16000:int(27.4 * 16000)] = 0
    assert inference.transcribe_audio_with_diagnostics(audio, 16000, ["Noa"])[0] == ""


def test_empty_silent_window_still_allows_recognized_words(monkeypatch):
    answers = iter(["", "the second part"])
    mock_asr(monkeypatch, lambda audio, **options: {"text": next(answers), "language": "en", "segments": []})
    audio = np.zeros(40 * 16000, dtype=np.float32)
    audio[30 * 16000:] = .2
    assert inference.transcribe_audio_with_diagnostics(audio, 16000, ["Noa"])[0] == "the second part"


@pytest.mark.parametrize("seconds", [1, 70])
def test_silence_only_audio_returns_empty(monkeypatch, seconds):
    calls = []
    def decode(audio, **options):
        assert not np.any(audio)
        calls.append(audio.copy())
        return {"text": "", "language": "en", "segments": []}
    mock_asr(monkeypatch, decode)
    audio = np.zeros(seconds * 16000, dtype=np.float32)
    text, diagnostics = inference.transcribe_audio_with_diagnostics(audio, 16000, ["Noa"])
    assert text == ""
    assert diagnostics["segments"] == 0
    assert np.concatenate(calls).tobytes() == audio.tobytes()


@pytest.mark.parametrize("hint", [None, []])
@pytest.mark.parametrize("seconds", [1, 70])
def test_no_hint_preserves_original_audio_options_text_and_diagnostics(monkeypatch, hint, seconds):
    audio = np.linspace(-.2, .2, seconds * 16000, dtype=np.float32)
    original_bytes = audio.tobytes()
    transcript = "  é\u0301  שלום\n𐐨 spoken words.  "
    calls = []
    def decode(window, **options):
        assert window is audio and window.tobytes() == original_bytes
        calls.append(options)
        return {"text": transcript, "language": "en", "segments": [{
            "start": 1.2, "end": 2, "temperature": .2, "avg_logprob": -.4567,
            "compression_ratio": 1.2345, "no_speech_prob": .0123}]}
    mock_asr(monkeypatch, decode)
    def unexpected(*args):
        pytest.fail("No-hint path must not plan windows or prepare hints")
    monkeypatch.setattr(inference, "hinted_audio_windows", unexpected)
    monkeypatch.setattr(inference, "_hint_tokenizer", unexpected)
    monkeypatch.setattr(inference, "_language_probabilities", unexpected)
    text, diagnostics = inference.transcribe_audio_with_diagnostics(audio, 16000, hint)
    assert text.encode() == transcript.strip().encode()
    assert audio.tobytes() == original_bytes
    # Frozen pre-windowing call contract and diagnostics, including rounding.
    assert calls == [{
        "path_or_hf_repo": inference.WHISPER_MLX_REPO, "verbose": False,
        "language": "en", "task": "transcribe",
        "temperature": (0., .2, .4, .6, .8, 1.),
        "compression_ratio_threshold": 2.4, "logprob_threshold": -1.,
        "no_speech_threshold": .6, "condition_on_previous_text": False}]
    assert diagnostics == {
        "language": "en", "segments": 1, "temperature": .2,
        "min_avg_logprob": -.457, "max_compression_ratio": 1.234,
        "max_no_speech_prob": .012, "language_probs": {}, "language_restricted": True}


def test_hebrew_prefixes_match_voice_launch_single_letters():
    import re
    from pathlib import Path
    source = (Path(__file__).resolve().parents[2] / "swift-client/Dictator/Models/VoiceLaunch.swift").read_text()
    prefixes = source.split("static let hebrewPrefixes: Set<String> = [", 1)[1].split("]", 1)[0]
    assert set(inference._HEBREW_DICTIONARY_PREFIXES) == set(re.findall(r'"([א-ת])"', prefixes))


def test_detection_failure_uses_plain_frame_and_unrestricted_decode(monkeypatch):
    seen = []
    def decode(audio, **options):
        seen.append(options)
        return {"text": "the spoken words", "language": "ja", "segments": []}
    mock_asr(monkeypatch, decode)
    monkeypatch.setattr(inference, "_language_probabilities", lambda *a: (_ for _ in ()).throw(RuntimeError("synthetic detector failure")))
    with inference.language_scope(()):
        _, diagnostics = inference.transcribe_audio_with_diagnostics(np.zeros(16000), 16000, ["Noa"])
    assert seen[0]["language"] is None
    assert seen[0]["initial_prompt"] == "Noa."
    assert diagnostics["language"] == "ja" and diagnostics["language_restricted"] is False
