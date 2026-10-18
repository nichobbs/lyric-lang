# D184 - The wasm32 component shape uses the Component Model async ABI

**Status:** accepted, implemented (slices A1 async exports, A2 promise imports, A3 concurrent calls)

## Context

docs/35 Q-JS-006 held `future<T>`/`stream<T>` and async exports back until
the Component Model async ABI stabilised. Until then an `async func` export
is a blocking WIT function that drives the scheduler inside the call (`W0041`,
D-progress-1043), and a `@wasmImport(..., promise)` extern is rejected in the
component shape (D-progress-1048).

The spike in `docs/progress/2026-10-17-component-async-spike.md` found that
the async ABI (`async` functions, `future`, `stream` and their canonical
built-ins) shipped in WASI 0.3.0 and is frozen until 1.0. Stackful lift and
`error-context` remain gated. wasm-tools 1.262.0, wasmtime 49.0.3 and jco
1.39.0 (node >= 24) build and run hand-written async components through the
same wasip1 + preview1-adapter pipeline Lyric uses; the toolchain moved to
those versions in #8377.

A follow-up prototype checked the one design point the spike left unverified:
a call can wake another, parked call through a private unit `future`
(`[future-new-unit]`, wit-component 0.262.0). Under jco 1.39 a call parked on
a unit future resumes when a second, concurrent call writes it. jco traps a
store in which every call is parked and no host operation is pending ("deadlock
detected"), which the lowering below never produces: a call only parks while a
subtask (a host import or a timer) is outstanding.

## Decision

1. **Mapping.** A `pub async func` export of a component package is a WIT
   `async func` with the same parameters and result. A
   `@wasmImport("m", promise)` extern is a WIT `async func` import. The
   `Task[T]` a Lyric `async func` returns is not itself a WIT type: the
   asynchrony is the function's, as both hosts present it (a Promise in jco, a
   concurrent call in wasmtime). This replaces docs/35's earlier
   "`Async[T]` maps to `future<T>`" row.

2. **Stackless callback lift only.** Lyric's coroutine lowering is stackless,
   so every async export uses `canon lift ... async (callback ...)`: the core
   export `[async-lift]<name>` and its callback `[callback][async-lift]<name>`.
   The gated stackful lift is never used.

3. **One scheduler turn per callback.** The entry and each callback run
   `lyric_sched_poll`. When the call's task is complete, its result is
   lowered as the synchronous path lowers it, passed to `[task-return]<name>`
   as flat parameters (a pointer past 16 flat values), anything it allocated
   is freed, and the callback returns `EXIT`. Otherwise it returns `WAIT` on
   the call's waitable set. A call whose task can never complete (no ready
   task, no timer, no outstanding subtask) traps, as `cabi_drive` does today.

4. **Timers are subtasks.** A sleeping task becomes an async-lowered call to
   WASI 0.3 `wasi:clocks/monotonic-clock@0.3.0.wait-for` for the earliest
   deadline, never a busy `YIELD` or a blocking `nanosleep`. A component that
   has an async export or a `promise` import declares that import in its
   WIT. Hosts need WASIp3 clocks: wasmtime 49 (on by default) or jco with
   `@bytecodealliance/preview3-shim` >= 0.11 on node >= 24.

5. **Host imports are subtasks.** A `promise` import is async-lowered. A call
   that returns `RETURNED` produces an already-finished task; otherwise the
   import returns a pending host task (`lyric_host_task_new`) and its subtask
   is recorded with its argument and result buffers. A `SUBTASK` event frees
   the arguments at `STARTED` and, at `RETURNED`, lifts the result, finishes
   the host task (`lyric_host_task_finish`, or `lyric_host_task_fail` for a
   lift error) and drops the subtask.

6. **Concurrent calls.** Each call keeps its state (task, result snapshot,
   waitable set, wake-up future) in a per-call record reached through
   `context.get`/`context.set` slot 0, never a global. An async shim
   snapshots its lowered result into its own call's record when the task
   completes, because the turn that completes it may belong to another call.
   A call whose task completes outside its own turn (in another call's turn,
   or inside a synchronous export's blocking wait) is woken through a private
   unit `future` (`[future-new-unit]`): it parks with a pending `future.read`
   in its own set, and the completion writes the future. Outstanding subtasks
   live in the waitable set of one live call (the home call); when it exits
   they move (`waitable.join`) to another live call's set, which that call is
   already waiting on, or out of any set until the next call starts. A call
   retires its future by writing it if nothing did and taking the completed
   read through `future.cancel-read`, since a future's writable end can only be
   dropped once written and its read end only once its event is delivered.
   (Slices A1 and A2 shipped with a second concurrent call trapping; A3 lifts
   that.)

7. **`future<T>` values are deferred.** A `future<T>` as a parameter, a field
   or a sync result is a separate boundary type when a consumer needs it, not
   `Task[T]`: docs/68 plans to stop a `Task[T]` handle escaping its `scope`,
   and a future crossing the boundary always escapes. Until then such a
   signature is not exportable, with a diagnostic.

8. **`stream<T>` values are deferred.** When needed, only `stream<u8>` maps,
   onto the byte interfaces of `Std.Stream` (`ByteReader`/`ByteWriter`), which
   covers the WASI 0.3 byte streams (CLI, HTTP). A generic async stream type
   waits for a consumer.

9. **Cancellation.** A `TASK_CANCELLED` event is acknowledged and the call
   runs to completion (`task.cancel` is optional). Mapping it onto a Lyric
   cancellation hook waits for docs/68's `cancel`.

10. **`W0041` is retired** for the component shape once A1 ships.

## Slices

| Slice | Scope |
|---|---|
| A1 | Items 1 to 4, 9 and 10 for exports; the per-call record and result snapshot of item 6, with a second concurrent call trapping |
| A2 | Item 5: `promise` host imports |
| A3 | The rest of item 6: concurrent calls, wake-up futures, subtask migration |

## Consequences

- The component shape gains a WASIp3 import (`wasi:clocks@0.3.0`) whenever it
  carries async code; a JS host needs `@bytecodealliance/preview3-shim`
  beside `preview2-shim`, and jco's async output needs node >= 24.
- docs/35 §3 and §11 describe the mapping; Q-JS-006 is resolved.
- Stackful lift, `error-context`, `future<T>` and `stream<T>` values stay out
  of scope until a later decision.
