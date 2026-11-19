# D409 - A bare `None` in a `return` takes the function's declared return type (docs/70 phase 3a, #8613)

**Status:** shipped; extends D401 (a function body's tail takes the declared return type).

## Context

`return None` inside a generic function (`func pick[T](n: in Int, x: in T): Option[T]`) leaves the `None` untyped in the checker: its type argument is the function's own parameter, which nothing at the `return` fixes. The builder settled a body's tail against the declared return type (D401) but not the operand of a `return` statement, so the body was counted ("the checker gave no usable type ... <error>", I0002): `Std.Task::runWithin` on the JVM. The non-generic `Option[Int]` version builds because the checker types it.

## Decision

`BuildEnv` records the declared return type of the function being built (`retTy`, none for a generator). A `return` outside a lambda settles its operand to it (`settleHole`), as the tail of the body is. A `return` in a lambda returns from the lambda, whose type is not recorded, so it is left as it was.

## Results

`return_hole_in_generic` in `scripts/ci/tir-builder-shapes-e2e.sh` builds with `--verify-ir` (verifier clean) and runs (exit 5); `Std.Task::runWithin` builds on the JVM.
