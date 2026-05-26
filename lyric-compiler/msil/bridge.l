// msil/bridge.l — Self-hosted MSIL compilation pipeline (Phase R6).
//
// Public entry point that chains the self-hosted Lyric pipeline to produce a
// .NET PE DLL from Lyric source text.  Calls (docs/41 §9 Band 1 + Band 5):
//   parse → typecheck → modecheck → elaborate → mono
//        → newCodegenCtx → addPackageTokens
//        → codegenMPackage → lowerMPackageWithCtx → writeBytes

package Msil.Bridge

import Std.Core
import Std.Collections
import Std.File
import Lyric.Lexer
import Lyric.Parser
import Lyric.AliasRewriter as Aliases
import Lyric.TypeChecker
import Lyric.ModeChecker
import Lyric.ContractElaborator
import Lyric.Cfg as Cfg
import Lyric.DiagnosticUtil as DiagUtil
import Lyric.Mono
import Lyric.Derives
import Lyric.RestoredPackages
import Lyric.ContractMeta as Meta
import Std.Encoding as Encoding
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
pub func compileToMsil(
  source:        in String,
  outputPath:    in String,
  stdlibSources: in List[String]
): Bool {
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
  source:         in String,
  outputPath:     in String,
  stdlibSources:  in List[String],
  packageVersion: in String
): Bool {
  val parseResult = parse(source)
  if reportAndAbort(parseResult.diagnostics) { return false }

  // ── Middle-end (Band 1 + Band 6 of docs/41 §9) ─────────────────────────
  // Run the self-hosted type checker with stdlib imports, mode checker, and
  // contract elaborator before codegen so that source-level diagnostics surface
  // here instead of producing broken IL further down.
  //
  // Band 6: parse each stdlib source and register its type-shaped items as
  // imported items so user code can reference `Std.X.Bar` (and the kernel-
  // declared `List[T]`, `Map[K,V]`, `Random`, `Scope`, …) at typecheck.
  // See `collectStdlibTypeItems` for the filter set and the rationale.
  val importedItems: List[Item] = newList()
  collectStdlibTypeItems(stdlibSources, importedItems)

  // Collapse `import X as Y` aliases: rewrite `Y.foo(...)` to bare
  // `foo(...)` (and the same for type / pattern positions) so the
  // self-hosted typechecker, which doesn't track import aliases
  // natively, doesn't fire T0020 on the alias head.  Mirrors the
  // F# `Lyric.Parser.AliasRewriter.rewriteFile` pass that the
  // production F# emitter runs immediately after parse.
  val file0 = Aliases.rewriteFile(parseResult.file)

  val tcRes = checkWithImports(file0, importedItems)
  reportDiagnostics(tcRes.diagnostics)   // advisory: type checker lacks builtin coverage

  val mcRes = checkFile(file0)
  if reportAndAbort(mcRes.diagnostics) { return false }

  val elaborated = elaborateFile(file0)

  // Synthesise @derive / @generate(Json) methods (Band 5 — docs/41 §9 #857).
  val derived = deriveFile(elaborated)

  // Monomorphise same-package generic calls (Band 5 — docs/41 §9).
  val monoRes = monoFile(derived)
  if reportAndAbort(monoRes.diagnostics) { return false }
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

  // Run the aspect weaver before the token pre-scan so that the pre-scan
  // sees the post-weave function list (renamed originals + synthesised wrappers).
  // `codegenMPackage` will call weaveAspectsMsil internally too, but it
  // short-circuits when the file has no IAspect items remaining.
  val weavedFile = weaveAspectsMsil(file)

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
  val resourceVersion = if packageVersion.length == 0 { "0.0.0" }
                        else { packageVersion }
  embedLyricContract(cctx.lctx, liftedFile, "Lyric.Contract", resourceVersion)

  // Lower the package IR to raw PE bytes using the pre-seeded context.
  val bytes = lowerMPackageWithCtx(pkg, cctx.lctx, entryToken)

  // Write the PE to disk.
  val result = writeBytes(outputPath, bytes)
  match result {
    case Ok(_)  -> true
    case Err(_) -> false
  }
}

/// One package's per-source-file payload for `compileProjectToMsil`.
/// `name` is the dotted package name (e.g. "Bug1140.Producer") and `source`
/// is the combined source text for that package — multi-file packages should
/// already be merged into a single string by the caller.
pub record ProjectPackagePayload {
  name:   String
  source: String
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
  packages:      in List[ProjectPackagePayload],
  assemblyName:  in String,
  outputPath:    in String,
  stdlibSources: in List[String]
): Bool {
  // Backward-compat shim: no feature flags, no restored artifacts.
  val noFeatures: List[String]   = newList()
  val noArtifacts: List[SynthesisedArtifact]  = newList()
  compileProjectToMsilWithRestored(packages, assemblyName, outputPath,
                                   stdlibSources, noFeatures, noFeatures,
                                   noArtifacts)
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
  packages:         in List[ProjectPackagePayload],
  assemblyName:     in String,
  outputPath:       in String,
  stdlibSources:    in List[String],
  activeFeatures:   in List[String],
  declaredFeatures: in List[String]
): Bool {
  // Forwarder: no restored artifacts.  Callers that need them use
  // `compileProjectToMsilWithRestored` directly.
  val noArtifacts: List[SynthesisedArtifact] = newList()
  compileProjectToMsilWithRestored(packages, assemblyName, outputPath,
                                   stdlibSources, activeFeatures, declaredFeatures,
                                   noArtifacts)
}

/// Like `compileProjectToMsilWithFeatures` but accepts a list of
/// `Lyric.RestoredPackages.SynthesisedArtifact`s for the consumer's
/// restored dependencies and seeds them into `CodegenCtx.restoredArtifacts`.
pub func compileProjectToMsilWithRestored(
  packages:          in List[ProjectPackagePayload],
  assemblyName:      in String,
  outputPath:        in String,
  stdlibSources:     in List[String],
  activeFeatures:    in List[String],
  declaredFeatures:  in List[String],
  restoredArtifacts: in List[SynthesisedArtifact]
): Bool {
  // Forwarder to the version-threading variant with an empty version
  // (legacy `0.0.0.0` Assembly row).
  compileProjectToMsilWithRestoredAndVersion(
    packages, assemblyName, outputPath, stdlibSources,
    activeFeatures, declaredFeatures, restoredArtifacts, "")
}

/// Like `compileProjectToMsilWithRestored` but accepts a `[package].version`
/// string used for the bundled Assembly row and the embedded
/// `Lyric.Contract.<pkg>` resources.  Empty string → legacy `"0.0.0"`
/// default (see #1364 for the threading plan).
pub func compileProjectToMsilWithRestoredAndVersion(
  packages:          in List[ProjectPackagePayload],
  assemblyName:      in String,
  outputPath:        in String,
  stdlibSources:     in List[String],
  activeFeatures:    in List[String],
  declaredFeatures:  in List[String],
  restoredArtifacts: in List[SynthesisedArtifact],
  packageVersion:    in String
): Bool {
  if packages.count == 0 {
    return false
  }

  // Phase 1: parse + middle-end every package; collect each package's
  // post-middle-end SourceFile and dotted package name.
  val perPkgFiles: List[SourceFile] = newList()
  val perPkgNames: List[String]     = newList()

  // Cross-package imported items: as we process each package, accumulate its
  // type items so subsequent packages (which may import it) see them at
  // typecheck (#1183 Phase 2).  Seeds with the precompiled stdlib's type
  // surface; each in-bundle package contributes its own type-shaped items
  // to the same list after parse, so a later package's `import Earlier.Pkg`
  // surfaces the earlier package's types at typecheck.
  //
  // Phase 2 scope: type items only.  Cross-package function-call resolution
  // is handled separately at codegen time via the FQN-keyed `funcTokens`
  // table built up by the per-package `addPackageTokens` calls below.
  //
  // Known gap (#1195): this flat accumulation lets earlier packages'
  // `pub func`s pass typecheck in a later package even when that later
  // package never imported them.  Codegen later traps the leak via the
  // `MObject` fall-through in `lowerBuiltinOrStaticCallMsil`, but
  // per-package import filtering would surface the missing-import
  // error at typecheck time where the diagnostic is actionable.
  val importedItems: List[Item] = newList()
  collectStdlibTypeItems(stdlibSources, importedItems)

  // Seed `importedItems` with each restored artifact's public surface so
  // the typechecker can resolve cross-assembly references against the
  // synthesised contract source.  `collectTypeItemsFromFile` picks up
  // type-shaped items + `pub func`s; the codegen-side
  // `registerRestoredArtifactTokens` then maps those names to
  // AssemblyRef / TypeRef / MemberRef rows.
  var ri = 0
  while ri < restoredArtifacts.count {
    collectTypeItemsFromFile(restoredArtifacts[ri].source, importedItems)
    ri = ri + 1
  }

  var pi = 0
  while pi < packages.count {
    val pkg = packages[pi]

    val parseResult = parse(pkg.source)
    if reportAndAbort(parseResult.diagnostics) { return false }
    // Apply `@cfg`-driven erasure BEFORE typecheck so feature-gated
    // items disappear cleanly (matches the F# emitter convention).
    val cfgRes = Cfg.applyCfgErasure(activeFeatures, declaredFeatures, parseResult.file)
    if reportAndAbort(cfgRes.diagnostics) { return false }
    // Collapse `import X as Y` aliases — see the rationale at the
    // single-package `compileToMsil` invocation above (`AuthKernelNet`
    // / #1378 follow-up).
    val file0 = Aliases.rewriteFile(cfgRes.file)

    val tcRes = checkWithImports(file0, importedItems)
    if reportAndAbort(tcRes.diagnostics) { return false }

    val mcRes = checkFile(file0)
    if reportAndAbort(mcRes.diagnostics) { return false }

    val elaborated = elaborateFile(file0)
    val derived    = deriveFile(elaborated)

    val monoRes = monoFile(derived)
    if reportAndAbort(monoRes.diagnostics) { return false }

    perPkgFiles.add(monoRes.file)
    perPkgNames.add(pkg.name)

    // Contribute this package's type-shaped items to `importedItems` so
    // subsequent packages see them.  Matches `collectStdlibTypeItems`'s
    // is-type filter.
    collectTypeItemsFromFile(file0, importedItems)

    pi = pi + 1
  }

  // Phase 2: weave + lambda-lift + token pre-scan for every package against
  // ONE shared cctx — the persistent `nextMethodDefRow` / `nextFieldDefRow`
  // counters in `CodegenCtx` thread row numbering across calls.  The cctx's
  // Assembly row is named after the bundle, not any individual package.
  // `packageVersion` populates the Assembly row's major/minor; empty
  // falls back to 0.0.0.0.
  val pvParts = parseSemverMajorMinor(packageVersion)
  val cctx = newCodegenCtx(assemblyName, restoredArtifacts, pvParts[0], pvParts[1])
  // Seed cross-package symbol tables with the restored artifacts' type
  // surface so the per-package addPackageTokens pre-scan sees restored
  // types as first-class lookups.
  registerRestoredArtifactTokens(cctx)

  val liftedFiles: List[SourceFile] = newList()
  var li = 0
  while li < perPkgFiles.count {
    val weaved = weaveAspectsMsil(perPkgFiles[li])
    val lifted = liftLambdasMsil(weaved)
    addPackageTokens(cctx, lifted, perPkgNames[li])
    // Project-as-DLL embedding: each package's contract goes in its
    // own `Lyric.Contract.<Pkg>` resource so the in-process loader can
    // surface them per-package (matching the F# bundled-DLL layout).
    // `packageVersion` carries the manifest's `[package].version` for
    // the bundle; per-package versioning is out of scope for #1364 and
    // tracked separately.
    val bundleVer = if packageVersion.length == 0 { "0.0.0" }
                    else { packageVersion }
    embedLyricContract(cctx.lctx, lifted, "Lyric.Contract." + perPkgNames[li], bundleVer)
    liftedFiles.add(lifted)
    li = li + 1
  }

  // Phase 3: codegen each package into an MPackage against the same cctx.
  val mpkgs: List[MPackage] = newList()
  var ci = 0
  while ci < liftedFiles.count {
    val mpkg = codegenMPackage(liftedFiles[ci], cctx)
    mpkgs.add(mpkg)
    ci = ci + 1
  }

  // Phase 4: pick an entry point.  When any package defined a `main` function
  // the pre-scan stored its MethodDef token on `cctx.funcTokens` under the
  // simple name "main"; otherwise the bundle is a library (token 0).
  val entryToken = resolveEntryToken(cctx)

  // Phase 5: lower all MPackages into a single PE against the shared lctx.
  val bytes = lowerMPackagesWithCtx(mpkgs, cctx.lctx, entryToken)

  val result = writeBytes(outputPath, bytes)
  match result {
    case Ok(_)  -> true
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
  specLines:     in List[String],
  assemblyName:  in String,
  outputPath:    in String,
  stdlibSources: in List[String]
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
    val src  = line.substring(tabPos + 1)
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
  specLines:        in List[String],
  assemblyName:     in String,
  outputPath:       in String,
  stdlibSources:    in List[String],
  restoredDllPaths: in List[String],
  packageVersion:   in String
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
    val src  = line.substring(tabPos + 1)
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

  val activeFeatures:   List[String] = newList()
  val declaredFeatures: List[String] = newList()
  compileProjectToMsilWithRestoredAndVersion(
    packages, assemblyName, outputPath, stdlibSources,
    activeFeatures, declaredFeatures, restoredArtifacts, packageVersion)
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
func collectTypeItemsFromFile(
  file:          in SourceFile,
  importedItems: in List[Item]
): Unit {
  var i = 0
  while i < file.items.count {
    val it = file.items[i]
    val isType = match it.kind {
      case IRecord(_)       -> true
      case IExposedRec(_)   -> true
      case IUnion(_)        -> true
      case IEnum(_)         -> true
      case IDistinctType(_) -> true
      case IInterface(_)    -> true
      case ITypeAlias(_)    -> true
      case IOpaque(_)       -> true
      case _                -> false
    }
    val isPubFunc = match it.kind {
      case IFunc(decl) -> match decl.visibility {
        case Some(vis) -> match vis {
          case VisPub(_) -> true
          case _         -> false
        }
        case None -> false
      }
      case _ -> false
    }
    if isType or isPubFunc { importedItems.add(it) }
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
func collectStdlibTypeItems(
  stdlibSources: in List[String],
  importedItems: in List[Item]
): Unit {
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
      val isType = match it.kind {
        case IRecord(_)       -> true
        case IExposedRec(_)   -> true
        case IUnion(_)        -> true
        case IEnum(_)         -> true
        case IDistinctType(_) -> true
        case IInterface(_)    -> true
        case ITypeAlias(_)    -> true
        case IOpaque(_)       -> true
        case IProtected(_)    -> true
        case IExternType(_)   -> true
        case _                -> false
      }
      if isType { importedItems.add(it) }
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
      case _         -> {}
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

func reportDiagnostics(diags: in List[Diagnostic]): Unit {
  DiagUtil.diagReport(diags)
}

// Join path segments with "." — e.g. ["My", "Package"] → "My.Package".
func segmentsToString(segments: in List[String]): String {
  var result = ""
  var i = 0
  while i < segments.count {
    if i > 0 { result = result + "." }
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
func embedLyricContract(lctx: in LoweringCtx, file: in SourceFile,
                        resourceName: in String, version: in String): Unit {
  val contract = Meta.buildContractFromFile(file, version)
  val json     = Meta.contractToJson(contract)
  val jsonBytes = Encoding.encodeUtf8(json)
  val jsonLen   = jsonBytes.length

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
  val _row = addManifestResource(lctx.tables, ManifestResourceRow(
    offset         = offset,
    flags          = 1,    // Public
    name           = sName,
    implementation = 0))   // embedded
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
