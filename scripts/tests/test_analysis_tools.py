"""Synthetic regressions; never open personal logs or the production SQLite DB."""
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'dsh_token_analysis'
BASE = 1794258000000  # 2026-11-10 05:00 Asia/Shanghai


def call(offset, turn, tokens):
    return {'time': BASE + offset, 'type': 'assistant/message', 'data': {
        'turn': turn, 'step': 1,
        'message': {'source': {'provider': 'minimax-cn', 'model': 'MiniMax-M3'}},
        'usage': {'inputTokens': tokens}}}


def retry(offset, rid, turn=2):
    return {'time': BASE + offset, 'type': 'llm/retry', 'data': {
        'turn': turn, 'step': 1, 'retryId': rid, 'provider': 'minimax-cn',
        'failure': {'code': 'RATE_LIMIT'}}}


class AnalysisToolsTests(unittest.TestCase):
    def run_log_script(self, script, events):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'fixture.zstd'
            fixture.write_text('\n'.join(json.dumps(ev) for ev in events))
            output = io.StringIO()
            # Only the fixture is enumerated, even when personal /tmp logs exist.
            with patch.dict(os.environ, DSH_PLAIN_DIR=directory), contextlib.redirect_stdout(output):
                namespace = runpy.run_path(str(SCRIPTS / script))
            return namespace, output.getvalue()

    def test_rate_limit_totals_include_all_calls_without_recounting_retries(self):
        events = [call(0, 1, 100), call(1000, 2, 200), retry(2000, 'a'),
                  retry(3000, 'b'), retry(3100, 'b'), call(4000, 3, 999)]
        ns, output = self.run_log_script('summary.py', events)
        rows = [line for line in output.splitlines() if line.startswith(('| 1 |', '| 2 |'))]
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(line.endswith('| 300 | 300 |') for line in rows), rows)
        self.assertIn('共 2 次 RATE_LIMIT', output)
        ns, output = self.run_log_script('analyze.py', events)
        self.assertEqual(ns['last_day_total']['input'], 300)
        self.assertEqual(ns['last_window_total']['input'], 300)
        self.assertEqual(ns['last_day_total']['count'], 2)

    def test_rate_limit_totals_reset_at_window_and_day_boundaries(self):
        events = [call(-1000, 1, 10), call(0, 2, 20), retry(0, 'a'),
                  call(24 * 3600000, 3, 30), retry(24 * 3600000, 'b', 3)]
        _, output = self.run_log_script('summary.py', events)
        rows = [line for line in output.splitlines() if line.startswith(('| 1 |', '| 2 |'))]
        self.assertTrue(rows[0].endswith('| 20 | 30 |'), rows)
        self.assertTrue(rows[1].endswith('| 30 | 30 |'), rows)
        ns, _ = self.run_log_script('analyze.py', events)
        self.assertEqual(ns['last_day_total']['input'], 30)
        self.assertEqual(ns['last_window_total']['input'], 30)

    def test_later_usage_from_same_call_is_not_visible_at_earlier_retry(self):
        events = [call(0, 1, 100), retry(1000, 'a', 1),
                  call(2000, 1, 200), retry(3000, 'b', 1)]
        _, output = self.run_log_script('summary.py', events)
        rows = [line for line in output.splitlines() if line.startswith(('| 1 |', '| 2 |'))]
        self.assertTrue(rows[0].endswith('| 100 | 100 |'), rows)
        self.assertTrue(rows[1].endswith('| 300 | 300 |'), rows)
        ns, output = self.run_log_script('analyze.py', events)
        self.assertEqual(ns['total_for_range'](BASE, BASE + 1001)['input'], 100)
        first_row = next(line for line in output.splitlines() if line.startswith('  1  '))
        self.assertEqual(first_row.count('in=100 '), 3, first_row)

    def test_cost_empty_all_hit_all_miss_zero_and_retry_only(self):
        for events in ([], [call(0, 1, 100)], [call(0, 2, 100), retry(1, 'a')],
                       [call(0, 1, 0)], [retry(0, 'a')]):
            with self.subTest(events=events):
                _, output = self.run_log_script('cost.py', events)
                self.assertIn('全部窗口合计', output)
                self.assertIn('暂无窗口数据', output)

    def test_minimax_cost_empty_and_zero_usage(self):
        with tempfile.TemporaryDirectory() as directory:
            db = str(Path(directory) / 'fixture.sqlite')
            connect = sqlite3.connect
            with contextlib.closing(connect(db)) as conn, conn:
                conn.execute('CREATE TABLE local_runtime_token_usage (model TEXT, ts INTEGER, '
                             'input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER, '
                             'cache_read_tokens INTEGER, cache_write_tokens INTEGER)')
            for with_row in (False, True):
                if with_row:
                    with contextlib.closing(connect(db)) as conn, conn:
                        conn.execute('INSERT INTO local_runtime_token_usage VALUES (?, ?, 0, 0, 0, 0, 0)',
                                     ('minimax/MiniMax-M3', BASE))
                output = io.StringIO()
                with patch.dict(os.environ, MINIMAX_USAGE_DB=db), contextlib.redirect_stdout(output):
                    ns = runpy.run_path(str(SCRIPTS / 'minimax_cost.py'))
                ns['conn'].close()
                self.assertIn('总成本**：¥0.00', output.getvalue())
                self.assertIn('窗口成本 max' if with_row else '暂无窗口数据', output.getvalue())

    def test_all_plaintext_suffixes_are_discovered_and_partial_lines_are_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            for index, suffix in enumerate(('.zstd', '.zst', '.jsonl')):
                (Path(directory) / f'session{suffix}').write_text(
                    json.dumps(call(index, index, 100)) + '\n{"unfinished":')
            (Path(directory) / 'unrelated.txt').write_text(json.dumps(call(4, 4, 999)))
            for script in ('summary.py', 'analyze.py', 'cost.py'):
                with self.subTest(script=script), patch.dict(os.environ, DSH_PLAIN_DIR=directory):
                    with contextlib.redirect_stdout(io.StringIO()):
                        ns = runpy.run_path(str(SCRIPTS / script))
                    records = ns['call_totals'].values()
                    key = 'i' if script == 'cost.py' else 'input'
                    self.assertEqual(sum(row[key] for row in records), 300)

    def test_reasoning_is_a_subset_of_raw_output(self):
        event = call(0, 1, 100)
        event['data']['usage'].update(outputTokens=50, reasoningTokens=20)
        for script in ('summary.py', 'analyze.py'):
            ns, _ = self.run_log_script(script, [event, retry(1, 'a', 1)])
            row = next(iter(ns['call_totals'].values()))
            self.assertEqual((row['output'], row['reasoning']), (30, 20))
        _, output = self.run_log_script('cost.py', [])
        self.assertNotIn('¥23.80', output)
        self.assertNotIn('20 元、45M', output)

    def test_final_daily_bucket_is_labelled_four_hours(self):
        for script in ('summary.py', 'analyze.py', 'cost.py'):
            with self.subTest(script=script):
                _, output = self.run_log_script(script, [call(15 * 3600000, 1, 100)])
                self.assertIn('20:00+4h', output)
                self.assertNotIn('20:00+5h', output)

    def test_minimax_cost_uses_raw_output_once_and_readonly_database(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / 'fixture.sqlite'
            with contextlib.closing(sqlite3.connect(db)) as conn, conn:
                conn.execute('CREATE TABLE local_runtime_token_usage (model TEXT, ts INTEGER, '
                             'input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER, '
                             'cache_read_tokens INTEGER, cache_write_tokens INTEGER)')
                conn.execute('INSERT INTO local_runtime_token_usage VALUES (?, ?, 100, 50, 20, 30, 999)',
                             ('minimax/MiniMax-M3', BASE))
            with patch.dict(os.environ, MINIMAX_USAGE_DB=str(db)), contextlib.redirect_stdout(io.StringIO()):
                ns = runpy.run_path(str(SCRIPTS / 'minimax_cost.py'))
            self.assertAlmostEqual(ns['total_cost'], (100 * 2.1 + 30 * .42 + 50 * 8.4) / 1e6)
            missing = Path(directory) / 'missing.sqlite'
            with patch.dict(os.environ, MINIMAX_USAGE_DB=str(missing)), self.assertRaises(sqlite3.OperationalError):
                runpy.run_path(str(SCRIPTS / 'minimax_cost.py'))
            self.assertFalse(missing.exists())

    def test_decompression_refreshes_large_files_and_protects_plaintext(self):
        try:
            from compression import zstd
        except ImportError:
            try:
                import zstandard as zstd
            except ImportError:
                self.skipTest('Decompression requires Python 3.14 or the optional zstandard package')
        decompress = runpy.run_path(str(SCRIPTS / 'decompress.py'))['decompress']
        with tempfile.TemporaryDirectory() as directory:
            src, out = Path(directory) / 'source', Path(directory) / 'out'
            names = ('session.jsonl.zstd', 'session.jsonl.zst', 'session.jsonl',
                     'session.v3.jsonl.zstd', 'session.v4.jsonl.zst')
            for index, name in enumerate(names):
                parent = src / str(index)
                parent.mkdir(parents=True)
                content = b'x' * 110_000
                (parent / name).write_bytes(content if name.endswith('.jsonl') else zstd.compress(content))
            with contextlib.redirect_stdout(io.StringIO()):
                decompress(src, out)
                for path in src.rglob('*'):
                    if not path.is_file():
                        continue
                    content = b'new data\n' * 20_000
                    path.write_bytes(zstd.compress(content) if path.suffix != '.jsonl' else content)
                decompress(src, out)
            self.assertEqual(out.stat().st_mode & 0o777, 0o700)
            self.assertEqual(len(list(out.iterdir())), len(names))
            for path in out.iterdir():
                self.assertEqual(path.read_bytes(), content)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            # Corrupt input must fail and leave the prior complete output intact.
            (src / '0/session.jsonl.zstd').write_bytes(b'not zstd')
            with self.assertRaises(zstd.ZstdError):
                decompress(src, out)
            self.assertEqual((out / '0__session.jsonl.zstd').read_bytes(), content)
            self.assertEqual(len(list(out.iterdir())), len(names))

    def test_opus_cache_input_zero_and_unknown_models(self):
        for tokens in (0, 100):
            with self.subTest(tokens=tokens), tempfile.TemporaryDirectory() as directory:
                sample = {'modelName': 'claude-opus-4-6-thinking', 'completedAt': '2026-11-10T00:00:00Z',
                          'inputTokens': tokens, 'cachedInputTokens': tokens, 'outputTokens': 0}
                path = Path(directory) / 'index.json'
                path.write_text(json.dumps({'samplesBySession': {'a': [sample, dict(sample, modelName='claude-opus-future')]}}))
                output = io.StringIO()
                with patch.dict(os.environ, ANTIGRAVITY_USAGE_INDEX=str(path)), contextlib.redirect_stdout(output):
                    ns = runpy.run_path(str(SCRIPTS / 'antigravity_opus.py'))
                self.assertEqual(ns['total_tokens'], tokens)
                self.assertEqual(ns['opuses_total']['i'], 0)
                self.assertEqual(ns['opuses_total']['n'], 1)
                self.assertNotIn('2026-07-29', output.getvalue())


if __name__ == '__main__':
    unittest.main()
