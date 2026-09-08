# D-progress-888 — MSIL codegen: an unannotated module-level `val` initialized by a record-constructor call is now typed as the constructed record, not `MObject` (#6786)

**Status:** shipped

**Context.** `msil/codegen.l`'s `inferUntypedStaticValMsilType` predicts the
MSIL field type of an untyped (`decl.ty == None`) module-level `val`/`const`
so that OTHER functions' `EPath`/`EMember` lowering knows what type a bare
`ldsfld` read of that field produces. #5955/#5988/#5992 taught it to resolve
`EPath` (a reference to an earlier val) and the common `EBinop` shapes; every
other expression form — including `ECall` — still fell through to the
catch-all `case _ -> MObject`.

**Symptom.** `val gCache = Cache(box = MutRecvBox(tag = 1))` (no type
annotation) predicted `MObject` for `gCache`'s field. A later `gCache.box`
read is an `EMember` whose receiver resolves to that (wrong) `MObject` type;
the field-read codegen path this falls into resolves the field by bare name
across the file's declared records (the same "keyed by name, first-registered
wins" class as #6682/#6639) rather than by the receiver's real record type. If
another record in the same file happens to declare a field with the same name
and is registered first, the read emits `castclass <wrong record>` against an
instance of the right-hand record — `InvalidCastException` at runtime, with a
clean build (silent miscompile).

**Fix.** Add an `ECall` arm to `inferUntypedStaticValMsilType` that resolves a
record constructor call the same way real `ECall` codegen does —
`cctx.recordCtorTokens` keyed by `<pkg>.<name>` first, then the fully
qualified callee — but only for a simple/qualified `EPath` callee and only
for the **non-generic** case: a generic record needs inferred type
arguments this single-expression pass has no symbol table to compute, so it
still falls back to `MObject` there (documented, matching the existing
"no symbol table at this pass" caveats elsewhere in this function and in
`hoist_engine.l`) rather than risk guessing a wrong instantiation. Scoped to
PLAIN RECORDS only, not union cases (review SUGGESTION): a local union
case's ctor token is registered under the mangled key
`<pkg>.<UnionName>_<CaseName>`, never the bare `<pkg>.<CaseName>` this arm
builds, so the arm's key lookup is always a miss for a union case — it
falls back to the documented `MObject`, same as before this fix, rather
than mistyping the value as the case's own class (defensively guarded via
`cctx.caseParentUnion.containsKey`). Threading this through required adding
`cctx: in CodegenCtx` and `pkgName: in String` parameters to
`inferUntypedStaticValMsilType` (used only by the new `ECall` arm; every other
arm ignores them) and its two call sites, both already inside
`addPackageTokens` where `cctx`/`pkgName` are in scope.

**Follow-up fix (#6878, review REQUIRED).** The `EPath` arm's `env`
(`valTypeEnv`) is frozen the first time each name is predicted, during
`addPackageTokens`' Pass 0 loop — which runs BEFORE Pass 1 populates
`cctx.recordCtorTokens`. So a record-constructor val processed in Pass 0
still gets `MObject` written into `env` at that point, even though Pass 1b
(after Pass 1) correctly recomputes the type into the authoritative
`cctx.staticValMsilTypes` map once `cctx.recordCtorTokens` exists. A later
`val alias = gCache` resolved only against the stale `env` entry inherited
that wrong `MObject` — reproducing this same issue's defect one alias hop
removed, undetected by the added test (which never aliases `gCache`). Fixed
by having the `EPath` arm consult `cctx.staticValMsilTypes` FIRST, falling
back to `env` only when absent there — `cctx.staticValMsilTypes` is
populated in the same file-declaration order `env` documents, so this can
only recover a more precise, already-corrected type, never regress a
lookup `env` would otherwise have answered.

**Regression coverage.** Extended `module_val_deps_self_test.l` (already
wired into CI on both `--target dotnet` and `--target jvm`) with the issue's
own repro shape: two records (`Holder`, declared first; `Cache`, declared
second) sharing a field name (`box`), and an unannotated
`val gCache = Cache(box = MutRecvBox(tag = 1))`. Pre-fix this would predict
`gCache: MObject` and mis-resolve `gCache.box` against `Holder`;
post-fix `gCache.box.tag` correctly reads `1`. A second val
(`gCacheParen`, wrapped in `EParen`) exercises the same `ECall` arm reached
through the predictor's existing `EParen` recursive delegation. JVM was never
affected (`prelowerModuleVals` derives every module val's field type from a
real lowering pass in declaration order, so it never diverges from the
initializer's real type) — the file already ran on both targets as a parity
pin, and continues to.

**Follow-up fix (#6966, review REQUIRED).** The `ECall` arm's `ctorKeyOpt`
resolution only implemented the LOCAL-package and explicit-qualifier tiers
of real `ECall` codegen's three-tier lookup, omitting the third
(`resolveTypeFqn`'s import-aware cross-package resolution). An UNQUALIFIED
reference to a record declared in a DIFFERENT, imported package (`import
Other.Lib; val g = Cache(...)`, no `Other.Lib.` qualifier) matched neither
implemented tier and fell back to `MObject`, reproducing this issue's exact
defect class one package hop removed: `fieldTokensByName`'s fallback key is
scoped to the READING package (`fctx.pkgName + "/" + memberName`, not the
constructed value's real declaring package), so a same-named field on one of
the consuming package's OWN records resolves in its place, `castclass`ing
against the wrong type. Fixed by adding the same `resolveTypeFqn(cctx,
pkgName, funcName)` tier real codegen uses, tried after the local/qualified
tiers miss and before falling back to `MObject`; `resolveTypeFqn` only needs
`cctx`/`pkgName` (both already threaded through this function) plus the
callee's simple name. Regression-tested in
`msil_project_bridge_self_test.l` (the established home for multi-package
MSIL bridge scenarios `lyric test`'s single-file synthesis can't reach): a
`Lib` package declaring `pub record Cache { box: Int }`, and an `App`
package that imports it, declares its own colliding `record Holder { box:
Int }`, and binds `val gCache = Cache(box = 42)` unqualified — pre-fix this
throws `InvalidCastException` reading `gCache.box` (resolves through
`App`'s own `Holder` field token); post-fix it correctly prints `42`.
