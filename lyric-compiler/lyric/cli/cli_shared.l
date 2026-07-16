//! lyric/cli/ — self-hosted Lyric CLI (Phase 5 §M5.3).
//!
//! Command dispatch for the `lyric` command-line tool.  Mirrors the F#
//! bootstrap CLI (compiler/src/Lyric.Cli/Program.fs) but written entirely
//! in Lyric.  Compiled by the self-hosted compiler during Phase 5 once
//! Lyric.Parser, Lyric.Emitter, Lyric.Fmt, Lyric.Lint, Lyric.Verifier,
//! and Lyric.Doc are available.
//!
//! Commands (project-aware: omit source file to auto-discover from lyric.toml):
//!   build   [<source.l>] [-o <output>] [--force] [--manifest <lyric.toml>]
//!              [--target dotnet|jvm]
//!   check   [<source.l>...] [--manifest <lyric.toml>] [--target dotnet|jvm]
//!   clean   [<dir>] [--manifest <lyric.toml>]
//!   run     [<source.l>] [--manifest <lyric.toml>] [--target dotnet|jvm] [--watch] [-- <args>...]
//!   fmt     [<source.l>...] [--manifest <lyric.toml>] [--check] [--write] [--stdin]
//!   lint    [<source.l>] [--manifest <lyric.toml>] [--error-on-warning]
//!   prove   [<source.l>] [--manifest <lyric.toml>] [--verbose] [--allow-unverified] [--json] [--explain --goal <n>]
//!   doc     [<source.l>] [--manifest <lyric.toml>] [-o <out.md|dir>]
//!   public-api-diff <old.dll> <new.dll>
//!   restore [--manifest <lyric.toml>]
//!   update  [--manifest <lyric.toml>]
//!   upgrade [--nuget | --dotnet-tool] [--github] [--version <version>] [--dir <dir>] [--dry-run]
//!   deps    [--manifest <lyric.toml>]
//!   publish [--manifest <lyric.toml>] [--dll <path>] [-o <dir>]
//!   test    [<source.l>] [--manifest <lyric.toml>] [--filter <prefix>] [--list]
//!   bench   [<source.l>] [--manifest <lyric.toml>] [--runs N] [--warmup N] [--filter <prefix>] [--target dotnet|jvm]
//!   openapi <spec.json> [-o <out.l>] [--client-name <Name>] [--package <Pkg>]
//!   --version / -v
//!
//! Future-package API contracts (packages not yet shipped; will exist
//! when this file is compiled in Phase 5):
//!
//!   Lyric.Parser:
//!     pub func parse(source: in String): ParseResult
//!     pub record ParseResult { file: SourceFile; diagnostics: List[Diagnostic] }
//!
//!   Lyric.Emitter:
//!     pub union CompileTarget { case Dotnet | case Jvm }
//!     pub record EmitRequest { source: String; assemblyName: String;
//!                              outputPath: String; target: CompileTarget }
//!     pub record EmitResult { outputPath: Option[String];
//!                             diagnostics: List[Diagnostic] }
//!     pub func emit(req: in EmitRequest): EmitResult
//!
//!   Lyric.Fmt:
//!     pub func format(parsed: in ParseResult): String
//!     pub func isFormatted(source: in String, parsed: in ParseResult): Bool
//!
//!   Lyric.Lint:
//!     pub union LintSeverity { case LintError | case LintWarning }
//!     pub record LintDiag { severity: LintSeverity; code: String;
//!                           message: String; line: Int; col: Int }
//!     pub record LintResult { diagnostics: List[LintDiag] }
//!     pub func lint(parsed: in ParseResult): LintResult
//!     pub func renderDiagnostic(d: in LintDiag): String
//!
//!   Lyric.Verifier:
//!     pub record ProveOptions { allowUnverified: Bool; verbose: Bool }
//!     pub record ProofSummary {
//!       diagnostics: List[Diagnostic]; totalCount: Int;
//!       dischargedCount: Int; isProofRequired: Bool;
//!       level: String; hadError: Bool }
//!     pub func prove(source: in String, options: in ProveOptions): ProofSummary
//!
//!   Lyric.Doc:
//!     pub func generate(parsed: in ParseResult): String
//!
//!   Lyric.ContractMeta:
//!     pub func readFromFile(path: in String): Option[String]
//!     pub func diffContracts(oldJson: in String, newJson: in String): List[String]
//!     pub func hasBreakingChanges(entries: in List[String]): Bool
package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.Errors
import Std.Hash as Hash
import Std.Json as Json
import Std.Yaml as Yaml
import Std.ProcessCapture as ProcessCapture
import Std.Time as Time
import Lyric.Manifest as Mf
import Lyric.Lexer
import Lyric.Workspace as Ws
import Lyric.Lockfile as LF
import Lyric.Discovery as Disc
import Lyric.Emitter as Emitter
import Lyric.ContractMeta as Meta
import Lyric.Version as Ver

func VERSION(): String {
  Ver.VERSION()
}

// ─────────────────────────────────────────────────────────────────────────────
// §1. Helpers
// ─────────────────────────────────────────────────────────────────────────────
func printErr(message: in String): Unit {
  Console.error(message)
}

func printDiag(d: in Diagnostic): Unit {
  val sev = match d.severity { case DiagError -> "error"; case DiagWarning -> "warning" }
  printErr(
    d.code + " " + sev + " [" + toString(d.span.startPos.line) + ":" + toString(d.span.startPos.column) + "]: " +
      d.message
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §1a. NuGet restore retry/backoff (NU1102 indexing lag)
//
// A Lyric package dependency declared in a manifest (e.g. a sibling
// ecosystem library published moments earlier in the same release run) can
// still 404 with NU1102 for a while after its own `dotnet nuget push`
// returned success -- NuGet.org's restore-side registration/validation
// pipeline lags behind the push, not just its full-text search index.
//
// A first cut of this retry (30s/60s/90s, 4 attempts, ~180s total) was
// observed in production still failing NU1102 on the final attempt for six
// ecosystem libraries at once (a whole release tier pushes its packages in
// a tight burst, which appears to make the lag worse) -- 180s falls short
// of NuGet.org's real worst-case propagation window, it isn't just close.
// Escalate for the first `nu1102EscalationAttempts` attempts, then hold at a
// plateau for the rest: `nu1102MaxAttempts` attempts total, ~660s (11 min)
// of backoff before giving up. Any restore failure that ISN'T NU1102 still
// fails immediately. Shared by `cmdPublish`'s temp-csproj restore and
// `cmdRestore`'s registry/[nuget] restore.
// ─────────────────────────────────────────────────────────────────────────────
pub val nu1102MaxAttempts = 8

pub val nu1102EscalationAttempts = 4

pub val nu1102BaseBackoffMs = 30000

pub val nu1102PlateauBackoffMs = nu1102EscalationAttempts * nu1102BaseBackoffMs

// Backoff duration (ms) before retrying the given (1-based) attempt number:
// ramps by `nu1102BaseBackoffMs` per attempt through `nu1102EscalationAttempts`,
// then holds flat at `nu1102PlateauBackoffMs`.
pub func backoffMsForAttempt(attempt: in Int): Int {
  if attempt <= nu1102EscalationAttempts {
    attempt * nu1102BaseBackoffMs
  } else {
    nu1102PlateauBackoffMs
  }
}

// Pure retry decision for a completed `dotnet restore` attempt: retry only
// on NU1102 (NuGet indexing lag) failures, never on a timeout, never on
// success, and never once `nu1102MaxAttempts` has been reached.
pub func shouldRetryRestore(
  exitCode: in Int, stdout: in String, stderr: in String, attempt: in Int, timedOut: in Bool
): Bool {
  if timedOut or exitCode == 0 or attempt >= nu1102MaxAttempts {
    false
  } else {
    stdout.contains("NU1102") or stderr.contains("NU1102")
  }
}

// Effective `dotnet restore` args for a given (1-based) attempt.  The first
// attempt uses the caller's args verbatim; every retry additionally passes
// `--no-http-cache`.  Without this, the first attempt's NU1102 ("package
// version not found") response is written to the on-disk HTTP cache, so a
// plain retry re-reads that stale negative in ~200ms instead of re-querying
// the feed — the retry fires but can never observe a sibling package that
// nuget.org has since indexed, which is why a just-published ecosystem
// dependency needed a whole fresh job rerun to resolve (#5644).
pub func restoreArgsForAttempt(baseArgs: in List[String], attempt: in Int): List[String] {
  if attempt <= 1 {
    baseArgs
  } else {
    val withNoCache: List[String] = newList()
    var ci = 0
    while ci < baseArgs.count {
      withNoCache.add(baseArgs[ci])
      ci += 1
    }
    if not stringListContains(baseArgs, "--no-http-cache") {
      withNoCache.add("--no-http-cache")
    }
    withNoCache
  }
}

// Run `dotnet restore` for the given args, retrying on NU1102 (NuGet
// indexing delay) with the escalating-then-plateau backoff above. `label`
// prefixes log/error output (e.g. "publish" or "restore") to match the
// caller's command.
pub func runRestoreWithRetry(restoreArgs: in List[String], label: in String): Int {
  var attempt = 1
  while attempt <= nu1102MaxAttempts {
    val effectiveArgs = restoreArgsForAttempt(restoreArgs, attempt)
    val captureResult = try {
      ProcessCapture.runCaptureWithDiagnosticsTimeout("dotnet", effectiveArgs, "", 300000)
    } catch Bug as b {
      CaptureResult(stdout = "", stderr = b.message, exitCode = -1, timedOut = false)
    }
    if not Str.isEmpty(captureResult.stdout) {
      Console.print(captureResult.stdout)
    }
    if not Str.isEmpty(captureResult.stderr) {
      Console.error(captureResult.stderr)
    }
    if captureResult.timedOut {
      printErr(label + ": dotnet restore timed out after 300 seconds")
      return 1
    }
    if captureResult.exitCode == -1 {
      printErr(label + ": dotnet restore failed to start (is dotnet on PATH?)")
      return 1
    }
    if captureResult.exitCode == 0 {
      return 0
    }
    if not shouldRetryRestore(captureResult.exitCode, captureResult.stdout, captureResult.stderr, attempt, captureResult.timedOut) {
      return captureResult.exitCode
    }
    val backoffMs = backoffMsForAttempt(attempt)
    printErr(
      label + ": NU1102 (NuGet indexing delay) on attempt " + toString(attempt) + "; retrying in " +
        toString(backoffMs / 1000) +
        "s"
    )
    Time.sleepMillis(backoffMs)
    attempt += 1
  }
  panic("unreachable: runRestoreWithRetry loop always returns")
}

// Single source of truth for the help text, grouped by workflow so it stays
// scannable.  `printUsage` writes it to stderr (the error/no-args paths);
// `lyric --help` writes the same text to stdout and exits 0.
func usageText(): String {
  "Usage: lyric [command] [args]\n" + "\n" + "  Run `lyric` with no command inside a project to build it.\n" + "\n" +
    "Project:\n" +
    "  lyric init    [<dir>] [--name <Name>] [--lib] [--force]\n" +
    "                (scaffold a new app (or --lib library) package: lyric.toml + src + .gitignore)\n" +
    "  lyric build   [<source.l>] [-o <output>] [--force] [--manifest <lyric.toml>] [--target dotnet|jvm|native] [--triple <llvm-triple>] [--opt 0|1|2|3|s] [--no-restore] [--watch]\n" +
    "                (no source: builds the discovered project's [project.packages] into one DLL;\n" +
    "                 auto-restores deps when lyric.lock is missing or stale unless --no-restore)\n" +
    "  lyric build   --release [<source.l>] [--manifest <lyric.toml>] [--rid <rid>] [-o <bin>]\n" +
    "                (self-contained Native AOT binary; no source: builds the discovered project)\n" +
    "  lyric check   [<source.l>...] [--manifest <lyric.toml>] [--target dotnet|jvm]\n" +
    "                (type-check without producing a usable output artifact)\n" +
    "  lyric clean   [<dir>] [--manifest <lyric.toml>]\n" +
    "                (remove bin/, .lyric-run/, .lyric-test/, .lyric-bench/, .lyric-check/, .lyric-release/)\n" +
    "  lyric restore [--manifest <lyric.toml>] [--locked]\n" +
    "  lyric update  [--manifest <lyric.toml>]\n" +
    "                (re-resolve all deps to latest compatible versions and rewrite lyric.lock)\n" +
    "  lyric upgrade [--nuget | --dotnet-tool] [--github] [--version <version>] [--dir <dir>] [--dry-run]\n" +
    "                (self-upgrade the lyric CLI to the latest or specific version)\n" +
    "  lyric deps    [--manifest <lyric.toml>]\n" +
    "                (print the resolved dependency tree from lyric.lock)\n" +
    "  lyric add     <name>[@<version>] [--path <dir>] [--git <url> [--tag|--rev|--branch <ref>]]\n" +
    "                [--nuget] [--manifest <lyric.toml>] [--no-restore]\n" +
    "                (adds/updates a dependency in [dependencies] (or [nuget]) and restores)\n" +
    "  lyric remove  <name> [--nuget] [--manifest <lyric.toml>] [--no-restore]\n" +
    "                (removes a dependency from [dependencies] (or [nuget]) and restores)\n" +
    "  lyric publish [--manifest <lyric.toml>] [--dll <path>] [-o <dir>] [--registry <url>] [--api-key <key>]\n" +
    "  lyric search  <term>\n" +
    "  lyric version [--manifest <lyric.toml>]\n" +
    "                (print the current package version)\n" +
    "  lyric version --set <semver> [--manifest <lyric.toml>]\n" +
    "                (update [package].version in lyric.toml)\n" +
    "  lyric version --workspace [--set <semver>]\n" +
    "                (print or update versions for all workspace members; warns on misalignment)\n" +
    "\n" +
    "Dev loop:\n" +
    "  lyric run     [<source.l>] [--manifest <lyric.toml>] [--target dotnet|jvm|native] [--watch] [-- <args>...]\n" +
    "                (no source: builds and runs the discovered project;\n" +
    "                 --watch: rebuild & re-run on source changes; Ctrl-C to stop)\n" +
    "  lyric test    [<source.l>] [--manifest <lyric.toml>] [--filter <prefix>] [--list] [--fail-fast] [--target dotnet|jvm]\n" +
    "                (no source: runs all [project.tests]; falls back to scanning [project.packages] for @test_module;\n" +
    "                 --fail-fast stops after the first file with failing tests)\n" +
    "  lyric bench   [<source.l>] [--manifest <lyric.toml>] [--target dotnet|jvm] [--runs N] [--warmup N] [--filter <prefix>]\n" +
    "                (no source: benchmarks all @bench_module files in the discovered project)\n" +
    "  lyric repl\n" +
    "\n" +
    "Quality:\n" +
    "  lyric fmt     [<source.l>...] [--manifest <lyric.toml>] [--check] [--write] [--diff] [--stdin]\n" +
    "                (no source: dry-run shows what would change; --write to apply; --check exits 1 if any would change;\n" +
    "                 --diff shows a unified diff of changes; --stdin reads from stdin and writes formatted output to stdout)\n" +
    "  lyric lint    [<source.l>] [--manifest <lyric.toml>] [--error-on-warning]\n" +
    "                (no source: lints all project source files; prints summary at end)\n" +
    "  lyric prove   [<source.l>] [--manifest <lyric.toml>] [--verbose] [--allow-unverified] [--json] [--explain --goal <n>]\n" +
    "                (no source: proves contracts in all project source files)\n" +
    "  lyric doc     [<source.l>] [--manifest <lyric.toml>] [-o <out.md|dir>]\n" +
    "                (no source: generates docs/ for all project source files)\n" +
    "  lyric public-api-diff <old.dll> <new.dll>\n" +
    "\n" +
    "\n" +
    "Codegen:\n" +
    "  lyric openapi <spec.json> [-o <out.l>] [--client-name <Name>] [--package <Pkg>]\n" +
    "\n" +
    "  lyric --version | --help\n" +
    "\n" +
    "Notes:\n" +
    "  build is incremental — same source + stdlib skips emit; --force rebuilds.\n" +
    "  build/restore/run/fmt/lint/prove/doc/test/bench/check/clean/update/deps all discover the nearest\n" +
    "  lyric.toml by walking up from the current directory when no source file is given.\n" +
    "  fmt:  no-arg project mode dry-run shows what would change; --write applies; --check exits 1 if any would change.\n" +
    "        --stdin reads stdin and writes formatted output to stdout (editor integration).\n" +
    "        All comment forms (//, ///, //!) are preserved by the CST formatter.\n" +
    "  lint: L001-L005 style checks. --error-on-warning exits 1 on warnings."
}

func printUsage(): Unit {
  printErr(usageText())
}

// Extract the top-level `compiler_version` string field from a parsed
// sdk-version.json document.  None when the field is absent or not a string.
func extractCompilerVersionFromJsonValue(root: in Yaml.YamlValue): Option[String] {
  match root {
    case Yaml.YMapping(pairs) -> {
      var i = 0
      while i < pairs.count {
        val pair = pairs[i]
        if pair.key == "compiler_version" {
          match pair.value {
            case Yaml.YString(v) -> return Some(value = v)
            case _ -> ()
          }
        }
        i += 1
      }
      None
    }
    case _ -> None
  }
}

// Read the sdk-version.json side-file from beside Lyric.Stdlib.dll and check
// that its compiler_version matches this binary's VERSION().  Missing file is
// silently ignored (dev builds and environments without a published SDK do not
// carry the file).  Returns 0 on match or absent file; returns 1 when
// LYRIC_STRICT_SDK_VERSION=1 and a mismatch is detected.
func checkSdkVersion(): Int {
  val libDir = findCompiledLibDir()
  if libDir.length == 0 {
    return 0
  }
  val sdkVersionPath = Path.join(libDir, "sdk-version.json")
  if not File.fileExists(sdkVersionPath) {
    return 0
  }
  val text = match File.readText(sdkVersionPath) { case Err(_) -> return 0; case Ok(t) -> t }
  // Parsed via the pure-Lyric Std.Yaml JSON parser (Result-returning) rather
  // than a manual indexOf extraction, so this is resilient to formatting
  // variation (pretty- vs compact-printed, reordered fields, extra
  // whitespace) instead of depending on the exact
  // `"compiler_version": "X.Y.Z"` byte layout the Makefile happens to emit
  // today.  Std.Yaml.parseJson is used over Std.Json here because it returns
  // a Result on malformed input rather than throwing (Std.Json.parseJson
  // throws on syntactically invalid JSON, #984) — appropriate since this
  // file's shape is not otherwise validated before we read it.
  val root = match Yaml.parseJson(text) { case Err(_) -> return 0; case Ok(v) -> v }
  val sdkVer = match extractCompilerVersionFromJsonValue(root) { case None -> return 0; case Some(v) -> v }
  if sdkVer == VERSION() {
    return 0
  }
  printErr(
    "warning: SDK version mismatch: compiler is " + VERSION() + " but Lyric.Stdlib.dll was built with compiler " +
      sdkVer +
      "."
  )
  printErr("  Hint: run 'lyric restore' or reinstall the Lyric SDK to align versions.")
  if Environment.getVarOrDefault("LYRIC_STRICT_SDK_VERSION", "") == "1" {
    printErr("error: aborting due to LYRIC_STRICT_SDK_VERSION=1")
    return 1
  }
  0
}

// Resolve the manifest a manifest-consuming command should use: an explicit
// --manifest wins; otherwise discover the nearest lyric.toml by walking up
// from the current directory (the project-aware default).
//
// An explicit relative path is absolutized against the current directory
// before being returned (mirroring `discoverManifestForSourceFile` in
// cli_build.l / D123): a bare relative manifest path like "lyric-web/lyric.toml"
// has `Path.dirname` == "lyric-web", and workspace-root walk-up
// (`Ws.findWorkspaceRoot`) from that relative directory can never reach any
// parent above the current directory — the walk needs an absolute starting
// point to climb past it (#5626 item 2).
//
// `pub` so `cli_shared_self_test.l` can drive it directly (same precedent
// as `resolveProjectSources`, #5333).
pub func discoverManifest(explicit: in Option[String]): Option[String] {
  match explicit {
    case Some(p) -> {
      val absP = if Path.isAbsolute(p) { p } else { Path.join(Environment.currentDirectory(), p) }
      Some(value = absP)
    }
    case None -> Disc.findNearestManifest(Environment.currentDirectory())
  }
}

// Outcome of resolving a project-mode command's source file list: shared by
// lint/doc/bench/fmt/prove, which all fork into project-mode when no
// positional source file is given.  A missing manifest and a fatal
// collection error are kept distinct because callers react differently
// (some print `printUsage()` on a missing manifest); `collectProjectSourcePaths`
// already reports its own fatal errors, so that case needs no extra message.
pub union ProjectSourcesResult {
  case ProjSourcesMissingManifest
  case ProjSourcesFatal
  case ProjSourcesFound(mfPath: String, paths: List[String])
}

// Discover the manifest (explicit --manifest or nearest lyric.toml) and
// collect its [project.packages] source paths.  Callers still print their
// own command-prefixed error messages, so wording is unchanged per command.
// `pub` so `cli_shared_self_test.l` can drive it directly against fixture
// manifests (#5333).
pub func resolveProjectSources(manifestArg: in Option[String]): ProjectSourcesResult {
  val mfPath = match discoverManifest(manifestArg) { case Some(p) -> p; case None -> return ProjSourcesMissingManifest }
  val (sourcePaths, hadFatal) = collectProjectSourcePaths(mfPath)
  if hadFatal {
    return ProjSourcesFatal
  }
  ProjSourcesFound(mfPath = mfPath, paths = sourcePaths)
}

// Whether `lyric build` should auto-restore before building: true when the
// manifest declares dependencies and `lyric.lock` is missing or out of sync
// with the `[dependencies]` table (a dep is absent from the lock, or a
// registry dep's locked version differs).  Conservative — returns true on any
// lock read/parse failure so a fresh restore corrects a corrupt lock.  The
// lock is resolved at the workspace root when one is found, else beside the
// manifest, matching `runRestore`'s own lock placement.
func lockNeedsRestore(mfPath: in String, manifest: in Manifest): Bool {
  if manifest.deps.count == 0 {
    return false
  }
  val mfDir = Path.dirname(mfPath)
  val lockPath = match Ws.findWorkspaceRoot(mfDir) {
    case Some(ctx) -> Path.join(ctx.rootDir, "lyric.lock")
    case None -> Path.join(mfDir, "lyric.lock")
  }
  if not File.fileExists(lockPath) {
    return true
  }
  val lf = match File.readText(lockPath) {
    case Err(_) -> return true
    case Ok(text) -> match LF.parseLockFile(text) { case Err(_) -> return true; case Ok(clf) -> clf }
  }
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    di += 1
    match LF.findPackage(lf, dep.name) {
      case None -> return true   // declared dependency not in the lock → stale
      case Some(locked) -> match dep.source {
        case Registry(v) -> if locked.version != v { return true }
        case _ -> ()  // path / workspace / git: presence suffices for the cheap check
      }
    }
  }
  false
}

// Return the stem of a filename (basename without final extension).
func stemOf(base: in String, extLen: in Int): String {
  val n = base.length
  if n > extLen {
    base.substring(0, n - extLen)
  } else {
    base
  }
}

// Return the output file extension for the managed assembly of a build.
// On Dotnet the assembly is always a managed `.dll`; `kind = "exe"` produces a
// separate native apphost launcher beside it (see `Lyric.AppHost`), it does not
// rename the assembly.  For Jvm: ".jar" (kind is currently a no-op).
func outputExt(target: in Emitter.CompileTarget, kind: in String): String {
  match target {
    case Emitter.Dotnet -> ".dll"
    case Emitter.Jvm -> ".jar"
    // A native build IS the executable; no extension on the Phase 1
    // POSIX targets (D-N-008).
    case Emitter.Native -> ""
  }
}

// Return the build kind from a manifest's [build] section, defaulting to "lib".
func getBuildKind(m: in Mf.Manifest): String {
  match m.build {
    case Some(section) -> section.kind
    case None -> "lib"
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Core build helper
// ─────────────────────────────────────────────────────────────────────────────
// Shared runtimeconfig skeleton — the TFM + framework version live here
// so they're maintained in one place (#1093).  `extra` is inserted at
// the end of the `runtimeOptions` block; pass an empty string for the
// minimal form, or the comma-prefixed `additionalProbingPaths` section.
func runtimeConfigJson(extra: in String): String {
  "{\n" + "  \"runtimeOptions\": {\n" + "    \"tfm\": \"net10.0\",\n" + "    \"framework\": {\n" +
    "      \"name\": \"Microsoft.NETCore.App\",\n" +
    "      \"version\": \"10.0.0\"\n" +
    "    }" +
    extra +
    "\n" +
    "  }\n" +
    "}\n"
}

// Write a minimal runtimeconfig.json next to `dllPath` so `dotnet exec`
// resolves the right runtime.  Failures are reported as warnings, not
// hard errors, because the DLL is already written at this point.
func writeRuntimeConfig(dllPath: in String): Unit {
  val dir = Path.dirname(dllPath)
  val base = stemOf(Path.basename(dllPath), 4)  // strip ".dll"
  val cfgPath = Path.join(dir, base + ".runtimeconfig.json")
  val json = runtimeConfigJson("")
  match File.writeText(cfgPath, json) {
    case Ok(_) -> ()
    case Err(e) -> printErr("build: warning: runtimeconfig: " + IOError.message(e))
  }
}

// Like writeRuntimeConfig but includes additionalProbingPaths in the JSON so
// that `dotnet exec` can locate referenced DLLs (e.g. Lyric.Stdlib.Testing)
// that live in dependency bin directories rather than the output directory.
func writeRuntimeConfigWithProbing(dllPath: in String, probingPaths: in List[String]): Unit {
  val dir = Path.dirname(dllPath)
  val base = stemOf(Path.basename(dllPath), 4)  // strip ".dll"
  val cfgPath = Path.join(dir, base + ".runtimeconfig.json")
  var probingSection = ""
  if probingPaths.count > 0 {
    probingSection = ",\n    \"additionalProbingPaths\": [\n"
    var pi = 0
    while pi < probingPaths.count {
      if pi > 0 {
        probingSection = probingSection + ",\n"
      }
      // Json.encodeString escapes quotes, backslashes, AND control characters
      // (newlines, tabs, NUL, etc.) per RFC 8259 §7 — a hardening upgrade over
      // the previous hand-rolled escaper, which only handled \ and " and would
      // emit raw control bytes for unusual paths (#1093).  Result is already
      // wrapped in quotes.
      probingSection = probingSection + "      " + Json.encodeString(probingPaths[pi])
      pi += 1
    }
    probingSection = probingSection + "\n    ]"
  }
  val json = runtimeConfigJson(probingSection)
  match File.writeText(cfgPath, json) {
    case Ok(_) -> ()
    case Err(e) -> printErr("build: warning: runtimeconfig: " + IOError.message(e))
  }
}

// True when `dir` holds the fully-compiled stdlib bundle.
func dirHasCompiledStdlib(dir: in String): Bool {
  dir.length > 0 and File.fileExists(Path.join(dir, "Lyric.Stdlib.dll"))
}

// Walk up from `start` (max 32 hops) looking for `<dir>/<rel>` that holds
// the compiled stdlib bundle; returns that directory or "".
func walkUpForCompiledStdlib(start: in String, rel: in String): String {
  if start.length == 0 {
    return ""
  }
  var dir = start
  var hop = 0
  while hop < 32 {
    val candidate = Path.join(dir, rel)
    if dirHasCompiledStdlib(candidate) {
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

// Locate the directory holding the fully-compiled stdlib runtime assemblies
// (`Lyric.Stdlib*.dll`).  Discovery is layout-agnostic — NO path is hardcoded
// — so a single-file `build` / `run` / `test` finds the *already-compiled*
// stdlib whether the CLI is the in-tree AOT binary (DLLs beside it), an
// installed SDK (`lib/` subdir), or a dev checkout (`.bootstrap/stage1` /
// `lyric-stdlib/bin`).  This replaces the previous reliance on the per-PID
// `/tmp/lyric-stdlib-*` recompile byproduct for runtime co-location.  First
// hit wins:
//   1. $LYRIC_STDLIB_BIN          — explicit override (used as-is; dir or .dll)
//   2. <appBaseDir>               — DLLs ship beside the binary
//   3. <appBaseDir>/lib           — installed SDK layout
//   4. walk up (appBase, cwd) for .bootstrap/stage1   — dev bootstrap output
//   5. walk up (appBase, cwd) for lyric-stdlib/bin     — dev manifest build
//   6. walk up (appBase, cwd) for .lyric-test          — lyric test cache dir
// When $LYRIC_STDLIB_BIN is set it is returned unconditionally; otherwise
// returns "" when no candidate holds `Lyric.Stdlib.dll`.  Kept in sync with
// `Lyric.Emitter.findCompiledStdlibDir` (emitter.l), which this mirrors (#3646).
func findCompiledLibDir(): String {
  val env = Environment.getVarOrDefault("LYRIC_STDLIB_BIN", "")
  if env.length > 0 {
    // Explicit override wins over all discovery and may name a directory or a
    // specific DLL (gating on the bundled `Lyric.Stdlib.dll` wrongly skipped
    // per-package self-builds, which emit only the split assemblies).  A `.dll`
    // path resolves to its containing directory whether or not it exists yet.
    if Str.endsWith(env, ".dll") {
      return Path.dirname(env)
    }
    return env
  }
  val appBase = Environment.appBaseDirectory()
  if dirHasCompiledStdlib(appBase) {
    return appBase
  }
  val appLib = Path.join(appBase, "lib")
  if dirHasCompiledStdlib(appLib) {
    return appLib
  }
  val cwd = Environment.currentDirectory()
  val stage1 = Path.join(".bootstrap", "stage1")
  val libBin = Path.join("lyric-stdlib", "bin")
  var hit = walkUpForCompiledStdlib(appBase, stage1)
  if hit.length > 0 {
    return hit
  }
  hit = walkUpForCompiledStdlib(cwd, stage1)
  if hit.length > 0 {
    return hit
  }
  hit = walkUpForCompiledStdlib(appBase, libBin)
  if hit.length > 0 {
    return hit
  }
  hit = walkUpForCompiledStdlib(cwd, libBin)
  if hit.length > 0 {
    return hit
  }
  val testCacheDir = ".lyric-test"
  hit = walkUpForCompiledStdlib(appBase, testCacheDir)
  if hit.length > 0 {
    return hit
  }
  hit = walkUpForCompiledStdlib(cwd, testCacheDir)
  if hit.length > 0 {
    return hit
  }
  ""
}

// ── Stdlib bundle freshness guard (D-progress-670) ─────────────────────────
// `lyric run` / `lyric test` link the PRECOMPILED `Lyric.Stdlib.dll` bundle
// for runtime execution; kernel source is read only for compile-time type
// checking.  So editing `lyric-stdlib/std/**` and re-running a test WITHOUT
// rebuilding the bundle silently exercises the stale bundle and reports
// results that don't reflect the edit — the exact trap that produced a false
// "all green" during the D-progress-669 auto-FFI migration.  This guard
// surfaces that staleness.
// True iff a `.l` source file is one that the `.NET` `Lyric.Stdlib.dll` bundle
// is built from.  Mirrors `findStdlibSourcesForTarget(false)`: the JVM- and
// native-only kernels — the whole `_kernel_jvm/` and `_kernel_native/` trees,
// plus the two JVM-only `_kernel/jvm*.l` files — never contribute to the .NET
// bundle, so editing one must NOT flag the bundle stale on a `--target dotnet`
// run (which would break the guard's "never fires spuriously" invariant).
pub func isDotnetStdlibSource(path: in String): Bool {
  if Str.contains(path, "_kernel_jvm") or Str.contains(path, "_kernel_native") {
    return false
  }
  // Any `jvm*.l` file in the shared `_kernel/` dir (today `jvm.l` /
  // `jvm_exception.l`) is JVM-only — mirror the loader's `startsWith("jvm")`
  // prefix skip (`emitter.l`) so a future `jvm_*.l` kernel is excluded too.
  not Str.startsWith(Path.basename(path), "jvm")
}

// True iff any `.NET`-relevant `.l` file under `dir` (recursive) is newer than
// `ref`.  Stats the bundle ONCE up front and passes it in so we can early-exit
// at the first newer source rather than computing the newest of the whole tree
// — the common (fresh) case still walks every file to confirm none are newer,
// but that is a bounded one-time `stat` sweep of the ~100-file stdlib source
// dir, dwarfed by the compile that always follows, and it only runs in a dev
// tree.
func anyLyricSourceNewerThan(dir: in String, ref: in File.FileStat): Bool {
  match File.listFilesRecursive(dir) {
    case Err(_) -> false
    case Ok(files) -> {
      for f in files.toArray() {
        if Str.endsWith(f, ".l") and isDotnetStdlibSource(f) {
          match File.stat(f) {
            case Ok(st) -> {
              if File.fileStatIsNewer(st, ref) {
                return true
              }
            }
            case Err(_) -> ()
          }
        }
      }
      false
    }
  }
}

// Warn (to stderr) when the compiled stdlib bundle at `libDir` is older than
// any `lyric-stdlib/std/**` source file — i.e. a dev edited a kernel but hasn't
// re-run `make lyric`, so this run links a stale bundle.  Dev-tree only: a
// silent no-op when the source tree isn't found (installed toolchains) or no
// bundle is present, so it never fires for shipped SDKs or a CI job that
// freshly rebuilt the bundle.
pub func warnIfStdlibBundleStale(libDir: in String): Unit {
  if libDir.length == 0 {
    return
  }
  val srcDir = Emitter.locateStdlibDir()
  if srcDir.length == 0 {
    return
  }
  val bundlePath = Path.join(libDir, "Lyric.Stdlib.dll")
  match File.stat(bundlePath) {
    case Err(_) -> ()
    case Ok(bundleStat) -> {
      if anyLyricSourceNewerThan(srcDir, bundleStat) {
        Console.error("warning: stdlib source under '" + srcDir + "' is newer than the compiled bundle at")
        Console.error("         '" + bundlePath + "'.")
        Console.error("         `lyric run` / `lyric test` link the prebuilt bundle for runtime, so this run")
        Console.error("         may not reflect your source edits — run `make lyric` to rebuild the stdlib.")
      }
    }
  }
}

// Co-locate the stdlib runtime assemblies (the single `Lyric.Stdlib.dll` bundle
// plus the per-package HTTP/async DLLs not yet bundleable, #4030) from the
// SDK/publish lib dir `srcDir` next to the assembly at `outPath`, so `dotnet
// exec` resolves them at run time (flat `additionalProbingPaths` do not work
// for a non-NuGet layout).  Best-effort: copy failures are non-fatal — the run
// then surfaces the original assembly-load error.  Always overwrites existing
// DLLs so stale copies from previous runs are replaced when the stdlib is
// rebuilt.
func copyRuntimeDepsBeside(outPath: in String, srcDir: in String): Unit {
  if srcDir.length == 0 {
    return
  }
  val destDir = Path.dirname(outPath)
  // Co-locate the stdlib beside the output: copy every Lyric.Stdlib*.dll (the
  // single Lyric.Stdlib.dll bundle plus the per-package HTTP/async DLLs that are
  // not yet bundleable, #4030) from the toolchain dir so `dotnet exec` resolves
  // them at run time.  The self-hosted emitter always emits arity-suffixed
  // generic references (#4019) and the stdlib beside the compiler is itself
  // self-hosted, so the historical mint-vs-self-hosted `userlib/` overlay and the
  // F#-era FSharp.Core/Lyric.Emitter copy are gone.
  match File.listFiles(srcDir) {
    case Err(_) -> ()
    case Ok(fs) -> {
      for f in fs.toArray() {
        val base = Path.basename(f)
        if Str.startsWith(base, "Lyric.Stdlib") and Str.endsWith(base, ".dll") {
          val dest = Path.join(destDir, base)
          if dest != outPath {
            match File.readBytes(f) {
              case Ok(bs) -> {
                val _ = File.writeBytes(dest, bs)
              }
              case Err(_) -> ()
            }
          }
        }
      }
    }
  }
}

// Copy a single dependency DLL beside `outPath`.  Best-effort: a missing or
// unreadable source, or a write failure, is silently skipped — the eventual
// `dotnet exec` surfaces the original assembly-load error instead.
func copyDllBeside(outPath: in String, dllPath: in String): Unit {
  if dllPath.length == 0 or not File.fileExists(dllPath) {
    return
  }
  val dest = Path.join(Path.dirname(outPath), Path.basename(dllPath))
  match File.readBytes(dllPath) {
    case Ok(bs) -> {
      val _ = File.writeBytes(dest, bs)
    }
    case Err(_) -> ()
  }
}

// Co-locate each restored-dependency output DLL beside the assembly at
// `outPath`.  `restoredDlls` entries are "<depName>\t<dllPath>" (the same
// encoding threaded into `EmitProjectRequest.restoredDllPaths`).  A
// flat `additionalProbingPaths` does not resolve a non-NuGet dep bin layout,
// so the referenced DLL must sit next to the consumer for `dotnet exec` to
// load it.  Best-effort: failures are non-fatal (the run then surfaces the
// original load error).
func copyRestoredDepDlls(outPath: in String, restoredDlls: in List[String]): Unit {
  var i = 0
  while i < restoredDlls.count {
    val depEntry = restoredDlls[i]
    i = i + 1
    val tabPos = depEntry.indexOf("\t")
    val dllPath = if tabPos >= 0 { depEntry.substring(tabPos + 1, depEntry.length - tabPos - 1) } else { depEntry }
    copyDllBeside(outPath, dllPath)
  }
}

// Co-locate genuine third-party NuGet assemblies (resolved by
// `partitionNugetLyricDeps`'s `thirdPartyPaths` — a bare-path list, since
// these carry no Lyric-side dep name to tag them with) beside the output
// DLL, mirroring `copyRestoredDepDlls` for the Lyric-package subset.  A
// `[nuget]` dependency that is a genuine .NET library (not another Lyric
// package) must sit next to the consumer for `dotnet exec` to load it at
// runtime, same as any other restored dependency (#5066).
func copyNugetAssembliesBeside(outPath: in String, nugetPaths: in List[String]): Unit {
  var i = 0
  while i < nugetPaths.count {
    copyDllBeside(outPath, nugetPaths[i])
    i += 1
  }
}

// Co-locate NuGet-restored native runtime assets (`resolveNugetNativeAssets`)
// beside the output DLL, reusing the same flat co-location `copyDllBeside`
// already provides for managed assemblies.  The CLI's bundler emits no
// `.deps.json`, and without one the .NET host's default native-library
// probing only checks the loading assembly's own directory — not the nested
// `runtimes/<rid>/native/` layout NuGet packages ship in the restore cache —
// so each RID-specific file is flattened directly beside the output rather
// than preserving that nesting (#5573).
func copyNugetNativeAssetsBeside(outPath: in String, nativePaths: in List[String]): Unit {
  var i = 0
  while i < nativePaths.count {
    copyDllBeside(outPath, nativePaths[i])
    i += 1
  }
}

// Pure decision logic behind `warnIfNugetUnresolved`: `Some(reason)` when
// the manifest declares `[nuget]` entries but no assemblies resolved,
// `None` when there is nothing to warn about.  `reason` distinguishes
// "was not found" (no `project.assets.json` — never restored) from "is
// stale or could not be resolved" (the file exists but parsed to zero
// assemblies — stale or corrupt), per #4326.  Split out from
// `warnIfNugetUnresolved` so the decision can be asserted directly in
// tests without capturing stderr output (#4770).
pub func nugetUnresolvedReason(
  mfDir: in String, nugetOpt: in Option[Mf.NugetSection], nugetPaths: in List[String]
): Option[String] {
  match nugetOpt {
    case Some(nugetSec) -> {
      if nugetSec.entries.count > 0 and nugetPaths.count == 0 {
        val assetsPath = Path.join(Path.join(mfDir, "obj"), "project.assets.json")
        val reason = if File.fileExists(assetsPath) { "is stale or could not be resolved" } else { "was not found" }
        Some(value = reason)
      } else {
        None
      }
    }
    case None -> None
  }
}

// Warn if the manifest declares `[nuget]` entries but no resolved
// assemblies — whether because `project.assets.json` is missing (never
// restored) or present but stale/corrupt (resolves to zero assemblies).
// Both states leave the build with unresolved NuGet deps, so the
// file-existence check does not gate the warning to the missing-file case
// only (#4326).  Shared by `buildProject` (cli_build.l) and
// `cmdTestManifest` (cli_test.l) so the two build paths give the same
// diagnostic instead of silently drifting apart (#4325).
pub func warnIfNugetUnresolved(
  mfDir: in String, nugetOpt: in Option[Mf.NugetSection], nugetPaths: in List[String]
): Unit {
  match nugetUnresolvedReason(mfDir, nugetOpt, nugetPaths) {
    case Some(reason) -> {
      printErr(
        "warning: [nuget] dependencies declared but project.assets.json " + reason + ". " +
          "Run 'lyric restore' or 'dotnet restore' to resolve NuGet dependencies."
      )
    }
    case None -> ()
  }
}

/// A successfully read + parsed `project.assets.json`, together with the
/// resolved NuGet global-packages directory its package-relative asset
/// paths are rooted under.  Shared by `resolveNugetAssets` (managed runtime
/// DLLs) and `resolveNugetNativeAssets` (native runtime assets, #5573) so
/// the file-read/parse/packages-dir-resolution work happens once per call
/// site instead of twice.
record ParsedNugetAssets {
  parsed: Yaml.YamlValue
  pkgsDir: String
}

// Read and parse `mfDir`/obj/project.assets.json, then resolve the NuGet
// global-packages directory it references: `NUGET_PACKAGES` env var first,
// then `project.restore.packagesPath` from the assets file itself, then the
// conventional `~/.nuget/packages` (`%USERPROFILE%` on Windows) fallback.
// `None` covers every miss uniformly — no assets file, an unreadable or
// malformed one, or no resolvable packages directory — so callers fall back
// to an empty asset list exactly as before this was split out.
func loadNugetAssets(mfDir: in String): Option[ParsedNugetAssets] {
  val assetsPath = Path.join(Path.join(mfDir, "obj"), "project.assets.json")
  if not File.fileExists(assetsPath) {
    return None
  }

  // Avoids binding a `match`-as-expression whose arm both yields a plain
  // value AND early-`return`s a DIFFERENT (union-typed) value from this
  // `Option[ParsedNugetAssets]`-returning function — that shape has a known
  // self-hosted MSIL emitter miscompile (StackUnexpected on the shared
  // return-value slot; see docs/10-bootstrap-progress.md's "deeply-nested
  // match-as-expression emitter bug" entry for the same class of issue).
  // Statement-position match + an explicit follow-up `if` sidesteps it.
  var content = ""
  var haveContent = false
  match File.readText(assetsPath) {
    case Ok(text) -> {
      content = text
      haveContent = true
    }
    case Err(_) -> ()
  }
  if not haveContent {
    return None
  }

  // Parse the JSON using AOT-safe pure-Lyric parser
  var parseResult: Yaml.YamlValue = Yaml.YMapping(pairs = newList())
  var haveParseResult = false
  match Yaml.parseJson(content) {
    case Ok(value) -> {
      parseResult = value
      haveParseResult = true
    }
    case Err(_) -> ()
  }
  if not haveParseResult {
    return None
  }

  // Resolve NuGet packages folder
  var pkgsDir = Environment.getVarOrDefault("NUGET_PACKAGES", "")
  if pkgsDir.length == 0 {
    pkgsDir = extractPackagesPathFromYaml(parseResult)
  }
  if pkgsDir.length == 0 {
    val home = match Environment.getVar("HOME") {
      case Ok(h) -> h
      case Err(_) -> match Environment.getVar("USERPROFILE") { case Ok(h) -> h; case Err(_) -> "" }
    }
    if home.length > 0 {
      pkgsDir = Path.join(home, ".nuget/packages")
    }
  }

  if pkgsDir.length == 0 {
    return None
  }

  Some(value = ParsedNugetAssets(parsed = parseResult, pkgsDir = pkgsDir))
}

// A thin managed-DLLs-only view over the same `loadNugetAssets` discovery
// `resolveAllNugetAssets` does in one pass; kept `pub` for direct
// self-testing (`cli_shared_self_test.l`) rather than for production use —
// production call sites (`resolveManifestDependencies`, `cmdTestManifest`)
// use `resolveAllNugetAssets` so a single `project.assets.json` read yields
// both the managed DLLs and the native assets (#5742).
pub func resolveNugetAssets(mfDir: in String): List[String] {
  match loadNugetAssets(mfDir) {
    case None -> newList()
    case Some(la) -> extractDllPathsFromYaml(la.parsed, la.pkgsDir)
  }
}

/// Resolve NuGet-restored native runtime assets (e.g.
/// `runtimes/linux-x64/native/libe_sqlite3.so`, required by
/// `Microsoft.Data.Sqlite` via `SQLitePCLRaw.provider.e_sqlite3`) for the
/// CURRENT host RID.  `lyric build`/`lyric test` compile and immediately run
/// on the same machine, so the build machine's own RID
/// (`Environment.runtimeIdentifier()`) is the only one that matters — there
/// is no cross-compilation target to choose between (#5573).  Mirrors
/// `resolveNugetAssets`'s discovery exactly and returns an empty list in
/// every case it would (no restore yet, a malformed assets file, or no
/// resolvable packages directory), plus when the host RID itself is unknown
/// (empty, e.g. under the JVM CLI host — see `Environment.runtimeIdentifier`'s
/// doc comment).
///
/// Like `resolveNugetAssets`, this is a thin single-kind (native-assets-only)
/// view over the same discovery `resolveAllNugetAssets` does in one pass;
/// kept `pub` for direct self-testing rather than for production use —
/// production call sites use `resolveAllNugetAssets` (#5742).
pub func resolveNugetNativeAssets(mfDir: in String): List[String] {
  val hostRid = Environment.runtimeIdentifier()
  if hostRid.length == 0 {
    return newList()
  }
  match loadNugetAssets(mfDir) {
    case None -> newList()
    case Some(la) -> extractNativeAssetPathsFromYaml(la.parsed, la.pkgsDir, hostRid)
  }
}

/// Both `resolveNugetAssets`'s managed DLLs and `resolveNugetNativeAssets`'s
/// native assets in a single `project.assets.json` read + parse (#5742) —
/// every call site that needs both (`resolveManifestDependencies`,
/// `cmdTestManifest`) previously called the two independent resolvers
/// back-to-back, each re-running `loadNugetAssets` and so re-reading/
/// re-parsing the same file.
pub record ResolvedNugetAssets {
  dllPaths: List[String]
  nativePaths: List[String]
}

pub func resolveAllNugetAssets(mfDir: in String): ResolvedNugetAssets {
  match loadNugetAssets(mfDir) {
    case None -> ResolvedNugetAssets(dllPaths = newList(), nativePaths = newList())
    case Some(la) -> {
      val dllPaths = extractDllPathsFromYaml(la.parsed, la.pkgsDir)
      val hostRid = Environment.runtimeIdentifier()
      var nativePaths: List[String] = newList()
      if hostRid.length > 0 {
        nativePaths = extractNativeAssetPathsFromYaml(la.parsed, la.pkgsDir, hostRid)
      }
      ResolvedNugetAssets(dllPaths = dllPaths, nativePaths = nativePaths)
    }
  }
}

/// Split `resolveNugetAssets`'s output into Lyric-package restored-dep
/// entries versus genuine third-party .NET assemblies, so a `[nuget]`
/// dependency on another Lyric package (e.g. `Lyric.Web`) gets its
/// declared signatures from its embedded `Lyric.Contract` resource — the
/// same path a workspace/path dependency already uses — instead of only
/// ever reaching the raw-metadata auto-FFI index, whose signature guesses
/// can misread a function's arity (#5004). A DLL with no `Lyric.Contract`
/// resource is a real third-party library and keeps going through
/// auto-FFI. Returns (restoredDlls entries formatted "name\tpath" — the
/// same shape workspace/path deps use, appendable directly to that list —
/// thirdPartyPaths bare paths for `nugetAssemblyPaths`).
pub func partitionNugetLyricDeps(nugetPaths: in List[String]): (List[String], List[String]) {
  val restoredEntries: List[String] = newList()
  val thirdPartyPaths: List[String] = newList()
  for path in nugetPaths {
    val contracts = Meta.readAllContractsFromFile(path)
    if contracts.count > 0 {
      restoredEntries.add(stemOf(Path.basename(path), 4) + "\t" + path)
    } else {
      thirdPartyPaths.add(path)
    }
  };
  (restoredEntries, thirdPartyPaths)
}

func extractPackagesPathFromYaml(root: in Yaml.YamlValue): String {
  // packagesPath is at project.restore.packagesPath in project.assets.json
  match root {
    case Yaml.YMapping(rootPairs) -> {
      var i = 0
      while i < rootPairs.count {
        val pair = rootPairs[i]
        if pair.key == "project" {
          match pair.value {
            case Yaml.YMapping(projectPairs) -> {
              var j = 0
              while j < projectPairs.count {
                val projPair = projectPairs[j]
                if projPair.key == "restore" {
                  match projPair.value {
                    case Yaml.YMapping(restorePairs) -> {
                      var k = 0
                      while k < restorePairs.count {
                        val restorePair = restorePairs[k]
                        if restorePair.key == "packagesPath" {
                          match restorePair.value {
                            case Yaml.YString(path) -> return path
                            case _ -> ()
                          }
                        }
                        k += 1
                      }
                    }
                    case _ -> ()
                  }
                }
                j += 1
              }
            }
            case _ -> ()
          }
        }
        i += 1
      }
    }
    case _ -> ()
  }
  ""
}

func extractDllPathsFromYaml(root: in Yaml.YamlValue, pkgsDir: in String): List[String] {
  var result: List[String] = newList()
  // Navigate to targets[*][*] where type == "package" and extract runtime DLL paths
  match root {
    case Yaml.YMapping(rootPairs) -> {
      var i = 0
      while i < rootPairs.count {
        val pair = rootPairs[i]
        if pair.key == "targets" {
          match pair.value {
            case Yaml.YMapping(frameworks) -> {
              // For each framework (e.g., ".NETFramework,Version=v4.7.2")
              var fIdx = 0
              while fIdx < frameworks.count {
                val fmwkPair = frameworks[fIdx]
                match fmwkPair.value {
                  case Yaml.YMapping(packages) -> {
                    // For each package in this framework
                    var pIdx = 0
                    while pIdx < packages.count {
                      val pkgPair = packages[pIdx]
                      // Extract the Package/Version key
                      val pkgKey = pkgPair.key
                      val slashPos = pkgKey.indexOf("/")
                      if slashPos > 0 and slashPos < pkgKey.length - 1 {
                        match pkgPair.value {
                          case Yaml.YMapping(pkgFields) -> {
                            // Check if type == "package"
                            var typeMatch = false
                            var j = 0
                            while j < pkgFields.count {
                              val field = pkgFields[j]
                              if field.key == "type" {
                                match field.value {
                                  case Yaml.YString(t) -> {
                                    if t == "package" {
                                      typeMatch = true
                                    }
                                  }
                                  case _ -> ()
                                }
                              }
                              j += 1
                            }
                            if typeMatch {
                              // Look for runtime section
                              j = 0
                              while j < pkgFields.count {
                                val field = pkgFields[j]
                                if field.key == "runtime" {
                                  match field.value {
                                    case Yaml.YMapping(runtimeEntries) -> {
                                      // Extract each DLL path
                                      var dIdx = 0
                                      while dIdx < runtimeEntries.count {
                                        val dllEntry = runtimeEntries[dIdx]
                                        val dllPath = dllEntry.key
                                        val lowerPath = dllPath.toLower()
                                        if Str.endsWith(lowerPath, ".dll") {
                                          val pkgName = pkgKey.substring(0, slashPos)
                                          val pkgVersion = pkgKey.substring(slashPos + 1, pkgKey.length - slashPos - 1)
                                          val lowerPkgName = pkgName.toLower()
                                          val fullPath = Path.join(pkgsDir, Path.join(Path.join(lowerPkgName, pkgVersion), dllPath))
                                          if File.fileExists(fullPath) {
                                            result.add(fullPath)
                                          }
                                        }
                                        dIdx += 1
                                      }
                                    }
                                    case _ -> ()
                                  }
                                }
                                j += 1
                              }
                            }
                          }
                          case _ -> ()
                        }
                      }
                      pIdx += 1
                    }
                  }
                  case _ -> ()
                }
                fIdx += 1
              }
            }
            case _ -> ()
          }
        }
        i += 1
      }
    }
    case _ -> ()
  }
  result
}

// Extract native runtime asset paths (e.g.
// `runtimes/linux-x64/native/libe_sqlite3.so`) restricted to `hostRid` from a
// parsed `project.assets.json`.  Unlike managed runtime DLLs (`extractDllPathsFromYaml`,
// keyed under a package's `runtime` map), NuGet records RID-specific assets
// under a sibling `runtimeTargets` map — same package-entry shape, same
// package-typed-entry filter — keyed by the asset's package-relative path,
// with each entry carrying its own `assetType` ("native" for a P/Invoke
// library, "runtime" for a RID-specific managed assembly — only the former
// is wanted here) and `rid` (which RID it targets).  An empty `hostRid`
// yields no matches: there is no meaningful "default" RID to fall back to
// (#5573).
func extractNativeAssetPathsFromYaml(root: in Yaml.YamlValue, pkgsDir: in String, hostRid: in String): List[String] {
  var result: List[String] = newList()
  if hostRid.length == 0 {
    return result
  }
  match root {
    case Yaml.YMapping(rootPairs) -> {
      var i = 0
      while i < rootPairs.count {
        val pair = rootPairs[i]
        if pair.key == "targets" {
          match pair.value {
            case Yaml.YMapping(frameworks) -> {
              var fIdx = 0
              while fIdx < frameworks.count {
                val fmwkPair = frameworks[fIdx]
                match fmwkPair.value {
                  case Yaml.YMapping(packages) -> {
                    var pIdx = 0
                    while pIdx < packages.count {
                      val pkgPair = packages[pIdx]
                      val pkgKey = pkgPair.key
                      val slashPos = pkgKey.indexOf("/")
                      if slashPos > 0 and slashPos < pkgKey.length - 1 {
                        match pkgPair.value {
                          case Yaml.YMapping(pkgFields) -> {
                            var typeMatch = false
                            var j = 0
                            while j < pkgFields.count {
                              val field = pkgFields[j]
                              if field.key == "type" {
                                match field.value {
                                  case Yaml.YString(t) -> {
                                    if t == "package" {
                                      typeMatch = true
                                    }
                                  }
                                  case _ -> ()
                                }
                              }
                              j += 1
                            }
                            if typeMatch {
                              j = 0
                              while j < pkgFields.count {
                                val field = pkgFields[j]
                                if field.key == "runtimeTargets" {
                                  match field.value {
                                    case Yaml.YMapping(rtEntries) -> {
                                      var rIdx = 0
                                      while rIdx < rtEntries.count {
                                        val rtEntry = rtEntries[rIdx]
                                        val assetPath = rtEntry.key
                                        var isNative = false
                                        var ridMatch = false
                                        match rtEntry.value {
                                          case Yaml.YMapping(assetFields) -> {
                                            var k = 0
                                            while k < assetFields.count {
                                              val af = assetFields[k]
                                              if af.key == "assetType" {
                                                match af.value {
                                                  case Yaml.YString(at) -> {
                                                    if at.toLower() == "native" {
                                                      isNative = true
                                                    }
                                                  }
                                                  case _ -> ()
                                                }
                                              }
                                              if af.key == "rid" {
                                                match af.value {
                                                  case Yaml.YString(r) -> {
                                                    if r == hostRid {
                                                      ridMatch = true
                                                    }
                                                  }
                                                  case _ -> ()
                                                }
                                              }
                                              k += 1
                                            }
                                          }
                                          case _ -> ()
                                        }
                                        if isNative and ridMatch {
                                          val pkgName = pkgKey.substring(0, slashPos)
                                          val pkgVersion = pkgKey.substring(slashPos + 1, pkgKey.length - slashPos - 1)
                                          val lowerPkgName = pkgName.toLower()
                                          val fullPath = Path.join(pkgsDir, Path.join(Path.join(lowerPkgName, pkgVersion), assetPath))
                                          if File.fileExists(fullPath) {
                                            result.add(fullPath)
                                          }
                                        }
                                        rIdx += 1
                                      }
                                    }
                                    case _ -> ()
                                  }
                                }
                                j += 1
                              }
                            }
                          }
                          case _ -> ()
                        }
                      }
                      pIdx += 1
                    }
                  }
                  case _ -> ()
                }
                fIdx += 1
              }
            }
            case _ -> ()
          }
        }
        i += 1
      }
    }
    case _ -> ()
  }
  result
}
