//! llvm/bridge.l — Lyric.LlvmBridge: the native compilation pipeline (N6.1).
//!
//! Public entry point that chains the self-hosted front/middle end to a
//! runnable native binary: parse → cfg erasure (target.native) → alias
//! rewrite → typecheck → modecheck → contract elaboration →
//! `?`-propagation → derives → mono → weave → reachability over the
//! bundled stdlib → `Lyric.LlvmCodegen.codegenNativeBundle` →
//! `Lyric.LlvmLowering.lowerNativePackage` → write `.ll` → clang (D-N-001).
//! `--triple wasm32-wasi` links with the wasi-sdk's clang and the wasm32
//! `lyric_rt` archive instead (no `-lpthread`/`-ldl`; docs/35 W2).
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
import Std.Parse as Parse
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
import Lyric.PluginExpand as PluginExpand
import Lyric.Mono
import Lyric.Derives
import Lyric.Pipeline
import Lyric.TypeAliasResolve as TAR
import Lyric.BareFuncRef as BFR
import Lyric.SelfFields as SelfFields
import Lyric.DiagnosticUtil as DiagUtil
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.LlvmCodegen
import Lyric.LlvmLowering
import Lyric.WasmGlue
import Lyric.ComponentGlue

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
      // `name[T](args)`: a call with explicit type arguments names `name`.
      match fn.kind {
        case EIndex(ir, _) -> match ir.kind {
          case EPath(ip) -> {
            if ip.segments.count == 1 {
              acc.add(ip.segments[0] + "/" + args.count.toString())
            }
          }
          case _ -> {
          }
        }
        case ETypeApp(tf, _) -> match tf.kind {
          case EPath(tp) -> {
            if tp.segments.count == 1 {
              acc.add(tp.segments[0] + "/" + args.count.toString())
            }
          }
          case _ -> {
          }
        }
        case _ -> {
        }
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
          if key.length == 0 or isLocalLikeReceiver(recv) {
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

/// A bare lower-case identifier receiver (`sb.append(x)`) is almost always a
/// local or parameter, but `callKeyOf` cannot tell it apart from a
/// `pkg.func(args)` static call and keys it as "sb.append/1", which names
/// nothing. Such a call also gets the bare member-name key so the method it
/// actually dispatches to is traced (#7257). Type and package heads are
/// capitalised by convention and keep the exact static-call key only.
func isLocalLikeReceiver(recv: in Expr): Bool {
  match recv.kind {
    case EPath(p) -> {
      if p.segments.count != 1 {
        return false
      }
      val head = p.segments[0]
      head.length > 0 and head[0] >= 'a' and head[0] <= 'z'
    }
    case _ -> false
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

/// The one Windows triple the native backend targets (docs/67 G9).
pub val windowsTriple = "x86_64-pc-windows-msvc"

/// Whether `triple` names a Windows target, of any architecture or ABI.
pub func isWindowsTriple(triple: in String): Bool {
  Str.contains(triple, "windows") or Str.contains(triple, "win32") or Str.contains(triple, "mingw")
}

/// Whether a native build for `triple` produces a Windows executable: the
/// triple names Windows, or it is empty (the host) and the host is Windows.
pub func nativeTargetIsWindows(triple: in String): Bool {
  if triple.length == 0 {
    Environment.isWindows()
  } else {
    isWindowsTriple(triple)
  }
}

/// The triple a self-test that codegens and links for the host passes to
/// `codegenNativePackage`: empty (the backend's default System V lowering,
/// which matches every POSIX host the suites run on) except on a Windows host,
/// whose Microsoft x64 ABI only `windowsTriple` selects.
pub func nativeHostCodegenTriple(): String {
  if Environment.isWindows() {
    windowsTriple
  } else {
    ""
  }
}

/// The path a native executable for `triple` is written to: `path` itself,
/// or with `.exe` appended for a Windows target when it has no `.exe` already,
/// since Windows starts a program only by its extension.
pub func nativeExecutablePath(path: in String, triple: in String): String {
  if nativeTargetIsWindows(triple) and not Str.endsWith(Str.toLower(path), ".exe") {
    path + ".exe"
  } else {
    path
  }
}

/// Locate the Windows `lyric_rt` archive: `$LYRIC_RT_WINDOWS_PATH`, then on a
/// Windows host `$LYRIC_RT_PATH`, the installed layout
/// (`<bin>/lib/lyric_rt-x86_64-pc-windows-msvc.lib`), then the dev layout
/// (`lyric-rt/build-x86_64-pc-windows-msvc/lyric_rt.lib`, from
/// `make -C lyric-rt windows`).
///
/// `dynamicCrt` selects the build against the DLL C runtime instead
/// (`$LYRIC_RT_WINDOWS_MD_PATH`, `lyric_rt_md-<triple>.lib`,
/// `lyric_rt_md.lib`), which AddressSanitizer needs: its Windows runtime
/// works only with the DLL C runtime, while ordinary programs link the static
/// one so they need no Visual C++ redistributable.
func findWindowsRtArchive(dynamicCrt: in Bool): String {
  val stem = if dynamicCrt { "lyric_rt_md" } else { "lyric_rt" }
  val winOverride = Environment.getVarOrDefault(
    if dynamicCrt { "LYRIC_RT_WINDOWS_MD_PATH" } else { "LYRIC_RT_WINDOWS_PATH" },
    ""
  )
  if winOverride.length > 0 and File.fileExists(winOverride) {
    return winOverride
  }
  if Environment.isWindows() and not dynamicCrt {
    val hostOverride = Environment.getVarOrDefault("LYRIC_RT_PATH", "")
    if hostOverride.length > 0 and File.fileExists(hostOverride) {
      return hostOverride
    }
  }
  val appBase = Environment.appBaseDirectory()
  val installed = Path.join(Path.join(appBase, "lib"), stem + "-" + windowsTriple + ".lib")
  if File.fileExists(installed) {
    return installed
  }
  val devRel = Path.join(Path.join("lyric-rt", "build-" + windowsTriple), stem + ".lib")
  val hit = walkUpFor(appBase, devRel)
  if hit.length > 0 {
    return hit
  }
  walkUpFor(Environment.currentDirectory(), devRel)
}

/// Whether the extra clang flags ask for AddressSanitizer.
func wantsAsan(flags: in List[String]): Bool {
  for f in flags {
    if f == "-fsanitize=address" {
      return true
    }
  }
  false
}

/// The AddressSanitizer runtime a Windows ASan build loads.
val windowsAsanDll: String = "clang_rt.asan_dynamic-x86_64.dll"

/// Where clang keeps `windowsAsanDll` for `triple`: what
/// `-print-file-name` finds on its library path, else the resource
/// directory's `lib/windows`; "" when neither has it.
func findWindowsAsanDll(triple: in String): String {
  val args: List[String] = newList()
  args.add("--target=" + triple)
  args.add("-print-file-name=" + windowsAsanDll)
  match Process.runCapture("clang", args, 60000) {
    case Ok(res) -> {
      val p = Str.trim(res.stdout)
      if res.exitCode == 0 and p != windowsAsanDll and File.fileExists(p) {
        return p
      }
    }
    case Err(_) -> ()
  }
  val rargs: List[String] = newList()
  rargs.add("--target=" + triple)
  rargs.add("-print-resource-dir")
  match Process.runCapture("clang", rargs, 60000) {
    case Ok(res) -> {
      val candidate = Path.join(Path.join(Path.join(Str.trim(res.stdout), "lib"), "windows"), windowsAsanDll)
      if res.exitCode == 0 and File.fileExists(candidate) {
        return candidate
      }
    }
    case Err(_) -> ()
  }
  ""
}

/// Copies `windowsAsanDll` beside the executable at `exePath`, where the
/// loader looks first.  Reports N0026 and returns false when clang has no
/// such runtime (an LLVM install without compiler-rt).
func bundleWindowsAsanDll(exePath: in String, triple: in String): Bool {
  val dll = findWindowsAsanDll(triple)
  if dll.length == 0 {
    Console.error(
      "error[N0026]: an AddressSanitizer build for Windows needs " + windowsAsanDll +
        ", which this clang does not have (install LLVM with compiler-rt, as the official Windows installer does)"
    )
    return false
  }
  val dest = Path.join(Path.dirname(exePath), windowsAsanDll)
  match File.readBytes(dll) {
    case Ok(bytes) -> match File.writeBytes(dest, bytes) {
      case Ok(_) -> true
      case Err(e) -> {
        Console.error("error[N0026]: cannot copy " + dll + " to " + dest + ": " + IOError.message(e))
        false
      }
    }
    case Err(e) -> {
      Console.error("error[N0026]: cannot read " + dll + ": " + IOError.message(e))
      false
    }
  }
}

/// The system's temporary directory: `$TMPDIR`, `$TEMP`, `$TMP`, then
/// `/tmp` (the same chain the self-tests use).
pub func nativeTempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

/// A scratch directory `name` under `nativeTempBase()`, created when
/// missing.  The native self-tests write their binaries here.
pub func nativeScratchDir(name: in String): String {
  val dir = Path.join(nativeTempBase(), name)
  val _ = File.createDir(dir)
  dir
}

/// Links the LLVM IR at `llPath` with lyric-rt into a host executable at
/// `outputPath` (with `.exe` on Windows), exactly as a host `lyric build
/// --target native` links: the host's runtime archive and system
/// libraries, `-fsanitize=address` when `sanitize` (with the DLL C runtime
/// and its ASan DLL beside the program on Windows), then `extraArgs` (extra
/// objects or `-l` libraries).  Returns the executable's path, or clang's
/// error output.
pub func linkNativeIr(
  llPath: in String, outputPath: in String, sanitize: in Bool, extraArgs: in List[String]
): Result[String, String] {
  val isWindows = Environment.isWindows()
  val rt = if isWindows { findWindowsRtArchive(sanitize) } else { findLyricRtArchive() }
  if rt.length == 0 {
    return Err(
      error = "the lyric_rt archive was not found (build it with `make -C lyric-rt`" +
        (if isWindows { " windows" } else { "" }) +
        ")"
    )
  }
  val exe = nativeExecutablePath(outputPath, "")
  val args: List[String] = newList()
  args.add("-O0")
  if sanitize {
    args.add("-fsanitize=address")
  }
  if isWindows {
    args.add("--target=" + windowsTriple)
    args.add("-fuse-ld=lld")
    if sanitize {
      // clang's MSVC link step picks the DLL-CRT AddressSanitizer thunk only
      // when `_DLL` is defined (as `/MD` does); `-fms-runtime-lib` alone gets
      // the static-CRT thunk, whose malloc clashes with ucrt.lib's.
      args.add("-fms-runtime-lib=dll")
      args.add("-D_DLL")
    }
  }
  args.add(llPath)
  for a in extraArgs {
    args.add(a)
  }
  args.add(rt)
  if isWindows {
    for lib in windowsSystemLibs() {
      args.add(lib)
    }
  } else {
    args.add("-lm")
    args.add("-lpthread")
    args.add("-ldl")
  }
  args.add("-o")
  args.add(exe)
  match Process.runCapture("clang", args, 300000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        return Err(error = "clang failed on " + llPath + ": " + res.stderr)
      }
    }
    case Err(e) -> return Err(error = "clang could not be started: " + e)
  }
  if isWindows and sanitize and not bundleWindowsAsanDll(exe, windowsTriple) {
    return Err(error = "the AddressSanitizer runtime could not be bundled (see stderr)")
  }
  Ok(value = exe)
}

/// The system import libraries every Windows link names, all used by the
/// runtime (lyric-rt's `WIN_LIBS`): CNG entropy (`bcrypt`), the UTF-16
/// command-line parser (`shell32`), the security descriptors of the
/// child-process pipes (`advapi32`), Winsock (`ws2_32`), and Schannel with the
/// certificate and key APIs (`secur32`, `crypt32`, `ncrypt`).
func windowsSystemLibs(): List[String] {
  val libs: List[String] = newList()
  for name in ["bcrypt", "shell32", "advapi32", "ws2_32", "secur32", "crypt32", "ncrypt"] {
    libs.add("-l" + name)
  }
  libs
}

/// Whether `triple` targets WebAssembly (docs/35): those builds link with a
/// wasi-sdk clang against the per-triple `lyric_rt` archive, never the host's.
func isWasmTriple(triple: in String): Bool {
  Str.startsWith(triple, "wasm32")
}

/// clang's canonical spelling of the WASI triple. `wasm32-wasi` is WASI
/// preview 1, which clang 23 (wasi-sdk 34) deprecates under that name and whose
/// sysroot only carries headers as `wasm32-wasip1`; the short form also makes
/// clang print an "overriding the module target triple" warning.
pub func normalizeNativeTriple(triple: in String): String {
  if triple == "wasm32-wasi" {
    return "wasm32-unknown-wasip1"
  }
  if isWindowsMsvcX64(triple) {
    return windowsTriple
  }
  triple
}

/// Whether `triple` is Windows x86-64 with the MSVC environment under any
/// vendor or version spelling: `clang -print-effective-triple` on a Windows
/// host prints the MSVC version (`x86_64-pc-windows-msvc19.40.33811`), and
/// `x86_64-unknown-windows-msvc` names the same target.
func isWindowsMsvcX64(triple: in String): Bool {
  val parts = Str.split(triple, "-")
  parts.length == 4 and (parts[0] == "x86_64" or parts[0] == "amd64") and parts[2] == "windows" and
    Str.startsWith(parts[3], "msvc")
}

/// Locate the wasm32 `lyric_rt` archive: `$LYRIC_RT_WASM32_PATH` override, the
/// installed layout (`<bin>/lib/lyric_rt-wasm32-wasi.a`), then the dev layout
/// (`lyric-rt/build-wasm32-wasi/lyric_rt.a`).  `$LYRIC_RT_PATH` is the HOST
/// archive's override and never applies here.
func findWasmRtArchive(): String {
  val envOverride = Environment.getVarOrDefault("LYRIC_RT_WASM32_PATH", "")
  if envOverride.length > 0 and File.fileExists(envOverride) {
    return envOverride
  }
  val appBase = Environment.appBaseDirectory()
  val installed = Path.join(Path.join(appBase, "lib"), "lyric_rt-wasm32-wasi.a")
  if File.fileExists(installed) {
    return installed
  }
  val devRel = Path.join(Path.join("lyric-rt", "build-wasm32-wasi"), "lyric_rt.a")
  val hit = walkUpFor(appBase, devRel)
  if hit.length > 0 {
    return hit
  }
  walkUpFor(Environment.currentDirectory(), devRel)
}

/// The wasi-sdk install root (`$WASI_SDK_PATH`, the variable wasi-sdk's own
/// docs use), or "" when it is not set or has no clang.
func findWasiSdk(): String {
  val root = Environment.getVarOrDefault("WASI_SDK_PATH", "")
  if root.length > 0 and File.fileExists(Path.join(Path.join(root, "bin"), "clang")) {
    return root
  }
  ""
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
// §2.9. The bundled stdlib.  Native compiles the `Std.*` packages from source
// into every binary (there is no precompiled stdlib to link against), so each
// build parses them, and type-checks the ones its import closure reaches.
// ─────────────────────────────────────────────────────────────────────────────
/// One stdlib source file of a native build (`Lyric.Emitter.findStdlibSourcesNative`):
/// its text, and the path a diagnostic in it names.
pub record NativeStdlibFile {
  path: String
  source: String
}

/// The parsed stdlib: every package's cross-package surface for the type
/// check, and each package's whole file and source path for bundling.
record NativeStdlib {
  importedPkgs: List[ImportedPackage]
  byPkg: Map[String, SourceFile]
  pathByPkg: Map[String, String]
}

func parseNativeStdlib(stdlibFiles: in List[NativeStdlibFile]): NativeStdlib {
  val noFeatures: List[String] = newList()
  val nativeFeatures = Cfg.withTargetFeature(noFeatures, "native")
  val importedPkgs: List[ImportedPackage] = newList()
  val byPkg: Map[String, SourceFile] = newMap()
  val pathByPkg: Map[String, String] = newMap()
  for sf in stdlibFiles {
    val pr = parse(sf.source)
    // Stdlib parse diagnostics are advisory (self-hosted parser gaps
    // vs. the stdlib tree must not block user builds — see the
    // matching note in Jvm.Bridge).
    val stdCfg = Cfg.applyCfgErasure(nativeFeatures, noFeatures, pr.file)
    // Invariant construction checkers (#7222), as the other bridges add them.
    val stdFile = synthesizeInvariantCheckers(Aliases.rewriteFile(stdCfg.file))
    val pkgItems: List[Item] = newList()
    for it in stdFile.items {
      if pipeIsCrossPackageItem(it) {
        pkgItems.add(it)
      }
    }
    val pn = dottedPath(stdFile.packageDecl.path)
    importedPkgs.add(
      ImportedPackage(
        name = pn,
        items = pkgItems,
        imports = collectImportNames(stdFile.imports),
        wholeImports = collectWholeImportNames(stdFile.imports)
      )
    )
    if pn.length > 0 and not byPkg.containsKey(pn) {
      byPkg.add(pn, stdFile)
      pathByPkg.add(pn, sf.path)
    }
  }
  NativeStdlib(importedPkgs = importedPkgs, byPkg = byPkg, pathByPkg = pathByPkg)
}

/// Type-check bundled stdlib package `pkg` (#7933), the counterpart of the
/// user package's fatal check (#7910): the native binary is built from this
/// source, so an ill-typed kernel or stdlib body must stop the build like
/// an ill-typed package of the program does.  Only error-severity
/// diagnostics are reported, labelled with the stdlib file's path; a
/// stdlib warning is not the user's to act on.  The package is checked
/// against the packages its own import closure reaches rather than the
/// whole stdlib, which bounds the signature resolution each check repeats.
/// Returns None after reporting an error, else the package with the checker's
/// record-arithmetic, record-equality and `array[N, T]` sites lowered, as the
/// user package gets from `pipeCheckFront`: the stdlib's own `Vec3 + Vec3` or
/// `m.m[i]` would otherwise reach codegen as an operator on a record.
func checkBundledStdlibPackage(pkg: in String, file: in SourceFile, stdlib: in NativeStdlib): Option[SourceFile] {
  val visible = stdlibImportClosure(pkg, stdlib)
  val tcRes = checkWithImportedPackagesForNative(file, visible)
  val errors: List[Diagnostic] = newList()
  for d in tcRes.diagnostics {
    if d.severity == DiagError {
      errors.add(d)
    }
  }
  if errors.count == 0 {
    return Some(value = lowerArraySites(lowerRecordSites(file, tcRes.symbols), tcRes.symbols, false))
  }
  DiagUtil.diagReportAndAbortInPkg(stdlibDiagLabel(pkg, stdlib), errors)
  None
}

/// The label a diagnostic in bundled stdlib package `pkg` is reported
/// under: its source file's path, or the package name when it has none.
func stdlibDiagLabel(pkg: in String, stdlib: in NativeStdlib): String {
  match mapGet(stdlib.pathByPkg, pkg) {
    case Some(p) -> if p.length > 0 { p } else { pkg }
    case None -> pkg
  }
}

/// The stdlib packages `pkg` reaches through its imports, transitively,
/// itself excluded: the scope a check of `pkg`'s own source needs.  Kept in
/// stdlib load order, which the checker's last-registered-wins lookup
/// depends on (kernels before the public files that re-export them; see
/// `Lyric.Emitter.findStdlibSources`).
func stdlibImportClosure(pkg: in String, stdlib: in NativeStdlib): List[ImportedPackage] {
  // A package split across several files reaches the union of their imports.
  val importsOf: Map[String, List[String]] = newMap()
  for ip in stdlib.importedPkgs {
    match mapGet(importsOf, ip.name) {
      case Some(known) -> {
        for m in ip.imports {
          known.add(m)
        }
      }
      case None -> {
        val own: List[String] = newList()
        for m in ip.imports {
          own.add(m)
        }
        importsOf.add(ip.name, own)
      }
    }
  }
  val reached: Map[String, Bool] = newMap()
  val worklist: List[String] = newList()
  worklist.add(pkg)
  var wi = 0
  while wi < worklist.count {
    val n = worklist[wi]
    wi = wi + 1
    if not reached.containsKey(n) {
      reached.add(n, true)
      match mapGet(importsOf, n) {
        case Some(ns) -> {
          for m in ns {
            worklist.add(m)
          }
        }
        case None -> ()
      }
    }
  }
  val visible: List[ImportedPackage] = newList()
  for ip in stdlib.importedPkgs {
    if ip.name != pkg and reached.containsKey(ip.name) {
      visible.add(ip)
    }
  }
  visible
}

// `{ val v: T = init; v }`: the declared type sits on a typed local so the
// monomorphiser infers a generic initializer's type arguments from it
// (it reads annotated locals, not the function's return type).
func typedInitBlock(ty: in TypeExpr, init: in Expr, sp: in Span): Block {
  val name = "__lyric_mvinit_value"
  val noInner: Option[Pattern] = None
  val stmts: List[Statement] = newList()
  stmts.add(
    Statement(
      kind = SLocal(
        binding = LBVal(
          pat = Pattern(kind = PBinding(name = name, inner = noInner), span = sp),
          ty = Some(value = ty),
          init = init
        )
      ),
      span = sp
    )
  )
  val segs: List[String] = newList()
  segs.add(name)
  stmts.add(
    Statement(
      kind = SExpr(expr = Expr(kind = EPath(path = ModulePath(segments = segs, span = sp)), span = sp)),
      span = sp
    )
  )
  Block(statements = stmts, span = sp)
}

/// The value-generic functions of the other packages of the project, which
/// the middle end specialises at each call (D167, D173): codegen
/// instantiates other generics itself, but has no value-argument form, so a
/// method of another package's value-generic record (`Vec.total[N: Nat]`)
/// is specialised before it.
func siblingValueGenericFuncs(importedPkgs: in List[ImportedPackage], ownPkg: in String): List[FunctionDecl] {
  val generics: List[FunctionDecl] = newList()
  for ip in importedPkgs {
    if ip.name != ownPkg {
      pipeAddGenericFuncs(ip.items, ip.name, false, false, generics)
    }
  }
  val valueGenerics: List[FunctionDecl] = newList()
  for g in generics {
    if hasValueGenericParam(g.generics) {
      valueGenerics.add(g)
    }
  }
  valueGenerics
}

func hasValueGenericParam(g: in Option[GenericParams]): Bool {
  match g {
    case Some(gp) -> {
      for p in gp.params {
        match p {
          case GPValue(_, _, _) -> return true
          case GPType(_, _) -> ()
        }
      }
      false
    }
    case None -> false
  }
}

/// Adds each specialisation of a value-generic record that one package
/// made of another package's record to the declaring package's file, once
/// (D173 item 3): every package then names the one `Pkg.Vec__V3`, and the
/// declaring package keeps its own specialisation when it made one itself.
func withForeignValueRecords(files: in List[SourceFile], records: in List[ForeignValueRecord]): Unit {
  if records.count == 0 {
    return
  }
  var fi = 0
  while fi < files.count {
    val f = files[fi]
    val pkg = dottedPath(f.packageDecl.path)
    val present: Map[String, Bool] = newMap()
    for it in f.items {
      val name = recordItemName(it)
      if name.length > 0 and not present.containsKey(name) {
        present.add(name, true)
      }
    }
    val added: List[Item] = newList()
    for fr in records {
      val name = recordItemName(fr.item)
      if fr.pkg == pkg and name.length > 0 and not present.containsKey(name) {
        present.add(name, true)
        added.add(fr.item)
      }
    }
    if added.count > 0 {
      val items: List[Item] = newList()
      for it in f.items {
        items.add(it)
      }
      for it in added {
        items.add(it)
      }
      files[fi] = f.copy(items = items)
    }
    fi = fi + 1
  }
}

func recordItemName(it: in Item): String {
  match it.kind {
    case IRecord(d) -> d.name
    case IExposedRec(d) -> d.name
    case IOpaque(d) -> d.name
    case IUnion(d) -> d.name
    case _ -> ""
  }
}

/// `file` with `generics` (visible generic functions, as they stood before
/// monomorphisation) appended, for codegen's own instantiation at a
/// cross-package call.
func withGenericItems(file: in SourceFile, generics: in List[Item]): SourceFile {
  if generics.count == 0 {
    return file
  }
  val items: List[Item] = newList()
  for it in file.items {
    items.add(it)
  }
  for g in generics {
    items.add(g)
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
  )
}

// Native stores a module-level `val` with a non-literal initializer in a static
// global that start-up code fills in (`Lyric.LlvmCodegen.loadModuleGlobal`).
// That initializer becomes a function, appended here BEFORE type check and
// monomorphisation so a generic initializer (`val m: Map[Int, V] = newMap()`)
// is checked and instantiated like any call. Only a `val` with a declared type
// is hoisted (the function needs a return type); the `val` itself stays so
// name resolution and the type check are unchanged.
func hoistModuleValInits(sf: in SourceFile): SourceFile {
  val items: List[Item] = newList()
  val hoisted: List[Item] = newList()
  for it in sf.items {
    match it.kind {
      case IVal(decl) -> {
        match decl.pattern.kind {
          case PBinding(vn, _) -> {
            match decl.ty {
              case Some(ty) -> {
                if not isLiteralInit(decl.init) {
                  val noDocs: List[DocComment] = newList()
                  val noAnns: List[Annotation] = newList()
                  val noParams: List[Param] = newList()
                  val noContracts: List[ContractClause] = newList()
                  val fd = FunctionDecl(
                    docComments = noDocs,
                    annotations = noAnns,
                    visibility = None,
                    isAsync = false,
                    name = mvInitFnName(vn),
                    generics = None,
                    params = noParams,
                    ret = Some(value = ty),
                    whereClause = None,
                    contracts = noContracts,
                    body = Some(value = FBBlock(block = typedInitBlock(ty, decl.init, decl.span))),
                    span = decl.span
                  )
                  hoisted.add(
                    Item(docComments = noDocs, annotations = noAnns, visibility = None, kind = IFunc(decl = fd), span = it.span)
                  )
                  // The `val` now just calls its initializer function, so the
                  // (possibly generic) initializer expression lives only in
                  // the typed hoisted body.
                  val segs: List[String] = newList()
                  segs.add(mvInitFnName(vn))
                  val noArgs: List[CallArg] = newList()
                  val callee = Expr(kind = EPath(path = ModulePath(segments = segs, span = decl.span)), span = decl.span)
                  val callInit = Expr(kind = ECall(fn = callee, args = noArgs), span = decl.span)
                  val newDecl = ValDecl(pattern = decl.pattern, ty = decl.ty, init = callInit, span = decl.span)
                  items.add(
                    Item(
                      docComments = it.docComments,
                      annotations = it.annotations,
                      visibility = it.visibility,
                      kind = IVal(decl = newDecl),
                      span = it.span
                    )
                  )
                } else {
                  items.add(it)
                }
              }
              case None -> items.add(it)
            }
          }
          case _ -> items.add(it)
        }
      }
      case _ -> items.add(it)
    }
  }
  for h in hoisted {
    items.add(h)
  }
  SourceFile(
    moduleDoc = sf.moduleDoc,
    fileAnnotations = sf.fileAnnotations,
    packageDecl = sf.packageDecl,
    imports = sf.imports,
    items = items,
    span = sf.span
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Public entry point.
// ─────────────────────────────────────────────────────────────────────────────
/// Compile `source` to a native executable at `outputPath`.
///
/// `stdlibFiles` are the stdlib source files (native-kernel variant — see
/// `Lyric.Emitter.findStdlibSourcesNative`).  `triple` ""
/// means "the host triple per clang"; `optLevel` "" defaults to "2".
/// Returns true when the binary was produced.
pub func compileToNative(
  source: in String,
  outputPath: in String,
  stdlibFiles: in List[NativeStdlibFile],
  triple: in String,
  optLevel: in String,
): Bool {
  val noFlags: List[String] = newList()
  val noDefines: List[String] = newList()
  compileToNativeWithFlags(source, outputPath, stdlibFiles, triple, optLevel, noFlags, noDefines, "", true)
}

/// Each `alias X = T` reference resolved to `T` before the checker or the
/// codegen sees the file, as the MSIL and JVM bridges do (#6404): native
/// codegen lowers the types an alias names, never the alias itself.
func resolveTypeAliasesNative(file: in SourceFile): SourceFile {
  TAR.resolveAliasesInFile(BFR.collectFuncAliasTargets(file), file)
}

/// `resolveTypeAliasesNative` for a package of a project: the aliases it
/// declares, then the `pub` aliases of the project packages it imports.
func resolveProjectTypeAliasesNative(file: in SourceFile, projectFiles: in List[SourceFile]): SourceFile {
  TAR.resolveAliasesInFile(TAR.projectAliasTargets(file, projectFiles), file)
}

/// `compileToNative` with extra clang driver flags (e.g.
/// `-fsanitize=address` for the sanitizer-checked self-tests).
///
/// `path`, when non-empty, is `source`'s on-disk path (#6611): threaded
/// into `pipeParseAndErase` so parse-phase diagnostics name the real file
/// instead of unlabelled bare `gate("", …)` output — matching the MSIL and
/// JVM bridges' single-file diagnostics attribution (docs/63 §9.7 /
/// #6282/#6284). "" keeps the previous unlabelled behaviour.
pub func compileToNativeWithFlags(
  source: in String,
  outputPath: in String,
  stdlibFiles: in List[NativeStdlibFile],
  triple: in String,
  optLevel: in String,
  extraClangFlags: in List[String],
  defines: in List[String],
  path: in String,
  contractsEnabled: in Bool = true,
): Bool {
  compileToNativeWithShape(
    source,
    outputPath,
    stdlibFiles,
    triple,
    optLevel,
    extraClangFlags,
    defines,
    path,
    contractsEnabled,
    ""
  )
}

/// The parsed shape argument: `module`, `component`, or "" plus the options a
/// `[wasm]` manifest table adds (`component;version=1.2.0;world=w;stack=131072`).
/// An option the build does not use is ignored.
record ShapeSpec {
  base: String
  version: String
  world: String
  stack: Int
  /// `wit=<path>`: where the generated WIT is written ("" = beside the component).
  witOut: String
  /// `js`: also transpile the component with `jco` into `<stem>-js/`.
  jsBindings: Bool
}

func parseShapeSpec(spec: in String): ShapeSpec {
  val parts = Str.split(spec, ";")
  var version = ""
  var world = ""
  var stack = 0
  var witOut = ""
  var jsBindings = false
  var i = 1
  while i < parts.length {
    val part = parts[i]
    val eq = Str.indexOfRaw(part, "=")
    if eq < 0 {
      if part == "js" {
        jsBindings = true
      }
    } else {
      val key = Str.substring(part, 0, eq)
      val value = Str.substring(part, eq + 1)
      if key == "version" {
        version = value
      } else if key == "world" {
        world = value
      } else if key == "stack" {
        stack = match Parse.parseOptInt(value) { case Some(n) -> n; case None -> 0 }
      } else if key == "wit" {
        witOut = value
      }
    }
    i = i + 1
  }
  val base = if parts.length > 0 { parts[0] } else { "" }
  ShapeSpec(base = base, version = version, world = world, stack = stack, witOut = witOut, jsBindings = jsBindings)
}

func shapeStackSize(spec: in ShapeSpec): String {
  if spec.stack > 0 {
    spec.stack.toString()
  } else {
    "1048576"
  }
}

/// For `--shape component`: append the generated canonical-ABI shims to the
/// package's AST and record its exports in `pkgs`; any other shape passes the
/// file through.  Reports the shims' `W0040` notes and an internal failure.
func shimForComponent(
  file: in SourceFile, shape: in String, pkgs: in List[ComponentPkg], peers: in List[SourceFile]
): Option[SourceFile] {
  if parseShapeSpec(shape).base != "component" {
    return Some(value = file)
  }
  val r = componentRewriteFile(file, peers)
  for n in r.info.notes {
    Console.error(n)
  }
  if r.error.length > 0 {
    Console.error("error[N0018]: component shim generation failed for package " + r.info.pkg + ": " + r.error)
    return None
  }
  pkgs.add(r.info)
  Some(value = r.file)
}

/// `compileToNativeWithFlags` with the output shape: "" for an ordinary native
/// binary, "module" for the wasm32 browser/JS-host module plus JS glue
/// (docs/35 W3).
pub func compileToNativeWithShape(
  source: in String,
  outputPath: in String,
  stdlibFiles: in List[NativeStdlibFile],
  triple: in String,
  optLevel: in String,
  extraClangFlags: in List[String],
  defines: in List[String],
  path: in String,
  contractsEnabled: in Bool,
  shape: in String,
): Bool {
  val noFeatures: List[String] = newList()
  compileToNativeWithFeatures(
    source,
    outputPath,
    stdlibFiles,
    triple,
    optLevel,
    extraClangFlags,
    defines,
    path,
    contractsEnabled,
    shape,
    noFeatures,
    noFeatures
  )
}

/// `compileToNativeWithShape` for a single file built under a manifest's
/// `[features]` (D182): its `@cfg` items are erased with the active features
/// `activeFeatures` and the manifest-declared `declaredFeatures`, as a
/// `--target dotnet` or `--target jvm` build of the file erases them.
pub func compileToNativeWithFeatures(
  source: in String,
  outputPath: in String,
  stdlibFiles: in List[NativeStdlibFile],
  triple: in String,
  optLevel: in String,
  extraClangFlags: in List[String],
  defines: in List[String],
  path: in String,
  contractsEnabled: in Bool,
  shape: in String,
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
): Bool {
  // Parse + `@cfg` erasure with the `target.native` pseudo-feature
  // (D-N-013); `Lyric.Pipeline` owns the placement (erasure directly
  // after parse, before anything indexes the items).
  val nativeDefines = BD.decodeDefines(defines)
  val noOrigins: List[DiagUtil.MergedLineOrigin] = newList()
  val cfgFile = match pipeParseAndErase(source, "native", activeFeatures, declaredFeatures, nativeDefines, path, noOrigins) {
    case Some(f) -> f
    case None -> return false
  }
  val componentPkgs: List[ComponentPkg] = newList()
  val noPeers: List[SourceFile] = newList()
  val shimFile = match shimForComponent(cfgFile, shape, componentPkgs, noPeers) {
    case Some(f) -> f
    case None -> return false
  }

  // Pre-typecheck rewrite chain: alias rewrite only.  The native bridge
  // does not expand docs/58 wire/config templates or synthesise
  // `@stubbable` stubs yet — the `false` flags make that gap explicit
  // (docs/59 §9.2 divergence flag) instead of an invisible omission.
  val noWires: Map[String, WireExpand.CollectedWireTemplate] = newMap()
  val noConfigs: Map[String, WireExpand.CollectedConfigTemplate] = newMap()
  // Config-template declarations become `pub record` twins (docs/58 §3); the
  // collection runs over an alias-rewritten copy, as on the managed targets.
  WireExpand.collectWireTemplates(
    Aliases.rewriteFile(shimFile).items,
    dottedPath(shimFile.packageDecl.path),
    noWires,
    noConfigs
  )
  val plugins: Map[String, PluginExpand.PluginPackage] = newMap()
  PluginExpand.collectPluginPackage(shimFile, plugins)
  val userFile0 = match pipeExpandAndRewrite(shimFile, noWires, noConfigs, plugins, true, false, false, path, noOrigins) {
    case Some(f) -> hoistModuleValInits(resolveTypeAliasesNative(f))
    case None -> return false
  }

  // Parse the stdlib once: type items for the typecheck,
  // whole files (cfg-erased, alias-rewritten) for bundling.
  val stdlib = parseNativeStdlib(stdlibFiles)
  val importedPkgs = stdlib.importedPkgs
  val stdlibByPkg = stdlib.byPkg

  // Middle end (`Lyric.Pipeline` owns the order).  An error from any pass,
  // the type check included, fails the build before codegen, as on the
  // managed targets (#7910).  Mono is fed the stdlib's interface and
  // record decls so method-call returns and field projections on imported
  // types drive same-package call-site inference (#3813).  Imported GENERIC decls
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
  val noTemplates: Map[String, Weaver.CollectedTemplate] = newMap()
  val noSingleFileOrigins: List[DiagUtil.MergedLineOrigin] = newList()
  // #7198, audited in #7201: native has no protected region for a suspend
  // to sit inside.  `try`/`catch`/`throw` are not lowered at all (D-N-003: a
  // panic aborts, nothing unwinds), so codegen rejects them with N0007
  // before an `await` could ever be placed in one.  `true` keeps F0045 in
  // front of that, reporting the `?` shape at its own position, and means
  // F0045 accepts and rejects the same programs on every target.
  val optsCheckedOut: List[SourceFile] = newList()
  val optsRecvOut: Map[String, String] = newMap()
  val optsCallArities: Map[String, Int] = newMap()
  val opts = MiddleEndOptions(
    tcFatal = true,
    tcReport = false,
    pkgLabel = path,
    lineOrigins = noSingleFileOrigins,
    awaitInTryIsHazard = true,
    bindListLiteralTypes = true,
    awaitAsyncCalls = false,
    contractsEnabled = contractsEnabled,
    checkedSourceOut = optsCheckedOut,
    memberRecvClassesOut = optsRecvOut,
    methodCallAritiesOut = optsCallArities,
    typeArgCalleesOut = newMap(),
    genericItemsOut = newList(),
    foreignValueRecordsOut = newList(),
    nativeIntrinsics = true
  )
  val userFile = match pipeMiddleEnd(userFile0, importedPkgs, noDeriveImports, noImportedGenFuncs, pipeInterfaceDecls(importedItemsForMono), pipeRecordDecls(importedItemsForMono), noTemplates, opts, None) {
    case Some(f) -> f
    case None -> return false
  }
  val userPkg = dottedPath(userFile.packageDecl.path)
  if DiagUtil.diagReportAndAbort(nativeConfigBlockDiagnostics(userFile)) {
    return false
  }

  // Transitive stdlib import closure, in deterministic worklist order.
  val toBundle: List[SourceFile] = newList()
  val seen: Map[String, Bool] = newMap()
  val worklist: List[String] = newList()
  var ui = 0
  while ui < userFile.imports.count {
    worklist.add(dottedPath(userFile.imports[ui].path))
    ui = ui + 1
  }
  // `Std.Core` (`Option`/`Result`) is an implicit prelude (#8256): a program
  // that never imports it still names its types, as on the managed targets.
  if userPkg != "Std.Core" {
    worklist.add("Std.Core")
  }
  // `format1`-`format4` lower to `Std.String.formatArgs` (#7840).
  if pipeUsesFormatBuiltin(userFile) {
    worklist.add("Std.String")
  }
  var wi = 0
  while wi < worklist.count {
    val pkg = worklist[wi]
    wi = wi + 1
    if not seen.containsKey(pkg) {
      seen.add(pkg, true)
      match mapGet(stdlibByPkg, pkg) {
        case Some(f) -> {
          // Stdlib contracts are always enabled regardless of the consumer's
          // [contracts] enabled setting (#7748); stdlib authors'
          // contracts run in all cases. User package contracts are governed
          // by the manifest setting above (via MiddleEndOptions).
          val stdChecked = match checkBundledStdlibPackage(pkg, f, stdlib) {
            case Some(lowered) -> lowered
            case None -> return false
          }
          val stdElaborated = elaborateFileWithInterfaces(stdChecked, newList(), true)
          // `?`-propagation (#6954): a bundled Std.* package's own body can
          // use `?` just like the user file's, and `Lyric.LlvmCodegen`
          // cannot lower an un-rewritten `EPropagate` node — mirrors
          // `pipeCheckAndMono`'s propagate step for the entry file.
          val stdProp = lowerPropagateFile(stdElaborated, opts.awaitInTryIsHazard)
          if DiagUtil.diagReportAndAbortInPkg(stdlibDiagLabel(pkg, stdlib), stdProp.diagnostics) {
            return false
          }
          // `formatN` lowers here too (#7984), and links `Std.String` in.
          val stdFormatted = pipeLowerFormatBuiltins(stdProp.file)
          if pipeUsesFormatBuiltin(stdFormatted) {
            worklist.add("Std.String")
          }
          toBundle.add(stdFormatted)
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

  // Reachable function ids, plus an `impl:<Pkg>.<Record>` marker per bundled
  // impl whose record is constructed (`noteConstructedImplType`).
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
  seedImplMethods(userFile, bodyIndex, pkgOfId, reachable, fnWorklist)
  var bi2 = 0
  while bi2 < toBundle.count {
    indexFileFns(toBundle[bi2], bodyIndex, pkgOfId)
    bi2 = bi2 + 1
  }
  val pkgImports: Map[String, List[String]] = newMap()
  addPkgImports(pkgImports, userFile)
  var bi3 = 0
  while bi3 < toBundle.count {
    addPkgImports(pkgImports, toBundle[bi3])
    bi3 = bi3 + 1
  }
  val implTypes: Map[String, BundledImpl] = newMap()
  var bi4 = 0
  while bi4 < toBundle.count {
    indexBundledImpls(toBundle[bi4], implTypes)
    bi4 = bi4 + 1
  }
  walkReachableFns(fnWorklist, canonical, bareTrailing, bodyIndex, pkgOfId, reachable, pkgImports, implTypes)

  // Assemble the codegen units: the user package in full, then each
  // bundled package's reachable slice.
  val units: List[CodegenUnit] = newList()
  units.add(unitOf(userFile, reachable, true, optsCallArities))
  appendBundledUnits(toBundle, reachable, units)

  linkAndEmitNative(units, 1, outputPath, triple, optLevel, extraClangFlags, shape, componentPkgs)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2.35. Multi-package native project build (#6809): the native analog of
// `Msil.Bridge.compileProjectToMsilWithRestoredAndVersion` /
// `Jvm.Bridge.compileProjectToJarBundledWithRestored` for a project's OWN
// `[project.packages]` and those of its path and workspace dependencies.
// Native has no restored-binary concept: like the `Std.*` stdlib sources, a
// dependency is compiled from source, and the CLI passes its packages in as
// further `NativeSourcePackage` entries, each with its own features (#7833).
// ─────────────────────────────────────────────────────────────────────────────
/// One own-package's pre-merged source for a native project build.
/// `Lyric.Emitter.emitNativeProject` merges a multi-file package's sources
/// into one compilation unit (the same `Lyric.PackageMerge` step the
/// MSIL/JVM project bridges use) before constructing these, so by the time a
/// package reaches here it is always exactly one valid `package` unit.
///
/// `path` (#6824 item 1) is this package's real on-disk path when it is a
/// single-file package (the MSIL/JVM `pkgPaths` parity field); "" for a
/// genuinely multi-file package (no single on-disk path names the merged
/// blob — see `originsByPkg` on `compileProjectToNativeWithFlags` for that
/// case's per-line attribution) or a synthetic/ad-hoc source, matching
/// `ProjectPackage.paths`' own "" convention for the identical case.
pub record NativeSourcePackage {
  name: String
  source: String
  path: String
  /// `Lyric.Pipeline.MiddleEndOptions.ioForbiddenReason` for the package
  /// (`[layers]`, D149); "" when it may do I/O.
  ioForbiddenReason: String = ""
  /// The `@cfg` features a dependency package is erased with: its own
  /// manifest's (#7833).  None for the project's own packages, which use the
  /// build's features.
  features: Option[PackageFeatureSet] = None
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

// #6824 item 1: resolve package `i`'s diagnostic label — its real on-disk
// path when known (single-file package), else its bare name (multi-file, or
// a synthetic/ad-hoc source) — matching the MSIL/JVM bridges' identical
// "path when known, else name" fallback (`Msil.Bridge`'s `pp.label` /
// `Jvm.Bridge`'s `pkgPathByName` lookups).
func nativePkgLabelAt(packages: in List[NativeSourcePackage], i: in Int): String {
  val p = packages[i]
  if p.path.length > 0 {
    p.path
  } else {
    p.name
  }
}

// Per-line provenance for package `i`, or empty when `originsByPkg` has no
// entry for it (shorter than `packages`, or a single-file package with
// nothing to translate) — mirrors `Jvm.Bridge`'s `originsByPkg[psi]`
// bounds-checked lookup.
func nativePkgOriginsAt(originsByPkg: in List[DiagUtil.PackageLineOrigins], i: in Int): List[DiagUtil.MergedLineOrigin] {
  if i < originsByPkg.count {
    originsByPkg[i].origins
  } else {
    newList()
  }
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
/// Every own package sees every OTHER own package's `pub`-AND-`internal`
/// surface as an `ImportedPackage` (`pipeIsCrossPackageItemProject`, #6580 —
/// a bundled stdlib package's cross-package items stay pub-only via
/// `pipeIsCrossPackageItem`), so `Web.OpenApi` importing `Web` (a
/// same-manifest import cycle, per the JVM bridge's
/// `compileProjectToJarBundledWithRestored` precedent for the identical
/// shape) resolves cleanly.  `triple` / `optLevel` / `extraClangFlags`
/// forward to `linkAndEmitNative` unchanged.
pub func compileProjectToNativeWithFlags(
  packages: in List[NativeSourcePackage],
  outputPath: in String,
  stdlibFiles: in List[NativeStdlibFile],
  triple: in String,
  optLevel: in String,
  extraClangFlags: in List[String],
  defines: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  packageVersion: in String,
  // Per-merged-line provenance for a genuinely multi-file own package,
  // parallel to `packages` by index (#6824 item 1; mirrors
  // `Msil.Bridge`/`Jvm.Bridge`'s `originsByPkg`/`pkgOriginsByName`
  // parameters). `originsByPkg[i]` is empty for a single-file package (its
  // real path already survives via `packages[i].path`) and non-empty for a
  // multi-file package, letting diagnostic rendering — across parse,
  // typecheck, modecheck, elaborate, propagate, mono, AND weave (all folded
  // into `pipeMiddleEnd` below, unlike the MSIL/JVM bridges' separate weave
  // phase) — resolve the merged blob's line numbers back to their real
  // on-disk file and line.  Shorter than `packages` (including empty) is
  // valid; missing entries resolve to no translation, matching the JVM
  // bridge's own out-of-range fallback.
  originsByPkg: in List[DiagUtil.PackageLineOrigins],
  contractsEnabled: in Bool = true,
): Bool {
  compileProjectToNativeWithShape(
    packages,
    outputPath,
    stdlibFiles,
    triple,
    optLevel,
    extraClangFlags,
    defines,
    activeFeatures,
    declaredFeatures,
    packageVersion,
    originsByPkg,
    contractsEnabled,
    ""
  )
}

/// `compileProjectToNativeWithFlags` with the output shape (see
/// `compileToNativeWithShape`).
pub func compileProjectToNativeWithShape(
  packages: in List[NativeSourcePackage],
  outputPath: in String,
  stdlibFiles: in List[NativeStdlibFile],
  triple: in String,
  optLevel: in String,
  extraClangFlags: in List[String],
  defines: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  packageVersion: in String,
  // Per-merged-line provenance for a genuinely multi-file own package,
  // parallel to `packages` by index (#6824 item 1; mirrors
  // `Msil.Bridge`/`Jvm.Bridge`'s `originsByPkg`/`pkgOriginsByName`
  // parameters). `originsByPkg[i]` is empty for a single-file package (its
  // real path already survives via `packages[i].path`) and non-empty for a
  // multi-file package, letting diagnostic rendering — across parse,
  // typecheck, modecheck, elaborate, propagate, mono, AND weave (all folded
  // into `pipeMiddleEnd` below, unlike the MSIL/JVM bridges' separate weave
  // phase) — resolve the merged blob's line numbers back to their real
  // on-disk file and line.  Shorter than `packages` (including empty) is
  // valid; missing entries resolve to no translation, matching the JVM
  // bridge's own out-of-range fallback.
  originsByPkg: in List[DiagUtil.PackageLineOrigins],
  contractsEnabled: in Bool,
  shape: in String,
): Bool {
  if packages.count == 0 {
    Console.error("error[N0005]: native project build received no packages")
    return false
  }

  val noFeatures: List[String] = newList()
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
  val componentPkgs: List[ComponentPkg] = newList()
  // #6824 item 1: label each own package's parse-phase diagnostics with its
  // real on-disk path when known, and translate a multi-file package's
  // merged-blob line numbers via `originsByPkg` — parity with the MSIL/JVM
  // project bridges (previously always the bare package name, no per-line
  // translation at all).
  var ppi = 0
  while ppi < packages.count {
    val pkgActive = match packages[ppi].features { case Some(pf) -> pf.active; case None -> activeFeatures }
    val pkgDeclared = match packages[ppi].features { case Some(pf) -> pf.declared; case None -> declaredFeatures }
    val cfgFile = match pipeParseAndErase(packages[ppi].source, "native", pkgActive, pkgDeclared, nativeDefines, nativePkgLabelAt(packages, ppi), nativePkgOriginsAt(originsByPkg, ppi)) {
      case Some(f) -> f
      case None -> return false
    }
    cfgFiles.add(cfgFile)
    ppi = ppi + 1
  }
  // Dot-named functions declared through an imported alias carry the
  // aliased type's name before anything indexes the packages (#8217).
  val canonicalCfg = canonicalAliasDotNamedAll(cfgFiles)
  var cci = 0
  while cci < canonicalCfg.count {
    cfgFiles[cci] = canonicalCfg[cci]
    cci = cci + 1
  }
  // The component shims of one package may name another package's `pub` types, so
  // they are generated once every own package is parsed (docs/35 W4, cross-package
  // types).  Other shapes pass the files through.
  val parsedPeers: List[SourceFile] = newList()
  for pf in cfgFiles {
    parsedPeers.add(pf)
  }
  var shi = 0
  while shi < parsedPeers.count {
    val shimFile = match shimForComponent(parsedPeers[shi], shape, componentPkgs, parsedPeers) {
      case Some(f) -> f
      case None -> return false
    }
    cfgFiles[shi] = shimFile
    shi = shi + 1
  }

  // Pre-typecheck rewrite chain: alias rewrite and config-template expansion
  // (a `pub config` template declares a `pub record` twin, docs/58 §3), matching
  // the single-source path. The native bridge does not synthesise `@stubbable`
  // stubs yet (docs/59 §9.2 divergence flag). Templates are collected from every
  // own package, dependencies included (native compiles them from source), over
  // alias-rewritten copies as on the managed targets.
  val noWires: Map[String, WireExpand.CollectedWireTemplate] = newMap()
  val noConfigs: Map[String, WireExpand.CollectedConfigTemplate] = newMap()
  // D207: every source package, for cross-package plugin references.
  val plugins: Map[String, PluginExpand.PluginPackage] = newMap()
  var wti = 0
  while wti < cfgFiles.count {
    PluginExpand.collectPluginPackage(cfgFiles[wti], plugins)
    WireExpand.collectWireTemplates(
      Aliases.rewriteFile(cfgFiles[wti]).items,
      dottedPath(cfgFiles[wti].packageDecl.path),
      noWires,
      noConfigs
    )
    wti = wti + 1
  }
  val ownFiles0: List[SourceFile] = newList()
  var owi = 0
  while owi < cfgFiles.count {
    // #6824 item 3: same label/origins attribution as the parse phase above
    // for this package's wire/config-template and impl-default-inheritance
    // diagnostics (`packages`/`originsByPkg` are 1:1 by index with
    // `cfgFiles` — no filtering happens between the two loops).
    val f0 = match pipeExpandAndRewrite(cfgFiles[owi], noWires, noConfigs, plugins, true, false, false, nativePkgLabelAt(packages, owi), nativePkgOriginsAt(originsByPkg, owi)) {
      case Some(f) -> f
      case None -> return false
    }
    ownFiles0.add(hoistModuleValInits(resolveProjectTypeAliasesNative(f0, cfgFiles)))
    owi = owi + 1
  }

  // Parse the stdlib once (identical to the single-source path).
  val stdlib = parseNativeStdlib(stdlibFiles)
  val importedPkgs: List[ImportedPackage] = newList()
  for ip in stdlib.importedPkgs {
    importedPkgs.add(ip)
  }
  val stdlibByPkg = stdlib.byPkg

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
      // #6580/#4900: these are the user's own project's sibling packages,
      // so `internal` items must be visible too — matches the MSIL/JVM
      // bridges' `pipeIsCrossPackageItemProject` for the identical
      // own-project-sibling shape (stdlib above stays pub-only).
      if pipeIsCrossPackageItemProject(f.items[ii]) {
        pkgItems.add(f.items[ii])
      }
      ii = ii + 1
    }
    val pn = dottedPath(f.packageDecl.path)
    importedPkgs.add(
      ImportedPackage(
        name = pn,
        items = pkgItems,
        imports = collectImportNames(f.imports),
        wholeImports = collectWholeImportNames(f.imports)
      )
    )
    oipi = oipi + 1
  }

  // Middle-end every own file against the shared stdlib+sibling pool.
  val ownFiles: List[SourceFile] = newList()
  // Each own file's `methodCallAritiesOut` (#7828), parallel to `ownFiles`.
  val ownCallArities: List[Map[String, Int]] = newList()
  val noDeriveImports: List[Item] = newList()
  val noTemplates: Map[String, Weaver.CollectedTemplate] = newMap()
  val importedItemsForMono = flattenImportedItems(importedPkgs)
  val importedInterfaceDecls = pipeInterfaceDecls(importedItemsForMono)
  val importedRecordDecls = pipeRecordDecls(importedItemsForMono)
  val foreignRecords: List[ForeignValueRecord] = newList()
  var mei = 0
  while mei < ownFiles0.count {
    // #6824 items 1/2: same label/origins attribution as the parse and
    // rewrite phases above — covers typecheck, modecheck, contract
    // elaboration, propagation, mono, AND weave in one place, since the
    // native bridge folds all of them into `pipeMiddleEnd` (docs/63 §9.6:
    // native has no separate weave phase the way `Msil.Bridge`/`Jvm.Bridge`
    // do).  Previously always `pkgLabel = ""` with no line translation.
    // #7198: see the other `MiddleEndOptions` construction site in this file.
    val optsCheckedOut: List[SourceFile] = newList()
    val optsRecvOut: Map[String, String] = newMap()
    val optsCallArities: Map[String, Int] = newMap()
    val optsGenericItems: List[Item] = newList()
    val optsForeignRecords: List[ForeignValueRecord] = newList()
    val opts = MiddleEndOptions(
      tcFatal = true,
      tcReport = false,
      pkgLabel = nativePkgLabelAt(packages, mei),
      lineOrigins = nativePkgOriginsAt(originsByPkg, mei),
      awaitInTryIsHazard = true,
      bindListLiteralTypes = true,
      awaitAsyncCalls = false,
      contractsEnabled = contractsEnabled,
      checkedSourceOut = optsCheckedOut,
      memberRecvClassesOut = optsRecvOut,
      methodCallAritiesOut = optsCallArities,
      typeArgCalleesOut = newMap(),
      genericItemsOut = optsGenericItems,
      foreignValueRecordsOut = optsForeignRecords,
      ioForbiddenReason = if mei < packages.count { packages[mei].ioForbiddenReason } else { "" },
      nativeIntrinsics = true
    )
    val siblingValueGenerics = siblingValueGenericFuncs(importedPkgs, dottedPath(ownFiles0[mei].packageDecl.path))
    val checked = match pipeMiddleEnd(ownFiles0[mei], importedPkgs, noDeriveImports, siblingValueGenerics, importedInterfaceDecls, importedRecordDecls, noTemplates, opts, None) {
      case Some(f) -> f
      case None -> return false
    }
    // Mono erased the package's visible generic functions; put them back so
    // codegen can instantiate them for a call from another package.
    ownFiles.add(withGenericItems(checked, optsGenericItems))
    ownCallArities.add(optsCallArities)
    for fr in optsForeignRecords {
      foreignRecords.add(fr)
    }
    mei = mei + 1
  }
  withForeignValueRecords(ownFiles, foreignRecords)
  var cfgFi = 0
  while cfgFi < ownFiles.count {
    if DiagUtil.diagReportAndAbort(nativeConfigBlockDiagnostics(ownFiles[cfgFi])) {
      return false
    }
    cfgFi = cfgFi + 1
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
    // `format1`-`format4` lower to `Std.String.formatArgs` (#7840).
    if pipeUsesFormatBuiltin(ownFiles[ofi]) {
      worklist.add("Std.String")
    }
    // `Std.Core` is an implicit prelude (#8256).
    if dottedPath(ownFiles[ofi].packageDecl.path) != "Std.Core" {
      worklist.add("Std.Core")
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
          // `?`-propagation (#6954): see the matching comment in
          // `compileToNativeWithFlags` — bundled Std.* packages need the
          // same desugar pass the own-project packages above already get.
          // `awaitInTryIsHazard = true`: F0045 stays on for native (#7198,
          // #7201; see the `MiddleEndOptions` sites above).
          // Stdlib contracts are always enabled (#7748).
          val stdChecked = match checkBundledStdlibPackage(pkg, f, stdlib) {
            case Some(lowered) -> lowered
            case None -> return false
          }
          val stdElaborated = elaborateFileWithInterfaces(stdChecked, newList(), true)
          val stdProp = lowerPropagateFile(stdElaborated, true)
          if DiagUtil.diagReportAndAbortInPkg(stdlibDiagLabel(pkg, stdlib), stdProp.diagnostics) {
            return false
          }
          // `formatN` lowers here too (#7984), and links `Std.String` in.
          val stdFormatted = pipeLowerFormatBuiltins(stdProp.file)
          if pipeUsesFormatBuiltin(stdFormatted) {
            worklist.add("Std.String")
          }
          toBundle.add(stdFormatted)
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

  // Reachable function ids, plus an `impl:<Pkg>.<Record>` marker per bundled
  // impl whose record is constructed (`noteConstructedImplType`).
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
    seedImplMethods(ownFiles[ifi], bodyIndex, pkgOfId, reachable, fnWorklist)
    ifi = ifi + 1
  }
  var bi2 = 0
  while bi2 < toBundle.count {
    indexFileFns(toBundle[bi2], bodyIndex, pkgOfId)
    bi2 = bi2 + 1
  }

  val pkgImports: Map[String, List[String]] = newMap()
  var pifi = 0
  while pifi < ownFiles.count {
    addPkgImports(pkgImports, ownFiles[pifi])
    pifi = pifi + 1
  }
  var bi3 = 0
  while bi3 < toBundle.count {
    addPkgImports(pkgImports, toBundle[bi3])
    bi3 = bi3 + 1
  }

  val implTypes: Map[String, BundledImpl] = newMap()
  var bi4 = 0
  while bi4 < toBundle.count {
    indexBundledImpls(toBundle[bi4], implTypes)
    bi4 = bi4 + 1
  }
  walkReachableFns(fnWorklist, canonical, bareTrailing, bodyIndex, pkgOfId, reachable, pkgImports, implTypes)

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
    units.add(unitOf(ownFiles[mainOwnIdx], reachable, true, ownCallArities[mainOwnIdx]))
  }
  var uoi = 0
  while uoi < ownFiles.count {
    if uoi != mainOwnIdx {
      units.add(unitOf(ownFiles[uoi], reachable, true, ownCallArities[uoi]))
    }
    uoi = uoi + 1
  }
  appendBundledUnits(toBundle, reachable, units)

  linkAndEmitNative(units, ownFiles.count, outputPath, triple, optLevel, extraClangFlags, shape, componentPkgs)
}

/// `N0025`: a `config { }` block (D046, docs/25) has no lowering on native
/// yet (#7435). Without this gate a program reading a config field reached
/// codegen's "unknown name" panic as an unhandled exception; the build now
/// stops with a normal diagnostic naming the block, as for the other
/// unsupported-on-native shapes.
func nativeConfigBlockDiagnostics(file: in SourceFile): List[Diagnostic] {
  val diags: List[Diagnostic] = newList()
  for it in file.items {
    match it.kind {
      case IConfig(decl) -> diags.add(
        errorDiagnostic(
          "N0025",
          "config block '" + decl.name +
            "' is not supported for --target native yet (docs/25; tracked in #7435); build for --target dotnet or --target jvm, or read the value from the environment with Std.Environment",
          it.span
        )
      )
      case _ -> ()
    }
  }
  diags
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
    val noArities: Map[String, Int] = newMap()
    val u = unitOf(toBundle[bi], reachable, false, noArities)
    if u.fns.count > 0 or u.externs.count > 0 or u.records.count > 0 or u.unions.count > 0 or u.enums.count > 0 or u.distincts.count > 0 or u.interfaces.count > 0 {
      units.add(u)
    }
    bi = bi + 1
  }
}

/// Each bundled/own file's OWN direct import package names, keyed by its
/// declaring package (#6625): the per-package adjacency `bareTrailing`
/// narrowing walks to approximate "could this call site's package
/// actually reach that candidate's declaring package via imports."
///
/// A package can span multiple files (`docs/19-multi-file-packages.md`),
/// each declaring its own import list, so this MERGES into whatever list
/// already sits under `pkg` rather than skipping once one file has been
/// seen — a first-file-wins skip silently dropped every later file's
/// imports for the same package, which could wrongly narrow `bareTrailing`
/// away from a genuinely-correct candidate (#6952).
pub func addPkgImports(pkgImports: in Map[String, List[String]], f: in SourceFile): Unit {
  val pkg = dottedPath(f.packageDecl.path)
  val imps: List[String] = match mapGet(pkgImports, pkg) {
    case Some(existing) -> existing
    case None -> {
      val fresh: List[String] = newList()
      pkgImports.add(pkg, fresh)
      fresh
    }
  }
  var i = 0
  while i < f.imports.count {
    imps.add(dottedPath(f.imports[i].path))
    i = i + 1
  }
}

/// BFS transitive closure of packages reachable from `root` via imports
/// (`root` itself included). Used to narrow `bareTrailing` candidates to
/// ones the calling package could plausibly have resolved unambiguously
/// itself — the type checker requires a cross-package callee's package be
/// imported (directly or transitively) for the ORIGINAL unambiguous call
/// to have type-checked at all, so the genuinely-correct candidate is
/// always inside this closure; this can only narrow away UNRELATED
/// same-named/arity candidates, never the real target (#6625).
pub func pkgTransitiveClosure(pkgImports: in Map[String, List[String]], root: in String): Map[String, Bool] {
  val seen: Map[String, Bool] = newMap()
  val worklist: List[String] = newList()
  seen.add(root, true)
  worklist.add(root)
  var wi = 0
  while wi < worklist.count {
    val p = worklist[wi]
    wi = wi + 1
    match mapGet(pkgImports, p) {
      case Some(imps) -> {
        var i = 0
        while i < imps.count {
          val q = imps[i]
          i = i + 1
          if not seen.containsKey(q) {
            seen.add(q, true)
            worklist.add(q)
          }
        }
      }
      case None -> {
      }
    }
  }
  seen
}

// ─────────────────────────────────────────────────────────────────────────────
// §2.4. Function-granularity reachability walk, shared by the single-source
// and multi-package native entry points (#6809): chases every call-key a
// worklist function's body names, resolving through `canonical` (exact
// package-qualified id) and `bareTrailing` (multi-valued UFCS fallback),
// mutating `reachable` and appending newly-discovered ids to `fnWorklist` in
// place — verbatim extraction of `compileToNativeWithFlags`'s original inline
// loop, no behavior change.
//
// `pkgImports` (#6625) narrows `bareTrailing`'s otherwise-bundle-wide
// candidate set per call site to the calling package's own transitive
// import closure — over-inclusive across two co-imported (but otherwise
// unrelated) packages that both happen to declare the same trailing
// name/arity, but no longer sweeps in a same-named candidate from a
// package the caller's own package can't even reach. A full precise fix
// needs receiver-type inference threaded into this syntax-only walk (see
// #6625) — this is a real, sound narrowing in the meantime, not a
// complete one.
// ─────────────────────────────────────────────────────────────────────────────
func walkReachableFns(
  fnWorklist: in List[String],
  canonical: in Map[String, String],
  bareTrailing: in Map[String, List[String]],
  bodyIndex: in Map[String, FunctionDecl],
  pkgOfId: in Map[String, String],
  reachable: in Map[String, Bool],
  pkgImports: in Map[String, List[String]],
  implTypes: in Map[String, BundledImpl],
): Unit {
  val pkgClosureMemo: Map[String, Map[String, Bool]] = newMap()
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
          noteConstructedImplType(raw, curPkg, implTypes, bodyIndex, pkgOfId, reachable, fnWorklist, pkgImports)
          // `raw` may ALSO be a bare UFCS trailing-segment key
          // (`collectCallKeys`'s "cfg.identity.rawHandle()" fallback):
          // resolve it through the multi-valued `bareTrailing` map
          // regardless of whether the ordinary single-valued `canonical`
          // lookup above already matched something (a different type's
          // same-named/arity method, per `registerBareTrailingSegment`'s
          // header) — mark reachable every candidate whose OWN declaring
          // package is within `curPkg`'s transitive import closure
          // (#6625); an empty `curPkg` (should not occur in practice —
          // every id in `pkgOfId` is registered with a real package name)
          // falls back to the old bundle-wide behavior rather than risk
          // silently under-including a genuine callee.
          // The same plain name in several packages: codegen resolves it
          // against the caller's DIRECT imports, so mark exactly those
          // candidates (not the whole transitive closure, which would pull
          // in unrelated packages' host seams).
          match mapGet(bareTrailing, "=" + raw) {
            case Some(sameName) -> {
              val direct: List[String] = match mapGet(pkgImports, curPkg) { case Some(d) -> d; case None -> newList() }
              for cand in sameName {
                val candPkg = match mapGet(pkgOfId, cand) { case Some(p) -> p; case None -> "" }
                var allowed = candPkg == curPkg
                for dp in direct {
                  if dp == candPkg {
                    allowed = true
                  }
                }
                if allowed and not reachable.containsKey(cand) {
                  reachable.add(cand, true)
                  fnWorklist.add(cand)
                }
              }
            }
            case None -> {
            }
          }
          match mapGet(bareTrailing, raw) {
            case Some(targets) -> {
              val closure = if curPkg.length == 0 {
                val none: Map[String, Bool] = newMap()
                none
              } else {
                match mapGet(pkgClosureMemo, curPkg) {
                  case Some(c) -> c
                  case None -> {
                    val c = pkgTransitiveClosure(pkgImports, curPkg)
                    pkgClosureMemo.add(curPkg, c)
                    c
                  }
                }
              }
              var ti = 0
              while ti < targets.count {
                val bt = targets[ti]
                ti = ti + 1
                val btPkg = match mapGet(pkgOfId, bt) { case Some(p) -> p; case None -> "" }
                val inClosure = curPkg.length == 0 or btPkg == curPkg or closure.containsKey(btPkg)
                if inClosure and not reachable.containsKey(bt) {
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
  ownUnits: in Int,
  outputPath: in String,
  triple: in String,
  optLevel: in String,
  extraClangFlags: in List[String],
  shape: in String,
  componentPkgs: in List[ComponentPkg],
): Bool {
  // #7585: `Self` nested inside a generic type argument (`List[Self]`,
  // `Option[Self]`) in an interface method signature has no uniform
  // erased representation on native (unlike a bare `Self`, which erases
  // to a pointer-width raw pointer) — report it as a proper `N0006`
  // diagnostic and abort BEFORE codegen, exactly like the mode checker's
  // own pre-codegen gates (`N0100`, above), instead of letting
  // `Lyric.LlvmCodegen`'s internal (and here unreachable) defensive panic
  // surface as an unhandled exception with a stack trace.
  if DiagUtil.diagReportAndAbort(nativeSelfShapeDiagnostics(units)) {
    return false
  }
  // Resolve the target triple before codegen (the datalayout depends
  // on it, as does how a by-value record crosses the C boundary).
  var effTriple = normalizeNativeTriple(triple)
  if effTriple.length == 0 {
    effTriple = normalizeNativeTriple(detectHostTriple())
  }
  // docs/67 §4.2: a by-value aggregate the target's C ABI lowering does not
  // cover (#8009).
  if DiagUtil.diagReportAndAbort(nativeByValueExternDiagnostics(units, effTriple)) {
    return false
  }
  val isWasm = isWasmTriple(effTriple)
  val isWindows = isWindowsTriple(effTriple)
  // docs/67 G9: one Windows target, with the MSVC C runtime and ABI.
  if isWindows and effTriple != windowsTriple {
    Console.error(
      "error[N0025]: unsupported Windows target '" + effTriple + "'; the native backend targets " + windowsTriple +
        " (pass --triple " +
        windowsTriple +
        ")"
    )
    return false
  }
  val spec = parseShapeSpec(shape)
  val isComponent = spec.base == "component"
  val isModule = spec.base == "module"
  val witVersion = if spec.version.length > 0 { spec.version } else { componentVersion() }
  if spec.base.length > 0 and not isModule and not isComponent {
    Console.error(
      "error[N0012]: unknown native output shape '" + spec.base + "'; the wasm32 shapes are 'module' and 'component'"
    )
    return false
  }
  if (isModule or isComponent) and not isWasm {
    Console.error("error[N0011]: --shape " + spec.base + " needs a wasm32 triple (pass --triple wasm32-wasi)")
    return false
  }
  if isComponent {
    val clash = importConflict(componentPkgs)
    if clash.length > 0 {
      Console.error("error[N0019]: " + clash)
      return false
    }
  }
  val allExports = collectWasmExportsOfShaped(units, if isModule or isComponent { ownUnits } else { 0 }, isComponent)
  val wasmExports = if isModule { withoutReservedJsNames(allExports) } else { allExports }
  var ui = 0
  while ui < units.count {
    if units[ui].wasmImports.count > 0 and not isModule {
      Console.error(
        "error[N0015]: package " + units[ui].pkgName +
          " declares a @wasmImport extern func, which only a --shape module build can satisfy (build with --triple wasm32-wasi --shape module)"
      )
      return false
    }
    ui = ui + 1
  }
  if isComponent {
    markComponentHostTaskExterns(units, componentPkgs)
  }
  if wasmExports.importErrors.count > 0 {
    var ii = 0
    while ii < wasmExports.importErrors.count {
      Console.error(wasmExports.importErrors[ii])
      ii = ii + 1
    }
    return false
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

  val windowsAsan = isWindows and wantsAsan(extraClangFlags)
  val rtPath = if isWasm {
    findWasmRtArchive()
  } else if isWindows {
    findWindowsRtArchive(windowsAsan)
  } else {
    findLyricRtArchive()
  }
  if rtPath.length == 0 {
    if windowsAsan {
      Console.error(
        "error[N0003]: the Windows lyric_rt_md archive an AddressSanitizer build links was not found (set LYRIC_RT_WINDOWS_MD_PATH, or build it with `make -C lyric-rt windows`)"
      )
    } else if isWindows {
      Console.error(
        "error[N0003]: the Windows lyric_rt archive was not found (set LYRIC_RT_WINDOWS_PATH, or build it with `make -C lyric-rt windows`)"
      )
    } else if isWasm {
      Console.error(
        "error[N0003]: the wasm32 lyric_rt archive was not found (set LYRIC_RT_WASM32_PATH, or build it with `make -C lyric-rt wasm32-wasi WASI_SDK=<wasi-sdk>`)"
      )
    } else {
      Console.error("error[N0003]: lyric_rt.a not found (set LYRIC_RT_PATH, or build it with `make -C lyric-rt`)")
    }
    Console.error("  the LLVM IR was written to " + llPath)
    return false
  }
  val wasiSdk = if isWasm { findWasiSdk() } else { "" }
  if isWasm and wasiSdk.length == 0 {
    Console.error(
      "error[N0009]: a wasm32 build needs a wasi-sdk (set WASI_SDK_PATH to its install directory, e.g. /opt/wasi-sdk; docs/35 section 5.1)"
    )
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
  if isWasm {
    clangArgs.add("--target=" + effTriple)
    clangArgs.add("--sysroot=" + Path.join(Path.join(wasiSdk, "share"), "wasi-sysroot"))
    // wasm-ld only WARNS when a call's signature differs from the callee's
    // definition and then compiles the call to a trap; make that a link error
    // so an extern declared with the wrong width fails the build.
    clangArgs.add("-Wl,--fatal-warnings")
    if isModule {
      appendWasmModuleLinkArgs(clangArgs, wasmExports, shapeStackSize(spec))
    }
    if isComponent {
      clangArgs.add("-mexec-model=reactor")
      clangArgs.add("-Wl,-z,stack-size=" + shapeStackSize(spec))
    }
  } else if isWindows {
    // lld-link on every host: it is part of every LLVM install, so a Linux
    // host cross-links with the MSVC CRT and Windows SDK named by the
    // INCLUDE/LIB environment variables, and a Windows host needs no
    // Visual Studio link.exe.
    clangArgs.add("--target=" + effTriple)
    clangArgs.add("-fuse-ld=lld")
    if windowsAsan {
      // Windows AddressSanitizer runs only with the DLL C runtime; `-D_DLL`
      // makes the link step pick the matching runtime thunk.
      clangArgs.add("-fms-runtime-lib=dll")
      clangArgs.add("-D_DLL")
    }
  } else if triple.length > 0 {
    clangArgs.add("--target=" + triple)
  }
  // The component shape compiles generated C wrappers (canonical-ABI lift and
  // lower) into the same link, and links to a core module that is componentised
  // afterwards.
  val cabiPath = wasmGlueStem(outputPath) + ".cabi.c"
  val coreOut = if isComponent { wasmGlueStem(outputPath) + ".core.wasm" } else { outputPath }
  if isComponent {
    match File.writeText(cabiPath, renderCabi(componentPkgs, witVersion)) {
      case Ok(_) -> ()
      case Err(e) -> {
        Console.error("error[N0013]: cannot write the component wrappers " + cabiPath + ": " + IOError.message(e))
        return false
      }
    }
    clangArgs.add(cabiPath)
  }
  clangArgs.add(llPath)
  clangArgs.add(rtPath)
  if isWindows {
    // The math functions are part of the UCRT, and there is no libpthread or
    // libdl: threads, sockets and TLS use the Win32 API.
    for lib in windowsSystemLibs() {
      clangArgs.add(lib)
    }
  } else {
    clangArgs.add("-lm")
  }
  if not isWasm and not isWindows {
    clangArgs.add("-lpthread")
    // libdl for the lyric_tls.c OpenSSL seam's dlopen/dlsym (a no-op stub on
    // glibc >= 2.34; a real dependency on older glibc / musl). A program that
    // never references the TLS seam does not pull lyric_tls.o from the archive,
    // so this stays inert for non-TLS binaries. docs/61 §7, issue #5890.
    clangArgs.add("-ldl")
  }
  var li = 0
  while li < npkg.nativeLibs.count {
    if not (isWindows and isWindowsCrtLibrary(npkg.nativeLibs[li])) {
      clangArgs.add(nativeLinkArg(npkg.nativeLibs[li], isWindows))
    }
    li = li + 1
  }
  clangArgs.add("-o")
  clangArgs.add(if isWindows { nativeExecutablePath(coreOut, effTriple) } else { coreOut })
  val clangExe = if isWasm { Path.join(Path.join(wasiSdk, "bin"), "clang") } else { "clang" }
  match Process.runCapture(clangExe, clangArgs, 300000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        Console.error("error[N0004]: clang failed while compiling " + llPath + ":")
        Console.error(res.stderr)
        return false
      }
    }
    case Err(e) -> {
      if isWasm {
        Console.error(
          "error[N0001]: the wasi-sdk clang could not be run (" + clangExe +
            "); check that $WASI_SDK_PATH points at an installed wasi-sdk"
        )
        Console.error("  the LLVM IR was written to " + llPath)
      } else {
        Console.error(
          "error[N0001]: clang was not found on PATH (install it via your platform's package manager: `apt install clang`, Xcode CLI tools, ...)"
        )
        Console.error("  the LLVM IR was written to " + llPath + "; compile it manually with:")
        if isWindows {
          Console.error(
            "  clang --target=" + effTriple + " -fuse-ld=lld -O" + effOpt + " " + llPath + " " + rtPath + " " +
              Str.joinList(" ", windowsSystemLibs()) +
              " -o " +
              nativeExecutablePath(outputPath, effTriple)
          )
        } else {
          Console.error("  clang -O" + effOpt + " " + llPath + " " + rtPath + " -lm -lpthread -ldl -o " + outputPath)
        }
      }
      Console.error("  (" + e + ")")
      return false
    }
  }
  if windowsAsan and not bundleWindowsAsanDll(nativeExecutablePath(coreOut, effTriple), effTriple) {
    return false
  }
  // Keep the workspace clean on success; the .ll is a build
  // intermediate (re-emit with a failing clang run or via LYRIC_RT_PATH
  // tricks when debugging).
  if isModule {
    if not writeWasmGlue(outputPath, wasmExports) {
      return false
    }
  }
  if isComponent {
    if not buildComponent(coreOut, outputPath, componentPkgs, witVersion, spec.world, spec.witOut, spec.jsBindings) {
      return false
    }
  }
  if Environment.getVarOrDefault("LYRIC_KEEP_LL", "").length == 0 {
    match File.deleteFile(llPath) {
      case Ok(_) -> {
      }
      case Err(_) -> {
      }
    }
    if isComponent {
      match File.deleteFile(cabiPath) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }
      match File.deleteFile(coreOut) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }
    }
  }
  true
}

/// The WIT package version of a component whose build was given no version (no
/// `[wasm] version` and no project version).
func componentVersion(): String {
  "0.1.0"
}

/// A component's promise host import is reached through a generated C function
/// that returns the pending host task (D184 item 5).  Record each one as a
/// module-less promise import so codegen declares it returning the task and
/// awaits every call, as it does a `--shape module` promise import.
func markComponentHostTaskExterns(units: in List[CodegenUnit], pkgs: in List[ComponentPkg]): Unit {
  for p in pkgs {
    for h in p.imports {
      if h.isPromise {
        for u in units {
          for ef in u.externs {
            if ef.symbol == h.cSym and not wasmImportIsPromise(u.wasmImports, ef.symbol) {
              u.wasmImports.add(WasmImportDecl(symbol = ef.symbol, module = "", problem = "", isPromise = true))
            }
          }
        }
      }
    }
  }
}

/// Locate `wasm-tools`: `$WASM_TOOLS`, else `wasm-tools` on PATH.
func findWasmTools(): String {
  val env = Environment.getVarOrDefault("WASM_TOOLS", "")
  if env.length > 0 {
    return env
  }
  "wasm-tools"
}

/// Run one `wasm-tools` step; false (after printing `N0016`) on failure.
func runWasmTools(args: in List[String], what: in String): Bool {
  match Process.runCapture(findWasmTools(), args, 300000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        Console.error("error[N0016]: wasm-tools failed while " + what + ":")
        Console.error(res.stderr)
        return false
      }
      true
    }
    case Err(e) -> {
      Console.error(
        "error[N0016]: wasm-tools could not be run (" + findWasmTools() +
          "); install it (docs/35 section 5.1) or point $WASM_TOOLS at the binary (" +
          e +
          ")"
      )
      false
    }
  }
}

/// Wrap the linked core module `corePath` as a WASI component at `outputPath`:
/// write `<stem>.wit`, embed it, and componentise against the preview1 reactor
/// adapter (`$LYRIC_WASI_ADAPTER`).
func buildComponent(
  corePath: in String,
  outputPath: in String,
  pkgs: in List[ComponentPkg],
  version: in String,
  world: in String,
  witOut: in String,
  jsBindings: in Bool,
): Bool {
  val adapter = Environment.getVarOrDefault("LYRIC_WASI_ADAPTER", "")
  if adapter.length == 0 or not File.fileExists(adapter) {
    Console.error(
      "error[N0016]: a component build needs the WASI preview1 reactor adapter; set $LYRIC_WASI_ADAPTER to wasi_snapshot_preview1.reactor.wasm (docs/35 section 5.1)"
    )
    return false
  }
  val stem = wasmGlueStem(outputPath)
  val witPath = if witOut.length > 0 { witOut } else { stem + ".wit" }
  if witOut.length > 0 {
    // A failure here surfaces as the N0013 write error below, with the OS reason.
    match File.createDir(Path.dirname(witOut)) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
  }
  match File.writeText(witPath, renderWit(pkgs, version, world)) {
    case Ok(_) -> ()
    case Err(e) -> {
      Console.error("error[N0013]: cannot write the WIT file " + witPath + ": " + IOError.message(e))
      return false
    }
  }
  val embedded = stem + ".embedded.wasm"
  val embedArgs: List[String] = newList()
  embedArgs.add("component")
  embedArgs.add("embed")
  embedArgs.add(witPath)
  embedArgs.add(corePath)
  embedArgs.add("--world")
  embedArgs.add(witWorldName(pkgs, world))
  embedArgs.add("-o")
  embedArgs.add(embedded)
  if not runWasmTools(embedArgs, "embedding the WIT") {
    return false
  }
  val newArgs: List[String] = newList()
  newArgs.add("component")
  newArgs.add("new")
  newArgs.add(embedded)
  newArgs.add("--adapt")
  newArgs.add("wasi_snapshot_preview1=" + adapter)
  newArgs.add("-o")
  newArgs.add(outputPath)
  val ok = runWasmTools(newArgs, "componentising the module")
  match File.deleteFile(embedded) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  if ok and jsBindings {
    return transpileBindings(outputPath, stem + "-js", pkgs, version)
  }
  ok
}

/// `$JCO`, else `jco` on `PATH`.
func findJco(): String {
  val env = Environment.getVarOrDefault("JCO", "")
  if env.length > 0 {
    return env
  }
  "jco"
}

/// `--js-bindings`: transpile the component at `componentPath` with `jco` into
/// `outDir`, mapping every host import to the JavaScript module that satisfies it
/// (`jcoMapArgs`).  False (after printing `N0022`) when `jco` is missing or fails.
func transpileBindings(
  componentPath: in String, outDir: in String, pkgs: in List[ComponentPkg], version: in String
): Bool {
  val args: List[String] = newList()
  args.add("transpile")
  args.add(componentPath)
  args.add("-o")
  args.add(outDir)
  for a in jcoMapArgs(pkgs, version) {
    args.add(a)
  }
  match Process.runCapture(findJco(), args, 300000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        Console.error("error[N0022]: jco transpile failed:")
        Console.error(res.stderr)
        return false
      }
      true
    }
    case Err(e) -> {
      Console.error(
        "error[N0022]: --js-bindings needs jco (" + findJco() + "); install @bytecodealliance/jco or point $JCO at it (" + e +
          ")"
      )
      false
    }
  }
}

/// The runtime helpers the generated glue calls (`lyric-rt/src/lyric_wasm.c`).
/// They are unreferenced by Lyric code, so each one both forces its archive
/// member into the link (`--undefined`) and is exported by name.
func wasmGlueHelperSymbols(): List[String] {
  val names: List[String] = newList()
  names.add("lyric_wasm_abi_version")
  names.add("lyric_wasm_alloc")
  names.add("lyric_wasm_free")
  names.add("lyric_wasm_string_new")
  names.add("lyric_wasm_string_len")
  names.add("lyric_wasm_string_data")
  names.add("lyric_wasm_retain")
  names.add("lyric_wasm_release")
  names
}

/// Link flags for `--shape module` (docs/35 §4): a reactor module (no `_start`;
/// the glue calls `_initialize`, then exports), a 1 MiB shadow stack, the glue
/// helpers, and every exported `pub func`, plus `__main_argc_argv` when the
/// program has a `main`.
func appendWasmModuleLinkArgs(clangArgs: in List[String], set: in WasmExportSet, stack: in String): Unit {
  clangArgs.add("-mexec-model=reactor")
  clangArgs.add("-Wl,-z,stack-size=" + stack)
  val helpers = wasmGlueHelperSymbols()
  var hi = 0
  while hi < helpers.count {
    clangArgs.add("-Wl,--undefined=" + helpers[hi])
    clangArgs.add("-Wl,--export=" + helpers[hi])
    hi = hi + 1
  }
  var ei = 0
  var anyAsync = false
  while ei < set.exports.count {
    clangArgs.add("-Wl,--export=" + set.exports[ei].wasmName)
    if set.exports[ei].isAsync {
      anyAsync = true
    }
    ei = ei + 1
  }
  // An async export, or a host import returning a `Task[T]`, needs the scheduler
  // entry and the task accessors the glue polls with; a module with neither never
  // links the scheduler.  A host import also needs the helpers that finish the
  // pending task it hands back.
  var anyAsyncImport = false
  for imp in set.imports {
    if Str.startsWith(imp.ret, "Task:") {
      anyAsyncImport = true
    }
  }
  if anyAsync or anyAsyncImport {
    val asyncHelpers: List[String] = newList()
    asyncHelpers.add("lyric_wasm_poll")
    asyncHelpers.add("lyric_task_is_complete")
    asyncHelpers.add("lyric_task_result")
    if anyAsyncImport {
      asyncHelpers.add("lyric_wasm_host_task_new")
      asyncHelpers.add("lyric_wasm_host_finish_i32")
      asyncHelpers.add("lyric_wasm_host_finish_i64")
      asyncHelpers.add("lyric_wasm_host_finish_f32")
      asyncHelpers.add("lyric_wasm_host_finish_f64")
      asyncHelpers.add("lyric_wasm_host_finish_string")
      asyncHelpers.add("lyric_wasm_host_fail")
    }
    var ai = 0
    while ai < asyncHelpers.count {
      clangArgs.add("-Wl,--undefined=" + asyncHelpers[ai])
      clangArgs.add("-Wl,--export=" + asyncHelpers[ai])
      ai = ai + 1
    }
  }
  if set.hasMain {
    clangArgs.add("-Wl,--export=__main_argc_argv")
  }
}

/// `<output minus .wasm>` — the stem the glue `.js` and `.d.ts` share.
func wasmGlueStem(outputPath: in String): String {
  if Str.endsWith(outputPath, ".wasm") {
    return Str.substring(outputPath, 0, outputPath.length - 5)
  }
  outputPath
}

/// Write `<stem>.js` and `<stem>.d.ts` next to the module and print the
/// `W0040` notes for `pub func`s the glue cannot export.
func writeWasmGlue(outputPath: in String, set: in WasmExportSet): Bool {
  var ni = 0
  while ni < set.notes.count {
    Console.error(set.notes[ni])
    ni = ni + 1
  }
  val stem = wasmGlueStem(outputPath)
  val wasmFile = Path.basename(outputPath)
  match File.writeText(stem + ".js", renderGlueModule(set, wasmFile)) {
    case Ok(_) -> ()
    case Err(e) -> {
      Console.error("error[N0013]: cannot write the JS glue " + stem + ".js: " + IOError.message(e))
      return false
    }
  }
  match File.writeText(stem + ".d.ts", renderGlueTypes(set)) {
    case Ok(_) -> ()
    case Err(e) -> {
      Console.error("error[N0013]: cannot write the TypeScript declarations " + stem + ".d.ts: " + IOError.message(e))
      return false
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
        // A plain function name two packages both declare (`Std.Json.parseJson`
        // and `Std.Yaml.parseJson`): the walk marks every candidate in the
        // caller's import closure reachable, so codegen's import-aware
        // resolution has the right one to pick.
        if lastDotIndex(decl.name) < 0 {
          registerBareName(bareTrailing, decl.name, decl.params.count, id)
        }
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

func registerBareName(bareTrailing: in Map[String, List[String]], name: in String, arity: in Int, id: in String): Unit {
  val key = "=" + name + "/" + arity.toString()
  match mapGet(bareTrailing, key) {
    case Some(targets) -> targets.add(id)
    case None -> {
      val targets: List[String] = newList()
      targets.add(id)
      bareTrailing.add(key, targets)
    }
  }
}

func addKey(m: in Map[String, String], k: in String, v: in String): Unit {
  if not m.containsKey(k) {
    m.add(k, v)
  }
}

/// A bundled package's `impl <Iface> for <Record>` blocks, indexed by the
/// implementing record's package-qualified name.  The impl's vtable references
/// every one of its methods, so a bundled impl is lowered whole, and only when
/// a value of its record type can exist: when reachable code constructs the
/// record (`implTypeSeen`).  An interface-typed value is always built from an
/// implementing record, so no construction means no vtable is ever read.
record BundledImpl {
  pkg: String
  methods: List[FunctionDecl]
}

func implMarker(pkg: in String, recordName: in String): String {
  "impl:" + pkg + "." + recordName
}

/// Index `f`'s non-generic impl blocks by implementing record.
func indexBundledImpls(f: in SourceFile, idx: in Map[String, BundledImpl]): Unit {
  val pkg = dottedPath(f.packageDecl.path)
  for item in f.items {
    match item.kind {
      case IImpl(decl) -> {
        match implTargetRecordName(decl.target) {
          case Some(recordName) -> {
            val key = pkg + "." + recordName
            val methods: List[FunctionDecl] = match mapGet(idx, key) {
              case Some(existing) -> existing.methods
              case None -> {
                val fresh: List[FunctionDecl] = newList()
                idx.add(key, BundledImpl(pkg = pkg, methods = fresh))
                fresh
              }
            }
            collectImplMethods(pkg, decl, methods)
          }
          case None -> {
          }
        }
      }
      case _ -> {
      }
    }
  }
}

/// A call key names a bundled record with impls: mark its impl reachable and
/// seed the impl's methods so the walk follows their callees.
///
/// The record is named as the caller wrote it: unqualified in its own
/// package, fully qualified (`Std.Plugin.GrantAllRequested()`), or, from
/// another package, unqualified or through an import alias
/// (`GrantAllRequested()`, `P.GrantAllRequested()`).  The last two resolve
/// against the caller's direct imports, as the type checker resolved them;
/// aliases are not recorded here, so a qualified name also tries its last
/// segment in every directly imported package (over-inclusion only lowers
/// an impl no value reaches).
func noteConstructedImplType(
  callKey: in String,
  curPkg: in String,
  implTypes: in Map[String, BundledImpl],
  bodyIndex: in Map[String, FunctionDecl],
  pkgOfId: in Map[String, String],
  reachable: in Map[String, Bool],
  fnWorklist: in List[String],
  pkgImports: in Map[String, List[String]],
): Unit {
  // A call key is `<callee path>/<argument count>`.
  val slash = Str.indexOfRaw(callKey, "/")
  val key = if slash > 0 { Str.substring(callKey, 0, slash) } else { callKey }
  if curPkg.length > 0 and implTypes.containsKey(curPkg + "." + key) {
    markBundledImpl(curPkg + "." + key, implTypes, bodyIndex, pkgOfId, reachable, fnWorklist)
    return
  }
  if implTypes.containsKey(key) {
    markBundledImpl(key, implTypes, bodyIndex, pkgOfId, reachable, fnWorklist)
    return
  }
  val segs = Str.split(key, ".")
  val bare = segs[segs.count - 1]
  if bare.length == 0 {
    return
  }
  match mapGet(pkgImports, curPkg) {
    case Some(direct) -> {
      for dp in direct {
        if implTypes.containsKey(dp + "." + bare) {
          markBundledImpl(dp + "." + bare, implTypes, bodyIndex, pkgOfId, reachable, fnWorklist)
        }
      }
    }
    case None -> {
    }
  }
}

/// Mark bundled impl `implKey` (`<pkg>.<Record>`) reachable, once, and seed
/// its methods.
func markBundledImpl(
  implKey: in String,
  implTypes: in Map[String, BundledImpl],
  bodyIndex: in Map[String, FunctionDecl],
  pkgOfId: in Map[String, String],
  reachable: in Map[String, Bool],
  fnWorklist: in List[String],
): Unit {
  if reachable.containsKey("impl:" + implKey) {
    return
  }
  reachable.add("impl:" + implKey, true)
  match mapGet(implTypes, implKey) {
    case Some(bi) -> seedMethodList(bi.pkg, bi.methods, bodyIndex, pkgOfId, reachable, fnWorklist)
    case None -> {
    }
  }
}

// An own package's `impl`, record and protected-type method bodies are lowered whole (`unitOf`'s
// `collectImplMethods`), so what they call must be reachable too: index each
// method under its lowered name and seed the walk with it. Without this a
// stdlib function called only from an impl method (`Std.HttpServer.nextContext`
// from an accept loop's `step`) never reaches the bundle.
func seedImplMethods(
  f: in SourceFile,
  bodyIndex: in Map[String, FunctionDecl],
  pkgOfId: in Map[String, String],
  reachable: in Map[String, Bool],
  fnWorklist: in List[String],
): Unit {
  val pkg = dottedPath(f.packageDecl.path)
  for item in f.items {
    match item.kind {
      case IImpl(decl) -> {
        val methods: List[FunctionDecl] = newList()
        collectImplMethods(pkg, decl, methods)
        seedMethodList(pkg, methods, bodyIndex, pkgOfId, reachable, fnWorklist)
      }
      case IRecord(decl) -> {
        val methods: List[FunctionDecl] = newList()
        collectRecordMethods(pkg, decl, methods)
        seedMethodList(pkg, methods, bodyIndex, pkgOfId, reachable, fnWorklist)
      }
      case IExposedRec(decl) -> {
        val methods: List[FunctionDecl] = newList()
        collectRecordMethods(pkg, decl, methods)
        seedMethodList(pkg, methods, bodyIndex, pkgOfId, reachable, fnWorklist)
      }
      case IProtected(decl) -> {
        val methods: List[FunctionDecl] = newList()
        collectProtectedMethods(pkg, decl, methods)
        seedMethodList(pkg, methods, bodyIndex, pkgOfId, reachable, fnWorklist)
      }
      case _ -> ()
    }
  }
}

func seedMethodList(
  pkg: in String,
  methods: in List[FunctionDecl],
  bodyIndex: in Map[String, FunctionDecl],
  pkgOfId: in Map[String, String],
  reachable: in Map[String, Bool],
  fnWorklist: in List[String],
): Unit {
  for fn in methods {
    val id = pkg + "." + fn.name + "/" + fn.params.count.toString()
    if not bodyIndex.containsKey(id) {
      bodyIndex.add(id, fn)
      pkgOfId.add(id, pkg)
    }
    if not reachable.containsKey(id) {
      reachable.add(id, true)
      fnWorklist.add(id)
    }
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
func unitOf(
  f0: in SourceFile, reachable: in Map[String, Bool], lowerAll: in Bool, arities: in Map[String, Int]
): CodegenUnit {
  // A member body's bare field references as `self.<name>` (#8264), as
  // `unitOfFile` does; a no-op for a file the middle end processed.
  val noRecords: List[RecordDecl] = newList()
  val noCases: Map[String, Bool] = newMap()
  val f = SelfFields.resolveSelfFieldsInFile(f0, noRecords, noCases)
  val pkg = dottedPath(f.packageDecl.path)
  val fns: List[FunctionDecl] = newList()
  val externs: List[ExternFuncDecl] = newList()
  val nativeLibs: List[String] = newList()
  val wasmImports: List[WasmImportDecl] = newList()
  val records: List[RecordDecl] = newList()
  val opaqueNames: List[String] = newList()
  val eqByFields: List[String] = newList()
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
          case PBinding(vn, _) -> moduleVals.add(ModuleValDef(name = vn, init = decl.init, ty = decl.ty, pkg = pkg))
          case _ -> ()
        }
      }
      case IConst(decl) -> moduleVals.add(
        ModuleValDef(name = decl.name, init = decl.init, ty = Some(value = decl.ty), pkg = pkg)
      )
      case IExternFunc(decl) -> {
        val id = pkg + "." + decl.name + "/" + decl.params.count.toString()
        if lowerAll or reachable.containsKey(id) {
          externs.add(decl)
          addExternLibrary(nativeLibs, f.items[i].annotations)
          addWasmImport(wasmImports, decl.symbol, f.items[i].annotations)
        }
      }
      case IRecord(decl) -> {
        records.add(decl)
        if recordComparesByFieldsNative(decl, f.items[i].annotations) {
          eqByFields.add(decl.name)
        }
        if lowerAll {
          collectRecordMethods(pkg, decl, fns)
        }
      }
      // Natively an exposed record is a record (`Lyric.LlvmCodegen`'s
      // single-package item walk).
      case IExposedRec(decl) -> {
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
          opaqueNames.add(decl.name)
        }
      }
      // Interface + impl (N3.2).  An interface is only a box and vtable type,
      // so every package contributes its own, as it does records: another
      // package's signature may name it.  An impl lowers whole (its vtable
      // references each method), so a bundled package's impl is taken only
      // once reachable code constructs its record (`noteConstructedImplType`).
      case IInterface(decl) -> {
        interfaces.add(decl)
      }
      case IImpl(decl) -> {
        val isGeneric = match decl.generics { case Some(_) -> true; case None -> false }
        val needed = not isGeneric and
          match implTargetRecordName(decl.target) {
            case Some(recordName) -> reachable.containsKey(implMarker(pkg, recordName))
            case None -> false
          }
        if lowerAll or needed {
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
    nativeLibs = nativeLibs,
    wasmImports = wasmImports,
    records = records,
    opaqueNames = opaqueNames,
    eqByFields = eqByFields,
    unions = unions,
    enums = enums,
    distincts = distincts,
    interfaces = interfaces,
    impls = impls,
    protecteds = protecteds,
    moduleVals = moduleVals,
    importsStdString = fileImportsStdString(f),
    imports = fileImportPackages(f),
    methodCallArities = arities
  )
}

/// Whether `@library(lib)` names the C library or its maths half, which on
/// Windows are the Universal C Runtime every program already links (there is
/// no `c.lib` or `m.lib`).
func isWindowsCrtLibrary(lib: in String): Bool {
  lib == "c" or lib == "m"
}

/// The clang argument that links library `lib` (D158): a path is an input
/// file, a file name (`libm.so.6`) is `-l:<name>`, and a base name
/// (`webview`) is `-l<name>`.  On Windows a file name (`webview.lib`) is an
/// input file too, which the linker looks for in the `LIB` directories; the
/// MSVC linker has no `-l:` form.
func nativeLinkArg(lib: in String, isWindows: in Bool): String {
  if Str.contains(lib, "/") or (isWindows and Str.contains(lib, "\\")) {
    lib
  } else if Str.contains(lib, ".") {
    if isWindows {
      lib
    } else {
      "-l:" + lib
    }
  } else {
    "-l" + lib
  }
}
