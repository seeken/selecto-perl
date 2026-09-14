# Synthetic data-rule fixtures

These three independently authored fixtures are byte-for-byte snapshots of
`selecto-protocol/spec/fixtures/rules/` from the workspace inspected at protocol
HEAD `52376622b225acfc78dce006b5c1160bc22deae4`.

They keep the distribution's data-rule tests independent of sibling checkouts.
The shared protocol remains authoritative; refresh all three together when its
baseline changes. `SELECTO_DATA_RULE_FIXTURES` can explicitly select another
fixture directory for protocol compatibility checks. No provider data or
protected standards are included.
