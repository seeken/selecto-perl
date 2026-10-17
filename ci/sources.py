#!/usr/bin/env python3
"""Immutable siblings; credentials travel only through Git's credential protocol."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

def manifest(root=ROOT):
    config = json.loads((root / 'ci/beep.json').read_text())
    sources = config.get('sources', [])
    seen = set()
    for source in sources:
        repo = source.get('repository', '')
        if not re.fullmatch(r'seeken/[A-Za-z0-9_-]+', repo) or repo in seen:
            raise ValueError('invalid or duplicate source repository')
        if not re.fullmatch(r'[0-9a-f]{40}', source.get('commit', '')):
            raise ValueError('source needs a complete immutable Git commit')
        if source.get('access') not in ('private', 'public'):
            raise ValueError('source access must be explicit')
        seen.add(repo)
    return config

def credential():
    if len(sys.argv) != 3 or sys.argv[2] != 'get':
        return
    values = {}
    for line in sys.stdin:
        line = line.rstrip('\n')
        if not line:
            break
        if '=' not in line:
            return
        key, value = line.split('=', 1)
        if not key or '\r' in value:
            return
        if key not in ('protocol', 'host', 'path'):
            continue
        if key in values:
            return
        values[key] = value
    path = values.get('path', '').removesuffix('.git')
    allowed = {s['repository'] for s in manifest()['sources'] if s['access'] == 'private'}
    configured = set(Path('/run/selecto-ci/creds/siblings').read_text().splitlines())
    if values.get('protocol') != 'https' or values.get('host') != 'github.com' or path not in allowed & configured:
        return
    token = Path('/run/selecto-ci/creds/token').read_text().strip()
    if not token or '\n' in token or '\r' in token:
        raise ValueError('missing sibling checkout credential')
    # stdout belongs exclusively to Git's credential pipe, never the job log.
    sys.stdout.write('username=x-access-token\npassword=' + token + '\n')

def checkout():
    config = manifest()
    workspace = Path(os.environ['GITHUB_WORKSPACE']).resolve()
    if ROOT.parent != workspace:
        raise ValueError('root checkout must be a direct workspace child')
    env = os.environ.copy()
    env['GIT_TERMINAL_PROMPT'] = '0'
    for key in tuple(env):
        if key.startswith('GIT_TRACE') or key in ('GIT_ASKPASS', 'SSH_ASKPASS', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT'):
            del env[key]
    for source in config['sources']:
        repo, commit = source['repository'], source['commit']
        destination = workspace / repo.split('/')[1]
        if destination.exists():
            raise ValueError('refusing an existing sibling checkout: ' + repo)
        destination.mkdir()
        base = ['git', '-c', 'credential.helper=', '-c', 'credential.useHttpPath=true']
        if source['access'] == 'private':
            helper = '!' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(Path(__file__).resolve())) + ' credential'
            base += ['-c', 'credential.https://github.com.helper=' + helper]
        subprocess.run(base + ['init', '--quiet', str(destination)], check=True, env=env)
        subprocess.run(base + ['-C', str(destination), 'remote', 'add', 'origin', 'https://github.com/' + repo + '.git'], check=True, env=env)
        subprocess.run(base + ['-C', str(destination), 'fetch', '--quiet', '--no-tags', '--depth=1', 'origin', commit], check=True, env=env)
        subprocess.run(base + ['-C', str(destination), 'checkout', '--quiet', '--detach', commit], check=True, env=env)
        actual = subprocess.check_output(['git', '-C', str(destination), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != commit:
            raise ValueError('sibling commit mismatch')
        print(json.dumps({'repository': repo, 'commit': actual, 'access': source['access']}))

if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == 'credential':
        credential()
    elif sys.argv[1:] == ['checkout']:
        checkout()
    else:
        raise SystemExit('usage: sources.py checkout')
