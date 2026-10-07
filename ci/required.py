#!/usr/bin/env python3
"""Fail missing controls before a test can turn them into a skipped success."""
import json
import os
from pathlib import Path
import subprocess
import sys

if sys.version_info[:3] != (3, 14, 3):
    raise SystemExit('unexpected Python runtime')
root = Path(__file__).resolve().parent.parent
config = json.loads((root / 'ci/beep.json').read_text())
for name in config.get('required_env', []):
    if not os.environ.get(name):
        raise SystemExit('required test environment is absent: ' + name)
cpanfiles = [str(path) for path in [root / 'cpanfile', *(
    root.parent / item['repository'].split('/')[1] / 'cpanfile' for item in config['sources']
)] if path.is_file()]
program = '''use strict; use warnings; use Module::CPANfile; use CPAN::Meta; use JSON::PP;
die "unexpected Perl" unless $^V eq v5.40.2;
my $modules = decode_json(shift @ARGV);
my @prereqs = map { Module::CPANfile->load($_)->prereqs } @ARGV;
push @prereqs, CPAN::Meta->load_file('MYMETA.json')->effective_prereqs;
for my $cpan (@prereqs) {
for my $phase (qw(runtime configure build test)) {
my $req = $cpan->requirements_for($phase, 'requires');
for my $module ($req->required_modules) {
if ($module eq 'perl') { die "declared Perl constraint failed" unless $req->accepts_module($module, $]); next; }
(my $file = "$module.pm") =~ s!::!/!g;
require $file; no strict 'refs'; my $version = ${$module . '::VERSION'} // 0;
die "declared dependency constraint failed" unless $req->accepts_module($module, $version);
}}}
for my $module (@$modules) { (my $file = "$module.pm") =~ s!::!/!g; require $file; }
'''
subprocess.run(['perl', '-e', program, json.dumps(config['modules']), *cpanfiles], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print('Required runtime, declared dependencies and native-control prerequisites are present.')
