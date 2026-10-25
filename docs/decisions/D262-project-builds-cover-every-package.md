# D262 — A project build covers every listed package; a package declares its target; `prove` runs the target's rewrites; multi-file packages keep their module docs

**Status:** accepted, implemented (#8357, #8311, #8246)

## Context

Three behaviours of the build system hid errors or dropped information:

- The JVM project build bundled the packages reachable from the entry
  package's imports and nothing else (`compileProjectToJarBundledWithRestored`
  seeded its import-closure walk from the entry package alone). A type error
  in a listed package that nothing imports built green on `--target jvm` and
  was reported on `--target dotnet` (#8357).
- `lyric prove --target jvm|native` checked through the MSIL bridge's front
  end, configured with the target's options. The bridges run the same
  `Lyric.Pipeline` passes, but each calls `pipeExpandAndRewrite` with its own
  literal flags (JVM injects weave imports; native synthesises no `@stubbable`
  stubs), so a program the native build rejects could be proved (#8311).
- `Lyric.PackageMerge` dropped every file's `//!` module docs from the merged
  unit, so a package of several files had no module doc where a package of one
  file had its own (#8246).

## Decision

1. **Every listed package is built.** The JVM project build adds every sibling
   project package to the import-closure walk, as the dotnet build already
   compiles every listed package. Reachability from the entry package decides
   only which standard-library packages are bundled.
2. **A package declares the targets it applies to with a file-level
   `@cfg(target = "...")`.** The existing mechanism erases every item of the
   file on the other targets (docs/19 §4), so the package is empty there and
   its kernel code is neither checked nor emitted. No new manifest field is
   introduced: the declaration sits in the file whose code it describes, which
   is also where `@cfg(feature = ...)` already sits. Applying it: `Grpc` and
   `Grpc.Aspects` are dotnet-only until the JVM kernel (Phase 6) exists.
3. **The pre-check rewrites of a target are one value.**
   `Lyric.Pipeline.pipeExpandProfile(targetName)` returns the `runWireExpand`,
   `runStubbable` and `injectWeave` flags of a build for that target;
   `pipeExpandAndRewriteFor` / `pipeExpandAndRewriteCollectFor` apply them.
   The MSIL, JVM and native bridges call the `For` forms with their target
   name, and so does the check `lyric prove` runs (`Msil.Bridge.checkSourceTypesForFeatures`,
   `projectFrontEnd`), so the two cannot drift. A native check also erases by
   the host's `target_os`, as a native build does.
4. **The module docs of every file reach the merged unit.** They are emitted,
   as each file wrote them, before the merged annotations in file order, with an
   empty `//!` line between files; each line keeps its file and line in the
   origins. A file gated out by its file-level `@cfg` contributes none (it
   contributes no items or imports either). This also applies to the
   standard-library and compiler packages the compiler discovers
   (`mergeDiscoveredPackage`), whose single files had their docs dropped by the
   rebuild: their merged units now start with their `//!` lines, which shifts
   the unit's line numbers; no output depends on the old numbers (line tables
   and the weaver's call-site strings are produced from the merged unit by
   both stages of the bootstrap alike).

## Not decided: #8311's full unification

`lyric prove` still runs the MSIL bridge's front-end entry points. What
differs between the bridges beyond the profile above is target-specific
preparation of the *standard library* (native erases its sources by
`target_os` and alias-rewrites them; the JVM synthesises invariant checkers the
same way MSIL does) and the native bridge's shim and config-block diagnostics.
A prove-check entry per bridge needs those bridges' project front ends split
from their compile functions; that split is tracked in the follow-up named on
#8311.

## Not decided: #7971

A cache of the bundled-stdlib type check cannot skip the check: the native
bridge needs the checker's symbol tables to lower record arithmetic and array
sites in each stdlib package (`checkBundledStdlibPackage`), so a cache must
store the lowered package, and the AST has no serialised form. The plan is on
#7971.
