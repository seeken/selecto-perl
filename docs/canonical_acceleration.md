# PostgreSQL canonical conversion acceleration

Canonical values remain opt-in (`canonical_values => 1`). Driver values and
`canonical_sql` keep their existing behavior. The engine still compiles every
execution and performs its resource, query binding, field resolution, required
policy, tenant and PostgreSQL session checks. Only pure field-expression syntax
keys are memoized; the complete string leaf is checked on every lookup, and
non-string leaves or expression subclasses use the general implementation.
Entries are owned by the expression's lifetime and hold no engine or context.

The Perl decoder keeps one column plan per adapter, replaced when the result
types, export mode, driver-number mode or accelerator choice changes. Converters
operate on a column at a time and retain no rows. Subclasses overriding `_decode`
keep the original per-cell dispatch. `_decode_rows_reference` retains the prior
column implementation for parity checks.

`Makefile.PL` probes compilation and linking and builds the optional plain XS
module when a compiler is available. It needs Perl's headers and a working C
compiler, with no Inline::C or extra native library. Include `xs/CanonicalXS.xs`
and `lib/Selecto/PostgreSQL/CanonicalXS.pm` in source distributions. Build the
extension using the interpreter that will run it. On this macOS toolchain use
the Xcode 26.5 SDK in `SDKROOT`; that is a build environment choice, not a
runtime dependency.

The adapter tries the extension on first canonical conversion. Failure to load
selects Perl silently. Force Perl at runtime with `SELECTO_PERL_PURE=1` or a true
`$Selecto::PostgreSQL::PURE_PERL`; the choice can change between calls. For a
source build without XS use:

```sh
SELECTO_PERL_NO_XS=1 perl Makefile.PL
make test
```

Use a clean build directory when changing build modes; a previous native bundle
can remain in `blib`. The runtime switch works even when XS is installed.

XS handles plain scalar ASCII numeric and timestamp formatting, boolean
conversion, and already-native integer columns. It preserves output UTF8 flags
and string/numeric identity. A column containing references, magic or a value
outside the native converter's supported input falls back as a whole before
any cell is changed. Unicode-sensitive regex behavior, export JSON parsing,
date-style validation and unusual integers remain in Perl. The timestamp
DateStyle check still runs per result, including when the native converter is
used. Raw driver values bypass conversion.

`t/canonical_converter_parity.t` compares the prior loop, the planned Perl path
and available XS over whole columns and individual values, including bytes,
UTF8 flags, numeric/string dualvars, decimal strings, booleans, nulls, dates,
timestamps and JSON. Run `prove -lr t` and `make test` with XS available and
again with `SELECTO_PERL_PURE=1`. These are finite corpus and fixture checks;
they do not certify every possible Perl magical scalar or driver configuration.
