# D-progress-893 — Self-hosted compiler: union case field types now resolve under the case's OWN declaring package, closing the #6972 gap left by D-progress-888's record-only fix

**Status:** shipped

**Context.** A `claude-review` REQUIRED finding on PR #6904 (D-progress-888)
pointed out that its `collectCtorFields` fix only covered records/exposed-
records/opaque constructor fields — `unionCaseFieldTypes` (backing both
`inferUnionCaseConstruction`, the construction path, and
`caseFieldTypesInstantiated`, the `match`-arm pattern-bind path) still
resolved a union case's field types under whatever `SymbolTable` scope was
active at the call site, leaving the identical cross-package same-name
collision hazard open for union case fields.

**Confirming the gap.** Debug instrumentation against the unfixed code
(temporary `println`s in `unionCaseFieldTypes`, since neither backend's
codegen observably diverges on a plain field READ through a pattern-bound
union-case field — MSIL re-derives a pattern-bound local's CLR layout
independently of this specific type-checker result at codegen time, and JVM
does too for this construct) confirmed the field type genuinely resolves
wrong: with a union declared in package `Pkg6972Owner` (`Full(tag: Item)`,
`Item` also declared in `Pkg6972Owner`) destructured from a project's
`Main6972` package that imports BOTH `Pkg6972Owner` and an unrelated
`Pkg6972Collide` (which ALSO declares an `Item`), `tag`'s bound field type
resolved to `Pkg6972Collide`'s `Item` — the last-registered candidate under
tier-2 scope resolution — instead of `Pkg6972Owner`'s (the field's own
declaring package). The resolution order is sensitive to package
registration order in the project's package list / the caller's own import
order, so the collision is timing-dependent, not deterministic either way.

**Fix.** Centralized the scope save/switch-to-declaring-scope/restore
(mirroring `collectCtorFields`'s established pattern) INSIDE
`unionCaseFieldTypes` itself, adding an `originPackage: in String`
parameter (both call sites already have it via `caseSym.originPackage`) —
this closes the gap at both call sites (construction and pattern-bind) with
one change instead of duplicating the scope-juggling boilerplate twice.

**Verification.** A type-checker-only test (asserting on diagnostics from
`checkWithImportedPackages`) turned out NOT to observe this defect: neither
a member-access check (T0113 only covers types declared in the checking
file, per docs/44's m-96 finding) nor, empirically, a nominal
argument-type-mismatch check (T0043) fired differently with the bug present
under that harness's own package-registration order. The regression test
that DOES observe it lives in `msil_project_bridge_self_test.l`
("union case field type resolves to the exact package named, not the
caller's scope (#6972)"): a full `compileProjectToMsil` build (which uses
the project bridge's own registration order, confirmed via the debug
instrumentation above to reproduce the collision) passing the pattern-bound
`tag` to a function requiring exactly `Pkg6972Owner.Item` — a wrong
resolution is a hard T0043 that fails the whole compile (confirmed by
reverting the fix and re-running: `error[T0043] 7:44: argument type Item
does not match parameter type Item`); with the fix, it compiles and runs,
printing the expected value. Full `msil_project_bridge_self_test.l` (56/56),
`jvm_cross_package_collision_self_test.l` (7/7), and `typechecker_self_test.l`
(419/419) all pass with no regressions.

**Related:** #6972 (this fix), D-progress-888/#6689 (the record-only
predecessor fix this closes the gap in), PR #6904.
