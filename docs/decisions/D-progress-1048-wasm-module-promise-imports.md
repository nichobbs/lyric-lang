# D-progress-1048: Promise host imports in the wasm32 module shape

**Status:** shipped (docs/35 W3/W4 follow-up, #8117 item 7, first slice; unblocks #8118 item 1 for the module shape)

## Decision

1. `@wasmImport("module", promise)` marks an extern whose JS function may return a Promise
   (or a plain value). The extern keeps its plain result type; `promise` is the only flag
   after the module name, and anything else is `N0014`. (`async` is a keyword and cannot be
   an annotation argument; `promise` names what the host returns.)
2. A call is an ordinary async call for the language: from an `async func` it suspends the
   calling task until the promise settles and other tasks run meanwhile, `await` is allowed
   and changes nothing, and `spawn` inside a `scope` starts several at once. Codegen treats
   the import's signature as async and declares the wasm import as returning the pending
   task pointer.
3. The runtime gains host-finished tasks: `lyric_host_task_new` returns a pending task (two
   refs, one for the caller, one the host spends), `lyric_host_task_finish` stores the result
   and wakes the waiters, `lyric_host_task_fail` finishes it with a message. Reading the
   result of a failed task panics with that message. `lyric_sched_poll` returns `-2`, not
   `-1`, when the only thing left is a pending host operation, so the glue waits for the
   host instead of reporting a deadlock.
4. The JS glue creates the pending task, calls the host function, and finishes the task from
   the promise; a rejection fails it, and every settlement re-runs the active scheduler
   steps. A rejected promise therefore panics the Lyric code that was waiting, with
   `host import failed: <message>`; a host that wants a recoverable failure resolves to a
   status value. Typed `Result` completion is future work (it needs union construction from
   JS).
5. Awaiting a host operation from a synchronous function aborts with a message naming the
   fix (make the caller `async`): the host cannot finish the operation until the call
   returns.
6. The `.d.ts` types such an import as `Promise<T> | T`, and quotes host import names that
   are not plain identifiers (`'fetch-text'`).
7. `--shape component` rejects the flag (`N0018`): the Component Model async ABI is not
   stable (docs/35 Q-JS-006), and a blocking import would stall the host.

## Not covered

A `fetch`-backed `Std.Http` twin on this hook, and `Std.File` with no preopened filesystem
(both still #8117 item 7). `Async[...]` results across NPM imports in the component shape
(#8118 item 1) wait on the component async ABI.
