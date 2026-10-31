# JVM: inout place cached across loops that cannot reach it (#8371, D298)

Root cause: D183 made `out`/`inout` parameters `Lyric$Ref$<K>` references read
and written through interface calls at every use. A callee reached with several
kinds of place has megamorphic call sites the JIT cannot inline, so a hot loop
in it ran 3-5x slower than before D183.

Fix: `appendLoopWithRefCache` (`lyric-compiler/jvm/codegen/05b_loop_ref_cache.l`)
keeps the place in the parameter's value slot across a `while`/`loop` whose
compiled body has no call, field access, allocation, array access, division,
cast, return, throw or outward jump and uses one place reference. One `get`
before, one `set` after. Anything else is unchanged.

`benchmarks/bench_inout.l`, JVM, medians of 3 runs of 7 (base `c30cda0` vs this
change): mixed places 490 ms to 86 ms, break loop 3700 ms to 231 ms.

Tests: `inout_loop_cache_self_test.l` (dotnet, JVM), existing inout suites on
the JVM unchanged. Docs: `docs/18-jvm-emission.md`, D298.
