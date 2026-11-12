# D583 - A branch that leaves through a nested `if`, `match`, `break` or `continue` fits the type of the whole (docs/70 phase 3a, #8613)

**Status:** shipped; extends D361.

## Context

A branch of a value-producing `if` or `match` is typed as the whole when it never completes, because control leaves before a value is needed. The builder recognised only a block with no tail whose last statement was `return`, `throw` or a `scope` ending in one. Every other leaving branch was counted as `a branch conversion` from `Unit`: a block ending in a nested `if` whose branches both return, a `match` whose arms all leave, a `break` or `continue`, and an expression statement that never completes. The wide census after D581 held about 125 such sites in the compiler area (`Unit` to `Int` 84, `Unit` to `String` 9, `Unit` to `Result`/`Option` types, the rest).

## Decision

- `neverCompletes` generalises the test: a tail-less block whose last statement is `return`, `throw`, `break`, `continue`, a `scope` that never completes, or an expression statement that never completes; an `if` with an `else` whose branches both never complete; a `match` whose arms all never complete.
- A branch that never completes is retyped as the whole (`retypeNeverCompleting`), and the branches of a nested `if` or `match` are retyped with it, because the verifier accepts a branch that is not `Never` only at the type of the whole.
- A branch conversion that still fails records its site and the two types in its message.

## Measured

`tir_build` 150 and `tir_verify` 27 pass; a new case builds and verifies a nested `if` whose branches return, a `break` branch in a loop, and a `match` arm that returns. The wide census was not re-measured for this change alone.
