# D-progress-886 — Native project-package diagnostics get real-path/origins attribution; MSIL codegen-phase (F0xxx) diagnostics and `pipeExpandAndRewrite`'s two gates resolve through the origins table too (#6824)

**Status:** shipped

**Context.** #6282/#6284's own fix (D-progress-804, D-progress-868) threaded
real-path and per-merged-line-origin attribution through the shared
parse/typecheck/modecheck/elaborate/propagate/derive/mono/weave pipeline for
the MSIL and JVM project-build paths, but explicitly carved out three
surfaces to keep that change bounded: (1) the **native** project-build path
— `Lyric.LlvmBridge.NativeSourcePackage` had no `path` field at all (a
pre-existing gap, not a regression — native's own project support predates
#6282), and `compileProjectToNativeWithFlags` had no `origins` parameter;
(2) **codegen-phase (F0xxx)** diagnostics — `Msil.Bridge
.abortOnCodegenDiagnosticsMsilInPkg` labels by bare package name only, since
F0021–F0025/F0034 accumulate on `CodegenCtx.diagnostics` directly rather than
routing through `Lyric.Pipeline.gate`; (3) `Lyric.Pipeline
.pipeExpandAndRewrite`'s two gates (docs/58 wire/config-template expansion,
and same-file interface-default-method inheritance) unconditionally called
`gate("", noOrigins, …)` regardless of whether the caller had already
resolved a real label/origins pair for the exact same package. Filed as
#6824 alongside #6284's own remaining acceptance-criteria audit (MSIL
`Document`/native `DIFile` emission — full debug-info bands B3/B4, not
attribution — are the only items #6284 still leaves open; see the note at
the end of this entry).

**Fix — item 1 (native).** `NativeSourcePackage` gains a `path: String`
field (mirroring the MSIL/JVM `pkgPaths`/`path` parity fields — "" for a
genuinely multi-file package, matching `ProjectPackage.paths`' own
convention). `compileProjectToNativeWithFlags` gains a trailing
`originsByPkg: List[Lyric.DiagnosticUtil.PackageLineOrigins]` parameter
(the same wrapper record #6824's own body flags as the required shape,
per D-progress-868's `List[List[<cross-package-record>]]`
generic-specialization trap) and two small helpers,
`nativePkgLabelAt`/`nativePkgOriginsAt`, resolve "real path when known, else
bare name" / "origins table entry, or empty" once per index — used
uniformly across all three of the function's own per-package loops: the
`pipeParseAndErase` loop, the `pipeExpandAndRewrite` loop (item 3, see
below), and the `MiddleEndOptions` loop feeding `pipeMiddleEnd`. The last of
these is the one place native's attribution differs structurally from
MSIL/JVM: native has no separate weave phase (docs/63 §9.6 — `pipeMiddleEnd`
folds typecheck/modecheck/elaborate/propagate/mono/weave into one call for
native), so fixing `MiddleEndOptions.pkgLabel`/`.lineOrigins` in that one
loop covers weave attribution too, for free. `Lyric.Emitter
.emitNativeProject` (the one real caller outside self-tests) now mirrors
`emitProject`'s own `pkgOrigins`/`mergePackageSourcesWithOrigins`
construction: a single-file own package gets its real `pkg.paths[0]`, a
multi-file one gets `path = ""` plus a populated origins table from
`mergePackageSourcesWithOrigins`.

**Fix — item 2 (MSIL codegen-phase).** New
`abortOnCodegenDiagnosticsMsilInPkgWithOrigins` wraps
`Lyric.DiagnosticUtil.diagReportAndAbortInPkgWithOrigins` (already shipped
by D-progress-868 for the shared-pipeline gates, just never called from the
codegen site) and replaces the old `abortOnCodegenDiagnosticsMsilInPkg` call
in the project bundle's per-package codegen loop, passing
`parsedPkgs[ci].origins` — the SAME `ParsedUserPkg.origins` table the
typecheck/weave phases a few lines earlier already resolved for this exact
package index (`liftedFiles`/`perPkgNames`/`parsedPkgs` are 1:1 by
construction, per the pre-existing loop comment). The now-unreachable
`abortOnCodegenDiagnosticsMsilInPkg` function itself is deleted rather than
left behind as dead code (flagged by review, addressed same-PR). **No
JVM-side change**:
the JVM backend has no codegen-phase diagnostics accumulator analogous to
`CodegenCtx.diagnostics` at all (F0021–F0025/F0034 are MSIL-specific
external-interface-conformance and try-catch-as-expression checks,
D-progress-809) — #6824's "and the JVM analog" phrasing does not correspond
to an actual gap on that target.

**Fix — item 3 (`pipeExpandAndRewrite`).** Added `label: String` /
`origins: List[DiagUtil.MergedLineOrigin]` trailing parameters (matching
`pipeParseAndErase`'s and `pipeWeave`'s own parameter shape), threaded to
both of its `gate()` calls in place of the hardcoded `""`/empty pair. All
six call sites across the three bridges now pass the same label/origins
pair the surrounding parse phase already resolved: the single-file paths
pass their own `path`/`noOrigins`; the MSIL and JVM project loops pass
`wep.label`/`wep.origins` and a per-package `pkgPathByName`/`pkgOriginsByName`
lookup respectively (mirroring each bridge's own existing convention); the
native project loop passes the same `nativePkgLabelAt`/`nativePkgOriginsAt`
pair item 1 introduced. The one caller with nothing to improve —
`Jvm.Bridge.compileToJar`, a legacy path with no `path` parameter at all,
used only by four `self_test_b13{0,2,3,4}.l` self-tests — keeps `""`/empty
unchanged.

**Verification.** All of the following exercised against a `make lyric`
rebuild seeded from the published NuGet `lyric` 0.6.2 global tool's own
installed DLLs (fed into `.bootstrap/stage0-publish/`, per D-progress-543's
sandbox-seeding technique — the GitHub release-download bootstrap step is
network-policy-blocked in this sandbox), so every assertion below ran
against a toolchain that actually contains this entry's fixes, not the
published tool's stale compiler:
- `source_path_diagnostics_self_test.l`: 17/17, five new cases — "multi-file
  project package (native): a parse error in the second file names that
  file and its real line" (item 1; a `--target native` sibling of the
  existing dotnet/jvm #6282 multi-file parse-error tests), "multi-file
  project package (dotnet): a codegen-phase error (F0025) in the second
  file names that file and its real line" (item 2; a `wrap[T]` generic
  try-catch Unit/value mismatch specialised via `Lyric.Mono`, split so the
  trigger lives entirely in the second file), "multi-file project package
  (dotnet): an impl-default diamond conflict (T0117) in the second file
  names that file" and its `--target native` sibling (item 3; two
  same-file-in-a.l interfaces defaulting one method name onto a
  `b.l`-declared record with both `impl`s, unresolved — the native case
  confirms `pipeExpandAndRewrite`'s unconditional `ImplDefaults
  .inheritDefaultsFile` gate attributes correctly via
  `nativePkgLabelAt`/`nativePkgOriginsAt` too, not just the parse-phase
  case item 1 already covered), and "multi-file project package (jvm): a
  weave-time error (A0044) in the second file names that file and its real
  line" (#6824 item 4 — the `--target jvm` sibling of D-progress-868's
  dotnet-only A0044 regression test; `Jvm.Bridge`'s `pkgOriginsByName`
  plumbing was previously only manually verified for this exact shape).
- `llvm_project_self_test.l`: 10/10 (every `NativeSourcePackage`/
  `compileProjectToNativeWithFlags` construction site updated for the new
  `path` field / `originsByPkg` parameter; ASan-compiled, required
  installing `libclang-rt-18-dev` in this sandbox for
  `libclang_rt.asan-x86_64.a`).
- `msil_codegen_diag_self_test.l`: 14/14 (F0021–F0026 unaffected —
  confirms the new `WithOrigins` codegen gate variant is behaviourally
  identical to the old one when `origins` is empty).
- `weaver_self_test.l`: 46/46; `wire_expand_self_test.l`,
  `config_block_self_test.l`, `config_templates_self_test.l`,
  `wire_templates_self_test.l`: all green (the two `pipeExpandAndRewrite`
  gates' existing behaviour is unchanged for every pre-existing caller,
  which all pass `""`/empty exactly as before).
- `bitwise_self_test.l` and `aspect_weave_self_test.l`, both targets:
  unaffected (10/10, 13/13).
- `./bin/lyric fmt --write` accepted every changed `.l` file with no
  loss-check refusals.

**#6284 status.** Per the assigning task's own audit request: JVM
`SourceFile` and diagnostics-include-a-filename were already shipped
(D-progress-804); multi-file packages reporting original-file lines closed
in D-progress-868; this entry's item 1 gives native the same real-path
attribution MSIL/JVM already had. The two acceptance items #6284 still does
NOT close are MSIL's portable-PDB `Document` table (band B3) and native's
`!DIFile` (band B4) — those are full debug-information EMITTERS (docs/63
§9.4/§9.6), an unimplemented and substantially larger scope than the
attribution plumbing this entry and its predecessors close out; #6284 stays
open against that remaining scope rather than being closed here.

**Related:** #6282, #6284, #6824 (closed by this entry), D-progress-804,
D-progress-868, `docs/63-build-profiles-and-debugger.md` §9.5/§9.7
(updated alongside this entry), D-progress-543 (the sandbox-seeding
technique this session's verification used).

**Note on numbering.** This entry was originally drafted (during this PR's
development) as D-progress-878, then renumbered to 882, then 883, each time
displaced by another PR merging the same number to `main` first while the
decision log was still a single append-only file. It landed here under 886
once `docs/decisions/` (this per-file convention, D-progress-885's
successor design) shipped, since a plain append no longer races.
