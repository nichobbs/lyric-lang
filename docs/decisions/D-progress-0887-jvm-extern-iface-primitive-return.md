# D-progress-887 — JVM codegen: extern-interface `impl` methods now convert a `slice[Elem]` RETURN value into the real primitive array type, not just reference-element arrays (#5931 review follow-up, #6977)

**Status:** shipped

**Context.** Automated review of D-progress-886's PR found `implTypeExprToJvm`'s
own doc comment ("a primitive slice element needs the real primitive array
too, not just an extern one") was aspirational, not implemented: the TYPE
resolution side (`TSlice(elem) -> JArray(elem = implTypeExprToJvm(elem,
...))`) already correctly resolves a primitive element (`Byte` -> `JByte`),
but the CODEGEN/coercion side (`coerceArgTo`'s `JArray` arm, fixed in
D-progress-886 only for reference-typed elements) had no handling for a
primitive target: its `case _ ->` fallback still emitted the old no-arg
`ArrayList.toArray()` (erasing to `Object[]`), which is not assignable to
e.g. `byte[]`.

**Root cause.** `coerceArgTo` cannot allocate the loop-temp local slots a
primitive-array conversion loop needs (no `FuncCtx` parameter — the same
constraint `emitArrayToArrayListJvm`'s own comment documents for the
opposite direction), so it never attempted a primitive-element narrowing at
all.

**Fix.** New `coerceArgToCtx(ctx, insns, fromTy, toTy)` in `04_calls.l`:
delegates to `coerceArgTo` for every shape except `ArrayList -> JArray(elem)`
where `elem` is a JVM primitive, in which case it calls the no-arg
`toArray()` (giving `Object[]`) then reuses the EXISTING
`emitUnboxObjectArray` helper (already used elsewhere for the ordinary
Lyric-slice-argument-to-JDK-primitive-array FFI direction) to unbox each
element into a freshly allocated primitive array. `lowerInstanceMethodBody`'s
two return-coercion call sites (`FBBlock`'s implicit tail return, `FBExpr`)
now call `coerceArgToCtx` instead of the plain `coerceArgTo` — this is the
single body-lowering tail both `lowerImplMethod` (extern-interface impls)
and `lowerProtectedMethod`/`lowerRecordMethod` (whose `retTy` is never
narrower than the ordinary erased `Object[]` slice ABI, so the new branch
is unreachable there — a safe no-op) share, per that function's own
"prevent the two call-sites from drifting" design.

**Known remaining gap (parameter side, not fixed here).** The reviewer's
finding also named the PARAMETER-side narrowing
(`implParamTypesToJvm`/`registerInstanceSigImplExtern`) as sharing this same
primitive-element gap: an ordinary Lyric caller passing an `ArrayList`-backed
`slice[Byte]` value as an argument to an extern-interface impl method whose
parameter narrows to `byte[]` would hit the identical `VerifyError`. Unlike
the return path (a single, well-defined call site in
`lowerInstanceMethodBody`), the parameter path's argument-to-`sig.params[i]`
coercion is duplicated across 6+ independent call-lowering functions in
`04_calls.l` (static calls, instance calls, UFCS, holder-mode variants,
etc.) — all of which pass `ctx` and could in principle reach an
extern-interface impl call, since Lyric's call dispatch does not have a
separate "impl method call" code path. A comprehensive fix requires
auditing and updating every one of those call sites; given the currently
severe CI/runner capacity constraints and the complete absence of any
concrete failing repro or real ecosystem usage of a primitive-element
`slice[T]` PARAMETER (as opposed to return) on an extern-interface impl,
this is deliberately left as an open, precisely-scoped follow-up rather
than risking an incomplete or under-tested sweep across every call site
under time pressure. Concrete repro shape for whoever picks this up:
`impl SomeExternIface for X { func consume(data: in slice[Byte]): Unit {
... } }` called as `x.consume(someArrayListBackedByteSlice)`.

**Verification.** New `iface_dispatch_jvm_self_test.l` case (`impl
java.security.Key for SliceIfacePrimitiveKey { func getEncoded():
slice[Byte] { [1, 2, 3] } }`) reproduces the reported `VerifyError: Bad
return type` before the fix and passes after it, asserting all three byte
values round-trip — `iface_dispatch_jvm_self_test` 9/9. No regression:
`ffi_iface_impl_jvm_self_test` (2/2), `record_method_jvm_self_test`
(19/19), `out_inout_jvm_self_test` (18/18),
`out_inout_instance_jvm_self_test` (9/9), `control_flow_jvm_self_test`
(17/17), `silent_miscompile_guard_jvm_self_test` (44/44).
