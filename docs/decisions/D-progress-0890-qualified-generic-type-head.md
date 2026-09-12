# D-progress-890 — MSIL codegen: a qualified generic type's own HEAD now resolves to the exact package named, closing the #6992 gap left by D-progress-888's `TRef`-only fix

**Status:** shipped

**Context.** A `claude-review` REQUIRED finding on PR #6904 (D-progress-888)
pointed out that `resolveTypeFqnQualified` was wired into `typeExprToMsilCtx`'s
bare `TRef` case only. The identical hazard applies to a qualified generic
type's own HEAD, not just its type arguments or a bare reference: `PkgA.Box[Int]`
where an unrelated `PkgB` also declares `Box[T]` still resolved `Box` via
the unqualified `resolveTypeFqn(cctx, pkgName, headSeg)` in the `TGenericApp`
fallback branch (reached whenever the generic head isn't one of the
special-cased names `List`/`Map`/`Set`/`MapKeyCollection`/`MapValueCollection`)
of **four** functions: `typeExprToMsilCtx`, `typeExprToMsilG`,
`typeExprToMsilGenBody`, and `typeExprToMsilGenSig`.

**Fix.** All four call sites now call `resolveTypeFqnQualified(cctx, pkgName,
head, headSeg)` — the same helper D-progress-888 introduced — passing the
generic application's own `head: ModulePath` (already in scope, used to
compute `headSeg` via `lastSegmentMsil(head)` at each site) instead of just
the bare tail segment.

**Verification.** New self-test in `msil_project_bridge_self_test.l`:
`Pkg6992A` and `Pkg6992B` each declare their own unrelated `Box[T]` union
with DIFFERENT case sets (so a wrong resolution can't coincidentally
construct the right shape); `Main6992` (which imports both) declares a
function whose PARAMETER type is the qualified `Pkg6992A.Box[Int]` — a
`val` type annotation was tried first and found NOT to observe the defect
(codegen derives a local's slot type from the initializer expression's
already-correct inferred type, not by re-resolving the annotation text),
mirroring the D-progress-893 test-harness dead end for a different reason.
Confirmed by reverting the fix and re-running: `error[T0115]: cannot
resolve name 'v' to a value here (in Main6992.unwrap)` (the match arm's
binding fails to type-check against whichever wrong `Box` instantiation
the parameter signature actually named); with the fix, it compiles and
runs, printing the expected value. Full `msil_project_bridge_self_test.l`
(57/57), `jvm_cross_package_collision_self_test.l` (9/9), and
`typechecker_self_test.l` (419/419) all pass with no regressions.

**Related:** #6992 (this fix), D-progress-888/#6904 (the `TRef`-only
predecessor fix this closes the gap in).
