#!/usr/bin/env python3
"""Report identities and declared modules, never environment or connection strings."""
import json
import os
from pathlib import Path
import subprocess
from sources import manifest

def git(path, *args):
    return subprocess.check_output(['git', '-C', str(path), *args], text=True, stderr=subprocess.DEVNULL).strip()

def main():
    root = Path(__file__).resolve().parent.parent
    config = manifest(root)
    sources = []
    for repo, path, expected in [(os.environ['GITHUB_REPOSITORY'], root, os.environ['GITHUB_SHA'])] + [
        (item['repository'], root.parent / item['repository'].split('/')[1], item['commit']) for item in config['sources']]:
        actual = git(path, 'rev-parse', 'HEAD')
        clean = not git(path, 'status', '--porcelain')
        if actual != expected or not clean:
            raise ValueError('source identity/cleanliness failure: ' + repo)
        sources.append({'repository': repo, 'commit': actual, 'tree': git(path, 'rev-parse', 'HEAD^{tree}'), 'clean': clean})
    modules = config.get('modules', ['DBI'])
    program = '''use strict; use warnings; use Config; use JSON::PP;
die "unexpected Perl runtime" unless $^V eq v5.40.2;
my @modules; for my $module (@ARGV) { die "invalid module" unless $module =~ /\\A[A-Za-z][A-Za-z0-9]*(?:::[A-Za-z0-9]+)*\\z/;
(my $file = "$module.pm") =~ s!::!/!g; require $file;
no strict 'refs'; push @modules, {module=>$module, version=>"${$module . '::VERSION'}", path=>$INC{$file}}; }
print JSON::PP->new->canonical->encode({perl=>"$^V", executable=>$^X, architecture=>$Config{archname}, modules=>\\@modules});'''
    runtime = json.loads(subprocess.check_output(['perl', '-e', program, *modules], text=True, stderr=subprocess.DEVNULL))
    expected_sources = config.get('module_sources', {})
    checkout_roots = [root] + [root.parent / item['repository'].split('/')[1] for item in config['sources']]
    allowed_paths = set()
    for checkout_root in checkout_roots:
        lib = (checkout_root / 'lib').resolve()
        if not lib.is_relative_to(checkout_root.resolve()):
            raise ValueError('source lib escapes its declared Git checkout')
        allowed_paths.add(lib)
    for module in runtime['modules']:
        if module['module'].startswith('Selecto'):
            if module['module'] not in expected_sources:
                raise ValueError('Selecto module requires a declared source path')
            expected = (root / expected_sources[module['module']]).resolve()
            if expected not in allowed_paths:
                raise ValueError('module source is not a declared Git checkout')
            if not Path(module['path']).resolve().is_relative_to(expected):
                raise ValueError('loaded module source mismatch: ' + module['module'])
    report = {'sources': sources, 'runtime': runtime, 'required_sdk': '5.40.2.1',
              'github': {key: os.environ[key] for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_WORKFLOW', 'GITHUB_JOB', 'GITHUB_EVENT_NAME')},
              'python': '.'.join(map(str, __import__('sys').version_info[:3]))}
    evidence = Path(os.environ['SELECTO_CI_EVIDENCE_DIR'])
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'runtime-sources.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))

if __name__ == '__main__':
    main()
