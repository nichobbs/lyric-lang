# wasm32 module: promise host imports (docs/35 follow-up)

`@wasmImport("module", promise)` externs return a Promise the calling task waits for
(D-progress-1048): host-finished tasks in the runtime, a `-2` "waiting on the host" poll
result, glue that finishes the task from the promise and kicks the scheduler, and the
`Promise<T> | T` typing. Tests: C unit tests for host tasks (native and under wasmtime), and
a node-driven module test covering String, Long, Double, Float, Bool, Byte and Unit results,
sequential and concurrent (`spawn`) waits, a rejected promise, a call from a synchronous
export, and the `.d.ts`; the component shape rejects the flag. Open in #8117: a
`fetch`-backed `Std.Http` twin, `Std.File` without preopens.
