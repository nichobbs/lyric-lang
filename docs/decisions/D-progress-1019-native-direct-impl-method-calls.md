# D-progress-1019 — Native: direct `impl` method calls on a concrete record receiver, and a scoped erased-`Self` unbox (#7600, #7618)

**Status:** shipped

## #7600: `impl` methods callable directly on a concrete record receiver

`collectImplMethods` registers each `impl I for R` method under the
collision-free `<Record>.<Iface>.<method>` name so the vtable
(`ifaceVtableInitStr`) never collides two impls of the same record, or an
impl with a record-body method of the same name. But `lowerUfcsCall`'s
ordinary method-call resolution — the tiered lookup
(`curPkg.<name>`/`<tyName>.<name>`/`<bareTyName>.<name>`/legacy fallback/bare
`<name>`) that handles record-body (D037) methods and dot-named UFCS
functions — never tried that compound name, so a call on the CONCRETE
receiver (`sq.area()` where `sq: Square`, not interface-typed) failed to
lower; only a call through an interface-typed receiver
(`ifaceBoxInfoOfType` + `lowerIfaceDispatch`) ever reached an impl method.
Protected-type impls were unaffected: the contract elaborator moves their
methods into the type's own `entry`/`func` members before codegen ever sees
the `IImpl` item (#7457), and those register under the bare `<pkg>.<method>`
name any ordinary lookup already finds.

### Decision

`registerImplDirectMethods` (new, `llvm_codegen.l`) indexes every
non-generic `impl` method under `<pkg>.<Record>.<method>/<arity>` ->
its `ctx.sigs` key (the `implMethodName`-qualified symbol
`collectImplMethods` already registers), walking `units`/`impls`/`members`
in the SAME order the type checker's `symTableAddImpl` +
`methodCandidatesFor` build and consult `tbl.impls`.

`lowerUfcsCall` consults this index as the FIRST step (immediately after
the existing interface-dispatch check, before the `curPkg + "." + name`
bare lookup) rather than folded into the existing tiered chain. This
ordering matters: `curPkg + "." + name` matches ANY same-arity function in
the current package regardless of receiver type — it does not verify the
match is actually a method of the record being called on — so trying the
impl-method index only AFTER that bare lookup let an unrelated
same-name/arity free function (`func area(x: Int): Int` alongside `impl
Shape for Square { func area(): Int }`) shadow the real impl method
(verified: this was the exact failure the "free function with the same
name as an impl method" test caught during development). The index is
looked up by the receiver's PACKAGE-QUALIFIED type name (`#7627` below),
so its own key is collision-free by construction (package + record +
method): checking it first can never steal a match that belongs to a
genuinely different function; an own-body record method or dot-named D037
function of the same name is simply absent from this index (only real
`impl` declarations populate it — and, since #7626/#7627 below, a record's
own-body method can never share a name with one of its impl methods at
all), so those still resolve through the existing chain unaffected when no
matching `impl` exists.

A `Self`-returning impl method needs no special handling for the direct
call: `collectImplMethods`/`implMethodToFn` already substitutes `Self` to
the concrete record type in the method's OWN registered signature before
it ever reaches codegen (pre-existing, unrelated to this fix), so the
`ctx.sigs` entry's return type is already concrete — calling it directly
is exactly like calling any other function.

### Tests

`llvm_self_test_impl_direct.l` (new, 5 tests, mirrors
`llvm_self_test_self_iface.l`'s ASan-capable harness): a plain-returning
impl method called directly (with an ASan-clean loop variant), a
`Self`-returning impl method called directly and then chained (`.doubled()`
then `.value()` on the concrete result, no rebox needed), a free function
sharing a name with an impl method (both resolve independently — no
cross-talk, since their `ctx.sigs` keys are disjoint), and a
cross-package aliasing regression (`#7627` below). Added to
`scripts/ci/native-backend-self-tests.sh`.

`llvm_self_test_self_iface.l`'s header comment (which documented the
concrete-receiver gap as "a separate, PRE-EXISTING native gap") is updated
to say it is fixed, pointing at this entry.

Regression: `scripts/ci/native-backend-self-tests.sh` (356 `ok`, 0
`not ok`), `scripts/ci/compiler-self-tests-batch.sh`, and
`scripts/ci/jvm-generics-self-tests-batch.sh` all green.

## #7626/#7627 review follow-ups to #7600

Review of #7600 raised two shapes it left unaddressed:

- **#7626** — a record declaring BOTH an own-body (D037) method and a
  same-named `impl` method: native resolved `.method()` to the impl
  method, not the own-body one the type checker's own candidate order
  (`methodCandidatesFor`: the type's own methods before `tbl.impls`-derived
  impl methods) silently picks.
- **#7627** — `registerImplDirectMethods`' index was keyed by the BARE
  record name (`<record>.<method>/<arity>`), so two packages in one
  native bundle declaring a same-named record with a same-named impl
  method aliased each other: whichever package registered first "won" for
  BOTH.

Investigating both surfaced a larger problem neither backend actually
handles: a record with an own-body method AND a same-named `impl` method,
or a record implementing two interfaces that both declare a same-named
method, fails on EVERY target today — MSIL fails codegen outright ("An
item with the same key has already been added"), JVM produces wrong
runtime results, and native (even with a #7626 fix attempted) still
resolves inconsistently. Protected types already reject both shapes as
`T0136` (`checkImplOnProtected`); records, exposed records, unions, and
opaque types had no equivalent diagnostic.

### Decision

Rather than teach native (and, eventually, MSIL/JVM) to reproduce the type
checker's own-body-before-impl tie-break for a shape no backend can
actually compile, the type checker now REJECTS both shapes for every
non-protected impl target, under a new code, **T0139**
(`checkImplMethodNameConflicts`, generalizing `checkImplOnProtected`'s
`earlierProtectedImplWithMethod` pattern via a new
`earlierImplWithMethodForTarget` helper — matched by the impl's RESOLVED
target type name rather than protected's raw-AST name match, so a
`type X = R; impl I for X` alias still matches an `impl J for R` for the
same underlying `R`). T0139 fires for:

- an impl method whose name matches one of the target's own record-body
  (D037) methods (#7626's shape);
- an impl method whose name matches a method of an EARLIER impl (possibly
  of a different interface) for the same target (the two-interfaces
  shape).

Protected targets are explicitly skipped (T0136 already covers them with
the elaborator's locked-member wording); the two AST-based lookups
(`recordDeclaresOwnBodyMethod`, `earlierImplWithMethodForTarget`) search
the file currently being checked, matching `checkImplOnProtected`'s own
scope — a record's own-body methods and its `impl` blocks are ordinarily
declared alongside the record itself, so this covers the realistic case; a
record and a same-named impl in genuinely different files/packages is a
known, documented gap (T0139 will not fire there).

With T0139 in place, native no longer needs a "which tier wins" priority
between own-body and impl methods: the shape simply cannot reach codegen.
`registerRecordDirectMethods`/`Ctx.recordDirectMethods` (the #7626 fix
attempt) were removed; `registerImplDirectMethods`/`Ctx.implDirectMethods`
stays, its key changed from the bare `<Record>.<method>/<arity>` to the
PACKAGE-QUALIFIED `<pkg>.<Record>.<method>/<arity>` (#7627) — matching
`tyName`, the same qualification every other `lowerUfcsCall` tier already
uses — so two same-named records in different packages of a multi-package
native bundle never alias each other's methods. Its pre-existing
first-declared-wins tie-break for two impls sharing a method name is now a
defensive fallback only (T0139 rejects that shape before it can reach
codegen).

### Tests

`typechecker_self_test.l` gains 6 T0139 cases: own-body-vs-impl (#7626),
two impls sharing a method name (#7627's root cause), a clean case with
distinct names, protected types still reporting T0136 (not double-reported
as T0139), and a free function sharing an impl method's name still being
accepted (T0139 targets impl/own-body member clashes only, not unrelated
free functions).

`llvm_self_test_impl_direct.l`'s "two interfaces declaring the same method
name: first-declared wins" test and the standalone
`own_body_vs_impl_method_self_test.l` (dotnet/JVM regression for #7626)
are removed — both pinned shapes are now T0139 compile errors, so they
cannot be constructed as passing runtime tests any more. In their place,
`llvm_self_test_impl_direct.l` gains a cross-package aliasing regression
(two packages each declaring a same-named record implementing a
same-named method on a DIFFERENT, distinctly-named interface, verifying
the sum of both packages' calls shows no aliasing) — `#7627`'s test.

Regression: `make self-test NAME=typechecker`,
`scripts/ci/native-backend-self-tests.sh`,
`scripts/ci/compiler-self-tests-batch.sh`, and
`scripts/ci/jvm-generics-self-tests-batch.sh` all green (see the
top-level PR validation for exact counts).

## #7627 continued: the actual cross-package aliasing root cause was NOT `implDirectMethods`

The `implDirectMethods` package-qualification above was necessary but,
verified by re-running the `#7627` regression test after landing it,
**not sufficient** — `Proj7.B.run()` still returned `Proj7.A`'s answer
(`11+11=22`, not `11+12=23`). Diagnosing further (per the task's
hypotheses a/b/c) showed the aliasing happens BEFORE `lowerUfcsCall` ever
looks at `implDirectMethods`: it happens in the record CONSTRUCTOR call
itself.

`Widget(n = 10)` inside `Proj7.B.run()` lowers through
`lowerConstructCall` -> `tryLowerConstruct(ctx, insns, "Widget", ...)`,
which looked the bare source name `"Widget"` up directly in
`ctx.recordDefs` (`mapGet(ctx.recordDefs, name)`, `llvm_codegen.l`
~line 4124, pre-fix). `addRecKey`/`replaceRecKey` register EVERY record
under both its package-qualified key (`<pkg>.<Record>`) AND a bare key
(`<Record>`) — by design, so an unqualified same-package reference
resolves without the caller tracking its own package — but the bare key
is a single GLOBAL map slot shared by every package in the bundle, with
documented "first-wins shadowing across packages" semantics
(`replaceRecKey`'s comment). `Proj7.A` registers `Widget` first (its
`CodegenUnit` is processed first), so `Proj7.B`'s OWN unqualified
`Widget(n = 10)` resolved to `Proj7.A`'s `NRecInfo` — meaning `.value()`'s
receiver already carried the type `NStruct("Proj7.A.Widget", ...)`
*before* `lowerUfcsCall`/`implDirectMethods` were even reached; the
`Proj7.A.Widget.value/1` method was doing exactly what its
(now-correctly-package-qualified) key said, on a struct that was itself
mis-resolved.

The identical global-bare-key aliasing risk exists in `lookupHeapType`
(the type-annotation resolution `typeToN`/`typeToNOpt` use for every
`TRef` type expression, including a synthesized impl method's `self: R`
parameter and any record-typed field/parameter/return annotation) via
its `joined`/`bare` two-tier lookup — for a single-segment (unqualified)
path, the OLD `joined = modulePathJoin(path.segments)` computation
returns exactly the bare name again (a one-segment path has nothing to
join), so `lookupHeapType`'s "qualified first" tier was a no-op for every
unqualified type reference in the entire native backend, not just impl
methods.

**Root cause, precisely:** the native backend's bare (unqualified)
name resolution for record CONSTRUCTION (`tryLowerConstruct`'s
`ctx.recordDefs`/`ctx.caseRefs`/`ctx.distinctDefs` lookups) and for type
ANNOTATIONS (`typeToN`/`typeToNOpt`'s `lookupHeapType` via `joined`) never
qualified an unqualified reference with the CALLER's OWN package before
falling back to the shared bare-name slot — so any two packages in one
native bundle declaring a same-named record (with or without an `impl`
block at all) alias each other's declaration for whichever package was
NOT processed first. This confirms the task's hypothesis (a): general
record bare-name construction, not `implDirectMethods`, was the actual
defect; `implDirectMethods`'s package-qualification (above) remains a
correct, necessary fix for its own narrower concern (impl-method symbol
resolution once the receiver's type is already correct) but was fixing a
symptom one layer downstream of where the aliasing actually happened.

### Decision

Added `qualifiedPathJoin(ctx, path)` (`llvm_codegen.l`): for a
single-segment `ModulePath`, returns `ctx.curPkg[0] + "." + segment`
instead of the bare segment; for a multi-segment path (already
explicitly qualified in source), behaves exactly as
`modulePathJoin(path.segments)` did before. `typeToN`/`typeToNOpt`'s two
`TRef` arms now compute `joined` via this helper instead of
`modulePathJoin` directly, so `lookupHeapType(ctx, joined, bare)`'s
"qualified first" tier is finally qualified for the common case (an
unqualified type reference), and only falls through to the shared bare
slot when the caller's own package genuinely has no such declaration
(preserving every existing use that relied on the bare fallback, e.g. a
name resolved without a live `ctx.curPkg` context).

Added `curPkgQualifiedGet[T](ctx, m, bareOrDotted)` (`llvm_codegen.l`): a
small generic helper with the same "caller's own package first, bare
fallback" shape, applied to `tryLowerConstruct`'s `ctx.recordDefs`,
`ctx.caseRefs`, and `ctx.distinctDefs` lookups (including the `.from`/
`.tryFrom` distinct-conversion forms). `ctx.caseToGenericUnion` and
`ctx.genericRecordDefs` were left as bare lookups — they resolve through
a DIFFERENT, single-owner mechanism (`genericDeclPkg` records exactly one
package per generic declaration name; there is no dual bare+qualified
registration to alias), a separate, narrower limitation out of this
fix's scope.

Both helpers are conservative by construction: they only ever prefer an
entry the CALLER's OWN package already registers (added at the exact
same declaration site as the pre-existing bare key) over the shared bare
slot: no existing call site's bare-only resolution regresses, and a
same-package unqualified reference behaves identically to before once
its package no longer collides with a stranger's.

### Tests

`llvm_self_test_impl_direct.l`'s `#7627` case (previous section) now
actually exercises the fix end to end: it failed with `actual=22` even
after the `implDirectMethods` package-qualification alone, and passes
(`23`) with `qualifiedPathJoin`/`curPkgQualifiedGet` in place.

New, impl-free general regression:
`llvm_project_self_test.l` gains "two packages with a same-named record
and different field layouts resolve independently, no impl (#7627)" —
`Proj7B.A.Rec` (one `Int` field) and `Proj7B.B.Rec` (two `Int` fields,
DIFFERENT layout) each construct and read back their own record with no
`impl` involved at all, proving the aliasing was a general record
resolution defect, not something specific to impl-method dispatch. A
layout mismatch (not just a wrong method target) would show up as
`r.y` reading garbage/another field's data rather than a plausible wrong
constant, so the field values are chosen to make an aliasing regression
numerically obvious in the summed exit code (`5 + (100+7) = 112`).

Regression (re-run after this fix, not just the `implDirectMethods`
change above): `scripts/ci/native-backend-self-tests.sh` (0 `not ok`),
`scripts/ci/compiler-self-tests-batch.sh` (0 `not ok`), and
`scripts/ci/jvm-generics-self-tests-batch.sh` (0 `not ok`) all green
against a full `make lyric` rebuild.

## #7618 review follow-ups to #7616 (D-progress-1016)

### 1. Scope the erased-`Self` unbox to the vtable-dispatch parameter slot, not any `i8*`-typed `want`

`coerceTo`'s `isRawI8PtrType(want)` branch (added by #7616 for the
erased-`Self` interface-method-parameter case, D-progress-1016) fired for
ANY call site whose declared type resolves to `i8*` — including
`externAdaptArg`'s fallback for `extern func` calls, where a genuinely
unrelated `NativePtr[Byte]` parameter erases to the identical `NType`.
Before #7616, passing a plain ref-typed value (a record or protected-type
instance) to a `NativePtr[Byte]` extern parameter panicked (a real, if
generic, type-mismatch error); after #7616 it silently bitcast with no
retain and no test — an accidental widening of the branch's scope.

**Decision:** the unbox is now driven by an EXPLICIT fact, never inferred
from the declared type happening to be `i8*`. `NIfaceInfo` gains
`methodParamIsSelf: List[List[Bool]]` (the per-parameter twin of the
existing `methodRetIsSelf`), computed in `registerInterfaceNames` phase A
(`isBareSelfTypeExpr` per parameter) and carried through phase B
unchanged. The unboxing logic itself moved out of `coerceTo` entirely into
a new standalone `unboxToSelfSlot(ctx, insns, v): NVal`, called ONLY from
`lowerIfaceDispatch`'s per-argument loop, and only for a parameter index
`ii.methodParamIsSelf[slot][ai]` marks — everywhere else (in particular
`externAdaptArg`'s extern-call fallback), a ref-typed value flowing into an
`i8*`-declared type now falls through `coerceTo`'s ordinary tail and hits
its existing generic type-mismatch panic ("cannot pass a '<from>' where
'<want>' is expected"), the SAME invariant-violation panic every other
`coerceTo` mismatch in this backend already produces (not a new, dedicated
diagnostic: reusing the existing, already-consistent panic message keeps
this fix minimal and matches how every other `coerceTo` failure in
`Lyric.LlvmCodegen` is reported — these are compiler-invariant violations
for a well-typed program, not reachable from valid user code, unlike the
`N0006` family, which IS reachable from a valid program the checker
accepts on `dotnet`/`jvm` but native cannot yet lower).

`isRawI8PtrType` (now dead — its only caller was the removed branch) was
deleted.

A future, stricter fix that turns this into a proper PRE-CODEGEN
diagnostic (so even the exotic misuse never reaches a panic, matching the
`N0006`/`N0100` precedent) needs either type-checker cooperation or a new
AST+type call-site walker (there is no reliable way to determine a call
argument's ref-ness from bare AST alone, and the mode checker's own
`N0100` pass answers a different question — "where may `NativePtr[T]`
appear" — not "does this argument's runtime type match the declared
`NativePtr[Byte]`"); this is a larger, separate piece of work, not
attempted here; tracked in #7624 (the type checker should reject the argument outright).

### 2. One shared nested-`Self` traversal

`registerInterfaceNames`'s inline nested-`Self` check (panics via
`panicUnsupportedSelfShape`) and `nativeSelfShapeDiagnostics`'s traversal
(collects `N0006` diagnostics) walked the same `sig.params`/`sig.ret`
shape independently. Factored into one shared helper,
`nestedSelfShapesInSig(sig: FunctionSig): List[NestedSelfShape]`
(`NestedSelfShape { where_: String, span: Span }`), so the two call sites
can never drift; each caller only decides what to DO with a found shape
(panic immediately vs. collect a diagnostic).

### Tests

No new diagnostic code, so no new N-series row. The scoping fix is
exercised indirectly: `llvm_self_test_self_iface.l`'s existing 9 tests
(unaffected — the erased-`Self` unbox path they exercise is unchanged,
only its trigger condition narrowed) and the full native suite continue
to pass with the narrowed, explicit gate.

Regression: same three suites as above, all green.
