#!/usr/bin/env python3
"""Measure synthetic vocabulary recognition, entirely offline.

Run with the speech server's Python environment (mlx-whisper installed):
  python scripts/vocabulary-packs/evaluate.py --model-repo /path/to/cached/model
A cached Hugging Face repo ID is also accepted; local_files_only forbids fetching.
No models or voices are downloaded. Four distinct installed English `say` voices
are required (override --voices for the voices available on the evaluation Mac).
Audio is deleted with the temporary directory, always outside the checkout.

The unaided and hinted decodes use identical audio/settings. Candidates are split
into full-frame, <=200-token hint batches; each term is tested in its batch across
all four voices. Rank by unaided misses, then hint recoveries, then source order.
Starter packs are unmeasured; these outputs replace them only on an explicit run.
--dry-run uses three candidates per pack, a stub decoder and a stub tokenizer;
it never invokes say, imports ML libraries or changes shipped packs by default.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unicodedata
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
PACKS = ROOT / 'shared' / 'vocabulary-packs'
BUDGET = 200
SENTENCE = 'Please write the term {term} in the notes.'
FALLBACK_FRAME = 'Hello. Today we talked about {terms}, and more. Thanks.'


def load_frame(path: Path = ROOT / 'shared' / 'vocabulary-hints.json') -> str:
    if not path.exists():
        return FALLBACK_FRAME
    data = json.loads(path.read_text())
    # Accept a direct frame, or the English frame in a multilingual document.
    frame = data.get('frame') or data.get('prompt_frame') or data.get('frames', {}).get('en')
    if not isinstance(frame, str) or frame.count('{terms}') != 1:
        raise ValueError(f'{path}: expected a frame with one {{terms}} placeholder')
    return frame


def prompt(terms: list[str], frame: str) -> str:
    return frame.replace('{terms}', ', '.join(terms)) if terms else ''


def fit(terms: list[str], tokens: Callable[[str], int], frame: str,
        budget: int = BUDGET) -> list[str]:
    """Greedy ordered fit, charging for the whole frame, never truncating a term."""
    kept: list[str] = []
    seen: set[str] = set()
    for term in terms:
        key = term.casefold()
        if key in seen:
            continue
        seen.add(key)
        if tokens(prompt(kept + [term], frame)) <= budget:
            kept.append(term)
    return kept


def hint_batches(terms: list[str], tokens: Callable[[str], int], frame: str) -> list[list[str]]:
    remaining = list(terms)
    batches = []
    while remaining:
        batch = fit(remaining, tokens, frame)
        if not batch:
            raise ValueError(f'Candidate cannot fit the {BUDGET}-token frame: {remaining[0]}')
        batches.append(batch)
        included = set(batch)
        remaining = [term for term in remaining if term not in included]
    return batches


def words(text: str) -> list[str]:
    # Ignore case and punctuation, but preserve word boundaries and diacritics:
    # "Chat GPT" does not pass for "ChatGPT", nor metropolol for metoprolol.
    return re.findall(r'[^\W_]+', unicodedata.normalize('NFKC', text).casefold())


def recognized(term: str, transcript: str) -> bool:
    wanted, actual = words(term), words(transcript)
    return bool(wanted) and any(actual[i:i + len(wanted)] == wanted
                               for i in range(len(actual) - len(wanted) + 1))


@dataclass
class Score:
    term: str
    unaided_misses: int = 0
    hinted_misses: int = 0
    recoveries: int = 0
    regressions: int = 0
    trials: int = 0

    def add(self, unaided: str, hinted: str) -> None:
        before, after = recognized(self.term, unaided), recognized(self.term, hinted)
        self.unaided_misses += not before
        self.hinted_misses += not after
        self.recoveries += not before and after
        self.regressions += before and not after
        self.trials += 1


def rank(scores: list[Score]) -> list[str]:
    return [s.term for s in sorted(scores, key=lambda s: (-s.unaided_misses, -s.recoveries, s.regressions))
            if s.unaided_misses > 0]


def read_pack(id: str, pack_dir: Path = PACKS) -> tuple[dict, list[str]]:
    metadata = json.loads((pack_dir / 'metadata' / f'{id}.json').read_text())
    terms = [line.strip() for line in (pack_dir / 'candidates' / f'{id}.txt').read_text().splitlines()
             if line.strip()]
    if metadata['id'] != id or metadata['language'] != 'en':
        raise ValueError(f'{id}: expected matching ID and English language')
    if not 120 <= len(terms) <= 160 or len({t.casefold() for t in terms}) != len(terms):
        raise ValueError(f'{id}: expected 120–160 unique candidates')
    return metadata, terms


def local_model(repo: str) -> Path:
    candidate = Path(repo).expanduser()
    if candidate.is_dir():
        return candidate.resolve()
    from huggingface_hub import snapshot_download
    return Path(snapshot_download(repo_id=repo, local_files_only=True))


def real_backend(repo: str):
    # Set before importing either library. No implicit tokenizer/model downloads.
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    model = local_model(repo)
    config = json.loads((model / 'config.json').read_text())
    n_vocab = config['n_vocab']
    multilingual = n_vocab >= 51865
    from mlx_whisper.tokenizer import get_tokenizer
    import mlx_whisper
    tokenizer = get_tokenizer(multilingual=multilingual,
                              num_languages=n_vocab - 51765 - int(multilingual),
                              language='en', task='transcribe')

    def transcribe(audio: Path, hint: str, term: str, voice: str) -> str:
        result = mlx_whisper.transcribe(str(audio), path_or_hf_repo=str(model),
                                        language='en', task='transcribe', temperature=0,
                                        condition_on_previous_text=False,
                                        initial_prompt=hint or None, verbose=False)
        return result['text']

    return lambda text: len(tokenizer.encode(" " + text.strip())) if text else 0, transcribe


def synthesize(term: str, voice: str, directory: Path) -> Path:
    # Fixed filenames are safe because each trial is decoded before the next one.
    aiff, wav = directory / 'speech.aiff', directory / 'speech.wav'
    subprocess.run(['say', '-v', voice, '-o', str(aiff), SENTENCE.format(term=term)],
                   check=True, capture_output=True)
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1',
                    str(aiff), str(wav)], check=True, capture_output=True)
    return wav


def installed_voices(voices: list[str]) -> None:
    if len(voices) != 4 or len(set(voices)) != 4:
        raise ValueError('Choose exactly four distinct installed English voices.')
    available = subprocess.run(['say', '-v', '?'], check=True, capture_output=True, text=True).stdout
    # Lines read "Daniel  en_GB ..." or "Daniel (English (UK))  en_GB ...".
    english = {re.sub(r'\s*\(.*$', '', match.group(1)).strip()
               for line in available.splitlines()
               if (match := re.match(r'^(.*?)\s+en[_-]\S+\s', line))}
    missing = set(voices) - english
    if missing:
        raise ValueError('English say voices are not installed: ' + ', '.join(sorted(missing)))


def outside_repo(path: Path) -> Path:
    path = path.expanduser().resolve()
    if path == ROOT or ROOT in path.parents:
        raise ValueError('Temporary audio and score reports must be outside the repository.')
    return path


def evaluate(id: str, voices: list[str], tokens, transcribe, audio_dir: Path,
             frame: str, dry_run: bool) -> tuple[dict, list[Score]]:
    metadata, candidates = read_pack(id)
    if dry_run:
        candidates = candidates[:3]
    scores = {term: Score(term) for term in candidates}
    for batch in hint_batches(candidates, tokens, frame):
        hint = prompt(batch, frame)
        for term in batch:
            for voice in voices:
                audio = audio_dir / 'stub.wav' if dry_run else synthesize(term, voice, audio_dir)
                scores[term].add(transcribe(audio, '', term, voice),
                                 transcribe(audio, hint, term, voice))
    results = list(scores.values())
    return dict(metadata, terms=fit(rank(results), tokens, frame)), results


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--model-repo', help='Existing local MLX Whisper directory or cached Hugging Face repo ID')
    parser.add_argument('--packs', nargs='+', help='Pack IDs (default: every candidate file)')
    parser.add_argument('--voices', nargs=4, default=['Samantha', 'Alex', 'Daniel', 'Karen'])
    parser.add_argument('--output-dir', type=Path, help='Defaults to shipped packs; dry-run defaults to throwaway output')
    parser.add_argument('--report-dir', type=Path, help='Optional per-term scores outside the checkout')
    parser.add_argument('--temp-dir', type=Path, default=Path('/private/tmp'))
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    if not args.dry_run and not args.model_repo:
        parser.error('--model-repo is required except with --dry-run')
    try:
        temp_root = outside_repo(args.temp_dir)
        report_dir = outside_repo(args.report_dir) if args.report_dir else None
        ids = args.packs or sorted(p.stem for p in (PACKS / 'candidates').glob('*.txt'))
        known = {p.stem for p in (PACKS / 'candidates').glob('*.txt')}
        if not ids or set(ids) - known:
            raise ValueError('Unknown or missing pack ID')
        frame = load_frame()
        if args.dry_run:
            tokens = lambda text: len(text.encode('utf-8')) // 3 + 1
            transcribe = lambda audio, hint, term, voice: SENTENCE.format(term=term if hint else 'unrecognized')
        else:
            installed_voices(args.voices)
            tokens, transcribe = real_backend(args.model_repo)
        with tempfile.TemporaryDirectory(prefix='dictator-vocabulary-', dir=temp_root) as folder:
            work = Path(folder)
            output = args.output_dir or (work / 'packs' if args.dry_run else PACKS)
            if args.dry_run:
                outside_repo(output)
            output.mkdir(parents=True, exist_ok=True)
            if report_dir:
                report_dir.mkdir(parents=True, exist_ok=True)
            for id in ids:
                pack, scores = evaluate(id, args.voices, tokens, transcribe, work, frame, args.dry_run)
                target = output / f'{id}.json'
                # Replace only after every voice and decode for this pack succeeds.
                staging = target.with_suffix('.json.tmp')
                staging.write_text(json.dumps(pack, indent=2, ensure_ascii=False) + '\n')
                staging.replace(target)
                if report_dir:
                    (report_dir / f'{id}.json').write_text(json.dumps([asdict(s) for s in scores], indent=2) + '\n')
                print(f'{id}: {len(pack["terms"])} terms, {tokens(prompt(pack["terms"], frame))} prompt tokens'
                      + (' (stub smoke test)' if args.dry_run else ''), flush=True)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
