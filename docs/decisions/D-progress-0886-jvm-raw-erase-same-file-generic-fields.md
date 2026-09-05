# D-progress-886 — JVM codegen: a generic union case / record field typed as ANOTHER same-file generic instantiation now erases to its raw class instead of universal `Object` (#4870)

**Status:** shipped.

**Context.** #4870 reported that a generic union case whose field is typed as
*another* generic instantiation using the enclosing type parameter —
`Branch(left: Box[T], right: Box[T])` inside `union Tree[T]` — miscompiled on
both targets: constructing such a case and reading a field back through a
monomorphized function faulted at runtime. A case field carrying a *bare*
type parameter (`One(a: T)`) already worked on both targets; the gap was
specifically a field whose declared type is itself a parameterized generic
application over the still-open enclosing `T`.

**MSIL half already fixed.** PR #6388 (D-progress-736) shipped the MSIL side:
nested-`TGenericApp` recursion in `typeExprToMsilG`, generics-aware field
registration, deferred `MLdfldGeneric` FieldSig encoding, nested-position
construction-site type-arg inference, a dangling-type-var-hint guard, and a
`Lyric.Mono` gap (inference-only ctor decls were synthesized for generic
union cases but never for generic *records*, so a bare `Box(item=10)` call was
invisible to ctor-arg unification). Verified against `main`: this issue's exact
repro now prints `ok` on `--target dotnet` with zero further changes needed.
This PR is the JVM half.

**Root cause (JVM).** `typeExprToJvm`'s `TGenericApp(head, _)` arm
(`jvm/codegen/01_types.l`) special-cased only the bare builtin heads `List`/
`Map` (→ `ArrayList`/`HashMap`) and erased **every other** generic head —
including a same-file user record like `Box[T]` — unconditionally to
`java/lang/Object`. This is a different class of bug than the MSIL side (no
substitution/registration bug at all): the JVM backend has no reified
generics, so a `Box[T]`-typed field is *supposed* to erase — but it should
erase the way Java's own raw-type erasure erases a parameterized generic
reference, to the **raw class** `Box` (type args dropped), not to `Object`.
`Object` is correct only for an erased *type parameter itself* (`Ok(value:
T)`, tracked via `JvmCaseField.paramIdx`); `Box[T]` is not a type parameter,
it is a concrete, locally-declared generic record whose own instantiation is
irrelevant to how the *field slot* is typed.

Because the case-field registry (`collectFileCasesExtern`) and the actual
bytecode field descriptor (`lowerRecord`/`lowerUnion`) both compute a field's
JVM type through the SAME erasure helper (`typeExprToJvmErasedExtern`), the
registered type and the emitted descriptor agreed with each other (both
`Object`) — so this was not a registration/emission *mismatch* the way #6329's
earlier, reverted MSIL attempt found; the erasure itself was simply wrong.
Once a match-bound local (`r` in `case Branch(l, r) -> r.item`) carried the
wrong static type `Object`, a subsequent field read (`r.item`) could not
resolve directly against `Box`'s own field registry and instead needed the
erased-`Object` bundle-wide `field:<name>` fallback — surfacing at runtime as
a `ClassCastException` unboxing the whole `Box` instance to the caller's
monomorphized concrete return type (`Int`), because the receiver's real
identity as a `Box` was lost before the field read ever ran.

**Fix.** Give the JVM backend Java-style raw-type erasure for same-file
generic types, scoped exactly like the existing `recordRetClassOf` /
`localRecordNames` precedent (#6399): a new
`collectFileLocalGenericTypeNames(file)` (`jvm/codegen/06_items.l`) pre-scans
a file's own `IRecord`/`IExposedRec`/`IUnion` declaration names (GENERIC or
not — this is deliberately broader than `collectFileDeclaredTypeFqns`, which
skips generics because it feeds cross-package FQN seeding, not same-file raw
erasure). A new `typeExprToJvmErasedExternL` (`jvm/codegen/01_types.l`) adds
exactly one new arm to the existing erasure chain: a bare `TGenericApp` head
found in `localTypeNames` resolves to `JRef(pkgName + "/" + head)`; every
other shape (bare type params, extern aliases, cross-package generics,
`List`/`Map`) is unchanged, delegating straight through to the pre-existing
`typeExprToJvmErasedExtern`. `collectFileCasesExtern` (the registry) and
`lowerRecord`/`lowerUnion` (the real field descriptor emitter) both now call
this new function with the SAME `localTypeNames` map (threaded once, from
`file`, at the top of `codegenPackageWithSigsSeeded`), so registry and
descriptor stay in lockstep by construction — no new mismatch class
introduced. No change to construction, matching, or field-read codegen was
needed: once the field's static type is correctly `Box` instead of `Object`,
the existing (already-correct, already-tested) non-erased member-access path
handles the rest.

**Scoping — deliberately same-file only.** Resolving a cross-package generic
type (a bare, unqualified `Result`/`Option`, or an imported user generic
record) would require knowing its DECLARING package, which this per-file pass
does not have; guessing wrong would silently corrupt an otherwise-working
cross-package field with a nonexistent class reference. Verified this stays
safe: `cross_package_generics_jvm_self_test.l` (7/7, restored-dependency
generic records/unions consumed from a producer JAR) is unaffected — those
types are never in the CONSUMER file's own `localTypeNames`, so they keep the
pre-existing `Object` erasure + bundle-wide fallback path unchanged.

**Verification.** Regression-guarded by 4 new cases appended to
`lyric-compiler/jvm/generic_jvm_self_test.l` (28/28 total): the exact #4870
repro (`Branch.right.item`), the symmetric `left` field, a `String`-payload
instantiation, and a same-`Tree` `Leaf` (bare-`T`) case to confirm the
existing bare-type-param path is untouched. Confirmed load-bearing by
reverting the codegen fix and rebuilding: the new cases fail closed at
COMPILE time (`error[J007]: member 'item' cannot be resolved on an erased
(statically Object) receiver`) rather than at runtime — the #4877-era
diagnostic hardening already turns this class of bug into a loud compile
error instead of a silent `ClassCastException`, consistent with the MSIL
fix's own comment that this same hardening was an incidental side effect
there. No regressions found in the surrounding generics-adjacent JVM
self-tests exercised: `generic_jvm_self_test.l`, `cross_package_generics_jvm_self_test.l`,
`exposed_record_generic_ret_jvm_self_test.l`, `erased_generic_arith_jvm_self_test.l`,
`erased_element_checkcast_jvm_self_test.l`, `union_case_collision_jvm_self_test.l`,
`chained_elem_jvm_self_test.l`, `record_method_jvm_self_test.l` (including its
own nested-unresolved-type-parameter cases, #6742), `method_scrutinee_jvm_self_test.l`,
`projectable_jvm_self_test.l`, `silent_miscompile_guard_jvm_self_test.l`, and
`iface_dispatch_jvm_self_test.l`.

#4870 is now closed on both targets (MSIL: D-progress-736 / #6388; JVM: this
entry). See `docs/43-in-bundle-generics-plan.md` (status header) and
`docs/44-jvm-production-readiness-plan.md` (M-1) for the per-target write-ups.
