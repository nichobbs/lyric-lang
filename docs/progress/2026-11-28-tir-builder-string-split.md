# The TIR builder builds String.split as a direct call (docs/70 phase 3c, D884)

## What shipped

- `buildStdSplitCall` (`tir/build/build_expr.l`): `s.split(sep)` with `Std.String` in scope is a `Direct` call of `Std.String.split`, no longer `IoBuiltin("String.split")` (D884). Without the import the built-in stays.
- Native census: a function calling `String.split` lowers from TIR (the census repro printed "1 of 3 functions lowered from TIR" before the format1 and `toSlice` items, with the same output as the AST path); `llvm_stdlib_self_test.l` passes 61/61 with `LYRIC_NATIVE_VIA_TIR=1`.
- `tir_build_self_test.l`: both forms.
