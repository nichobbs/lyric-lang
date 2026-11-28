# D885 - The TIR builder builds format1-format4 as a call of `Std.String.formatArgs`

**Status:** accepted, implemented in the TIR builder (docs/70 phase 3c, §6.3; found by the native-via-TIR census, phase 4a)

## Decision

1. **`formatN(template, a1, ..., aN)` is `Std.String.formatArgs(template, [toString(a1), ..., toString(aN)])`** when `Std.String.formatArgs` is visible in the package's symbol table: an `XCall(Direct(formatArgs))` whose second argument is an `XListLit` of `slice[String]` holding each argument stringified as `toString` does (`stringPart`). This is the rewrite `Lyric.Pipeline.lowerFormatBuiltin` gives every AST-path build (#7840), so the placeholder grammar stays in one Lyric function and every target stringifies a `UInt`, a `Double` and a `Byte` the same way.
2. **Without `Std.String` in scope the built-in stays**, as for D884.
3. The checker still validates the template (`T0199`) and respells unsigned arguments; the builder builds from the checked node.

## Effect

A function calling `format1`-`format4` lowers from TIR on native when `Std.String` is imported. `tir_build_self_test.l` covers both forms.
