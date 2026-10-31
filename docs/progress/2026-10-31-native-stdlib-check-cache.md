# Native builds cache the bundled-stdlib type check (#7971, D301)

A `--target native` build no longer re-checks the bundled `Std.*` packages it
reached on every build (#7933). Each package whose check was clean and recorded no
`array[N, T]` or record-arithmetic lowering site gets an entry under
`~/.lyric/cache/native-stdlib-check/` (`$LYRIC_CACHE_DIR`; `off` disables); the
next build with the same compiler, target OS and stdlib sources skips that check.
99 of 102 packages qualify. Design, key, soundness argument and the relation to
docs/70 are in D301.

Measured in the development sandbox (x86-64 Linux), interleaved runs, median of 5, `lyric build
--target native` of a program that imports:

| Program | Cache off | Warm cache |
|---|---|---|
| `Std.Http`, `Std.Collections`, `Std.Console` | 2.71 s | 2.19 s (-0.52 s) |
| all 48 public `Std` packages | 5.27 s | 2.64 s (-2.63 s) |

The generated LLVM IR is byte-identical with the cache off, cold and warm.

Tests: `native_stdlib_cache_self_test.l` (hit, invalidation of each key input,
corrupt/truncated/foreign/directory entries, compiler fingerprint, the cacheability
predicate against the real checker) in the compiler self-test batch, and
`scripts/ci/native-stdlib-cache-e2e.sh` (cold/warm, IR identity, content-keyed hit
across a copied stdlib, an edited `std/string.l` invalidating only its dependents,
four damaged entries re-checked and healed, an unwritable location) in the native
backend self-tests. `LYRIC_TRACE_STDLIB_CHECK_CACHE=1` prints each package's outcome.
