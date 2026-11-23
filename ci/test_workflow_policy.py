#!/usr/bin/env python3
"""Keep pull-request code off the private-source beep runners."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / '.github' / 'workflows'


def workflow_source(path):
    return '\n'.join(line.split('#', 1)[0] for line in path.read_text().splitlines())


class WorkflowPolicyTests(unittest.TestCase):
    def test_no_workflow_runs_pull_request_code(self):
        # Every job runs on beep, which holds private-source credentials, so
        # no workflow may run on pull requests: only reviewed main commits.
        workflows = sorted(WORKFLOWS.glob('*.y*ml'))
        self.assertTrue(workflows, 'no workflows found')
        for path in workflows:
            source = workflow_source(path)
            self.assertNotRegex(source, r'\bpull_request(?:_target)?\b',
                                f'{path.name} runs pull-request code')
            runner_lines = [line.strip() for line in source.splitlines()
                            if re.match(r'^\s*runs-on\s*:', line)]
            self.assertTrue(runner_lines, f'{path.name} has no explicit runner')
            for line in runner_lines:
                self.assertEqual(line, 'runs-on: [self-hosted, beep-vm]',
                                 f'{path.name} uses a runner other than beep-vm')
            jobs = len(runner_lines)
            self.assertEqual(source.count("if: github.ref == 'refs/heads/main'"), jobs,
                             f'{path.name} has a job not limited to main')

    def test_private_verifier_accepts_only_main_commits(self):
        source = workflow_source(WORKFLOWS / 'ci.yml')
        self.assertNotRegex(source, r'\bpull_request(?:_target)?\b')
        self.assertIn("if: github.ref == 'refs/heads/main'", source)
        self.assertIn('ref: ${{ github.sha }}', source)
        self.assertIn('runs-on: [self-hosted, beep-vm]', source)
        self.assertRegex(source, r'(?m)^\s*run: mise exec \S.* -- ci/verify\s*$')


if __name__ == '__main__':
    unittest.main()
