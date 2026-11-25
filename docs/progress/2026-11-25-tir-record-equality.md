# TIR builder: == and != on a structural record (D164)

docs/70 phase 3c (#8613, #9394 item 1). `==` and `!=` on a record with no `var` field (or one deriving
`Equals`) is rewritten into field-by-field comparisons by `Lyric.ContractElaborator.lowerRecordEq` on the AST.
In TIR the operator stayed an `IoEq`/`IoNeq` intrinsic on a record type, so the native lowering reported
"an operator on <record>" and kept the function on the AST path.

The builder now handles the sites the checker recorded in `SymbolTable.recordEqSites`
(`buildRecordEq`): the two operands are bound once each, left to right, to locals; each leaf path of the site
(a nested record expanded into its fields, a distinct type through its value, read off the typed locals) is
compared with `IoEq`; the comparisons are joined with the short-circuit `and`, and the conjunction is negated
with `IoNot` for `!=`. The result is a block, so `Lyric.Tir.Verify` accepts it as any other.

Not in this slice: a site with an array leaf, a tuple or union holding an array, a `Float`/`Double` leaf
(the D172 NaN rule), or a leaf path the builder cannot read (through a generic record) keeps the single
`IoEq`/`IoNeq` on the record type that the builder produced before, with no error recorded (`lyric prove`
builds TIR and fails on an I0002, so an inexpressible case must not become one). Covered by four cases in
`tir_build_self_test.l` (nested record, `!=`, the Float fallback, a record holding a generic record).
