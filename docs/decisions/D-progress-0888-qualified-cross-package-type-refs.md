# D-progress-888 — Self-hosted compiler: qualified cross-package type references resolve to the exact package named, not scope-priority (#6689)

**Status:** shipped

**Context.** `List[T]`-of-record-typed cross-package constructor arguments
could pick up an unrelated same-named record from a different package.
Found while building the JVM restored-dependency pipeline (`Jvm.Driver.
BuildRequest`'s `contractEntries: List[Jvm.Zip.ZipEntry]` field resolving to
`Jvm.ZipReader.ZipEntry` instead — a `MissingMethodException`), worked
around with a parallel-list representation there. Root-caused to TWO
independent bugs, one type-checker-side and one MSIL-codegen-side; the JVM
symptom was fixed by the first alone (JVM codegen resolves types through the
checker's own resolved `Type`, not by re-deriving FQNs from raw source text
at codegen time — confirmed empirically, a same-shaped repro runs correctly
on `--target jvm` with zero JVM-side changes), but the family is broader on
MSIL and affects any qualified type reference, not just constructor fields.

**Bug 1 (type checker) — `collectCtorFields` resolves under the CALLER's
scope.** A record/opaque's field types are resolved lazily, on every use
(`collectCtorFields` → `resolveType`), rather than once at the type's own
declaration and cached. Every call site ran this resolution with whatever
`SymbolTable` scope happened to be active — the scope of the CALLING file's
own package, not the field's DECLARING package. A field typed `List[Item]`
in package A resolved `Item` against the CALLING file's imports: a caller
that transitively imports an unrelated same-named `Item` from package B
picked B's `Item` instead of A's, with zero diagnostics. Fixed by having
`collectCtorFields` save the caller's scope, temporarily switch to the
field-owning symbol's OWN declaring package + that package's own recorded
imports (a new `packageImports: Map[String, List[String]]` side index,
populated during T3 signature collection exactly where `symTableSetScope`
already sets each package's own scope for `resolveFunctionSig`), run the
resolution, then restore the caller's scope.

**Bug 2 (MSIL codegen) — `typeExprToMsilCtx` discards a qualified type
reference's owner entirely.** Independent of bug 1, and broader: affects
ANY qualified type reference at codegen time, not just constructor fields
(a `val` binding's type annotation, a function return type, …). `typeExprToMsilCtx`'s
`TRef(path)` case computes `val seg = lastSegmentMsil(path)` — the bare
tail name only — and resolves it via `resolveTypeFqn(cctx, pkgName, seg)`,
a scope-priority walk keyed by the REFERENCING package's own imports. Even
though `Lyric.AliasRewriter.rewritePath` fully expands a qualified
reference's owner to its real dotted package (a bare `import Pkg.Sub`
alias-expands `Sub.Item` to `Pkg.Sub.Item`) before codegen runs, that
qualifier was discarded outright: `List[PkgA.Item]` written in a package
that imports BOTH `PkgA` and an unrelated `PkgB` (also declaring `Item`)
resolved to whichever candidate won `resolveTypeFqn`'s "last-registered
package among ALL this file's imports" walk — not necessarily `PkgA` —
silently building a `List<PkgB.Item>`-shaped generic instantiation.
Confirmed via a minimal single-project repro (no restored dependencies
needed): `ArrayTypeMismatchException`/`InvalidProgramException` at runtime,
depending on exactly where the wrong instantiation surfaced. Fixed with a
new `resolveTypeFqnQualified(cctx, pkgName, path, seg)` that, for a
multi-segment `path`, tries the EXACT `<ownerFromPath>.<seg>` candidate
first (mirroring the type checker's own #6338 exact-owner-match precedent
for the identical hazard) before falling back to `resolveTypeFqn`'s
scope-priority walk for a genuinely bare reference. `sliceElemMsilCtx`
delegates straight into this same `TRef` case, so `List[T]`/`slice[T]`
element-type resolution is fixed by the same change with no separate patch.

**Verification.** New self-tests in `msil_project_bridge_self_test.l`: a
`val` binding's qualified generic type argument (`List[Pkg.Item]`) resolves
to the exact package named, not scope-priority, across two colliding
same-named siblings; the same shape through a record CONSTRUCTOR FIELD
(matching the original JVM-context repro's actual shape). Full
`typechecker_self_test.l` suite (425/425) and `msil_project_bridge_self_test.l`
pass with no regressions. `--target jvm` re-confirmed unaffected by either
fix (already correct; no JVM-side change made). Following a `claude-review`
SUGGESTION on the PR, a dedicated end-to-end JVM test was added to
`jvm_cross_package_collision_self_test.l` ("qualified record field type
resolves to the exact package named") pinning bug 1's shared type-checker
fix on `--target jvm` too, not just confirming it by code inspection.
