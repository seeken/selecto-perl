#!/usr/bin/env python3
"""Download authenticated top-level CPAN bytes, then install with the selected SDK."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import urllib.request

URL = re.compile(r"https://cpan\.metacpan\.org/authors/id/[A-Z]/[A-Z]{2}/[A-Z0-9_-]+/[A-Za-z0-9._+-]+\.(?:tar\.gz|tgz|tar\.bz2|tar\.xz|zip)\Z")
SHA = re.compile(r"[0-9a-f]{64}\Z")
LIMIT = 64 * 1024 * 1024


def profile(path):
    result, seen = [], set()
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        parts = line.split()
        if len(parts) != 2 or not SHA.fullmatch(parts[0]) or not URL.fullmatch(parts[1]):
            raise ValueError('dependency requires SHA256 and exact HTTPS CPAN author URL')
        digest, url = parts
        author = url.split('/authors/id/', 1)[1].split('/')
        if author[0] != author[2][0] or author[1] != author[2][:2] or url in seen:
            raise ValueError('invalid or duplicate CPAN author URL')
        seen.add(url)
        result.append((digest, url))
    if not result:
        raise ValueError('empty top-level dependency profile')
    return result


class HTTPSOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        if not URL.fullmatch(new_url):
            raise ValueError('CPAN archive redirect left the declared HTTPS mirror')
        return super().redirect_request(request, fp, code, message, headers, new_url)


def download(items, cache):
    files, proof = [], []
    opener = urllib.request.build_opener(HTTPSOnly())
    for expected, url in items:
        directory = cache / expected
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / url.rsplit('/', 1)[1]
        if not target.exists():
            temporary = target.with_suffix(target.suffix + '.partial')
            digest, size = hashlib.sha256(), 0
            try:
                with opener.open(url, timeout=120) as response, temporary.open('wb') as output:
                    if not URL.fullmatch(response.url):
                        raise ValueError('CPAN archive left the declared HTTPS mirror')
                    while chunk := response.read(1024 * 1024):
                        size += len(chunk)
                        if size > LIMIT:
                            raise ValueError('CPAN archive exceeds bounded download size')
                        digest.update(chunk)
                        output.write(chunk)
                if digest.hexdigest() != expected:
                    raise ValueError('CPAN archive SHA256 mismatch')
                temporary.replace(target)
            finally:
                temporary.unlink(missing_ok=True)
        if target.stat().st_size > LIMIT or hashlib.sha256(target.read_bytes()).hexdigest() != expected:
            raise ValueError('CPAN archive cache SHA256 mismatch')
        files.append(str(target))
        proof.append({'url': url, 'sha256': expected, 'bytes': target.stat().st_size})
    return files, proof


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', type=Path, default=Path('ci/deps.txt'))
    parser.add_argument('--download-only', action='store_true')
    args = parser.parse_args()
    prefix = Path(os.environ['SELECTO_CI_CPAN_DIR']).resolve()
    prefix.mkdir(parents=True, exist_ok=True)
    files, proof = download(profile(args.profile), prefix / 'archives')
    report = {'top_level_archives': proof, 'transitive_resolution': 'HTTPS CPAN mirror; not fully locked'}
    if os.environ.get('SELECTO_CI_EVIDENCE_DIR'):
        evidence = Path(os.environ['SELECTO_CI_EVIDENCE_DIR'])
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / 'cpan-archives.json').write_text(json.dumps(report, indent=2) + '\n')
    if args.download_only:
        print(json.dumps(report))
        return 0
    perl = shutil.which('perl')
    if not perl:
        raise ValueError('selected Perl executable unavailable')
    actual = subprocess.check_output([perl, '-e', 'print $^V'], text=True, stderr=subprocess.DEVNULL)
    if actual != 'v5.40.2':
        raise ValueError('dependency installation requires selected Perl 5.40.2')
    command = [perl, '-x', '-S', 'cpanm', '--notest', '--from', 'https://cpan.metacpan.org',
               '--local-lib-contained', str(prefix), *files]
    return subprocess.run(command).returncode


if __name__ == '__main__':
    raise SystemExit(main())
