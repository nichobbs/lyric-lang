// msil/bridge.l — Self-hosted MSIL compilation pipeline (Phase R6).
//
// Public entry point that chains the self-hosted Lyric pipeline to produce a
// .NET PE DLL from Lyric source text.  Calls (docs/41 §9 Band 1):
//   parse → typecheck → modecheck → elaborate
//        → newCodegenCtx → addPackageTokens
//        → codegenMPackage → lowerMPackageWithCtx → writeBytes
//
// `Lyric.Mono` (call-site monomorphiser) is NOT yet wired in.  Its source
// `lyric-compiler/lyric/mono.l` uses Lyric idioms that the frozen F#
// bootstrap parser can't compile (literal-pattern match arms followed by
// further arms — the F# parser P0040s on the second arm), so importing it
// here breaks the precompile of `Lyric.Msil.Bridge.dll` itself.  Until
// mono.l is restructured around the F# parser's quirks (or the F# parser
// is patched), bare generics in source-code calls fall through to the
// codegen's `MObject` default — which is the existing v0.x behaviour.

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
// import Lyric.Mono     // (see header) — wiring deferred to Band 5/6
import Msil.Lowering
import Msil.Codegen

/// Compile `source` to a .NET PE DLL at `outputPath` using the self-hosted
/// MSIL pipeline.
///
/// Returns true on success; false if the source contains parse / type /
/// mode errors, or if the file write fails.  All error- and warning-severity
/// diagnostics from each pass are printed to stdout before the bridge
/// returns.  The package name and assembly name are taken from the parsed
/// `package` declaration in the source.
pub func compileToMsil(source: in String, outputPath: in String): Bool {
  val parseResult = parse(source)
  if reportAndAbort(parseResult.diagnostics) { return false }

  // ── Middle-end (Band 1 of docs/41 §9) ─────────────────────────────────
  // Run the self-hosted type checker, mode checker, and contract
  // elaborator before codegen so that source-level diagnostics surface
  // here instead of producing broken IL further down.
  //
  // Type-checker diagnostics are printed but NOT fatal yet: the self-hosted
  // typechecker doesn't resolve cross-package imports (Band 6 in docs/41 —
  // typechecker_resolver.l:129 "deferred to T7+"), so it raises T0010 /
  // T0020 / T0050 for every reference to a stdlib name like `newList` or
  // `List[Int]`.  Treating those as build failures here would regress every
  // production program that imports `Std.*`.  Mode-checker diagnostics are
  // fatal — V0001–V0011 enforcement only consults the file itself plus
  // imported metadata, which the bridge supplies as the empty list (M4.1
  // conservative fallback per modechecker_check.l:81).
  val file0 = parseResult.file

  val tcRes = check(file0)
  reportDiagnostics(tcRes.diagnostics)   // advisory until Band 6

  val mcRes = checkFile(file0)
  if reportAndAbort(mcRes.diagnostics) { return false }

  val file = elaborateFile(file0)

  // Reconstruct the package name as a dotted string (e.g. "Hello" or
  // "My.Package") from the parsed path segments.
  val pkgName = segmentsToString(file.packageDecl.path.segments)

  // Build the codegen context — seeds a fresh LoweringCtx with all standard
  // library AssemblyRef / TypeRef / MemberRef rows.
  val cctx = newCodegenCtx(pkgName)

  // Pre-scan the AST to assign deterministic MethodDef / FieldDef tokens for
  // same-package types and functions.
  addPackageTokens(cctx, file, pkgName)

  // Walk the AST and produce the MSIL package IR.
  val pkg = codegenMPackage(file, cctx)

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

func formatDiagnostic(d: in Diagnostic): String {
  DiagUtil.diagFormat(d)
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
