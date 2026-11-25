# `?` lowered on TIR, and the shared TIR walker (docs/70 phase 3c, D503)

`Lyric.Tir.Propagate` turns `XPropagate` into a bind-and-match with an early `return` of the rebuilt failure (`Err(x)` / `None`), verified by `tir_propagate_self_test.l` (the source's `?` count before and after, and `Lyric.Tir.Verify` on the result). `Lyric.Tir.Walk` is the rewriting traversal it is built on. `Pipeline.pipePropagateTir` is the entry and `--verify-ir` prints an `I0003 propagate census`. Operand-position hoisting and nullable propagation are not covered (see the decision).
