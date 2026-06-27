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
import Lyric.Manifest as Mf
import Lyric.Lexer
import Lyric.Workspace as Ws
import Lyric.Lockfile as LF
import Lyric.Discovery as Disc
import Lyric.Emitter as Emitter

func VERSION(): String {
  "0.1.0"
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

// Single source of truth for the help text, grouped by workflow so it stays
// scannable.  `printUsage` writes it to stderr (the error/no-args paths);
// `lyric --help` writes the same text to stdout and exits 0.
func usageText(): String {
  "Usage: lyric [command] [args]\n" + "\n" + "  Run `lyric` with no command inside a project to build it.\n" + "\n" +
    "Project:\n" +
    "  lyric init    [<dir>] [--name <Name>] [--lib] [--force]\n" +
    "                (scaffold a new app (or --lib library) package: lyric.toml + src + .gitignore)\n" +
    "  lyric build   [<source.l>] [-o <output>] [--force] [--manifest <lyric.toml>] [--target dotnet|jvm] [--no-restore] [--watch]\n" +
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
    "  lyric run     [<source.l>] [--manifest <lyric.toml>] [--target dotnet|jvm] [--watch] [-- <args>...]\n" +
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
  // Minimal extraction: find "compiler_version": "X.Y.Z" in the JSON blob.
  val key = "\"compiler_version\": \""
  val keyPos = text.indexOf(key)
  if keyPos < 0 {
    return 0
  }
  val valueStart = keyPos + key.length
  val closeQuote = text.indexOf("\"", valueStart)
  if closeQuote < 0 {
    return 0
  }
  val sdkVer = text.substring(valueStart, closeQuote - valueStart)
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
func discoverManifest(explicit: in Option[String]): Option[String] {
  match explicit {
    case Some(p) -> Some(value = p)
    case None -> Disc.findNearestManifest(Environment.currentDirectory())
  }
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
// When $LYRIC_STDLIB_BIN is set it is returned unconditionally; otherwise
// returns "" when no candidate holds `Lyric.Stdlib.dll`.
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
  ""
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

// Co-locate each restored-dependency output DLL beside the assembly at
// `outPath`.  `restoredDlls` entries are "<depName>\t<dllPath>" (the same
// encoding threaded into `EmitProjectRequest.restoredDllPaths`).  A
// flat `additionalProbingPaths` does not resolve a non-NuGet dep bin layout,
// so the referenced DLL must sit next to the consumer for `dotnet exec` to
// load it.  Best-effort: failures are non-fatal (the run then surfaces the
// original load error).
func copyRestoredDepDlls(outPath: in String, restoredDlls: in List[String]): Unit {
  val destDir = Path.dirname(outPath)
  var i = 0
  while i < restoredDlls.count {
    val depEntry = restoredDlls[i]
    i = i + 1
    val tabPos = depEntry.indexOf("\t")
    val dllPath = if tabPos >= 0 { depEntry.substring(tabPos + 1, depEntry.length - tabPos - 1) } else { depEntry }
    if dllPath.length == 0 or not File.fileExists(dllPath) {
      continue
    }
    val dest = Path.join(destDir, Path.basename(dllPath))
    match File.readBytes(dllPath) {
      case Ok(bs) -> {
        val _ = File.writeBytes(dest, bs)
      }
      case Err(_) -> ()
    }
  }
}

pub func resolveNugetAssets(mfDir: in String): List[String] {
  var result: List[String] = newList()
  val assetsPath = Path.join(Path.join(mfDir, "obj"), "project.assets.json")
  if not File.fileExists(assetsPath) {
    return result
  }

  val contentOpt = match File.readText(assetsPath) {
    case Ok(text) -> Some(value = text)
    case Err(_) -> None
  }

  val content = match contentOpt {
    case Some(text) -> text
    case None -> return result
  }

  // Resolve NuGet packages folder using helper
  var pkgsDir = Environment.getVarOrDefault("NUGET_PACKAGES", "")
  if pkgsDir.length == 0 {
    pkgsDir = extractPackagesPath(content)
  }
  if pkgsDir.length == 0 {
    val home = match Environment.getVar("HOME") {
      case Ok(h) -> h
      case Err(_) -> match Environment.getVar("USERPROFILE") {
        case Ok(h) -> h
        case Err(_) -> ""
      }
    }
    if home.length > 0 {
      pkgsDir = Path.join(home, ".nuget/packages")
    }
  }

  if pkgsDir.length == 0 {
    return result
  }

  // Extract DLL paths using helper
  extractDllPathsFromJson(content, pkgsDir, result)
  return result
}

func extractPackagesPath(content: in String): String {
  // Look for "packagesPath": "..." in the JSON
  var result = ""
  var searchPos = 0
  val pattern = "packagesPath\": \""
  while searchPos < content.length - pattern.length {
    // Look for opening quote first
    var quotePos = searchPos
    while quotePos < content.length and content[quotePos] != '"' {
      quotePos += 1
    }
    if quotePos >= content.length - pattern.length {
      break
    }
    // Check if pattern matches after the quote
    var matches = true
    var i = 0
    while i < pattern.length and matches {
      if content[quotePos + 1 + i] != pattern[i] {
        matches = false
      }
      i += 1
    }
    if matches {
      val valueStart = quotePos + 1 + pattern.length
      var valueEnd = valueStart
      while valueEnd < content.length and content[valueEnd] != '"' {
        valueEnd += 1
      }
      if valueEnd < content.length and valueEnd > valueStart {
        result = content.substring(valueStart, valueEnd - valueStart)
        return result
      }
    }
    searchPos = quotePos + 1
  }
  result
}

func extractDllPathsFromJson(content: in String, pkgsDir: in String, result: inout List[String]): Unit {
  // Search for "lib/.../*.dll" patterns in the JSON string
  var searchPos = 0
  while searchPos < content.length {
    // Find next "lib/" pattern
    var libPos = searchPos
    while libPos < content.length - 4 {
      if content[libPos] == 'l' and content[libPos + 1] == 'i' and content[libPos + 2] == 'b' and
          content[libPos + 3] == '/' {
        break
      }
      libPos += 1
    }
    if libPos >= content.length - 4 {
      break
    }

    // Find next ".dll" from this position
    var dllPos = libPos + 4
    while dllPos < content.length - 4 {
      if content[dllPos] == '.' and content[dllPos + 1] == 'd' and content[dllPos + 2] == 'l' and
          content[dllPos + 3] == 'l' {
        break
      }
      dllPos += 1
    }
    if dllPos >= content.length - 4 {
      searchPos = libPos + 1
      continue
    }

    val dllEnd = dllPos + 4
    val relPath = content.substring(libPos, dllEnd - libPos)

    // Try to extract package name and version from backwards search
    // JSON structure: "Package/Version": { "runtime": { "lib/.../.dll": {} } }
    // Search backward to find the nearest quoted key that contains '/' (package/version format)
    var pos = libPos - 1
    var foundPkgKey = false
    while pos > 1 and not foundPkgKey {
      // Skip backward to find a quote
      while pos > 0 and content[pos] != '"' {
        pos -= 1
      }
      if pos <= 0 {
        break
      }
      // Found a closing quote; now find the opening quote
      val closeQuote = pos
      pos = pos - 1
      while pos > 0 and content[pos] != '"' {
        pos -= 1
      }
      if pos > 0 {
        val openQuote = pos
        val potentialKey = content.substring(openQuote + 1, closeQuote - openQuote - 1)

        // Check if this key contains '/' (package/version format)
        var slashPos = 0
        while slashPos < potentialKey.length and potentialKey[slashPos] != '/' {
          slashPos += 1
        }

        if slashPos > 0 and slashPos < potentialKey.length - 1 {
          val pkgName = potentialKey.substring(0, slashPos)
          val pkgVersion = potentialKey.substring(slashPos + 1, potentialKey.length - slashPos - 1)
          val lowerPkgName = pkgName.toLower()
          val fullPath = Path.join(pkgsDir, Path.join(Path.join(lowerPkgName, pkgVersion), relPath))
          if File.fileExists(fullPath) {
            result.add(fullPath)
          }
          foundPkgKey = true
        } else {
          pos = openQuote - 1
        }
      }
    }

    searchPos = dllEnd
  }
}

