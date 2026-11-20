# D326 - A propagated `Err(e)` or `None` never yields, and a `Never` value builds (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker is unchanged.

## Context

`Err(e)?` and `None?` always propagate: the operand is the failure itself, so the `?` never produces a value and its success type is free (nothing fixes it). The checker records no type for such a node, so the builder counted every function using one (I0002, about twenty bodies of `propagate_ctor_operand_self_test.l` and `propagate_never_value_self_test.l`), and the shapes built from it (`None?.length`, `Err(e)? == x`, `(Err(e)?, 1)`, `if Err(e)? { ... }`) with it.

## Decision

`openHoleTy` types the `?` of a constructed `Err(...)` or `None` as `Never` (and `exprNeverCompletes` counts it as leaving, so a block ending in one is `Never` like one ending in `return`). The operand takes `Result[Never, E]` or `Option[Never]` through `propagateOperandTy`, which already gives the error type from the function. A value of type `Never` converts to any type (`CvFromNever`): a field read on one, an operator whose left operand is one, and a condition that is one (`buildCondition`, so the verifier's `Bool` rule holds) are built as that conversion of the receiver, the rest of the expression being unreachable. A tuple the checker left open takes the types of its elements.

Not covered, still counted: `?` of an `if`, `match` or block whose every branch fails (`(if c { Err(a) } else { Err(b) })?`), which needs a compound operand typed `Result[Never, E]` per branch.

## Results

`propagate_never` in `scripts/ci/tir-builder-shapes-e2e.sh` builds with `--verify-ir` (verifier clean) and runs (exit 15). `propagate_ctor_operand_self_test.l` builds all 58 bodies (was 52), `propagate_never_value_self_test.l` 8 of 13 (was 4).
