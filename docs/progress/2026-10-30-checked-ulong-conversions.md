# Checked ULong conversions (#8450, #7901)

`ULong.toLong()` is now a checked conversion (panics above `Long.MaxValue`) and
`ULong.toDouble()` / `toFloat()` convert the unsigned value, on MSIL, the JVM and
native alike (D278). They were `T0103`. The type checker records the call as an
overflow site (`ulong:<method>`); `Lyric.ContractElaborator.lowerOverflowChecks`
lowers it to plain `Long` operations before any backend runs, so the panic message
and the rounding are the same everywhere and no backend changed.

Files: `lyric-compiler/lyric/type_checker/typechecker_exprs.l`
(`noteUnsignedSourceConversion`), `lyric-compiler/lyric/contract_elaborator/overflow.l`
(`ulongConversion`), `docs/01-language-reference.md` §4.1, `book/chapters/appendix-b-quick-reference.md`.
Tests: `conv_methods_self_test.l`.
