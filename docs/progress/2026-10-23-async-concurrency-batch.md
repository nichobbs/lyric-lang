# Async and concurrency fixes: woven async functions, JVM Unit locals, SM reload cost, bounded reads (#8287, #8294, #8295, #7201, #7515)

## #8287: an aspect-woven `async` function returned garbage on dotnet

The weaver renames an `async` target to `<name>__aspect_target` and wraps it
in an `async` wrapper, but the wrapper's `proceed()` became a plain call to
the renamed function. `Lyric.Propagate` makes every direct async call's
implicit await explicit using the type checker's call-site map, and it runs
before weaving, so the call the weaver synthesised was never awaited. On
`--target dotnet` the `Task` reference was stored into the `Int` (or `String`)
out-variable. The JVM and native backends await a direct call themselves,
which hid it.

`proceedSubstitution` (and the timed `call.elapsed` form) now wraps the call
in `EAwait` when the matched function is `async`. Every layer of a composed
chain is async, so each inner call is awaited. `aspect_weave_self_test.l` gains
value-type, reference-type and `Unit` cases (seen failing on dotnet before the
fix, passing on dotnet and JVM after); `llvm_self_test_async.l` adds the native
case. B'-mode (cross-package `from` templates) is not affected: its specialised
function takes `proceed` as a closure.

## #8294: JVM `VerifyError` in `unitValThenSuspend`

A `Unit`-typed `val` (`val u = doUnitWork()`) allocated a local slot but never
stored to it, since the call leaves nothing on the operand stack, while the
StackMapTable framed the slot as an int. The first branch target after it then
named a local no path had written. The binding now stores a zero to its slot
(`emitStoreBindingSlot`). `async_sm_self_test.l` (71 cases) passes on JVM and is
added to `scripts/ci/jvm-generics-self-tests-batch.sh`.

## #8295: async state machine IL was quadratic in shadowing blocks

`emitPhaseBAwait` reloaded every promoted slot registered so far at every
resume, including slots of blocks that had already exited. A promoted local now
carries a dead flag, set when its block exits (`exitBlockScopeMsil` records the
slot mark at entry) and cleared if the slot is written again; resumes skip dead
slots. The fields themselves stay. `msil_codegen_diag_self_test.l` compiles
functions with 1, 61 and 121 shadowing blocks and requires the second step of
output growth to stay under twice the first (before: 143 KB then 392 KB).

## #7201: native and F0045

Native has no protected region for a suspend to sit in: `try`/`catch`/`throw`
are not lowered (D-N-003) and codegen rejects them with N0007. `awaitInTryIsHazard
= true` is kept so `?` in a `try` gets F0045 at its own position and F0045
behaves the same on every target; the comments that said "pending audit" now
record the result.

## #7515: bounded reads

Decision: no `cancelPendingRead`. Cancelling the read behind a timed-out
`pipedReadLineWithin`/`readStdinWithin` would drop the partial line the
documented no-loss guarantee keeps. At most one read is outstanding per handle,
and it ends on data, `pipedKill` or `pipedClose`. This is now documented on both
functions and in docs/62, and `process_tests.l` pins that 25 consecutive
timeouts leave one reader (lines stay ordered, kill ends the read).

## Closed without code

#7196 (fixed earlier by #7838), #7767 (waited on since the #7766/#7767 change),
#5329 (all listed bugs verified fixed), #8259 (duplicate of #8367).
