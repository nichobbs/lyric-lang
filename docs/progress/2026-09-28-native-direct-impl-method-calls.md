# Native: `impl` methods callable directly on a concrete record receiver, scoped erased-`Self` unbox (#7600, #7618)

`--target native` previously only reached an `impl I for R` method through
an interface-typed receiver — `sq.area()` on a concrete `Square` failed to
lower, since `collectImplMethods` registers the method under the
collision-free `<Record>.<Iface>.<method>` symbol and ordinary UFCS
resolution (`lowerUfcsCall`) never looked that name up (#7600). Fixed with
`registerImplDirectMethods`, an index from `<pkg>.<Record>.<method>/<arity>`
(package-qualified, #7627 below) to the impl method's `ctx.sigs` key,
walked in the same units/impls/members order the type checker's
`tbl.impls` builds up. It comes before the bare `curPkg + "." + name`
lookup, which matches any same-arity function in the package regardless of
receiver type and would otherwise let an unrelated free function shadow
the method.

Review of #7600 raised two follow-ups: a record declaring both an own-body
method and a same-named `impl` method resolved to the impl method on
native, not the checker's own own-body-first tie-break (#7626); and the
index above was keyed by the BARE record name, so two packages in one
native bundle declaring a same-named record with a same-named impl method
aliased each other (#7627). Investigating showed neither shape compiles on
ANY target — MSIL fails codegen outright, JVM produces wrong results — so
rather than teach every backend the checker's tie-break for an
uncompilable shape, the type checker now REJECTS both as a new code,
**T0139** (`checkImplMethodNameConflicts`, generalizing the protected-type
`T0136` check to every other impl target). With T0139 in place native
needs no own-body-vs-impl priority at all; `registerImplDirectMethods`'
key changed to package-qualified to fix #7627.

Also lands two review follow-ups to #7616/D-progress-1016 (#7618): the
`coerceTo` erased-`Self`-slot unbox is now gated on an explicit
`NIfaceInfo.methodParamIsSelf` fact instead of inferring "this is a `Self`
slot" from the declared type merely being `i8*` (a real `NativePtr[Byte]`
extern parameter erases identically and must not silently accept a
ref-typed argument); and `registerInterfaceNames`'s panic path and
`nativeSelfShapeDiagnostics`'s diagnostic path now share one
`nestedSelfShapesInSig` traversal instead of two copies.

**#7627 continued — the `implDirectMethods` package-qualification above
was necessary but NOT sufficient.** Re-running the #7627 regression after
landing it still failed (`actual=22`, both packages returning `Proj7.A`'s
answer). The real defect was upstream of impl-method dispatch entirely:
`Widget(n = 10)` inside `Proj7.B.run()` (an unqualified record
CONSTRUCTOR call, resolved by `tryLowerConstruct` via
`mapGet(ctx.recordDefs, "Widget")`, the bare source name) was itself
resolving to `Proj7.A`'s record, because `addRecKey`/`replaceRecKey`
register every record under both a package-qualified key AND a bare key
shared GLOBALLY by every package in the bundle, with documented
"first-wins shadowing across packages" semantics — `Proj7.A` registers
`Widget` first, so `Proj7.B`'s own unqualified reference silently built
`Proj7.A`'s struct, before `lowerUfcsCall`/`implDirectMethods` were even
reached. The identical defect existed in type-ANNOTATION resolution
(`typeToN`/`typeToNOpt`'s `lookupHeapType`, used for a synthesized impl
method's `self: R` parameter and any record-typed annotation): its
"qualified-first, bare-fallback" `joined`/`bare` lookup computed `joined`
via `modulePathJoin(path.segments)`, which for a single-segment
(unqualified) path returns the bare name again — a no-op qualification.

Fixed generally (not just for impl methods) with two small helpers in
`llvm_codegen.l`: `qualifiedPathJoin(ctx, path)` qualifies a
single-segment `ModulePath` with the caller's own `ctx.curPkg[0]` before
`typeToN`/`typeToNOpt` hand it to `lookupHeapType`; `curPkgQualifiedGet`
does the analogous "caller's own package first, bare fallback" lookup for
`tryLowerConstruct`'s `ctx.recordDefs`/`ctx.caseRefs`/`ctx.distinctDefs`.
Both are strictly additive (an existing bare-only resolution never
regresses — they only ever prefer an entry the caller's own package
already registers at the same declaration site as the pre-existing bare
key). This confirms the task's hypothesis (a): the general "record
bare-name resolution across packages" bug, not something specific to
`implDirectMethods`.

See D-progress-1019 for the full design and `docs/01-language-reference.md`
§ native-backend paragraph and `book/chapters/01-getting-started.md` /
`appendix-b-quick-reference.md` for the updated surface description.

## Tests

New: `lyric-compiler/lyric/llvm_self_test_impl_direct.l` (5 tests: plain
return, `Self` return + chain, a free function sharing a name with an
impl method, and a cross-package aliasing regression for #7627 — this
is the test that stayed red after the `implDirectMethods`
package-qualification alone, and went green only after the
`qualifiedPathJoin`/`curPkgQualifiedGet` fix above). Added to
`scripts/ci/native-backend-self-tests.sh`.

New, impl-free general regression: `llvm_project_self_test.l` gains "two
packages with a same-named record and different field layouts resolve
independently, no impl (#7627)" — two packages each declare `record Rec`
with a DIFFERENT field count/layout and no `impl` at all, proving the
aliasing was a general record-resolution defect rather than something
specific to impl-method dispatch (a layout alias would misread a field,
not just call the wrong method).

New: `typechecker_self_test.l` gains 6 T0139 cases (own-body-vs-impl,
two-impls-same-name, a clean distinct-names case, protected types still
reporting T0136 and not double-reporting T0139, and a free function
sharing an impl method's name still being accepted).

Removed: `own_body_vs_impl_method_self_test.l` and
`llvm_self_test_impl_direct.l`'s "two interfaces declaring the same method
name: first-declared wins" test — both pinned a shape that is now a
T0139 compile error, so neither can be constructed as a passing runtime
test any more.

Regression, all green:
- `make self-test NAME=typechecker`.
- `scripts/ci/native-backend-self-tests.sh`.
- `scripts/ci/compiler-self-tests-batch.sh`.
- `scripts/ci/jvm-generics-self-tests-batch.sh`.
- `scripts/ci/jvm-ecosystem-suites.sh`.

(See the PR's own validation output for exact `ok`/`not ok` counts.)

## Out of scope

- A true pre-codegen diagnostic (new N-code) for a ref-typed value passed
  to a genuinely-declared `NativePtr[Byte]` extern parameter, so even that
  misuse never reaches a panic. The scoped fix above already stops the
  #7616 SILENT bitcast (it now hits `coerceTo`'s existing generic
  type-mismatch panic, the same invariant-violation report every other
  `coerceTo` failure in this backend produces), but a dedicated,
  pre-codegen-gated diagnostic (matching the `N0006`/mode-checker `N0100`
  precedent) needs either type-checker cooperation or a new AST+type
  call-site walker — a larger, separate piece of work not attempted here. Tracked in #7624: the type checker accepts the
  ill-typed argument today, and should reject it.
- T0139's own-body-method detection is AST-based over the file currently
  being checked (mirroring `checkImplOnProtected`'s own scope), so a
  record and a same-named `impl` declared in genuinely different
  files/packages are not caught. A fully robust version would resolve
  through the symbol table's global `TypeId`-keyed method-signature space
  instead of re-walking `items`; not attempted here since every reported
  and reproduced instance of #7626/#7627 was same-file. Tracked in #7639.
- The same bare-name first-wins lookup remains for enums (`enumDefs`) and
  unions (`unionDefs`, `EPath` resolution); tracked in #7643.
