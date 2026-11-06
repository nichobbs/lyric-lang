# 2026-11-06 - Method, interface, protected-type and extern member calls record their callee (D365)

`recordMethodCalleeNode` resolves record-body, `impl` and interface methods by
their declaration span (`symTableMethodDeclId`), interface and protected-type
members record `Pkg::Type::member`, and extern member calls record an
`ExternCallSite` in `SymbolTable.externByNode`. Over the stdlib tests the
census now lists only distinct-type factories, `.copy`, a few computed callees
and some host instance calls. `tir_build_self_test.l` has an interface and
impl-method case (15 cases).
