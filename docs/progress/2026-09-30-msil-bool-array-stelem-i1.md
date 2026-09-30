# MSIL: store `Bool` array elements with `stelem.i1` (#7783)

A `Bool` value sits on the evaluation stack as an I4: `ldc.i4 1`, a `ceq`
result, or an `ldelem.u1` read. The dotnet backend stored it into a `bool[]`
element with the generic `stelem <System.Boolean>` form, which ILVerify
rejects with `StackUnexpected [found Boolean]`. This hit every `slice[Bool]`
literal, index store and fast-path store, in `slice_array_abi_self_test`
(6 errors), `slice_fastpath_self_test` (2) and `list_literal_index_self_test`
(2).

`Char` elements had the same problem and were fixed by switching to
`stelem.i2` (#5563). `Bool` now gets the matching `stelem.i1` (new
`MStelemI1` MIL instruction). The seven hand-copied
`if elem == MChar { stelem.i2 } else { stelem <tok> }` store sites share one
helper, `emitArrayElemStoreMsil`: array literals, the typed and fast-path
index stores, the compound index store, the `List`-to-array copy, the
array-append builder, and hoisted-var cells.

The three self-tests above now verify with 0 errors and are added to
`scripts/ilverify-selfhosted.sh` phase 4.
