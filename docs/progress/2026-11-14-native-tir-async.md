# Native backend on TIR: async functions (docs/70 phase 4a, D520)

Async functions lower from TIR as coroutines with the AST path's prologue, retained reference
parameters, task completion on every return and cleanup blocks. Calls await in place, `spawn` keeps
the task, `await t` unwraps a `Task[T]` and `scope { }` lowers its body. Coroutines that call a
parking leaf (`sleepMillis`, fd waits, socket twins, process capture) and out/inout async
parameters stay on the AST path. `native-via-tir/async.l` runs both ways and under AddressSanitizer.
