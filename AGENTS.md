# selecto-perl

- This repository owns the native Perl implementation of the Selecto domain,
  query, portable-write, and database-adapter contracts.
- Use Mojolicious for the lightweight Perl object foundation and adapter
  registry, but keep the core HTTP-neutral. DBI is the database boundary; web
  routes, ORMs, HTTP, and UI integrations belong in consumers such as
  `selecto-perl-northwind`.
- Database implementations must inherit `Selecto::Adapter`, return
  `Selecto::Statement` objects, and register by a stable lowercase name. Keep
  dialect SQL and result normalization inside the concrete adapter.
- The domain owns the root relation. Query objects must not expose or accept a
  `from` override; engines pass the domain and query intent to adapters
  separately, and adapters render the root from the domain.
- Certification observations must exercise public Selecto APIs. The central
  harness owns expected values and certification verdicts.
- Keep credentials and connection strings out of errors, JSON output, fixtures,
  and reports. Use only independently authored synthetic test data.
- Run `script/with-local-deps prove -lr t` and
  `script/with-local-deps sh -c 'perl Makefile.PL && make test'` before handoff. Run the
  central PostgreSQL certificate when `DBD::Pg` and a disposable database are
  available.
