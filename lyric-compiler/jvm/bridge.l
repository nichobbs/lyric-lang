// jvm/bridge.l — Self-hosted JVM compilation pipeline (Phase R4).
//
// Public entry point that chains the self-hosted Lyric pipeline to produce a
// JAR file from Lyric source text.  Calls parse → typecheck → modecheck →
// elaborate → mono → codegen → lower → write.

package Jvm.Bridge

import Std.Core
import Std.Collections
import Std.Console as Console
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.ModeChecker
import Lyric.ContractElaborator
import Lyric.DiagnosticUtil as DiagUtil
import Lyric.Mono
import Jvm.Kernel
import Jvm.Classfile
import Jvm.Lowering
import Jvm.Codegen
import Jvm.Driver

// Diagnostic-printing helpers — thin wrappers over `Lyric.DiagnosticUtil`
// (#827).  Local names differ from `DiagUtil.diag*` to dodge the
// bootstrap call-resolver shadowing pitfall (lyric-lang #714).
func reportAndAbort(diags: in List[Diagnostic]): Bool {
  DiagUtil.diagReportAndAbort(diags)
}

func reportDiagnostics(diags: in List[Diagnostic]): Unit {
  DiagUtil.diagReport(diags)
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
/// Band 6: accept pre-read stdlib source texts and use them as imported items
/// for cross-package type resolution.  Callers (F# shims) read the stdlib .l
/// files from disk and pass them here; this function parses them and feeds the
/// resulting items to checkWithImports so that stdlib names like `List`, `Option`,
/// `Result`, and `Map` resolve correctly rather than raising T0010 / T0014.
pub func compileToJar(
  source:        in String,
  outputPath:    in String,
  packageName:   in String,
  stdlibSources: in List[String]
): Bool {
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

  // ── Middle-end (Band 1 + Band 6 of docs/41 §9) ─────────────────────────
  // Run the self-hosted type checker with stdlib imports, mode checker, and
  // contract elaborator before codegen.
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
    // #905: surface stdlib parse diagnostics so a botched edit to a
    // stdlib source file doesn't silently produce an incomplete
    // `importedItems` list (later surfacing as opaque T0010/T0014
    // errors in user code).  Advisory only.
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

  // Monomorphise same-package generic calls (Band 5 — docs/41 §9).
  val monoRes = monoFile(elaborated)
  val file = monoRes.file

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
