# D-progress-957 — `ensures:` checks returns nested in initializers and arm expressions (#7224)

**Status:** shipped

## Problem

The contract elaborator routes each `return e` through the postcondition
checks. It found returns at the top level of a body and inside
`if`/`match`/loop/`try`/`scope` statement bodies. It passed three shapes
through untouched, so a return in them skipped every `ensures:` clause
silently:

- a `val`/`var`/`let` initializer, e.g.
  `val v = match o { case None -> return 0; ... }`;
- an assignment's right-hand side;
- an expression-bodied match arm (`case A -> if c { return 1 } else { 2 }`),
  a value-producing block, or an `unsafe { }` block.

## Decision

- `elaborateStmtDeep` rewrites `SLocal` initializers and `SAssign`
  right-hand sides through `elaborateExprDeep`.
- `elaborateExprDeep` descends into `EBlock`, `EUnsafe` and `EParen`, and
  `elaborateExprOrBlockDeep` descends into expression-bodied branches as
  well as block-bodied ones.
- Lambdas are deliberately not entered: a `return` inside a lambda leaves
  the lambda, not the enclosing function.
- `?` early exits stay unchecked. `Lyric.Propagate` runs after the
  elaborator, so the synthesized early return passes the callee's
  `Err`/`None` through without evaluating postconditions. This was already
  the pipeline's documented intent (`pipeline.l`): a success-shaped
  postcondition would otherwise fire on every propagated error. The
  language reference now states the rule, and recommends the
  `result.isOk implies ...` form for `Result`/`Option` postconditions.
- Checking loop invariants at loop exit (#7224's remaining item) is not in
  this change.

## Verification

`ensures_self_test.l` gains three runtime cases, on `--target dotnet` and
`--target jvm`. Each returns early with an `ensures:`-violating value from
inside a `val` initializer, an assignment right-hand side, or an
expression-bodied match arm, and asserts `PostconditionViolated`.
