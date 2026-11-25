# Loop invariants on TIR (docs/70 phase 3c)

Decision: D510.

## What shipped

- `Lyric.Tir.Loops` / `Pipeline.pipeLoopsTir`: loop `invariant:` clauses asserted each iteration and after a loop that ends normally; `while` as a `loop` with the exit check in its guard, `for` with a break flag; wired into the native bridge after `?` lowering.
- `TsInvariant` carries its text; `Walker` has a statement hook (`preStmt`, `newWalker`).
- `lyric-compiler/lyric/tir_loops_self_test.l` and `scripts/ci/native-via-tir/loops.l` (runtime: per-iteration, exit-only violation, `break` exemption, panic message).
