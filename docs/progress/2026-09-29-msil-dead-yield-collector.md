# MSIL: remove the unreachable list-collector `yield` lowering

`FuncCtx.yieldSlots` in `lyric-compiler/msil/codegen.l` backed an old
collect-all generator model: each `yield e` appended `e` to a `List<object>`
held in the slot. Nothing has populated the list since generators became
`async func`s lowered through the lazy `TaskCompletionSource` protocol (D119):
`makeFuncCtxMsil` created it empty and no code ever added to it, so the
`EYield` arm's `fctx.yieldSlots.count > 0` branch was unreachable. A `yield`
outside an `async func` is rejected by the type checker (T0094), so the lazy
generator context is the only `yield` lowering. The field, its construction
and the branch are removed; the arm's remaining fallback still panics with
"yield outside async generator", which only a front-end bug could reach.
`docs/progress/2026-09-29-for-generator-callee-resolution.md` noted the dead
branch while fixing #7771.

Verified by the generator self-tests (`generator_for_loop`,
`async_generator`, `generator_control_flow`, `generator_dispose`,
`generator_closure_var_capture`, …) in the compiler self-test batches and
`scripts/ilverify-selfhosted.sh`.
