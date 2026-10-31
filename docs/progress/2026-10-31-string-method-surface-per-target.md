# T0113 for an unknown `String` method, per target (#7204)

The type checker now knows the target's `String` method surface, so an unknown
`String` method is T0113 on dotnet (closed set) and on the JVM (anything not in
`java.lang.String`'s metadata), while `getBytes()` and the rest of the JDK's
methods stay valid on the JVM. Native and target-less checks (the language
server) are unchanged. See D299.

Tests: `typechecker_self_test.l` (per-surface cases), the existing JVM `getBytes()` self-tests (`hash_jvm_self_test.l`, `try_catch_expr_jvm_self_test.l`), and `lyric-compiler/lyric/testdata/reject/`.
