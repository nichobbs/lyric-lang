# Checked ULong conversions (#8450, #7901)

`ULong.toLong()` is now a checked conversion (panics above `Long.MaxValue`) and
`ULong.toDouble()` / `toFloat()` convert the unsigned value, on MSIL and the JVM (D278; native does not support the `ULong` type at all yet, so it has no surface for them). They were `T0103`. The type checker records the call as an
overflow site (`ulong:<method>`); `Lyric.ContractElaborator.lowerOverflowChecks`
lowers it to plain `Long` operations before any backend runs, so the panic message
and the rounding are the same on both targets and no backend changed.

Files: `lyric-compiler/lyric/type_checker/typechecker_exprs.l`
(`noteUnsignedSourceConversion`), `lyric-compiler/lyric/contract_elaborator/overflow.l`
(`ulongConversion`), `docs/01-language-reference.md` §4.1, `book/chapters/appendix-b-quick-reference.md`.
Tests: `conv_methods_self_test.l`.
