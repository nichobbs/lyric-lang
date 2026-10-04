# D-progress-1043 — Async exports in the component shape

**Status:** shipped (W4 follow-up, tracked in #8117 item 4; resolves Q-JS-006 for v1)

## Decision

1. **The synchronous subset ships; real async WIT waits.** WIT `future<T>` and `stream<T>`
   depend on the Component Model async ABI, which `jco` and the preview2 shim do not yet
   treat as stable. An `async func` export is therefore an ordinary WIT function
   (`later: func(x: s32) -> s32`), and a host call to it blocks until the task completes.
   The build prints `W0041` for each, so the blocking is never silent.
2. **Lowering.** The generated shim for an async export is itself an `async func` that
   lifts the arguments, `await`s the user's function and lowers the result, as the
   synchronous shim does. Its raw symbol returns the task, so the C wrapper calls it,
   then runs `cabi_drive`: poll the scheduler (`lyric_wasm_poll`, the entry the module
   shape's glue also uses), return when the task is complete, trap when nothing can ever
   complete it (the module shape rejects the promise with a deadlock error), and
   otherwise `nanosleep` for the milliseconds until the next timer. The wasi-libc
   `nanosleep` is a WASI clock subscription the host's preview2 implementation answers.
3. **Scope of the blocking.** The wrapper owns the instance for the duration of the call;
   a component instance is single-threaded and not re-entered, so nothing else can run
   in it meanwhile. A host that needs concurrency uses the module shape (Promise-returning
   exports) or a separate instance.
4. **Linking.** The scheduler entry is referenced only from the generated C, so a
   component with an async export forces its archive member into the link
   (`--undefined=lyric_wasm_poll`); one without never links the scheduler.

## Not changed

An async *host import* (a `Promise` the host resolves later) still needs a completion hook
from the host to the scheduler; that is the browser-I/O work (#8117 item 7, #8118 item 1).
