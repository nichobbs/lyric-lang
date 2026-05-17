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

// ─────────────────────────────────────────────────────────────────────────────
// §2. Subprocess helpers
// ─────────────────────────────────────────────────────────────────────────────
//
// NOTE: lyrExe / lyrPrefixArgs / lyrArgs are duplicated verbatim in
// contract_meta.l.  If you change one, change both.  A shared
// `Lyric.CliShell` package would eliminate the duplication once the import
// graph permits it.
//
// The executable to invoke.  When LYRIC_CLI_DLL is set this is "dotnet";
// when only LYRIC_BIN is set (native binary or wrapper script) this is
// that value; otherwise fall back to "lyric" on PATH.
func lyrExe(): String {
  val cliDll = Environment.getVarOrDefault("LYRIC_CLI_DLL", "")
  if Str.isNotEmpty(cliDll) {
    // Running under `dotnet exec <dll>`; use the dotnet executable.
    Environment.getVarOrDefault("LYRIC_BIN", "dotnet")
  } else {
    Environment.getVarOrDefault("LYRIC_BIN", "lyric")
  }
}

// Leading args that must precede any subcommand args.
// Non-empty only when LYRIC_CLI_DLL is set (inserts "exec <dll>").
func lyrPrefixArgs(): List[String] {
  val prefix: List[String] = newList()
  val cliDll = Environment.getVarOrDefault("LYRIC_CLI_DLL", "")
  if Str.isNotEmpty(cliDll) {
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
