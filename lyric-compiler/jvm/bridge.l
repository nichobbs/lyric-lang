//! jvm/bridge.l — Self-hosted JVM compilation pipeline (Phase R4).
//!
//! Public entry point that chains the self-hosted Lyric pipeline to produce a
//! JAR file from Lyric source text.  Calls parse → typecheck → modecheck →
//! elaborate → mono → codegen → lower → write.
package Jvm.Bridge

import Std.Core
import Std.Collections
import Std.Console as Console
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.ModeChecker
import Lyric.ContractElaborator
import Lyric.Propagate
import Lyric.Cfg as Cfg
import Lyric.Weaver as Weaver
import Lyric.DiagnosticUtil as DiagUtil
import Lyric.Mono
import Lyric.Derives
import Lyric.Stubbable as Stubbable
import Jvm.Kernel
import Jvm.Classfile
import Jvm.Lowering
import Jvm.AutoFfi
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
  source: in String, outputPath: in String, packageName: in String, stdlibSources: in List[String]
): Bool {
  val parseResult = parse(source)
  if reportAndAbort(parseResult.diagnostics) {
    return false
  }

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
  // Band 6: collect each stdlib source's type declarations (functions are
  // skipped — many share a name, e.g. toString), grouped by declaring package
  // so same-named cross-package types (Std.Regex/Std.RegexSafe RegexError)
  // resolve against their own package rather than colliding.
  val importedPkgs: List[ImportedPackage] = newList()
  // Parsed stdlib source files, retained so `collectStdlibGenericFuncsJvm`
  // can feed the stdlib's pure-Lyric generic `pub func`s to the
  // monomorphizer (M-5 cross-package specialisation; parity with the
  // MSIL bridge's `collectStdlibGenericFuncs`).
  val stdlibFiles: List[SourceFile] = newList()
  var si = 0
  while si < stdlibSources.count {
    val stdPr = parse(stdlibSources[si])
    // Surface stdlib parse diagnostics — advisory, not fatal (#914).
    // See the matching block in `lyric-compiler/msil/bridge.l` for the
    // rationale: self-hosted `Lyric.Parser` has known gaps vs. the
    // stdlib source files, so promoting these to fatal would break
    // every user build until the parser reaches stdlib parity.
    reportDiagnostics(stdPr.diagnostics)
    val pkgItems: List[Item] = newList()
    var ii = 0
    while ii < stdPr.file.items.count {
      val it = stdPr.file.items[ii]
      if isTypeItem(it) {
        pkgItems.add(it)
      }
      ii = ii + 1
    }
    importedPkgs.add(ImportedPackage(name = dottedPath(stdPr.file.packageDecl.path), items = pkgItems))
    stdlibFiles.add(stdPr.file)
    si = si + 1
  }

  // Synthesise `@stubbable` interface stubs (record + impl) before type-check,
  // matching the MSIL bridge — keeps `@stubbable` working on both targets.
  val file0 = Stubbable.stubbableRewriteFile(parseResult.file)

  val tcRes = checkWithImportedPackages(file0, importedPkgs)
  reportDiagnostics(tcRes.diagnostics)
  // advisory: type checker lacks builtin coverage

  val mcRes = checkFile(file0)
  if reportAndAbort(mcRes.diagnostics) {
    return false
  }

  val elaborated = elaborateFile(file0)

  // Lower `?` error-propagation into match-unwrap + early-return (#1475).
  // Runs after the elaborator so a propagated Err/None short-circuit is not
  // forced through the success-shaped `ensures:` rewrite — parity with the
  // MSIL bridge (J2 / docs/44 §5, #2665).
  val propRes = lowerPropagateFile(elaborated)
  if reportAndAbort(propRes.diagnostics) {
    return false
  }

  // Synthesise @derive / @generate(Json) methods (Band 5 — docs/41 §9 #857).
  val derived = deriveFile(propRes.file)

  // Monomorphise generic calls (Band 5 — docs/41 §9), feeding the stdlib's
  // pure-Lyric generic `pub func`s so cross-package generic calls (`mapGet`,
  // `unwrapOr`, …) specialise into this artifact instead of erasing their
  // generic return to `object` (M-5; parity with the MSIL bridge's
  // `monoFileWithImports`).
  val stdlibGenFuncs = collectStdlibGenericFuncsJvm(stdlibFiles)
  val monoRes = monoFileWithImports(derived, stdlibGenFuncs)
  if reportAndAbort(monoRes.diagnostics) {
    return false
  }

  // Aspect weaving (B-3) — after mono, before codegen, matching the MSIL
  // bridge.  `weaveFileWithDiags` applies the todo/06 features (config
  // wiring #683, call-context #682, `@inline_template` #681) and surfaces
  // weave-time diagnostics (A0042 / A0043 / A0044) before codegen runs.
  val weaveRes = Weaver.weaveFileWithDiags(monoRes.file)
  if reportAndAbort(weaveRes.diagnostics) {
    return false
  }
  val file = weaveRes.file

  val pkg = codegenPackage(file)
  val pool = poolNew()
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
      if k > 0 {
        acc = acc + "."
      }
      acc = acc + segs[k]
      k = k + 1
    }
    mainClassName = acc
  }

  val req = BuildRequest(packageName = packageName, mainClass = mainClassName, version = "0.1.0", outPath = outputPath)

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
// Each package is lowered with its *own* constant pool.  Every package that
// reaches the bundling loop is in the user program's transitive import closure
// — i.e. it is *referenced* by the build — so a codegen failure for it is a
// real bug in a package the program depends on and is **fatal at compile time**
// (J1 B-6, #2664).  Mirrors the MSIL bridge, where the per-package codegen loop
// (`compileProjectToMsil`) likewise lets a codegen failure propagate rather than
// swallowing it.  Packages that are *not* in the closure are never added to the
// bundle list (the closure walk's `case None ->` arm), so they cannot mask a
// failure: their bytecode is simply absent, and a genuinely-unreached reference
// resolves lazily at a call that never happens.
// ─────────────────────────────────────────────────────────────────────────────
// Join a ModulePath's segments with "." (the Lyric package-name spelling).
func dottedPath(path: in ModulePath): String {
  var acc = ""
  var i = 0
  while i < path.segments.count {
    if i > 0 {
      acc = acc + "."
    }
    acc = acc + path.segments[i]
    i = i + 1
  }
  acc
}

// True for top-level items that must reach packages importing this one, so
// cross-package type names and pub-val constants resolve (#2377).
// Mirrors `collectTypeItemsFromFile` in `lyric-compiler/msil/bridge.l`.
func isTypeItem(it: in Item): Bool {
  val isType = match it.kind {
    case IRecord(_) -> true
    case IExposedRec(_) -> true
    case IUnion(_) -> true
    case IEnum(_) -> true
    case IDistinctType(_) -> true
    case IInterface(_) -> true
    case ITypeAlias(_) -> true
    case IOpaque(_) -> true
    // `extern type` declarations (e.g. `extern type Pool = "…"` in Jvm.Kernel)
    // must reach packages that import the declaring package, so the bare type
    // name resolves instead of aborting with T0010.
    case IExternType(_) -> true
    // `protected type` declarations must likewise propagate across package
    // boundaries so importing packages can reference the protected type.
    case IProtected(_) -> true
    case _ -> false
  }
  if isType {
    return true
  }
  // Module-level `pub val`s (e.g. `pub val ACC_PUBLIC: Int = 1` in Jvm.Classfile)
  // must reach importing packages or cross-package references abort with T0020.
  match it.kind {
    case IVal(_) -> match it.visibility { case Some(vis) -> match vis { case VisPub(_) -> true; case _ -> false }; case None -> false }
    case _ -> false
  }
}

// Run the middle-end (type check → mode check → contract elaborate →
// `?`-propagation lower → derive → monomorphise → weave) on one parsed file.
// Returns the post-weave file, or None if a fatal mode-check / propagate /
// mono / weave diagnostic was raised.  Type-check diagnostics are advisory
// (the self-hosted checker lacks full builtin coverage), mirroring
// `compileToJar`.
//
// Mirrors the MSIL bridge's per-package pass order (`?`-propagation after the
// elaborator, `monoFileWithImports` fed the stdlib's generic `pub func`s, then
// `Weaver.weaveFileWithDiags` before codegen) so the JVM target weaves
// aspects and specialises cross-package generics with the same semantics
// (J2 / docs/44 §5, #2665).
//
// `stdlibGenFuncs` supplies the stdlib's pure-Lyric generic `pub func`s to the
// monomorphizer so cross-package generic calls specialise into this bundle.
//
// `reportTcAdvisories` gates whether the (non-gating) type-check diagnostics
// are echoed to stderr.  Bundled stdlib packages pass `false`: their advisory
// T0020-style noise (the self-hosted checker lacks full builtin coverage)
// would otherwise leak onto a *successful* build's output.  Real errors still
// gate via `reportAndAbort` on the mode-check / propagate / mono / weave
// passes regardless.
func runMiddleEnd(
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  stdlibGenFuncs: in List[FunctionDecl],
  reportTcAdvisories: in Bool,
): Option[SourceFile] {
  val tcRes = checkWithImportedPackages(file0, importedPkgs)
  if reportTcAdvisories {
    reportDiagnostics(tcRes.diagnostics)
  }
  val mcRes = checkFile(file0)
  if reportAndAbort(mcRes.diagnostics) {
    return None
  }
  val elaborated = elaborateFile(file0)

  // Lower `?` error-propagation (#1475); see the single-file path above.
  val propRes = lowerPropagateFile(elaborated)
  if reportAndAbort(propRes.diagnostics) {
    return None
  }

  val derived = deriveFile(propRes.file)
  val monoRes = monoFileWithImports(derived, stdlibGenFuncs)
  if reportAndAbort(monoRes.diagnostics) {
    return None
  }

  // Aspect weaving (B-3) — after mono, before codegen, matching the MSIL
  // bridge's per-package weave so the todo/06 features and weave-time
  // diagnostics (A0042 / A0043 / A0044) apply on the JVM target too.
  val weaveRes = Weaver.weaveFileWithDiags(monoRes.file)
  if reportAndAbort(weaveRes.diagnostics) {
    return None
  }
  Some(value = weaveRes.file)
}

// Collect every pure-Lyric generic `pub func` from the parsed stdlib source
// files so the monomorphizer can specialise cross-package generic call sites —
// e.g. `mapGet(m, "k")` -> a concrete `mapGet__String__String` copy emitted
// into the bundle — instead of leaving the generic return erased.  Mirrors
// `Msil.Bridge.collectStdlibGenericFuncs`, but operates directly on the
// already-parsed `SourceFile`s the JVM bridge holds (the JVM bridge does not
// depend on the `Msil.*` packages, so the MSIL `StdlibPkg`-shaped helper is
// replicated here rather than imported).
//
// Filtered conservatively to `generic` `pub func`s with a real `{ }` block body
// and no blocking annotations — `annsBlockSpecializationJvm` rejects
// `@externTarget` and `@axiom` (whose bodies codegen synthesises / must not run
// as code).  `mapGet` is excluded: it is a codegen intrinsic whose specialised
// copy would call the un-lowerable generic kernel extern `tryGetValue`.
func collectStdlibGenericFuncsJvm(files: in List[SourceFile]): List[FunctionDecl] {
  val genFuncs: List[FunctionDecl] = newList()
  var fi = 0
  while fi < files.count {
    val f = files[fi]
    val pkgName = dottedPath(f.packageDecl.path)
    var ii = 0
    while ii < f.items.count {
      match f.items[ii].kind {
        case IFunc(decl) -> {
          val isPub = match decl.visibility { case Some(VisPub(_)) -> true; case _ -> false }
          val isGeneric = match decl.generics { case Some(_) -> true; case None -> false }
          val hasBlockBody = match decl.body {
            case Some(fb) -> match fb { case FBBlock(_) -> true; case FBExpr(_) -> false }
            case None -> false
          }
          if isPub and isGeneric and hasBlockBody and not annsBlockSpecializationJvm(decl.annotations) and not (decl.name == "mapGet" and pkgName == "Std.Collections") {
            genFuncs.add(decl)
          }
        }
        case _ -> ()
      }
      ii = ii + 1
    }
    fi = fi + 1
  }
  genFuncs
}

// True iff the annotation list carries a marker that makes a generic unsuitable
// for monomorphization-by-copy (`@externTarget` / `@axiom`).  Mirrors
// `Msil.Bridge.annsBlockSpecialization`.
func annsBlockSpecializationJvm(anns: in List[Annotation]): Bool {
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

// Codegen one (already middle-ended) file against `registry` and append its
// class files to `out`.  Uses an isolated constant pool per package.
func codegenPackageInto(
  file: in SourceFile,
  registry: in Map[String, JvmFuncSig],
  caseReg: in Map[String, List[JvmCaseField]],
  ctorReg: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  allProjFqns: in Map[String, Bool],
  acc: in List[BuiltClass],
): Unit {
  val pkg = codegenPackageWithSigs(file, registry, caseReg, ctorReg, autoFfi, allProjFqns)
  val pool = poolNew()
  val classFiles = lowerPackage(pkg, pool)
  var j = 0
  while j < classFiles.count {
    val cf = classFiles[j]
    acc.add(BuiltClass(binaryName = cf.thisClass, bytes = serializeClassWithPool(cf, pool)))
    j = j + 1
  }
}

// ── Call-reachability (J1 B-6) ────────────────────────────────────────────
//
// The bundle list (`toBundle`) follows the *import* graph, which over-
// approximates the bytecode actually reached: a package can be imported only
// for its types (or be a dead import, like `Std.Testing`'s `import Std.File`)
// while none of its functions are ever invoked.  A codegen failure in such an
// import-only package must not fail the build — its bytecode is never reached.
//
// Reachability is computed at *function* granularity (matching the JVM's lazy
// per-method linking): a function is reachable when it is called transitively
// from one of the user package's own functions (the program entry points).  We
// resolve each call site to the callee's canonical registry key (`owner/name`)
// using the same two-stage lookup the codegen uses.  A call whose target is not
// in the registry (an extern / auto-FFI call such as a kernel shim's
// `lyric.stdlib.jvm.FileHost.fileExists`) resolves to nothing, so it cannot
// drag a package in via a colliding short name.  A bundled package is then
// "referenced" iff it declares at least one reachable function; only those are
// fatal-on-codegen-failure.  A package whose functions are all unreachable —
// dead imports, type-only imports, or sibling functions never invoked — is
// skipped (advisory) if its codegen fails, because the JAR never links them.
// Canonical registry key (`owner/name`) a call target resolves to, or "" when
// the callee is not a registered Lyric function (extern / auto-FFI / unresolved).
// Mirrors `lowerCall`'s two-stage lookup.  Kept flat (no nested option match)
// to dodge the stage-0 bootstrap emitter's `Map[_, record]` value-threading gap.
func registryKeyOf(registry: in Map[String, JvmFuncSig], key: in String): String {
  match mapGet(registry, key) {
    case Some(sig) -> sig.owner + "/" + lastSegOfKey(key)
    case None -> ""
  }
}

// The substring of a registry key after the last "/", i.e. the function name.
func lastSegOfKey(key: in String): String {
  var lastSlash = -1
  var i = 0
  while i < key.length {
    if key[i] == '/' {
      lastSlash = i
    }
    i = i + 1
  }
  if lastSlash < 0 {
    key
  } else {
    key.substring(lastSlash + 1, key.length)
  }
}

// A package's JVM-internal owner name (segments joined with "/"), matching
// `Jvm.Codegen.segmentsToJvmPath` so it agrees with `JvmFuncSig.owner`.
func pkgJvmOwner(path: in ModulePath): String {
  ownerOfSegments(path.segments, path.segments.count)
}

// Join the first `upTo` segments with "/".
func ownerOfSegments(segments: in List[String], upTo: in Int): String {
  var acc = ""
  var si = 0
  while si < upTo {
    if si > 0 {
      acc = acc + "/"
    }
    acc = acc + segments[si]
    si = si + 1
  }
  acc
}

// Resolve a call target expression `fn` to the callee's canonical registry key
// (`owner/name`), or "" when it is not a registered Lyric function.
func resolveCallKey(fn: in Expr, registry: in Map[String, JvmFuncSig]): String {
  // Peel ETypeApp so explicit generic calls (foo[T](…)) resolve via their inner
  // path rather than falling through to `case _ -> ""` (#2780).
  val inner = match fn.kind { case ETypeApp(f, _) -> f; case _ -> fn }
  match inner.kind {
    case EPath(path) -> {
      if path.segments.count == 0 {
        ""
      } else if path.segments.count > 1 {
        // Qualified call: only the explicit-owner key counts.  A qkey absent
        // from the registry is an extern / non-Lyric FQN, so we do *not* fall
        // back to the bare name (which could mis-resolve a colliding short name
        // such as a kernel shim's `fileExists`).
        val funcName = path.segments[path.segments.count - 1]
        val owner = ownerOfSegments(path.segments, path.segments.count - 1)
        registryKeyOf(registry, owner + "/" + funcName)
      } else {
        registryKeyOf(registry, path.segments[0])
      }
    }
    case EMember(recv, memberName) -> {
      match recv.kind {
        case EPath(rpath) -> registryKeyOf(registry, ownerOfSegments(rpath.segments, rpath.segments.count) + "/" + memberName)
        case _ -> ""
      }
    }
    case _ -> ""
  }
}

// Walk `e`, resolving every call site's owner package into `acc` and recursing.
func collectExprNames(e: in Expr, acc: in List[String], registry: in Map[String, JvmFuncSig]): Unit {
  match e.kind {
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(ex) -> collectExprNames(ex, acc, registry)
          case ISText(_, _) -> ()
        }
        i = i + 1
      }
    }
    case EParen(inner) -> collectExprNames(inner, acc, registry)
    case ETuple(exprs) -> collectExprListNames(exprs, acc, registry)
    case EList(exprs) -> collectExprListNames(exprs, acc, registry)
    case EIf(cond, thenB, elseB, _) -> {
      collectExprNames(cond, acc, registry)
      collectExprOrBlockNames(thenB, acc, registry)
      match elseB {
        case Some(eb) -> collectExprOrBlockNames(eb, acc, registry)
        case None -> ()
      }
    }
    case EMatch(scrut, arms) -> {
      collectExprNames(scrut, acc, registry)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> collectExprNames(g, acc, registry)
          case None -> ()
        }
        collectExprOrBlockNames(arms[i].body, acc, registry)
        i = i + 1
      }
    }
    case EAwait(inner) -> collectExprNames(inner, acc, registry)
    case EYield(inner) -> collectExprNames(inner, acc, registry)
    case ESpawn(inner) -> collectExprNames(inner, acc, registry)
    case ETry(inner) -> collectExprNames(inner, acc, registry)
    case EOld(inner) -> collectExprNames(inner, acc, registry)
    case ELambda(_, body) -> collectBlockNames(body, acc, registry)
    case ECall(fn, args) -> {
      val callKey = resolveCallKey(fn, registry)
      if callKey.length > 0 {
        acc.add(callKey)
      }
      collectExprNames(fn, acc, registry)
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(_, value, _) -> collectExprNames(value, acc, registry)
          case CAPositional(ex) -> collectExprNames(ex, acc, registry)
        }
        i = i + 1
      }
    }
    case ETypeApp(fn, _) -> collectExprNames(fn, acc, registry)
    case EIndex(receiver, indices) -> {
      collectExprNames(receiver, acc, registry)
      collectExprListNames(indices, acc, registry)
    }
    case EMember(recv, _) -> collectExprNames(recv, acc, registry)
    case EPropagate(inner) -> collectExprNames(inner, acc, registry)
    case EPrefix(_, operand) -> collectExprNames(operand, acc, registry)
    case EBinop(_, lhs, rhs) -> {
      collectExprNames(lhs, acc, registry)
      collectExprNames(rhs, acc, registry)
    }
    case EAssign(target, _, value) -> {
      collectExprNames(target, acc, registry)
      collectExprNames(value, acc, registry)
    }
    case EBlock(block) -> collectBlockNames(block, acc, registry)
    case EUnsafe(block) -> collectBlockNames(block, acc, registry)
    case _ -> ()
  }
}

func collectExprListNames(exprs: in List[Expr], acc: in List[String], registry: in Map[String, JvmFuncSig]): Unit {
  var i = 0
  while i < exprs.count {
    collectExprNames(exprs[i], acc, registry)
    i = i + 1
  }
}

func collectExprOrBlockNames(eob: in ExprOrBlock, acc: in List[String], registry: in Map[String, JvmFuncSig]): Unit {
  match eob {
    case EOBExpr(ex) -> collectExprNames(ex, acc, registry)
    case EOBBlock(b) -> collectBlockNames(b, acc, registry)
  }
}

func collectStmtNames(s: in Statement, acc: in List[String], registry: in Map[String, JvmFuncSig]): Unit {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> collectExprNames(init, acc, registry)
        case LBLet(_, _, init) -> collectExprNames(init, acc, registry)
        case LBVar(_, _, init) -> {
          match init {
            case Some(ie) -> collectExprNames(ie, acc, registry)
            case None -> ()
          }
        }
      }
    }
    case SAssign(target, _, value) -> {
      collectExprNames(target, acc, registry)
      collectExprNames(value, acc, registry)
    }
    case SReturn(value) -> match value { case Some(v) -> collectExprNames(v, acc, registry); case None -> () }
    case SThrow(ex) -> collectExprNames(ex, acc, registry)
    case STry(body, catches, finally_) -> {
      collectBlockNames(body, acc, registry)
      var i = 0
      while i < catches.count {
        collectBlockNames(catches[i].body, acc, registry)
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> collectBlockNames(fb, acc, registry)
        case None -> ()
      }
    }
    case SDefer(body) -> collectBlockNames(body, acc, registry)
    case SScope(_, body) -> collectBlockNames(body, acc, registry)
    case SFor(_, _, iter, body) -> {
      collectExprNames(iter, acc, registry)
      collectBlockNames(body, acc, registry)
    }
    case SWhile(_, cond, body) -> {
      collectExprNames(cond, acc, registry)
      collectBlockNames(body, acc, registry)
    }
    case SLoop(_, body) -> collectBlockNames(body, acc, registry)
    case SInvariant(ex) -> collectExprNames(ex, acc, registry)
    case SExpr(ex) -> collectExprNames(ex, acc, registry)
    case SRule(lhs, rhs) -> {
      collectExprNames(lhs, acc, registry)
      collectExprNames(rhs, acc, registry)
    }
    case SItem(it) -> match it.kind {
      // A nested function's body calls count toward the enclosing function for
      // reachability (the JVM lowers them into the same class either way).
      case IFunc(decl) -> match decl.body { case Some(fb) -> match fb { case FBExpr(ex) -> collectExprNames(ex, acc, registry); case FBBlock(b) -> collectBlockNames(b, acc, registry) }; case None -> () }
      case _ -> ()
    }
    case _ -> ()
  }
}

func collectBlockNames(b: in Block, acc: in List[String], registry: in Map[String, JvmFuncSig]): Unit {
  var i = 0
  while i < b.statements.count {
    collectStmtNames(b.statements[i], acc, registry)
    i = i + 1
  }
}

// Canonical registry keys (`owner/name`) of every Lyric function `decl`'s
// body calls.
func collectFuncCallKeys(decl: in FunctionDecl, registry: in Map[String, JvmFuncSig]): List[String] {
  val acc: List[String] = newList()
  match decl.body {
    case Some(fb) -> match fb { case FBExpr(ex) -> collectExprNames(ex, acc, registry); case FBBlock(b) -> collectBlockNames(b, acc, registry) }
    case None -> ()
  }
  acc
}

// Detect a derive-synthesised free-function name: `deriveFile` emits names of
// the form `TypeName.method` (e.g. `Point.equals`, `Color.show`), which always
// contain a dot.  Bare names (e.g. `classify`, `main`) are not derive-free.
func isDeriveFreeName(name: in String): Bool {
  match lastIndexOf(name, ".") {
    case Some(_) -> true
    case None -> false
  }
}

// Register IFunc items whose name contains a "." — the `TypeName.method` form
// that `deriveFile` synthesises for `@derive(Equals/Show/Hash/Ord)` free
// functions (e.g. `Point.equals`, `Color.show`).  Called after `runMiddleEnd`
// to patch the registry built from the pre-derive `userFile` (#3139).
// Only processes new keys (first-wins guard, same as `collectFileSigs`).
func collectDeriveFreeSigs(file: in SourceFile, into: in Map[String, JvmFuncSig]): Unit {
  val owner = pkgJvmOwner(file.packageDecl.path)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        if isDeriveFreeName(decl.name) {
          val params: List[JvmType] = newList()
          val paramNames: List[String] = newList()
          var pi = 0
          while pi < decl.params.count {
            params.add(typeExprToJvm(decl.params[pi].ty, owner))
            paramNames.add(decl.params[pi].name)
            pi = pi + 1
          }
          val ret = match decl.ret { case Some(te) -> typeExprToJvm(te, owner); case None -> JVoid }
          // paramDefaults intentionally empty: derive-synthesized free functions have
          // no default values.  Using an empty list avoids the stage-0 bootstrap
          // List[Option[Expr]] miscompile on .add() (#3139).
          val sig = JvmFuncSig(owner = owner, params = params, ret = ret, paramNames = paramNames, paramDefaults = newList())
          val qkey = owner + "/" + decl.name
          if not into.containsKey(qkey) {
            into.add(qkey, sig)
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

// Back-compat forwarder: no feature flags, so no `@cfg` erasure runs.  Callers
// that thread a manifest's `[features]` table (the in-process CLI path) use
// `compileToJarBundledWithFeatures`.
pub func compileToJarBundled(
  source: in String,
  outputPath: in String,
  packageName: in String,
  stdlibSources: in List[String],
): Bool {
  val noFeatures: List[String] = newList()
  compileToJarBundledWithFeatures(source, outputPath, packageName, stdlibSources, noFeatures, noFeatures)
}

/// Like `compileToJarBundled` but threads `activeFeatures` / `declaredFeatures`
/// through `Lyric.Cfg.applyCfgErasure` before type-check (M-4; parity with the
/// MSIL bridge's `compileProjectToMsilWithFeatures`).  Items in the user package
/// annotated `@cfg(feature = "X")` where `X` is absent from `activeFeatures`
/// are erased; an annotation naming a feature absent from `declaredFeatures`
/// (when the declared set is non-empty) raises an `F0013` typo warning.
pub func compileToJarBundledWithFeatures(
  source: in String,
  outputPath: in String,
  packageName: in String,
  stdlibSources: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
): Bool {
  val parseResult = parse(source)
  if reportAndAbort(parseResult.diagnostics) {
    return false
  }
  match mainReturns2SlotType(parseResult.file) {
    case Some(ty) -> {
      Console.error("error[J001]: `func main(): " + ty + "` is not supported on the JVM target")
      Console.error("  hint: use `func main(): Int` (exit code) or `func main(): Unit`")
      return false
    }
    case None -> ()
  }
  // `@cfg`-driven erasure before `@stubbable` synthesis and type-check (M-4):
  // drop user-package items gated on inactive features so the rest of the
  // pipeline never sees them.  Mirrors the MSIL bridge, which runs cfg erasure
  // on each user package immediately after parse.
  val cfgRes = Cfg.applyCfgErasure(activeFeatures, declaredFeatures, parseResult.file)
  if reportAndAbort(cfgRes.diagnostics) {
    return false
  }
  // `@stubbable` synthesis before type-check (parity with the MSIL bridge).
  val userFile = Stubbable.stubbableRewriteFile(cfgRes.file)

  // Parse every stdlib source once: collect its type items (for cross-package
  // type resolution) and index the whole file by dotted package name (for the
  // import-closure walk below).
  // Type items grouped by declaring package (see `compileToJar` for the
  // RegexError collision this scope-aware grouping fixes).
  val importedPkgs: List[ImportedPackage] = newList()
  val stdlibFiles: List[SourceFile] = newList()
  val stdlibByPkg: Map[String, SourceFile] = newMap()
  var si = 0
  while si < stdlibSources.count {
    val pr = parse(stdlibSources[si])
    // Stdlib parse diagnostics are advisory and never gate the bundle (only the
    // user file's parse and the per-package codegen are fatal).  Echoing them
    // here leaked self-hosted-parser-gap noise (e.g. `spawn`/`var` keyword
    // P0051s from std/process.l) onto every successful JVM build's output;
    // suppress it so a clean build stays clean.
    val pkgItems: List[Item] = newList()
    var ii = 0
    while ii < pr.file.items.count {
      if isTypeItem(pr.file.items[ii]) {
        pkgItems.add(pr.file.items[ii])
      }
      ii = ii + 1
    }
    val pn = dottedPath(pr.file.packageDecl.path)
    importedPkgs.add(ImportedPackage(name = pn, items = pkgItems))
    stdlibFiles.add(pr.file)
    if pn.length > 0 and not stdlibByPkg.containsKey(pn) {
      stdlibByPkg.add(pn, pr.file)
    }
    si = si + 1
  }

  // Build the cross-package call registry across the user file and *every*
  // stdlib file (resolution is cheap and harmless for packages we don't bundle).
  val registry: Map[String, JvmFuncSig] = newMap()
  collectFileSigs(userFile, registry)
  val caseReg: Map[String, List[JvmCaseField]] = newMap()
  collectFileCases(userFile, caseReg)
  val ctorReg: Map[String, String] = newMap()
  collectFileCtors(userFile, ctorReg)
  // #3044: complete @projectable pre-scan across the whole compilation, so
  // nested-view substitution / tryInto() eligibility see every projectable
  // regardless of declaration or package order (JVM counterpart of the MSIL
  // `prescanProjectableFqns`).
  val allProjFqns: Map[String, Bool] = newMap()
  collectFileProjectables(userFile, allProjFqns)
  var ri = 0
  while ri < stdlibFiles.count {
    collectFileSigs(stdlibFiles[ri], registry)
    collectFileCases(stdlibFiles[ri], caseReg)
    collectFileCtors(stdlibFiles[ri], ctorReg)
    collectFileProjectables(stdlibFiles[ri], allProjFqns)
    ri = ri + 1
  }
  // View-twin registration must run after the pre-scan is complete (the
  // substituted view field types depend on the full projectable set).
  registerProjectableViews(userFile, allProjFqns, caseReg, registry)
  var rvi = 0
  while rvi < stdlibFiles.count {
    registerProjectableViews(stdlibFiles[rvi], allProjFqns, caseReg, registry)
    rvi = rvi + 1
  }

  // Transitive import closure: the stdlib packages whose bytecode must be
  // bundled because the user (directly or indirectly) imports them.
  val toBundle: List[SourceFile] = newList()
  val seen: Map[String, Bool] = newMap()
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
        case None -> ()
        // Genuinely unreached / unavailable: a builtin head (`Std.*`
        // resolved by the emitter, `Lyric.*` compiler packages) or a
        // package with no in-bundle source.  Nothing to bundle, so no
        // codegen runs for it and a failure can never be masked here.
        // This `None` arm is the only "skip" path; every package that
        // *does* have source is bundled and its codegen failure is fatal.
      }
    }
  }

  // ── Call-reachability fixpoint (J1 B-6, #2664) ──────────────────────────
  // Build a function-level call graph over the user package plus every bundled
  // package: each function's canonical key (`owner/name`) maps to the keys of
  // the functions it calls.  Mark every function in the *user* package as a
  // root (entry points — `main`, the synthesised `lyric test` runners) and
  // close the reachable set transitively.  A bundled package is "referenced"
  // iff at least one of its declared functions is reachable; only those are
  // fatal-on-codegen-failure.  This matches the JVM's lazy per-method linking:
  // a never-invoked sibling function (e.g. `Std.Hash.sha512OfFile` pulling in
  // `Std.FileHost` when only `sha512OfBytes` is called) does not make its
  // callee package "referenced".
  val callGraph: Map[String, List[String]] = newMap()
  val reachableFns: Map[String, Bool] = newMap()
  val fnWorklist: List[String] = newList()

  // User package: every top-level function is a root.
  val userOwner = pkgJvmOwner(userFile.packageDecl.path)
  var gi = 0
  while gi < userFile.items.count {
    match userFile.items[gi].kind {
      case IFunc(decl) -> {
        val selfKey = userOwner + "/" + decl.name
        if not callGraph.containsKey(selfKey) {
          callGraph.add(selfKey, collectFuncCallKeys(decl, registry))
        }
        if not reachableFns.containsKey(selfKey) {
          reachableFns.add(selfKey, true)
          fnWorklist.add(selfKey)
        }
      }
      case _ -> ()
    }
    gi = gi + 1
  }

  // Bundled packages: index their functions' outgoing calls (not roots).
  var bgi = 0
  while bgi < toBundle.count {
    val bf = toBundle[bgi]
    val bOwner = pkgJvmOwner(bf.packageDecl.path)
    var bii = 0
    while bii < bf.items.count {
      match bf.items[bii].kind {
        case IFunc(decl) -> {
          val selfKey = bOwner + "/" + decl.name
          if not callGraph.containsKey(selfKey) {
            callGraph.add(selfKey, collectFuncCallKeys(decl, registry))
          }
        }
        case _ -> ()
      }
      bii = bii + 1
    }
    bgi = bgi + 1
  }

  // Transitive closure over the call graph.
  var wfi = 0
  while wfi < fnWorklist.count {
    val cur = fnWorklist[wfi]
    wfi = wfi + 1
    match mapGet(callGraph, cur) {
      case Some(callees) -> {
        var ci = 0
        while ci < callees.count {
          val callee = callees[ci]
          if not reachableFns.containsKey(callee) {
            reachableFns.add(callee, true)
            fnWorklist.add(callee)
          }
          ci = ci + 1
        }
      }
      case None -> ()
    }
  }

  // A bundled package is referenced iff one of its functions is reachable.
  val referencedPkgs: Map[String, Bool] = newMap()
  var rpi = 0
  while rpi < toBundle.count {
    val rf = toBundle[rpi]
    val rOwner = pkgJvmOwner(rf.packageDecl.path)
    if not referencedPkgs.containsKey(rOwner) {
      var rii = 0
      var anyReachable = false
      while rii < rf.items.count {
        match rf.items[rii].kind {
          case IFunc(decl) -> {
            if reachableFns.containsKey(rOwner + "/" + decl.name) {
              anyReachable = true
            }
          }
          case _ -> ()
        }
        rii = rii + 1
      }
      if anyReachable {
        referencedPkgs.add(rOwner, true)
      }
    }
    rpi = rpi + 1
  }

  val autoFfi = buildAutoFfiCtx()
  val allClasses: List[BuiltClass] = newList()

  // Stdlib pure-Lyric generic `pub func`s, fed to each package's monomorphizer
  // so cross-package generic calls (`mapGet`, `unwrapOr`, …) specialise into
  // this bundle instead of erasing their generic return (M-5; parity with the
  // MSIL bridge's `collectStdlibGenericFuncs`).
  val stdlibGenFuncs = collectStdlibGenericFuncsJvm(stdlibFiles)

  // User package first (its codegen failing is always fatal).  Its type-check
  // advisories are echoed (they are about the program the user actually wrote).
  match runMiddleEnd(userFile, importedPkgs, stdlibGenFuncs, true) {
    case Some(f) -> {
      // Register sigs synthesised by `deriveFile` (inside `runMiddleEnd`) so
      // that call-site resolution in `codegenPackageInto` can find them.  The
      // `collectFileSigs(userFile, registry)` above ran on the pre-derive file
      // and therefore missed free functions like `Point.equals` / `Color.show`,
      // causing the call sites to fall through to the `invokevirtual Object`
      // guess — a NoSuchMethodError at runtime (#3139).
      // Use the narrow `collectDeriveFreeSigs` (only `.`-named items) rather
      // than the full `collectFileSigs` to avoid the stage-0 bootstrap
      // List[Option[Expr]] miscompile on paramDefaults.add().
      collectDeriveFreeSigs(f, registry)
      codegenPackageInto(f, registry, caseReg, ctorReg, autoFfi, allProjFqns, allClasses)
    }
    case None -> return false
  }

  // For every bundled package, a codegen failure is **fatal** when the package
  // is call-reachable — i.e. the program actually invokes one of its functions
  // — because the resulting JAR would otherwise throw NoSuchMethodError at
  // runtime instead of failing the build.  The catch surfaces the panic's
  // message, which names the failing symbol / declaration / construct (e.g.
  // "Jvm.Codegen: EForall not supported in JVM codegen"), so the build points at
  // the exact lowering gap.  A package that is imported only for its types (or
  // dead-imported) and never called is *not* call-reachable: its bytecode is
  // never invoked, so a codegen failure for it is skipped silently.  Bundled
  // packages pass `reportTcAdvisories = false`: their advisory type-check noise
  // (the self-hosted checker lacks full builtin coverage) is suppressed so a
  // successful build does not print self-hosted-coverage-gap noise from
  // unrelated stdlib code.  Real errors still surface — referenced-package
  // codegen panics are echoed via the fatal J002 path below.
  var bi = 0
  var skippedCount = 0
  while bi < toBundle.count {
    val f = toBundle[bi]
    val pkgName = dottedPath(f.packageDecl.path)
    val reachable = referencedPkgs.containsKey(pkgJvmOwner(f.packageDecl.path))
    val ok = try {
      match runMiddleEnd(f, importedPkgs, stdlibGenFuncs, false) {
        case Some(ff) -> {
          codegenPackageInto(ff, registry, caseReg, ctorReg, autoFfi, allProjFqns, allClasses)
          true
        }
        // A fatal middle-end diagnostic (already reported) aborts the build only
        // when the package is actually called; an imported-only package whose
        // middle-end fails is skipped (its bytecode is never invoked).
        case None -> not reachable
      }
    } catch Bug as b {
      if reachable {
        Console.error("error[J002]: JVM codegen failed for referenced package '" + pkgName + "': " + b.message)
        Console.error(
          "  this package's functions are called by the program, so it must compile; " +
            "the failure above names the symbol or construct the JVM backend could not lower"
        )
        false
      } else {
        // Unreached package whose codegen failed: not a build error because its
        // bytecode is never invoked, but counted so we can surface a summary note
        // pointing users toward the root cause if they hit a runtime failure.
        skippedCount = skippedCount + 1
        true
      }
    }
    if not ok {
      return false
    }
    bi = bi + 1
  }
  if skippedCount > 0 {
    Console.error(
      "note[J003]: " + skippedCount.toString() + " stdlib package(s) could not be bundled (JVM backend gap); " +
        "runtime calls into them will fail with NoClassDefFoundError — " +
        "if that happens, please file an issue"
    )
  }

  // Main-Class from the user package declaration.
  val segs = userFile.packageDecl.path.segments
  var mainClassName: String = packageName
  if segs.count > 0 {
    mainClassName = dottedPath(userFile.packageDecl.path)
  }

  val req = BuildRequest(packageName = packageName, mainClass = mainClassName, version = "0.1.0", outPath = outputPath)
  writeJarFromClasses(req, allClasses)
}
