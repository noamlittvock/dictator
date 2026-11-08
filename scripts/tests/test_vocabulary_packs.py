"""No audio, ML libraries, models or personal data: authored fixtures only."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('vocabulary_evaluate', ROOT / 'scripts/vocabulary-packs/evaluate.py')
evaluate = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = evaluate
SPEC.loader.exec_module(evaluate)


class VocabularyScoreTests(unittest.TestCase):
    def test_whole_terms_and_spelling(self):
        self.assertTrue(evaluate.recognized('ChatGPT', 'Please write ChatGPT.'))
        self.assertTrue(evaluate.recognized('res judicata', 'Res judicata, please.'))
        self.assertTrue(evaluate.recognized('RT-PCR', 'RT PCR.'))
        self.assertFalse(evaluate.recognized('ChatGPT', 'Chat GPT'))
        self.assertFalse(evaluate.recognized('metoprolol', 'metropolol'))
        self.assertFalse(evaluate.recognized('law', 'lawful'))
        self.assertFalse(evaluate.recognized('CDS', 'CDSO'))
        self.assertFalse(evaluate.recognized('Elisa', 'Elísa'))
        self.assertFalse(evaluate.recognized('', 'anything'))

    def test_rank_misses_recoveries_regressions_and_stable_ties(self):
        scores = [evaluate.Score(term) for term in ['easy', 'hard', 'helped', 'tie', 'regressed']]
        for score, before, after in zip(scores,
                                        ['easy', 'wrong', 'wrong', 'wrong', 'wrong'],
                                        ['easy', 'wrong', 'helped', 'wrong', 'regressed']):
            score.add(before, after)
        scores[4].add('regressed', 'wrong')
        scores[1].add('wrong', 'wrong')
        self.assertEqual(evaluate.rank(scores), ['hard', 'helped', 'regressed', 'tie'])
        self.assertEqual(scores[4].regressions, 1)
        self.assertEqual(scores[1].unaided_misses, 2)
        self.assertEqual(scores[1].trials, 2)


class VocabularyFitTests(unittest.TestCase):
    def test_frame_is_counted_at_exact_boundary(self):
        frame = 'Prefix {terms} suffix'
        budget = len(evaluate.prompt(['first', 'second'], frame))
        self.assertEqual(evaluate.fit(['first', 'second', 'third'], len, frame, budget), ['first', 'second'])
        self.assertEqual(evaluate.fit(['first', 'second'], len, frame, budget - 1), ['first'])

    def test_oversized_term_does_not_hide_later_terms_or_duplicate(self):
        frame = 'Frame {terms} end'
        self.assertEqual(evaluate.fit(['long' * 100, 'x', 'X', 'y'], len, frame, 15), ['x', 'y'])
        self.assertEqual(evaluate.fit(['x'], len, frame, 1), [])

    def test_batches_cover_candidates_once_within_budget(self):
        terms = ['term' + str(i) for i in range(150)]
        batches = evaluate.hint_batches(terms, len, '{terms}')
        self.assertEqual([t for batch in batches for t in batch], terms)
        self.assertTrue(all(len(evaluate.prompt(batch, '{terms}')) <= 200 for batch in batches))
        with self.assertRaises(ValueError):
            evaluate.hint_batches(['x' * 201], len, '{terms}')

    def test_frame_loading_fallback_and_validation(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'frame.json'
            self.assertEqual(evaluate.load_frame(path), evaluate.FALLBACK_FRAME)
            path.write_text(json.dumps({'frame': 'Hello {terms}.'}))
            self.assertEqual(evaluate.load_frame(path), 'Hello {terms}.')
            path.write_text(json.dumps({'frame': 'bare list'}))
            with self.assertRaises(ValueError):
                evaluate.load_frame(path)

    def test_temp_and_reports_cannot_be_inside_repo(self):
        with self.assertRaises(ValueError):
            evaluate.outside_repo(ROOT / 'scratch')


class VocabularyPackDataTests(unittest.TestCase):
    def test_all_packs_and_metadata_match_candidates(self):
        ids = {'common', 'software', 'medicine', 'law', 'finance', 'science', 'music', 'design-video', 'marketing-sales'}
        self.assertEqual({p.stem for p in evaluate.PACKS.glob('*.json')}, ids)
        for id in sorted(ids):
            with self.subTest(pack=id):
                metadata, candidates = evaluate.read_pack(id)
                pack = json.loads((evaluate.PACKS / f'{id}.json').read_text())
                self.assertEqual({k: v for k, v in pack.items() if k != 'terms'}, metadata)
                self.assertTrue(pack['terms'])
                self.assertTrue(set(pack['terms']).issubset(candidates))
                self.assertEqual(len(pack['terms']), len({t.casefold() for t in pack['terms']}))
                self.assertEqual(len(pack['apps']), len(set(pack['apps'])))
                self.assertTrue(all('.' in app and not any(c.isspace() for c in app) for app in pack['apps']))
                if id in {'medicine', 'law'}:
                    self.assertEqual(pack['apps'], [])
                self.assertEqual(pack.get('alwaysOn', False), id == 'common')

    def test_dry_run_is_stub_only_and_preserves_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'output'
            with patch.object(evaluate, 'real_backend', side_effect=AssertionError('real backend')):
                with patch.object(evaluate, 'synthesize', side_effect=AssertionError('real audio')):
                    self.assertEqual(evaluate.main(['--dry-run', '--packs', 'law', '--output-dir', str(output)]), 0)
            pack = json.loads((output / 'law.json').read_text())
            metadata, candidates = evaluate.read_pack('law')
            self.assertEqual(pack, dict(metadata, terms=candidates[:3]))


if __name__ == '__main__':
    unittest.main()
