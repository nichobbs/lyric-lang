# A multi-threaded scheduler for native `async` tasks (docs/67 G8, #7947, D217)

- `lyric-rt/src/lyric_async.c`: opt-in multi-threaded mode (`LYRIC_ASYNC_THREADS=N`, N >= 2): worker
  threads plus every `lyric_task_block_on` caller run coroutines from one shared FIFO queue; two-phase
  await/sleep registration published after the coroutine function returns; atomic task `state`;
  `g_running`-based deadlock detection; the default cooperative mode is unchanged and lock-free.
- Codegen (`llvm_codegen.l`): `spawn` call sites raise `lyric_spawn_hint`, every coroutine prologue
  calls `lyric_task_defer_start` and takes a first suspend point when it returns 1, every async call is
  followed by `lyric_ramp_done`.
- `lyric_rt.h`: `LyricTask.state` atomic, `park_kind`/`park_dep`, the new entry points, and
  `LYRIC_RC_DEC_ORDER` (acq_rel decrements under ThreadSanitizer, which cannot see the ARC fence).
- Tests: `lyric-rt/test/lyric_async_mt_test.c` (busy-flag fake coroutines: fan-out with measured overlap,
  fan-in, 1500 register-vs-complete races, await chain, nested `block_on`, dropped handles) under
  `make -C lyric-rt test test-tsan test-asan-async`; `llvm_self_test_async_mt.l` (rendezvous that needs
  three simultaneous task bodies, recursive fork-join, sleepers, protected counter, ASan);
  `lyric-stdlib/tests/async_mt_tsan_main.l` under ThreadSanitizer via `scripts/ci/async-mt-e2e.sh`.
- Docs: D217, docs/01 section 7.4, docs/67, native/plan/06, book chapter 10 and appendix B, CLAUDE.md.
- Open: work stealing and a task-throughput benchmark (#8493), a compile-time sendability check so the
  mode can become the default (#8492), an async I/O reactor (#8494).
