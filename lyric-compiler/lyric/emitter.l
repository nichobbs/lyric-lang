// lyric/emitter.l — Lyric.Emitter bootstrap package.
//
// Implements the `emit(req): EmitResult` contract that cli.l and repl.l
// depend on.  In the bootstrap phase the actual MSIL/JVM lowering still
// lives in the F# Lyric.Emitter project; this package shells out to the
// current `lyric` process (via `--internal-build`) to invoke it.
//
// Environment variables:
//   LYRIC_BIN      — path to the dotnet (or lyric) executable.
//                    Set automatically by Program.fs before routing to the
//                    self-hosted CLI.  Defaults to "lyric".
//   LYRIC_CLI_DLL  — when the CLI is a dotnet exec DLL rather than a
//                    native binary, this is set to the DLL path.
//                    Program.fs populates it from Assembly.GetEntryAssembly.
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

import Lyric.Lexer

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
// §2. Subprocess helpers
// ─────────────────────────────────────────────────────────────────────────────
//
// NOTE: lyrExe / lyrPrefixArgs / lyrArgs are duplicated verbatim in
// contract_meta.l.  If you change one, change both.  A shared
// `Lyric.CliShell` package would eliminate the duplication once the import
// graph permits it.
//
// The executable to invoke.  Two cases when LYRIC_CLI_DLL is set:
//   a) LYRIC_BIN is the AppHost native launcher for the DLL
//      (LYRIC_BIN + ".dll" == LYRIC_CLI_DLL).  Call it directly — the
//      AppHost already knows its DLL, no "exec" prefix is needed.
//   b) LYRIC_BIN is an explicit dotnet/wrapper executable (or unset).
//      Use dotnet + "exec <dll>" prefix to run the managed DLL.
// When LYRIC_CLI_DLL is unset, fall back to LYRIC_BIN or "lyric" on PATH.
func lyrIsAppHost(): Bool {
  val cliDll = Environment.getVarOrDefault("LYRIC_CLI_DLL", "")
  val bin    = Environment.getVarOrDefault("LYRIC_BIN",    "")
  Str.isNotEmpty(bin) and cliDll == bin + ".dll"
}

func lyrExe(): String {
  val cliDll = Environment.getVarOrDefault("LYRIC_CLI_DLL", "")
  if Str.isNotEmpty(cliDll) {
    val bin = Environment.getVarOrDefault("LYRIC_BIN", "")
    if Str.isNotEmpty(bin) and cliDll == bin + ".dll" {
      // AppHost mode: the native launcher IS the entry point for this DLL.
      bin
    } else {
      Environment.getVarOrDefault("LYRIC_BIN", "dotnet")
    }
  } else {
    Environment.getVarOrDefault("LYRIC_BIN", "lyric")
  }
}

// Leading args that must precede any subcommand args.
// Non-empty only when running under an explicit dotnet host (not AppHost).
func lyrPrefixArgs(): List[String] {
  val prefix: List[String] = newList()
  val cliDll = Environment.getVarOrDefault("LYRIC_CLI_DLL", "")
  if Str.isNotEmpty(cliDll) and not lyrIsAppHost() {
    prefix.add("exec")
    prefix.add(cliDll)
  }
  prefix
}

// Build the full args list for a lyric subcommand invocation.
func lyrArgs(subcmd: in List[String]): List[String] {
  val all: List[String] = newList()
  for a in lyrPrefixArgs().toArray() { all.add(a) }
  for a in subcmd.toArray()          { all.add(a) }
  all
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
  val tmpDir = Path.join(tempBase(), "lyric-emit")
  match File.createDir(tmpDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val outDir = Path.dirname(req.outputPath)
  if Str.isNotEmpty(outDir) {
    match File.createDir(outDir) {
      case Ok(_)  -> ()
      case Err(_) -> ()
    }
  }

  // Write each package's sources to temp files and build spec lines.
  // Spec line format: <packageName> TAB <srcPath1> TAB <srcPath2> ...
  val specLines: List[String] = newList()
  var pi = 0
  while pi < req.packages.count {
    val pkg = req.packages[pi]
    var line = pkg.name
    var si = 0
    while si < pkg.sources.count {
      val srcName = req.assemblyName + "__" + pkg.name + "__" + toString(si) + "__src.l"
      val srcPath = Path.join(tmpDir, srcName)
      match File.writeText(srcPath, pkg.sources[si]) {
        case Ok(_)  -> ()
        case Err(e) -> return failResult("cannot write temp source: " + IOError.message(e))
      }
      line = line + "\t" + srcPath
      si += 1
    }
    specLines.add(line)
    pi += 1
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
    case Err(e) -> return failResult("cannot write project spec: " + IOError.message(e))
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

  match Process.run(lyrExe(), lyrArgs(subcmd)) {
    case Ok(code) -> {
      if code != 0 {
        return failResult("project build failed (see stderr)")
      }
      val okDiags: List[Diagnostic] = newList()
      EmitResult(outputPath = Some(value = req.outputPath), diagnostics = okDiags)
    }
    case Err(e) ->
      return failResult("cannot launch compiler: " + IOError.message(e))
  }
}

/// Compile Lyric source to a .NET DLL or JVM JAR.
///
/// Shells out to `lyric --internal-build` which is handled by the F#
/// bootstrap CLI before it routes to the self-hosted CLI dispatcher.
/// Errors from the compiler are printed directly to stderr by the
/// subprocess; `EmitResult.diagnostics` carries a synthetic failure
/// marker so callers can detect the failure without parsing stderr.
@stable(since="0.1")
pub func emit(req: in EmitRequest): EmitResult {
  // Write source text to a temp file.
  val srcPath = match writeTempSource(req.source, req.assemblyName) {
    case Ok(p)  -> p
    case Err(e) ->
      return failResult("cannot write temp source: " + IOError.message(e))
  }

  // Ensure the output directory exists.
  val outDir = Path.dirname(req.outputPath)
  if Str.isNotEmpty(outDir) {
    match File.createDir(outDir) {
      case Ok(_)  -> ()
      case Err(_) -> ()   // non-fatal; `--internal-build` will report the failure
    }
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

  match Process.run(lyrExe(), lyrArgs(subcmd)) {
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
