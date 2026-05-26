// lyric/emitter.l — Lyric.Emitter bootstrap package.
//
// Implements the `emit(req): EmitResult` contract that cli.l and repl.l
// depend on.
//
// As of Track A (docs/41 §860, A1), `--target dotnet` single-source
// compilation runs IN-PROCESS via `Msil.Bridge.compileToMsil`.  No
// subprocess hop, no F# emitter touched at runtime.  `--target jvm`
// still uses the subprocess fallback because importing `Jvm.Bridge`
// here would pull `Jvm.Bytecode.BranchInsn` into the same F# emitter
// scope as `Lyric.Manifest.Branch` / `Lyric.GitDep.Branch` and the F#
// emitter has known issues with that closure (now mitigated by PR #868
// but not yet exhaustively retested for the JVM path).
//
// The subprocess shellout to `lyric --internal-build` also survives
// unconditionally when `LYRIC_FORCE_SUBPROCESS=1`, used by the
// bootstrap validation pipeline to compare in-process vs subprocess
// output, and for `emitProject` — multi-package + restored-dep builds
// still route through F# `Program.fs::internalProjectBuild` until the
// bridges gain a multi-package entry point.
//
// Environment variables:
//   LYRIC_FORCE_SUBPROCESS — set to "1" to opt out of the in-process
//                            compile path; forces every emit() call to
//                            shell back to `lyric --internal-build`.
//                            Default: in-process when available.
//   LYRIC_BIN              — path to the dotnet (or lyric) executable.
//                            Used by the subprocess fallback only.
//                            Set automatically by Program.fs before
//                            routing to the self-hosted CLI.
//                            Defaults to "lyric".
//   LYRIC_CLI_DLL          — when the CLI is a dotnet exec DLL rather
//                            than a native binary, this is set to the
//                            DLL path.  Subprocess-fallback only.
//                            Program.fs populates it from
//                            Assembly.GetEntryAssembly.
//
// Thread safety: emit() has no shared mutable state; it is safe to call
// concurrently.

@runtime_checked
package Lyric.Emitter

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str      // before Path so Path.join/2 wins over Str.join/2
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment

import Std.Uuid as Uuid
import Lyric.Lexer
import Lyric.CliShell as CliShell
import Lyric.ContractMeta as Meta
import Lyric.RestoredPackages as RP
import Msil.Bridge as MsilBridge

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public types  (mirrors the future-package contract in cli.l)
// ─────────────────────────────────────────────────────────────────────────────

pub union CompileTarget {
  case Dotnet
  case Jvm
}

pub record EmitRequest {
  source:       String
  assemblyName: String
  outputPath:   String
  target:       CompileTarget
}

pub record EmitResult {
  outputPath:  Option[String]
  diagnostics: List[Diagnostic]
}

/// Per-package source feed for `emitProject`.  Each package's `sources` list
/// holds the `.l` file contents in deterministic order (multi-file packages
/// should already be resolved by the caller).
pub record ProjectPackage {
  name:    String
  sources: List[String]
}

pub record EmitProjectRequest {
  packages:         List[ProjectPackage]
  assemblyName:     String
  outputPath:       String
  target:           CompileTarget
  /// Restored dependency DLL paths.  Each entry is "depName\tdllPath".
  /// Written to the spec file as `DEP\tdepName\tdllPath` lines.
  restoredDllPaths: List[String]
  /// Active feature flags for @cfg erasure.  Each entry is a feature name.
  /// Written to the spec file as `FEATURE\t<name>` lines.
  activeFeatures:   List[String]
  /// Declared feature flags from the manifest's `[features]` table.
  /// Used by `@cfg` erasure to fire `F0013` when a feature reference
  /// names a feature absent from this set (typo guard).  Distinct from
  /// `activeFeatures`: a declared-but-inactive feature suppresses
  /// F0013, while a feature absent from `declaredFeatures` raises it.
  /// An empty list disables the typo guard (F0013 is gated on
  /// `declared.count > 0`).
  declaredFeatures: List[String]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Subprocess helpers — thin wrappers over Lyric.CliShell.
// ─────────────────────────────────────────────────────────────────────────────
//
// The wrapper names below are deliberately distinct from CliShell's
// public surface: when the local function and the cross-package
// callee share a name, the bootstrap parser shadows the call site
// with the enclosing module's symbol, producing infinite recursion
// at runtime (observed via stack-overflow when both were named
// `lyrExe`).

func cliShellExe(): String { CliShell.lyrExe() }

func cliShellArgs(subcmd: in List[String]): List[String] {
  CliShell.lyrArgs(subcmd)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Temporary source file
// ─────────────────────────────────────────────────────────────────────────────

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR",
    Environment.getVarOrDefault("TEMP",
      Environment.getVarOrDefault("TMP", "/tmp")))
}

// Walk up from `start` looking for a directory whose direct child
// `lyric-stdlib/std/` exists.  Returns "" if no such ancestor is found
// within 32 hops.  Used by `findStdlibSources` to try multiple anchor
// points (app-base directory first, then CWD).
func walkUpForStdlib(start: in String): String {
  if start.length == 0 { return "" }
  var dir = start
  var hop = 0
  while hop < 32 {
    val candidate = Path.join(Path.join(dir, "lyric-stdlib"), "std")
    if File.dirExists(candidate) { return candidate }
    val parent = Path.dirname(dir)
    if parent.length == 0 or parent == dir { return "" }
    dir = parent
    hop = hop + 1
  }
  ""
}

// Locate the `lyric-stdlib/std/` directory at runtime, then read every
// top-level `*.l` source file (excluding the `_kernel/` subdirectory —
// those files contain extern declarations that aren't meaningful when
// surfaced to the parser as plain items).
//
// Probes (in order):
//   1. `$LYRIC_STD_PATH` if set — explicit override for installers /
//      CI scripts.
//   2. Walk up from `Std.Environment.appBaseDirectory()` — the
//      production CLI path, where the AOT binary's parent eventually
//      contains `lyric-stdlib/`.
//   3. Walk up from `Std.Environment.currentDirectory()` — the
//      development path, when the running DLL lives in a temp
//      directory but the shell that invoked it sits inside the repo.
//
// Returns the file contents as a `List[String]`.  Returns an empty list
// when the stdlib directory cannot be located (graceful degradation —
// callers fall back to advisory-only type checking, same as the F#
// `findStdlibSources` shim).
//
// Mirrors `bootstrap/src/Lyric.Cli/SelfHostedBridge.fs::findStdlibSources`
// and supersedes it on the in-process bridge path.  Tracked in #1183 as
// the change that removes the F# stdlib-source shim from the bridge
// surface.
func findStdlibSources(): List[String] {
  val sources: List[String] = newList()
  // 1. Explicit override.
  var stdlibDir = ""
  val envOverride = Environment.getVarOrDefault("LYRIC_STD_PATH", "")
  if envOverride.length > 0 and File.dirExists(envOverride) {
    stdlibDir = envOverride
  }
  // 2. AppContext.BaseDirectory walk.
  if stdlibDir.length == 0 {
    stdlibDir = walkUpForStdlib(Environment.appBaseDirectory())
  }
  // 3. CWD walk (typical for development / tests).
  if stdlibDir.length == 0 {
    stdlibDir = walkUpForStdlib(Environment.currentDirectory())
  }
  if stdlibDir.length == 0 { return sources }
  // Read every top-level `*.l` file.  `_kernel/` falls below the recursion
  // boundary, so `listFiles` (non-recursive) gives us exactly the right
  // surface — no post-filtering needed.
  val files = match File.listFiles(stdlibDir) {
    case Ok(fs)  -> fs
    case Err(_)  -> newList()
  }
  var fi = 0
  while fi < files.count {
    val f = files[fi]
    if Str.endsWith(f, ".l") {
      match File.readText(f) {
        case Ok(text) -> sources.add(text)
        case Err(_)   -> ()  // skip unreadable files, same as the F# shim
      }
    }
    fi = fi + 1
  }
  sources
}

// Write `source` to a temp file so `--internal-build` can read it.
// Returns the file path, or an IOError if the write fails.
func writeTempSource(source: in String, assemblyName: in String): Result[String, IOError] {
  val dir = Path.join(tempBase(), "lyric-emit")
  match File.createDir(dir) {
    case Ok(_)  -> ()
    case Err(_) -> ()   // ignore; dir may already exist
  }
  val path = Path.join(dir, assemblyName + "__src.l")
  match File.writeText(path, source) {
    case Ok(_)  -> Ok(value = path)
    case Err(e) -> Err(error = e)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. emit
// ─────────────────────────────────────────────────────────────────────────────

func failResult(msg: in String): EmitResult {
  val sp   = pointSpan(initialPosition())
  val diag = errorDiagnostic("B0001", msg, sp)
  val diags: List[Diagnostic] = newList()
  diags.add(diag)
  EmitResult(outputPath = None, diagnostics = diags)
}

/// Compile a multi-package project to a single bundled DLL or JAR.
///
/// Default path (#1183 Phase 4 — `--target dotnet` only): calls
/// `Msil.Bridge.compileProjectToMsil` in-process via a direct package
/// import.  No subprocess hop, no F# emitter touched at runtime.
///
/// Falls back to the `lyric --internal-project-build` subprocess (handled
/// by the F# bootstrap CLI) when:
///   - the target is JVM (the JVM bridge has no project-level entry
///     point yet),
///   - the request carries restored dependency DLLs (in-process bridge
///     does not yet thread `RestoredPackages` through the middle-end),
///   - or `LYRIC_FORCE_SUBPROCESS=1` is set for differential testing.
///
/// Active feature flags (`@cfg`-driven erasure) ARE now plumbed
/// through the in-process path via `compileProjectToMsilWithFeatures`
/// (#1183).  The subprocess path will be retired once restored deps
/// are plumbed through as well.
@stable(since="0.1")
pub func emitProject(req: in EmitProjectRequest): EmitResult {
  val outDir = Path.dirname(req.outputPath)
  if Str.isNotEmpty(outDir) {
    match File.createDir(outDir) {
      case Ok(_)  -> ()
      case Err(_) -> ()
    }
  }

  val canInProc = match req.target {
                    case Dotnet -> true
                    case Jvm    -> false
                  }
                  and not useSubprocessFallback()

  if canInProc {
    emitProjectInProcess(req)
  } else {
    emitProjectViaSubprocess(req)
  }
}

// In-process project emit — direct call into `Msil.Bridge.compileProjectToMsil`
// (#1183 Phase 4).  Each `ProjectPackage`'s multiple sources are joined with
// a newline boundary before being handed to the bridge, matching the F#
// `joinPackageSources` convention.  Diagnostics from the bridge land on
// stderr (same path as `compileToMsil`).
func emitProjectInProcess(req: in EmitProjectRequest): EmitResult {
  val payloads: List[ProjectPackagePayload] = newList()
  var pi = 0
  while pi < req.packages.count {
    val pkg = req.packages[pi]
    var combined = ""
    var si = 0
    while si < pkg.sources.count {
      if si > 0 { combined = combined + "\n" }
      combined = combined + pkg.sources[si]
      si += 1
    }
    payloads.add(ProjectPackagePayload(name = pkg.name, source = combined))
    pi += 1
  }
  // Auto-resolve `lyric-stdlib/std/*.l` at runtime so the in-process bridge
  // sees Std.Core / Std.Collections / etc. types at typecheck.  Without
  // this the typechecker rejects user code that imports `Std.Core`
  // (T0010 / T0020 on `Result`, `Option`, `Ok`, `None`, …) and the
  // codegen falls back to obj-typed handling, which silently miscompiles
  // cross-package union dispatch (#1140-style).  Mirrors the F# bootstrap
  // `Lyric.Cli.SelfHostedBridge.findStdlibSources` helper.
  val stdlibSources = findStdlibSources()

  // Load + synthesise each restored-dependency DLL.  `restoredDllPaths`
  // entries are "depName\tdllPath"; only the dllPath portion matters for
  // the in-process loader (depName is metadata for the F# subprocess
  // path's diagnostic surfaces).  If any DLL fails to load or synthesise
  // (e.g. the dep was built by the self-hosted bridge, which doesn't yet
  // emit `Lyric.Contract` resources), fall back to the F# subprocess
  // path which can build against the dep via reflection regardless of
  // contract presence.
  val restoredArtifacts: List[SynthesisedArtifact] = newList()
  var ri = 0
  while ri < req.restoredDllPaths.count {
    val depEntry  = req.restoredDllPaths[ri]
    val tabPos = depEntry.indexOf("\t")
    val dllPath = if tabPos >= 0 {
      depEntry.substring(tabPos + 1, depEntry.length - tabPos - 1)
    } else {
      depEntry
    }
    match RP.loadRestoredPackage(dllPath) {
      case Err(_) -> return emitProjectViaSubprocess(req)
      case Ok(arts) -> {
        var ai = 0
        while ai < arts.count {
          // Fresh preamble per call so a mutation by `synthesiseArtifact`
          // (intended read-only but not enforced by the type system)
          // can't leak across iterations.
          val preamble: List[Meta.ContractDecl] = newList()
          match RP.synthesiseArtifact(arts[ai], preamble) {
            case Err(_) -> return emitProjectViaSubprocess(req)
            case Ok(syn) -> restoredArtifacts.add(syn)
          }
          ai = ai + 1
        }
      }
    }
    ri = ri + 1
  }

  val ok = MsilBridge.compileProjectToMsilWithRestored(
    payloads, req.assemblyName, req.outputPath,
    stdlibSources, req.activeFeatures, req.declaredFeatures,
    restoredArtifacts)
  if ok {
    val okDiags: List[Diagnostic] = newList()
    EmitResult(outputPath = Some(value = req.outputPath), diagnostics = okDiags)
  } else {
    failResult("project build failed (see stderr)")
  }
}

// Subprocess project emit — preserved as the fallback for JVM target,
// restored-dep / feature-bearing requests, and `LYRIC_FORCE_SUBPROCESS=1`.
// Will be retired in #1183 Phase 5 once the in-process bridge covers every
// supported scenario.
func emitProjectViaSubprocess(req: in EmitProjectRequest): EmitResult {
  // Per-invocation subdirectory under lyric-emit/ keyed on a v4 UUID.
  // Two concurrent builds for the same assemblyName would otherwise
  // race on the spec / source filenames; the UUID guarantees a unique
  // namespace and a clean tree to delete on completion.
  val tmpRoot = Path.join(tempBase(), "lyric-emit")
  match File.createDir(tmpRoot) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }
  val tmpDir = Path.join(tmpRoot, Uuid.uuidToString(Uuid.newUuid()))
  match File.createDir(tmpDir) {
    case Ok(_)  -> ()
    case Err(e) -> return failResult("cannot create temp build directory: " + IOError.message(e))
  }

  // Helper: best-effort cleanup of the per-invocation temp directory.
  // Errors are swallowed so a transient file-handle leak doesn't fail
  // a successful build; the OS will sweep the parent eventually.
  // (#837: every early-exit path runs this before returning, so a
  // write failure never leaves an orphaned UUID directory.)

  // Write each package's sources to temp files and build spec lines.
  // Spec line format: <packageName> TAB <srcPath1> TAB <srcPath2> ...
  val specLines: List[String] = newList()
  var failMsg = ""
  var pi = 0
  while pi < req.packages.count and failMsg == "" {
    val pkg = req.packages[pi]
    var line = pkg.name
    var si = 0
    while si < pkg.sources.count and failMsg == "" {
      val srcName = req.assemblyName + "__" + pkg.name + "__" + toString(si) + "__src.l"
      val srcPath = Path.join(tmpDir, srcName)
      match File.writeText(srcPath, pkg.sources[si]) {
        case Ok(_)  -> ()
        case Err(e) -> { failMsg = "cannot write temp source: " + IOError.message(e) }
      }
      line = line + "\t" + srcPath
      si += 1
    }
    specLines.add(line)
    pi += 1
  }

  if failMsg != "" {
    match File.deleteDirRecursive(tmpDir) { case Ok(_) -> () case Err(_) -> () }
    return failResult(failMsg)
  }

  // Append restored dependency DLL lines: DEP\t<name>\t<dllPath>
  var di = 0
  while di < req.restoredDllPaths.count {
    specLines.add("DEP\t" + req.restoredDllPaths[di])
    di += 1
  }

  // Append active feature lines: FEATURE\t<name>
  var fi = 0
  while fi < req.activeFeatures.count {
    specLines.add("FEATURE\t" + req.activeFeatures[fi])
    fi += 1
  }

  // Append declared feature lines: DECLARED\t<name> for F0013 typo guard.
  var di2 = 0
  while di2 < req.declaredFeatures.count {
    specLines.add("DECLARED\t" + req.declaredFeatures[di2])
    di2 += 1
  }

  val specContent = Str.joinList("\n", specLines)
  val specPath = Path.join(tmpDir, req.assemblyName + "__project_spec.txt")
  match File.writeText(specPath, specContent) {
    case Ok(_)  -> ()
    case Err(e) -> { failMsg = "cannot write project spec: " + IOError.message(e) }
  }

  if failMsg != "" {
    match File.deleteDirRecursive(tmpDir) { case Ok(_) -> () case Err(_) -> () }
    return failResult(failMsg)
  }

  val targetStr = match req.target {
    case Dotnet -> "dotnet"
    case Jvm    -> "jvm"
  }

  val subcmd: List[String] = newList()
  subcmd.add("--internal-project-build")
  subcmd.add(specPath)
  subcmd.add("-o")
  subcmd.add(req.outputPath)
  subcmd.add("--target")
  subcmd.add(targetStr)

  val result = match Process.run(cliShellExe(), cliShellArgs(subcmd)) {
    case Ok(code) -> {
      if code != 0 {
        failResult("project build failed (see stderr)")
      } else {
        val okDiags: List[Diagnostic] = newList()
        EmitResult(outputPath = Some(value = req.outputPath), diagnostics = okDiags)
      }
    }
    case Err(e) ->
      failResult("cannot launch compiler: " + IOError.message(e))
  }

  match File.deleteDirRecursive(tmpDir) { case Ok(_) -> () case Err(_) -> () }

  result
}

/// Compile Lyric source to a .NET DLL or JVM JAR.
///
/// Default path (AOT-friendly): `--target dotnet` calls
/// `Msil.Bridge.compileToMsil` in-process via a direct package import.
/// No subprocess hop, no F# emitter touched at runtime.
///
/// `--target jvm` still uses the subprocess fallback (see header
/// comment for why).  Set `LYRIC_FORCE_SUBPROCESS=1` to route every
/// call through the subprocess shellout for differential testing.
@stable(since="0.1")
pub func emit(req: in EmitRequest): EmitResult {
  // Ensure the output directory exists so the bridges' raw byte-write
  // doesn't fail with ENOENT on the first build into a fresh tree.
  val outDir = Path.dirname(req.outputPath)
  if Str.isNotEmpty(outDir) {
    match File.createDir(outDir) {
      case Ok(_)  -> ()
      case Err(_) -> ()   // non-fatal; the bridge / subprocess will report
    }
  }

  if useSubprocessFallback() {
    emitViaSubprocess(req)
  } else {
    match req.target {
      case Dotnet -> emitMsilInProcess(req)
      // JVM stays on subprocess fallback (see header comment).
      case Jvm    -> emitViaSubprocess(req)
    }
  }
}

func useSubprocessFallback(): Bool {
  Environment.getVarOrDefault("LYRIC_FORCE_SUBPROCESS", "") == "1"
}

// In-process MSIL emit — direct call into `Msil.Bridge.compileToMsil`.
// Diagnostics from the bridge land on **stderr** (#893) via
// `Lyric.DiagnosticUtil`, matching the F# bootstrap CLI convention so
// IDE integrations, CI scripts, and `2>errors.txt` redirects continue
// to work the same way they did with the old subprocess path.  The
// bridge returns true on success and false on any error (parse,
// type-check, mode-check, codegen).
func emitMsilInProcess(req: in EmitRequest): EmitResult {
  // Auto-resolve `lyric-stdlib/std/*.l` so the bridge's typechecker sees
  // stdlib types at typecheck.  Mirrors the F# bootstrap shim
  // `Lyric.Cli.SelfHostedBridge.findStdlibSources` — see the parallel
  // comment in `emitProjectInProcess` for the rationale.
  val stdlibSources = findStdlibSources()
  val ok = MsilBridge.compileToMsil(req.source, req.outputPath, stdlibSources)
  if ok {
    val okDiags: List[Diagnostic] = newList()
    EmitResult(outputPath = Some(value = req.outputPath), diagnostics = okDiags)
  } else {
    failResult("MSIL compilation failed (see stderr)")
  }
}

// Subprocess fallback — preserved for `LYRIC_FORCE_SUBPROCESS=1` and
// the JVM target.  Writes the source to a temp file and shells back
// to `lyric --internal-build` which the F# bootstrap CLI dispatches
// through `Program.fs::internalBuild`.
func emitViaSubprocess(req: in EmitRequest): EmitResult {
  // Write source text to a temp file.
  val srcPath = match writeTempSource(req.source, req.assemblyName) {
    case Ok(p)  -> p
    case Err(e) ->
      return failResult("cannot write temp source: " + IOError.message(e))
  }

  val targetStr = match req.target {
    case Dotnet -> "dotnet"
    case Jvm    -> "jvm"
  }

  val subcmd: List[String] = newList()
  subcmd.add("--internal-build")
  subcmd.add(srcPath)
  subcmd.add("-o")
  subcmd.add(req.outputPath)
  subcmd.add("--target")
  subcmd.add(targetStr)

  match Process.run(cliShellExe(), cliShellArgs(subcmd)) {
    case Ok(code) -> {
      if code != 0 {
        return failResult("build failed (see stderr)")
      }
      val okDiags: List[Diagnostic] = newList()
      EmitResult(outputPath = Some(value = req.outputPath), diagnostics = okDiags)
    }
    case Err(e) ->
      return failResult("cannot launch compiler: " + IOError.message(e))
  }
}
