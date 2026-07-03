//! llvm/bridge.l — Lyric.LlvmBridge: the native compilation pipeline (N6.1).
//!
//! Public entry point that chains the self-hosted front/middle end to a
//! runnable native binary: parse → cfg erasure (target.native) → alias
//! rewrite → typecheck (advisory) → modecheck → contract elaboration →
//! `?`-propagation → derives → mono → weave → reachability over the
//! bundled stdlib → `Lyric.LlvmCodegen.codegenNativeBundle` →
//! `Lyric.LlvmLowering.lowerNativePackage` → write `.ll` → clang (D-N-001).
//!
//! Bundling model: like `Jvm.Bridge.compileToJarBundled`, the user
//! package plus the transitive closure of its stdlib imports compile
//! into ONE module — but at *function* granularity: only functions
//! reachable from the user package's own functions are lowered, so a
//! stdlib package whose unreached functions use not-yet-lowered
//! constructs (records, match, generics) does not block a scalar
//! program.  A reachable function that the Phase N1 codegen cannot
//! lower fails the build with a construct-naming diagnostic.
//!
//! clang is the universal driver (D-N-001/D-N-009): it optimises,
//! assembles, and links `lyric_rt.a` + libm + libpthread.  When clang
//! is missing the `.ll` is left next to the requested output and the
//! diagnostic names it, so the user can drive clang manually.
package Lyric.LlvmBridge

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.ModeChecker
import Lyric.ContractElaborator
import Lyric.Propagate
import Lyric.Cfg as Cfg
import Lyric.AliasRewriter as Aliases
import Lyric.Weaver as Weaver
import Lyric.DiagnosticUtil as DiagUtil
import Lyric.Mono
import Lyric.Derives
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.LlvmCodegen
import Lyric.LlvmLowering

func reportAndAbort(diags: in List[Diagnostic]): Bool {
  DiagUtil.diagReportAndAbort(diags)
}

func reportDiagnostics(diags: in List[Diagnostic]): Unit {
  DiagUtil.diagReport(diags)
}

func dottedPath(path: in ModulePath): String {
  modulePathJoin(path.segments)
}

// True for top-level items that must reach packages importing this one
// (types, pub module vals, and pub funcs) so cross-package names
// resolve during the advisory typecheck — without the pub funcs every
// stdlib call in user code prints a spurious T0020 on a successful
// build.  Extends `Jvm.Bridge.isTypeItem` with the pub-func rule from
// `Msil.Bridge.collectStdlibPackages`.
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
    case IExternType(_) -> true
    case IProtected(_) -> true
    case IImpl(_) -> true
    case _ -> false
  }
  if isType {
    return true
  }
  match it.kind {
    case IVal(_) -> match it.visibility { case Some(vis) -> match vis { case VisPub(_) -> true; case _ -> false }; case None -> false }
    case IFunc(decl) -> match decl.visibility { case Some(vis) -> match vis { case VisPub(_) -> true; case _ -> false }; case None -> false }
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §1. Reachability walk (function granularity).
// ─────────────────────────────────────────────────────────────────────────────
// Collect the `callKeyOf` key of every call site in an expression tree.
func collectCallKeys(e: in Expr, acc: in List[String]): Unit {
  match e.kind {
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(ex) -> collectCallKeys(ex, acc)
          case ISText(_, _) -> {
          }
        }
        i = i + 1
      }
    }
    case EParen(inner) -> collectCallKeys(inner, acc)
    case ETuple(exprs) -> collectExprListKeys(exprs, acc)
    case EList(exprs) -> collectExprListKeys(exprs, acc)
    case EIf(cond, thenB, elseB, _) -> {
      collectCallKeys(cond, acc)
      collectEobKeys(thenB, acc)
      match elseB {
        case Some(eb) -> collectEobKeys(eb, acc)
        case None -> {
        }
      }
    }
    case EMatch(scrut, arms) -> {
      collectCallKeys(scrut, acc)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> collectCallKeys(g, acc)
          case None -> {
          }
        }
        collectEobKeys(arms[i].body, acc)
        i = i + 1
      }
    }
    case EAwait(inner) -> collectCallKeys(inner, acc)
    case EYield(inner) -> collectCallKeys(inner, acc)
    case ESpawn(inner) -> collectCallKeys(inner, acc)
    case ETry(inner) -> collectCallKeys(inner, acc)
    case EOld(inner) -> collectCallKeys(inner, acc)
    case ELambda(_, body) -> collectBlockKeys(body, acc)
    case ECall(fn, args) -> {
      val key = callKeyOf(fn, args.count)
      if key.length > 0 {
        acc.add(key)
      }
      // A method-call receiver is an expression too (scalar methods
      // resolve without the registry, so an unresolvable key is fine).
      match fn.kind {
        case EMember(recv, _) -> collectCallKeys(recv, acc)
        case _ -> {
        }
      }
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(_, value, _) -> collectCallKeys(value, acc)
          case CAPositional(ex) -> collectCallKeys(ex, acc)
        }
        i = i + 1
      }
    }
    case ETypeApp(fn, _) -> collectCallKeys(fn, acc)
    case EIndex(receiver, indices) -> {
      collectCallKeys(receiver, acc)
      collectExprListKeys(indices, acc)
    }
    case EMember(recv, _) -> collectCallKeys(recv, acc)
    case EPropagate(inner) -> collectCallKeys(inner, acc)
    case EPrefix(_, operand) -> collectCallKeys(operand, acc)
    case EBinop(_, lhs, rhs) -> {
      collectCallKeys(lhs, acc)
      collectCallKeys(rhs, acc)
    }
    case EAssign(target, _, value) -> {
      collectCallKeys(target, acc)
      collectCallKeys(value, acc)
    }
    case EBlock(block) -> collectBlockKeys(block, acc)
    case EUnsafe(block) -> collectBlockKeys(block, acc)
    case _ -> {
    }
  }
}

func collectExprListKeys(exprs: in List[Expr], acc: in List[String]): Unit {
  var i = 0
  while i < exprs.count {
    collectCallKeys(exprs[i], acc)
    i = i + 1
  }
}

func collectEobKeys(eob: in ExprOrBlock, acc: in List[String]): Unit {
  match eob {
    case EOBExpr(ex) -> collectCallKeys(ex, acc)
    case EOBBlock(b) -> collectBlockKeys(b, acc)
  }
}

func collectStmtKeys(s: in Statement, acc: in List[String]): Unit {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> collectCallKeys(init, acc)
        case LBLet(_, _, init) -> collectCallKeys(init, acc)
        case LBVar(_, _, init) -> {
          match init {
            case Some(ie) -> collectCallKeys(ie, acc)
            case None -> {
            }
          }
        }
      }
    }
    case SAssign(target, _, value) -> {
      collectCallKeys(target, acc)
      collectCallKeys(value, acc)
    }
    case SReturn(value) -> match value { case Some(v) -> collectCallKeys(v, acc); case None -> () }
    case SThrow(ex) -> collectCallKeys(ex, acc)
    case STry(body, catches, finally_) -> {
      collectBlockKeys(body, acc)
      var i = 0
      while i < catches.count {
        collectBlockKeys(catches[i].body, acc)
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> collectBlockKeys(fb, acc)
        case None -> {
        }
      }
    }
    case SDefer(body) -> collectBlockKeys(body, acc)
    case SScope(_, body) -> collectBlockKeys(body, acc)
    case SFor(_, _, iter, body) -> {
      collectCallKeys(iter, acc)
      collectBlockKeys(body, acc)
    }
    case SWhile(_, cond, body) -> {
      collectCallKeys(cond, acc)
      collectBlockKeys(body, acc)
    }
    case SLoop(_, body) -> collectBlockKeys(body, acc)
    case SInvariant(ex) -> collectCallKeys(ex, acc)
    case SExpr(ex) -> collectCallKeys(ex, acc)
    case SRule(lhs, rhs) -> {
      collectCallKeys(lhs, acc)
      collectCallKeys(rhs, acc)
    }
    case SItem(it) -> {
      match it.kind {
        case IFunc(decl) -> collectFnBodyKeys(decl, acc)
        case _ -> {
        }
      }
    }
    case _ -> {
    }
  }
}

func collectBlockKeys(b: in Block, acc: in List[String]): Unit {
  var i = 0
  while i < b.statements.count {
    collectStmtKeys(b.statements[i], acc)
    i = i + 1
  }
}

func collectFnBodyKeys(decl: in FunctionDecl, acc: in List[String]): Unit {
  match decl.body {
    case Some(fb) -> {
      match fb {
        case FBExpr(ex) -> collectCallKeys(ex, acc)
        case FBBlock(b) -> collectBlockKeys(b, acc)
      }
    }
    case None -> {
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Runtime archive + clang discovery.
// ─────────────────────────────────────────────────────────────────────────────
func walkUpFor(start: in String, rel: in String): String {
  if start.length == 0 {
    return ""
  }
  var dir = start
  var hop = 0
  while hop < 32 {
    val candidate = Path.join(dir, rel)
    if File.fileExists(candidate) {
      return candidate
    }
    val parent = Path.dirname(dir)
    if parent.length == 0 or parent == dir {
      return ""
    }
    dir = parent
    hop = hop + 1
  }
  ""
}

/// Locate `lyric_rt.a` (D-N-009): `$LYRIC_RT_PATH` override, the
/// installed layout (`<bin>/lib/`, `<bin>/`), then the dev layout
/// (`lyric-rt/build/lyric_rt.a` walking up from the binary and the CWD).
pub func findLyricRtArchive(): String {
  val envOverride = Environment.getVarOrDefault("LYRIC_RT_PATH", "")
  if envOverride.length > 0 and File.fileExists(envOverride) {
    return envOverride
  }
  val appBase = Environment.appBaseDirectory()
  val installedLib = Path.join(Path.join(appBase, "lib"), "lyric_rt.a")
  if File.fileExists(installedLib) {
    return installedLib
  }
  val beside = Path.join(appBase, "lyric_rt.a")
  if File.fileExists(beside) {
    return beside
  }
  val devRel = Path.join(Path.join("lyric-rt", "build"), "lyric_rt.a")
  var hit = walkUpFor(appBase, devRel)
  if hit.length > 0 {
    return hit
  }
  walkUpFor(Environment.currentDirectory(), devRel)
}

/// The host triple from `clang -print-effective-triple`, or "" when
/// clang is unavailable.
func detectHostTriple(): String {
  val args: List[String] = newList()
  args.add("-print-effective-triple")
  match Process.runCapture("clang", args, 30000) {
    case Ok(res) -> {
      if res.exitCode == 0 {
        Str.trim(res.stdout)
      } else {
        ""
      }
    }
    case Err(_) -> ""
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Public entry point.
// ─────────────────────────────────────────────────────────────────────────────
/// Compile `source` to a native executable at `outputPath`.
///
/// `stdlibSources` are the pre-read stdlib `.l` texts (native-kernel
/// variant — see `Lyric.Emitter.findStdlibSourcesNative`).  `triple` ""
/// means "the host triple per clang"; `optLevel` "" defaults to "2".
/// Returns true when the binary was produced.
pub func compileToNative(
  source: in String,
  outputPath: in String,
  stdlibSources: in List[String],
  triple: in String,
  optLevel: in String,
): Bool {
  val noFlags: List[String] = newList()
  compileToNativeWithFlags(source, outputPath, stdlibSources, triple, optLevel, noFlags)
}

/// `compileToNative` with extra clang driver flags (e.g.
/// `-fsanitize=address` for the sanitizer-checked self-tests).
pub func compileToNativeWithFlags(
  source: in String,
  outputPath: in String,
  stdlibSources: in List[String],
  triple: in String,
  optLevel: in String,
  extraClangFlags: in List[String],
): Bool {
  val parseResult = parse(source)
  if reportAndAbort(parseResult.diagnostics) {
    return false
  }

  val noFeatures: List[String] = newList()
  val nativeFeatures = Cfg.withTargetFeature(noFeatures, "native")
  val cfgRes = Cfg.applyCfgErasure(nativeFeatures, noFeatures, parseResult.file)
  if reportAndAbort(cfgRes.diagnostics) {
    return false
  }
  val userFile0 = Aliases.rewriteFile(cfgRes.file)

  // Parse the stdlib once: type items for the advisory typecheck,
  // whole files (cfg-erased, alias-rewritten) for bundling.
  val importedPkgs: List[ImportedPackage] = newList()
  val stdlibByPkg: Map[String, SourceFile] = newMap()
  var si = 0
  while si < stdlibSources.count {
    val pr = parse(stdlibSources[si])
    // Stdlib parse diagnostics are advisory (self-hosted parser gaps
    // vs. the stdlib tree must not block user builds — see the
    // matching note in Jvm.Bridge).
    val stdCfg = Cfg.applyCfgErasure(nativeFeatures, noFeatures, pr.file)
    val stdFile = Aliases.rewriteFile(stdCfg.file)
    val pkgItems: List[Item] = newList()
    var ii = 0
    while ii < stdFile.items.count {
      if isTypeItem(stdFile.items[ii]) {
        pkgItems.add(stdFile.items[ii])
      }
      ii = ii + 1
    }
    val pn = dottedPath(stdFile.packageDecl.path)
    importedPkgs.add(ImportedPackage(name = pn, items = pkgItems, imports = collectImportNames(stdFile.imports)))
    if pn.length > 0 and not stdlibByPkg.containsKey(pn) {
      stdlibByPkg.add(pn, stdFile)
    }
    si = si + 1
  }

  // Advisory typecheck (the self-hosted checker lacks full builtin
  // coverage); the mode check gates.
  val tcRes = checkWithImportedPackages(userFile0, importedPkgs)
  reportDiagnostics(tcRes.diagnostics)
  val mcRes = checkFile(userFile0)
  if reportAndAbort(mcRes.diagnostics) {
    return false
  }

  // Middle end on the user file.
  val elaborated = elaborateFile(userFile0)
  val propRes = lowerPropagateFile(elaborated)
  if reportAndAbort(propRes.diagnostics) {
    return false
  }
  val derived = deriveFile(propRes.file)
  val monoRes = monoFile(derived)
  if reportAndAbort(monoRes.diagnostics) {
    return false
  }
  val weaveRes = Weaver.weaveFileWithDiags(monoRes.file)
  if reportAndAbort(weaveRes.diagnostics) {
    return false
  }
  val userFile = weaveRes.file
  val userPkg = dottedPath(userFile.packageDecl.path)

  // Transitive stdlib import closure, in deterministic worklist order.
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
          // Contracts in bundled packages lower to runtime asserts the
          // same way the user file's do.
          toBundle.add(elaborateFile(f))
          var fi = 0
          while fi < f.imports.count {
            worklist.add(dottedPath(f.imports[fi].path))
            fi = fi + 1
          }
        }
        case None -> {
        }
      }
    }
  }

  // Function-granularity reachability: canonical id = "Pkg.name/arity".
  // `resolve` mirrors the codegen's two-step lookup (caller-package
  // qualified first, then the key as written).
  val canonical: Map[String, String] = newMap()
  registerFileFns(userFile, canonical)
  var bi = 0
  while bi < toBundle.count {
    registerFileFns(toBundle[bi], canonical)
    bi = bi + 1
  }

  val reachable: Map[String, Bool] = newMap()
  val fnWorklist: List[String] = newList()
  var gi = 0
  while gi < userFile.items.count {
    match userFile.items[gi].kind {
      case IFunc(decl) -> {
        val selfId = userPkg + "." + decl.name + "/" + decl.params.count.toString()
        if not reachable.containsKey(selfId) {
          reachable.add(selfId, true)
          fnWorklist.add(selfId)
        }
      }
      case _ -> {
      }
    }
    gi = gi + 1
  }
  // Bodies indexed by canonical id so the walk can chase callees.
  val bodyIndex: Map[String, FunctionDecl] = newMap()
  val pkgOfId: Map[String, String] = newMap()
  indexFileFns(userFile, bodyIndex, pkgOfId)
  var bi2 = 0
  while bi2 < toBundle.count {
    indexFileFns(toBundle[bi2], bodyIndex, pkgOfId)
    bi2 = bi2 + 1
  }
  var wfi = 0
  while wfi < fnWorklist.count {
    val cur = fnWorklist[wfi]
    wfi = wfi + 1
    val curPkg = match mapGet(pkgOfId, cur) { case Some(p) -> p; case None -> "" }
    match mapGet(bodyIndex, cur) {
      case Some(decl) -> {
        val keys: List[String] = newList()
        collectFnBodyKeys(decl, keys)
        var ki = 0
        while ki < keys.count {
          val raw = keys[ki]
          ki = ki + 1
          var target = ""
          if curPkg.length > 0 {
            match mapGet(canonical, curPkg + "." + raw) {
              case Some(t) -> {
                target = t
              }
              case None -> {
              }
            }
          }
          if target.length == 0 {
            match mapGet(canonical, raw) {
              case Some(t) -> {
                target = t
              }
              case None -> {
              }
            }
          }
          if target.length > 0 and not reachable.containsKey(target) {
            reachable.add(target, true)
            fnWorklist.add(target)
          }
        }
      }
      case None -> {
      }
    }
  }

  // Assemble the codegen units: the user package in full, then each
  // bundled package's reachable slice.
  val units: List[CodegenUnit] = newList()
  units.add(unitOf(userFile, reachable, true))
  var bi3 = 0
  while bi3 < toBundle.count {
    val u = unitOf(toBundle[bi3], reachable, false)
    // A unit with no reachable functions still contributes its type
    // declarations (e.g. Std.Core's Result/Option are referenced by
    // other packages' signatures without any Std.Core call).
    if u.fns.count > 0 or u.externs.count > 0 or u.records.count > 0 or u.unions.count > 0 or u.enums.count > 0 or u.distincts.count > 0 {
      units.add(u)
    }
    bi3 = bi3 + 1
  }

  // Resolve the target triple before codegen (the datalayout depends
  // on it).
  var effTriple = triple
  if effTriple.length == 0 {
    effTriple = detectHostTriple()
  }

  val npkg = codegenNativeBundle(units, effTriple)
  val ll = lowerNativePackage(npkg)

  val llPath = outputPath + ".ll"
  match File.writeText(llPath, ll) {
    case Ok(_) -> {
    }
    case Err(e) -> {
      Console.error("error[N0002]: cannot write LLVM IR to " + llPath + ": " + IOError.message(e))
      return false
    }
  }

  val rtPath = findLyricRtArchive()
  if rtPath.length == 0 {
    Console.error("error[N0003]: lyric_rt.a not found (set LYRIC_RT_PATH, or build it with `make -C lyric-rt`)")
    Console.error("  the LLVM IR was written to " + llPath)
    return false
  }

  val effOpt = if optLevel.length > 0 { optLevel } else { "2" }
  val clangArgs: List[String] = newList()
  clangArgs.add("-O" + effOpt)
  var xi = 0
  while xi < extraClangFlags.count {
    clangArgs.add(extraClangFlags[xi])
    xi = xi + 1
  }
  if triple.length > 0 {
    clangArgs.add("--target=" + triple)
  }
  clangArgs.add(llPath)
  clangArgs.add(rtPath)
  clangArgs.add("-lm")
  clangArgs.add("-lpthread")
  var li = 0
  while li < npkg.nativeLibs.count {
    clangArgs.add("-l" + npkg.nativeLibs[li])
    li = li + 1
  }
  clangArgs.add("-o")
  clangArgs.add(outputPath)
  match Process.runCapture("clang", clangArgs, 300000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        Console.error("error[N0004]: clang failed while compiling " + llPath + ":")
        Console.error(res.stderr)
        return false
      }
    }
    case Err(e) -> {
      Console.error(
        "error[N0001]: clang was not found on PATH (install it via your platform's package manager: `apt install clang`, Xcode CLI tools, ...)"
      )
      Console.error("  the LLVM IR was written to " + llPath + "; compile it manually with:")
      Console.error("  clang -O" + effOpt + " " + llPath + " " + rtPath + " -lm -lpthread -o " + outputPath)
      Console.error("  (" + e + ")")
      return false
    }
  }
  // Keep the workspace clean on success; the .ll is a build
  // intermediate (re-emit with a failing clang run or via LYRIC_RT_PATH
  // tricks when debugging).
  match File.deleteFile(llPath) {
    case Ok(_) -> {
    }
    case Err(_) -> {
    }
  }
  true
}

func registerFileFns(f: in SourceFile, canonical: in Map[String, String]): Unit {
  val pkg = dottedPath(f.packageDecl.path)
  var i = 0
  while i < f.items.count {
    match f.items[i].kind {
      case IFunc(decl) -> {
        val id = pkg + "." + decl.name + "/" + decl.params.count.toString()
        addKey(canonical, id, id)
        addKey(canonical, decl.name + "/" + decl.params.count.toString(), id)
      }
      case IExternFunc(decl) -> {
        val id = pkg + "." + decl.name + "/" + decl.params.count.toString()
        addKey(canonical, id, id)
        addKey(canonical, decl.name + "/" + decl.params.count.toString(), id)
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

func addKey(m: in Map[String, String], k: in String, v: in String): Unit {
  if not m.containsKey(k) {
    m.add(k, v)
  }
}

func indexFileFns(f: in SourceFile, bodyIndex: in Map[String, FunctionDecl], pkgOfId: in Map[String, String]): Unit {
  val pkg = dottedPath(f.packageDecl.path)
  var i = 0
  while i < f.items.count {
    match f.items[i].kind {
      case IFunc(decl) -> {
        val id = pkg + "." + decl.name + "/" + decl.params.count.toString()
        if not bodyIndex.containsKey(id) {
          bodyIndex.add(id, decl)
          pkgOfId.add(id, pkg)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// One package's codegen unit.  `lowerAll` (the user package) takes every
// function; bundled packages take only the reachable ones.  Extern
// funcs follow the same rule (an undeclared extern is never called).
// Type declarations (records/unions/enums/distincts) always collect —
// registration is cheap and other packages' signatures may reference
// them.  Record methods lower with the user package (D037 desugar);
// bundled-package record methods are a Phase N5 follow-up (calling one
// panics with a resolution message today).
func unitOf(f: in SourceFile, reachable: in Map[String, Bool], lowerAll: in Bool): CodegenUnit {
  val pkg = dottedPath(f.packageDecl.path)
  val fns: List[FunctionDecl] = newList()
  val externs: List[ExternFuncDecl] = newList()
  val records: List[RecordDecl] = newList()
  val unions: List[UnionDecl] = newList()
  val enums: List[EnumDecl] = newList()
  val distincts: List[DistinctTypeDecl] = newList()
  val interfaces: List[InterfaceDecl] = newList()
  val impls: List[ImplDecl] = newList()
  var i = 0
  while i < f.items.count {
    match f.items[i].kind {
      case IFunc(decl) -> {
        val id = pkg + "." + decl.name + "/" + decl.params.count.toString()
        if lowerAll or reachable.containsKey(id) {
          fns.add(decl)
        }
      }
      case IExternFunc(decl) -> {
        val id = pkg + "." + decl.name + "/" + decl.params.count.toString()
        if lowerAll or reachable.containsKey(id) {
          externs.add(decl)
        }
      }
      case IRecord(decl) -> {
        records.add(decl)
        if lowerAll {
          collectRecordMethods(pkg, decl, fns)
        }
      }
      case IUnion(decl) -> unions.add(decl)
      case IEnum(decl) -> enums.add(decl)
      case IDistinctType(decl) -> distincts.add(decl)
      // Interface + impl are collected together (N3.2): the impl's vtable
      // references its methods, so registering one without the other would
      // dangle.  Gated on `lowerAll` — native interfaces are user-package
      // only today (no bundled stdlib interfaces to reach).
      case IInterface(decl) -> {
        if lowerAll {
          interfaces.add(decl)
        }
      }
      case IImpl(decl) -> {
        if lowerAll {
          impls.add(decl)
          collectImplMethods(pkg, decl, fns)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  CodegenUnit(
    pkgName = pkg,
    fns = fns,
    externs = externs,
    records = records,
    unions = unions,
    enums = enums,
    distincts = distincts,
    interfaces = interfaces,
    impls = impls
  )
}
