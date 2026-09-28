# JVM project builds: build the weaver type-owner index once, cache extern seeds per file (#7497, #7503)

`Jvm.Bridge.compileProjectToJarBundledWithRestored` — the JVM manifest/project
build path — had two sources of redundant per-package work carried over from
`Lyric.Pipeline.pipeMiddleEnd`'s generic per-file contract:

- **#7497**: `pipeMiddleEnd` calls `Lyric.Pipeline.pipeTypeOwnerIndex(importedPkgs)`
  (the weaver's A0047 row-type-check index, docs/56) on every invocation. The
  JVM bridge called `runMiddleEnd` (a thin `pipeMiddleEnd` wrapper) once per
  bundled package — the entry package plus every sibling project package —
  so the identical index was rebuilt from the identical `importedPkgs` list
  once per package. The MSIL project path (`Msil.Bridge`) already builds its
  `weaveTypeIndex` once before its weave loop and reuses it across every
  package.
- **#7503**: `externSeedForFile` (the per-file transitive-import-closure BFS
  behind `Jvm.Bridge`'s extern-type resolution) was recomputed from scratch on
  every call, even for the SAME file. The bundling loop's per-package block
  calls it up to six times for the identical file (`collectDeriveFreeSigs`,
  `collectAspectWovenSigs`, `collectBModeWovenSigs`,
  `collectMonoSpecializedSigs`, `collectFileCasesExtern`,
  `withRecvClasses`'s own seed argument), once for the entry package and once
  again for each sibling; the #7644 derive pre-pass loop added a seventh call
  site for the pre-middle-end file.

## Fix

`Lyric.Pipeline.pipeMiddleEnd` (and its `runMiddleEnd`/`compileToJarBundledWithRestored`
callers) now take an optional prebuilt `Weaver.TypeOwnerIndex`
(`typeIndex: in Option[Weaver.TypeOwnerIndex]`); `None` keeps the previous
on-demand behaviour (every single-file caller and the native LLVM bridge pass
`None`, unchanged). `Jvm.Bridge.compileProjectToJarBundledWithRestored` builds
the index once, right where it already collects cross-package aspect
templates (mirroring `Msil.Bridge`'s `weaveTypeIndex`), and passes
`Some(value = weaveTypeIndex)` to both the entry-package and every
sibling-package `runMiddleEnd` call.

`Jvm.Bridge.externSeedForFile`'s result depends only on the file's own
`file.imports` list, given a fixed `(extPkgNames, extPkgMaps,
pkgImportNames)` triple — which is fully finalised by the time the bridge's
first `externSeedForFile` call runs. A new `externSeedForFileCached` wrapper
memoises by the file's import list content (`importsCacheKey`, a `dottedPath`
join of `file.imports`) in a `Map[String, Map[String, String]]` cache that
lives for the whole bundled build; every call site in
`compileProjectToJarBundledWithRestored` (21 call sites) now goes through it.
Keying on import *content* rather than file identity or package name is
required for correctness: a weave-time import injection (`addStdTimeImport`
for `call.elapsed` instrumentation, #1298) can add an import between the
derive pre-pass's pre-middle-end file and the main loop's post-middle-end
file for the same package, so those two calls must NOT share a cache entry
unless their import lists are actually identical — the content key handles
this automatically (different imports → different key → recompute), while
also picking up the common case where imports are unchanged and the six
per-package calls collapse to one real computation.

Both fixes are behaviour-preserving refactors — no new correctness fix is
claimed for `#7497`'s "is the JVM path missing a correctness gap parity with
MSIL" question (see below).

## The MSIL-parity investigation (#7497)

`Msil.Bridge`'s `weaveTypeIndex` starts from `baseImportedPkgs` (stdlib +
restored deps only) and explicitly adds its own bundle packages
(`perPkgFiles`) plus path-dependency template sources
(`depTemplatePkgs`/`dtRewritten`) via `Weaver.typeOwnerIndexAddFile`, because
MSIL's `baseImportedPkgs` doesn't carry the bundle's own packages.

The JVM bridge's flat `importedPkgs` list is a superset of MSIL's
`baseImportedPkgs ∪ perPkgFiles`: it already unions the entry package, every
stdlib file, every sibling project package, AND every restored artifact (see
the `importedPkgs.add(...)` calls at lines ~2241, ~2297, ~2388, ~2608), so
`pipeTypeOwnerIndex(importedPkgs)` already covers what MSIL's two-step union
achieves — "an aspect matching a type from another bundled package" was
never actually missing type-owner coverage on the JVM path.

The one thing `importedPkgs` genuinely does NOT carry, matching MSIL's gap
exactly, is **path-dependency template sources** (`depTemplateSrcs`): a path
dependency's aspect template is parsed and its templates collected via
`Weaver.collectAspectTemplates`, but its own declared types were never fed
into the type-owner index. The fix adds the matching
`Weaver.typeOwnerIndexAddFile(weaveTypeIndex, dtRewritten)` call in the
`depTemplateSrcs` loop, for structural parity with `Msil.Bridge`.

Investigating whether this was a **live** correctness gap: every current JVM
CLI caller that populates `EmitProjectRequest.depTemplateSrcs`
(`emitSingleFileWithWorkspaceMembers`, the general single-file-near-manifest
path, and `buildProjectFromManifest`'s manifest path, all in
`lyric-compiler/lyric/cli/cli_build.l`) ALSO adds the identical
path-dependency/workspace-member packages into the full compiled bundle
(`pkgs`) when `target == Emitter.Jvm` — see the `case Emitter.Jvm -> { ...
pkgs.add(...) }` blocks around lines 844-853, 927-936, and 2682-2691 of
`cli_build.l`. So every package that appears in `depTemplateSrcs` today is
ALSO already a member of `importedPkgs` via the ordinary
entry/stdlib/sibling registration loop, and its types are already indexed
before the new `typeOwnerIndexAddFile` call ever runs. A minimal repro
(a path-dependency-only package declaring a `pub aspect ... where TArgs has
{ f: CustomType }` template, consumed by an app package that never imports
the dependency directly) cannot even reach weave-time: the type checker
itself rejects a signature referencing `CustomType` through an unimported
package before A0047 is reached, since `importedPkgs` — not
`depTemplateSrcs` — is what `Lyric.TypeChecker.checkFile` resolves imports
against.

Conclusion: the added `typeOwnerIndexAddFile` call for `depTemplateSrcs` is
defense-in-depth / exact structural parity with `Msil.Bridge`, not a fix for
a reachable bug today — it protects a future JVM caller that (unlike every
current one) feeds `depTemplateSrcs` content not duplicated into `pkgSrcs`
(paralleling MSIL, which never recompiles a path dependency's source into
its own bundle at all — it reads the compiled types from the restored DLL's
contract and only needs the dependency's SOURCE for template splicing).

## Verification

- Built `lyric-storage` (`lyric.toml`, 4 packages, no `[dependencies]`) with
  `--target jvm` on the base commit and on this change (`Weaver.CollectedTemplate`
  templates, aspects, and a `Storage.Kernel.Jvm` extern boundary exercise the
  changed collectors): the resulting JAR is **byte-for-byte identical**
  (`md5sum` match) across a base build, the first fixed build, and a second
  fixed rebuild from a clean stash/pop cycle.
- `scripts/ci/compiler-self-tests-batch.sh`: 2214 `ok`, 0 failures, exit 0.
- `scripts/ci/jvm-generics-self-tests-batch.sh`: 127 `ok`, 0 `not ok`.
- `scripts/ci/jvm-ecosystem-suites.sh` (storage, resilience, jsonrpc, mcp,
  health, generator-sdk, web — the last with a real Maven-restored
  `io.undertow:undertow-core` dependency): all seven suites report `0
  failed`.
- Every `--target jvm` self-test file listed in `.github/workflows/ci.yml`
  (119 files, via `scripts/ci/self-test.sh`): 118 pass; the one reported
  failure (`config_block_self_test.l`) was this session's own test-harness
  omission (two of the eight required `LYRIC_CONFIG_...` env vars were
  dropped when copying the CI step's env block) — re-run with the complete
  env var set from `ci.yml`, it passes 6/6.
- Timing: `lyric build --manifest lyric-storage/lyric.toml --target jvm`,
  3 runs each, base ≈ 9.1–10.4s, fixed ≈ 9.5–9.9s (modest — `lyric-storage`
  has only 4 packages, so the O(packages) → O(1) type-index rebuild and the
  O(6) → O(1) per-file extern-seed recomputation save less here than on a
  larger multi-package project; the algorithmic win scales with package/file
  count).

## Files changed

- `lyric-compiler/lyric/pipeline/pipeline.l` — `pipeMiddleEnd` gains a
  `typeIndex: in Option[Weaver.TypeOwnerIndex]` parameter.
- `lyric-compiler/jvm/bridge.l` — `runMiddleEnd` forwards the new parameter;
  `compileProjectToJarBundledWithRestored` builds `weaveTypeIndex` once and
  adds `depTemplateSrcs` to it; new `externSeedForFileCached` /
  `importsCacheKey` helpers; every `externSeedForFile` call site in the
  project-build function routes through the cache.
- `lyric-compiler/lyric/llvm_bridge.l` — its two `pipeMiddleEnd` call sites
  pass `None` (unchanged on-demand behaviour).
- `lyric-compiler/jvm/codegen/06_items.l` — `lowerFuncScoped`'s inline
  `decl.name` dot-split now calls the existing `jvmDotMethodNameFromDeclName`
  helper (01_types.l) instead of duplicating its split/substring logic
  (spotted during review of the adjacent #7501/#7502 derive-dispatch
  mangling this PR builds on top of).
