# D-progress-886 — JVM codegen: three `group:jvm-generics-erasure` gaps fixed at their shared root cause (generic-record instantiations erasing to `Object` outside List/Map) (#6691, #6708, #6586)

**Status:** shipped

**Context.** Three related self-hosted JVM backend issues, all filed under
the `group:jvm-generics-erasure` label, traced back to the same underlying
gap: `typeExprToJvmExtern`'s `TGenericApp` branch (`jvm/codegen/01_types.l`)
erases *every* non-bare-List/Map generic instantiation to `java/lang/Object`
— correct for the type-parameter *payload* of a genuinely generic type
(`Result[T, E]`'s `T`), but overly broad for a generic *record*'s own class
identity, which the JVM erasure model keeps as a single concrete class file
regardless of instantiation (`Box<T>` is always `Box.class`, exactly like
`List`/`Map` already special-case).

**#6691 — generic-record PARAMETER field read resolves by bare name across
the whole bundle.** `func unboxInt(b: in Box[Int]): Int { b.value }` erased
`b`'s slot type to `Object`, so `EMember`'s record-field lowering fell to the
erased-receiver fallback: a `field:<name>` lookup keyed by bare field name
across *every* bundled type — landing on an unrelated same-named field
(`Std.Http.Url.value` was the observed collision) and `checkcast`-ing to the
WRONG class. Silent miscompile, not a compile-time diagnostic. The sibling
shape (a return VALUE bound to a local, `val b = makeBox(5); b.value`) was
already fixed for #6399 (PR #6400, `recordRetClassOf`); parameter bindings
never got the analogous treatment.

**#6708 — field read on an indexed element of a nested generic-record
container.** `List[MapEntry[K, V]]`/`slice[MapEntry[K, V]]`, where `MapEntry`
is instantiated over the ENCLOSING generic function's own type parameters,
hit the identical erasure at a different call site
(`indexedElemTypeOverride`/`resolveConcreteTypeExpr`, `02_exprs.l`/
`03_match.l`): the container's OWN element-type arg is itself a `TGenericApp`
that erased to `Object`, so an indexed read never had a class to narrow to
and failed with `error[J007]` ("member cannot be resolved on an erased
Object receiver"). This directly blocked `Std.Collections.Persistent.
PersistentMap[K, V]` (#6570) from shipping on `--target jvm` —
`pmapLookup`/`pmapInsert`/`pmapDelete` all do `m[i].key` on a
`slice[MapEntry[K, V]]` parameter, and the stdlib test suite additionally
exercises `val asList: List[MapEntry[Int, String]] = pmapToList(m);
asList[0].key`.

**#6586 — `slice[Char]`/`slice[Byte]` element `.toInt()` fails JVM auto-FFI.**
Confirmed, on investigation, to be a DIFFERENT bug than the issue's own
hypothesis: a plain `slice[Char]`/`slice[Byte]` PARAMETER (`sumCharCodesSlice`,
`sumByteSlice`, `firstCharCode` — the three functions the issue named) already
worked correctly in isolation once tested — `recordDeclaredElemType` already
registers a parameter's declared element type, and `indexedElemTypeOverride`
already narrows an indexed read against it. The actual failure in
`slice_array_abi_self_test.l` came from a DIFFERENT statement in the same
file: `val cs2 = cs.append('z'); cs2[0].toInt()`. `.append`/`.concat`/`.slice`
are slice-builtin intrinsics (`lowerSliceAppendJvm`/`lowerSliceConcatJvm`/
`lowerSliceSliceJvm`, `04_calls.l`) that were never registered as a
`retGenericArgs`-carrying function signature, so `scrutineeGenericArgs`'s
`ECall`/`EMember` arm (`03_match.l`) had nothing to recover for a bound local
— `cs2` carried no recorded element-type args at all, leaving `cs2[0]`
statically `Object` and `.toInt()` falling through to JVM auto-FFI dispatch
(no `toInt()` on `java.lang.Object`).

**Fix.** #6691 and #6708 share one new function, `Jvm.Codegen.
recordParamClassOf` (`01_types.l`): resolves a bare `TGenericApp` head
through `ctorClassFor` — the SAME `ctx.ctors` registry a
`RecordName(field = value, …)` construction call already resolves against,
which is unconditionally populated for every record (generic or not,
same-package or cross-package/stdlib) by `collectFileCtors`, unlike a fresh
per-file `localRecordNames` pre-scan (`recordRetClassOf`'s #6399 approach,
same-file-only — insufficient here since #6708's motivating case,
`Std.Collections.MapEntry`, is a stdlib record consumed from an unrelated
package).

- **#6691**: `setupStaticParamSlotsAndHolders`/`setupInstanceParamSlotsAndHolders`
  (`06_items.l`) run a new "pass 3" after every parameter's real ABI slot is
  allocated: for a plain (`in`-mode, non-holder) parameter whose type
  resolves via `recordParamClassOf`, load the raw (erased) ABI value,
  `checkcast` to the resolved class, and store into a FRESH local slot bound
  to the parameter's name — mirroring the "narrow at the bind site" idiom
  `narrowStaticCallResult` (#6399) already uses for a call result bound to a
  local. The fresh slot's index is always `>=` every ABI parameter/holder
  slot, so its tracked class flows through the ordinary `LAstoreAs`-driven
  `storeTypes` path in `Jvm.Lowering.lowerFuncImpl` (used for every
  StackMapTable frame at slot indices beyond the parameter range) rather than
  the method's real, still-erased parameter descriptor (`f.params`, whose
  frame type at a param slot index is fixed for the WHOLE method regardless
  of any store instruction) — robust across `if`/loop/match branches inside
  the function body, unlike narrowing the SAME ABI slot in place would be.
  The method's actual descriptor (and every call site's invoke descriptor)
  is deliberately left untouched — `Object`-erased, matching every other
  generic-record parameter — so no cross-call-site ABI change was needed.
  Holder (`out`/`inout`) parameters are excluded from the narrowing (their
  array-typed ABI slot must stay erased to match the caller's holder-array
  argument exactly).
- **#6708**: `resolveConcreteTypeExpr` (`03_match.l`) gains a `TGenericApp`
  arm trying `recordParamClassOf` before falling to the pre-existing
  `typeExprToJvmExtern` erasure — so `indexedElemTypeOverride`'s existing
  general resolution path (already used for `slice[Elem]`/`List[Elem]`
  parameters and call-derived instantiations) now also recovers a NESTED
  generic-record element's real class.

#6586's fix is independent: `scrutineeGenericArgs`'s `EMember` arm
(`03_match.l`) recurses into the RECEIVER's own recorded generic args for
`.append`/`.concat`/`.slice` — checked only AFTER a genuine user-defined
instance method of the same name has already missed (`viaInstance.count ==
0`), so a real `impl`'s own `.append` is unaffected — letting a bound local
inherit the receiver's declared element type through the SAME
`ctx.varGenericArgs` registry `recordDeclaredElemType`/`recordVarGenericArgs`
already populate. The physical array construction inside
`lowerSliceAppendJvm`/etc. is untouched (still builds a genuine `Object[]`
where the receiver's own slot type is erased) — only the compiler's own
element-type TRACKING gained the extra propagation, exactly the same "peek,
don't re-emit" shape as #5686's homogeneous-list-literal inference
(docs/44 m-98).

**Verification.** New self-tests, both targets: `generic_param_field_read_
jvm_self_test.l` (5 cases: Int/String payload, two independent same-
instantiation parameters, a same-field-name non-generic control, an instance
method's own generic-record parameter) and `generic_element_field_read_
jvm_self_test.l` (4 cases: `slice`/`List` parameter direct in-body indexing,
a locally-built container, and the exact PersistentMap annotated-bind
shape). `lyric-compiler/lyric/slice_array_abi_self_test.l` is now 16/16 on
`--target jvm` (was J008-failing on the `.append()` case; the issue's own
named parameter shapes already passed in isolation, confirming the
diagnosis above). `lyric-stdlib/tests/collections_persistent_map_tests.l`
now passes end-to-end on `--target jvm` via plain `lyric run` (was
dotnet-only) — `PersistentMap[K, V]` is no longer platform-restricted.
Zero regressions across the existing JVM generics-erasure self-test sweep:
`erased_generic_arith_jvm_self_test.l` (23), `generic_jvm_self_test.l` (24,
including the #6399 return-value-narrowing cases this fix's parameter-side
narrowing sits alongside), `generic_uint_erasure_jvm_self_test.l` (5),
`exposed_record_generic_ret_jvm_self_test.l` (1),
`erased_element_checkcast_jvm_self_test.l` (16), and
`generic_extern_jvm_self_test.l` (5) — 74 cases, all still green.

**Two narrower limitations noted in `recordParamClassOf`'s own doc
comment.** (1) Bounded to a BARE single-segment `TGenericApp` head: a
package-qualified generic-record parameter type (`b: in Other.Box[Int]`)
still erases to `Object` and keeps the original #6691 silent-miscompile
behavior. (2) Resolves through the plain `ctorClassFor` (bundle-global,
first-registered-wins bare-name fallback) rather than the more
collision-resistant `ctorClassForExpecting` (#5976/#6640) this same file
already uses elsewhere, so two same-named generic records in different
packages could still resolve a parameter's `checkcast` to the wrong
package's class — accepted as no worse than the existing risk a plain
`RecordName(...)` construction call already carries, but a related
bare-name-resolution-ordering gap worth keeping in view alongside #6929.

**Known remaining gap, explicitly out of scope.** A field read directly on a
plain local bound to a DIFFERENT generic function's call result across a
call boundary, when the callee cannot be monomorphized (`val e =
someGenericFn(x); e.field`, where `x` is a variable rather than a literal or
an annotated binding `Lyric.Mono` can specialize from) still resolves the
callee's return class at SIGNATURE-COLLECTION time
(`collectFileSigsSeeded`'s `recordRetClassOf`, a same-file-only pre-scan),
which runs BEFORE the bundle-wide `ctx.ctors` registry is fully populated
for a cross-package record (`Jvm.Bridge`'s `collectFileSigsSeeded(userFile,
…)` call precedes its `collectFileCtors(stdlibFiles[ri], …)` loop). Fixing
this needs either re-ordering `Jvm.Bridge`'s registration passes (all
`collectFileCtors` calls before any `collectFileSigsSeeded` call) or a late
enrichment pass over `registry` once `ctorReg` is complete — both a larger,
riskier change to the shared bridge pipeline than this fix's scope, and
deferred as a separate follow-up rather than folded in here. Tracked as
#6929.

**Second, distinct residual gap found while writing this fix's own
self-test.** `self.<genericRecordField>.<field>` on a record whose OWN
FIELD (not a parameter or an indexed container element) is declared as a
generic-record instantiation still erases to `Object` and hits the same
bare-field-name fallback #6691 fixed for parameters. This fix's
`recordParamClassOf` narrowing applies at the parameter-BIND site
(`setupStaticParamSlotsAndHolders`/`setupInstanceParamSlotsAndHolders`)
and at the indexed-element read site (`resolveConcreteTypeExpr`), neither
of which covers a record's own field-DECLARATION-typing path
(`collectFileCasesExtern`/`lowerRecord`'s field-type computation).
Documented in `generic_param_field_read_jvm_self_test.l`'s header comment
and tracked separately as #6959.
