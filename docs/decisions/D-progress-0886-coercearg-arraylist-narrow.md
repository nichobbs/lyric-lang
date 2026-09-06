# D-progress-886 — JVM codegen: `coerceArgTo`'s `ArrayList` → array conversion now narrows to the real element type instead of always producing `Object[]` (#5931 review follow-up, #6970)

**Status:** shipped

**Context.** Automated review of D-progress-885's PR found the new test
coverage was one-sided: only the parameter-side narrowing
(`implParamTypesToJvm`) had a regression test, while the sibling return-type
narrowing (`lowerImplMethod`'s `retTy` path) had none. Adding a test using
the PR's own motivating example — `impl X509TrustManager for Record { func
getAcceptedIssuers(): slice[JX509Certificate] { [] } }` — immediately
reproduced a real, distinct `VerifyError: Bad return type`: the method's
declared descriptor was correctly narrowed to
`[Ljava/security/cert/X509Certificate;`, but the body's `[]` literal builds
an `ArrayList` (ordinary Lyric slice-value semantics), and nothing converted
that `ArrayList` into the narrower array type before the `areturn`.

**Root cause.** `Jvm.Codegen.coerceArgTo`'s `JArray` arm converts an
`ArrayList` value to an array via the no-arg `Collection.toArray()`
overload unconditionally — whose erased return type is always `Object[]`.
That was sufficient for the pre-existing erased-`Object[]` slice ABI, but
once `retTy`/`implParamTypesToJvm` can request a narrower `JArray(elem =
SpecificType)` target, the no-arg overload's `Object[]` result is not
assignable to it — the exact `VerifyError` class this whole fix exists to
eliminate, now reached through the coercion helper the fix itself didn't
touch.

**Fix.** When `toTy`'s element type is a non-`Object` reference type,
`coerceArgTo` now emits the typed `Collection.toArray(T[])` overload
instead: `anewarray <elemClass>` with a zero-length count builds a real
`T[]` to pass in (the JDK allocates a fresh correctly-typed array whenever
the supplied one is too small, per `Collection.toArray`'s contract), then a
`checkcast [Lclass;` after the call narrows the verifier's *static* tracked
type to match what is genuinely on the heap at runtime (the call's own
erased descriptor is still `([Ljava/lang/Object;)[Ljava/lang/Object;`, so
without the `checkcast` the verifier would still see `Object[]`). The
`elemTy == Object` case is untouched, preserving the exact prior behavior
for the ordinary erased slice ABI.

**Verification.** New `iface_dispatch_jvm_self_test.l` case (`impl
X509TrustManager for SliceIfaceTrustManager`) reproduces the reported
`VerifyError` before the fix and passes after it —
`iface_dispatch_jvm_self_test` 8/8. No regression: `ffi_iface_impl_jvm_self_test`
(2/2), `record_method_jvm_self_test` (19/19), `out_inout_jvm_self_test`
(18/18), `control_flow_jvm_self_test` (17/17),
`silent_miscompile_guard_jvm_self_test` (44/44).
