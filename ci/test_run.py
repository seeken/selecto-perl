#!/usr/bin/env python3
"""Safe CI failure identities never include assertions or connection data."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('ci_run', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

class FailureSummaryTests(unittest.TestCase):
    def test_failed_indexes_and_continuations(self):
        records = runner.failed_tap_files('''Test Summary Report
-------------------
t/guard.t (Wstat: 512 (exited 2) Tests: 20 Failed: 4)
  Failed tests: 2-3, 8
                11
  Non-zero exit status: 2
''')
        self.assertEqual(records, [{'file': 't/guard.t', 'wait_status': 512,
            'exit_status': 2, 'tests': 20, 'failed': 4,
            'failed_test_indexes': [2, 3, 8, 11], 'index_parse_status': 'reported'}])

    def test_no_assertions_or_sensitive_values(self):
        output = '''not ok 1 - secret-token-value
# got postgres://secret-user:secret-password@secret-host/db
Test Summary Report
t/guard.t (Wstat: 65280 (exited 255) Tests: 1 Failed: 0)
  Parse errors: secret-token-value
'''
        report = json.dumps(runner.failed_tap_files(output))
        self.assertNotIn('secret-', report)
        self.assertNotIn('postgres://', report)
        self.assertEqual(runner.failed_tap_files(output)[0]['failed_test_indexes'], [])

    def test_untrusted_paths_and_non_summary_text_are_ignored(self):
        output = '''t/before.t (Wstat: 512 (exited 2) Tests: 2 Failed: 1)
Test Summary Report
t/../secret.t (Wstat: 512 (exited 2) Tests: 2 Failed: 1)
t/secret?token.t (Wstat: 512 (exited 2) Tests: 2 Failed: 1)
'''
        self.assertEqual(runner.failed_tap_files(output), [])

    def test_large_and_invalid_ranges_are_bounded(self):
        prefix = 'Test Summary Report\nt/guard.t (Wstat: 512 (exited 2) Tests: 100000 Failed: 99999)\n'
        record = runner.failed_tap_files(prefix + '  Failed tests: 1-99999\n')[0]
        self.assertEqual(record['index_parse_status'], 'bounded')
        self.assertEqual(record['failed_test_indexes'], [])
        record = runner.failed_tap_files(prefix + '  Failed tests: 0-5\n')[0]
        self.assertEqual(record['index_parse_status'], 'malformed')

if __name__ == '__main__':
    unittest.main()
