# D-progress-1013 — `Self` in an impl method signature on a protected type (#7550)

**Status:** shipped (dotnet, JVM); native remains a pre-existing gap.

Follow-up to D-progress-1009 (#7457): `impl Iface for P` where `P` is a
protected type moves each impl method into `P` as a locked `entry`. When the
interface method's signature mentions `Self` — as a parameter, a return, or
nested inside a generic argument — the moved entry previously failed T0136
(#7547's fix), because a naive `Self -> P` substitution in the moved
signature produces `merge(P)` against an interface slot erased to
`merge(object)`: `TypeLoadException` ("does not have an implementation") on
dotnet, `AbstractMethodError` on the JVM.

## Decision

Do not substitute. The contract elaborator (`mergeProtectedImpls`,
`protected_impls.l`) already copies the impl method's signature into the
moved `EntryDecl` unchanged; this was already true before this change and
needed no edit. MSIL and JVM both erase a bare `Self` type expression to
`object`/`Object` deep inside the SAME signature-lowering function used for
the interface slot's own signature (`typeExprToMsilCtx`'s `TSelf` arm;
`typeExprToJvmExtern`'s `TSelf` arm) — so as long as the moved entry's
signature is the literal, unmodified interface signature, the two erasures
are structurally identical by construction, at any nesting depth, with no
special-casing required for the SIGNATURE (and hence the emitted descriptor)
to match.

What still needed fixing was CODEGEN-INTERNAL body-typing bookkeeping — the
same class of gap #6421/#6426 fixed for ordinary `impl`/record methods — so
that a non-receiver `Self`-typed parameter's own fields/methods resolve
inside the entry's body instead of falling through the erased-`object`
fallback:

- **MSIL** (`lowerProtectedMsil`'s `PMEntry` arm, `msil/codegen.l`): the
  entry's parameter-registration loop now routes through the shared
  `registerParamsMsil` helper (the same one `lowerImplMethodMsil` and
  `lowerRecordMethodMsil` use) instead of a bespoke loop that always tracked
  every parameter's MSIL type via a bare `typeExprToMsilCtx` call.
  `registerParamsMsil` already special-cases a `Self`-typed parameter,
  narrowing its CODEGEN-INTERNAL tracked type to `MClass(typeFqn)` (the
  entry's own protected type) — sound because the type checker only ever
  accepts a `Self`-typed argument here when it resolves to exactly this
  type. The emitted IL signature is untouched (still the erased `object`).
  `methodRetIsSelf` (used to narrow a `Self`-returning call's result back
  to the caller's own concrete receiver type) was already recorded correctly
  for entries — `addPackageTokens`'s `PMEntry` arm calls the same
  `registerMethodRetTy` used for every other method category, against the
  entry's raw (pre-erasure) `ed.ret`, so it needed no change.
- **JVM** (`lowerProtectedMethod`, `jvm/codegen/06_items.l`): now calls
  `emitSelfParamChecksJvm` after parameter-slot setup, mirroring
  `lowerRecordMethod`/`lowerImplMethod`. Unlike MSIL, the JVM verifier
  enforces bytecode type-safety at class-load time, so a real
  `checkcast <className>` (re-narrowing the already-allocated parameter
  slot) is required, not just codegen bookkeeping. `retIsSelf` on the
  entry's `JvmFuncSig` was already populated correctly —
  `registerInstanceSig` (used to register a `PMEntry`'s call-site
  descriptor) delegates to the shared `registerInstanceSigErased`, which
  computes `retIsSelf` from the entry's raw return type the same way it
  does for every other instance method, so it needed no change either.

T0136 no longer rejects a `Self`-mentioning impl signature; the type
checker's `checkImplOnProtected` dropped that arm (and the now-dead
`funcSignatureMentionsSelf`/`typeExprMentionsSelf` helpers) entirely — the
same as ordinary (non-protected) `impl`/record methods, which have never
had such a restriction.

## Native: left as a pre-existing gap, not implemented here

`--target native` cannot lower ANY interface method mentioning `Self` today
— for a record impl or a protected impl alike. This is unrelated to
protected types specifically: `registerInterfaceTypes` (the vtable
slot-type registration phase, `llvm_codegen.l`) resolves every interface
method's declared param/return types through `typeToN`/`retTypeToN`, which
fall through to `typeExprToNType` for a bare `TSelf`, and that function's
final arm panics ("this type form is not yet supported for --target
native (Phase N1)") — a hard compile-time panic, not a diagnostic, that
fires at interface-type registration, before any protected-type-specific
lowering is reached. Native's own vtable-slot machinery for a protected
impl (registered separately, since D-progress-1009, in
`ifaceVtableInitStr`'s "moved entry" special case) was never the blocker;
the blocker is upstream of it, in the interface's own type registration,
and would need to be fixed for record impls before it could be fixed for
protected impls.

Implementing native `Self`-slot support (a vtable method pointer typed by
the CALLING interface's own erased ABI, with the callee narrowing the
receiver itself, mirroring the MSIL/JVM approach but with LLVM's own
opaque-pointer conventions) is a separate, larger piece of work spanning
`registerInterfaceNames`/`registerInterfaceTypes`/`ifaceVtableInitStr`/
`lowerIfaceDispatch`/`lowerUfcsCall`, and is out of scope here — it was
never attempted for ordinary record impls either. T0136 is therefore NOT
made target-conditional (the shared, target-independent type checker has no
mechanism for that, and none was added): a `Self`-mentioning impl for a
protected type type-checks identically to the ordinary record case, and a
`--target native` build of either one panics at the SAME pre-existing
`typeExprToNType` site. This is a regression-free outcome (native support
for `Self`-mentioning interface methods was already absent before this
change) but a real gap; native `Self`-in-interface-method support (record and protected together),
and a proper diagnostic in place of the internal error until then, are
tracked in #7585. The JVM case where an untyped local bound from a
`Self`-returning interface call is tracked as `Object` (found while writing
these tests, reproduces with records) is tracked in #7586.

## Tests

`typechecker_self_test.l`: the T0136-for-Self test is replaced by a test
asserting `Self` (parameter, return, and nested in `List[Self]`) is
ACCEPTED. New `protected_iface_impl_self_type_self_test.l` (dotnet and JVM
batches only, not native): a `Self` parameter and a `Self` return, each via
both an interface-typed value and the concrete protected receiver (with the
`Self`-returned value's own field/method access exercising the narrowing);
and a `List[Self]`-returning method compiling and round-tripping its element
count through both call shapes. `protected_iface_impl_self_test.l`,
`protected_iface_impl_contracts_self_test.l`, and
`protected_exclusion_{dotnet,jvm}_self_test.l` are unaffected and continue
to pass unmodified.
