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
non-generic `impl` method under `<bare record name>.<method>/<arity>` ->
its `ctx.sigs` key (the `implMethodName`-qualified symbol
`collectImplMethods` already registers), walking `units`/`impls`/`members`
in the SAME order the type checker's `symTableAddImpl` +
`methodCandidatesFor` build and consult `tbl.impls` — so when two
interfaces implemented by the same record declare a same-named method, the
FIRST `impl` in source order wins the index (`containsKey` guard,
first-write-wins), matching the checker's own tie-break. Records have no
ambiguity diagnostic for this case (unlike protected types' `T0136`), so
there is nothing to diagnose — the checker itself picks the first match
silently.

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
name as an impl method" test caught during development). The impl-method
index's own key is collision-free by construction (record + interface +
method), so checking it first can never steal a match that belongs to a
genuinely different function; an own-body record method or dot-named D037
function of the same name is simply absent from this index (only real
`impl` declarations populate it), so those still resolve through the
existing chain unaffected when no matching `impl` exists.

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
then `.value()` on the concrete result, no rebox needed), two interfaces
declaring the same method name on one record (first-declared wins), and a
free function sharing a name with an impl method (both resolve
independently — no cross-talk, since their `ctx.sigs` keys are disjoint).
Added to `scripts/ci/native-backend-self-tests.sh`.

`llvm_self_test_self_iface.l`'s header comment (which documented the
concrete-receiver gap as "a separate, PRE-EXISTING native gap") is updated
to say it is fixed, pointing at this entry.

Regression: `scripts/ci/native-backend-self-tests.sh` (356 `ok`, 0
`not ok`), `scripts/ci/compiler-self-tests-batch.sh`, and
`scripts/ci/jvm-generics-self-tests-batch.sh` all green.

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
