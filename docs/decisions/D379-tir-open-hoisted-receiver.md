# A method receiver the hoist recorded a closed type for takes it (docs/70 phase 3a, #8613)

**Status:** shipped for a receiver the checker recorded in `hoistOperandTypeSites`; the receiver whose type only the method's parameters fix, with no hoist, stays counted (tracked in #8613).

## Context

`val r: (Option[Int], Int) = emptyCell().tagged(await five())`: the receiver `emptyCell()` leaves `T` open, the hoist records the type the expected result fixes (`Cell[Int]`), but `buildMethodCall` read the receiver's type from the call site (`Cell[<error>]`) and failed (`await_hoist_typed_self_test.l`, `openReceiverFromResult`).

## Decision

When the site's receiver type does not convert, `buildMethodCall` takes the receiver's closed type from the build (`exprOrOpenTy`, which reads `hoistOperandTypeSites`), settles the receiver expression to it, and instantiates the member at its arguments: the owner's arguments of `instantiateMethod` and the member's parameter types come from that type.

## Results

`await_hoist_typed_self_test.l` `openReceiverFromResult` builds. `openReceiverFromArgument` (`emptyCell().orDefault(await five())`, a receiver typed by an argument alone) is not covered and is still counted.
