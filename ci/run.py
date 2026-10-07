#!/usr/bin/env python3
"""Bounded, credential-free summaries of real verifier commands."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

LIMIT = 20 * 1024 * 1024
SUMMARY = re.compile(r'Files=(\d+),\s*Tests=(\d+)')
SKIP = re.compile(r'^.*(?:\b[0-9]+\.\.0\s+#\s*SKIP\b|^\s*(?:ok|not ok)\s+\d+.*#\s*skip\b)', re.I)
FILE_SKIP = re.compile(r'^\s*[A-Za-z0-9_./-]+\.t\s+\.+\s+skipped:\s*(.*)$', re.I)

def skip_reason(line):
    match = FILE_SKIP.match(line)
    if match:
        return match.group(1).strip()
    if SKIP.search(line):
        return line.partition('#')[2].strip()[4:].strip()
    return None

def summarize(output):
    counts = [{'files': int(a), 'tests': int(b)} for a, b in SUMMARY.findall(output)]
    skips = [line for line in output.splitlines() if skip_reason(line) is not None]
    classes = {}
    for line in skips:
        category = next((name for name in ('duckdb', 'mysql', 'mariadb', 'mssql', 'postgres', 'sqlite', 'northwind') if name in line.lower()), 'other')
        classes[category] = classes.get(category, 0) + 1
    return counts, classes

def main():
    if len(sys.argv) < 4 or sys.argv[2] != '--' or not re.fullmatch(r'[a-z0-9][a-z0-9:_-]{0,80}', sys.argv[1]):
        raise SystemExit('usage: run.py STAGE -- COMMAND...')
    stage = sys.argv[1]
    config = json.loads(Path('ci/beep.json').read_text())
    if stage not in config.get('stages', {}):
        raise SystemExit('undeclared verification stage')
    rule = config['stages'][stage]
    evidence = Path(os.environ['SELECTO_CI_EVIDENCE_DIR']).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    status, output, code = 'passed', '', 1
    # Raw command output is temporary, bounded, and never an artifact or log.
    with tempfile.TemporaryFile() as log:
        env = os.environ.copy()
        env['HARNESS_VERBOSE'] = '1'
        proc = subprocess.Popen(sys.argv[3:], stdout=log, stderr=subprocess.STDOUT, start_new_session=True, env=env)
        timeout = int(rule.get('timeout_seconds', 3600))
        while proc.poll() is None:
            if time.monotonic() - start > timeout or os.fstat(log.fileno()).st_size > LIMIT:
                status = 'timeout' if time.monotonic() - start > timeout else 'output_limit'
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                break
            time.sleep(0.2)
        code = proc.returncode
        if os.fstat(log.fileno()).st_size > LIMIT:
            status = 'output_limit'
        log.seek(0)
        output = log.read(LIMIT).decode('utf-8', errors='replace')
    counts, skips = summarize(output)
    if code != 0 and status == 'passed':
        status = 'command_failed'
    floor = int(rule.get('minimum_tests', 0))
    if status == 'passed' and floor and (not counts or any(item['tests'] < floor for item in counts)):
        status = 'coverage_floor_failed'
    skip_lines = [line for line in output.splitlines() if skip_reason(line) is not None]
    allowed = rule.get('allowed_skip_reasons', [])
    required_skips = sum(not any(skip_reason(line).lower() == reason.lower() for reason in allowed) for line in skip_lines)
    if status == 'passed' and rule.get('require_no_skips') and required_skips:
        status = 'required_coverage_skipped'
    report = {'stage': stage, 'status': status, 'exit_code': code,
              'elapsed_seconds': round(time.monotonic() - start, 3), 'tap_summaries': counts,
              'tap_skip_directives': sum(bool(SKIP.search(line)) for line in skip_lines),
              'harness_file_skips': sum(bool(FILE_SKIP.match(line)) for line in skip_lines),
              'skip_categories': skips,
              'required_skip_directives': required_skips,
              'minimum_tests': floor, 'require_no_skips': bool(rule.get('require_no_skips'))}
    (evidence / (stage.replace(':', '-') + '.json')).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    return 0 if status == 'passed' else (code if code > 0 else 1)

if __name__ == '__main__':
    raise SystemExit(main())
