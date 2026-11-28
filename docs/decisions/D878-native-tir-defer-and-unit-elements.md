# D878: the native TIR lowering takes `defer` and Unit elements

Status: accepted (docs/70 phase 4a, part 10; D520 slice 53).

## Decision

A `defer` block (`TsDefer`) registers in the innermost lexical scope. Each scope keeps its pending blocks beside its reference locals (`LCtx.defers`, pushed and popped with `refScopes`), and they run in reverse declaration order at every exit from the scope, before the scope's references are released: normal fall-off (`popRefScope`) and `return`, `break` and `continue` (`releaseDownTo`, for every scope it leaves). The block is lowered again at each exit, so a scope with many exits repeats it in the IR (a shared cleanup block is a later size optimisation); a scope's list is emptied while its blocks run, so a `return`, `break` or `continue` inside a deferred block cannot run the block it is in again. A `panic` still bypasses them (no unwinding on native, D-N-003). A `defer` inside a coroutine stays on the AST path ("a defer in a coroutine") until a suspend point inside a deferred block has a defined meaning.

`String.normalize` and `String.isNormalized` stay on the AST path: the Unicode normalization tables are not in lyric-rt, and a program that reaches them is refused at compile time (#7304, #7452: tests pin the refusal), which a run-time trap in the lowering would change. They leave the census when the tables are ported.

A list or map element of type `Unit` (`List[Unit]`, `Map[String, Unit]`) is a zero slot that reads back as Unit (`listElemOk`, `slotOf`, `fromSlot`), as the AST path stores it; `unit_value_self_test.l` now builds from TIR.

`llvm_self_test_defer.l` (eight cases: fall-off, `return`, `break`, `continue`, nesting, order, a panic before the defer) now runs these functions from TIR.
