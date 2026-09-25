# D-progress-985 — Operators on distinct types act on the underlying value

**Status:** shipped

Closes #7361 and the remaining item of #7226 (range re-checks of derived
arithmetic).

## Problem

A distinct type is a wrapper class with a `value` field on dotnet and the
JVM. The checker accepted `==`, `!=` and the derived operators on it, but
no backend lowered them through the wrapper:

- derived arithmetic operated on object references, which corrupted memory
  on dotnet (`AccessViolationException`) and failed verification on the JVM;
- `==` compared references, so `Cents.from(5) == Cents.from(5)` was `false`.

Native represents a distinct value as its underlying scalar, so it
happened to work there.

## Decision

One backend-neutral rewrite after type checking,
`Lyric.ContractElaborator.lowerDistinctOps`, replaces three backend fixes.

- **Recording.** The checker records every operator whose operands have the
  same distinct type (`SymbolTable.distinctOpSites`): `arith:<T>.from` for
  derived `+ - * / %`, and `cmp` for `== !=` and the derived comparisons.
  Compound assignments go in `distinctCompoundSites`. Only operators the
  checker sees are recorded; collection hashing is #7375.
- **Rewrite.**
  - Arithmetic `a op b` becomes `T.from(a.value op b.value)`, which
    re-checks a range subtype.
  - A comparison becomes `a.value op b.value`.
  - `x op= y` becomes `x = T.from(x.value op y.value)`.
  - The pass maps contract clauses too, so `requires: a < b` on distinct
    values is lowered. `AstMapper` gains an opt-in `contracts` flag for this.
- **T0134.** The compound rewrite evaluates its target twice, so the target
  must be a variable or field path. The parked #7226 draft called this
  T0129, a code #7307 now uses.
- **One spelling on every target.**
  - `.value` already worked on dotnet and native. On the JVM it now calls
    the wrapper's synthesised `$value()`.
  - Native gains `T.from` (it only knew `T(x)` and the old `T.From`) and
    `T.tryFrom`. `tryFrom` is lowered as an `if` whose `Ok`/`Err` arms are
    built against the expected `Result[T, String]`.
  - Native range messages now match the managed targets:
    `<T>.from: value out of range [lo, hi]` from `from`, and the
    `<T>.tryFrom: ...` text in `Err`. `Byte`/`UInt`/`ULong`-backed bounds
    compare unsigned.
- **Typing `T.from` and `T.tryFrom`.** The checker typed both as the
  lenient `TyError`, so an operator applied directly to their result was
  never recorded and never checked. `from` now has type `T` and `tryFrom`
  has type `Result[T, String]`.

## Left open

Wrapper classes still have reference equality and hashing, so a distinct
value used as a `Map`/`Set` key is compared by identity on dotnet and the
JVM. That is a separate change to the classes themselves (`Equals` /
`GetHashCode`, `equals` / `hashCode`), tracked in #7375.

## Tests

- `distinct_ops_self_test.l` runs on dotnet, JVM and native. It covers
  `==`/`!=` on `Long`- and `Byte`-backed types, arithmetic on `Long`, `Int`
  and `Double`, chained operators, comparisons, compound assignment on a
  variable and a field, contract clauses, and `tryFrom` Ok/Err.
- `range_subtype_arith_self_test.l` (dotnet, JVM) checks that derived
  results outside the range panic.
- `typechecker_self_test.l` covers T0134.

## Docs

- Language reference §2.3.
- Book chapter 2 and appendix B.
