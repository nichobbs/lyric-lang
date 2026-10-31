# D281 - Re-check record and opaque-type invariants at public boundaries and on `inout` (#7222)

**Status:** shipped (boundary and `inout` slice; methods, generics and `tryInto` open under #7222)

## Context

D-progress-958 enforces `invariant:` when a value is constructed. A value can
still be broken afterwards, by writing a `var` field or by an `inout`
parameter, and docs/08 section 7.1 requires re-checks at public boundaries.

## Decision

The contract elaborator inserts the checks, so MSIL, JVM and native share
them, with no backend codegen.

1. The type checker exports the non-generic invariant-bearing types and the
   path of each construction checker (`invariantBoundaryTypes`), split into
   types of other packages and types of the current package. A local type
   shadows an imported one of the same name.
2. For a `pub` top-level function, `elaborateMember` adds:
   - an entry statement `Checker(param)` for each `in` or `inout` parameter
     of a foreign type, before the range checks and `requires:` asserts;
   - an exit assert, in the `ensures` machinery (so it runs at every return
     and sees `result`), of `{ Checker(x); true }` for the result of a
     foreign type and for each `inout` or `out` parameter of a foreign or
     local type.
   The clauses are not added to `fn.contracts`, so contract metadata and the
   verifier see the source clauses unchanged.
3. A construction checker (`__lyric_checked_*`) is never subject to these
   checks.
4. The checks are system checks: `[contracts] enabled = false` does not
   disable them, like construction and range checks.

## Rule

A value is checked at construction and `.copy`; on entry to and exit from a
public function of another package; on exit from a public function of its
own package for `inout`/`out` parameters. A `var` field write is not checked
where it happens (docs/08 section 7.2).

## Not decided here

Impl and record methods, generic types, types inside `Option`/`Result`/
collections, and the `@projectable` `tryInto` (docs/08 section 7.4; MSIL and
JVM only, native refuses `@projectable`) remain open under #7222.

## Verification

`examples/invariant-boundary` (dotnet and JVM): valid crossings, a broken
`in` argument, a broken result, an `inout` written broken by a foreign
function and by a function of the declaring package.
