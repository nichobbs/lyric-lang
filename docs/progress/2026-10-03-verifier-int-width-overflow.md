# `lyric prove` checks `Int` overflow at 32 bits and `Long` at 64 (#7871)

`Lyric.Verifier` models `Int`, `Long` and `Nat` as the unbounded SMT `Int`
sort. Under `@proof_required(checked_arithmetic)` every signed `+`, `-` and
`*` carried the obligation that its result fits 64 bits, for `Int` as well
as `Long`, so `x + 1` on an `Int` at `Int.MaxValue` was never flagged. A
parameter of either type also carried no range fact, so an obligation that
needed one (`ensures: result == x - d * (x / d)` over `Long`) got a
counterexample outside the type's range.

Two related holes made the overflow obligations easy to miss even at the
right width: unary minus carried none (`-Int.MinValue` overflows too), and
the side conditions of a `val`/`let`/`var` initializer or an assignment's
right-hand side were discarded, so neither an overflow there nor a callee's
`requires:` (`val r = pos(y)`) was ever proved.

## Decision

D163 settled the runtime semantics: `+`, `-`, `*` and unary `-` panic on
overflow in a `debug` build and wrap in a `release` build. `lyric prove`
takes no build profile, and nothing specified which semantics a proof uses.
It now reasons with the `debug` (checked) semantics, the sound choice for a
proof: an operation that would overflow panics before producing the value a
later obligation is stated over. A plain `@proof_required` proof is
therefore a partial-correctness proof that does not cover a `release`
build's wrapped results, and a `checked_arithmetic` proof, which rules
overflow out, holds in both profiles. docs/15 §5.4, docs/01 §13.3 and book
chapter 18 say so.

## Fix

- `SortInfo.intBits` records a signed integer's width: 32 for `Int`, 64 for
  `Long` and `Nat`, carried through range subtypes over them. `VEnv`
  carries the width of each `Int`/`Long` record and protected-type field
  (`fieldIntBits`).
- `intBitsOfExpr` gives an expression's static width from a binding's or
  field's declared type, a callee's result type or an `i32`/`i64` suffix; an
  unannotated binding takes its initializer's. An expression of unsuffixed
  literals is checked as an `Int` unless a literal needs 64 bits: checking a
  `Long` against the narrower range can fail a proof, never pass a wrong
  one.
- Under `checked_arithmetic`, signed `+`, `-`, `*`, unary `-` and the
  compound assignments `+=`, `-=`, `*=` carry `Min <= result <= Max` for
  that width; unsigned compound assignments carry the no-wrap obligation the
  operators already had (#7848).
- Every mode assumes the type's bounds for an `Int`/`Long` parameter,
  protected-type field, callee result and loop-havocked variable, values
  that exist at runtime and so lie in range whatever the profile.
- A `val`/`let`/`var` initializer's and an assignment's side conditions are
  side goals, like an expression statement's.

## Verification

`verifier_self_test.l` gains z3-backed cases that refute `Int` arithmetic at
`Int.MaxValue`/`Int.MinValue` (addition, subtraction, multiplication,
negation) while the same operations on `Long` discharge, refute `Long` at its
own bounds, check a `val` initializer, a compound assignment (signed and
unsigned) and a record field at their declared width, assume parameter and
callee-result widths, and refute a callee precondition reached through a
`val` initializer or an assignment. The four CI proof examples still
discharge in full.
