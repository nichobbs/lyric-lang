//! msil/bridge.l — Self-hosted MSIL compilation pipeline (Phase R6).
//!
//! Public entry point that chains the self-hosted Lyric pipeline to produce a
//! .NET PE DLL from Lyric source text.  Calls (docs/41 §9 Band 1 + Band 5):
//!   parse → typecheck → modecheck → elaborate → mono
//!        → newCodegenCtx → addPackageTokens
//!        → codegenMPackage → lowerMPackageWithCtx → writeBytes
package Msil.Bridge

import Std.Core
import Std.Collections
import Std.File
import Lyric.Lexer
import Lyric.Parser
import Lyric.AliasRewriter as Aliases
import Lyric.Stubbable as Stubbable
import Lyric.TypeChecker
import Lyric.ModeChecker
import Lyric.ContractElaborator
import Lyric.Propagate
import Lyric.Cfg as Cfg
import Lyric.DiagnosticUtil as DiagUtil
import Lyric.Mono
import Lyric.Derives
import Lyric.RestoredPackages
import Lyric.ContractMeta as Meta
import Std.Encoding as Encoding
import Lyric.Weaver as Weaver
import Msil.Lowering
import Msil.Codegen
import Msil.Tables
import Msil.Heaps

/// Compile `source` to a .NET PE DLL at `outputPath` using the self-hosted
/// MSIL pipeline.
///
/// Returns true on success; false if the source contains parse / type /
/// mode errors, or if the file write fails.  All error- and warning-severity
/// Band 6: accept pre-read stdlib source texts for cross-package type resolution.
/// diagnostics from each pass are printed to stdout before the bridge
/// returns.  The package name and assembly name are taken from the parsed
/// `package` declaration in the source.
pub func compileToMsil(source: in String, outputPath: in String, stdlibSources: in List[String]): Bool {
  compileToMsilWithVersion(source, outputPath, stdlibSources, "")
}

/// Variant of `compileToMsil` that accepts a `[package].version` string.
/// Empty string means "no version threaded" — falls back to `0.0.0` for
/// the Assembly row and the embedded `Lyric.Contract` resource, matching
/// the legacy `compileToMsil` behaviour.  Non-empty values are parsed via
/// `parseSemverMajorMinor` (patch / pre-release segments ignored; the
/// full string is preserved verbatim in the contract resource).  See
/// #1364 for the threading plan.
pub func compileToMsilWithVersion(
  source: in String,
  outputPath: in String,
  stdlibSources: in List[String],
  packageVersion: in String,
): Bool {
  val parseResult = parse(source)
  if reportAndAbort(parseResult.diagnostics) {
    return false
  }

  // ── Middle-end (Band 1 + Band 6 of docs/41 §9) ─────────────────────────
  // Run the self-hosted type checker with stdlib imports, mode checker, and
  // contract elaborator before codegen so that source-level diagnostics surface
  // here instead of producing broken IL further down.
  //
  // Band 6: parse each stdlib source and register its type-shaped items as
  // imported items so user code can reference `Std.X.Bar` (and the kernel-
  // declared `List[T]`, `Map[K,V]`, `Random`, `Scope`, …) at typecheck.
  // See `collectStdlibTypeItems` for the filter set and the rationale.
  //
  // `collectStdlibPackages` produces the per-package grouping that the
  // codegen `registerStdlibArtifactTokens` consumes below to wire
  // cross-assembly `MemberRef` rows for `pub func` items.
  val stdlibPkgs = collectStdlibPackages(stdlibSources)
  // Group stdlib items by package so each resolves against its own decls,
  // fixing the same-name cross-package type collision (#1488 category D).
  val importedPkgs: List[ImportedPackage] = newList()
  var spi = 0
  while spi < stdlibPkgs.count {
    importedPkgs.add(ImportedPackage(name = stdlibPkgs[spi].name, items = stdlibPkgs[spi].items))
    spi = spi + 1
  }

  // Collapse `import X as Y` aliases: rewrite `Y.foo(...)` to bare
  // `foo(...)` (and the same for type / pattern positions) so the
  // self-hosted typechecker, which doesn't track import aliases
  // natively, doesn't fire T0020 on the alias head.  Mirrors the
  // F# `Lyric.Parser.AliasRewriter.rewriteFile` pass that the
  // production F# emitter runs immediately after parse.  Then synthesise the
  // `@stubbable` interface stubs (record + impl) so the type checker and codegen
  // see them — mirrors the F# `Lyric.Parser.Stubbable` pre-typecheck pass.
  val file0 = Stubbable.stubbableRewriteFile(Aliases.rewriteFile(parseResult.file))

  val tcRes = checkWithImportedPackages(file0, importedPkgs)
  // Type errors in a single-file build are now fatal, matching the project path.
  if reportAndAbort(tcRes.diagnostics) {
    return false
  }

  val mcRes = checkFile(file0)
  if reportAndAbort(mcRes.diagnostics) {
    return false
  }

  val elaborated = elaborateFile(file0)

  // Lower `?` error-propagation into match-unwrap + early-return (#1475).
  // Runs after the elaborator so a propagated Err/None short-circuit is not
  // forced through the success-shaped `ensures:` rewrite.
  val propRes = lowerPropagateFile(elaborated)
  if reportAndAbort(propRes.diagnostics) {
    return false
  }

  // Synthesise @derive / @generate(Json) methods (Band 5 — docs/41 §9 #857).
  val derived = deriveFile(propRes.file)

  // Monomorphise same-package generic calls (Band 5 — docs/41 §9), feeding
  // the stdlib's pure-Lyric generic `pub func`s as imported generics so calls
  // like `mapGet(m, "k")` specialise into a concrete copy in this bundle
  // rather than erasing their generic return to `object` (#1727).
  val stdlibGenFuncs = collectStdlibGenericFuncs(stdlibPkgs)
  val monoRes = monoFileWithImports(derived, stdlibGenFuncs)
  if reportAndAbort(monoRes.diagnostics) {
    return false
  }
  val file = monoRes.file

  // Reconstruct the package name as a dotted string (e.g. "Hello" or
  // "My.Package") from the parsed path segments.
  val pkgName = segmentsToString(file.packageDecl.path.segments)

  // Build the codegen context — seeds a fresh LoweringCtx with all standard
  // library AssemblyRef / TypeRef / MemberRef rows.  Single-package
  // compile path: no restored artifacts.  `packageVersion` is parsed for
  // the Assembly row; empty string → `0.0.0.0` (legacy default).
  val emptyArtifacts: List[SynthesisedArtifact] = newList()
  val verParts = parseSemverMajorMinor(packageVersion)
  val cctx = newCodegenCtx(pkgName, emptyArtifacts, verParts[0], verParts[1])
  // Allocate cross-assembly MemberRef rows for every stdlib `pub func`
  // so that user code calling `Std.X.foo(...)` emits a real
  // `call <memberref>` instead of falling through to the `MObject`
  // arm in `lowerBuiltinOrStaticCallMsil`.  See the matching wire-up
  // in `compileProjectToMsilWithRestoredAndVersion` for the full
  // rationale (mirrors the F# emitter's `resolveStdlibImports` +
  // `emitAssembly` import-table population).
  registerStdlibArtifactTokens(cctx, stdlibPkgs)

  // Run the aspect weaver before the token pre-scan so that the pre-scan
  // sees the post-weave function list (renamed originals + synthesised wrappers).
  // Use `Lyric.Weaver.weaveFileWithDiags` (not `weaveAspectsMsil`) so the
  // todo/06 features — `config { }` wiring (#683), `call` ambient prelude
  // (#682), `@inline_template` `args.<field>` rewriting (#681) — are
  // applied during `lyric build`, not just `lyric prove` (#1327).  Abort
  // on any weave-time error (A0042 / A0043 / A0044) so the user sees the
  // weaver-targeted message rather than a downstream codegen error.
  val weaveRes = Weaver.weaveFileWithDiags(file)
  if reportAndAbort(weaveRes.diagnostics) {
    return false
  }
  val weavedFile = weaveRes.file

  // Lambda-lifting: extract ELambda nodes into synthetic __lambda_<i> IFunc items
  // so that addPackageTokens assigns them stable MethodDef tokens before codegen.
  val liftedFile = liftLambdasMsil(weavedFile)

  // Pre-scan the AST to assign deterministic MethodDef / FieldDef tokens for
  // same-package types and functions.
  addPackageTokens(cctx, liftedFile, pkgName)

  // Walk the AST and produce the MSIL package IR.
  val pkg = codegenMPackage(liftedFile, cctx)

  // Determine the entry-point MethodDef token (0 = no entry point / library).
  val entryToken = resolveEntryToken(cctx)

  // Embed the package's Lyric.Contract resource (parsed-by-the-loader
  // JSON describing this assembly's public surface) so downstream
  // restored-dep consumers see the contract via the in-process loader.
  // Empty `packageVersion` falls back to "0.0.0" so ad-hoc compiles
  // without a manifest behave like the legacy path; callers threading
  // a manifest version (#1364) pass the declared semver verbatim and
  // it ends up in the embedded contract.
  val resourceVersion = if packageVersion.length == 0 { "0.0.0" } else { packageVersion }
  embedLyricContract(cctx.lctx, liftedFile, "Lyric.Contract", resourceVersion)

  // Lower the package IR to raw PE bytes using the pre-seeded context.
  val bytes = lowerMPackageWithCtx(pkg, cctx.lctx, entryToken)

  // Write the PE to disk.
  val result = writeBytes(outputPath, bytes)
  match result {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

/// One package's per-source-file payload for `compileProjectToMsil`.
/// `name` is the dotted package name (e.g. "Bug1140.Producer") and `source`
/// is the combined source text for that package — multi-file packages should
/// already be merged into a single string by the caller.
pub record ProjectPackagePayload {
  name: String
  source: String
}

/// Intermediate carrier used by `compileProjectToMsilWithRestoredAndVersion`'s
/// pre-parse pass.  Holds the post-parse + cfg-erase + alias-rewrite
/// `SourceFile` alongside the dotted package name so the second-pass
/// typecheck loop can index the bundle and build per-package imported-item
/// lists without re-parsing.
record ParsedUserPkg {
  name: String
  file: SourceFile
}

/// Compile a list of packages into ONE bundled .NET PE DLL using the
/// self-hosted MSIL pipeline (#1183, Phase 1 — independent-package bundle).
///
/// Runs the per-package middle-end pipeline (parse → typecheck → modecheck →
/// elaborate → derive → mono → weave → lambda-lift) for every package in
/// `packages` order, accumulates each package's pre-scan tokens into the
/// shared `CodegenCtx`, then lowers every `MPackage` against a single shared
/// `LoweringCtx` and writes one PE.  The bundled assembly is named after
/// `assemblyName` (matching the F# `Emitter.emitProject` convention).
///
/// Returns true on success; false on any parse / mode error, codegen error,
/// or file write failure.  All diagnostics from each pass are printed via
/// `Lyric.DiagnosticUtil` before the bridge returns.
///
/// Phase 1 scope: independent packages only.  Cross-package imports (one
/// package importing another in the same bundle) are deferred to Phase 2 —
/// the call-site resolver in `codegen.l` still treats unknown names as
/// fallback `MObject` calls when the imported package's tokens aren't in
/// `cctx.funcTokens`.  This entry point already gives `Lyric.Emitter.emitProject`
/// a path to bundle multiple independent packages without subprocess-hopping
/// through the F# emitter.
pub func compileProjectToMsil(
  packages: in List[ProjectPackagePayload],
  assemblyName: in String,
  outputPath: in String,
  stdlibSources: in List[String],
): Bool {
  // Backward-compat shim: no feature flags, no restored artifacts.
  val noFeatures: List[String] = newList()
  val noArtifacts: List[SynthesisedArtifact] = newList()
  compileProjectToMsilWithRestored(
    packages,
    assemblyName,
    outputPath,
    stdlibSources,
    noFeatures,
    noFeatures,
    noArtifacts
  )
}

/// Like `compileProjectToMsil` but threads `activeFeatures` /
/// `declaredFeatures` through `Lyric.Cfg.applyCfgErasure` before
/// typecheck.  Items annotated `@cfg(feature = "X")` where `X` is
/// absent from `activeFeatures` are erased; items whose annotation
/// references a feature absent from `declaredFeatures` (when the
/// declared set is non-empty) raise an `F0013` typo warning.
///
/// Mirrors the Phase 4 cfg-erasure path the F# `--internal-project-build`
/// subprocess already implements via `Lyric.Emitter.Cfg.applyCfgErasure`.
/// Tracked in #1183 as the prerequisite that lets `Lyric.Emitter.emitProject`
/// route feature-bearing requests through the in-process bridge instead of
/// the subprocess fallback.
pub func compileProjectToMsilWithFeatures(
  packages: in List[ProjectPackagePayload],
  assemblyName: in String,
  outputPath: in String,
  stdlibSources: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
): Bool {
  // Forwarder: no restored artifacts.  Callers that need them use
  // `compileProjectToMsilWithRestored` directly.
  val noArtifacts: List[SynthesisedArtifact] = newList()
  compileProjectToMsilWithRestored(
    packages,
    assemblyName,
    outputPath,
    stdlibSources,
    activeFeatures,
    declaredFeatures,
    noArtifacts
  )
}

/// Like `compileProjectToMsilWithFeatures` but accepts a list of
/// `Lyric.RestoredPackages.SynthesisedArtifact`s for the consumer's
/// restored dependencies and seeds them into `CodegenCtx.restoredArtifacts`.
pub func compileProjectToMsilWithRestored(
  packages: in List[ProjectPackagePayload],
  assemblyName: in String,
  outputPath: in String,
  stdlibSources: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  restoredArtifacts: in List[SynthesisedArtifact],
): Bool {
  // Forwarder to the version-threading variant with an empty version
  // (legacy `0.0.0.0` Assembly row).
  compileProjectToMsilWithRestoredAndVersion(
    packages,
    assemblyName,
    outputPath,
    stdlibSources,
    activeFeatures,
    declaredFeatures,
    restoredArtifacts,
    ""
  )
}

/// Like `compileProjectToMsilWithRestored` but accepts a `[package].version`
/// string used for the bundled Assembly row and the embedded
/// `Lyric.Contract.<pkg>` resources.  Empty string → legacy `"0.0.0"`
/// default (see #1364 for the threading plan).
pub func compileProjectToMsilWithRestoredAndVersion(
  packages: in List[ProjectPackagePayload],
  assemblyName: in String,
  outputPath: in String,
  stdlibSources: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  restoredArtifacts: in List[SynthesisedArtifact],
  packageVersion: in String,
): Bool {
  if packages.count == 0 {
    return false
  }

  // Phase 0: build the BASE imported-items list — items that every
  // user package can reference unconditionally.  Stdlib and restored-
  // dependency artifacts go here.  Per-package import filtering
  // (#1378's architectural recommendation) only applies to in-bundle
  // user packages: stdlib types like `List` / `Map` and restored
  // record / function references are always in scope because the
  // codegen-side AssemblyRef / TypeRef / MemberRef rows for them are
  // unconditionally seeded into the codegen context.
  //
  // `collectStdlibPackages` walks the same `stdlibSources` list that
  // `collectStdlibTypeItems` does but ALSO returns the items grouped
  // by their declaring package (`Std.Core`, `Std.Encoding`, …).  The
  // codegen-side `registerStdlibArtifactTokens` consumes that group
  // map to allocate cross-assembly MemberRef rows for every
  // user-callable stdlib `pub func`, so `tryDecodeBase64(...)` etc.
  // emit a real `call <memberref>` instruction instead of the
  // `MObject` fall-through that produced `InvalidProgramException`
  // at runtime.
  val stdlibPkgs = collectStdlibPackages(stdlibSources)
  // Always-in-scope items (stdlib + restored-dep types), grouped by declaring
  // package for scope-aware resolution.  Per-package import filtering (#1378)
  // applies only to in-bundle user packages below; stdlib / restored-dep refs
  // are wired via the codegen-side token tables, kept in sync with this view.
  val baseImportedPkgs: List[ImportedPackage] = newList()
  var sbi = 0
  while sbi < stdlibPkgs.count {
    baseImportedPkgs.add(ImportedPackage(name = stdlibPkgs[sbi].name, items = stdlibPkgs[sbi].items))
    sbi = sbi + 1
  }
  var ri0 = 0
  while ri0 < restoredArtifacts.count {
    val rItems: List[Item] = newList()
    collectTypeItemsFromFile(restoredArtifacts[ri0].source, rItems)
    baseImportedPkgs.add(
      ImportedPackage(name = segmentsToString(restoredArtifacts[ri0].source.packageDecl.path.segments), items = rItems)
    )
    ri0 = ri0 + 1
  }

  // Phase 1a: parse + cfg-erase + alias-rewrite every user package
  // up front so we can build a per-package items map before any
  // typecheck runs.  Doing this in a separate pass over a fresh pass
  // over the input means each user package's typecheck only sees
  // items from packages it actually `import`s (transitively), instead
  // of every earlier-in-the-list package's items.  See #1378's
  // "per-package symbol tables" recommendation; the old flat
  // accumulation was a known gap tracked as #1195.
  val parsedPkgs: List[ParsedUserPkg] = newList()
  var pi = 0
  while pi < packages.count {
    val pkg = packages[pi]
    val parseResult = parse(pkg.source)
    if reportAndAbort(parseResult.diagnostics) {
      return false
    }
    val cfgRes = Cfg.applyCfgErasure(activeFeatures, declaredFeatures, parseResult.file)
    if reportAndAbort(cfgRes.diagnostics) {
      return false
    }
    val file0 = Stubbable.stubbableRewriteFile(Aliases.rewriteFile(cfgRes.file))
    parsedPkgs.add(ParsedUserPkg(name = pkg.name, file = file0))
    pi = pi + 1
  }

  // Phase 1b: index each in-bundle package by name so the per-package
  // import filter can look its items up by `import <pkgName>` segment.
  // Item lists are extracted via `collectTypeItemsFromFile` (matches
  // the historical flat-accumulation semantics: `pub func`s + every
  // type-shaped item).
  val inBundleItems: Map[String, List[Item]] = newMap()
  val inBundleImports: Map[String, List[ImportDecl]] = newMap()
  var bi = 0
  while bi < parsedPkgs.count {
    val pp: ParsedUserPkg = parsedPkgs[bi]
    val items: List[Item] = newList()
    collectTypeItemsFromFile(pp.file, items)
    inBundleItems.add(pp.name, items)
    inBundleImports.add(pp.name, pp.file.imports)
    bi = bi + 1
  }

  // Phase 2: typecheck + mode-check + elaborate + derive + mono per
  // package, using a per-package grouped imports view filtered by the
  // package's declared imports.
  //
  // Build a set of stdlib package names so `perPackageImportedPackages` can
  // skip adding in-bundle items for packages that are already fully
  // represented in `baseImportedPkgs`.  Without this guard, a stdlib self-build
  // (where `packages` and `stdlibSources` contain the same files) would
  // register every Std.* type twice with distinct TypeIds, corrupting the
  // type-variable resolution for subsequent packages and causing spurious
  // T0033 diagnostics on `var i = 0; while i < n { … }` loops.  (#1435)
  val baseNames: Map[String, Bool] = newMap()
  var bn = 0
  while bn < stdlibPkgs.count {
    if not baseNames.containsKey(stdlibPkgs[bn].name) {
      baseNames.add(stdlibPkgs[bn].name, true)
    }
    bn = bn + 1
  }
  // Stdlib pure-Lyric generic `pub func`s, fed to each package's monomorphizer
  // so cross-assembly generic calls (`mapGet`, `unwrapOr`, …) specialise into
  // the consumer bundle instead of erasing their return to `object` (#1727).
  val stdlibGenFuncs = collectStdlibGenericFuncs(stdlibPkgs)
  // In-bundle user package generic pub funcs: same treatment so a test package
  // calling `Validation.toResult(42, [])` specialises `toResult__Int` into its
  // own class rather than hitting the unresolved-call fallback (#2932).
  val inBundleGenFuncs = collectInBundleGenericFuncs(parsedPkgs)
  val allImportedGenFuncs: List[FunctionDecl] = newList()
  var agfi = 0
  while agfi < stdlibGenFuncs.count {
    allImportedGenFuncs.add(stdlibGenFuncs[agfi])
    agfi = agfi + 1
  }
  var agfj = 0
  while agfj < inBundleGenFuncs.count {
    allImportedGenFuncs.add(inBundleGenFuncs[agfj])
    agfj = agfj + 1
  }
  val perPkgFiles: List[SourceFile] = newList()
  val perPkgNames: List[String] = newList()
  var ti = 0
  while ti < parsedPkgs.count {
    val pp: ParsedUserPkg = parsedPkgs[ti]
    val importedPkgs = perPackageImportedPackages(
      baseImportedPkgs,
      pp.file.imports,
      inBundleItems,
      inBundleImports,
      baseNames
    )

    val tcRes = checkWithImportedPackages(pp.file, importedPkgs)
    if reportAndAbortInPkg(pp.name, tcRes.diagnostics) {
      return false
    }

    val mcRes = checkFile(pp.file)
    if reportAndAbortInPkg(pp.name, mcRes.diagnostics) {
      return false
    }

    val elaborated = elaborateFile(pp.file)

    // Lower `?` error-propagation (#1475); see the single-file path above.
    val propRes = lowerPropagateFile(elaborated)
    if reportAndAbortInPkg(pp.name, propRes.diagnostics) {
      return false
    }

    val derived = deriveFile(propRes.file)

    val monoRes = monoFileWithImports(derived, allImportedGenFuncs)
    if reportAndAbortInPkg(pp.name, monoRes.diagnostics) {
      return false
    }

    perPkgFiles.add(monoRes.file)
    perPkgNames.add(pp.name)

    ti = ti + 1
  }

  // Phase 3: weave + lambda-lift + token pre-scan for every package against
  // ONE shared cctx — the persistent `nextMethodDefRow` / `nextFieldDefRow`
  // counters in `CodegenCtx` thread row numbering across calls.  The cctx's
  // Assembly row is named after the bundle, not any individual package.
  // `packageVersion` populates the Assembly row's major/minor; empty
  // falls back to 0.0.0.0.
  val pvParts = parseSemverMajorMinor(packageVersion)
  val cctx = newCodegenCtx(assemblyName, restoredArtifacts, pvParts[0], pvParts[1])
  // Allocate cross-assembly AssemblyRef / TypeRef / MemberRef rows for
  // every `pub func` declared in the stdlib so that user code which
  // calls `Std.X.foo(...)` (e.g. `Std.Encoding.tryDecodeBase64`)
  // emits a real `call <memberref>` instruction instead of falling
  // through to the `MObject` arm in `lowerBuiltinOrStaticCallMsil`
  // (which previously produced an unbalanced operand stack and an
  // `InvalidProgramException` at runtime).  Mirrors the F# emitter's
  // `resolveStdlibImports` + `emitAssembly` import-table population.
  //
  // Runs BEFORE restored-artifact registration so the stdlib type
  // surface (`Std.Core.Result`, `Std.Core.Option`, …) is in
  // `ffiTypeRefs` / `typeFqnByName` when a restored artifact's member
  // signatures reference it.  A restored interface method returning
  // `Result[T, E]` would otherwise resolve the return type to `MObject`
  // (TypeRef miss), so the consumer's `match` on the call result saw a
  // bare `object` scrutinee and panicked "match not exhaustive" (#1602).
  // Stdlib registration is self-contained — it never references a
  // restored type — so this reorder is safe.
  //
  // Filter `stdlibPkgs` to exclude any package whose name matches an
  // in-bundle user package — otherwise registering MemberRefs for
  // `Std.Encoding` when COMPILING `Std.Encoding` itself (as happens
  // during stdlib bundle precompile) would clash with the
  // `addPackageTokens` MethodDef registration that follows.  In
  // practice the bridge today never sees the stdlib being compiled
  // (the F# emitter handles that), but the guard makes the bridge
  // robust to a future refactor that routes stdlib compilation
  // through the in-process path.
  registerStdlibArtifactTokens(cctx, filterStdlibPkgsByBundle(stdlibPkgs, perPkgNames))
  // Seed cross-package symbol tables with the restored artifacts' type
  // surface so the per-package addPackageTokens pre-scan sees restored
  // types as first-class lookups.
  registerRestoredArtifactTokens(cctx)

  // Pre-register all in-bundle user-type names in typeFqnByName so that
  // cross-package type references in specialised functions resolve correctly
  // regardless of package processing order.  `cmdTestManifest` in cli.l
  // places the test package FIRST in allPkgs (so its synthesised main() wins
  // the entry-point slot), which means addPackageTokens for the test package
  // runs before addPackageTokens for the library packages.  Any specialised
  // function placed in the test package (e.g. toResult__Int synthesised from
  // Validation.toResult[T]) carries unqualified type refs (e.g. TRef
  // ["ValidationError"]) whose FQN must be resolved via typeFqnByName.
  // Without this pre-pass the lookup falls back to pkgName + "." + seg,
  // producing the wrong FQN (e.g. Validation.ValidationTests.ValidationError)
  // and a "match not exhaustive" panic at run time (#2932).
  var prtpi = 0
  while prtpi < perPkgFiles.count {
    val prtFile = perPkgFiles[prtpi]
    val prtPkg = perPkgNames[prtpi]
    var prtii = 0
    while prtii < prtFile.items.count {
      match prtFile.items[prtii].kind {
        case IRecord(decl) -> {
          if not cctx.typeFqnByName.containsKey(decl.name) {
            cctx.typeFqnByName.add(decl.name, prtPkg + "." + decl.name)
          }
        }
        case IExposedRec(decl) -> {
          if not cctx.typeFqnByName.containsKey(decl.name) {
            cctx.typeFqnByName.add(decl.name, prtPkg + "." + decl.name)
          }
        }
        case IUnion(decl) -> {
          if not cctx.typeFqnByName.containsKey(decl.name) {
            cctx.typeFqnByName.add(decl.name, prtPkg + "." + decl.name)
          }
        }
        case IEnum(decl) -> {
          if not cctx.typeFqnByName.containsKey(decl.name) {
            cctx.typeFqnByName.add(decl.name, prtPkg + "." + decl.name)
          }
        }
        case IInterface(decl) -> {
          if not cctx.typeFqnByName.containsKey(decl.name) {
            cctx.typeFqnByName.add(decl.name, prtPkg + "." + decl.name)
          }
        }
        case IOpaque(decl) -> {
          if not cctx.typeFqnByName.containsKey(decl.name) {
            cctx.typeFqnByName.add(decl.name, prtPkg + "." + decl.name)
          }
        }
        case IDistinctType(decl) -> {
          if not cctx.typeFqnByName.containsKey(decl.name) {
            cctx.typeFqnByName.add(decl.name, prtPkg + "." + decl.name)
          }
        }
        case _ -> ()
      }
      prtii = prtii + 1
    }
    prtpi = prtpi + 1
  }

  val liftedFiles: List[SourceFile] = newList()
  var li = 0
  while li < perPkgFiles.count {
    // Use `Lyric.Weaver.weaveFileWithDiags` so the todo/06 features
    // (config wiring #683, call prelude #682, `@inline_template`
    // args.<field> #681) ship through `lyric build` for every
    // package in the bundle, not just `lyric prove` (#1327).  Abort
    // on weave-time errors (A0042 / A0043 / A0044).
    val weaveRes = Weaver.weaveFileWithDiags(perPkgFiles[li])
    if reportAndAbort(weaveRes.diagnostics) {
      return false
    }
    val weaved = weaveRes.file
    val lifted = liftLambdasMsil(weaved)
    addPackageTokens(cctx, lifted, perPkgNames[li])
    // Project-as-DLL embedding: each package's contract goes in its
    // own `Lyric.Contract.<Pkg>` resource so the in-process loader can
    // surface them per-package (matching the F# bundled-DLL layout).
    // `packageVersion` carries the manifest's `[package].version` for
    // the bundle; per-package versioning is out of scope for #1364 and
    // tracked separately.
    val bundleVer = if packageVersion.length == 0 { "0.0.0" } else { packageVersion }
    embedLyricContract(cctx.lctx, lifted, "Lyric.Contract." + perPkgNames[li], bundleVer)
    liftedFiles.add(lifted)
    li = li + 1
  }

  // Phase 4: codegen each package into an MPackage against the same cctx.
  val mpkgs: List[MPackage] = newList()
  var ci = 0
  while ci < liftedFiles.count {
    val mpkg = codegenMPackage(liftedFiles[ci], cctx)
    mpkgs.add(mpkg)
    ci = ci + 1
  }

  // Phase 5: pick an entry point.  When any package defined a `main` function
  // the pre-scan stored its MethodDef token on `cctx.funcTokens` under the
  // simple name "main"; otherwise the bundle is a library (token 0).
  val entryToken = resolveEntryToken(cctx)

  // Phase 6: lower all MPackages into a single PE against the shared lctx.
  val bytes = lowerMPackagesWithCtx(mpkgs, cctx.lctx, entryToken)

  val result = writeBytes(outputPath, bytes)
  match result {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

/// Tab-encoded variant of `compileProjectToMsil` for reflection-based
/// callers (the F# bootstrap test shim in
/// `bootstrap/src/Lyric.Cli/SelfHostedMsilProject.fs`).  Each entry in
/// `specLines` is `<packageName> TAB <packageSource>`; the leading segment
/// is the dotted package name and everything after the first tab is the
/// combined source text.  Delegates to `compileProjectToMsil` once parsed.
///
/// Using a `List[String]` payload avoids cross-language reflection on the
/// Lyric-emitted `ProjectPackagePayload` record from F# — only strings need
/// to cross the boundary.
pub func compileProjectToMsilEncoded(
  specLines: in List[String],
  assemblyName: in String,
  outputPath: in String,
  stdlibSources: in List[String],
): Bool {
  val packages: List[ProjectPackagePayload] = newList()
  var i = 0
  while i < specLines.count {
    val line = specLines[i]
    val tabPos = line.indexOf("\t")
    if tabPos < 0 {
      return false
    }
    val name = line.substring(0, tabPos)
    val src = line.substring(tabPos + 1)
    packages.add(ProjectPackagePayload(name = name, source = src))
    i = i + 1
  }
  compileProjectToMsil(packages, assemblyName, outputPath, stdlibSources)
}

/// Reflection-friendly variant of `compileProjectToMsilWithRestored`.
/// Mirrors `compileProjectToMsilEncoded` (tab-encoded `<pkgName> TAB
/// <pkgSource>` rows for the bundle's source packages) but adds a
/// `restoredDllPaths` list — each entry is the absolute path to a DLL
/// the consumer treats as a restored Lyric package.
///
/// The bridge loads each DLL via `Lyric.RestoredPackages.loadRestoredPackage`
/// and synthesises a parsed-and-typechecked `SynthesisedArtifact` so the
/// downstream codegen can resolve cross-assembly references without
/// touching the F# `--internal-project-build` subprocess fallback.
/// Returns false if any restored DLL fails to load or synthesise.
///
/// Used by `bootstrap/src/Lyric.Cli/SelfHostedMsilProject.fs` to drive
/// the slice-3 E2E test that demonstrates the in-process bridge produces
/// linkable artifacts.
pub func compileProjectToMsilWithRestoredEncoded(
  specLines: in List[String],
  assemblyName: in String,
  outputPath: in String,
  stdlibSources: in List[String],
  restoredDllPaths: in List[String],
  packageVersion: in String,
): Bool {
  val packages: List[ProjectPackagePayload] = newList()
  var i = 0
  while i < specLines.count {
    val line = specLines[i]
    val tabPos = line.indexOf("\t")
    if tabPos < 0 {
      return false
    }
    val name = line.substring(0, tabPos)
    val src = line.substring(tabPos + 1)
    packages.add(ProjectPackagePayload(name = name, source = src))
    i = i + 1
  }

  // Load + synthesise each restored DLL into a `SynthesisedArtifact`.
  // Mirrors the loop in `lyric-compiler/lyric/emitter.l::emitProjectInProcess`
  // so the F# shim's behaviour matches the production CLI path.
  val restoredArtifacts: List[SynthesisedArtifact] = newList()
  var ri = 0
  while ri < restoredDllPaths.count {
    val dllPath = restoredDllPaths[ri]
    match loadRestoredPackage(dllPath) {
      case Err(_) -> return false
      case Ok(arts) -> {
        var ai = 0
        while ai < arts.count {
          // Fresh preamble per call so an intended-read-only mutation
          // by `synthesiseArtifact` can't leak across iterations.
          val preamble: List[Meta.ContractDecl] = newList()
          match synthesiseArtifact(arts[ai], preamble) {
            case Err(_) -> return false
            case Ok(syn) -> restoredArtifacts.add(syn)
          }
          ai = ai + 1
        }
      }
    }
    ri = ri + 1
  }

  val activeFeatures: List[String] = newList()
  val declaredFeatures: List[String] = newList()
  compileProjectToMsilWithRestoredAndVersion(
    packages,
    assemblyName,
    outputPath,
    stdlibSources,
    activeFeatures,
    declaredFeatures,
    restoredArtifacts,
    packageVersion
  )
}

// Build the typecheck's per-package `importedItems` list (#1378's
// per-package symbol-table recommendation).  The result is the
// concatenation of:
//
//   1. `baseItems`   — every stdlib + restored-dep item, always in
//                      scope.
//   2. For each `import <pkg>` declaration that targets an in-bundle
//      package: that package's items, walked transitively (so
//      `import A` reaches B when `A` itself imports `B`).
//
// In-bundle packages are looked up by dotted package name (the
// `ProjectPackagePayload.name` of each input package).  Imports that
// don't match an in-bundle key (stdlib, restored, builtin, or simply
// unknown) fall through silently — they're either already in
// `baseItems` or were never an in-bundle reference to begin with.
//
// Concrete impact: a user package that doesn't `import` a sibling
// package no longer sees its types/funcs at typecheck, surfacing the
// missing-import error at T0010 / T0020 (where it's actionable)
// instead of letting it slip to codegen's `MObject` fall-through
// (which was the long-standing #1195 leak).
// `baseNames` is the set of package names whose items are already fully
// represented in `baseItems` (i.e., the stdlib packages collected by
// `collectStdlibPackages`).  Any in-bundle package whose name appears in
// `baseNames` is skipped: its items are already in `baseItems`, and adding
// them again via the in-bundle closure would register every type twice,
// allocating a second distinct `TypeId` for each type.  The second
// TypeId is never used by the codegen (`symTableTryFindOne` scans newest-to-oldest
// and resolves the last-registered TypeId) but the duplicate `DKUnion`/`DKRecord`/...
// symbols inflate the symbol table.  More critically, duplicate union-case
// symbols (`Some`, `None`, `Ok`, `Err`) push extra `DKUnionCase` entries
// whose `parentId` refers to the *second* (unused) TypeId; when the type
// checker resolves a generic type variable for a subsequently analysed
// function body it can end up with a stale `TyVar("")` binding instead of
// the expected `TyPrim(PtInt)`, producing spurious T0033 diagnostics on
// perfectly valid `var i = 0; while i < n { … }` loops.  (#1435)
// Grouped analogue of the old flat `perPackageImportedItems`: returns the
// imported items partitioned by their declaring package, so the scope-aware
// type checker resolves each package's signatures against its own
// declarations instead of one flat last-registered-wins table.
// `baseImportedPkgs` (stdlib + restored deps) are always in scope; the
// in-bundle import closure rooted at `importList` is appended, one
// `ImportedPackage` per reachable in-bundle package.
func perPackageImportedPackages(
  baseImportedPkgs: in List[ImportedPackage],
  importList: in List[ImportDecl],
  inBundleItems: in Map[String, List[Item]],
  inBundleImports: in Map[String, List[ImportDecl]],
  baseNames: in Map[String, Bool],
): List[ImportedPackage] {
  val result: List[ImportedPackage] = newList()
  var bi = 0
  while bi < baseImportedPkgs.count {
    result.add(baseImportedPkgs[bi])
    bi = bi + 1
  }
  val visited: Map[String, Bool] = newMap()
  var ii = 0
  while ii < importList.count {
    val imp: ImportDecl = importList[ii]
    val depName = segmentsToString(imp.path.segments)
    addBundleClosurePackages(depName, inBundleItems, inBundleImports, visited, baseNames, result)
    ii = ii + 1
  }
  result
}

// Walk the transitive in-bundle import closure rooted at `pkgName`, appending
// each reachable in-bundle package as its own `ImportedPackage` to `acc`.
// Visited packages are tracked to avoid infinite loops on cyclic imports
// (which the typechecker / module system already rejects, but this helper
// stays defensive in case a future relaxation lands).  `baseNames` packages
// are skipped because their items are already in `baseImportedPkgs`.
func addBundleClosurePackages(
  pkgName: in String,
  inBundleItems: in Map[String, List[Item]],
  inBundleImports: in Map[String, List[ImportDecl]],
  visited: in Map[String, Bool],
  baseNames: in Map[String, Bool],
  acc: in List[ImportedPackage],
): Unit {
  if visited.containsKey(pkgName) {
    return
  }
  if baseNames.containsKey(pkgName) {
    return
  }
  visited.add(pkgName, true)
  match mapGet(inBundleItems, pkgName) {
    case Some(items) -> acc.add(ImportedPackage(name = pkgName, items = items))
    case None -> return
  }
  match mapGet(inBundleImports, pkgName) {
    case Some(deps) -> {
      var ii = 0
      while ii < deps.count {
        val sub = segmentsToString(deps[ii].path.segments)
        addBundleClosurePackages(sub, inBundleItems, inBundleImports, visited, baseNames, acc)
        ii = ii + 1
      }
    }
    case None -> ()
  }
}

// Append every type-shaped and function-shaped item from `file` to
// `importedItems`.  Used by `compileProjectToMsil` to thread each in-bundle
// package's types AND public functions forward to subsequent packages'
// typechecks (#1183 Phase 2).
//
// Note: the parallel `collectStdlibTypeItems` deliberately excludes IFunc
// because the stdlib has multiple definitions of the same simple name
// (e.g. `toString`) across files; in-bundle packages here are user
// packages where the same risk applies — we include `pub`-visible
// functions only, matching the F# emitter's intra-project import policy.
func collectTypeItemsFromFile(file: in SourceFile, importedItems: in List[Item]): Unit {
  var i = 0
  while i < file.items.count {
    val it = file.items[i]
    val isType = match it.kind {
      case IRecord(_) -> true
      case IExposedRec(_) -> true
      case IUnion(_) -> true
      case IEnum(_) -> true
      case IDistinctType(_) -> true
      case IInterface(_) -> true
      case ITypeAlias(_) -> true
      case IOpaque(_) -> true
      // Mirror `collectStdlibTypeItems`: an in-bundle package's `extern type`
      // and `protected type` declarations must reach packages that import it,
      // so a transitively-loaded compiler package (e.g. `Jvm.Classfile`
      // referencing `Jvm.Kernel`'s `extern type Pool`) resolves the bare type
      // name instead of aborting with T0010 (#1488 compiler-internal closure).
      // Safe now that extern types dedup to a canonical `TypeId` (#2394).
      case IExternType(_) -> true
      case IProtected(_) -> true
      case _ -> false
    }
    val isPubFunc = match it.kind {
      case IFunc(decl) -> match decl.visibility { case Some(vis) -> match vis { case VisPub(_) -> true; case _ -> false }; case None -> false }
      case _ -> false
    }
    // Module-level `pub val`s (#2195) — e.g. `Jvm.Classfile`'s `pub val
    // ACC_PUBLIC: Int = …` access-flag constants — must reach packages that
    // import them, or a cross-package reference aborts with T0020.
    val isPubVal = match it.kind {
      case IVal(_) -> match it.visibility { case Some(vis) -> match vis { case VisPub(_) -> true; case _ -> false }; case None -> false }
      case _ -> false
    }
    if isType or isPubFunc or isPubVal {
      importedItems.add(it)
    }
    i = i + 1
  }
}

// Helper: parse `stdlibSources`, extract every type-shaped item, and
// append it to `importedItems`.  Both single-package and multi-package
// compile paths share this rule so the user's typecheck sees the same
// view of the stdlib regardless of project shape.
//
// The filter set now includes `IExternType` and `IProtected` so that
// `_kernel/` declarations like
// `extern type List[T] = "System.Collections.Generic.List`1"`,
// `extern type Map[K, V] = "...Dictionary`2"`, `extern type Random`,
// `pub protected type Scope`, etc. reach the typechecker's symbol
// table.  Without these, any user signature that references those bare
// names (`pub func sumList(xs: in List[Int]): Int`) aborts the
// multi-package build with T0010 / T0014.  The `findStdlibSources`
// loader on both the Lyric and F# shim sides now reads
// `_kernel/*.l` so the items are even visible to be collected.
//
// `IFunc` items remain out of scope (#1378 follow-up): user code that
// calls a stdlib `pub func` by bare name (`tryDecodeBase64(...)` after
// `import Std.Encoding`) still aborts the multi-package typecheck with
// `T0020 unknown name '<fn>'`.  Including IFunc here gets the typecheck
// past T0020 but the bridge's codegen does not yet allocate cross-
// assembly `MemberRef`s for arbitrary stdlib functions — only the
// hardcoded set in `lowerBuiltinOrStaticCallMsil` (`newList`, `newMap`,
// `mapGet`, `println`, `toString`, …) gets a real `call` instruction.
// Everything else falls through to the `MObject` arm in
// `lowerCallMsil`, which walks the args for side effects but emits no
// call — producing an unbalanced operand stack and an
// `InvalidProgramException` at runtime.  Letting typecheck pass while
// codegen silently emits broken IL would be a worse failure mode than
// today's clean T0020.  Two follow-ups close that gap:
//
//   1. Promote the stdlib `IFunc` collection here (and on the user-
//      side per-package import filter recommended in #1378).
//   2. Extend the codegen pre-scan (`addPackageTokens` /
//      `registerRestoredArtifactTokens`) to register `MemberRef` rows
//      for every imported stdlib `pub func`, mirroring the F# emitter's
//      `resolveStdlibImports` + `emitAssembly` import-table population.
//
// Parse errors stay advisory (printed, not fatal) for the same reason
// the original loop documented (#914): the self-hosted parser still has
// known gaps vs. the stdlib source tree (e.g. `try { ... } catch Bug
// as _ { ... }` in `_kernel/http_server.l`).  Aborting here would block
// every user build until the parser reaches stdlib parity.  Items from
// a file whose parse failed are dropped so that partial / malformed
// items don't pollute downstream passes.
func collectStdlibTypeItems(stdlibSources: in List[String], importedItems: in List[Item]): Unit {
  var si = 0
  while si < stdlibSources.count {
    val stdPr = parse(stdlibSources[si])
    reportDiagnostics(stdPr.diagnostics)
    if hasParseError(stdPr.diagnostics) {
      si = si + 1
      continue
    }
    var ii = 0
    while ii < stdPr.file.items.count {
      val it = stdPr.file.items[ii]
      // Include types AND functions so user code can resolve calls
      // into stdlib (e.g. `println` from `Std.Console`).  Multi-file
      // duplicate function names (`toString` lives in several stdlib
      // packages) are handled by `addSigsFromItems`'s first-wins
      // `containsKey` check rather than blowing up `Dictionary.Add`.
      val include = match it.kind {
        case IRecord(_) -> true
        case IExposedRec(_) -> true
        case IUnion(_) -> true
        case IEnum(_) -> true
        case IDistinctType(_) -> true
        case IInterface(_) -> true
        case ITypeAlias(_) -> true
        case IOpaque(_) -> true
        case IProtected(_) -> true
        case IExternType(_) -> true
        case IFunc(_) -> true
        case _ -> false
      }
      if include {
        importedItems.add(it)
      }
      ii = ii + 1
    }
    si = si + 1
  }
}

// Return true if `diags` contains any error-severity entry.  Used to
// short-circuit item collection from a stdlib source whose parse
// produced errors — see the rationale at `collectStdlibTypeItems`.
func hasParseError(diags: in List[Diagnostic]): Bool {
  var i = 0
  while i < diags.count {
    match diags[i].severity {
      case DiagError -> return true
      case _ -> {
      }
    }
    i = i + 1
  }
  false
}

// `StdlibPkg` record is defined in `Msil.Codegen` so the codegen-side
// `registerStdlibArtifactTokens` can consume it without a circular
// import.  Imported into this package via `Msil.Codegen`.
// Walk every `stdlibSources` entry, parse it, and group the included
// items by the source's `package` declaration.  Items are filtered to
// the same set `collectStdlibTypeItems` accepts (types + `pub func`s
// + extern types + protected types) so the per-package map is a strict
// subset of the flat `baseItems` view.
//
// Parse-error files are dropped wholesale (matching the
// `collectStdlibTypeItems` convention) so partial / malformed items
// don't pollute the downstream codegen registration.
pub func collectStdlibPackages(stdlibSources: in List[String]): List[StdlibPkg] {
  val pkgs: List[StdlibPkg] = newList()
  var si = 0
  while si < stdlibSources.count {
    val stdPr = parse(stdlibSources[si])
    // Diagnostics already surfaced via `collectStdlibTypeItems`'s
    // earlier walk over the same sources, so suppress double-printing
    // here.
    if hasParseError(stdPr.diagnostics) {
      si = si + 1
      continue
    }
    val pkgName = segmentsToString(stdPr.file.packageDecl.path.segments)
    val items: List[Item] = newList()
    var ii = 0
    while ii < stdPr.file.items.count {
      val it = stdPr.file.items[ii]
      // Only `pub` functions surface in the foreign DLL's public
      // method table; private functions get internal accessibility
      // and a cross-assembly MemberRef would fail to bind at
      // runtime.  Filtering here keeps `StdlibPkg.items` aligned
      // with what `registerStdlibFunc` would actually register and
      // removes the dead `isPub`-guarded iteration on the codegen
      // side (review #1429).
      val include = match it.kind {
        case IRecord(_) -> true
        case IExposedRec(_) -> true
        case IUnion(_) -> true
        case IEnum(_) -> true
        case IDistinctType(_) -> true
        case IInterface(_) -> true
        case ITypeAlias(_) -> true
        case IOpaque(_) -> true
        case IProtected(_) -> true
        case IExternType(_) -> true
        case IFunc(decl) -> match decl.visibility { case Some(VisPub(_)) -> true; case _ -> false }
        case _ -> false
      }
      if include {
        items.add(it)
      }
      ii = ii + 1
    }
    pkgs.add(StdlibPkg(name = pkgName, items = items))
    si = si + 1
  }
  pkgs
}

// Collect every pure-Lyric generic `pub func` from the stdlib packages so the
// monomorphizer can specialise consumer call sites — e.g. `mapGet(m, "k")` ->
// a concrete `mapGet__String__String` copy emitted into the consumer bundle —
// instead of leaving an un-instantiated cross-assembly generic call whose
// `Option[V]` return erases to `object` and breaks the consumer's concrete
// `match` (#1727).
//
// Filtered conservatively to `generic` funcs with a real `{ }` block body
// and no blocking annotations — `annsBlockSpecialization` rejects
// `@externTarget` and `@axiom` while allowing benign markers like `@stable`.
// This excludes kernel externs (`tryGetValue`, `newMap`, …), which are `= ()`
// expression bodies carrying `@externTarget`: `specializeFunc` drops
// annotations, so a specialised copy of an extern would lose its
// `@externTarget` and emit a broken no-op body.  Those calls stay
// un-specialised and are emitted directly by codegen's extern path.  Missing
// a legitimately-specialisable generic here is safe (the call just stays
// un-specialised, the status quo); including a non-specialisable one is not.
pub func collectStdlibGenericFuncs(pkgs: in List[StdlibPkg]): List[FunctionDecl] {
  val genFuncs: List[FunctionDecl] = newList()
  var pi = 0
  while pi < pkgs.count {
    val pkg: StdlibPkg = pkgs[pi]
    var ii = 0
    while ii < pkg.items.count {
      match pkg.items[ii].kind {
        case IFunc(decl) -> {
          val isGeneric = match decl.generics { case Some(_) -> true; case None -> false }
          val hasBlockBody = match decl.body {
            case Some(fb) -> match fb { case FBBlock(_) -> true; case FBExpr(_) -> false }
            case None -> false
          }
          // `mapGet` is a codegen builtin intrinsic (see the `funcName ==
          // "mapGet"` branch in `Msil.Codegen.lowerBuiltinOrStaticCallMsil`),
          // which wraps `Dictionary.get_Item` into `Option[V]` directly.
          // Monomorphizing it would rename the call (`mapGet__String__String`),
          // bypass the intrinsic, and copy a body that calls the generic kernel
          // extern `tryGetValue` — which the consumer can't lower.  Leave it to
          // the intrinsic.
          // Bare-name match: only stdlib packages enter `collectStdlibGenericFuncs`,
          // and `mapGet` is unique in `Std.Collections` today.  A future @builtin_intrinsic
          // annotation would let any module mark intrinsics declaratively.
          if isGeneric and hasBlockBody and not annsBlockSpecialization(decl.annotations) and not (decl.name == "mapGet" and pkg.name == "Std.Collections") {
            genFuncs.add(decl)
          }
        }
        case _ -> {
        }
      }
      ii = ii + 1
    }
    pi = pi + 1
  }
  genFuncs
}

// Collect every generic `pub func` with a block body from all parsed in-bundle
// user packages so that cross-package same-bundle generic calls (e.g.
// `Validation.toResult(42, [])` from a test package calling a generic in the
// `Validation` package) are specialised into the calling package instead of
// falling through to the unresolved-call fallback that emits unbalanced IL
// (causing `InvalidProgramException` at runtime).  Mirrors the logic of
// `collectStdlibGenericFuncs` but operates on `ParsedUserPkg` entries (#2932).
func collectInBundleGenericFuncs(parsedPkgs: in List[ParsedUserPkg]): List[FunctionDecl] {
  val genFuncs: List[FunctionDecl] = newList()
  var pi = 0
  while pi < parsedPkgs.count {
    val file = parsedPkgs[pi].file
    var ii = 0
    while ii < file.items.count {
      match file.items[ii].kind {
        case IFunc(decl) -> {
          val isPub = match decl.visibility { case Some(VisPub(_)) -> true; case _ -> false }
          val isGeneric = match decl.generics { case Some(_) -> true; case None -> false }
          val hasBlockBody = match decl.body {
            case Some(fb) -> match fb { case FBBlock(_) -> true; case FBExpr(_) -> false }
            case None -> false
          }
          if isPub and isGeneric and hasBlockBody and not annsBlockSpecialization(decl.annotations) {
            genFuncs.add(decl)
          }
        }
        case _ -> ()
      }
      ii = ii + 1
    }
    pi = pi + 1
  }
  genFuncs
}

// True iff the annotation list carries a marker that makes a generic
// unsuitable for monomorphization-by-copy.  `@externTarget` is a kernel
// boundary whose body codegen synthesises from the BCL target (and
// `specializeFunc` drops annotations, so a copy would lose it); `@axiom`
// funcs are proof-only and must not be emitted as runtime code.  Benign
// markers like `@stable` do not block specialization.
func annsBlockSpecialization(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 {
      val n = segs[0]
      if n == "externTarget" or n == "axiom" {
        return true
      }
    }
    i = i + 1
  }
  false
}

// Return a new `StdlibPkg` list with any package whose name matches
// an entry in `bundleNames` dropped.  Used to keep
// `registerStdlibArtifactTokens` from clashing with `addPackageTokens`
// when the in-bundle build set happens to include the stdlib package
// itself (e.g. compiling the `Lyric.Stdlib` bundle).
pub func filterStdlibPkgsByBundle(pkgs: in List[StdlibPkg], bundleNames: in List[String]): List[StdlibPkg] {
  val keep: List[StdlibPkg] = newList()
  var i = 0
  while i < pkgs.count {
    val pkg: StdlibPkg = pkgs[i]
    if not bundleNameMatches(bundleNames, pkg.name) {
      keep.add(pkg)
    }
    i = i + 1
  }
  keep
}

func bundleNameMatches(bundleNames: in List[String], name: in String): Bool {
  var i = 0
  while i < bundleNames.count {
    if bundleNames[i] == name {
      return true
    }
    i = i + 1
  }
  false
}

// Diagnostic-printing helpers — thin wrappers over `Lyric.DiagnosticUtil`.
// The local names differ from `DiagUtil.diagReportAndAbort` etc. because
// the bootstrap call resolver shadows fully-qualified cross-package
// calls with the enclosing module's same-named symbol, producing
// infinite recursion at runtime (lyric-lang #714).
func reportAndAbort(diags: in List[Diagnostic]): Bool {
  DiagUtil.diagReportAndAbort(diags)
}

func reportAndAbortInPkg(pkgName: in String, diags: in List[Diagnostic]): Bool {
  DiagUtil.diagReportAndAbortInPkg(pkgName, diags)
}

func reportDiagnostics(diags: in List[Diagnostic]): Unit {
  DiagUtil.diagReport(diags)
}

// Join path segments with "." — e.g. ["My", "Package"] → "My.Package".
func segmentsToString(segments: in List[String]): String {
  var result = ""
  var i = 0
  while i < segments.count {
    if i > 0 {
      result = result + "."
    }
    result = result + segments[i]
    i = i + 1
  }
  result
}

// Return the MethodDef token of `main` if it was registered, or 0 for libraries.
// The first package whose `main()` `addPackageTokens` walked over records
// its token in `cctx.mainEntryToken[0]` (#1183 Phase 2).
// Build a `Lyric.Contract` resource payload for `file` and seed the
// lowering ctx + metadata tables so the assembler emits it into the
// PE.  Mirrors what the F# emitter's
// `bootstrap/src/Lyric.Emitter/ContractMeta.fs::embedIntoAssemblyAs`
// does as a post-process step; the self-hosted bridge does it in-line
// during emission instead.
//
// `resourceName` is typically `"Lyric.Contract"` for single-package
// assemblies, or `"Lyric.Contract.<Pkg>"` for project-as-DLL bundles
// (#1183 multi-package emission).  `version` is the manifest-declared
// semver for the package being emitted; ad-hoc compiles without a
// manifest pass `"0.0.0"`.
func embedLyricContract(lctx: in LoweringCtx, file: in SourceFile, resourceName: in String, version: in String): Unit {
  val contract = Meta.buildContractFromFile(file, version)

  // Emit contract metadata in v2 format.
  // Phase 1.2b (v3 format with SHA-256 hashing) is shipped in Lyric.ContractMetaEmit
  // for the self-hosted compiler path and will be integrated here once the
  // bootstrap path supports loading self-hosted packages (tracked in #2580).
  val json = Meta.contractToJson(contract)
  val jsonBytes = Encoding.encodeUtf8(json)
  val jsonLen = jsonBytes.length

  // Resources region layout: per-resource = 4-byte LE length + bytes.
  // `offset` on the ManifestResource row points at the start of this
  // resource's length-prefixed slot.
  val offset = lctx.resourceData.count

  // Append the 4-byte LE length prefix.
  lctx.resourceData.add(jsonLen % 256)
  lctx.resourceData.add((jsonLen / 256) % 256)
  lctx.resourceData.add((jsonLen / 65536) % 256)
  lctx.resourceData.add((jsonLen / 16777216) % 256)

  // Append the UTF-8 bytes.
  var i = 0
  while i < jsonLen {
    lctx.resourceData.add(jsonBytes[i])
    i = i + 1
  }

  // Register the ManifestResource row.  `implementation = 0` for an
  // embedded resource per ECMA-335 §II.22.24.  Row index discarded —
  // the row's identity is its position in `lctx.tables.manifestResources`
  // and downstream serialisation reads that list directly.
  val sName = internString(lctx.strings, resourceName)
  val _row = addManifestResource(
    lctx.tables,
    ManifestResourceRow(
      offset = offset,
      flags = 1,
      // Public
      name = sName,
      implementation = 0
    )
  )
  // embedded
}

// Resolve the bundle-wide entry-point MethodDef token.  Returns 0
// (= library / no entry point) when no `main()` was registered.
func resolveEntryToken(cctx: in CodegenCtx): Int {
  if cctx.mainEntryToken.count > 0 {
    cctx.mainEntryToken[0]
  } else {
    0
  }
}
