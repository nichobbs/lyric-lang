# Native backend on TIR: the bundled standard library and parity fixes (docs/70 phase 4a, D520)

A `--via-tir` build builds TIR for each bundled `Std.*` package and lowers the functions it
covers from it; the census reports them on their own line. The stdlib, collections and
invariant-boundary native self-tests pass under `LYRIC_NATIVE_VIA_TIR=1`. Running them found
and fixed four divergences from the AST path: D163 overflow checks, invariant records, calls
to async functions and `String + scalar`. `LYRIC_NATIVE_TIR_TRACE` and `LYRIC_NATIVE_TIR_SKIP`
bisect a miscompile without rebuilding.
