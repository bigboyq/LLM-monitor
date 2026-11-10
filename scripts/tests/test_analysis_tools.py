"""Synthetic regressions; never open personal logs or the production SQLite DB."""
import contextlib
import io
import json
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
            with patch.object(Path, 'glob', return_value=iter([fixture])), contextlib.redirect_stdout(output):
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
                with patch.object(sqlite3, 'connect', side_effect=lambda _: connect(db)), contextlib.redirect_stdout(output):
                    ns = runpy.run_path(str(SCRIPTS / 'minimax_cost.py'))
                ns['conn'].close()
                self.assertIn('总成本**：¥0.00', output.getvalue())
                self.assertIn('窗口成本 max' if with_row else '暂无窗口数据', output.getvalue())


if __name__ == '__main__':
    unittest.main()
