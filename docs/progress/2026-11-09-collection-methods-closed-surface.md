# 2026-11-09 - `List`/`Map`/`Set` method surface is closed: T0113 (D-progress-1054)

#7683. A method call on a `List`, `Map` or `Set` that names none of the members
the backends lower (and no function binding by UFCS or dot-name) is T0113 on
every target instead of a throwing stub (MSIL) or a codegen failure (JVM, native).
Tests: `typechecker_self_test.l` ("a method call on a collection names a built-in
member"), `testdata/reject/unknown_collection_method`. The other issues in the S5
batch (#7978, #7786, #8161, #8249, #8289, #8331, #8334, and #8104 except its
native item) already pass on main; each was re-run against a built binary.
