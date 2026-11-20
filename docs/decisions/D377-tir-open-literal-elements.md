# D377 - An open element of a bracket literal, and an open left operand of an equality, take their neighbours' type (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker is unchanged.

## Context

The checker types a bracket literal whose elements mix a typed construction with a bare one (`[Some(1), None, Some(3)]`, `[Ok(1), Err("abc")]`) as the slice of the joined type but records no type for the bare element (`None`, `Err("abc")`), and types `None == f()` with no type for the bare left operand (the right operand of `x == None` was already settled from the left). The builder counted each such body unbuilt (I0002): `await_hoist_typed_self_test.l`, `list_literal_join_self_test.l` and four more files.

## Decision

An element of a literal the checker typed as `slice[T]` or `array[N, T]` is settled to `T` before it is built (`settleHole`, as an argument is settled to its parameter's type). A literal the checker left untyped is typed from its elements: one that holds typed elements of a single type is the slice of it, and one whose elements are all `Some(x)`/`None` or all `Ok(x)`/`Err(e)` is the slice of `Option[typeof x]` or `Result[typeof x, typeof e]` when every payload's type is known and the payloads of one case agree (`ctorListJoinTy`). An operand of `==` or `!=` the checker left untyped takes the type of the other, typed one (`settleLeftFromRight`). Nothing the checker accepts changes, and a literal whose elements disagree stays counted.

## Results

`list_literal_open_elements` in `scripts/ci/tir-builder-shapes-e2e.sh` builds with `--verify-ir` (verifier clean) and runs (exit 9). `list_literal_join_self_test.l` builds 9 of 9 bodies (was 6), `await_hoist_typed_self_test.l` 53 of 55 (was 48).
