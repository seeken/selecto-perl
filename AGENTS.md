# selecto-perl

- This repository owns the native Perl implementation of the Selecto domain,
  query, portable-write, and PostgreSQL adapter contracts.
- Keep the core framework-neutral. DBI is the database boundary; web frameworks,
  ORMs, HTTP, and UI integrations belong in consumers such as
  `selecto-perl-northwind`.
- Certification observations must exercise public Selecto APIs. The central
  harness owns expected values and certification verdicts.
- Keep credentials and connection strings out of errors, JSON output, fixtures,
  and reports. Use only independently authored synthetic test data.
- Run `prove -lr t` and `perl Makefile.PL && make test` before handoff. Run the
  central PostgreSQL certificate when `DBD::Pg` and a disposable database are
  available.

