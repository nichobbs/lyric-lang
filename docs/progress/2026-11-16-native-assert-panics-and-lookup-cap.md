# `assertPanics` on native, and a cap on in-flight name lookups (#9141, #9137)

- `Std.Testing.assertPanics` / `assertPanicsWith` now build and run on
  `--target native`. They call `Std.PanicTrapHost.trapPanic`, a kernel with a
  `try`/`catch` form in `_kernel/` (dotnet, JVM) and a native twin
  (`_kernel_native/panic_trap_host.l`) that runs the body in a forked child
  through three `lyric-rt` functions (`lyric_panic_trap_enter`, `_child_done`,
  `_join` in `lyric_rt.c`; `lyric_panic_msg` reports a trapped panic down the
  child's pipe). Design, rejected alternatives (`setjmp`/`longjmp`) and limits:
  D608. This takes the N0007 error off every test file that used either function
  (the hermetic suites of `cache-redis`, `session-redis`, `cache-memcached`).
- Tests: `lyric-stdlib/tests/assert_panics_native_tests.l` (panic passes,
  normal return fails with the message, allocation before a panic, repeated and
  nested use, a `requires:` violation, the in-memory-effects difference, `exit`
  reported rather than taken for a panic) and `test_panic_trap` in
  `lyric-rt/test/lyric_rt_test.c`. Windows and wasm32-wasi report "no fork" and
  fail the assertion (D608).
- `resolve_bounded` (`lyric_tls.c`, and `lyric_sock_win32.c`) caps lookups in
  flight at `LYRIC_RESOLVE_MAX_INFLIGHT` (32): past it a bounded connect to a
  name fails with "too many name lookups in flight" instead of starting another
  helper thread (D605 item 7). `test_resolve_inflight_cap` in
  `lyric_tls_test.c` reaches the cap through a test seam
  (`lyric_resolve_lookup_hook`) and runs under `make -C lyric-rt test` and
  `test-asan`.
