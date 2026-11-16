# D440 - A never-ending loop and a generator body build as branches (docs/70 phase 3a, #8613)

**Status:** shipped; follows the D528 census.

## Context

The wide census (D528) counted 16 "branch conversion" bodies from two causes. A function whose last statement is `while true` (or `loop`) with no `break` out of it has the loop's type, `Unit`, where the checker accepts any declared return type, because control never reaches the end. A generator whose body ends in `try` was given the declared return type as the `try`'s expected type, but a generator's values are its `yield`s and its body is `Unit`.

## Decision

`neverCompletes` treats a `loop`, or a `while` whose condition is the literal `true`, as never completing when no `break` can leave it (an unlabelled `break` at the loop's own depth, or one naming its label; nested loops shield unlabelled breaks). The function body then meets any return type. A generator's body no longer takes the declared return type as the `try`'s expected type. Loops that can break, and conditions other than the literal `true`, are unchanged and stay counted.

The census residue of this kind is the `impl` members of extern interfaces (a record converted to a host interface type), which is a separate kind of conversion and stays counted.
