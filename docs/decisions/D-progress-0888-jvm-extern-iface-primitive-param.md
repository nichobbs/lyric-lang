# D-progress-888 — JVM codegen: close the extern-interface impl parameter-side slice-narrowing gap left open by D-progress-887 (#5931 review follow-up, #6977 param-side)

**Status:** shipped

**Context.** Automated review of D-progress-887 (the return-side primitive-
array-narrowing fix) noted that the PARAMETER-side half of #6977 was still
open, and confirmed it wasn't fully resolved rather than auto-closing the
finding. Writing a concrete regression test for it (an ordinary Lyric
function forwarding a `slice[Byte]` PARAMETER into an extern-interface
`impl`'s narrowed `byte[]` parameter — `java.util.zip.Checksum.update(byte[],
int, int)`) surfaced that the actual gap is broader than the decision-log's
own D-progress-887 entry assumed.

**Root cause.** D-progress-887's `coerceArgToCtx` only handled a
`fromTy = JRef("java/util/ArrayList")` source — correct for a FRESHLY
CONSTRUCTED slice value (a literal, matching every test D-progress-886/887
used), but a `slice[T]`-typed LOCAL or PARAMETER already stored in a JVM
slot carries the ordinary erased ABI's OWN representation instead:
`JArray(elem = Object)` (a real `Object[]` reference), not `ArrayList`. A
plain function like `func wrap(cbs: in slice[JCallback]): Unit { h.handle
(cbs) }` (the #6960 shape, previously found NOT to reproduce because `cbs`
there was a param truly typed `Object[]` calling into `Object[]`-agreeing
JVM covariance rules that happened to work) differs from THIS shape only in
that the CALLEE's parameter is now narrowed (byte[] or a specific reference
array) rather than staying `Object[]` — and `coerceArgToCtx`'s `case _ ->`
fallback for a `JArray(Object)` source silently no-opped, leaving the
erased `Object[]` value on the stack where the narrowed descriptor demanded
`byte[]`/`SpecificType[]`.

**Fix.** `coerceArgToCtx` gains a `JArray(elem = Object)` source arm,
narrowing via the SAME copy-loop machinery as the `ArrayList` source (no
`ArrayList.toArray()` step needed first, since the source is already an
array): primitive targets reuse the existing `emitUnboxObjectArray`; a new
`emitNarrowObjectArrayRef` (a `checkcast`-per-element copy loop, the
reference-typed sibling of `emitUnboxObjectArray`) handles a narrower
reference-array target. The `ArrayList`-source arm also gains the same
reference-array case (it previously only narrowed a primitive target,
matching the D-progress-887 gap's own oversight for non-primitive
reference-array literals). All 10 `coerceArgTo(insns, aTy, sig.params[...])`
/ holder-arg call sites converted to `coerceArgToCtx` in the prior D-progress-887
commit needed no further changes — the dispatch on `fromTy`'s shape lives
entirely inside `coerceArgToCtx` itself.

**Verification.** New `iface_dispatch_jvm_self_test.l` case: a real JDK
interface (`java.util.zip.Checksum`) with a `byte[]`-taking method,
implemented by a record, called by forwarding an ordinary `slice[Byte]`
parameter through a plain Lyric function. Reproduces the reported
`VerifyError: Bad type on operand stack` before the fix (confirmed via
`javap`: the call site pushed the parameter's raw `Object[]` with no
conversion before `invokevirtual update:([BII)V`) and passes after it,
asserting the real array length is observed inside the impl method —
`iface_dispatch_jvm_self_test` 10/10. No regression: `ffi_iface_impl_jvm_self_test`
(2/2), `record_method_jvm_self_test` (19/19), `out_inout_jvm_self_test`
(18/18), `out_inout_instance_jvm_self_test` (9/9),
`control_flow_jvm_self_test` (17/17),
`silent_miscompile_guard_jvm_self_test` (44/44),
`jvm_cross_package_collision_self_test` (7/7).
