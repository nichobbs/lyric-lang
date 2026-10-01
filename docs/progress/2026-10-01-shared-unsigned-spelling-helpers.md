# One home for the stringifying-builtin, unsigned-spelling and paren-strip helpers (#7861)

The unsigned-operand pipeline of #7812 depends on three passes agreeing on two
facts: which builtins stringify their arguments, and which expression shapes
already say they are unsigned. The type checker records a `UInt`/`ULong`
operand as a conversion site unless it is already spelled unsigned,
`Lyric.Mono.desugarCheckedFile` respells each recorded site as the identity
`.toUInt()`/`.toULong()`, and the MSIL and JVM backends lower exactly the
unsigned spellings with unsigned comparison, division, remainder and
stringification. Each pass carried its own copy of the rules:
`isStringifyingBuiltin`/`spellsUnsigned` in the type checker,
`isStringifyingBuiltinMono`/`spelledUnsignedMono` in Mono, `isUnsignedExprMsil`
(with `isUnsignedConvCallMsil`) in `Msil.Codegen` and `isUnsignedExpr` in
`Jvm.Codegen`. A name added to one list and not the other would have left an
unsigned value handled as signed with no diagnostic.

Both helpers now live once, as `pub` functions in `Lyric.Parser`
(`lyric-compiler/lyric/parser/parser_ast.l`, beside `argsWithDefaults`), which
every one of those passes already imports, so the package dependency graph is
unchanged. All five copies are deleted and every call site uses the shared
`isStringifyingBuiltin` / `spellsUnsigned`.

The four `spellsUnsigned` copies were not quite identical: the backends looked
through parentheses and the checker and Mono did not. The shared helper looks
through parentheses, so the checker and Mono now skip `(x.toUInt())` exactly
when the backends already treat it as unsigned, instead of wrapping it in a
redundant identity call.

The reserved-intrinsic name lists (`isReservedBuiltinFuncName`,
`isReservedIntrinsicNameMsil`, `isReservedIntrinsicNameJvm`) are a different,
larger set (T0140 redeclaration rules) and are unchanged.

The same review (#7888) found the paren-strip analog of this drift in the
open-tuple work of #7863. The checker registers a tuple literal matched
directly as an open site through any depth of parentheses (its private
`stripExprParens`), but `Lyric.Mono.tupleScrutineeTypedMono` unwrapped only
one `EParen`, so `match (((Ok(2), Err("abc")))) { ... }` was registered and
never rewritten, and built its open elements at `object` on dotnet ("match not
exhaustive"). `stripExprParens` now also lives once in `Lyric.Parser`; the
checker's copy and Mono's `unwrapParenExprMono` are deleted, and Mono strips
every level before deciding the scrutinee is a tuple.
`expected_type_propagation_self_test.l` adds a double- and a
triple-parenthesised matched literal, on both targets.

`parser_self_test.l` gains two cases: one asserts the exact set of
stringifying builtins (and rejects near-misses), the other pins the shapes
`spellsUnsigned` accepts and rejects.
