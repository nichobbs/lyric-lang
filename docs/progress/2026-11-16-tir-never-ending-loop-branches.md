# 2026-11-16: the TIR builder covers never-ending loops and generator bodies (D440)

A function ending in `while true` or `loop` with no `break` out of it, and an `async` generator body ending in `try`, now build (D440). `neverCompletes` gains the loop cases (`blockMayBreak` follows labels and loop depth), and a generator's body no longer takes the return type as the `try`'s expected type. Three `tir_build_self_test.l` cases cover both, and a loop with a `break` stays counted. Extern-interface `impl` members remain counted. Docs/70 status updated.
