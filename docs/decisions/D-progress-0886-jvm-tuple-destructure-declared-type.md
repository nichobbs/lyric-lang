# D-progress-886 — JVM codegen: `val (a, b): (T1, T2) = <expr>` tuple destructuring now binds each element at its declared type instead of blanket `Object` (#6578)

**Status:** shipped

**Context.** `val (sslContext, authMode): (JSSLContext, Option[JSslClientAuthMode])
= match tls.clientCa { case Some(ca) -> { ...; (ctx, Some(value = mode)) }; case
None -> (serverSslContextFromConfig(...).rawContext(), None) }` — a tuple
destructure whose two match arms build the tuple via differently-shaped
expressions (one a block with intermediate `val`s, the other a bare inline
tuple) — crashed at class-load with `VerifyError: Bad type on operand stack`
the moment `sslContext` (declared `JSSLContext`, a real `javax.net.ssl.
SSLContext` extern type) was later passed to a parameter expecting that type.

**Root cause.** `Jvm.Codegen.lowerLocalPatBind`'s fallback for any pattern
other than a bare binding or wildcard — which a `PTuple` (`val (a, b) = …`)
falls into — always routed through `lowerPatternBind`'s own `PTuple` arm,
which unconditionally types every extracted element as `java/lang/Object`
(the ONLY correct behaviour for a match-ARM tuple pattern, which has no type
annotation to consult). For a top-level `val (a, b): (T1, T2) = expr`
LET-binding, this ignored the declared tuple-type annotation entirely: `a`'s
local slot registered as `Object` regardless of the annotation, so a later
use requiring `T1` emitted no `checkcast` and the StackMapTable's local-slot
frame stayed `java/lang/Object` — a VerifyError at that use, independent of
whether the two match arms built the tuple the same way or not (the
"divergent arm shapes" framing in the original report was an incomplete
diagnosis; the bug is unconditional for any annotated tuple destructure of a
non-`Object` element type).

**Fix.** `lowerLocalPatBind` gains a dedicated `PTuple` arm: when the
declared type annotation (peeling `TParen`) is a `TTuple` of the same arity,
each element is extracted, `checkcast`/unboxed (`coerceArgTo`) to its own
annotation-derived JVM type, and bound at that type. An absent, mismatched,
or non-tuple annotation falls through to the pre-existing blanket-`Object`
binding, unchanged.

**Verification.** New `stackmap_expr_branch_jvm_self_test.l` case
reconstructs the reported divergent-arm shape with a real extern type
(`java.lang.StringBuilder`) standing in for `JSSLContext`, asserting the
destructured element is usable (`sb.append(...)`) without a VerifyError and
that the second element binds correctly —
`stackmap_expr_branch_jvm_self_test` 10/10. No regression in
`record_method_jvm_self_test`, `out_inout_jvm_self_test`,
`control_flow_jvm_self_test`, `try_catch_expr_jvm_self_test`, and
`silent_miscompile_guard_jvm_self_test` (all green).

**Correction (CI follow-up).** This file's other nine cases are
deliberately target-portable (per its own header comment: "the shapes are
target-portable; the JVM run is the load-bearing one"), but this file is
wired into CI on BOTH `--target jvm` and `--target dotnet`
(`.github/workflows/ci.yml`). The `java.lang.StringBuilder` extern type
above does not exist as a .NET reference-assembly type, so the
`--target dotnet` run failed with `error[T0120]: auto-FFI call 'new' on
extern type 'java.lang.StringBuilder' cannot be resolved`. Replaced with a
plain Lyric `record TextBox { var text: String }`: the underlying bug is
triggered by any non-`Object`-typed tuple element, not specifically an
extern one, so a record reproduces the identical shape (confirmed by
reverting the fix as a negative control — without it, the codegen's own
erased-receiver check now rejects `box.text`/`appendToBox(box, ...)` with
`error[J007]: member 'text' cannot be resolved on an erased (statically
Object) receiver`, a compile-time rejection rather than the original
runtime `VerifyError`, but an equally definite regression signal) while
compiling cleanly on both targets — `stackmap_expr_branch_jvm_self_test`
10/10 on both `--target dotnet` and `--target jvm`.
