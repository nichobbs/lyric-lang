# Component shape: a call that exits keeps the scheduler armed (D184 A3 follow-up)

Fixes a hang in the concurrent-call runtime of `--shape component` builds
(`docs/progress/2026-10-18-component-concurrent-calls.md`).

When an async export's task completed in its own scheduler turn, `cabi_turn`
returned `EXIT` straight after `lyric_sched_poll`, before arming the WASI 0.3
timer for the remaining sleepers. The timer that had just fired was already
dropped, so a second call still sleeping (for example `later(5, 20)` and
`later(6, 120)` started together) was left parked with nothing to wake it; jco
traps that as "deadlock detected". `cabi_turn` now runs every ready task and
arms the timer for the earliest sleeper before it reports a done call `EXIT`.

Review follow-ups from #8386 in the same change:

- `lyric_cabi_async_done` panics with a glue-bug message, instead of
  dereferencing null, when its call record is missing.
- `lyric_cabi_host_call` grows the subtask table through a temporary, as
  `cabi_call_begin` does for the call table.
- `cabi_call_end` documents why a subtask left in no set loses no event: a
  waitable keeps its pending event until it is delivered, and the next call
  joins it to its own set.
- `importSignature` binds the `promise ` prefix to a named value.

The import subtask's cancelled branch is not tested: only a `subtask.cancel`
by the caller reaches those states, and the glue never cancels an import. A
comment now says so.

Verified locally with wasi-sdk 34, wasmtime 49.0.3, wasm-tools 1.262.0, jco
1.39.0 and node 24.22.0: `llvm_wasm32_component_self_test.l` 27/27, whose jco
concurrency test gains two cases. In the first, the first call exits while a
later call still sleeps; this case deadlocked before the fix. In the second,
the first call exits while a later call still waits on a host import.
