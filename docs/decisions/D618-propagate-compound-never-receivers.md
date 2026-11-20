# D618 - `?` of a branching operand that always fails, members of a value that never exists, and an assignment of an open value (docs/70 phase 3a, #8613)

**Status:** shipped; builder and the AST mapper, the checker accepts exactly what it did.

## Context

D326 built `Err(e)?` and `None?` as `Never` and left four shapes of `propagate_never_value_self_test.l` counted (I0002), plus three bodies in the protected-type self-tests:

- `(if c { Err(a) } else { Err(b) })?`, the same with a `match` whose arms are all `None`, and a branch that is a block with statements before its failure: the checker records no type for the operand or its branches.
- `val n = None?.length` and `val (s, n) = (Err(e)?, 1)` followed by `s.length`: the member read on a value that never exists has no recorded type, and neither does one on a local bound to such a value.
- `item = None` into a field of a generic protected type (`Chan[T]`, `Slot[T]`): the checker leaves the `None` open and the assignment built the right-hand side without the place's type.
- `entry bump(by: in Int = 1)`: the default of a protected entry's parameter had no `NodeId`, because `mapFileNodes` rebuilt an entry with its parameters as written.

## Decision

`propagatesAlwaysDeep` extends D326's `propagatesAlways` to an `if`, `match` or block every branch of which ends in a failure construction; the `?` of such an operand never yields (`exprNeverCompletes`, `openHoleTy`), and its operand takes `Result[yielded, E]` or `Option[yielded]` with the enclosing function's error type from the checker's record of the operand (`propagateOperandTy`), settling each branch to it through `buildOrBlock` as a branch of any `if` is settled. A member read or method call whose receiver never exists (`neverReceiver`: that `?`, or a local the builder declared `Never`) is `Never` too, built as the conversion of the receiver (D326). `buildAssign` settles a plain assignment's right-hand side to the place's type before building it. `mapFileNodes` maps a protected entry's parameters, so their defaults are numbered like a function's.

## Results

`propagate_compound` in `scripts/ci/tir-builder-shapes-e2e.sh` builds with `--verify-ir` (verifier clean) and runs (exit 112); `propagate_never_value_self_test.l` builds all 13 bodies (was 8), `generic_protected_self_test.l`, `protected_exclusion_dotnet_self_test.l` and `method_default_args_self_test.l` build their protected bodies.
