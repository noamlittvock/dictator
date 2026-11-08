"""Golden audio quality test: word accuracy and command handling on real models.

Drives the running speech server end to end:
loads each WAV from `shared/golden-audio/`, sends raw float32 PCM via
the same wire shape the Mac app uses, and asserts the
transcribed text against the manually authored reference in
`shared/reference-transcripts/`.

The five gates mirror the original quality targets:
    english      WER ≤ 0.10  (≥90% accuracy)
    hebrew       WER ≤ 0.10
    mixed        WER ≤ 0.15  (≥85% accuracy)
    punctuation  literal "," "." and "\\n" appear
    self-correction  contains "today", does not contain "yesterday"

The audio is synthetic `say(1)` speech, so this is a first check; real
speech is checked by hand (docs/manual-testing.md).
"""
from __future__ import annotations

import array
import os
import struct
import subprocess
import urllib.request
import wave
from pathlib import Path

import jiwer
import pytest


REPO = Path(__file__).resolve().parents[2]
GOLDEN = REPO / "shared" / "golden-audio"
REFS = REPO / "shared" / "reference-transcripts"
SERVER_PORT = 7878
TOKEN_FILE = Path(os.environ.get(
    "DICTATION_TOKEN_FILE",
    Path.home() / "Library/Application Support/Dictator/speech-server.token",
))


def _tailscale_ip() -> str:
    """Resolve this host's Tailscale IPv4. Mirrors server.resolve_tailscale_ip()
    so the test stays decoupled from server module import."""
    for tbin in ("/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"):
        try:
            r = subprocess.run([tbin, "ip", "-4"], capture_output=True, text=True, timeout=5)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
        if r.returncode == 0:
            for line in r.stdout.splitlines():
                ip = line.strip()
                if ip.startswith("100."):
                    return ip
    raise RuntimeError("Tailscale IPv4 not found; server cannot be reached.")


SERVER_URL = f"http://{_tailscale_ip()}:{SERVER_PORT}/transcribe"


def _load_wav_as_float32_pcm(path: Path) -> tuple[bytes, int, int]:
    """Read a 16-bit signed mono WAV and return (raw_f32_pcm_bytes, sample_rate, frame_count)."""
    with wave.open(str(path), "rb") as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        nframes = w.getnframes()
        raw = w.readframes(nframes)
    assert ch == 1, f"{path.name}: expected mono, got {ch} channels"
    assert sw == 2, f"{path.name}: expected 16-bit PCM, got sampwidth={sw}"
    samples = array.array("h")
    samples.frombytes(raw)
    body = b"".join(struct.pack("<f", s / 32768.0) for s in samples)
    return body, sr, len(samples)


def _post_transcribe(name: str) -> str:
    wav_path = GOLDEN / f"{name}.wav"
    body, sr, fc = _load_wav_as_float32_pcm(wav_path)
    req = urllib.request.Request(
        SERVER_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {TOKEN_FILE.read_text().strip()}",
            "X-Sample-Rate": str(sr),
            "X-Frame-Count": str(fc),
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read().decode("utf-8")


def _read_ref(name: str) -> str:
    return (REFS / f"{name}.txt").read_text().strip()


def _wer(reference: str, hypothesis: str) -> float:
    """Word error rate, case-insensitive, punctuation stripped on both sides
    so the WER predicate measures content rather than
    cosmetic punctuation. Punctuation correctness is asserted separately
    by the punctuation-commands test."""
    transform = jiwer.Compose([
        jiwer.ToLowerCase(),
        jiwer.RemovePunctuation(),
        jiwer.RemoveMultipleSpaces(),
        jiwer.Strip(),
        jiwer.ReduceToListOfListOfWords(),
    ])
    return jiwer.wer(
        reference,
        hypothesis,
        reference_transform=transform,
        hypothesis_transform=transform,
    )


@pytest.fixture(scope="module")
def transcripts() -> dict[str, str]:
    """Run inference once per sample, share across tests."""
    out = {}
    for name in (
        "english-5s",
        "hebrew-5s",
        "mixed-5s",
        "punctuation-commands",
        "self-correction",
    ):
        out[name] = _post_transcribe(name)
    return out


def test_english(transcripts: dict[str, str]) -> None:
    """English-only ≥90% word accuracy."""
    hyp = transcripts["english-5s"]
    ref = _read_ref("english-5s")
    wer = _wer(ref, hyp)
    assert wer <= 0.10, f"English WER {wer:.3f} > 0.10\n  ref: {ref!r}\n  hyp: {hyp!r}"


def test_hebrew(transcripts: dict[str, str]) -> None:
    """Hebrew-only ≥90% word accuracy."""
    hyp = transcripts["hebrew-5s"]
    ref = _read_ref("hebrew-5s")
    wer = _wer(ref, hyp)
    assert wer <= 0.10, f"Hebrew WER {wer:.3f} > 0.10\n  ref: {ref!r}\n  hyp: {hyp!r}"


def test_mixed_code_switch(transcripts: dict[str, str]) -> None:
    """Code-switched ≥85% word accuracy."""
    hyp = transcripts["mixed-5s"]
    ref = _read_ref("mixed-5s")
    wer = _wer(ref, hyp)
    assert wer <= 0.15, f"Mixed WER {wer:.3f} > 0.15\n  ref: {ref!r}\n  hyp: {hyp!r}"


def test_punctuation_commands(transcripts: dict[str, str]) -> None:
    """Spoken "comma", "period" and "new line" produce literal
    ',', '.', '\\n' — not the words."""
    hyp = transcripts["punctuation-commands"]
    assert "," in hyp, f"missing comma in: {hyp!r}"
    assert "." in hyp, f"missing period in: {hyp!r}"
    assert "\n" in hyp, f"missing newline in: {hyp!r}"
    # The literal command words must not survive in the output.
    lower = hyp.lower()
    assert " comma" not in lower, f"literal 'comma' word survived: {hyp!r}"
    assert " period" not in lower, f"literal 'period' word survived: {hyp!r}"
    assert "new line" not in lower, f"literal 'new line' phrase survived: {hyp!r}"


def test_self_correction(transcripts: dict[str, str]) -> None:
    """'actually [restatement]' → only the restatement."""
    hyp = transcripts["self-correction"].lower()
    assert "today" in hyp, f"missing 'today' in: {hyp!r}"
    assert "yesterday" not in hyp, f"'yesterday' was not stripped: {hyp!r}"
