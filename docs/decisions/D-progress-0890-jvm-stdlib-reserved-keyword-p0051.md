# D-progress-890 — JVM codegen: a reserved keyword used as a local name in a bundled stdlib source now fails the build with P0051 instead of an opaque codegen panic, or silent success when unreached (#5550)

**Status:** shipped

**Context.** Using the reserved keywords `out` or `end` as local names in a
BUNDLED STDLIB package surfaces as an opaque `Jvm.Codegen: unsupported
assignment-target expression shape` panic at bundle time, while the
identical code as USER code gets the proper P0051 parse error naming the
reserved word. Found while rewriting the JVM kernels in PR #5544.

**Root cause.** `Jvm.Bridge.compileProjectToJarBundledWithRestored`'s
stdlib-parsing loop treats EVERY stdlib parse diagnostic as advisory
(reported nowhere, never gating the build) — a deliberate design, since the
self-hosted `Lyric.Parser` has known gaps against some stdlib source and
promoting every diagnostic to fatal would break unrelated builds. But P0051
("`<keyword>` is a reserved keyword and cannot be used as a `<X>` name") is
categorically different from those gaps: it fires only when `readIdent`/
pattern/expression parsing could not bind a real identifier at all, so the
offending AST node carries a synthetic `"<error>"` name — guaranteed to
reach codegen malformed and panic with a message that names the wrong
thing. Worse: since the loop runs over EVERY bundled stdlib source
unconditionally (not just ones the entry package imports), an UNREACHED
package with this exact bug compiled "successfully" — the broken package
was simply, silently, never mentioned again.

**Fix.** A new `reservedKeywordDiags` helper filters a diagnostic list down
to P0051 entries. In the stdlib-parsing loop, any such diagnostic on ANY
bundled source — reachable or not — aborts the build immediately via
`DiagUtil.diagReportAndAbortInPkg`, printing the real parse-time cause
instead of letting a malformed AST reach codegen.

**Verification.** New `jvm_registry_rollback_self_test.l` case bundles a
stdlib source using `end` as a `val` name — never imported by the entry
package — and asserts `compileToJarBundled` returns `false` (previously it
returned `true`, silently dropping the broken package):
`jvm_registry_rollback_self_test` 2/2, with the real `error[P0051]`
diagnostic visible on stderr. No regression in
`jvm_cross_package_collision_self_test` (7/7) and
`jvm_stdlib_compiled_bundle_self_test` (3/3).
