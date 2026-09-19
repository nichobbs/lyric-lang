# D-progress-936 — `emitGenericMethodExternCall`'s method-own-generic return narrows a genuine reference-type wrapper return, not just the value-type case (review follow-up)

**Status:** shipped

**Context.** A `claude-review` pass on PR #6981 flagged (SUGGESTION) that
`emitGenericMethodExternCall`'s return-handling code (D-progress-929, Gap 2)
only narrowed a method-own-generic return (`MMethodTypeVar`, witnessed as
`System.Object` by the MethodSpec) back to the wrapper's own declared type
when that declared type was a BCL VALUE type (`unbox.any`, #6989). A wrapper
declaring a genuine (non-`Object`) REFERENCE type at that position had no
corresponding `castclass` — the erased `object` was left on the stack and
returned as-is.

**Reachability.** Unlike D-progress-932's `MValueTypeGenericInst` parameter
case (confirmed unreachable through every current Lyric-side mechanism),
this shape is trivially reachable with a real, unremarkable BCL API:
`System.Linq.Enumerable.First<TSource>(IEnumerable<TSource>): TSource` is
exactly Gap 2's family (a method-own generic on a non-generic-declaring
type), and wrapping it with a Lyric-declared `String` return (instead of the
`Int` the existing #6989 test already covers) hits this gap directly. A
`@externTarget` wrapper declaring any non-`Object` reference-type return for
a method-own-generic BCL method — not just `First<T>` — would silently
build IL where the CLR verifier's declared-return-type check fails against
the `object` actually left on the stack.

**Fix.** Added an `else if retIsMethodVar` branch (alongside the existing
value-type `unbox.any` branch) that calls `castObjectToMsil` — the same
shared erased-`object`-to-concrete-type coercion helper already used
elsewhere in this file for exactly this class of narrowing. `castclass`
(unlike `unbox.any`) is null-safe per ECMA-335 §III.4.6, so no null-guard
is needed here, unlike the value-type branch's dup/brtrue/pop dance (which
exists specifically because `unbox.any` throws `NullReferenceException` on
a null erased return). A wrapper that genuinely declares `Object` as its
return type falls through `castObjectToMsil`'s own `MObject` no-op case, so
this adds no overhead to the common erased-return path.

**Verification.** New test in `generic_extern_methodspec_self_test.l`
("Enumerable.First<TSource>'s reference-type return is narrowed from the
witnessed Object") reuses the existing `repeatStr`/`IEnumerableOfT[String]`
infrastructure from the #7016 test to construct a `String` source sequence,
then asserts `firstOfStr` round-trips the value correctly — proving the
`castclass` narrows to the right type, not just that the call doesn't crash.
Full regression sweep (`generic_extern_methodspec_self_test.l` 6/6,
`msil_project_bridge_self_test.l` 59/59, `typed_ffi_delegate_self_test.l`
5/5, `generic_extern_self_test.l` 7/7, `auto_ffi_self_test.l` 23/23,
`nested_generic_self_test.l` 8/8, `mono_self_test.l` 87/87,
`cross_package_generics_self_test.l` 11/11, `msil_restored_bridge_self_test.l`
6/6, `generic_extern_valuetype_instance_self_test.l` 2/2) plus `make ilverify`
(123 DLLs, 0 IL-validity errors), all green.

**Related:** #6581/D-progress-929 (Gap 2, this entry's base), D-progress-930
(#6989, the value-type side of this same return-narrowing dance),
D-progress-932 (the contrasting *unreachable* parameter-side case, for
comparison), PR #6981.
