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
  val parseResult = parse(source)
  if reportAndAbort(parseResult.diagnostics) { return false }

  // ── Middle-end (Band 1 + Band 6 of docs/41 §9) ─────────────────────────
  // Run the self-hosted type checker with stdlib imports, mode checker, and
  // contract elaborator before codegen so that source-level diagnostics surface
  // here instead of producing broken IL further down.
  //
  // Band 6: parse each stdlib source and register only their type declarations
  // as imported items.  Only type items (IRecord, IUnion, IEnum, IDistinctType,
  // IInterface, ITypeAlias, IOpaque, IExposedRec) are collected — function items
  // are skipped because multiple stdlib files define functions with the same name
  // (e.g. toString) and checkWithImports uses a strict-insert map that throws on
  // duplicate keys.  Type names are unique across the stdlib so safe to merge.
  val importedItems: List[Item] = newList()
  var si = 0
  while si < stdlibSources.count {
    val stdPr = parse(stdlibSources[si])
    // Surface stdlib parse diagnostics — advisory, not fatal (#914).
    //
    // Aborting on stdlib parse *errors* would be safer in principle
    // (the alternative is silently dropping items from `importedItems`,
    // which then surfaces in user code as opaque T0010 / T0014 errors
    // far from the real cause).  But today the self-hosted
    // `Lyric.Parser` still has known gaps relative to the actual
    // stdlib source files — switching this to `reportAndAbort` makes
    // every user build fail with parser errors that the F# stage-0
    // pipeline already tolerates.  Keep advisory until the self-hosted
    // parser reaches parity with the stdlib (tracked alongside the
    // type-checker advisory promotion in docs/41 §9 Band 1).
    reportDiagnostics(stdPr.diagnostics)
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
        case _                -> false
      }
      if isType { importedItems.add(it) }
      ii = ii + 1
    }
    si = si + 1
  }

  val file0 = parseResult.file

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
  // compile path: no restored artifacts.
  val emptyArtifacts: List[SynthesisedArtifact] = newList()
  val cctx = newCodegenCtx(pkgName, emptyArtifacts)

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
  embedLyricContract(cctx.lctx, liftedFile, "Lyric.Contract")

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

  var pi = 0
  while pi < packages.count {
    val pkg = packages[pi]

    val parseResult = parse(pkg.source)
    if reportAndAbort(parseResult.diagnostics) { return false }
    // Apply `@cfg`-driven erasure BEFORE typecheck so feature-gated
    // items disappear cleanly (matches the F# emitter convention).
    val cfgRes = Cfg.applyCfgErasure(activeFeatures, declaredFeatures, parseResult.file)
    if reportAndAbort(cfgRes.diagnostics) { return false }
    val file0 = cfgRes.file

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
  val cctx = newCodegenCtx(assemblyName, restoredArtifacts)
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
    embedLyricContract(cctx.lctx, lifted, "Lyric.Contract." + perPkgNames[li])
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

// Helper: parse `stdlibSources`, extract type-shaped items, and append them
// to `importedItems`.  Mirrors the per-source loop inside `compileToMsil`
// (lines 53-88) so multi-package and single-package compile share the same
// stdlib type-resolution rules.  Parse errors are advisory (printed but not
// fatal) for the same reason `compileToMsil`'s loop documents: the self-
// hosted parser still has known gaps relative to the actual stdlib source
// files (#914).
func collectStdlibTypeItems(
  stdlibSources: in List[String],
  importedItems: in List[Item]
): Unit {
  var si = 0
  while si < stdlibSources.count {
    val stdPr = parse(stdlibSources[si])
    reportDiagnostics(stdPr.diagnostics)
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
        case _                -> false
      }
      if isType { importedItems.add(it) }
      ii = ii + 1
    }
    si = si + 1
  }
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
// (#1183 multi-package emission).
func embedLyricContract(lctx: in LoweringCtx, file: in SourceFile,
                        resourceName: in String): Unit {
  val contract = Meta.buildContractFromFile(file)
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
  // embedded resource per ECMA-335 §II.22.24.
  val sName = internString(lctx.strings, resourceName)
  val mresRow = addManifestResource(lctx.tables, ManifestResourceRow(
    offset         = offset,
    flags          = 1,    // Public
    name           = sName,
    implementation = 0))   // embedded
  // Row index returned by addManifestResource is unused at the
  // bridge level (the metadata table itself carries it); the call's
  // only side effect we depend on is appending the row.
  if mresRow < 0 { () }  // unreachable; row indices are 1-based
}

func resolveEntryToken(cctx: in CodegenCtx): Int {
  if cctx.mainEntryToken.count > 0 {
    cctx.mainEntryToken[0]
  } else {
    0
  }
}
