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
/// Shells out to `lyric --internal-project-build` which is handled by the F#
/// bootstrap CLI before it routes to the self-hosted CLI dispatcher.  Each
/// package's source texts are written to temp files; a tab-delimited spec file
/// lists all packages and their temp source paths.
@stable(since="0.1")
pub func emitProject(req: in EmitProjectRequest): EmitResult {
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

  val outDir = Path.dirname(req.outputPath)
  if Str.isNotEmpty(outDir) {
    match File.createDir(outDir) {
      case Ok(_)  -> ()
      case Err(_) -> ()
    }
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
// Diagnostics from the bridge land on stdout (see
// `msil/bridge.l:reportAndAbort`); the bridge returns true on success
// and false on any error (parse, type-check, mode-check, codegen).
// CLI consumers that want stderr-shaped diagnostics should layer a
// redirect at the dispatch boundary rather than inside the bridge.
func emitMsilInProcess(req: in EmitRequest): EmitResult {
  val ok = MsilBridge.compileToMsil(req.source, req.outputPath)
  if ok {
    val okDiags: List[Diagnostic] = newList()
    EmitResult(outputPath = Some(value = req.outputPath), diagnostics = okDiags)
  } else {
    failResult("MSIL compilation failed (see stdout)")
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
