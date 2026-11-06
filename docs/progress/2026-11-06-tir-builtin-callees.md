# 2026-11-06 - Built-in and collection-member calls record their callee name (D362)

`SymbolTable.builtinByNode` records the name of a built-in function or built-in
member under the call's `NodeId` (`recordBuiltinCall`, `recordBuiltinCallee`),
and `Lyric.Tir.Build.callCovered` counts a call covered by either callee table.
`tir_build_self_test.l` has a new case for `println` and a slice member (12 cases);
the existing uncovered-call case now uses a call through a function value. The
typechecker (1119), emitter_project, resolve, mono, weaver and derives self-tests
pass. Next: function values, interface and extern members, then instantiation.
