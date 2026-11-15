# D471 - `Exception.typeName` and the `Result`/`Option` `value` and `error` projections are built-in property reads (docs/70 §6.2, #8613)

**Status:** shipped.

## Context

The wide census after D470 left "a member access that is not a record field" at 2 sites in the compiler, 3 in the ecosystem libraries and 3 in the self-tests. The named members were two shapes: `e.typeName` on a catch-bound exception (`Exception.typeName`, the checker types it `String` like `message`), and `r.value`, `r.error` and `o.value` on a `Result` or `Option` (`ensures: result.isOk implies result.value >= 0`, the checker's `monadAccessorType`).

## Decision

- `builtinPropertyName` names `Exception.typeName` beside `Exception.message`; the read is a call of that built-in with the receiver as its argument, as every built-in property read is.
- `r.value`, `r.error` and `o.value` on the real `Std.Core` `Result` and `Option` (origin package `Std.Core`, not a user type of the same name) are the built-ins `Result.value`, `Result.error` and `Option.value`: the partial projection of the payload of the case that holds the receiver, which a contract states under `isOk`/`isSome`. They are not `Std.Core` functions: `unwrapResult` and `unwrapOption` carry a `requires:` that a read inside a contract would have to satisfy circularly, and no function reads the `Err` payload without a default. The checker's typing (`monadAccessorType`) is unchanged.

## Not covered

The partial projection's behaviour on the wrong case (a panic outside contracts) is the backends' to define when phase 3b lowers the built-in, as for the other built-in property reads.
