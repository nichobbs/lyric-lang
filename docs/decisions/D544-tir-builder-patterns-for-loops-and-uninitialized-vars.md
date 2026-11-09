# D544 - Binding patterns, for loops and uninitialized vars in the TIR builder (docs/70 phase 3a, #8613)

**Status:** shipped; extends D543.

## Context

After D543 the census ranked `a name that is not a local` first, but most of those
were cascades: a `val (q, r) = f()` or `var x: Int` the builder refused left its names
undeclared, so every later read of them failed too. The root kinds were `a binding
pattern`, `a var without an initializer` and `a for loop`.

## Decision

1. A `val` of any pattern builds as `TsLet`: the initializer is built first (it cannot
   see the pattern's names), then the pattern through `buildPat`, which declares them.
2. A `var x: T` with no initializer builds as `TsVar` with no initializer and the
   annotation's type. Without an annotation it stays counted.
3. A `for` builds its iterable, its pattern (in a scope of its own) and its body. A
   closed or half-open range in iterator position builds as `XRange` typed by its
   bounds, since the checker types a range only as the loop's element type; an
   open-ended range stays counted.
4. The checker's `bindPattern` (the `val` and `for` pattern binder) now records each
   pattern's type (`patTypes`) and each bare name as a binding (`patBindingNodes`), as
   `bindPatternTyped` already did for `match` arms. Before, a tuple or name pattern in
   a `val` or `for` had no recorded type, which is an I0002.

## Tests

`tir_build_self_test.l`: a tuple `val`, a `var` without initializer and a range `for`
each build and verify (I0003 0).

## Measured

`scripts/ci/tir-census.sh` over the 98 programs: bodies built 913 -> 964 of 1165
(I0002 252 -> 201), I0003 0. `a name that is not a local` 77 -> 71, `a for loop` and
`a binding pattern` are gone. Next by count: a name that is not a local (71), a
defaulted argument (70; the callee's default expression is not in the resolved
signature, so a call must build it from the callee's declaration), a method,
constructor or member call (58), a method call with no declared receiver (38), a
function with no symbol (37), an argument conversion (31).
