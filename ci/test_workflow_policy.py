#!/usr/bin/env python3
"""Keep pull-request code outside the private-source runner boundary."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / '.github' / 'workflows'


def workflow_source(path):
    return '\n'.join(line.split('#', 1)[0] for line in path.read_text().splitlines())


class WorkflowPolicyTests(unittest.TestCase):
    def test_pull_request_workflows_use_only_hosted_public_paths(self):
        pull_request_workflows = []
        forbidden = ('self-hosted', 'beep-vm', 'ci/verify', 'ci/sources.py',
                     '/run/selecto-ci/creds')
        for path in sorted(WORKFLOWS.glob('*.y*ml')):
            source = workflow_source(path)
            if not re.search(r'\bpull_request(?:_target)?\b', source):
                continue
            pull_request_workflows.append(path.name)
            runner_lines = [line.strip() for line in source.splitlines()
                            if re.match(r'^\s*runs-on\s*:', line)]
            self.assertTrue(runner_lines, f'{path.name} has no explicit runner')
            self.assertTrue(all(line == 'runs-on: ubuntu-latest' for line in runner_lines),
                            f'{path.name} has a non-hosted pull-request runner')
            for value in forbidden:
                self.assertNotIn(value, source, f'{path.name} exposes {value} to pull requests')
        self.assertTrue(pull_request_workflows, 'no pull-request validation workflow found')

    def test_private_verifier_accepts_only_main_commits(self):
        source = workflow_source(WORKFLOWS / 'ci.yml')
        self.assertNotRegex(source, r'\bpull_request(?:_target)?\b')
        self.assertIn("if: github.ref == 'refs/heads/main'", source)
        self.assertIn('ref: ${{ github.sha }}', source)
        self.assertIn('runs-on: [self-hosted, beep-vm]', source)
        self.assertIn('run: mise exec perl@5.40.2.1 python@3.14.3 -- ci/verify', source)


if __name__ == '__main__':
    unittest.main()
