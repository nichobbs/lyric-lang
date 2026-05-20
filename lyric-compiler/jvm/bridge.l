// jvm/bridge.l — Self-hosted JVM compilation pipeline (Phase R4).
//
// Public entry point that chains the self-hosted Lyric pipeline to produce a
// JAR file from Lyric source text.  Calls parse → codegen → lower → write.

// `Lyric.Mono` (call-site monomorphiser) is NOT yet wired in.  Its source
// `lyric-compiler/lyric/mono.l` uses Lyric idioms that the frozen F#
// bootstrap parser can't compile (literal-pattern match arms followed by
// further arms), so importing it here would break the precompile of
// `Lyric.Jvm.Bridge.dll` itself.  See header comment in `msil/bridge.l`
// for details.  Tracking: docs/41 §9 Bands 5–6.

package Jvm.Bridge

import Std.Core
import Std.Collections
import Std.Console as Console
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.ModeChecker
import Lyric.ContractElaborator
// import Lyric.Mono     // (see header) — wiring deferred
import Jvm.Kernel
import Jvm.Classfile
import Jvm.Lowering
import Jvm.Codegen
import Jvm.Driver

// Print every diagnostic in `diags` to stdout and return true when any of
// them is error-severity.  Warnings alone do not abort the build.  Mirrors
// the helper in `msil/bridge.l` (Band 1 of docs/41 §9).
func reportAndAbort(diags: in List[Diagnostic]): Bool {
  var hasErrors = false
  var i = 0
  while i < diags.count {
    val d = diags[i]
    println(formatDiagnostic(d))
    if d.severity == DiagError { hasErrors = true }
    i = i + 1
  }
  hasErrors
}

// Print every diagnostic in `diags` to stdout without affecting the
// compile's success/failure outcome.  Used for typechecker output until
// Band 6 (cross-package resolution) lands.
func reportDiagnostics(diags: in List[Diagnostic]): Unit {
  var i = 0
  while i < diags.count {
    println(formatDiagnostic(diags[i]))
    i = i + 1
  }
}

func formatDiagnostic(d: in Diagnostic): String {
  val sev = match d.severity {
    case DiagError   -> "error"
    case DiagWarning -> "warning"
  }
  sev + "[" + d.code + "] " +
    d.span.startPos.line.toString() + ":" +
    d.span.startPos.column.toString() + ": " + d.message
}

// Returns Some(typeName) if func main() has a 2-slot return type (Long or Double);
// None otherwise.  These types require POP2 to discard, but the JVM main wrapper
// only emits a single-slot POP — so they must be rejected before codegen rather
// than panicking inside codegenPackage.
func mainReturns2SlotType(file: in SourceFile): Option[String] {
  var i = 0
  while i < file.items.count {
    val item = file.items[i]
    match item.kind {
      case IFunc(decl) -> {
        if decl.name == "main" {
          match decl.ret {
            case Some(te) -> {
              match te.kind {
                case TRef(path) -> {
                  if path.segments.count > 0 {
                    val last = path.segments[path.segments.count - 1]
                    if last == "Long" or last == "Double" {
                      return Some(last)
                    }
                  }
                }
                case _ -> ()
              }
            }
            case None -> ()
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

/// Compile `source` to a JAR at `outputPath`.
///
/// Returns true on success; false if the source contains parse errors or the
/// JAR write fails.  `packageName` is the Lyric package identifier the F# CLI
/// derives from the source filename — it is used as the `Lyric-Package`
/// manifest attribute.  The JVM `Main-Class` attribute is derived from the
/// source's actual `package` declaration so a Lyric program saved as
/// `hello_jvm.l` but declaring `package Hello` still produces a runnable
/// `java -jar` artefact.
pub func compileToJar(source: in String, outputPath: in String, packageName: in String): Bool {
  val parseResult = parse(source)
  if reportAndAbort(parseResult.diagnostics) { return false }

  // Reject func main(): Long/Double before codegen: the JVM main wrapper emits
  // a single-slot POP to discard the return value, which would corrupt the operand
  // stack for 2-slot types (VerifyError at class load).  Surface the error here
  // as a clean compiler diagnostic rather than a panic inside codegenPackage.
  match mainReturns2SlotType(parseResult.file) {
    case Some(ty) -> {
      Console.error("error[J001]: `func main(): " + ty + "` is not supported on the JVM target")
      Console.error("  hint: use `func main(): Int` (exit code) or `func main(): Unit`")
      return false
    }
    case None -> ()
  }

  // ── Middle-end (Band 1 of docs/41 §9) ─────────────────────────────────
  // Run the self-hosted type checker, mode checker, and contract
  // elaborator before codegen.  The F# emitter co-runs today, but
  // wiring the self-hosted middle-end here lets the JVM bridge stand on
  // its own once `--target dotnet-legacy` is removed.
  //
  // Type-checker diagnostics are advisory only (no cross-package import
  // resolution yet — see Band 6 in docs/41).  Mode-checker and elaborator
  // output is fully self-contained, so V-codes / elaborated requires-and-
  // ensures asserts are load-bearing here.
  val file0 = parseResult.file

  val tcRes = check(file0)
  reportDiagnostics(tcRes.diagnostics)   // advisory until Band 6

  val mcRes = checkFile(file0)
  if reportAndAbort(mcRes.diagnostics) { return false }

  val file = elaborateFile(file0)

  val pkg    = codegenPackage(file)
  val pool   = poolNew()
  val classFiles = lowerPackage(pkg, pool)

  val classes: List[BuiltClass] = newList()
  var j = 0
  while j < classFiles.count {
    val cf = classFiles[j]
    classes.add(BuiltClass(binaryName = cf.thisClass, bytes = serializeClassWithPool(cf, pool)))
    j = j + 1
  }

  // Derive the JVM `Main-Class` from the source's `package` declaration.
  // ModulePath segments are joined with "." (JVM manifest convention).
  // Falls back to the F#-supplied packageName when the file has no package
  // declaration (only the synthetic stdlib bootstrap can hit that path).
  // Use the post-mono `file` rather than the raw parse tree so that
  // future package-renaming passes in the middle-end stay authoritative.
  val segs = file.packageDecl.path.segments
  var mainClassName: String = packageName
  if segs.count > 0 {
    var k = 0
    var acc = ""
    while k < segs.count {
      if k > 0 { acc = acc + "." }
      acc = acc + segs[k]
      k = k + 1
    }
    mainClassName = acc
  }

  val req = BuildRequest(
    packageName = packageName,
    mainClass   = mainClassName,
    version     = "0.1.0",
    outPath     = outputPath
  )

  writeJarFromClasses(req, classes)
}
