# D485 - A default the source-loaded standard library declares as a bare case or a suffixed integer builds from the parameter's type (docs/70 phase 3a, #8613)

**Status:** shipped; extends D482 and D483.

## Context

The standard library is loaded as source, so no interface is registered for it (D482) and the checker's tables hold only its
signatures. D483 let a plain literal default build from its own type. The stdlib's remaining defaults are `None` (six),
`Tls12`, and integer literals with a suffix (`268435456i64`); each stayed counted as "a default argument declared in another
package" (22 sites in the stdlib-tests census).

## Decision

- A default that is a single bare name is the payload-free case of that name in the parameter's own union or enum
  (`nullaryCaseOf`), constructed at the parameter's type. `None` for `Option[T]` and `Tls12` for `TlsVersion` need nothing
  from the declaring package's tables: the parameter type names the union.
- An integer literal's suffix fixes its type (`i32` Int, `i64` Long, `u8` Byte, `u32` UInt, `u64` ULong); other suffixes stay
  counted.
- Any other source-loaded default (a call such as `newList()`, a constant) is still counted. Those need either the stdlib's
  interface or an on-demand interface of a source-loaded dependency, which remains open.

## Results

`tir-builder-shapes-e2e.sh` gains `stdlib_case_defaults` (`TlsServerConfig(identity = id)` leaning on `Tls12` and `None`,
built with `--verify-ir` and run). The foreign-default kind over stdlib-tests fell from 22 to 6 before the suffix rule; I0003
stays 0.
