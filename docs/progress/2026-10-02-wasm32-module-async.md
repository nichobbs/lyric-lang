# wasm32 `module` shape: async exports as Promises driven by host timers (docs/35 W3, slice 2)

Second slice of phase W3 (D-progress-1030). An `async func` in the program's own
packages whose parameters and result are over the supported kinds is exported
by `--shape module` as a Promise-returning JS function.

## What ships

- `lyric_sched_poll` (`lyric_async.c`) and `lyric_wasm_poll`
  (`lyric_wasm_async.c`): run ready tasks without blocking and report the time
  to the next timer; `lyric_task_block_on` is untouched.
- Glue: async wrappers that start the task, poll from `setTimeout`, decode the
  result slot (Int, Byte, Bool, Long, Float, Double, String, Unit) and resolve
  or reject; a `poll_oneoff` clock shim for blocking sleeps in `run()`; helper
  ABI version 2.
- `Lyric.WasmGlue`: async functions are no longer excluded (`W0040` no longer
  names async), `Async[T]`/`Task[T]` annotations are unwrapped, the export table
  carries `async: true` and the `.d.ts` declares `Promise<T>`.
- Link: the scheduler entry and task accessors are exported only when an async
  function is.
- Test fixes carried from the slice-1 review: a `Byte` case in the scalar round
  trip, and a stray blank line in `docs/01`.

## Tests

`llvm_wasm32_module_self_test.l` (10 cases) gains: an async export resolving
after its sleep with `String`, `Long`, `Double` and never-suspending results,
two concurrent async calls finishing in sleep order, and `run()` sleeping 40 ms
through `poll_oneoff`.
