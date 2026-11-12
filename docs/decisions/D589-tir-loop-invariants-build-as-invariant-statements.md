# D589 - A loop `invariant:` clause builds as an invariant statement (docs/70 phase 3a, #8613)

**Status:** shipped; extends D358.

## Context

A loop's `invariant:` clause is parsed as the statement `SInvariant(expr)` at the head of the loop body. TIR has the matching `TsInvariant(expr)`, and the verifier checks that its expression is a `Bool`, but the builder counted every loop invariant as `a loop invariant` (19 sites in the self-test area of the wide census).

## Decision

- `SInvariant(x)` builds `x` as an expression and wraps it as `TsInvariant`. The expression keeps whatever the checker typed it as, so the verifier's `Bool` rule is the check; an expression the builder cannot build (an `await`, a quantifier) is counted under its own kind, not under the invariant.
- Where the invariant is enforced is the backends' and the verifier's: the TIR only carries it, as it carries `requires:` and `ensures:`.

## Measured

`tir_build` 166 and `tir_verify` 27 pass; a new case builds and verifies a `while` loop with `invariant: i <= n`. The wide census was not re-measured for this change alone.
