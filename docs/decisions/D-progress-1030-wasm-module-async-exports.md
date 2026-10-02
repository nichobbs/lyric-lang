# D-progress-1030 — Async exports of the wasm32 `module` shape are Promises driven by a host-polled scheduler

**Status:** shipped (W3 slice 2)

Extends D-progress-1029; implements the `module` half of `docs/35` §11.

## Context

The native backend runs `async func` on a cooperative single-threaded scheduler
(`lyric_async.c`) entered through `lyric_task_block_on`, which idles with
`nanosleep`. A browser cannot block its event loop, so an async export cannot
use that entry point.

## Decision

1. **An async `pub func` over the supported kinds is exported.** The wasm export
   returns the task (an ordinary `i32` pointer) after running to its first
   suspension; the JS wrapper returns a Promise. A `Task[T]`/`Async[T]`
   annotation is unwrapped to `T`.
2. **The host drives the scheduler.** `lyric_sched_poll` (new, in
   `lyric_async.c`) runs every ready task, wakes expired sleepers and returns
   the nanoseconds to the next timer, never blocking; `lyric_wasm_poll`
   (`lyric_wasm_async.c`) rounds that up to milliseconds. The glue calls it from
   `setTimeout`, resolves the Promise when `lyric_task_is_complete` turns true
   and rejects with a deadlock error when nothing is ready or sleeping.
   `lyric_task_block_on` is unchanged, so every other target behaves as before.
3. **Result decoding.** A task's result is its 64-bit slot, decoded the way the
   native backend stores it: `Int` sign-extended, `Bool`/`Byte` zero-extended,
   `Float` in the low 32 bits, `Double` as its bits, a `String` as its pointer
   (copied out, then the task is released, which releases the string).
4. **Argument lifetime.** `String` arguments of an async call stay alive until
   the task completes, since the coroutine may read them after its first
   suspension.
5. **Blocking sleeps.** A synchronous `run()` of a program that sleeps reaches
   `poll_oneoff`; the glue implements clock subscriptions with `Atomics.wait`
   where the host allows it and a spin otherwise, and documents that an async
   export is the non-blocking route.
6. **Link.** The scheduler entry lives in its own archive member and the link
   pulls it, with the task accessors, only when an exported function is async, so
   a synchronous module never links the scheduler or its coroutine symbols. The
   helper ABI version is 2.

## Consequences

- Concurrent async exports interleave on one scheduler, one host timer at a
  time per pending call.
- A task awaiting something other than a timer or another task (a future host
  `fetch`) will need a completion hook; the deadlock rejection is deliberate
  until then.
