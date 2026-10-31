# Verifier: generic aliases of Result and Option (#8631, item 3)

`alias R[T] = Result[T, String]` was left unexpanded, so `R[Int]` was an
uninterpreted sort and a function using it failed closed. `registerScalarAliases`
now registers a generic alias whose right-hand side is `Result`, `Option` or a
nullable type, with its type-parameter names (`genericAliasKey`,
`genericAliasParamsKey` in the file's distinct-type map), and
`sortOfTypeExprDepthRaw` expands `R[Int]` by substituting the arguments written
at the use (`expandGenericAlias`), including inside a generic function
(`R[U]`). A generic alias of any other type, a wrong argument count and a value
argument are left as before (fail closed).

Items 1 and 2 of #8631 shipped in #8646. Tests: `verifier_self_test.l`, "a
generic alias of Result or Option is expanded at its use (#8631)".
