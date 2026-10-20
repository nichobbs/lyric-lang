# `buffer[T]` on native (docs/67 G2, #7941, D186)

`buffer[T]` now works on `--target native` with packed storage and copy on write.

- Runtime: `LyricBuffer` and `lyric_buffer_new` / `_copy` / `_unique` in
  `lyric-rt` (unit-tested in `lyric_rt_test.c`; layout pinned by static asserts).
- Codegen: `__buffer<T>` struct type, element access by GEP into the packed
  array, length from the header, an inline reference-count check before each
  element write that takes a private copy only when the block is shared, the
  copy intrinsic as the identity, and the `Std.Buffer` list bridge as copy loops.
- Tests: `llvm_buffer_self_test.l` (8, under AddressSanitizer with leak
  detection; asserts no allocation for unshared writes and one copy for the
  first shared write), `buffer_self_test.l` and `buffer_spawn_self_test.l` on
  native, all in `native-backend-self-tests.sh`.
- Bench: `benchmarks/bench_buffer.l`. 100 passes over a 10 000-element buffer
  take about 0.86 ms per run on native; the copy-on-first-write bench allocates
  one buffer copy per iteration.
- Found on the way: an array or buffer passed to `spawn` is copied inside the
  task on the JVM, so the task sees later writes (#8391, also true of arrays).

Open under #7941: `withPointer`/`withMutPointer` with the `N0100` extension, the
verifier's array model, the `lyric lint` rule, the lazy managed form (#8389), a
native `filled` that skips the list.
