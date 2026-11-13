#!/usr/bin/env python3
"""Exercise branch checkout and job-bound identities with a local Git remote."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import sources


class SourceCheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.workspace = self.directory / 'workspace'
        self.root = self.workspace / 'selecto-perl'
        (self.root / 'ci').mkdir(parents=True)
        self.remote = self.directory / 'runner.git'
        self.author = self.directory / 'author'
        self.git('init', '--quiet', '--bare', str(self.remote))
        self.git('init', '--quiet', '--initial-branch=main', str(self.author))
        self.git('-C', str(self.author), 'config', 'user.name', 'CI fixture')
        self.git('-C', str(self.author), 'config', 'user.email', 'ci@example.invalid')
        self.git('-C', str(self.author), 'config', 'commit.gpgsign', 'false')
        self.git('-C', str(self.author), 'remote', 'add', 'origin', str(self.remote))
        self.first = self.advance('first')
        config = self.directory / 'gitconfig'
        self.git('config', '--file', str(config),
                 f'url.{self.remote.as_uri()}.insteadOf',
                 'https://github.com/seeken/selecto-perl-certification.git')
        self.git('config', '--file', str(config), 'protocol.file.allow', 'always')
        self.addCleanup(patch.stopall)
        patch.object(sources, 'ROOT', self.root).start()
        patch.dict(os.environ, {'GITHUB_WORKSPACE': str(self.workspace),
                                'GIT_CONFIG_GLOBAL': str(config),
                                'GIT_CONFIG_NOSYSTEM': '1'}).start()

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'protocol.file.allow=always', *args], text=True,
                                       stderr=subprocess.PIPE).strip()

    def advance(self, value):
        (self.author / 'fixture.txt').write_text(value)
        self.git('-C', str(self.author), 'add', 'fixture.txt')
        self.git('-C', str(self.author), 'commit', '--quiet', '-m', value)
        self.git('-C', str(self.author), 'push', '--quiet', 'origin', 'main')
        return self.git('-C', str(self.author), 'rev-parse', 'HEAD')

    def configure(self, **revision):
        source = {'repository': 'seeken/selecto-perl-certification',
                  'access': 'public', **revision}
        (self.root / 'ci/beep.json').write_text(json.dumps({'sources': [source]}))
        return source

    def checkout(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            sources.checkout()
        return json.loads(output.getvalue())

    def test_main_uses_latest_tip_and_diagnostics_keep_that_job_snapshot(self):
        source = self.configure(branch='main')
        second = self.advance('second')
        result = self.checkout()
        destination = self.workspace / 'selecto-perl-certification'
        self.assertEqual(result['requested_ref'], 'refs/heads/main')
        self.assertEqual(result['commit'], second)
        self.assertEqual(self.git('-C', str(destination), 'rev-parse', 'HEAD'), second)
        self.assertEqual(self.git('-C', str(destination), 'status', '--porcelain'), '')
        self.advance('third')
        self.assertEqual(sources.expected_commit(source, destination), second)

    def test_immutable_commit_still_checks_out_the_exact_declared_revision(self):
        source = self.configure(commit=self.first)
        self.advance('second')
        result = self.checkout()
        self.assertEqual(result['commit'], self.first)
        self.assertEqual(sources.expected_commit(source, self.remote), self.first)

    def test_only_runner_main_can_float_and_mixed_selectors_are_rejected(self):
        for revision in [{'branch': 'other'}, {'branch': 'main', 'commit': self.first},
                         {'commit': 'short'}, {}]:
            with self.subTest(revision=revision):
                self.configure(**revision)
                with self.assertRaises(ValueError):
                    sources.manifest(self.root)
        source = self.configure(branch='main')
        source['repository'] = 'seeken/selecto-perl'
        (self.root / 'ci/beep.json').write_text(json.dumps({'sources': [source]}))
        with self.assertRaises(ValueError):
            sources.manifest(self.root)


if __name__ == '__main__':
    unittest.main()
