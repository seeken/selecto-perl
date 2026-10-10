# Published contract compatibility

`Selecto::Domain::ContractVerification` checks declared provider interfaces
without a database. Pass portable contract hashes or parsed `Selecto::Domain`
objects to its public methods:

```perl
my $before = Selecto::Domain::ContractVerification->snapshot($provider);
my $report = Selecto::Domain::ContractVerification->verify($provider, $consumer);
my $after = Selecto::Domain::ContractVerification->snapshot($new_provider);
my $diff = Selecto::Domain::ContractVerification->diff_snapshots($before, $after);
```

Parsed domains also expose `contract_snapshot`,
`verify_contract_compatibility($consumer)`, and
`diff_contract_snapshots($before, $after)`.

Each `published_views` entry becomes a named surface. Its `columns` declare
the output types, and `fields` can restrict the advertised output fields.
Filters must name entries in the provider's `filters`; query members use the
qualified `group.name` form. Required filters name root fields or declared
filters. Snapshots copy only published interface metadata, order identifiers
deterministically, and use `generated_at => 'stable'`. Declared callbacks and
physical refresh/query definitions are neither copied nor executed. This
metadata API does not imply that Perl can execute every declared query member.

A consumer's `domain_dependencies` names `provider` and `contract`, optionally
`accepts`, `expected_fingerprint`, `uses` (`fields`, `filters`, `query_members`),
and `satisfies`. Reports include dependencies for the supplied provider and all
independent incompatibility diagnostics. Other providers' declarations are
structurally validated and omitted from this provider's report. Malformed
metadata throws `Selecto::Error` with code `invalid_domain`.

Numeric versions have two or three components. Requirements support equality,
`<`, `<=`, `>`, `>=`, `~>`, and `and` conjunctions. `~> 1.2` admits versions from
1.2.0 up to 2.0.0; `~> 1.2.0` stops at 1.3.0. Invalid expressions, prerelease
versions, and unsupported operators are incompatible. `expected_fingerprint`
checks the surface fingerprint when present, otherwise the provider's
`domain_fingerprint`. This fallback and the selection of dependencies for one
named provider follow canonical Elixir behavior. The JVM implementation
currently requires a surface fingerprint and reports other-provider
dependencies as missing contracts; consumers moving between runtimes should
account for these differences.

Diff reports have `changed`, `breaking`, and a diagnostic `changes` array.
Surface, field, filter, or query member removal, result type changes, and added
required filters are breaking. New surfaces and fields are additive. Other
metadata changes are reported for review without asserting an interface break.

`Selecto::Verification::ContractSafety->verify` builds all 32 combinations of
valid/invalid field, filter, scope, version, and fingerprint dependencies. It
calls the public verifier for each state and checks acceptance completeness and
specific diagnostics, producing 64 checks and actual counterexamples. The
optional `verifier => sub { ... }` argument lets consumers evaluate another
implementation against the same bounded model.

The regression fixture was projected from the unchanged central D014, D015,
D016, D017, and D062 portable inputs at commit
`7473f7fe44aa1c315597a83e5676166822240abb`. Only the relevant domain inputs are
included; expected outputs are owned by tests and the central harness.
