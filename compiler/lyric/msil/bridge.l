// msil/bridge.l — Self-hosted MSIL compilation pipeline (Phase R6).
//
// Public entry point that chains the self-hosted Lyric pipeline to produce a
// .NET PE DLL from Lyric source text.  Calls:
//   parse → error-check → newCodegenCtx → addPackageTokens
//   → codegenMPackage → lowerMPackageWithCtx → writeBytes

package Msil.Bridge

import Std.Core
import Std.Collections
import Std.File
import Lyric.Lexer
import Lyric.Parser
import Msil.Lowering
import Msil.Codegen

/// Compile `source` to a .NET PE DLL at `outputPath` using the self-hosted
/// MSIL pipeline.
///
/// Returns true on success; false if the source contains parse errors or the
/// file write fails.  The package name and assembly name are taken from the
/// parsed `package` declaration in the source.
pub func compileToMsil(source: in String, outputPath: in String): Bool {
  val parseResult = parse(source)

  // Abort on any error-severity diagnostic.
  var hasErrors = false
  var i = 0
  while i < parseResult.diagnostics.count {
    val diag = parseResult.diagnostics[i]
    match diag.severity {
      case DiagError   -> hasErrors = true
      case DiagWarning -> ()
    }
    i = i + 1
  }
  if hasErrors { return false }

  val file = parseResult.file

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
