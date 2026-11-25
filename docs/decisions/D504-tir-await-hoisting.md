# D504 - Await hoisting on TIR: every `await` on an empty stack

**Status:** accepted, implemented as `Lyric.Tir.AwaitHoist` (docs/70 phase 3c, §7.2)

## Decision

1. **`Lyric.Tir.AwaitHoist.hoistAwaitsFn`** is the last middle-end pass on TIR, the counterpart of `Lyric.AwaitHoist` and `Lyric.HoistEngine`. A backend that lowers `await` to a state machine on a stack machine loses what is on the evaluation stack when it suspends; the pass leaves every `await` evaluating on an empty stack. In an operand list (call arguments with an `Indirect` callee's function value first, a construction's fields, tuple, list and interpolation elements, an index's receiver and index, a range, a copy) with an operand containing an `await` and operands ahead of it, every operand up to and including the last awaiting one is bound, in evaluation order, to a fresh local ahead of the statement, and the expression reads the locals. An awaiting first operand stays in place (nothing is ahead of it).
2. **Conditional parts keep their preludes inside them**: a short-circuit right-hand side, an `if` or `match` branch, a guard and a `try`, `catch` or `finally` body are wrapped as blocks, so a hoisted binding runs only when its part does. A `while` condition containing an `await` becomes `loop { prelude; if cond' { body } else { break } }`. An assignment to a field or an element binds the target's operands and then the value. A lambda or `spawn` body is a deferred computation and is not entered.
3. **`Lyric.Tir.Walk` finds the awaits** (the presence test cuts at lambdas and `spawn`). Node ids come from 900,000,000 up, shared per package; locals from 1,700,000,000 up per function. `Pipeline.pipeHoistAwaitsTir` is the entry; `--verify-ir` prints an `I0003 hoist census` and `tir-census.sh` counts it toward its gate.
4. **Order.** It runs last, after contract elaboration, `?` lowering and monomorphisation: the `return`s and matches those passes introduce are hoisted like the user's. The native backend, which lowers to LLVM and has no evaluation stack, does not need the pass; the JVM and MSIL ports do.

## Not done

`forall`/`exists` bodies and `old(..)` are not entered (quantifiers never lower to code); an `out`/`inout` argument's place is not entered; the pass is not yet consumed by a backend (phase 4).
