# D852: the native TIR lowering takes closures over Unit values

Status: accepted (docs/70 phase 4a, part 7; D520 slice 42; completes D536's Unit leftovers for closures).

## Decision

1. **A lambda that captures a Unit local** leaves it out of the closure object: the capture owns no storage (D536), so the closure holds only the other captures and the body's slot for it is the Unit marker, which reads as Unit.
2. **A lambda with a Unit parameter** keeps the parameter in position: `funcType` no longer refuses a function type whose parameter is Unit (the function pointer type prints a Unit parameter as `i8`, as every other signature does), the body takes an `NVoid` parameter with no slot, and a call through the function value passes the `i8 undef` placeholder.

## Not done

A pattern on a Unit field (`case Tick(())`) and a Unit `out`/`inout` argument still fall back.

## Verification

`scripts/ci/native-via-tir/closures.l` gains a closure capturing a Unit local and a lambda with a Unit parameter; it lowers 10 of 10 functions from TIR with the AST path's output and runs clean under AddressSanitizer.
