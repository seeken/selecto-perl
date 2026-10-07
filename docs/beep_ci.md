# Beep CI

This library verifies pull requests and its default branch on disposable Beep
runners. `ci/beep.json` declares complete immutable sibling commits and source
paths. Public references clone without authentication; private references use
only the job-scoped, read-only credential file through Git's credential pipe.

The actual runtime is Perl 5.40.2, relocatable SDK 5.40.2.1, with Mise 2026.10.3
and Python 3.14.3. Browser/MCP jobs additionally use Node 22.23.3; MCP uses uv
0.12.23 and its reference harness's locked official clients. CPAN dependencies
install into the disposable job directory, with declared constraints checked
before testing. Top-level selected versions and loaded paths are recorded;
unlocked transitive CPAN requirements are not a full dependency lock.

The workflow runs the complete package verifier, mandatory native controls,
and distribution tests. Raw command output stays in bounded temporary files;
artifacts contain stage statuses, TAP counts/skips and source/runtime identities.
SQL Patterns' six-dialect output is compilation evidence; optional database
backends are not certified by this workflow. No production database is used.
