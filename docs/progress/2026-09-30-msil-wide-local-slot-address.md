# MSIL: address-of-local and argument stores use the long form past slot 255 (#7822)

MSIL lowering emitted the short forms `ldloca.s`, `ldarga.s` and `starg.s`
for every `MLdloca`, `MLdarga` and `MStarg`, whatever the slot index. The
short form's operand is one byte, and the encoder wrote the index with
`bufU1` without checking its range. So in a method with more than 256 locals,
taking the address of slot 256 or higher silently addressed slot
`slot & 0xFF` instead. `MLdloc`/`MStloc`/`MLdarg` were already width-aware
(`emitLdloc`/`emitStloc`/`emitLdarg`); only the address-of and argument-store
paths were not.

An `async func` hits this most easily. Every `val` is hoisted into the
state machine's `MoveNext`, and the awaiter local is allocated after them. So
with more than 256 locals ahead of an `await`, `TaskAwaiter.IsCompleted` and
`GetResult` (both called through `ldloca`) ran against whichever local was
at `slot & 0xFF`. In the case that surfaced this, that was a `string`.
The result was undefined behaviour at runtime: `AccessViolationException`
and `DataMisalignedException` on linux-arm64, and a garbage
`EntryPointNotFoundException` from `IAsyncStateMachine.MoveNext()` on
osx-arm64, linux-arm64 and linux-x64. It was found as a production crash in
nichobbs/cloud-agents, whose `createRunnerContainer` had grown past 256
locals. The same wrap also breaks synchronous code without any exception: an
`inout` argument on a local at slot 256 or higher wrote to a different local,
and the caller's variable kept its old value.

`emitLdloca`, `emitLdarga` and a new `emitStarg` (with the matching long-form
`iStarg`) in `lyric-compiler/msil/opcodes.l` now choose the short form for
slot 0–255 and the two-byte-index long form (`FE 0D`/`FE 0A`/`FE 0B`) above
that, the same way `emitLdloc` does. `lowerMInsn` in `lowering.l` routes all
three instructions through them. `serializeMethodBody` now panics on a
short-form (`VarS`) index outside 0–255 instead of truncating it, so a future
caller that bypasses the width-aware emitters fails at compile time rather
than miscompiling.

Verified by `lyric-compiler/lyric/wide_local_slot_self_test.l` (dotnet):
an `await` after 270 locals, and an `inout` argument on a local declared after
270 others. Both tests fail on v0.7.3 (the `inout` case silently returns the
unmodified value) and pass with this change.
