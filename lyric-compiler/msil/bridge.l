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
import Lyric.DiagnosticUtil as DiagUtil
import Lyric.Mono
import Lyric.Derives
import Msil.Lowering
import Msil.Codegen

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
    // #905: surface stdlib parse diagnostics so a botched edit to a stdlib
    // source file doesn't silently produce an incomplete `importedItems`
    // list (which would later surface as opaque T0010/T0014 errors in
    // user code).  Advisory only — a stdlib parse warning shouldn't
    // gate user builds, but the user should see it.
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
  val file = monoRes.file

  // Reconstruct the package name as a dotted string (e.g. "Hello" or
  // "My.Package") from the parsed path segments.
  val pkgName = segmentsToString(file.packageDecl.path.segments)

  // Build the codegen context — seeds a fresh LoweringCtx with all standard
  // library AssemblyRef / TypeRef / MemberRef rows.
  val cctx = newCodegenCtx(pkgName)

  // Run the aspect weaver before the token pre-scan so that the pre-scan
  // sees the post-weave function list (renamed originals + synthesised wrappers).
  // `codegenMPackage` will call weaveAspectsMsil internally too, but it
  // short-circuits when the file has no IAspect items remaining.
  val weavedFile = weaveAspectsMsil(file)

  // Pre-scan the AST to assign deterministic MethodDef / FieldDef tokens for
  // same-package types and functions.
  addPackageTokens(cctx, weavedFile, pkgName)

  // Walk the AST and produce the MSIL package IR.
  val pkg = codegenMPackage(weavedFile, cctx)

  // Determine the entry-point MethodDef token (0 = no entry point / library).
  val entryToken = resolveEntryToken(cctx)

  // Lower the package IR to raw PE bytes using the pre-seeded context.
  val bytes = lowerMPackageWithCtx(pkg, cctx.lctx, entryToken)

  // Write the PE to disk.
  val result = writeBytes(outputPath, bytes)
  match result {
    case Ok(_)  -> true
    case Err(_) -> false
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
func resolveEntryToken(cctx: in CodegenCtx): Int {
  match mapGet(cctx.funcTokens, "main") {
    case Some(tok) -> tok
    case None      -> 0
  }
}
