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
import Lyric.Derives
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
    // Surface stdlib parse diagnostics — advisory, not fatal (#914).
    // See the matching block in `lyric-compiler/msil/bridge.l` for the
    // rationale: self-hosted `Lyric.Parser` has known gaps vs. the
    // stdlib source files, so promoting these to fatal would break
    // every user build until the parser reaches stdlib parity.
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

// ─────────────────────────────────────────────────────────────────────────────
// Multi-package JAR compilation (#1611).
//
// `compileToJar` above bundles only the user's own package, so a program that
// imports `Std.Testing` (or any stdlib package whose *functions* it calls)
// links but then faults at runtime — the callee's bytecode is absent.
// `compileToJarBundled` closes that gap: it compiles the user package plus the
// transitive closure of its stdlib imports into a single runnable JAR, and
// builds one cross-package call registry (JvmFuncSig) so every call site
// resolves its callee's host class + descriptor regardless of declaring package.
//
// Each package is lowered with its *own* constant pool, so a package whose
// codegen fails (e.g. a kernel/extern package the JVM backend can't yet emit)
// can be skipped without corrupting the rest of the JAR — and any unreachable
// reference to its classes resolves lazily at first call, which never happens.
// ─────────────────────────────────────────────────────────────────────────────

// Join a ModulePath's segments with "." (the Lyric package-name spelling).
func dottedPath(path: in ModulePath): String {
  var acc = ""
  var i = 0
  while i < path.segments.count {
    if i > 0 { acc = acc + "." }
    acc = acc + path.segments[i]
    i = i + 1
  }
  acc
}

// True for top-level type-declaring items (the set fed to `checkWithImports`
// as imported items so cross-package type names resolve).
func isTypeItem(it: in Item): Bool {
  match it.kind {
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
}

// Run the middle-end (type check → mode check → contract elaborate → derive →
// monomorphise) on one parsed file.  Returns the post-mono file, or None if a
// fatal mode-check / mono diagnostic was raised.  Type-check diagnostics are
// advisory (the self-hosted checker lacks full builtin coverage), mirroring
// `compileToJar`.
func runMiddleEnd(file0: in SourceFile, importedItems: in List[Item]): Option[SourceFile] {
  val tcRes = checkWithImports(file0, importedItems)
  reportDiagnostics(tcRes.diagnostics)
  val mcRes = checkFile(file0)
  if reportAndAbort(mcRes.diagnostics) { return None }
  val elaborated = elaborateFile(file0)
  val derived    = deriveFile(elaborated)
  val monoRes    = monoFile(derived)
  if reportAndAbort(monoRes.diagnostics) { return None }
  Some(value = monoRes.file)
}

// Codegen one (already middle-ended) file against `registry` and append its
// class files to `out`.  Uses an isolated constant pool per package.
func codegenPackageInto(file: in SourceFile,
                        registry: in Map[String, JvmFuncSig],
                        acc: in List[BuiltClass]): Unit {
  val pkg        = codegenPackageWithSigs(file, registry)
  val pool       = poolNew()
  val classFiles = lowerPackage(pkg, pool)
  var j = 0
  while j < classFiles.count {
    val cf = classFiles[j]
    acc.add(BuiltClass(binaryName = cf.thisClass, bytes = serializeClassWithPool(cf, pool)))
    j = j + 1
  }
}

pub func compileToJarBundled(
  source:        in String,
  outputPath:    in String,
  packageName:   in String,
  stdlibSources: in List[String]
): Bool {
  val parseResult = parse(source)
  if reportAndAbort(parseResult.diagnostics) { return false }
  match mainReturns2SlotType(parseResult.file) {
    case Some(ty) -> {
      Console.error("error[J001]: `func main(): " + ty + "` is not supported on the JVM target")
      Console.error("  hint: use `func main(): Int` (exit code) or `func main(): Unit`")
      return false
    }
    case None -> ()
  }
  val userFile = parseResult.file

  // Parse every stdlib source once: collect its type items (for cross-package
  // type resolution) and index the whole file by dotted package name (for the
  // import-closure walk below).
  val importedItems: List[Item] = newList()
  val stdlibFiles:   List[SourceFile] = newList()
  val stdlibByPkg:   Map[String, SourceFile] = newMap()
  var si = 0
  while si < stdlibSources.count {
    val pr = parse(stdlibSources[si])
    reportDiagnostics(pr.diagnostics)
    var ii = 0
    while ii < pr.file.items.count {
      if isTypeItem(pr.file.items[ii]) { importedItems.add(pr.file.items[ii]) }
      ii = ii + 1
    }
    stdlibFiles.add(pr.file)
    val pn = dottedPath(pr.file.packageDecl.path)
    if pn.length > 0 and not stdlibByPkg.containsKey(pn) { stdlibByPkg.add(pn, pr.file) }
    si = si + 1
  }

  // Build the cross-package call registry across the user file and *every*
  // stdlib file (resolution is cheap and harmless for packages we don't bundle).
  val registry: Map[String, JvmFuncSig] = newMap()
  collectFileSigs(userFile, registry)
  var ri = 0
  while ri < stdlibFiles.count {
    collectFileSigs(stdlibFiles[ri], registry)
    ri = ri + 1
  }

  // Transitive import closure: the stdlib packages whose bytecode must be
  // bundled because the user (directly or indirectly) imports them.
  val toBundle: List[SourceFile] = newList()
  val seen:     Map[String, Bool] = newMap()
  val worklist: List[String] = newList()
  var ui = 0
  while ui < userFile.imports.count {
    worklist.add(dottedPath(userFile.imports[ui].path))
    ui = ui + 1
  }
  var wi = 0
  while wi < worklist.count {
    val pkg = worklist[wi]
    wi = wi + 1
    if not seen.containsKey(pkg) {
      seen.add(pkg, true)
      match mapGet(stdlibByPkg, pkg) {
        case Some(f) -> {
          toBundle.add(f)
          var fi = 0
          while fi < f.imports.count {
            worklist.add(dottedPath(f.imports[fi].path))
            fi = fi + 1
          }
        }
        case None -> ()   // builtin head / unavailable package — nothing to bundle
      }
    }
  }

  val allClasses: List[BuiltClass] = newList()

  // User package first (its codegen failing is fatal).
  match runMiddleEnd(userFile, importedItems) {
    case Some(f) -> codegenPackageInto(f, registry, allClasses)
    case None    -> return false
  }

  // Bundled stdlib packages, best-effort: a package the JVM backend can't yet
  // emit (kernel/extern surfaces) is skipped rather than failing the build, so
  // only the call-reachable packages need to compile cleanly.
  var bi = 0
  while bi < toBundle.count {
    val f = toBundle[bi]
    try {
      match runMiddleEnd(f, importedItems) {
        case Some(ff) -> codegenPackageInto(ff, registry, allClasses)
        case None     -> ()
      }
    } catch Bug as _ {
      Console.error("note: skipped bundling JVM package '" +
        dottedPath(f.packageDecl.path) + "' (codegen unsupported); " +
        "calls into it will fail only if actually reached")
    }
    bi = bi + 1
  }

  // Main-Class from the user package declaration.
  val segs = userFile.packageDecl.path.segments
  var mainClassName: String = packageName
  if segs.count > 0 { mainClassName = dottedPath(userFile.packageDecl.path) }

  val req = BuildRequest(
    packageName = packageName,
    mainClass   = mainClassName,
    version     = "0.1.0",
    outPath     = outputPath
  )
  writeJarFromClasses(req, allClasses)
}
