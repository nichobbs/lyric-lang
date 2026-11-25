# Native TIR lowering: instances over types from other units (docs/70 phase 4a)

Decision: D850. Slice 40 of phase 4a, part 7.

## What shipped

- `Ctx.tirKnownAll` and its use in `tirInstArg` (`lyric-compiler/lyric/llvm_codegen.l`); a trace line for each unregistered instance under `LYRIC_NATIVE_TIR_TRACE=1`.

## Remaining

Instances over invariant records (`Url`) wait on TIR invariant elaboration.
