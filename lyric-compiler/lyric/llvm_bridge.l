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
import Lyric.BuildDefines as BD
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
import Lyric.WireExpand as WireExpand
import Lyric.Mono
import Lyric.Derives
import Lyric.Pipeline
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.LlvmCodegen
import Lyric.LlvmLowering

func dottedPath(path: in ModulePath): String {
  pipeDottedPath(path)
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
        case EMember(recv, memberName) -> {
          collectCallKeys(recv, acc)
          // UFCS on a VALUE receiver (`cfg.identity.rawHandle()`) is
          // invisible to `callKeyOf` — it only resolves an `EMember` whose
          // receiver is itself a bare type/package `EPath` (the
          // `Type.method(args)` static-call shape), and this reachability
          // walk runs before codegen knows the receiver's static type, so
          // it can't construct the exact "TypeName.methodName" key an
          // extension-method-style declaration registers under. Fall back
          // to a bare member-name-only key: `registerFileFns` indexes such
          // a declaration's trailing segment too, so this still traces the
          // edge — over-inclusive (any same-named/arity method anywhere in
          // the bundle also matches) but never under-inclusive, mirroring
          // `Lyric.LlvmCodegen.lowerUfcsCall`'s own bare-name fallback.
          if key.length == 0 {
            acc.add(memberName + "/" + (args.count + 1).toString())
          }
        }
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
  val noDefines: List[String] = newList()
  compileToNativeWithFlags(source, outputPath, stdlibSources, triple, optLevel, noFlags, noDefines)
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
  defines: in List[String],
): Bool {
  // Parse + `@cfg` erasure with the `target.native` pseudo-feature
  // (D-N-013); `Lyric.Pipeline` owns the placement (erasure directly
  // after parse, before anything indexes the items).
  val noFeatures: List[String] = newList()
  val nativeFeatures = Cfg.withTargetFeature(noFeatures, "native")
  val nativeDefines = BD.decodeDefines(defines)
  val cfgFile = match pipeParseAndErase(source, "native", noFeatures, noFeatures, nativeDefines, "") {
    case Some(f) -> f
    case None -> return false
  }

  // Pre-typecheck rewrite chain: alias rewrite only.  The native bridge
  // does not expand docs/58 wire/config templates or synthesise
  // `@stubbable` stubs yet — the `false` flags make that gap explicit
  // (docs/59 §9.2 divergence flag) instead of an invisible omission.
  val noWires: Map[String, CollectedWireTemplate] = newMap()
  val noConfigs: Map[String, CollectedConfigTemplate] = newMap()
  val userFile0 = match pipeExpandAndRewrite(cfgFile, noWires, noConfigs, false, false, false) {
    case Some(f) -> f
    case None -> return false
  }

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
      if pipeIsCrossPackageItem(stdFile.items[ii]) {
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

  // Middle end (`Lyric.Pipeline` owns the order).  The typecheck is
  // advisory on the native target (the self-hosted checker lacks full
  // builtin coverage); the mode check, `?`-propagation, mono, and weave
  // gate.  Mono is fed the stdlib's interface and record decls so
  // method-call returns and field projections on imported types drive
  // same-package call-site inference (#3813).  Imported GENERIC decls
  // are deliberately NOT fed: unlike MSIL/JVM codegen, the native
  // backend performs its own whole-bundle generic instantiation at
  // lowering time (`Lyric.LlvmCodegen.genericFnDefs`, N3.1) over the
  // never-mono'd bundled stdlib files, so cross-package generic calls
  // are not erased on native — copying stdlib generic bodies into the
  // user package here would only duplicate that work and risk dangling
  // references to intra-stdlib helpers the function-granularity
  // reachability walk never registered for the user package.
  val importedItemsForMono = flattenImportedItems(importedPkgs)
  val noImportedGenFuncs: List[FunctionDecl] = newList()
  val noDeriveImports: List[Item] = newList()
  val noTemplates: Map[String, CollectedTemplate] = newMap()
  val opts = MiddleEndOptions(tcFatal = false, tcReport = true, pkgLabel = "")
  val userFile = match pipeMiddleEnd(userFile0, importedPkgs, noDeriveImports, noImportedGenFuncs, pipeInterfaceDecls(importedItemsForMono), pipeRecordDecls(importedItemsForMono), noTemplates, opts) {
    case Some(f) -> f
    case None -> return false
  }
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
  val bareTrailing: Map[String, List[String]] = newMap()
  registerFileFns(userFile, canonical, bareTrailing)
  var bi = 0
  while bi < toBundle.count {
    registerFileFns(toBundle[bi], canonical, bareTrailing)
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
  walkReachableFns(fnWorklist, canonical, bareTrailing, bodyIndex, pkgOfId, reachable)

  // Assemble the codegen units: the user package in full, then each
  // bundled package's reachable slice.
  val units: List[CodegenUnit] = newList()
  units.add(unitOf(userFile, reachable, true))
  appendBundledUnits(toBundle, reachable, units)

  linkAndEmitNative(units, outputPath, triple, optLevel, extraClangFlags)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2.35. Multi-package native project build (#6809): the native analog of
// `Msil.Bridge.compileProjectToMsilWithRestoredAndVersion` /
// `Jvm.Bridge.compileProjectToJarBundledWithRestored` for a project's OWN
// `[project.packages]` — a manifest's `[dependencies]` on OTHER restored
// Lyric packages (NuGet/Maven-style prebuilt binaries, or another project's
// own DLL/JAR) stay explicitly out of scope: native has no restored-binary
// concept (unlike dotnet/jvm, it always compiles the whole reachable world
// from source, mirroring how `Std.*` stdlib sources are bundled today), and
// a workspace/path dependency is itself just another `[project.packages]`
// tree the CALLER can feed in as more `NativeSourcePackage` entries once a
// follow-up teaches the CLI to resolve that graph (`docs/03-decision-log.md`
// tracks the exact cut).
// ─────────────────────────────────────────────────────────────────────────────
/// One own-package's pre-merged source for a native project build.
/// `Lyric.Emitter.emitNativeProject` merges a multi-file package's sources
/// into one compilation unit (the same `mergePackageSources` step the
/// MSIL/JVM project bridges use) before constructing these, so by the time a
/// package reaches here it is always exactly one valid `package` unit.
pub record NativeSourcePackage {
  name: String
  source: String
}

/// True when `file` declares a top-level `func main` — the project entry
/// package marker for a multi-package native build.  Mirrors
/// `Jvm.Bridge.fileHasTopLevelMain` (package-private there too; duplicated
/// rather than cross-imported to avoid a `Lyric.LlvmBridge` -> `Jvm.Bridge`
/// layering dependency for four lines of logic).
func fileHasTopLevelMain(file: in SourceFile): Bool {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        if decl.name == "main" {
          return true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

/// Compile a project's own packages (`packages`, in manifest declaration
/// order — list position does NOT determine the entry point; the package
/// declaring a top-level `func main` is auto-detected via
/// `fileHasTopLevelMain` and always emitted first, regardless of where it
/// falls in `packages`) plus the bundled stdlib closure into one native
/// binary.
///
/// Every entry in `packages` is always fully lowered (`lowerAll = true` in
/// `unitOf` terms) — exactly like the single-source path's own package —
/// because a project's own packages are the "user code" whose declared
/// functions must all be available to each other and to the entry point,
/// not a stdlib dependency whose unreached functions can be pruned.
/// Reachability gating still applies to the bundled STDLIB closure only, so
/// an unreached stdlib construct the Phase N1+ codegen cannot yet lower
/// never blocks a project build that never calls it — parity with the
/// single-source path's own bundling model.
///
/// Every own package sees every OTHER own package's public surface as an
/// `ImportedPackage`, resolved the identical way a bundled stdlib package's
/// cross-package items are (`pipeIsCrossPackageItem`), so `Web.OpenApi`
/// importing `Web` (a same-manifest import cycle, per the JVM bridge's
/// `compileProjectToJarBundledWithRestored` precedent for the identical
/// shape) resolves cleanly.  `triple` / `optLevel` / `extraClangFlags`
/// forward to `linkAndEmitNative` unchanged.
pub func compileProjectToNativeWithFlags(
  packages: in List[NativeSourcePackage],
  outputPath: in String,
  stdlibSources: in List[String],
  triple: in String,
  optLevel: in String,
  extraClangFlags: in List[String],
  defines: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  packageVersion: in String,
): Bool {
  if packages.count == 0 {
    Console.error("error[N0005]: native project build received no packages")
    return false
  }

  val noFeatures: List[String] = newList()
  val nativeFeatures = Cfg.withTargetFeature(noFeatures, "native")
  // Layer the manifest's `[package].version` in as the well-known `version`
  // define's fallback (#6821), matching
  // `Msil.Bridge.compileProjectToMsilWithRestoredAndVersion`'s identical
  // `BD.decodeDefines(BD.withWellKnownDefines(packageVersion, defines))`
  // call — an explicit `--define version=…` (already present in `defines`)
  // still wins, since `withWellKnownDefines` prepends the fallback and
  // `decodeDefines` is last-wins.
  val nativeDefines = BD.decodeDefines(BD.withWellKnownDefines(packageVersion, defines))

  // Parse + `@cfg` erasure for every own package (per-package repeat of the
  // single-source path's first pipeline stage) — threading the real
  // `activeFeatures`/`declaredFeatures` (#6818), matching
  // `Msil.Bridge.compileProjectToMsilWithRestoredAndVersion`'s identical
  // call.  Own packages get the caller's real feature set; the bundled
  // stdlib closure below still erases against `noFeatures` (a stdlib
  // package's own `@cfg(feature = ...)` items are never user-feature-gated
  // on any target, same as the single-source path).
  val cfgFiles: List[SourceFile] = newList()
  var ppi = 0
  while ppi < packages.count {
    val cfgFile = match pipeParseAndErase(packages[ppi].source, "native", activeFeatures, declaredFeatures, nativeDefines) {
      case Some(f) -> f
      case None -> return false
    }
    cfgFiles.add(cfgFile)
    ppi = ppi + 1
  }

  // Pre-typecheck rewrite chain: alias rewrite only, matching the
  // single-source path (docs/59 §9.2 divergence flag — no wire/config
  // template expansion or `@stubbable` synthesis on native yet).
  val noWires: Map[String, CollectedWireTemplate] = newMap()
  val noConfigs: Map[String, CollectedConfigTemplate] = newMap()
  val ownFiles0: List[SourceFile] = newList()
  var owi = 0
  while owi < cfgFiles.count {
    val f0 = match pipeExpandAndRewrite(cfgFiles[owi], noWires, noConfigs, false, false, false) {
      case Some(f) -> f
      case None -> return false
    }
    ownFiles0.add(f0)
    owi = owi + 1
  }

  // Parse the stdlib once (identical to the single-source path).
  val importedPkgs: List[ImportedPackage] = newList()
  val stdlibByPkg: Map[String, SourceFile] = newMap()
  var si = 0
  while si < stdlibSources.count {
    val pr = parse(stdlibSources[si])
    val stdCfg = Cfg.applyCfgErasure(nativeFeatures, noFeatures, pr.file)
    val stdFile = Aliases.rewriteFile(stdCfg.file)
    val pkgItems: List[Item] = newList()
    var ii = 0
    while ii < stdFile.items.count {
      if pipeIsCrossPackageItem(stdFile.items[ii]) {
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

  // Every own package also contributes its cross-package items to the SAME
  // `importedPkgs` pool every OTHER own package (and itself) type-checks
  // against — mirroring `Jvm.Bridge.compileProjectToJarBundledWithRestored`'s
  // #6024 fix, which found that excluding a project's own entry package from
  // its sibling-visible surface broke same-manifest import cycles (a kernel
  // package importing back the package that imports it).  Including a
  // package's own items in its own `importedPkgs` is harmless: the type
  // checker resolves `Pkg.Type` references identically whether the name came
  // from the file's own declarations or a same-named `ImportedPackage` entry.
  var oipi = 0
  while oipi < ownFiles0.count {
    val f = ownFiles0[oipi]
    val pkgItems: List[Item] = newList()
    var ii = 0
    while ii < f.items.count {
      if pipeIsCrossPackageItem(f.items[ii]) {
        pkgItems.add(f.items[ii])
      }
      ii = ii + 1
    }
    val pn = dottedPath(f.packageDecl.path)
    importedPkgs.add(ImportedPackage(name = pn, items = pkgItems, imports = collectImportNames(f.imports)))
    oipi = oipi + 1
  }

  // Middle-end every own file against the shared stdlib+sibling pool.
  val ownFiles: List[SourceFile] = newList()
  val noImportedGenFuncs: List[FunctionDecl] = newList()
  val noDeriveImports: List[Item] = newList()
  val noTemplates: Map[String, CollectedTemplate] = newMap()
  val importedItemsForMono = flattenImportedItems(importedPkgs)
  val importedInterfaceDecls = pipeInterfaceDecls(importedItemsForMono)
  val importedRecordDecls = pipeRecordDecls(importedItemsForMono)
  var mei = 0
  while mei < ownFiles0.count {
    val opts = MiddleEndOptions(tcFatal = false, tcReport = true, pkgLabel = "")
    val checked = match pipeMiddleEnd(ownFiles0[mei], importedPkgs, noDeriveImports, noImportedGenFuncs, importedInterfaceDecls, importedRecordDecls, noTemplates, opts) {
      case Some(f) -> f
      case None -> return false
    }
    ownFiles.add(checked)
    mei = mei + 1
  }

  // Transitive stdlib import closure across every own package's imports.
  val toBundle: List[SourceFile] = newList()
  val seen: Map[String, Bool] = newMap()
  val worklist: List[String] = newList()
  var ofi = 0
  while ofi < ownFiles.count {
    var ui = 0
    while ui < ownFiles[ofi].imports.count {
      worklist.add(dottedPath(ownFiles[ofi].imports[ui].path))
      ui = ui + 1
    }
    ofi = ofi + 1
  }
  var wi = 0
  while wi < worklist.count {
    val pkg = worklist[wi]
    wi = wi + 1
    if not seen.containsKey(pkg) {
      seen.add(pkg, true)
      match mapGet(stdlibByPkg, pkg) {
        case Some(f) -> {
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

  // Function-granularity reachability, rooted at EVERY own package's own
  // functions (every own package is fully lowered — see the doc comment
  // above), walking into the bundled stdlib closure.
  val canonical: Map[String, String] = newMap()
  val bareTrailing: Map[String, List[String]] = newMap()
  var rfi = 0
  while rfi < ownFiles.count {
    registerFileFns(ownFiles[rfi], canonical, bareTrailing)
    rfi = rfi + 1
  }
  var bi = 0
  while bi < toBundle.count {
    registerFileFns(toBundle[bi], canonical, bareTrailing)
    bi = bi + 1
  }

  val reachable: Map[String, Bool] = newMap()
  val fnWorklist: List[String] = newList()
  var sfi = 0
  while sfi < ownFiles.count {
    val pkgName = dottedPath(ownFiles[sfi].packageDecl.path)
    var gi = 0
    while gi < ownFiles[sfi].items.count {
      match ownFiles[sfi].items[gi].kind {
        case IFunc(decl) -> {
          val selfId = pkgName + "." + decl.name + "/" + decl.params.count.toString()
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
    sfi = sfi + 1
  }

  // Bodies indexed by canonical id so the walk can chase callees.
  val bodyIndex: Map[String, FunctionDecl] = newMap()
  val pkgOfId: Map[String, String] = newMap()
  var ifi = 0
  while ifi < ownFiles.count {
    indexFileFns(ownFiles[ifi], bodyIndex, pkgOfId)
    ifi = ifi + 1
  }
  var bi2 = 0
  while bi2 < toBundle.count {
    indexFileFns(toBundle[bi2], bodyIndex, pkgOfId)
    bi2 = bi2 + 1
  }

  walkReachableFns(fnWorklist, canonical, bareTrailing, bodyIndex, pkgOfId, reachable)

  // Assemble the codegen units: the package declaring a top-level `func
  // main` goes FIRST — `Lyric.LlvmCodegen`'s C-`main` synthesis only scans
  // `units[0]` for a zero-arg `main` (a carry-over single-file assumption:
  // the single-source path's own package is always unit 0), so a manifest's
  // `[project.packages]` table — which has no guaranteed declaration order
  // relative to which package holds `main` — must be reordered here rather
  // than in the codegen itself.  Mirrors
  // `Jvm.Bridge.compileProjectToJarBundledWithRestored`'s identical
  // "entry package is the one declaring func main" convention.  Falls back
  // to declaration order when no own package declares one (a library-only
  // project with no runnable entry point).
  var mainOwnIdx = -1
  var moi = 0
  while moi < ownFiles.count and mainOwnIdx < 0 {
    if fileHasTopLevelMain(ownFiles[moi]) {
      mainOwnIdx = moi
    }
    moi = moi + 1
  }
  val units: List[CodegenUnit] = newList()
  if mainOwnIdx >= 0 {
    units.add(unitOf(ownFiles[mainOwnIdx], reachable, true))
  }
  var uoi = 0
  while uoi < ownFiles.count {
    if uoi != mainOwnIdx {
      units.add(unitOf(ownFiles[uoi], reachable, true))
    }
    uoi = uoi + 1
  }
  appendBundledUnits(toBundle, reachable, units)

  linkAndEmitNative(units, outputPath, triple, optLevel, extraClangFlags)
}

// Appends one `CodegenUnit` per bundled (stdlib) package in `toBundle` whose
// reachable slice is non-empty, mutating `units` in place. A unit with no
// reachable functions still contributes its type declarations (e.g.
// Std.Core's Result/Option are referenced by other packages' signatures
// without any Std.Core call). Shared by the single-source and multi-package
// native entry points (#6817).
func appendBundledUnits(
  toBundle: in List[SourceFile], reachable: in Map[String, Bool], units: in List[CodegenUnit]
): Unit {
  var bi = 0
  while bi < toBundle.count {
    val u = unitOf(toBundle[bi], reachable, false)
    if u.fns.count > 0 or u.externs.count > 0 or u.records.count > 0 or u.unions.count > 0 or u.enums.count > 0 or u.distincts.count > 0 {
      units.add(u)
    }
    bi = bi + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2.4. Function-granularity reachability walk, shared by the single-source
// and multi-package native entry points (#6809): chases every call-key a
// worklist function's body names, resolving through `canonical` (exact
// package-qualified id) and `bareTrailing` (multi-valued UFCS fallback),
// mutating `reachable` and appending newly-discovered ids to `fnWorklist` in
// place — verbatim extraction of `compileToNativeWithFlags`'s original inline
// loop, no behavior change.
// ─────────────────────────────────────────────────────────────────────────────
func walkReachableFns(
  fnWorklist: in List[String],
  canonical: in Map[String, String],
  bareTrailing: in Map[String, List[String]],
  bodyIndex: in Map[String, FunctionDecl],
  pkgOfId: in Map[String, String],
  reachable: in Map[String, Bool],
): Unit {
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
          // `raw` may ALSO be a bare UFCS trailing-segment key
          // (`collectCallKeys`'s "cfg.identity.rawHandle()" fallback):
          // resolve it through the multi-valued `bareTrailing` map
          // regardless of whether the ordinary single-valued `canonical`
          // lookup above already matched something (a different type's
          // same-named/arity method, per `registerBareTrailingSegment`'s
          // header) — mark EVERY candidate reachable.
          match mapGet(bareTrailing, raw) {
            case Some(targets) -> {
              var ti = 0
              while ti < targets.count {
                val bt = targets[ti]
                ti = ti + 1
                if not reachable.containsKey(bt) {
                  reachable.add(bt, true)
                  fnWorklist.add(bt)
                }
              }
            }
            case None -> {
            }
          }
          // The async process leaf (D-N-023): the codegen intercept
          // redirects in-coroutine `Std.Process.runCapture` /
          // `runCaptureWithInput` calls to the kernel's async seam, a
          // target no Lyric source names — keep the seam (and everything
          // its body pulls in) reachable whenever either is.
          // Arity-coupled to the intercept in llvm_codegen.l — change
          // both together (#5108).
          if target == "Std.Process.runCapture/3" or target == "Std.Process.runCaptureWithInput/4" {
            match mapGet(canonical, "Std.ProcessCaptureHost.hostRunCaptureListAsync/4") {
              case Some(seam) -> {
                if not reachable.containsKey(seam) {
                  reachable.add(seam, true)
                  fnWorklist.add(seam)
                }
              }
              case None -> {
              }
            }
          }
        }
      }
      case None -> {
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2.5. Codegen -> IR -> clang link, shared by the single-source
// (`compileToNativeWithFlags`) and multi-package (`compileProjectToNativeWithFlags`)
// entry points (#6809): everything downstream of "here are the codegen units"
// is target-triple/clang-invocation plumbing that neither cares how many
// source packages contributed the units.
// ─────────────────────────────────────────────────────────────────────────────
func linkAndEmitNative(
  units: in List[CodegenUnit],
  outputPath: in String,
  triple: in String,
  optLevel: in String,
  extraClangFlags: in List[String],
): Bool {
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
  // libdl for the lyric_tls.c OpenSSL seam's dlopen/dlsym (a no-op stub on
  // glibc >= 2.34; a real dependency on older glibc / musl). A program that
  // never references the TLS seam does not pull lyric_tls.o from the archive,
  // so this stays inert for non-TLS binaries. docs/61 §7, issue #5890.
  clangArgs.add("-ldl")
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
      Console.error("  clang -O" + effOpt + " " + llPath + " " + rtPath + " -lm -lpthread -ldl -o " + outputPath)
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

func registerFileFns(
  f: in SourceFile, canonical: in Map[String, String], bareTrailing: in Map[String, List[String]]
): Unit {
  val pkg = dottedPath(f.packageDecl.path)
  var i = 0
  while i < f.items.count {
    match f.items[i].kind {
      case IFunc(decl) -> {
        val id = pkg + "." + decl.name + "/" + decl.params.count.toString()
        addKey(canonical, id, id)
        addKey(canonical, decl.name + "/" + decl.params.count.toString(), id)
        registerBareTrailingSegment(bareTrailing, decl.name, decl.params.count, id)
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

// An extension-method-style declaration (`func Identity.rawHandle(...)`)
// registers under its full `TypeName.methodName` compound name above, but
// a UFCS call on a VALUE receiver (`cfg.identity.rawHandle()`) parses as
// `EMember` whose receiver is itself a value expression, not a bare type
// path — `callKeyOf` can't construct "Identity.rawHandle" from that shape
// (the receiver's static type isn't known at this syntax-only reachability
// stage), so `collectCallKeys` falls back to a bare member-name-only key
// ("rawHandle/1"). Index that trailing segment here too so the fallback
// resolves. This is a SEPARATE, multi-valued map from `canonical` (not
// merged into its single-target `addKey` scheme): two different types in
// the same bundle can both declare a same-named/same-arity extension
// method (e.g. `Std.Tls`'s OWN `Certificate.rawHandle`/`Identity.rawHandle`
// both trail to "rawHandle/1") — `canonical`'s first-write-wins `addKey`
// would silently pick only ONE of them, permanently shadowing the other
// under this ambiguous key. A `List[String]` target lets the walker mark
// EVERY same-named/arity candidate reachable instead: over-inclusive, but
// never under-inclusive, the same bare-name fallback philosophy
// `Lyric.LlvmCodegen.lowerUfcsCall`'s own resolution order already relies
// on for its OWN (unambiguous, single-target) bare-name lookup.
func registerBareTrailingSegment(
  bareTrailing: in Map[String, List[String]],
  name: in String,
  arity: in Int,
  id: in String,
): Unit {
  val dotIdx = lastDotIndex(name)
  if dotIdx >= 0 {
    val trailing = Str.substring(name, dotIdx + 1, name.length - dotIdx - 1) + "/" + arity.toString()
    match mapGet(bareTrailing, trailing) {
      case Some(targets) -> targets.add(id)
      case None -> {
        val targets: List[String] = newList()
        targets.add(id)
        bareTrailing.add(trailing, targets)
      }
    }
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
  val protecteds: List[ProtectedTypeDecl] = newList()
  // Module-level `val`/`const` bindings (#5977 part 2): collected regardless of
  // `lowerAll` (like type declarations) so a reference from the user package to
  // a bundled package's const resolves via use-site inlining.
  val moduleVals: List[ModuleValDef] = newList()
  var i = 0
  while i < f.items.count {
    match f.items[i].kind {
      case IFunc(decl) -> {
        val id = pkg + "." + decl.name + "/" + decl.params.count.toString()
        if lowerAll or reachable.containsKey(id) {
          fns.add(decl)
        }
      }
      case IVal(decl) -> {
        match decl.pattern.kind {
          case PBinding(vn, _) -> moduleVals.add(ModuleValDef(name = vn, init = decl.init, ty = decl.ty))
          case _ -> ()
        }
      }
      case IConst(decl) -> moduleVals.add(ModuleValDef(name = decl.name, init = decl.init, ty = Some(value = decl.ty)))
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
      // Opaque types (#6234 part 1): reshaped into an equivalent
      // `RecordDecl` (`Lyric.LlvmCodegen.opaqueToRecordDecl`) so they share
      // every downstream record code path.  Always collected regardless of
      // `lowerAll`, like the other type declarations above — a bundled
      // stdlib package's opaque type (e.g. `Std.Tls.Certificate`) must
      // register even when none of its own functions are reachable, since a
      // reachable *user* function may still construct/read one.  A
      // body-less forward declaration has no fields to lower.
      case IOpaque(decl) -> {
        if decl.hasBody {
          records.add(opaqueToRecordDecl(decl))
        }
      }
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
      // Protected types (N3.4): gated on `lowerAll` like interfaces above —
      // native protected types are user-package only today.
      case IProtected(decl) -> {
        if lowerAll {
          protecteds.add(decl)
          collectProtectedMethods(pkg, decl, fns)
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
    impls = impls,
    protecteds = protecteds,
    moduleVals = moduleVals,
    importsStdString = fileImportsStdString(f)
  )
}
