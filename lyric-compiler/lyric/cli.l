//! lyric/cli.l — self-hosted Lyric CLI (Phase 5 §M5.3).
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
//!   run     [<source.l>] [--manifest <lyric.toml>] [--target dotnet|jvm] [--watch] [-- <args>...]
//!   fmt     [<source.l>] [--manifest <lyric.toml>] [--check] [--write]
//!   lint    [<source.l>] [--manifest <lyric.toml>] [--error-on-warning]
//!   prove   [<source.l>] [--manifest <lyric.toml>] [--verbose] [--allow-unverified] [--json] [--explain --goal <n>]
//!   doc     [<source.l>] [--manifest <lyric.toml>] [-o <out.md|dir>]
//!   public-api-diff <old.dll> <new.dll>
//!   restore [--manifest <lyric.toml>]
//!   publish [--manifest <lyric.toml>] [--dll <path>] [-o <dir>]
//!   test    [<source.l>] [--manifest <lyric.toml>] [--filter <prefix>] [--list]
//!   bench   [<source.l>] [--manifest <lyric.toml>] [--runs N] [--warmup N] [--filter <prefix>]
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
// before Path so Path.join/2 wins over Str.join/2
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.Errors
import Std.Parse
import Std.Hash as Hash
// sha512OfFile / sha512OfBytes for #738 lock integrity
import Std.Time as Time
// sleepMillis — the --watch poll interval (#1974)
import Std.Json as Json
// encodeString — RFC 8259 string literal escaping (#1093)
import Lyric.Manifest as Mf
// parseManifest(text, filePath) -> Result[Manifest, ManifestError]
import Lyric.Pack as Pack
// publishCsproj, restoreCsproj, xmlEscape, sanitisedPackageName
import Lyric.Lexer
// Diagnostic, DiagnosticSeverity, DiagError, DiagWarning, Span, Position
import Lyric.Workspace as Ws
// findWorkspaceRoot, findMember, resolveDep, WorkspaceContext
import Lyric.Discovery as Disc
// findNearestManifest — nearest lyric.toml walking up from cwd
import Lyric.Release as Release
// buildRelease — `--release` Native AOT native-binary pipeline
import Lyric.Init as Init
// runInit — `lyric init` project scaffolder (#1972)
import Lyric.GitDep as GitDep
// resolve(url, ref, subdir) -> Result[GitDepResult, String]
import Lyric.Lockfile as LF
// emptyLockFile, addOrUpdatePackage, serializeLockFile, parseLockFile
import Std.ProcessCapture as ProcessCapture
// runCapture(exe, args, stdin) -> String
import Std.Char as Ch
import Lyric.Generator as Generator
// preprocess(source, manifestPath, sourceFile) -> Result[String, String]
// Phase 5 M5.2+ packages — present when the self-hosted compiler compiles this file.
import Lyric.Emitter as Emitter
// emit(req) -> EmitResult; CompileTarget, Dotnet, Jvm
import Lyric.Fmt as Fmt
// formatSource(src) -> String; isFormattedSource(src) -> Bool
import Lyric.Lint as Lint
// lint(source) -> List[LintDiag]
import Lyric.ModeChecker as MC
// vlIsProofRequired, vlDisplay
import Lyric.Verifier as Verifier
// proveSource/proveSourceWithOptions -> ProofSummary; summary* helpers
import Lyric.Doc as Doc
// generate(source) -> String
import Lyric.ContractMeta as Meta
// readFromFile, diffContracts, hasBreakingChanges
import Lyric.Repl as Repl
// run(argv) -> Int
import Lyric.TestSynth as TestSynth
// synthesize, listEntries
import Lyric.BenchSynth as BenchSynth
// synthesizeBench
import Lyric.OpenApiParser as OAParser
// parseSpec(json) -> Result[ParsedSpec, String]
import Lyric.OpenApiGen as OAGen
// generateOpenApi(spec, clientName, packageName) -> String
import Lyric.Lsp as Lsp
// lspRunLoop() — language server stdio loop
import Lyric.CfgGate as CfgGate
// isCfgGatedOut, assembleDirectoryPackageSources (#1123, #1124)
import Lyric.CliSuggest as Suggest

// suggestCommand — did-you-mean for unknown commands
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
    "  lyric build   --release [<source.l>] [--rid <rid>] [-o <bin>]\n" +
    "                (self-contained Native AOT binary; single-file today, see #1975)\n" +
    "  lyric restore [--manifest <lyric.toml>] [--locked]\n" +
    "  lyric add     <name>[@<version>] [--path <dir>] [--git <url> [--tag|--rev|--branch <ref>]]\n" +
    "                [--nuget] [--manifest <lyric.toml>] [--no-restore]\n" +
    "                (adds/updates a dependency in [dependencies] (or [nuget]) and restores)\n" +
    "  lyric publish [--manifest <lyric.toml>] [--dll <path>] [-o <dir>] [--registry <url>] [--api-key <key>]\n" +
    "  lyric search  <term>\n" +
    "\n" +
    "Dev loop:\n" +
    "  lyric run     [<source.l>] [--manifest <lyric.toml>] [--target dotnet|jvm] [--watch] [-- <args>...]\n" +
    "                (no source: builds and runs the discovered project;\n" +
    "                 --watch: rebuild & re-run on source changes; Ctrl-C to stop)\n" +
    "  lyric test    [<source.l>] [--manifest <lyric.toml>] [--filter <prefix>] [--list] [--target dotnet|jvm]\n" +
    "                (no source: runs all [project.tests] from the discovered project)\n" +
    "  lyric bench   [<source.l>] [--manifest <lyric.toml>] [--runs N] [--warmup N] [--filter <prefix>]\n" +
    "                (no source: benchmarks all @bench_module files in the discovered project)\n" +
    "  lyric repl\n" +
    "\n" +
    "Quality:\n" +
    "  lyric fmt     [<source.l>] [--manifest <lyric.toml>] [--check] [--write]\n" +
    "                (no source: dry-run shows what would change; --write to apply; --check exits 1 if any would change)\n" +
    "  lyric lint    [<source.l>] [--manifest <lyric.toml>] [--error-on-warning]\n" +
    "                (no source: lints all project source files)\n" +
    "  lyric prove   [<source.l>] [--manifest <lyric.toml>] [--verbose] [--allow-unverified] [--json] [--explain --goal <n>]\n" +
    "                (no source: proves contracts in all project source files)\n" +
    "  lyric doc     [<source.l>] [--manifest <lyric.toml>] [-o <out.md|dir>]\n" +
    "                (no source: generates docs/ for all project source files)\n" +
    "  lyric public-api-diff <old.dll> <new.dll>\n" +
    "\n" +
    "Codegen:\n" +
    "  lyric openapi <spec.json> [-o <out.l>] [--client-name <Name>] [--package <Pkg>]\n" +
    "\n" +
    "  lyric --version | --help\n" +
    "\n" +
    "Notes:\n" +
    "  build is incremental — same source + stdlib skips emit; --force rebuilds.\n" +
    "  build/restore/run/fmt/lint/prove/doc/test/bench all discover the nearest\n" +
    "  lyric.toml by walking up from the current directory when no source file is given.\n" +
    "  fmt:  no-arg project mode dry-run shows what would change; --write applies; --check exits 1 if any would change.\n" +
    "        Non-doc comments (//) are not preserved — only /// and //!.\n" +
    "  lint: L001-L005 style checks. --error-on-warning exits 1 on warnings."
}

func printUsage(): Unit {
  printErr(usageText())
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
//   1. $LYRIC_STDLIB_BIN          — explicit override
//   2. <appBaseDir>               — DLLs ship beside the binary
//   3. <appBaseDir>/lib           — installed SDK layout
//   4. walk up (appBase, cwd) for .bootstrap/stage1   — dev bootstrap output
//   5. walk up (appBase, cwd) for lyric-stdlib/bin     — dev manifest build
// Returns "" when no candidate holds `Lyric.Stdlib.dll`.
func findCompiledLibDir(): String {
  val env = Environment.getVarOrDefault("LYRIC_STDLIB_BIN", "")
  if dirHasCompiledStdlib(env) {
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

// Co-locate the split stdlib runtime assemblies (`Lyric.Stdlib.*.dll` — the
// per-package façades, their `*Host` shims) plus `FSharp.Core.dll` from the
// SDK/publish lib dir `srcDir` next to the assembly at `outPath`.  The
// self-hosted codegen references the stdlib under split per-package assembly
// names, but a manifest dependency build only ships the bundled
// `Lyric.Stdlib.dll`; co-locating the split DLLs lets `dotnet exec` resolve
// them (flat `additionalProbingPaths` do not work for a non-NuGet layout).
// Best-effort: existing files are left in place and copy failures are
// non-fatal — the run then surfaces the original assembly-load error.
// Always overwrites existing DLLs so stale copies from previous runs are
// replaced when the stdlib is rebuilt.
func copyRuntimeDepsBeside(outPath: in String, srcDir: in String): Unit {
  if srcDir.length == 0 {
    return
  }
  val destDir = Path.dirname(outPath)
  match File.listFiles(srcDir) {
    case Err(_) -> ()
    case Ok(fs) -> {
      for f in fs.toArray() {
        val base = Path.basename(f)
        val wanted = (Str.startsWith(base, "Lyric.Stdlib") and Str.endsWith(base, ".dll")) or base == "FSharp.Core.dll" or
          base == "Lyric.Emitter.dll"
        if wanted {
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

// Compile `sourcePath` to a DLL at `outPath`.
// Returns the exit code: 0 on success, 1 on error.
// `manifestPath` is forwarded to the generator pre-processor so custom
// @generate(Pkg.Name) annotations can resolve their generator DLLs.
func buildOne(sourcePath: in String, outPath: in String, target: in CompileTarget, manifestPath: in Option[String]): Int {
  var source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("build: " + IOError.message(e))
      return 1
    }
  }

  // Run custom @generate(X.Y) pre-processing before handing source to the
  // emitter.  Built-in generators (@generate(Json) etc.) are handled later
  // inside the F# bootstrap's Generate.synthesizeItems pass.
  source = match Generator.preprocess(source, match manifestPath { case Some(p) -> p; case None -> "" }, sourcePath) {
    case Ok(augmented) -> augmented
    case Err(msg) -> {
      printErr("build: generator error: " + msg)
      return 1
    }
  }

  val outDir = Path.dirname(outPath)
  match File.createDir(outDir) {
    case Ok(_) -> ()
    case Err(e) -> printErr("build: cannot create output dir: " + IOError.message(e))
  }

  val outBase = Path.basename(outPath)
  val asmName = stemOf(outBase, 4)  // strip ".dll"
  val req = EmitRequest(
    source = source,
    assemblyName = asmName,
    outputPath = outPath,
    target = target,
    packageVersion = ""
  )

  val result = Emitter.emit(req)
  var hadError = false
  for d in result.diagnostics.toArray() {
    match d.severity {
      case DiagError -> {
        hadError = true
      }
      case DiagWarning -> ()
    }
    printDiag(d)
  }

  if hadError {
    printErr(sourcePath + ": build failed")
    return 1
  }

  // Also check the output path: if the emitter reported no diagnostics but
  // still failed (e.g. the --internal-build subprocess exited non-zero with
  // errors already printed to stderr), outputPath will be None.
  match result.outputPath {
    case None -> {
      printErr(sourcePath + ": build failed")
      return 1
    }
    case Some(_) -> ()
  }

  // A `.runtimeconfig.json` is a .NET-only artifact consumed by `dotnet exec`;
  // a JVM build produces a self-contained runnable JAR, so emitting one there
  // would leave stray .NET tooling cruft next to the JAR.
  match target {
    case Dotnet -> writeRuntimeConfig(outPath)
    case Jvm -> ()
  }
  Console.println("built " + outPath)
  0
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Build command
// ─────────────────────────────────────────────────────────────────────────────
func cmdBuild(argv: in slice[String]): Int {
  var force = false
  var explicitOut: Option[String] = None
  var manifestArg: Option[String] = None
  var target: CompileTarget = Dotnet
  // D045 build features.  Captured here for spec parity with the F#
  // bootstrap CLI; the self-hosted compiler will consume them once the
  // emitter ships (Phase 5+ stage 7).
  val cliFeatures: List[String] = newList()
  var noDefaultFeatures: Bool = false
  var allFeatures: Bool = false
  var release: Bool = false
  var ridArg: Option[String] = None
  var noRestore: Bool = false
  var watch: Bool = false
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--force" {
      force = true
      i += 1
    } else if arg == "-o" {
      if i + 1 < argv.length {
        explicitOut = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("build: -o requires an argument")
        return 1
      }
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("build: --manifest requires an argument")
        return 1
      }
    } else if arg == "--features" {
      if i + 1 < argv.length {
        val raw = argv[i + 1]
        // Comma-separated, whitespace-trimmed; empty entries dropped.
        val pieces = Str.split(raw, ",")
        for piece in pieces {
          val trimmed = Str.trim(piece)
          if Str.length(trimmed) > 0 {
            cliFeatures.add(trimmed)
          }
        }
        i += 2
      } else {
        printErr("build: --features requires a comma-separated list")
        return 1
      }
    } else if arg == "--no-default-features" {
      noDefaultFeatures = true
      i += 1
    } else if arg == "--all-features" {
      allFeatures = true
      i += 1
    } else if arg == "--release" {
      release = true
      i += 1
    } else if arg == "--rid" {
      if i + 1 < argv.length {
        ridArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("build: --rid requires an argument")
        return 1
      }
    } else if arg == "--no-restore" {
      noRestore = true
      i += 1
    } else if arg == "--watch" {
      watch = true
      i += 1
    } else if arg == "--target" {
      if i + 1 < argv.length {
        val t = argv[i + 1]
        if t == "jvm" {
          target = Jvm
        } else {
          target = Dotnet
        }
        i += 2
      } else {
        printErr("build: --target requires an argument")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }
  // `--rid` only applies to `--release` (Native AOT); warn rather than ignore
  // it silently on a normal build (#2022).
  match ridArg {
    case Some(_) -> if not release { printErr("build: warning: --rid has no effect without --release") }
    case None -> ()
  }
  // `--no-restore` only affects project-mode auto-restore; warn rather than
  // silently ignore it on a single-file build (#2048).
  if noRestore and positional.count > 0 {
    printErr("build: warning: --no-restore has no effect without a project manifest")
  }
  // Project-mode: `lyric build --manifest lyric.toml`, or no positional source
  // at all (discover the nearest lyric.toml by walking up from the cwd).
  if positional.count == 0 {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("build: no source file given and no lyric.toml found in this directory or any parent")
        printUsage()
        return 1
      }
    }
    if release {
      // Project-mode Native AOT is a focused follow-up (needs entry-package
      // detection across the bundle + path-dependency referencing); tracked in
      // #1975.  Fail loud rather than silently producing a managed DLL.
      printErr(
        "build: --release for project mode is not yet supported; build a single-file entry with `lyric build --release <main.l>` (tracked in #1975)"
      )
      return 1
    }
    if watch {
      return watchLoop(
        projectWatchFiles(mfPath),
        BuildProj(
          mfPath = mfPath,
          outArg = explicitOut,
          target = target,
          feats = cliFeatures,
          noDef = noDefaultFeatures,
          allF = allFeatures,
          noRestore = noRestore
        )
      )
    }
    return buildProject(mfPath, explicitOut, target, cliFeatures, noDefaultFeatures, allFeatures, noRestore)
  }

  val sourcePath = positional[0]
  if not File.fileExists(sourcePath) {
    printErr("build: source file not found: " + sourcePath)
    return 1
  }

  if release and watch {
    printErr("build: --watch is not supported with --release")
    return 1
  }

  if release {
    return buildReleaseSingle(sourcePath, explicitOut, target, ridArg, manifestArg)
  }

  val outPath = match explicitOut {
    case Some(o) -> o
    case None -> {
      val dir = Path.dirname(sourcePath)
      val stem = stemOf(Path.basename(sourcePath), 2)  // strip ".l"
      // Default output extension is target-aware: a `--target jvm` build
      // produces a runnable JAR, a `--target dotnet` build a managed DLL.
      val ext = match target { case Jvm -> ".jar"; case Dotnet -> ".dll" }
      Path.join(dir, stem + ext)
    }
  }

  if watch {
    val files: List[String] = newList()
    files.add(sourcePath)
    return watchLoop(files, BuildFile(sourcePath = sourcePath, outArg = outPath, target = target, manifest = manifestArg))
  }

  buildOne(sourcePath, outPath, target, manifestArg)
}

// Single-file `lyric build --release <source.l>`: compile to a staging DLL,
// then produce a self-contained native binary via Lyric.Release.  The default
// output is the source stem with no extension (an executable), next to the
// source unless `-o` overrides it.
func buildReleaseSingle(
  sourcePath: in String,
  explicitOut: in Option[String],
  target: in CompileTarget,
  ridArg: in Option[String],
  manifestArg: in Option[String],
): Int {
  val releaseTarget = match target { case Jvm -> Release.JvmNativeImage; case Dotnet -> Release.DotnetAot }
  // JVM (GraalVM) release fails loud without doing a wasted .NET build.
  match releaseTarget {
    case JvmNativeImage -> return Release.buildRelease(releaseTarget, "", "", newList(), ridArg, "")
    case DotnetAot -> ()
  }

  val srcText = match File.readText(sourcePath) {
    case Ok(t) -> t
    case Err(e) -> {
      printErr("build: " + IOError.message(e))
      return 1
    }
  }
  val pkgName = Release.packageNameOf(srcText)
  // Validate the entry package up front — before the (slow) managed build —
  // so a source with no `package` declaration fails fast (#2021).
  if pkgName == "" {
    printErr("build: --release: no `package` declaration found in " + sourcePath)
    return 1
  }

  val srcDir = Path.dirname(sourcePath)
  val stem = stemOf(Path.basename(sourcePath), 2)  // strip ".l"
  val stagingDll = Path.join(Path.join(srcDir, ".lyric-release"), stem + ".dll")
  val buildExit = buildOne(sourcePath, stagingDll, Dotnet, manifestArg)
  if buildExit != 0 {
    return buildExit
  }

  val outNative = match explicitOut { case Some(o) -> o; case None -> Path.join(srcDir, stem) }
  Release.buildRelease(releaseTarget, stagingDll, pkgName, newList(), ridArg, outNative)
}

// Deterministic ascending sort of a file-path list.
//
// Uses a monomorphic selection sort over `List[String]` rather than
// `Std.Sort.sortStrings`: `cli.l` is compiled by the F# stage-1 bootstrap
// during stage-1, which bundles `Std.Sort` inline and produces broken code for
// its typed-lambda generics — the bundled `sortStrings` crashes at runtime.
// This workaround can be retired once stage-2 self-hosting lands (cli.l
// compiled exclusively by the self-hosted compiler).  Tracking: #2592 slice 4.
func sortFileList(xs: in List[String]): List[String] {
  val remaining: List[String] = newList()
  var c = 0
  while c < xs.count {
    remaining.add(xs[c])
    c = c + 1
  }
  val sorted: List[String] = newList()
  while remaining.count > 0 {
    var bestIdx = 0
    var k = 1
    while k < remaining.count {
      if remaining[k] < remaining[bestIdx] {
        bestIdx = k
      }
      k = k + 1
    }
    sorted.add(remaining[bestIdx])
    remaining.removeAt(bestIdx)
  }
  sorted
}

// Project-mode build: reads [project.packages] from lyric.toml and
// bundles every package's .l files into a single DLL.
func buildProject(
  mfPath: in String,
  explicitOut: in Option[String],
  target: in CompileTarget,
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
  allFeatures: in Bool,
  noRestore: in Bool,
): Int {
  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("build: " + IOError.message(e))
      return 1
    }
  }
  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("build: " + ManifestError.message(e))
      return 1
    }
  }
  val proj: ProjectSection = match manifest.project {
    case Some(p) -> p
    case None -> {
      printErr("build: " + mfPath + " has no [project] section")
      return 1
    }
  }

  // Auto-restore: when the manifest declares dependencies and lyric.lock is
  // missing or out of sync with the [dependencies] table, resolve them before
  // building so a clean checkout (or a just-edited dependency set) builds
  // without a manual `lyric restore`.  `--no-restore` opts out.
  if not noRestore and lockNeedsRestore(mfPath, manifest) {
    Console.println("build: resolving dependencies (lyric.lock missing or stale) ...")
    val rc = runRestore(mfPath, false)
    if rc != 0 {
      printErr("build: dependency restore failed")
      return rc
    }
  }

  // D045: resolve active feature set from manifest defaults + CLI flags.
  // `getManifestFeaturesOrEmpty` returns the whole FeaturesSection record from
  // the match arm (bootstrap-emitter-safe pattern); field access happens after
  // the match, outside any match arm body.
  // D045: resolve active feature set from manifest defaults + CLI flags.
  // readFeatureDefaultsFromToml / readFeatureDeclaredFromToml bypass the
  // Manifest.features field (which has a bootstrap-emitter match quirk when
  // the field type is Option[FeaturesSection]) and scan the raw TOML text
  // directly.  mfText was already read at the top of this function.
  val mfDefaults = Mf.readFeatureDefaultsFromToml(mfText, mfPath)
  val mfDeclared = Mf.readFeatureDeclaredFromToml(mfText, mfPath)
  val activeFeatures: List[String] = newList()
  if allFeatures {
    var ai = 0
    while ai < mfDeclared.count {
      activeFeatures.add(mfDeclared[ai])
      ai += 1
    }
  } else {
    if not noDefaultFeatures {
      var ai = 0
      while ai < mfDefaults.count {
        activeFeatures.add(mfDefaults[ai])
        ai += 1
      }
    }
    var ci = 0
    while ci < cliFeatures.count {
      activeFeatures.add(cliFeatures[ci])
      ci += 1
    }
  }

  val mfDir = Path.dirname(mfPath)
  val outPath = match explicitOut {
    case Some(o) -> o
    case None -> {
      val stem = match proj.outputAssembly { case Some(s) -> s; case None -> proj.name + ".dll" }
      Path.join(Path.join(mfDir, "bin"), stem)
    }
  }

  val outDir = Path.dirname(outPath)
  match File.createDir(outDir) {
    case Ok(_) -> ()
    case Err(e) -> printErr("build: cannot create output dir: " + IOError.message(e))
  }

  if proj.packages.count == 0 {
    printErr(
      "build: " + mfPath +
        " [project.packages] is empty — single-DLL projects require explicit per-package source dirs (auto-discovery not yet wired)"
    )
    return 1
  }

  // Collect sources for each package entry individually (not concatenated).
  // Each package entry may be a single .l file or a directory of .l files.
  val pkgs: List[ProjectPackage] = newList()
  var hadFatal = false
  var pi = 0
  while pi < proj.packages.count {
    val pkgEntry = proj.packages[pi]
    val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(mfDir, pkgEntry.path) }
    val pkgSources: List[String] = newList()
    if File.fileExists(abs) {
      // Single .l file: read it directly, then run custom generators.
      match File.readText(abs) {
        case Ok(raw) -> {
          match Generator.preprocess(raw, mfPath, abs) {
            case Ok(t) -> pkgSources.add(t)
            case Err(e) -> {
              printErr("build: package '" + pkgEntry.name + "': generator error in " + abs + ": " + e)
              hadFatal = true
            }
          }
        }
        case Err(e) -> {
          printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
        }
      }
    } else if File.dirExists(abs) {
      // Directory: collect all .l files recursively, sorted for determinism.
      val allFiles = match File.listFilesRecursive(abs) {
        case Ok(fs) -> fs
        case Err(e) -> {
          printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
          newList()
        }
      }
      val lFiles: List[String] = newList()
      for f in allFiles.toArray() {
        if Str.endsWith(f, ".l") {
          lFiles.add(f)
        }
      }
      if lFiles.count == 0 {
        printErr("build: package '" + pkgEntry.name + "': no .l files found in " + abs)
        hadFatal = true
      } else {
        val sorted = sortFileList(lFiles)
        for f in sorted {
          match File.readText(f) {
            case Ok(raw) -> {
              match Generator.preprocess(raw, mfPath, f) {
                case Ok(t) -> pkgSources.add(t)
                case Err(e) -> {
                  printErr("build: package '" + pkgEntry.name + "': generator error in " + f + ": " + e)
                  hadFatal = true
                }
              }
            }
            case Err(e) -> {
              printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
              hadFatal = true
            }
          }
        }
      }
    } else {
      printErr("build: package '" + pkgEntry.name + "': path not found: " + abs)
      hadFatal = true
    }
    if pkgSources.count > 0 {
      pkgs.add(ProjectPackage(name = pkgEntry.name, sources = pkgSources))
    }
    pi += 1
  }

  if hadFatal {
    return 1
  }

  // Resolve local-path dependencies to DLL paths.
  // Format: "depName\tdllPath" — passed to emitter.l which writes "DEP\t..." lines.
  val restoredDlls: List[String] = newList()
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Path(dir) -> {
        val depDir = if Path.isAbsolute(dir) { dir } else { Path.join(mfDir, dir) }
        val depToml = Path.join(depDir, "lyric.toml")
        val depBinDir = Path.join(depDir, "bin")
        if File.fileExists(depToml) {
          match File.readText(depToml) {
            case Ok(depMfText) -> {
              match Mf.parseManifest(depMfText, depToml) {
                case Ok(depMf) -> {
                  val dllName = match depMf.project {
                    case Some(p) -> match p.outputAssembly { case Some(asm) -> asm; case None -> p.name + ".dll" }
                    case None -> depMf.packageSection.name + ".dll"
                  }
                  val dllPath = Path.join(depBinDir, dllName)
                  if File.fileExists(dllPath) {
                    restoredDlls.add(dep.name + "\t" + dllPath)
                  } else {
                    printErr("build: local dep '" + dep.name + "' not built — run `lyric build --manifest " + depToml + "` first")
                  }
                }
                case Err(e) -> {
                  printErr("build: local dep '" + dep.name + "': malformed lyric.toml: " + ManifestError.message(e))
                }
              }
            }
            case Err(e) -> {
              printErr("build: local dep '" + dep.name + "': cannot read " + depToml + ": " + IOError.message(e))
            }
          }
        } else {
          printErr(
            "build: local dep '" + dep.name + "' — no lyric.toml found at '" + depToml +
              "'; check the path = \"...\" entry in your lyric.toml"
          )
        }
      }
      case _ -> ()
    }
    di += 1
  }

  val asmName = stemOf(Path.basename(outPath), 4)
  val projReq = EmitProjectRequest(
    packages = pkgs,
    assemblyName = asmName,
    outputPath = outPath,
    target = target,
    restoredDllPaths = restoredDlls,
    activeFeatures = activeFeatures,
    declaredFeatures = mfDeclared,
    packageVersion = manifest.packageSection.version
  )

  val result = Emitter.emitProject(projReq)
  var hadError = false
  for d in result.diagnostics.toArray() {
    match d.severity {
      case DiagError -> {
        hadError = true
      }
      case DiagWarning -> ()
    }
    printDiag(d)
  }

  if hadError {
    printErr(mfPath + ": project build failed")
    return 1
  }

  writeRuntimeConfig(outPath)
  Console.println("built " + outPath)
  0
}

// Compute the default output DLL path for a project build (no explicit -o).
func projectBinDllPath(mfDir: in String, proj: in ProjectSection): String {
  val stem = match proj.outputAssembly { case Some(s) -> s; case None -> proj.name + ".dll" }
  Path.join(Path.join(mfDir, "bin"), stem)
}

// Target-aware variant of projectBinDllPath: returns the runnable artifact path
// (.dll for Dotnet, .jar for Jvm) that buildProject writes.
func projectBinOutputPath(mfDir: in String, proj: in ProjectSection, target: in CompileTarget): String {
  match target {
    case Jvm -> {
      val stem = match proj.outputAssembly {
        case Some(s) -> {
          if Str.endsWith(s, ".dll") {
            Str.substring(s, 0, s.length - 4) + ".jar"
          } else {
            s
          }
        }
        case None -> proj.name + ".jar"
      }
      Path.join(Path.join(mfDir, "bin"), stem)
    }
    case Dotnet -> projectBinDllPath(mfDir, proj)
  }
}

// Collect all .l source file paths from [project.packages] in a lyric.toml.
// Returns (paths, hadFatal). A file entry yields itself; a directory entry yields
// all .l files under it, sorted deterministically.
func collectProjectSourcePaths(mfPath: in String): (List[String], Bool) {
  val paths: List[String] = newList()
  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("cannot read manifest: " + IOError.message(e))
      return (paths, true)
    }
  }
  val manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("cannot parse manifest: " + ManifestError.message(e))
      return (paths, true)
    }
  }
  val proj = match manifest.project {
    case Some(p) -> p
    case None -> {
      printErr(mfPath + " has no [project] section")
      return (paths, true)
    }
  }
  val mfDir = Path.dirname(mfPath)
  var hadFatal = false
  var pi = 0
  while pi < proj.packages.count {
    val pkgEntry = proj.packages[pi]
    val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(mfDir, pkgEntry.path) }
    if File.fileExists(abs) {
      paths.add(abs)
    } else if File.dirExists(abs) {
      val allFiles = match File.listFilesRecursive(abs) {
        case Ok(fs) -> fs
        case Err(e) -> {
          printErr("package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
          newList()
        }
      }
      val lFiles: List[String] = newList()
      for f in allFiles.toArray() {
        if Str.endsWith(f, ".l") {
          lFiles.add(f)
        }
      }
      val sorted = sortFileList(lFiles)
      for f in sorted {
        paths.add(f)
      }
    } else {
      printErr("package '" + pkgEntry.name + "': path not found: " + abs)
      hadFatal = true
    }
    pi += 1
  };
  (paths, hadFatal)
}

// Build a project and run its output artifact.
func runProjectOnce(mfPath: in String, userArgs: in List[String], target: in CompileTarget): Int {
  val mfText = match File.readText(mfPath) {
    case Ok(t) -> t
    case Err(e) -> {
      printErr("run: " + IOError.message(e))
      return 1
    }
  }
  val manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("run: " + ManifestError.message(e))
      return 1
    }
  }
  val proj = match manifest.project {
    case None -> {
      printErr("run: " + mfPath + " has no [project] section")
      return 1
    }
    case Some(p) -> p
  }
  val mfDir = Path.dirname(mfPath)
  val buildRc = buildProject(mfPath, None, target, newList(), false, false, false)
  if buildRc != 0 {
    return buildRc
  }
  val outPath = projectBinOutputPath(mfDir, proj, target)
  if not File.fileExists(outPath) {
    printErr("run: project output not found after build: " + outPath)
    return 1
  }
  match target {
    case Jvm -> {
      val execArgs: List[String] = newList()
      execArgs.add("-jar")
      execArgs.add(outPath)
      for a in userArgs.toArray() {
        execArgs.add(a)
      }
      match Process.run("java", execArgs) {
        case Ok(code) -> code
        case Err(e) -> {
          printErr("run: failed to start java: " + IOError.message(e))
          1
        }
      }
    }
    case Dotnet -> {
      copyRuntimeDepsBeside(outPath, findCompiledLibDir())
      val execArgs: List[String] = newList()
      execArgs.add("exec")
      execArgs.add(outPath)
      for a in userArgs.toArray() {
        execArgs.add(a)
      }
      match Process.run("dotnet", execArgs) {
        case Ok(code) -> code
        case Err(e) -> {
          printErr("run: failed to start dotnet: " + IOError.message(e))
          1
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Run command
// ─────────────────────────────────────────────────────────────────────────────
// ── --watch support (#1974) ──────────────────────────────────────────────────
//
// The watch loop runs in the CLI process (the .NET AOT binary), polling a set
// of source files and re-running the action when any of them changes.  Change
// detection fingerprints each file with sha512 (reused from lock integrity) so
// it needs no new file-metadata primitive; the only new stdlib primitive is the
// synchronous Std.Time.sleepMillis poll interval.  The loop runs until the user
// interrupts it (Ctrl-C).
val WATCH_POLL_MS: Int = 400

// The deferred action a watch loop re-runs on each detected change.
union WatchAction {
  case RunFile(sourcePath: String, userArgs: List[String])
  case RunProj(mfPath: String, userArgs: List[String], target: CompileTarget)
  case BuildProj(mfPath: String, outArg: Option[String], target: CompileTarget, feats: List[String], noDef: Bool, allF: Bool, noRestore: Bool)
  case BuildFile(sourcePath: String, outArg: String, target: CompileTarget, manifest: Option[String])
}

// Build the program once and `dotnet exec` it.  Extracted from cmdRun so the
// watch loop can re-run it.
func runOnce(sourcePath: in String, userArgs: in List[String]): Int {
  val srcDir = Path.dirname(sourcePath)
  val stem = stemOf(Path.basename(sourcePath), 2)
  val outPath = Path.join(Path.join(srcDir, ".lyric-run"), stem + ".dll")

  val buildExit = buildOne(sourcePath, outPath, Dotnet, None)
  if buildExit != 0 {
    return buildExit
  }

  // Co-locate the fully-compiled stdlib runtime assemblies beside the output
  // so a program using real stdlib `pub func`s (Std.Testing / Std.Json /
  // Std.Time / … — anything not lowered to a BCL intrinsic) resolves them
  // under `dotnet exec`.  Discovery is non-hardcoded (see findCompiledLibDir).
  copyRuntimeDepsBeside(outPath, findCompiledLibDir())

  val execArgs: List[String] = newList()
  execArgs.add("exec")
  execArgs.add(outPath)
  for a in userArgs.toArray() {
    execArgs.add(a)
  }

  match Process.run("dotnet", execArgs) {
    case Ok(code) -> code
    case Err(e) -> {
      printErr("run: failed to start dotnet: " + IOError.message(e))
      1
    }
  }
}

func runWatchAction(a: in WatchAction): Int {
  match a {
    case RunFile(sp, ua) -> runOnce(sp, ua)
    case RunProj(mp, ua, t) -> runProjectOnce(mp, ua, t)
    case BuildProj(mf, o, t, f, nd, af, nr) -> buildProject(mf, o, t, f, nd, af, nr)
    case BuildFile(sp, o, t, m) -> buildOne(sp, o, t, m)
  }
}

// A change-detection fingerprint over `files`: each file's sha512 (or "∅" when
// missing) joined together, so adding, removing, or editing any watched file
// flips the value.
func watchFingerprint(files: in List[String]): String {
  var fp = ""
  var i = 0
  while i < files.count {
    val f = files[i]
    val h = match Hash.sha512OfFile(f) { case Ok(x) -> x; case Err(_) -> "∅" }
    fp = fp + f + "=" + h + ";"
    i += 1
  }
  fp
}

// Run `action` once, then poll `files` and re-run on every change until the
// process is interrupted.  Never returns under normal use.
func watchLoop(files: in List[String], action: in WatchAction): Int {
  Console.println("watch: watching " + toString(files.count) + " file(s); press Ctrl-C to stop")
  // Snapshot the fingerprint BEFORE the initial run so any edit that occurs
  // during compilation is captured by the first poll and triggers a re-run.
  var fp = watchFingerprint(files)
  val initRc = runWatchAction(action)
  Console.println("watch: done (exit " + toString(initRc) + "); waiting for changes ...")
  while true {
    Time.sleepMillis(WATCH_POLL_MS)
    val cur = watchFingerprint(files)
    if cur != fp {
      fp = cur
      Console.println("")
      Console.println("watch: change detected — rerunning ...")
      val rc = runWatchAction(action)
      Console.println("watch: done (exit " + toString(rc) + "); waiting for changes ...")
    }
  }
  0
}

// The files a project `build --watch` should watch: the manifest plus every
// `[project.packages]` source path (resolved relative to the manifest dir).
func projectWatchFiles(mfPath: in String): List[String] {
  val files: List[String] = newList()
  files.add(mfPath)
  val mfDir = Path.dirname(mfPath)
  match File.readText(mfPath) {
    case Err(_) -> {
      Console.error("watch: could not read manifest '" + mfPath + "' — watching manifest file only")
    }
    case Ok(txt) -> match Mf.parseManifest(txt, mfPath) { case Err(_) -> { Console.error("watch: could not parse manifest '" + mfPath + "' — watching manifest file only") }; case Ok(m) -> match m.project { case None -> (); case Some(p) -> { var i = 0; while i < p.packages.count { files.add(Path.join(mfDir, p.packages[i].path)); i += 1 } } } }
  }
  files
}

func cmdRun(argv: in slice[String]): Int {
  var watch = false
  var sourcePath = ""
  var haveSource = false
  var manifestArg: Option[String] = None
  var targetArg: Option[String] = None
  val userArgs: List[String] = newList()

  var i = 1
  var pastSep = false
  while i < argv.length {
    val arg = argv[i]
    if pastSep {
      userArgs.add(arg)
      i += 1
    } else if arg == "--" {
      pastSep = true
      i += 1
    } else if arg == "--watch" {
      watch = true
      i += 1
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("run: --manifest requires a path")
        return 1
      }
    } else if arg == "--target" {
      if i + 1 < argv.length {
        targetArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("run: --target requires dotnet or jvm")
        return 1
      }
    } else if not haveSource {
      sourcePath = arg
      haveSource = true
      i += 1
    } else {
      userArgs.add(arg)
      i += 1
    }
  }

  val runTarget = match targetArg { case Some(t) -> if t == "jvm" { Jvm } else { Dotnet }; case None -> Dotnet }

  // Project-mode: no explicit source file — discover or use --manifest.
  if not haveSource {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("run: missing source file and no lyric.toml found")
        printUsage()
        return 1
      }
    }
    if watch {
      return watchLoop(projectWatchFiles(mfPath), RunProj(mfPath = mfPath, userArgs = userArgs, target = runTarget))
    }
    return runProjectOnce(mfPath, userArgs, runTarget)
  }

  if not File.fileExists(sourcePath) {
    printErr("run: source file not found: " + sourcePath)
    return 1
  }

  if watch {
    val files: List[String] = newList()
    files.add(sourcePath)
    return watchLoop(files, RunFile(sourcePath = sourcePath, userArgs = userArgs))
  }

  runOnce(sourcePath, userArgs)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Fmt command
// ─────────────────────────────────────────────────────────────────────────────
func cmdFmt(argv: in slice[String]): Int {
  var checkMode = false
  var writeMode = false
  var manifestArg: Option[String] = None
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--check" {
      checkMode = true
      i += 1
    } else if arg == "--write" {
      writeMode = true
      i += 1
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("fmt: --manifest requires a path")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // Project-mode: no explicit source file — discover or use --manifest.
  // In-place write is implicit (like `cargo fmt`); --check just reports.
  if positional.count == 0 {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("fmt: missing source file and no lyric.toml found")
        printUsage()
        return 1
      }
    }
    val (sourcePaths, hadFatal) = collectProjectSourcePaths(mfPath)
    if hadFatal {
      return 1
    }
    if sourcePaths.count == 0 {
      printErr("fmt: no source files found in project")
      return 1
    }
    if checkMode {
      // --check: silently exit 1 if any file needs formatting; print which ones.
      var anyUnformatted = false
      var pi = 0
      while pi < sourcePaths.count {
        val sp = sourcePaths[pi]
        pi += 1
        val source = match File.readText(sp) {
          case Ok(t) -> t
          case Err(e) -> {
            printErr("fmt: " + IOError.message(e))
            anyUnformatted = true
            continue
          }
        }
        if not Fmt.isFormattedSource(source) {
          printErr(sp + ": not formatted — run `lyric fmt --write` to reformat")
          anyUnformatted = true
        }
      }
      if anyUnformatted {
        return 1
      }
      return 0
    }
    if writeMode {
      // --write: format every file in-place; skip files that are already correct.
      var anyFailed = false
      var fi = 0
      while fi < sourcePaths.count {
        val sp = sourcePaths[fi]
        fi += 1
        val source = match File.readText(sp) {
          case Ok(t) -> t
          case Err(e) -> {
            printErr("fmt: " + IOError.message(e))
            anyFailed = true
            continue
          }
        }
        val checkResult = Fmt.formatSourceChecked(source)
        if not Fmt.fmtCheckIsOk(checkResult) {
          printErr(sp + ": " + Fmt.fmtCheckMessage(checkResult))
          anyFailed = true
          continue
        }
        val formatted = Fmt.fmtCheckText(checkResult)
        if formatted == source {
          continue
        }
        match File.writeText(sp, formatted) {
          case Ok(_) -> Console.println("formatted " + sp)
          case Err(e) -> {
            printErr("fmt: " + IOError.message(e))
            anyFailed = true
          }
        }
      }
      if anyFailed {
        return 1
      }
      return 0
    }
    // Default (no --write, no --check): dry-run — report what would change without writing.
    var anyUnformatted = false
    var di = 0
    while di < sourcePaths.count {
      val sp = sourcePaths[di]
      di += 1
      val source = match File.readText(sp) {
        case Ok(t) -> t
        case Err(e) -> {
          printErr("fmt: " + IOError.message(e))
          anyUnformatted = true
          continue
        }
      }
      if not Fmt.isFormattedSource(source) {
        Console.println(sp + ": would reformat")
        anyUnformatted = true
      }
    }
    if anyUnformatted {
      Console.println("run `lyric fmt --write` to apply")
      return 1
    }
    return 0
  }

  // Single-file mode (existing behaviour):
  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("fmt: " + IOError.message(e))
      return 1
    }
  }

  // `--check` is a read-only "is this already formatted?" probe: it must
  // never abort on a file the formatter cannot round-trip (it writes
  // nothing), so it stays on the plain `isFormattedSource` comparison.
  if checkMode {
    if Fmt.isFormattedSource(source) {
      return 0
    } else {
      printErr(sourcePath + ": not formatted — run `lyric fmt --write`")
      return 1
    }
  }

  // Write / print: route through the loss-checked path so we never emit
  // or persist output that would drop a comment, change the code-token
  // sequence, or fail to re-parse.  See `Lyric.Fmt.formatSourceChecked`.
  val checkResult = Fmt.formatSourceChecked(source)
  if not Fmt.fmtCheckIsOk(checkResult) {
    printErr(sourcePath + ": " + Fmt.fmtCheckMessage(checkResult))
    return 1
  }
  val formatted = Fmt.fmtCheckText(checkResult)

  if writeMode {
    match File.writeText(sourcePath, formatted) {
      case Ok(_) -> {
        Console.println("formatted " + sourcePath)
        return 0
      }
      case Err(e) -> {
        printErr("fmt: " + IOError.message(e))
        return 1
      }
    }
  }

  Console.print(formatted)
  0
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Lint command
// ─────────────────────────────────────────────────────────────────────────────
func cmdLint(argv: in slice[String]): Int {
  var errorOnWarning = false
  var manifestArg: Option[String] = None
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--error-on-warning" {
      errorOnWarning = true
      i += 1
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("lint: --manifest requires a path")
        return 2
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // Project-mode: no explicit source file — discover or use --manifest.
  if positional.count == 0 {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("lint: missing source file and no lyric.toml found")
        printUsage()
        return 2
      }
    }
    val (sourcePaths, hadFatal) = collectProjectSourcePaths(mfPath)
    if hadFatal {
      return 2
    }
    if sourcePaths.count == 0 {
      printErr("lint: no source files found in project")
      return 2
    }
    var hasError = false
    var hasWarning = false
    var pi = 0
    while pi < sourcePaths.count {
      val sp = sourcePaths[pi]
      pi += 1
      val source = match File.readText(sp) {
        case Ok(t) -> t
        case Err(e) -> {
          printErr("lint: " + IOError.message(e))
          hasError = true
          continue
        }
      }
      val lintDiags = Lint.lint(source)
      for d in lintDiags.toArray() {
        val sev = match d.severity { case LintError -> "error"; case LintWarning -> "warning" }
        printErr(
          sp + ": " + d.code + " " + sev + " [" + toString(d.span.startPos.line) + ":" + toString(d.span.startPos.column) +
            "]: " +
            d.message
        )
        match d.severity {
          case LintError -> {
            hasError = true
          }
          case LintWarning -> {
            hasWarning = true
          }
        }
      }
    }
    if hasError or (errorOnWarning and hasWarning) {
      return 1
    }
    return 0
  }

  // Single-file mode (existing behaviour):
  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("lint: " + IOError.message(e))
      return 2
    }
  }

  val lintDiags = Lint.lint(source)
  var hasError = false
  var hasWarning = false
  for d in lintDiags.toArray() {
    val sev = match d.severity { case LintError -> "error"; case LintWarning -> "warning" }
    printErr(
      d.code + " " + sev + " [" + toString(d.span.startPos.line) + ":" + toString(d.span.startPos.column) + "]: " +
        d.message
    )
    match d.severity {
      case LintError -> {
        hasError = true
      }
      case LintWarning -> {
        hasWarning = true
      }
    }
  }

  if hasError or (errorOnWarning and hasWarning) {
    1
  } else {
    0
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Prove command
// ─────────────────────────────────────────────────────────────────────────────
// JSON-escape a string value (no surrounding quotes).
func jsonEsc(s: in String): String {
  var r = ""
  var i = 0
  while i < s.length {
    val c = s[i]
    if c == '"' {
      r = r + "\\\""
    } else if c == '\\' {
      r = r + "\\\\"
    } else if c == '\n' {
      r = r + "\\n"
    } else if c == '\r' {
      r = r + "\\r"
    } else if c == '\t' {
      r = r + "\\t"
    } else {
      r = r + ("" + c)
    }
    i = i + 1
  }
  r
}

func jsonStr(s: in String): String {
  "\"" + jsonEsc(s) + "\""
}

func cmdProve(argv: in slice[String]): Int {
  var verbose = false
  var allowUnverified = false
  var jsonOutput = false
  var explain = false
  var explainGoal: Option[Int] = None
  var manifestArg: Option[String] = None
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--verbose" or arg == "-v" {
      verbose = true
      i += 1
    } else if arg == "--allow-unverified" {
      allowUnverified = true
      i += 1
    } else if arg == "--json" {
      jsonOutput = true
      i += 1
    } else if arg == "--explain" {
      explain = true
      i += 1
    } else if arg == "--goal" {
      if i + 1 < argv.length {
        match parseOptInt(argv[i + 1]) {
          case Some(n) -> {
            explainGoal = Some(value = n)
            i += 2
          }
          case None -> {
            printErr("prove: --goal requires an integer")
            return 1
          }
        }
      } else {
        printErr("prove: --goal requires a value")
        return 1
      }
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("prove: --manifest requires a path")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // Project-mode: no explicit source file — discover or use --manifest.
  // --json and --explain are file-specific and require an explicit source.
  if positional.count == 0 {
    if jsonOutput {
      printErr("prove: --json requires a source file")
      return 1
    }
    if explain {
      printErr("prove: --explain requires a source file")
      return 1
    }
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("prove: missing source file and no lyric.toml found")
        return 1
      }
    }
    val (sourcePaths, hadFatal) = collectProjectSourcePaths(mfPath)
    if hadFatal {
      return 1
    }
    if sourcePaths.count == 0 {
      printErr("prove: no source files found in project")
      return 1
    }
    var totalGoals = 0
    var totalDischarged = 0
    var anyError = false
    var pi = 0
    while pi < sourcePaths.count {
      val sp = sourcePaths[pi]
      pi += 1
      val source = match File.readText(sp) {
        case Ok(t) -> t
        case Err(e) -> {
          printErr("prove: " + IOError.message(e))
          anyError = true
          continue
        }
      }
      val summary = Verifier.proveSourceWithOptions(source, allowUnverified)
      for d in summary.diagnostics.toArray() {
        printDiag(d)
      }
      val total = Verifier.summaryTotalCount(summary)
      val discharged = Verifier.summaryDischargedCount(summary)
      val levelStr = MC.vlDisplay(summary.level)
      if MC.vlIsProofRequired(summary.level) {
        Console.println(
          sp + ": " + toString(discharged) + "/" + toString(total) + " obligations discharged (" + levelStr + ")"
        )
      } else {
        Console.println(sp + ": no proof obligations (" + levelStr + ")")
      }
      totalGoals += total
      totalDischarged += discharged
      if Verifier.summaryHasErrorDiag(summary) or Verifier.summaryHasCounterexample(summary) {
        anyError = true
      }
    }
    if sourcePaths.count > 1 {
      Console.println(
        "project: " + toString(totalDischarged) + "/" + toString(totalGoals) + " total obligations discharged"
      )
    }
    if anyError {
      return 1
    }
    return 0
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("prove: " + IOError.message(e))
      return 1
    }
  }

  val summary = Verifier.proveSourceWithOptions(source, allowUnverified)

  if explain {
    val total = Verifier.summaryTotalCount(summary)
    match explainGoal {
      case None -> {
        printErr("prove --explain: specify a goal index with --goal <n>")
        printErr("  (this file has " + toString(total) + " goal(s))")
        var gi = 0
        while gi < summary.results.count {
          val r = summary.results[gi]
          printErr("  " + toString(gi) + ": " + r.goal.label + "  [" + Verifier.goalKindDisplay(r.goal.kind) + "]")
          gi = gi + 1
        }
        return 1
      }
      case Some(idx) -> {
        if idx < 0 or idx >= total {
          printErr("prove --explain: goal " + toString(idx) + " out of range (0.." + toString(total - 1) + ")")
          return 1
        }
        val r = summary.results[idx]
        Console.print(Verifier.prettyGoal(idx, r.goal))
        return 0
      }
    }
  }

  if jsonOutput {
    var jsonBuf = "{\n"
    jsonBuf = jsonBuf + "  \"file\": " + jsonStr(sourcePath) + ",\n"
    jsonBuf = jsonBuf + "  \"level\": " + jsonStr(MC.vlDisplay(summary.level)) + ",\n"
    jsonBuf = jsonBuf + "  \"goals\": [\n"
    var gi = 0
    while gi < summary.results.count {
      val r = summary.results[gi]
      val gl = r.goal
      val comma = if gi + 1 < summary.results.count { "," } else { "" }
      val outcomeStr = match r.outcome {
        case Discharged -> "discharged"
        case Counterexample(_) -> "counterexample"
        case Unknown(_) -> "unknown"
      }
      val modelStr = match r.outcome { case Counterexample(m) -> jsonStr(m); case _ -> "null" }
      jsonBuf = jsonBuf + "    {\n"
      jsonBuf = jsonBuf + "      \"index\": " + toString(gi) + ",\n"
      jsonBuf = jsonBuf + "      \"label\": " + jsonStr(gl.label) + ",\n"
      jsonBuf = jsonBuf + "      \"kind\": " + jsonStr(Verifier.goalKindDisplay(gl.kind)) + ",\n"
      jsonBuf = jsonBuf + "      \"line\": " + toString(gl.origin.startPos.line) + ",\n"
      jsonBuf = jsonBuf + "      \"col\": " + toString(gl.origin.startPos.column) + ",\n"
      jsonBuf = jsonBuf + "      \"outcome\": " + jsonStr(outcomeStr) + ",\n"
      jsonBuf = jsonBuf + "      \"model\": " + modelStr + ",\n"
      jsonBuf = jsonBuf + "      \"smtPath\": null,\n"
      jsonBuf = jsonBuf + "      \"suggestions\": []\n"
      jsonBuf = jsonBuf + "    }" + comma + "\n"
      gi = gi + 1
    }
    jsonBuf = jsonBuf + "  ],\n"
    jsonBuf = jsonBuf + "  \"diagnostics\": [\n"
    var di = 0
    while di < summary.diagnostics.count {
      val d = summary.diagnostics[di]
      val comma = if di + 1 < summary.diagnostics.count { "," } else { "" }
      val sevStr = match d.severity { case DiagError -> "error"; case DiagWarning -> "warning" }
      jsonBuf = jsonBuf + "    {\"code\":" + jsonStr(d.code) + ",\"severity\":" + jsonStr(sevStr) + ",\"message\":" +
        jsonStr(d.message) +
        ",\"line\":" +
        toString(d.span.startPos.line) +
        ",\"col\":" +
        toString(d.span.startPos.column) +
        "}" +
        comma +
        "\n"
      di = di + 1
    }
    jsonBuf = jsonBuf + "  ],\n"
    jsonBuf = jsonBuf + "  \"summary\": {\n"
    jsonBuf = jsonBuf + "    \"total\": " + toString(Verifier.summaryTotalCount(summary)) + ",\n"
    jsonBuf = jsonBuf + "    \"discharged\": " + toString(Verifier.summaryDischargedCount(summary)) + ",\n"
    jsonBuf = jsonBuf + "    \"unknown\": 0,\n"
    jsonBuf = jsonBuf + "    \"counterexamples\": 0\n"
    jsonBuf = jsonBuf + "  }\n"
    jsonBuf = jsonBuf + "}\n"
    Console.print(jsonBuf)
    if Verifier.summaryHasErrorDiag(summary) or Verifier.summaryHasCounterexample(summary) {
      return 1
    }
    return 0
  }

  for d in summary.diagnostics.toArray() {
    printDiag(d)
  }

  val total = Verifier.summaryTotalCount(summary)
  val discharged = Verifier.summaryDischargedCount(summary)
  val levelStr = MC.vlDisplay(summary.level)

  if MC.vlIsProofRequired(summary.level) {
    Console.println(toString(discharged) + "/" + toString(total) + " obligations discharged (" + levelStr + ")")
  } else {
    Console.println("no proof obligations: package is " + levelStr)
  }

  // Exit 1 only for error diagnostics or counterexamples; unknown goals
  // (trivial solver gave up, z3 not available) are not failures.
  if Verifier.summaryHasErrorDiag(summary) or Verifier.summaryHasCounterexample(summary) {
    1
  } else {
    0
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Doc command
// ─────────────────────────────────────────────────────────────────────────────
func cmdDoc(argv: in slice[String]): Int {
  var explicitOut: Option[String] = None
  var manifestArg: Option[String] = None
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "-o" {
      if i + 1 < argv.length {
        explicitOut = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("doc: -o requires an argument")
        return 1
      }
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("doc: --manifest requires a path")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // Project-mode: no explicit source file — discover or use --manifest.
  // Writes <stem>.md for each source file into docs/ (or -o <dir>).
  if positional.count == 0 {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("doc: missing source file and no lyric.toml found")
        return 1
      }
    }
    val (sourcePaths, hadFatal) = collectProjectSourcePaths(mfPath)
    if hadFatal {
      return 1
    }
    if sourcePaths.count == 0 {
      printErr("doc: no source files found in project")
      return 1
    }
    val mfDir = Path.dirname(mfPath)
    val outDir = match explicitOut { case Some(d) -> d; case None -> Path.join(mfDir, "docs") }
    match File.createDir(outDir) {
      case Ok(_) -> ()
      case Err(e) -> {
        printErr("doc: cannot create output directory '" + outDir + "': " + IOError.message(e))
        return 1
      }
    }
    var anyFailed = false
    var pi = 0
    while pi < sourcePaths.count {
      val sp = sourcePaths[pi]
      pi += 1
      val source = match File.readText(sp) {
        case Ok(t) -> t
        case Err(e) -> {
          printErr("doc: " + IOError.message(e))
          anyFailed = true
          continue
        }
      }
      val md = Doc.generate(source)
      // Preserve subdirectory structure so auth/main.l → docs/auth/main.md
      // rather than colliding with web/main.l → docs/main.md.
      val relLen = if Str.startsWith(sp, mfDir) { mfDir.length + 1 } else { 0 }
      val relPath = if relLen > 0 and relLen < sp.length {
        Str.substring(sp, relLen, sp.length - relLen)
      } else {
        Path.basename(sp)
      }
      val mdRel = stemOf(relPath, 2) + ".md"
      val outPath = Path.join(outDir, mdRel)
      val outParent = Path.dirname(outPath)
      if outParent != outDir {
        val _ = File.createDir(outParent)
      }
      match File.writeText(outPath, md) {
        case Ok(_) -> Console.println("wrote " + outPath)
        case Err(e) -> {
          printErr("doc: " + IOError.message(e))
          anyFailed = true
        }
      }
    }
    if anyFailed {
      return 1
    }
    return 0
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("doc: " + IOError.message(e))
      return 1
    }
  }

  val md = Doc.generate(source)
  match explicitOut {
    case None -> {
      Console.print(md)
      return 0
    }
    case Some(outPath) -> {
      val outDir = Path.dirname(outPath)
      match File.createDir(outDir) {
        case Ok(_) -> ()
        case Err(e) -> printErr("doc: warning: " + IOError.message(e))
      }
      match File.writeText(outPath, md) {
        case Ok(_) -> {
          Console.println("wrote " + outPath)
          return 0
        }
        case Err(e) -> {
          printErr("doc: " + IOError.message(e))
          return 1
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Public-api-diff command
// ─────────────────────────────────────────────────────────────────────────────
func cmdPublicApiDiff(argv: in slice[String]): Int {
  // Collect positional arguments (the two DLL paths).
  val positional: List[String] = newList()
  var i = 1
  while i < argv.length {
    positional.add(argv[i])
    i += 1
  }

  if positional.count != 2 {
    printErr("public-api-diff: expected `lyric public-api-diff <old.dll> <new.dll>`")
    return 1
  }

  val oldDll = positional[0]
  val newDll = positional[1]

  if not File.fileExists(oldDll) {
    printErr("public-api-diff: '" + oldDll + "' not found")
    return 1
  }
  if not File.fileExists(newDll) {
    printErr("public-api-diff: '" + newDll + "' not found")
    return 1
  }

  val oldJson = match Meta.readFromFile(oldDll) {
    case Some(j) -> j
    case None -> {
      printErr("public-api-diff: '" + oldDll + "' has no Lyric.Contract resource")
      return 1
    }
  }
  val newJson = match Meta.readFromFile(newDll) {
    case Some(j) -> j
    case None -> {
      printErr("public-api-diff: '" + newDll + "' has no Lyric.Contract resource")
      return 1
    }
  }

  val entries = Meta.diffContracts(oldJson, newJson)
  if entries.count == 0 {
    Console.println("No public-API changes between the two assemblies.")
    return 0
  }

  Console.println("Public-API diff: " + oldDll + " -> " + newDll)
  for e in entries.toArray() {
    Console.println(e)
  }

  if Meta.hasBreakingChanges(entries) {
    Console.println("")
    Console.println("SemVer: BREAKING — bump the major version.")
    return 2
  }

  Console.println("")
  Console.println("SemVer: backwards-compatible — bump the minor version.")
  0
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Restore command
// ─────────────────────────────────────────────────────────────────────────────
// Emit the <PackageReference> elements for a manifest's registry Lyric deps +
// all [nuget] entries.  Used in the generated restore csproj.
func buildRestoreCsproj(manifest: in Manifest, target: in String): String {
  var refs = ""
  var di = 0
  while di < manifest.deps.count {
    val d = manifest.deps[di]
    match d.source {
      case Registry(version) -> {
        refs = refs + "    <PackageReference Include=\"" + Pack.xmlEscape(d.name) + "\" Version=\"" + Pack.xmlEscape(version) +
          "\" />\n"
      }
      case _ -> ()
    }
    di = di + 1
  }
  match manifest.nuget {
    case None -> ()
    case Some(n) -> {
      var ni = 0
      while ni < n.entries.count {
        val e = n.entries[ni]
        refs = refs + "    <PackageReference Include=\"" + Pack.xmlEscape(e.name) + "\" Version=\"" +
          Pack.xmlEscape(e.version) +
          "\" />\n"
        ni = ni + 1
      }
    }
  }
  var xml = "<Project Sdk=\"Microsoft.NET.Sdk\">\n"
  xml = xml + "  <PropertyGroup>\n"
  xml = xml + "    <TargetFramework>" + Pack.xmlEscape(target) + "</TargetFramework>\n"
  xml = xml + "    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>\n"
  xml = xml + "    <IncludeBuildOutput>false</IncludeBuildOutput>\n"
  xml = xml + "  </PropertyGroup>\n"
  xml = xml + "  <ItemGroup>\n"
  xml = xml + refs
  xml = xml + "  </ItemGroup>\n"
  xml + "</Project>\n"
}

// ─────────────────────────────────────────────────────────────────────────────
// §10a. Lock-file content hashing (lyric-lang #738)
// ─────────────────────────────────────────────────────────────────────────────
/// SHA-512 of the resolved dependency's `lyric.toml`.  Used as the lockable
/// content identity for `Path`, `Workspace`, and `Git` deps — the manifest
/// is the canonical content-snapshot for source-form dependencies.
///
/// Returns `None` when the file is missing or unreadable; callers treat that
/// as "graceful skip" in normal restore and as a hard failure in `--locked`.
func lockSha512OfLocalManifest(localDir: in String): Option[String] {
  if localDir.length == 0 {
    return None
  }
  val manifestPath = Path.join(localDir, "lyric.toml")
  match Hash.sha512OfFile(manifestPath) {
    case Ok(hex) -> Some(value = hex)
    case Err(_) -> None
  }
}

/// SHA-512 of the resolved NuGet `.nupkg` for a registry dep.  Layout is
/// `~/.nuget/packages/<name-lower>/<version>/<name-lower>.<version>.nupkg`
/// — populated by `dotnet restore` before this is called.
///
/// Returns `None` when the file is missing (e.g. on a host where the
/// NuGet cache lives elsewhere, or when `dotnet restore` was skipped).
func lockSha512OfNupkg(name: in String, version: in String): Option[String] {
  if name.length == 0 or version.length == 0 {
    return None
  }
  val lower = name.toLower()
  // NUGET_PACKAGES overrides the cache root (CI uses this); empty falls through so `--locked` isn't soft-bypassed.
  val nugetPkgVar: Option[String] = match Environment.getVar("NUGET_PACKAGES") {
    case Ok(p) -> if p.length > 0 { Some(value = p) } else { None }
    case Err(_) -> None
  }
  val cacheRoot = match nugetPkgVar {
    case Some(p) -> p
    case None -> {
      val home = match Environment.getVar("HOME") {
        case Ok(h) -> h
        case Err(_) -> match Environment.getVar("USERPROFILE") { case Ok(h) -> h; case Err(_) -> return None }
      }
      Path.join(home, ".nuget/packages")
    }
  }
  val cacheDir = Path.join(cacheRoot, lower)
  val versionDir = Path.join(cacheDir, version)
  val nupkgPath = Path.join(versionDir, lower + "." + version + ".nupkg")
  match Hash.sha512OfFile(nupkgPath) {
    case Ok(hex) -> Some(value = hex)
    case Err(_) -> None
  }
}

// `lyric init [<dir>] [--name <Name>] [--lib] [--force]` — scaffold a new
// application (or `--lib` library) package in <dir> (default the current
// directory): a lyric.toml, src/main.l (or src/lib.l), and a .gitignore (#1972).
func cmdInit(argv: in slice[String]): Int {
  var dir = "."
  var haveDir = false
  var nameOverride: Option[String] = None
  var isLib = false
  var force = false

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--name" {
      if i + 1 < argv.length {
        nameOverride = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("init: --name requires an argument")
        return 1
      }
    } else if arg == "--lib" {
      isLib = true
      i += 1
    } else if arg == "--force" {
      force = true
      i += 1
    } else {
      if not haveDir {
        dir = arg
        haveDir = true
        i += 1
      } else {
        printErr("init: unexpected extra argument '" + arg + "'")
        return 1
      }
    }
  }

  Init.runInit(InitOptions(dir = dir, nameOverride = nameOverride, isLib = isLib, force = force))
}

// Whether a TOML line defines the bare key `key` (its left-of-`=` token,
// trimmed, equals `key`).  Comment lines and table headers never match.
func lineDefinesKey(line: in String, key: in String): Bool {
  val t = Str.trim(line)
  if Str.startsWith(t, "#") {
    return false
  }
  if Str.startsWith(t, "[") {
    return false
  }
  match Str.indexOf(t, "=") {
    case None -> false
    case Some(eq) -> Str.trim(Str.substring(t, 0, eq)) == key
  }
}

// Insert or update `key = rhs` inside the `[table]` section of a TOML document,
// preserving the rest of the file.  If the key already exists in that table its
// line is replaced (idempotent re-add); if the table exists the entry is
// appended to it; if the table is absent a new section is appended at EOF.
func upsertTomlEntry(text: in String, table: in String, key: in String, rhs: in String): String {
  val newLine = key + " = " + rhs
  val header = "[" + table + "]"
  val lines = Str.split(text, "\n")
  val n = lines.length

  var secIdx = -1
  var idx = 0
  while idx < n {
    // Accept a trailing comment after the section header (e.g.
    // `[dependencies] # managed by lyric`).  Strip everything after
    // the first `#` before comparing, as TOML allows this form.
    val rawLine = Str.trim(lines[idx])
    val strippedLine = match Str.indexOf(rawLine, "#") {
      case Some(ci) -> Str.trim(Str.substring(rawLine, 0, ci))
      case None -> rawLine
    }
    if strippedLine == header {
      secIdx = idx
      idx = n
    } else {
      idx += 1
    }
  }

  val outLines: List[String] = newList()
  if secIdx < 0 {
    // Table absent — append a fresh section at EOF.
    var p = 0
    while p < n {
      outLines.add(lines[p])
      p += 1
    }
    if n > 0 and Str.length(Str.trim(lines[n - 1])) > 0 {
      outLines.add("")
    }
    outLines.add(header)
    outLines.add(newLine)
    return Str.joinList("\n", outLines)
  }

  // Locate an existing key line and the section's end (next header or EOF).
  var keyIdx = -1
  var secEnd = n
  var q = secIdx + 1
  while q < n {
    val t = Str.trim(lines[q])
    if Str.startsWith(t, "[") {
      secEnd = q
      q = n
    } else {
      if keyIdx < 0 and lineDefinesKey(lines[q], key) {
        keyIdx = q
      }
      q += 1
    }
  }

  if keyIdx >= 0 {
    var r = 0
    while r < n {
      if r == keyIdx {
        outLines.add(newLine)
      } else {
        outLines.add(lines[r])
      }
      r += 1
    }
    return Str.joinList("\n", outLines)
  }

  // No existing key: insert after the last non-blank line of the section.
  var insertAt = secIdx + 1
  var s = secIdx + 1
  while s < secEnd {
    if Str.length(Str.trim(lines[s])) > 0 {
      insertAt = s + 1
    }
    s += 1
  }
  var w = 0
  while w < n {
    if w == insertAt {
      outLines.add(newLine)
    }
    outLines.add(lines[w])
    w += 1
  }
  if insertAt >= n {
    outLines.add(newLine)
  }
  Str.joinList("\n", outLines)
}

// `lyric add <name>[@<version>] [--path <p>] [--git <url> [--tag|--rev|--branch <ref>]]
//   [--nuget] [--manifest <m>] [--no-restore]` — add or update a dependency in the
// discovered manifest's [dependencies] (or [nuget]) table, then restore (#1973).
func cmdAdd(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  var pathArg: Option[String] = None
  var gitArg: Option[String] = None
  var gitRefKind: String = ""    // "tag" | "rev" | "branch"
  var gitRef: String = ""
  var isNuget: Bool = false
  var noRestore: Bool = false
  var spec: Option[String] = None

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("add: --manifest requires an argument")
        return 1
      }
    } else if arg == "--path" {
      if i + 1 < argv.length {
        pathArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("add: --path requires an argument")
        return 1
      }
    } else if arg == "--git" {
      if i + 1 < argv.length {
        gitArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("add: --git requires an argument")
        return 1
      }
    } else if arg == "--tag" {
      if i + 1 < argv.length {
        gitRefKind = "tag"
        gitRef = argv[i + 1]
        i += 2
      } else {
        printErr("add: --tag requires an argument")
        return 1
      }
    } else if arg == "--rev" {
      if i + 1 < argv.length {
        gitRefKind = "rev"
        gitRef = argv[i + 1]
        i += 2
      } else {
        printErr("add: --rev requires an argument")
        return 1
      }
    } else if arg == "--branch" {
      if i + 1 < argv.length {
        gitRefKind = "branch"
        gitRef = argv[i + 1]
        i += 2
      } else {
        printErr("add: --branch requires an argument")
        return 1
      }
    } else if arg == "--nuget" {
      isNuget = true
      i += 1
    } else if arg == "--no-restore" {
      noRestore = true
      i += 1
    } else {
      match spec {
        case None -> {
          spec = Some(value = arg)
          i += 1
        }
        case Some(_) -> {
          printErr("add: unexpected extra argument '" + arg + "'")
          return 1
        }
      }
    }
  }

  val rawSpec = match spec {
    case Some(s) -> s
    case None -> {
      printErr("add: missing <name>[@version]")
      printUsage()
      return 1
    }
  }

  // Split `name@version`.
  var name = rawSpec
  var version = ""
  match Str.indexOf(rawSpec, "@") {
    case Some(at) -> {
      name = Str.substring(rawSpec, 0, at)
      version = Str.substring(rawSpec, at + 1, Str.length(rawSpec) - at - 1)
    }
    case None -> ()
  }
  if Str.length(name) == 0 {
    printErr("add: empty dependency name")
    return 1
  }

  // Validate mutually-exclusive source selectors.
  val hasPath = match pathArg { case Some(_) -> true; case None -> false }
  val hasGit = match gitArg { case Some(_) -> true; case None -> false }
  if hasPath and hasGit {
    printErr("add: --path and --git are mutually exclusive")
    return 1
  }
  if isNuget and (hasPath or hasGit) {
    printErr("add: --nuget cannot be combined with --path/--git")
    return 1
  }
  if gitRefKind != "" and not hasGit {
    printErr("add: --tag/--rev/--branch require --git")
    return 1
  }
  if Str.length(version) > 0 and (hasPath or hasGit) {
    printErr("add: @version cannot be combined with --path/--git")
    return 1
  }

  // Reject double-quote and backslash characters in path/URL values: they are
  // embedded directly in a TOML basic-string RHS and would produce malformed
  // TOML.  On Windows, use forward slashes in --path values (they work on
  // .NET and avoid the backslash-as-escape-sequence ambiguity in TOML strings).
  match pathArg {
    case Some(p) -> {
      if Str.contains(p, "\"") {
        printErr("add: --path value must not contain double-quote characters")
        return 1
      }
      if Str.contains(p, "\\") {
        printErr(
          "add: --path value contains backslashes; use forward slashes instead (they work on all platforms in TOML strings)"
        )
        return 1
      }
    }
    case None -> ()
  }
  match gitArg {
    case Some(url) -> {
      if Str.contains(url, "\"") {
        printErr("add: --git URL must not contain double-quote characters")
        return 1
      }
    }
    case None -> ()
  }
  // The git ref (--tag/--rev/--branch) is embedded in the TOML RHS too, so it
  // gets the same double-quote guard against malformed/injected TOML.
  if gitRefKind != "" {
    if Str.contains(gitRef, "\"") {
      printErr("add: --" + gitRefKind + " value must not contain double-quote characters")
      return 1
    }
  }

  // Render the TOML right-hand side for the chosen source form.
  val rhs = match pathArg {
    case Some(p) -> "{ path = \"" + p + "\" }"
    case None -> match gitArg { case Some(url) -> if gitRefKind != "" { "{ git = \"" + url + "\", " + gitRefKind + " = \"" + gitRef + "\" }" } else { "{ git = \"" + url + "\" }" }; case None -> "\"" + (if Str.length(version) > 0 { version } else { "*" }) + "\"" }
  }

  val table = if isNuget { "nuget" } else { "dependencies" }

  val mfPath = match discoverManifest(manifestArg) {
    case Some(p) -> p
    case None -> {
      printErr("add: no lyric.toml found in this directory or any parent (use --manifest)")
      return 1
    }
  }
  val mfText = match File.readText(mfPath) {
    case Ok(t) -> t
    case Err(e) -> {
      printErr("add: " + IOError.message(e))
      return 1
    }
  }

  var updated = upsertTomlEntry(mfText, table, name, rhs)
  // Keep the file POSIX-clean: end with exactly one trailing newline.
  if not Str.endsWith(updated, "\n") {
    updated = updated + "\n"
  }

  // Guard: the edited manifest must still parse before we commit it to disk.
  match Mf.parseManifest(updated, mfPath) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("add: refusing to write — resulting manifest is invalid: " + ManifestError.message(e))
      return 1
    }
  }
  match File.writeText(mfPath, updated) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("add: could not write " + mfPath + ": " + IOError.message(e))
      return 1
    }
  }
  Console.println("add: " + name + " = " + rhs + " -> [" + table + "] in " + mfPath)

  if noRestore {
    return 0
  }
  runRestore(mfPath, false)
}

func cmdRestore(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  var lockedMode = false

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("restore: --manifest requires an argument")
        return 1
      }
    } else if arg == "--locked" {
      lockedMode = true
      i += 1
    } else {
      printErr("restore: unrecognised flag '" + arg + "'")
      i += 1
    }
  }

  val mfPath = match discoverManifest(manifestArg) { case Some(p) -> p; case None -> "lyric.toml" }

  return runRestore(mfPath, lockedMode)
}

// Resolve and lock every dependency declared in the manifest at `mfPath`,
// writing `lyric.lock` (or verifying it under `lockedMode`).  Extracted from
// cmdRestore so `lyric build` can auto-restore when the lock is missing or
// stale.
func runRestore(mfPath: in String, lockedMode: in Bool): Int {
  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("restore: " + IOError.message(e))
      return 1
    }
  }

  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("restore: " + ManifestError.message(e))
      return 1
    }
  }

  val mfDir = Path.dirname(mfPath)
  val pkgName = manifest.packageSection.name

  // Find workspace context (if any) for resolving workspace/path deps.
  val wsCtx: Option[WorkspaceContext] = Ws.findWorkspaceRoot(mfDir)

  // Read existing lock file (if present).
  val lockPath = match wsCtx {
    case Some(ctx) -> Path.join(ctx.rootDir, "lyric.lock")
    case None -> Path.join(mfDir, "lyric.lock")
  }
  var lockFileExists = false
  var lockParseError = false
  val existingLf = match File.readText(lockPath) {
    case Err(_) -> LF.emptyLockFile()
    case Ok(locked) -> {
      lockFileExists = true
      match LF.parseLockFile(locked) {
        case Err(e) -> {
          printErr("restore: lock file parse error: " + e)
          lockParseError = true
          LF.emptyLockFile()
        }
        case Ok(clf) -> clf
      }
    }
  }
  var lf = existingLf

  var exitCode = 0
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    di += 1

    match dep.source {
      case Registry(version) -> {
        // NuGet registry dep — handled by `dotnet restore` below; record in lock.
        val nugetBase = "nuget:https://api.nuget.org/v3/index.json"
        val src = match dep.registry {
          case Some(url) -> "nuget:" + url
          case None -> match manifest.registry { case Some(rc) -> match rc.dotnet { case Some(url) -> "nuget:" + url; case None -> nugetBase }; case None -> nugetBase }
        }
        lf = LF.addOrUpdatePackage(
          lf,
          LF.LockedPackage(
            name = dep.name,
            version = version,
            source = src,
            sha512 = None,
            // populated after `dotnet restore` below
            path = None
          )
        )
      }
      case Workspace(versionConstraint) -> {
        // Workspace dep — resolve to local path via workspace index.
        val resolvedDir = match wsCtx {
          case None -> {
            printErr("restore: '" + dep.name + "' declared workspace = true but no workspace root found")
            exitCode = 1
            ""
          }
          case Some(ctx) -> match Ws.resolveDep(dep.name, ctx) { case None -> { printErr("restore: '" + dep.name + "' declared workspace = true but not found in workspace"); exitCode = 1; "" }; case Some(dir) -> dir }
        }
        if resolvedDir != "" {
          // Optional version constraint check.
          match versionConstraint {
            case None -> ()
            case Some(constraint) -> {
              val memberToml = Path.join(resolvedDir, "lyric.toml")
              match File.readText(memberToml) {
                case Err(_) -> ()
                case Ok(memberText) -> match Mf.parseManifest(memberText, memberToml) { case Err(_) -> (); case Ok(memberMf) -> { if memberMf.packageSection.version != constraint { printErr("restore: workspace member '" + dep.name + "' version " + memberMf.packageSection.version + " does not satisfy constraint " + constraint); exitCode = 1 } } }
              }
            }
          }
          if exitCode == 0 {
            lf = LF.addOrUpdatePackage(
              lf,
              LF.LockedPackage(
                name = dep.name,
                version = "",
                source = "workspace",
                sha512 = lockSha512OfLocalManifest(resolvedDir),
                path = Some(value = resolvedDir)
              )
            )
            Console.println("restore: " + dep.name + " -> " + resolvedDir + " (workspace)")
          }
        }
      }
      case Path(relDir) -> {
        val absDir = if Path.isAbsolute(relDir) { relDir } else { Path.join(mfDir, relDir) }
        lf = LF.addOrUpdatePackage(
          lf,
          LF.LockedPackage(
            name = dep.name,
            version = "",
            source = "path:" + absDir,
            sha512 = lockSha512OfLocalManifest(absDir),
            path = Some(value = absDir)
          )
        )
        Console.println("restore: " + dep.name + " -> " + absDir + " (path)")
      }
      case Git(url, refKind, refValue, subdir) -> {
        Console.println("restore: fetching " + dep.name + " from git " + url + "...")
        match GitDep.resolve(url, refKind, refValue, subdir) {
          case Err(e) -> {
            printErr("restore: git dep '" + dep.name + "': " + e)
            exitCode = 1
          }
          case Ok(result) -> {
            val srcTag = "git:" + url + "#" + result.resolvedRev
            lf = LF.addOrUpdatePackage(
              lf,
              LF.LockedPackage(
                name = dep.name,
                version = result.resolvedRev,
                source = srcTag,
                sha512 = lockSha512OfLocalManifest(result.localDir),
                path = Some(value = result.localDir)
              )
            )
            Console.println("restore: " + dep.name + " -> " + result.localDir + " (" + result.resolvedRev + ")")
          }
        }
      }
    }
  }

  if exitCode != 0 {
    return exitCode
  }

  // Run `dotnet restore` for registry and [nuget] deps.
  val nugetCount = match manifest.nuget { case Some(n) -> n.entries.count; case None -> 0 }
  var registryCount = 0
  var ri = 0
  while ri < manifest.deps.count {
    match manifest.deps[ri].source {
      case Registry(_) -> {
        registryCount += 1
      }
      case _ -> ()
    }
    ri += 1
  }

  if nugetCount > 0 or registryCount > 0 {
    val target = match manifest.nuget {
      case Some(n) -> match n.target { case Some(t) -> t; case None -> "net10.0" }
      case None -> "net10.0"
    }
    val csproj = buildRestoreCsproj(manifest, target)
    val tmpCsproj = Path.join(mfDir, pkgName + "-restore.csproj")
    match File.writeText(tmpCsproj, csproj) {
      case Err(e) -> {
        printErr("restore: cannot write temp csproj: " + IOError.message(e))
        return 1
      }
      case Ok(_) -> ()
    }
    val args: List[String] = newList()
    args.add("restore")
    args.add(tmpCsproj)
    val dotnetExit = match Process.run("dotnet", args) {
      case Ok(code) -> code
      case Err(e) -> {
        printErr("restore: dotnet restore failed: " + IOError.message(e))
        return 1
      }
    }
    if dotnetExit != 0 {
      return dotnetExit
    }
  }

  // Second pass: now that `dotnet restore` has populated the NuGet cache,
  // compute SHA-512 of each registry dep's `.nupkg` and write it back into
  // the lock entry (#738 supply-chain integrity).  Path / Workspace / Git
  // deps already had their digests written in the resolution loop above.
  val upgraded: List[LF.LockedPackage] = newList()
  var ui = 0
  while ui < lf.packages.count {
    val pkgEntry = lf.packages[ui]
    val nupkgSha: Option[String] = if Str.startsWith(pkgEntry.source, "nuget:") {
      match pkgEntry.sha512 {
        case Some(_) -> pkgEntry.sha512    // unlikely — kept defensively
        case None -> lockSha512OfNupkg(pkgEntry.name, pkgEntry.version)
      }
    } else {
      pkgEntry.sha512
    }
    upgraded.add(
      LF.LockedPackage(
        name = pkgEntry.name,
        version = pkgEntry.version,
        source = pkgEntry.source,
        sha512 = nupkgSha,
        path = pkgEntry.path
      )
    )
    ui = ui + 1
  }
  lf = LF.LockFile(formatVersion = lf.formatVersion, packages = upgraded)

  // Write the lock file or verify it (--locked mode).
  if lockedMode {
    // --locked: fail if no lock file exists on disk.
    if not lockFileExists {
      printErr("restore: --locked: no lock file found; run 'lyric restore' first to generate it")
      return 1
    }
    // A parse error was already reported above; fail without a misleading "is empty" message.
    if lockParseError {
      return 1
    }
    // Distinguish an empty lock file from a missing one.
    if existingLf.packages.count == 0 and lf.packages.count > 0 {
      printErr("restore: --locked: lock file exists but is empty; run 'lyric restore' to regenerate it")
      return 1
    }
    var lockMismatch = false
    // Forward check: every resolved package must be in the lock file.
    var ci = 0
    while ci < lf.packages.count {
      val resolved = lf.packages[ci]
      match LF.findPackage(existingLf, resolved.name) {
        case None -> {
          printErr(
            "restore: --locked: '" + resolved.name +
              "' is not recorded in the lock file (lyric.lock is stale — run 'lyric restore')"
          )
          lockMismatch = true
        }
        case Some(locked) -> {
          if locked.source != resolved.source {
            printErr(
              "restore: --locked: '" + resolved.name + "' source changed: locked='" + locked.source + "' resolved='" +
                resolved.source +
                "'"
            )
            lockMismatch = true
          } else if locked.version != resolved.version {
            printErr(
              "restore: --locked: '" + resolved.name + "' version changed: locked='" + locked.version + "' resolved='" +
                resolved.version +
                "'"
            )
            lockMismatch = true
          } else {
            // Content-integrity check (#738).  A `None` on the lock side
            // means the lock file pre-dates the SHA-512 enforcement; we
            // refuse to proceed and instruct the user to regenerate.  A
            // mismatch between the two digests means the resolved
            // artifact's content changed since the lock was written — the
            // exact registry-poisoning attack the lock file is supposed
            // to detect.
            match locked.sha512 {
              case None -> match resolved.sha512 {
                case None -> printErr("restore: --locked: warning: '" + resolved.name + "' has no SHA-512 on either side; integrity check skipped (regenerate lyric.lock with 'lyric restore' to populate digests)")
                // Both None — soft-pass with a warning so the operator knows the integrity check was skipped (typical for pre-#738 lock files).
                case Some(_) -> {
                  printErr(
                    "restore: --locked: '" + resolved.name +
                      "' has no SHA-512 in the lock file; lyric.lock pre-dates content-integrity enforcement — run 'lyric restore' to regenerate"
                  )
                  lockMismatch = true
                }
              }
              case Some(lockedHash) -> match resolved.sha512 { case None -> printErr("restore: --locked: warning: '" + resolved.name + "' could not be re-hashed; integrity check skipped (locked='" + lockedHash + "')"); case Some(resolvedHash) -> if lockedHash != resolvedHash { printErr("restore: --locked: '" + resolved.name + "' content changed: locked SHA-512 != resolved SHA-512"); printErr("  locked   : " + lockedHash); printErr("  resolved : " + resolvedHash); printErr("  (a registry-poisoning attack would surface here; if the package was legitimately updated, run 'lyric restore' to regenerate the lock)"); lockMismatch = true } }
            }
          }
        }
      }
      ci += 1
    }
    // Reverse check: every locked package must still be in lyric.toml.
    var ri = 0
    while ri < existingLf.packages.count {
      val locked = existingLf.packages[ri]
      match LF.findPackage(lf, locked.name) {
        case None -> {
          printErr(
            "restore: --locked: '" + locked.name +
              "' is in the lock file but not in lyric.toml (lyric.lock is stale — run 'lyric restore')"
          )
          lockMismatch = true
        }
        case Some(_) -> {
        }
      }
      ri += 1
    }
    if lockMismatch {
      return 1
    }
    Console.println("restore: --locked: lock file verified")
  } else {
    val lockText = LF.serializeLockFile(lf)
    match File.writeText(lockPath, lockText) {
      case Err(e) -> printErr("restore: warning: could not write lock file: " + IOError.message(e))
      case Ok(_) -> ()
    }
  }

  Console.println("restore: done")
  0
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Publish command
// ─────────────────────────────────────────────────────────────────────────────
func cmdPublish(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  var dllOverride: Option[String] = None
  var outputDir: Option[String] = None
  var registryUrl: Option[String] = None
  var apiKey: Option[String] = None

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: --manifest requires an argument")
        return 1
      }
    } else if arg == "--dll" {
      if i + 1 < argv.length {
        dllOverride = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: --dll requires an argument")
        return 1
      }
    } else if arg == "-o" {
      if i + 1 < argv.length {
        outputDir = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: -o requires an argument")
        return 1
      }
    } else if arg == "--registry" {
      if i + 1 < argv.length {
        registryUrl = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: --registry requires an argument")
        return 1
      }
    } else if arg == "--api-key" {
      if i + 1 < argv.length {
        apiKey = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: --api-key requires an argument")
        return 1
      }
    } else {
      printErr("publish: unrecognised flag '" + arg + "'")
      i += 1
    }
  }

  val mfPath = match manifestArg { case Some(p) -> p; case None -> "lyric.toml" }

  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("publish: " + IOError.message(e))
      return 1
    }
  }

  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("publish: " + ManifestError.message(e))
      return 1
    }
  }

  // Warn when [workspace.overrides] are present — these should not ship.
  match manifest.workspace {
    case Some(ws) -> if ws.overrides.count > 0 { printErr("publish: warning: [workspace.overrides] is non-empty — override entries should not be committed") }
    case None -> ()
  }

  // Reject branch-form git deps — mutable refs cannot appear in a published manifest.
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Git(_, refKind, refValue, _) -> if refKind == "branch" { printErr("publish: dep '" + dep.name + "' uses git branch '" + refValue + "' — mutable refs are not allowed in published packages"); return 1 }
      case _ -> ()
    }
    di += 1
  }

  val pkg: PackageSection = manifest.packageSection
  val mfDir = Path.dirname(mfPath)
  val dllPath = match dllOverride {
    case Some(d) -> d
    case None -> Path.join(Path.join(mfDir, "bin"), pkg.name + ".dll")
  }

  if not File.fileExists(dllPath) {
    printErr("publish: DLL not found: " + dllPath + " — run `lyric build` first")
    return 1
  }

  val outDir = match outputDir { case Some(d) -> d; case None -> Path.join(Path.join(mfDir, "bin"), "nupkg") }
  match File.createDir(outDir) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("publish: cannot create output dir: " + IOError.message(e))
      return 1
    }
  }

  // Build the .nuspec for dotnet pack.  All Lyric deps must be published at
  // their declared Registry version — workspace deps are substituted.
  var nuspecDeps = ""
  var si = 0
  while si < manifest.deps.count {
    val dep = manifest.deps[si]
    val version = match dep.source {
      case Registry(v) -> v
      case Workspace(_) -> {
        // Substitute workspace dep with registry ref at member's declared version.
        val publishWsCtx = match Ws.findWorkspaceRoot(mfDir) {
          case Some(ctx) -> ctx
          case None -> {
            printErr("publish: workspace dep '" + dep.name + "' cannot be resolved — no workspace root")
            return 1
          }
        }
        val memberDir = match Ws.resolveDep(dep.name, publishWsCtx) {
          case Some(dir) -> dir
          case None -> {
            printErr("publish: workspace dep '" + dep.name + "' not found in workspace")
            return 1
          }
        }
        val memberToml = Path.join(memberDir, "lyric.toml")
        val memberText = match File.readText(memberToml) {
          case Ok(t) -> t
          case Err(e) -> {
            printErr("publish: cannot read workspace member manifest: " + IOError.message(e))
            return 1
          }
        }
        match Mf.parseManifest(memberText, memberToml) {
          case Err(e) -> {
            printErr("publish: cannot parse workspace member manifest: " + ManifestError.message(e))
            return 1
          }
          case Ok(mf) -> mf.packageSection.version
        }
      }
      case Path(_) -> {
        printErr("publish: dep '" + dep.name + "' uses path source — not allowed in published packages")
        return 1
      }
      case Git(_, _, refValue, _) -> refValue  // tag name / SHA / branch (branch rejected above)
    }
    nuspecDeps = nuspecDeps + "    <PackageReference Include=\"" + dep.name + "\" Version=\"" + version + "\" />\n"
    si += 1
  }

  val absDllPath = if Path.isAbsolute(dllPath) { dllPath } else { Path.join(mfDir, dllPath) }
  val dllBase = Path.basename(absDllPath)
  var csproj = "<Project Sdk=\"Microsoft.NET.Sdk\">\n"
  csproj = csproj + "  <PropertyGroup>\n"
  csproj = csproj + "    <TargetFramework>net10.0</TargetFramework>\n"
  csproj = csproj + "    <IncludeBuildOutput>false</IncludeBuildOutput>\n"
  csproj = csproj + "    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>\n"
  csproj = csproj + "    <NoWarn>$(NoWarn);NU5128</NoWarn>\n"
  csproj = csproj + "    <PackageId>" + Pack.xmlEscape(pkg.name) + "</PackageId>\n"
  csproj = csproj + "    <Version>" + Pack.xmlEscape(pkg.version) + "</Version>\n"
  if not Str.isEmpty(pkg.description) {
    csproj = csproj + "    <Description>" + Pack.xmlEscape(pkg.description) + "</Description>\n"
  }
  if not Str.isEmpty(pkg.license) {
    csproj = csproj + "    <PackageLicenseExpression>" + Pack.xmlEscape(pkg.license) + "</PackageLicenseExpression>\n"
  }
  match pkg.repository {
    case Some(r) -> {
      csproj = csproj + "    <RepositoryUrl>" + Pack.xmlEscape(r) + "</RepositoryUrl>\n"
    }
    case None -> ()
  }
  csproj = csproj + "    <PackageTags>lyric-package</PackageTags>\n"
  csproj = csproj + "  </PropertyGroup>\n"
  csproj = csproj + "  <ItemGroup>\n"
  csproj = csproj + "    <None Include=\"" + Pack.xmlEscape(absDllPath) + "\" Pack=\"true\" PackagePath=\"lib/net10.0/" +
    Pack.xmlEscape(dllBase) +
    "\" />\n"
  csproj = csproj + "  </ItemGroup>\n"
  if not Str.isEmpty(nuspecDeps) {
    csproj = csproj + "  <ItemGroup>\n"
    csproj = csproj + nuspecDeps
    csproj = csproj + "  </ItemGroup>\n"
  }
  csproj = csproj + "</Project>\n"

  val tmpCsproj = Path.join(mfDir, pkg.name + "-publish.csproj")
  match File.writeText(tmpCsproj, csproj) {
    case Err(e) -> {
      printErr("publish: cannot write temp csproj: " + IOError.message(e))
      return 1
    }
    case Ok(_) -> ()
  }

  // Run `dotnet pack`.
  val packArgs: List[String] = newList()
  packArgs.add("pack")
  packArgs.add(tmpCsproj)
  packArgs.add("-o")
  packArgs.add(outDir)
  packArgs.add("--no-build")
  val packExit = match Process.run("dotnet", packArgs) {
    case Ok(code) -> code
    case Err(e) -> {
      printErr("publish: dotnet pack failed: " + IOError.message(e))
      return 1
    }
  }
  if packExit != 0 {
    return packExit
  }

  val nupkgPath = Path.join(outDir, pkg.name + "." + pkg.version + ".nupkg")
  Console.println("publish: packed " + nupkgPath)

  // Determine push registry and API key.
  val pushRegistry = match registryUrl {
    case Some(url) -> url
    case None -> match manifest.registry { case Some(rc) -> match rc.dotnet { case Some(url) -> url; case None -> "https://api.nuget.org/v3/index.json" }; case None -> "https://api.nuget.org/v3/index.json" }
  }

  val pushKey = match apiKey {
    case Some(k) -> k
    case None -> match Environment.getVar("LYRIC_NUGET_API_KEY") { case Ok(k) -> k; case Err(_) -> "" }
  }

  if Str.isEmpty(pushKey) {
    printErr("publish: no API key — set --api-key or LYRIC_NUGET_API_KEY")
    return 1
  }

  // Run `dotnet nuget push`.
  val pushArgs: List[String] = newList()
  pushArgs.add("nuget")
  pushArgs.add("push")
  pushArgs.add(nupkgPath)
  pushArgs.add("--source")
  pushArgs.add(pushRegistry)
  pushArgs.add("--api-key")
  pushArgs.add(pushKey)
  val pushExit = match Process.run("dotnet", pushArgs) {
    case Ok(code) -> code
    case Err(e) -> {
      printErr("publish: dotnet nuget push failed: " + IOError.message(e))
      return 1
    }
  }
  if pushExit != 0 {
    return pushExit
  }

  Console.println("publish: pushed " + pkg.name + " " + pkg.version + " to " + pushRegistry)
  0
}

// ─────────────────────────────────────────────────────────────────────────────
// §11a. Search command
// ─────────────────────────────────────────────────────────────────────────────
func cmdSearch(argv: in slice[String]): Int {
  val positional: List[String] = newList()
  var allMode = false

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--all" {
      allMode = true
      i += 1
    } else {
      positional.add(arg)
      i += 1
    }
  }

  val query = if allMode {
    ""
  } else if positional.count > 0 {
    positional[0]
  } else {
    printErr("search: provide a search term or use --all")
    printUsage()
    return 1
  }

  // Percent-encode the query to prevent injection through & # % characters.
  val encodedQuery = percentEncodeQuery(query)

  // Query the NuGet.org search API, filtered by the lyric-package tag.
  val searchUrl = "https://azuresearch-usnc.nuget.org/query?q=" + encodedQuery + "&packageType=lyric-package&take=20"
  val curlArgs: List[String] = newList()
  curlArgs.add("-fsSL")
  curlArgs.add(searchUrl)
  val raw = ProcessCapture.runCapture("curl", curlArgs, "")
  if Str.isEmpty(raw) {
    printErr("search: no response from NuGet search API (is curl available?)")
    return 1
  }

  // Scan the JSON for "id":"…" / "version":"…" / "description":"…" patterns.
  // We do NOT split on commas; instead we locate each key needle and extract
  // the string value character-by-character so commas inside descriptions
  // are handled correctly.
  val results: List[String] = newList()
  val idNeedle = "\"id\":\""
  val verNeedle = "\"version\":\""
  val descNeedle = "\"description\":\""
  var pos = 0
  while pos < raw.length {
    val tail = Str.substring(raw, pos, raw.length - pos)
    match Str.indexOf(tail, idNeedle) {
      case None -> {
        pos = raw.length
      }
      case Some(rel) -> {
        val idStart = pos + rel + idNeedle.length
        val (idVal, afterId) = jsonStringAt(raw, idStart)
        if idVal == "" {
          pos = pos + rel + 1
        } else {
          // Look for "version" and "description" in the remainder of this entry.
          val rest = Str.substring(raw, afterId, raw.length - afterId)
          val versionVal = match Str.indexOf(rest, verNeedle) {
            case None -> ""
            case Some(rv) -> {
              val (v, _) = jsonStringAt(raw, afterId + rv + verNeedle.length)
              v
            }
          }
          val descVal = match Str.indexOf(rest, descNeedle) {
            case None -> ""
            case Some(rd) -> {
              val (d, _) = jsonStringAt(raw, afterId + rd + descNeedle.length)
              d
            }
          }
          if versionVal != "" {
            results.add(idVal + "\t" + versionVal + "\t" + descVal)
          }
          pos = pos + rel + idNeedle.length + 1
        }
      }
    }
  }

  if results.count == 0 {
    Console.println("No packages found matching '" + query + "'.")
    return 0
  }

  for line in results.toArray() {
    Console.println(line)
  }
  0
}

// Percent-encode characters unsafe in a URL query string.
func percentEncodeQuery(q: in String): String {
  var r = ""
  var qi = 0
  while qi < q.length {
    val c = q[qi]
    if c == ' ' {
      r = r + "%20"
    } else if c == '%' {
      r = r + "%25"
    } else if c == '&' {
      r = r + "%26"
    } else if c == '+' {
      r = r + "%2B"
    } else if c == '#' {
      r = r + "%23"
    } else if c == '=' {
      r = r + "%3D"
    } else if c == '?' {
      r = r + "%3F"
    } else {
      r = r + ("" + c)
    }
    qi += 1
  }
  r
}

// Extract a JSON string value starting at `startPos` (position right after the
// opening double-quote).  Returns (value, endPos) where endPos is the position
// after the closing double-quote.  Handles `\"` escapes.
func jsonStringAt(json: in String, startPos: in Int): (String, Int) {
  if startPos >= json.length {
    return ("", startPos)
  }
  var s = ""
  var j = startPos
  var escaping = false
  while j < json.length {
    val c = json[j]
    if escaping {
      if c == 'n' {
        s = s + "\n"
      } else if c == 't' {
        s = s + "\t"
      } else if c == 'r' {
        s = s + "\r"
      } else if c == 'b' {
        s = s + "\u{0008}"
      } else if c == 'f' {
        s = s + "\u{000c}"
      } else {
        s = s + ("" + c)
      }
      escaping = false
    } else if c == '\\' {
      escaping = true
    } else if c == '"' {
      return (s, j + 1)
    } else {
      s = s + ("" + c)
    }
    j += 1
  };
  (s, j)
}

// ─────────────────────────────────────────────────────────────────────────────
// §11b. Repl command
// ─────────────────────────────────────────────────────────────────────────────
func cmdRepl(argv: in slice[String]): Int {
  Repl.runRepl(argv)
}

// ─────────────────────────────────────────────────────────────────────────────
// §11c. Test command
// ─────────────────────────────────────────────────────────────────────────────
// First `package <name>` declaration in `src` (skipping annotations/comments),
// or "" if none.  Used to wrap a single `@test_module` file as a `ProjectPackage`
// when linking compiler DLLs (#2364 Stage 5).
func firstPackageNameOf(src: in String): String {
  val lines = Str.split(src, "\n")
  var i = 0
  while i < lines.length {
    val t = Str.trim(lines[i])
    if Str.startsWith(t, "package ") {
      return Str.trim(Str.substring(t, 8, t.length - 8))
    }
    i = i + 1
  }
  ""
}

// Emit a single-file `@test_module` plainly (no compiler-DLL linking).
func emitTestPlain(rewritten: in String, stem: in String, outPath: in String, targetJvm: in Bool): EmitResult {
  val tgt = if targetJvm { Jvm } else { Dotnet }
  Emitter.emit(
    EmitRequest(source = rewritten, assemblyName = stem, outputPath = outPath, target = tgt, packageVersion = "")
  )
}

// Emit a single-file `@test_module` that imports `Lyric.*` compiler packages,
// linking the already-compiled compiler DLLs as restored deps (#2364 Stage 5).
func emitTestLinked(
  rewritten: in String, stem: in String, outPath: in String, compilerDlls: in List[String]
): EmitResult {
  val testSrcs: List[String] = newList()
  testSrcs.add(rewritten)
  // Guard against a missing `package` declaration: an empty package name would
  // produce a malformed `ProjectPackage`.  A `@test_module` always carries a
  // `package` line, so this falls back to the assembly stem only defensively
  // (#2564).
  val rawPkgName = firstPackageNameOf(rewritten)
  val testPkgName = if rawPkgName.length > 0 { rawPkgName } else { stem }
  val testPkgs: List[ProjectPackage] = newList()
  testPkgs.add(ProjectPackage(name = testPkgName, sources = testSrcs))
  val activeF: List[String] = newList()
  val declaredF: List[String] = newList()
  Emitter.emitProject(
    EmitProjectRequest(
      packages = testPkgs,
      assemblyName = stem,
      outputPath = outPath,
      target = Dotnet,
      restoredDllPaths = compilerDlls,
      activeFeatures = activeF,
      declaredFeatures = declaredF,
      packageVersion = ""
    )
  )
}

func cmdTest(argv: in slice[String]): Int {
  var filterArg: Option[String] = None
  var manifestArg: Option[String] = None
  var listMode = false
  var targetJvm = false
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--filter" {
      if i + 1 < argv.length {
        filterArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("test: --filter requires a value")
        return 1
      }
    } else if arg == "--target" {
      if i + 1 < argv.length {
        val t = argv[i + 1]
        if t == "jvm" {
          targetJvm = true
        } else if t == "dotnet" {
          targetJvm = false
        } else {
          printErr("test: --target must be 'dotnet' or 'jvm'")
          return 1
        }
        i += 2
      } else {
        printErr("test: --target requires an argument (dotnet|jvm)")
        return 1
      }
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("test: --manifest requires a path")
        return 1
      }
    } else if arg == "--list" {
      listMode = true
      i += 1
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // `lyric test --manifest <toml>` reads `[project.tests]` and runs
  // each test file bundled with the manifest's `[project.packages]`
  // (#465).  Each test contributes one synthesised executable; the
  // command's exit code is non-zero if any test fails.
  // Explicit --manifest takes precedence.
  match manifestArg {
    case Some(p) -> return cmdTestManifest(p, filterArg)
    case None -> ()
  }

  if positional.count == 0 {
    // No explicit source file and no --manifest: auto-discover project.
    match Disc.findNearestManifest(Environment.currentDirectory()) {
      case Some(p) -> return cmdTestManifest(p, filterArg)
      case None -> {
        printErr("test: missing source file and no lyric.toml found")
        return 1
      }
    }
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("test: " + IOError.message(e))
      return 1
    }
  }

  if listMode {
    match TestSynth.listEntries(source) {
      case Err(diags) -> {
        for d in diags.toArray() {
          printDiag(d)
        }
        return 1
      }
      case Ok(entries) -> {
        for e in entries.toArray() {
          match e {
            case TestEntry(title) -> Console.println("test: " + title)
            case PropertyEntry(title, reason) -> Console.println("prop: " + title + " (" + reason + ")")
            case FixtureEntry(name) -> Console.println("fixture: " + name)
          }
        }
        return 0
      }
    }
  }

  val stem = stemOf(Path.basename(sourcePath), 2)
  val outExt = if targetJvm { ".jar" } else { ".dll" }
  val outPath = Path.join(Path.join(Path.dirname(sourcePath), ".lyric-test"), stem + outExt)

  match TestSynth.synthesize(source, filterArg) {
    case NoTestModule(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) + ": not a @test_module — add @test_module annotation")
      return 1
    }
    case UserMainExists(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) + ": @test_module cannot define func main()")
      return 1
    }
    case FixtureUnsupported(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) + ": fixture types are not yet supported by `lyric test`")
      return 1
    }
    case ParseFailures(diags) -> {
      for d in diags.toArray() {
        printDiag(d)
      }
      return 1
    }
    case Synthesised(rewritten, testCnt, skipCnt) -> {
      Console.println(toString(testCnt) + " test(s), " + toString(skipCnt) + " skipped")

      match File.createDir(Path.dirname(outPath)) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }

      // #2364 Stage 5: a @test_module that imports `Lyric.*` compiler packages
      // links the already-compiled compiler DLLs as restored deps (via
      // `emitProject`) rather than recompiling them from source (the retired
      // `LYRIC_LOAD_COMPILER` path).  The closure → DLL mapping is computed by
      // `Emitter.compilerClosureDllPaths`; an empty result (no compiler imports,
      // or JVM target) keeps the plain single-file `emit`.  The emit itself is
      // delegated to small helpers so this function body stays simple (the F#
      // stage-0 segment compiler chokes on a large record-valued if-expression).
      val testLibDir = if targetJvm { "" } else { findCompiledLibDir() }
      val compilerDlls: List[String] = if targetJvm {
        newList()
      } else {
        Emitter.compilerClosureDllPaths(rewritten, testLibDir)
      }
      val result = if compilerDlls.count > 0 {
        emitTestLinked(rewritten, stem, outPath, compilerDlls)
      } else {
        emitTestPlain(rewritten, stem, outPath, targetJvm)
      }
      var hadError = false
      for d in result.diagnostics.toArray() {
        match d.severity {
          case DiagError -> {
            hadError = true
          }
          case DiagWarning -> ()
        }
        printDiag(d)
      }
      if hadError {
        return 1
      }
      match result.outputPath {
        case None -> {
          printErr("test: build failed")
          return 1
        }
        case Some(_) -> ()
      }
      // JVM: the bundled JAR is self-contained (the self-hosted JVM bridge
      // bundles the user package plus its transitive stdlib import closure),
      // so it runs directly via `java -jar` with no DLL staging or runtimeconfig.
      if targetJvm {
        val jvmArgs: List[String] = newList()
        jvmArgs.add("-jar")
        jvmArgs.add(outPath)
        val jvmRes = ProcessCapture.runCaptureWithDiagnosticsTimeout("java", jvmArgs, "", 600000)
        Console.print(jvmRes.stdout)
        if jvmRes.stderr.length > 0 {
          Console.error(jvmRes.stderr)
        }
        if jvmRes.exitCode == -1 {
          printErr("test: failed to start java")
          return 1
        }
        if jvmRes.timedOut {
          printErr("test: test binary timed out (600 s limit reached)")
          return 1
        }
        if jvmRes.stdout.length == 0 and jvmRes.exitCode == 0 {
          printErr("test: compiled test binary produced no TAP output — possible silent compile or runtime failure")
          return 1
        }
        return jvmRes.exitCode
      }
      // Co-locate the fully-compiled stdlib runtime assemblies beside the
      // test DLL so `dotnet exec` resolves the real stdlib `pub func`s
      // (Std.Testing.assertEqualInt, …).  Discovery is non-hardcoded
      // (findCompiledLibDir): the already-compiled stdlib beside the binary /
      // in the SDK `lib/` / in the dev `.bootstrap/stage1` tree is the source
      // of truth — not the per-PID `/tmp/lyric-stdlib-*` recompile byproduct.
      val testOutDir2 = Path.dirname(outPath)
      val libDir = findCompiledLibDir()
      if libDir.length > 0 {
        copyRuntimeDepsBeside(outPath, libDir)
      } else {
        // Fallback for environments without a discoverable compiled stdlib
        // (e.g. an isolated temp checkout): recover the DLLs the in-process
        // bridge just wrote to its per-PID `/tmp/lyric-stdlib-*` cache.
        val tmpRoot = Environment.getVarOrDefault("TMPDIR", "/tmp")
        match File.listDirs(tmpRoot) {
          case Err(_) -> ()
          case Ok(tmpDirs) -> {
            for d in tmpDirs.toArray() {
              val base = Path.basename(d)
              if Str.startsWith(base, "lyric-stdlib-") {
                match File.listFiles(d) {
                  case Err(_) -> ()
                  case Ok(fs) -> {
                    for f in fs.toArray() {
                      if Str.endsWith(f, ".dll") {
                        val dest = Path.join(testOutDir2, Path.basename(f))
                        if not File.fileExists(dest) {
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
            }
          }
        }
      }
      // #2364 Stage 5: co-locate the linked compiler DLLs beside the test so
      // `dotnet exec` resolves them (a flat probing path can't load a non-NuGet
      // bin layout).
      if compilerDlls.count > 0 {
        copyRestoredDepDlls(outPath, compilerDlls)
      }
      writeRuntimeConfig(outPath)

      val execArgs: List[String] = newList()
      execArgs.add("exec")
      execArgs.add(outPath)
      val dotnetRes = ProcessCapture.runCaptureWithDiagnosticsTimeout("dotnet", execArgs, "", 600000)
      Console.print(dotnetRes.stdout)
      if dotnetRes.stderr.length > 0 {
        Console.error(dotnetRes.stderr)
      }
      if dotnetRes.exitCode == -1 {
        printErr("test: failed to start dotnet")
        1
      } else if dotnetRes.timedOut {
        printErr("test: test binary timed out (600 s limit reached)")
        1
      } else if dotnetRes.stdout.length == 0 and dotnetRes.exitCode == 0 {
        printErr("test: compiled test binary produced no TAP output — possible silent compile or runtime failure")
        1
      } else {
        dotnetRes.exitCode
      }
    }
  }
}

// isCfgGatedOut and the directory-package assembly helpers moved to
// `Lyric.CfgGate` (#1123, #1124) so they're independently testable and
// the duplicate-`package`-declaration bug for multi-file directory
// packages is fixed at the assembly level.
func cmdTestManifest(mfPath: in String, filterArg: in Option[String]): Int {
  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("test: " + IOError.message(e))
      return 1
    }
  }
  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("test: " + ManifestError.message(e))
      return 1
    }
  }
  val proj: ProjectSection = match manifest.project {
    case Some(p) -> p
    case None -> {
      printErr("test: " + mfPath + " has no [project] section")
      return 1
    }
  }

  if proj.tests.count == 0 {
    printErr("test: " + mfPath + " has no [project.tests] entries")
    return 1
  }

  val mfDir = Path.dirname(mfPath)

  // Resolve active feature set from manifest defaults (no CLI flags in the test runner).
  val mfDefaults = Mf.readFeatureDefaultsFromToml(mfText, mfPath)
  val mfDeclared = Mf.readFeatureDeclaredFromToml(mfText, mfPath)
  val activeFeatures: List[String] = newList()
  var afi = 0
  while afi < mfDefaults.count {
    activeFeatures.add(mfDefaults[afi])
    afi += 1
  }

  // Build ProjectPackage entries from [project.packages], matching buildProject.
  val libPkgs: List[ProjectPackage] = newList()
  var hadFatal = false
  var pi = 0
  while pi < proj.packages.count {
    val pkgEntry = proj.packages[pi]
    val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(mfDir, pkgEntry.path) }
    val pkgSources: List[String] = newList()
    if File.fileExists(abs) {
      match File.readText(abs) {
        case Ok(t) -> {
          if CfgGate.isCfgGatedOut(t, activeFeatures) {
            // Package is gated by an inactive feature: substitute an empty stub
            // so that imports of this package from sibling packages resolve, while
            // the @cfg-gated items in those packages are properly elided.
            pkgSources.add(CfgGate.emptyPackageStub(pkgEntry.name))
          } else {
            pkgSources.add(t)
          }
        }
        case Err(e) -> {
          printErr("test: package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
        }
      }
    } else if File.dirExists(abs) {
      val allFiles = match File.listFilesRecursive(abs) {
        case Ok(fs) -> fs
        case Err(e) -> {
          printErr("test: package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
          newList()
        }
      }
      val lFiles: List[String] = newList()
      for f in allFiles.toArray() {
        if Str.endsWith(f, ".l") {
          lFiles.add(f)
        }
      }
      if lFiles.count == 0 {
        printErr("test: package '" + pkgEntry.name + "': no .l files found in " + abs)
        hadFatal = true
      } else {
        // Read every file first, then hand the (path, contents) list to
        // CfgGate so the assembly logic adds at most one empty-package
        // stub when every file is gated — preventing the duplicate-
        // `package` declaration bug from #1124 when two or more files
        // in a directory package are each gated out.
        val fileEntries: List[CfgGate.CfgGateFile] = newList()
        val sorted = sortFileList(lFiles)
        var readFailed = false
        for f in sorted {
          match File.readText(f) {
            case Ok(t) -> fileEntries.add(CfgGate.CfgGateFile(path = f, contents = t))
            case Err(e) -> {
              printErr("test: package '" + pkgEntry.name + "': " + IOError.message(e))
              hadFatal = true
              readFailed = true
            }
          }
        }
        // All-or-nothing assembly: a partial source list would confuse `@cfg`
        // detection (one missing file can flip the gated-out decision) and
        // produce a misleading downstream "unresolved import" cascade instead
        // of a clear "read failed" error.  `hadFatal` is already set; downstream
        // packages skip importing this one.
        if not readFailed {
          val assembly = CfgGate.assembleDirectoryPackageSources(fileEntries, pkgEntry.name, activeFeatures)
          var ai = 0
          while ai < assembly.sources.count {
            pkgSources.add(assembly.sources[ai])
            ai += 1
          }
        }
      }
    } else {
      printErr("test: package '" + pkgEntry.name + "': path not found: " + abs)
      hadFatal = true
    }
    if pkgSources.count > 0 {
      libPkgs.add(ProjectPackage(name = pkgEntry.name, sources = pkgSources))
    }
    pi += 1
  }

  if hadFatal {
    return 1
  }

  // Build local-path dependencies in topological order (#2887).
  // Uses an iterative DFS post-order over the full transitive local-path-dep
  // closure so a dep's own local-path dependencies are always built before the
  // dep itself — even when the manifest order is not dependency-first and even
  // when transitive deps are not listed directly in this manifest.
  //
  // Stack entries are pairs stored as alternating elements with tomlPath on top:
  //   add("open"), add(tomlPath)   → tomlPath at count-1, "open" at count-2
  //   pop tomlPath, pop state
  val dfsSeen: List[String] = newList()
  val topoOrder: List[String] = newList()
  val dfsStack: List[String] = newList()

  // Seed the DFS with direct local-path deps (push in reverse for correct pop order).
  var seedIdx = manifest.deps.count - 1
  while seedIdx >= 0 {
    val seedDep = manifest.deps[seedIdx]
    match seedDep.source {
      case Path(seedDir) -> {
        val seedDepDir = if Path.isAbsolute(seedDir) { seedDir } else { Path.join(mfDir, seedDir) }
        dfsStack.add("open")
        dfsStack.add(Path.join(seedDepDir, "lyric.toml"))
      }
      case _ -> ()
    }
    seedIdx -= 1
  }

  while dfsStack.count > 0 {
    val dfsToml = dfsStack[dfsStack.count - 1]
    dfsStack.removeAt(dfsStack.count - 1)
    val dfsState = dfsStack[dfsStack.count - 1]
    dfsStack.removeAt(dfsStack.count - 1)

    if dfsState == "close" {
      topoOrder.add(dfsToml)
      continue
    }

    // "open": skip if already visited (handles diamond deps and back edges).
    var dfsAlreadySeen = false
    var dfsSeenIdx = 0
    while dfsSeenIdx < dfsSeen.count {
      if dfsSeen[dfsSeenIdx] == dfsToml {
        dfsAlreadySeen = true
      }
      dfsSeenIdx += 1
    }
    if dfsAlreadySeen {
      continue
    }
    dfsSeen.add(dfsToml)

    // Push close marker for this node (will fire after all children are processed).
    dfsStack.add("close")
    dfsStack.add(dfsToml)

    // Parse this dep's manifest to discover its own local-path deps,
    // pushing them as children (in reverse for correct DFS pop order).
    match File.readText(dfsToml) {
      case Ok(dfsText) -> {
        match Mf.parseManifest(dfsText, dfsToml) {
          case Ok(dfsMf) -> {
            val dfsMfDir = Path.dirname(dfsToml)
            var childIdx = dfsMf.deps.count - 1
            while childIdx >= 0 {
              val childDep = dfsMf.deps[childIdx]
              match childDep.source {
                case Path(childDir) -> {
                  val childDepDir = if Path.isAbsolute(childDir) { childDir } else { Path.join(dfsMfDir, childDir) }
                  dfsStack.add("open")
                  dfsStack.add(Path.join(childDepDir, "lyric.toml"))
                }
                case _ -> ()
              }
              childIdx -= 1
            }
          }
          case Err(_) -> ()
        }
      }
      case Err(_) -> ()
    }
  }

  // Build each dep in topo order; skip those already built.
  var topoIdx = 0
  while topoIdx < topoOrder.count {
    val buildToml = topoOrder[topoIdx]
    match File.readText(buildToml) {
      case Ok(buildText) -> {
        match Mf.parseManifest(buildText, buildToml) {
          case Ok(buildMf) -> {
            val buildDllName = match buildMf.project {
              case Some(p) -> match p.outputAssembly { case Some(asm) -> asm; case None -> p.name + ".dll" }
              case None -> buildMf.packageSection.name + ".dll"
            }
            val buildDllPath = Path.join(Path.join(Path.dirname(buildToml), "bin"), buildDllName)
            if not File.fileExists(buildDllPath) {
              Console.println("test: building dep '" + buildMf.packageSection.name + "' ...")
              val buildRc = buildProject(buildToml, None, Dotnet, newList(), false, false, false)
              if buildRc != 0 {
                printErr("test: failed to build dep '" + buildMf.packageSection.name + "'")
                return 1
              }
            }
          }
          case Err(e) -> {
            printErr("test: malformed lyric.toml at '" + buildToml + "': " + ManifestError.message(e))
            return 1
          }
        }
      }
      case Err(e) -> {
        printErr("test: cannot read dep manifest at '" + buildToml + "': " + IOError.message(e))
        return 1
      }
    }
    topoIdx += 1
  }

  // Resolve local-path dependencies to DLL paths, matching buildProject.
  // Also track unique dep bin directories so the test runtimeconfig can
  // include additionalProbingPaths — this lets dotnet exec locate stdlib
  // DLLs (e.g. Lyric.Stdlib.Testing) that live in the dep's bin dir but
  // are not merged into the main dep bundle (e.g. Lyric.Stdlib.dll).
  val restoredDlls: List[String] = newList()
  val depBinDirs: List[String] = newList()
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Path(dir) -> {
        val depDir = if Path.isAbsolute(dir) { dir } else { Path.join(mfDir, dir) }
        val depToml = Path.join(depDir, "lyric.toml")
        val depBinDir = Path.join(depDir, "bin")
        if File.fileExists(depToml) {
          match File.readText(depToml) {
            case Ok(depMfText) -> {
              match Mf.parseManifest(depMfText, depToml) {
                case Ok(depMf) -> {
                  val dllName = match depMf.project {
                    case Some(p) -> match p.outputAssembly { case Some(asm) -> asm; case None -> p.name + ".dll" }
                    case None -> depMf.packageSection.name + ".dll"
                  }
                  val dllPath = Path.join(depBinDir, dllName)
                  if File.fileExists(dllPath) {
                    restoredDlls.add(dep.name + "\t" + dllPath)
                    // Collect unique dep bin directories for runtime probing.
                    var alreadyHave = false
                    var ddi = 0
                    while ddi < depBinDirs.count {
                      if depBinDirs[ddi] == depBinDir {
                        alreadyHave = true
                      }
                      ddi += 1
                    }
                    if not alreadyHave {
                      depBinDirs.add(depBinDir)
                    }
                  } else {
                    printErr("test: local dep '" + dep.name + "' could not be built")
                    return 1
                  }
                }
                case Err(e) -> {
                  printErr("test: local dep '" + dep.name + "': malformed lyric.toml: " + ManifestError.message(e))
                }
              }
            }
            case Err(e) -> {
              printErr("test: local dep '" + dep.name + "': cannot read " + depToml + ": " + IOError.message(e))
            }
          }
        } else {
          printErr("test: local dep '" + dep.name + "' — no lyric.toml found at '" + depToml + "'")
        }
      }
      case _ -> ()
    }
    di += 1
  }

  // Include the bootstrap CLI DLL directory in the runtime probing paths so
  // that host-shim DLLs compiled alongside it (e.g. Lyric.Session.Host.dll)
  // are locatable when the compiled test DLL runs via `dotnet exec`.
  // LYRIC_CLI_DLL is set by Program.fs when the CLI is a dotnet exec DLL
  // (the typical CI case); it is unset for native AOT binaries.
  val cliDll = Environment.getVarOrDefault("LYRIC_CLI_DLL", "")
  if cliDll.length > 0 {
    val cliDir = Path.dirname(cliDll)
    var haveCliDir = false
    var hdi = 0
    while hdi < depBinDirs.count {
      if depBinDirs[hdi] == cliDir {
        haveCliDir = true
      }
      hdi += 1
    }
    if not haveCliDir {
      depBinDirs.add(cliDir)
    }
  }

  val testOutDir = Path.join(mfDir, ".lyric-test")
  match File.createDir(testOutDir) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("test: cannot create '" + testOutDir + "': " + IOError.message(e))
      return 1
    }
  }

  var totalPassed = 0
  var totalFailed = 0

  var ti = 0
  while ti < proj.tests.count {
    val testEntry = proj.tests[ti]
    val abs = if Path.isAbsolute(testEntry.path) { testEntry.path } else { Path.join(mfDir, testEntry.path) }
    Console.println("== " + testEntry.name + " (" + testEntry.path + ")")

    val testSource = match File.readText(abs) {
      case Ok(t) -> t
      case Err(e) -> {
        printErr("test: " + IOError.message(e))
        totalFailed += 1
        ti += 1
        continue
      }
    }

    var synthFailed = false
    var rewritten = ""
    match TestSynth.synthesize(testSource, filterArg) {
      case Synthesised(rw, _, _) -> {
        rewritten = rw
      }
      case NoTestModule(span) -> {
        printErr(abs + ":" + toString(span.startPos.line) + ": not a @test_module — add @test_module annotation")
        totalFailed += 1
        synthFailed = true
      }
      case UserMainExists(span) -> {
        printErr(abs + ":" + toString(span.startPos.line) + ": @test_module cannot define func main()")
        totalFailed += 1
        synthFailed = true
      }
      case FixtureUnsupported(span) -> {
        printErr(abs + ":" + toString(span.startPos.line) + ": fixture types are not yet supported by `lyric test`")
        totalFailed += 1
        synthFailed = true
      }
      case ParseFailures(diags) -> {
        for d in diags.toArray() {
          printDiag(d)
        }
        totalFailed += 1
        synthFailed = true
      }
    }
    if synthFailed {
      ti += 1
      continue
    }

    // Compile the library packages together with the synthesised test package
    // via emitProject so each package declaration is a separate compilation
    // unit — concatenating sources into a single-file emit is invalid when
    // the project contains more than one `package` declaration.
    // Add the test package FIRST so its synthesized main() is recorded as the
    // entry point by the first-wins semantics in addPackageTokens (#2885).
    val allPkgs: List[ProjectPackage] = newList()
    val testSrcs: List[String] = newList()
    testSrcs.add(rewritten)
    allPkgs.add(ProjectPackage(name = testEntry.name, sources = testSrcs))
    var si = 0
    while si < libPkgs.count {
      allPkgs.add(libPkgs[si])
      si += 1
    }
    val asmStem = stemOf(Path.basename(testEntry.path), 2)
    val outPath = Path.join(testOutDir, asmStem + ".dll")

    val projReq = EmitProjectRequest(
      packages = allPkgs,
      assemblyName = asmStem,
      outputPath = outPath,
      target = Dotnet,
      restoredDllPaths = restoredDlls,
      activeFeatures = activeFeatures,
      declaredFeatures = mfDeclared,
      packageVersion = manifest.packageSection.version
    )
    val result = Emitter.emitProject(projReq)
    var hadBuildError = false
    for d in result.diagnostics.toArray() {
      match d.severity {
        case DiagError -> {
          hadBuildError = true
        }
        case DiagWarning -> ()
      }
      printDiag(d)
    }
    if hadBuildError {
      printErr(abs + ": test build failed")
      totalFailed += 1
      ti += 1
      continue
    }
    // The self-hosted codegen references the stdlib under its split
    // per-package assembly names (`Lyric.Stdlib.Core`, `Lyric.Stdlib.Testing`,
    // …), but a manifest dependency build ships only the bundled
    // `Lyric.Stdlib.dll` in the dep's bin dir.  The split DLLs (and their host
    // shims + `FSharp.Core`) ship beside the running `lyric` binary
    // (`appBaseDirectory()` — the publish/SDK lib dir).  `additionalProbingPaths`
    // only resolves NuGet-structured layouts, not a flat lib dir, so co-locate
    // the referenced assemblies next to the test instead — mirroring the
    // single-file `cmdTest` path.  Without this `dotnet exec` fails with
    // `Could not load file or assembly 'Lyric.Stdlib.Core'` (#1468 / #1841).
    copyRuntimeDepsBeside(outPath, Environment.appBaseDirectory())
    // Co-locate each local-path dependency's output DLL (e.g. a sibling
    // package's `Cache.dll`) beside the test assembly — a flat probing path
    // can't resolve the dep's non-NuGet bin layout.  This subsumes the manual
    // dep-DLL copy the CI ecosystem step used to do by hand.
    copyRestoredDepDlls(outPath, restoredDlls)
    writeRuntimeConfigWithProbing(outPath, depBinDirs)

    val execArgs: List[String] = newList()
    execArgs.add("exec")
    execArgs.add(outPath)
    val mfDotnetRes = ProcessCapture.runCaptureWithDiagnosticsTimeout("dotnet", execArgs, "", 600000)
    Console.print(mfDotnetRes.stdout)
    if mfDotnetRes.stderr.length > 0 {
      Console.error(mfDotnetRes.stderr)
    }
    val testExitCode = if mfDotnetRes.exitCode == -1 {
      printErr("test: failed to start dotnet")
      1
    } else if mfDotnetRes.timedOut {
      printErr("test: test binary timed out (600 s limit reached)")
      1
    } else if mfDotnetRes.stdout.length == 0 and mfDotnetRes.exitCode == 0 {
      printErr("test: compiled test binary produced no TAP output — possible silent compile or runtime failure")
      1
    } else {
      mfDotnetRes.exitCode
    }
    if testExitCode == 0 {
      totalPassed += 1
    } else {
      totalFailed += 1
    }
    ti += 1
  }

  Console.println("")
  Console.println("== summary: " + toString(totalPassed) + " passed, " + toString(totalFailed) + " failed")
  if totalFailed > 0 {
    1
  } else {
    0
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §11d. Bench command
// ─────────────────────────────────────────────────────────────────────────────
func cmdBench(argv: in slice[String]): Int {
  var runsArg = 100
  var warmupArg = 5
  var filterArg = ""
  var manifestArg: Option[String] = None
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--runs" {
      if i + 1 < argv.length {
        match parseOptInt(argv[i + 1]) {
          case Some(n) -> {
            runsArg = n
            i += 2
          }
          case None -> {
            printErr("bench: --runs requires an integer")
            return 1
          }
        }
      } else {
        printErr("bench: --runs requires a value")
        return 1
      }
    } else if arg == "--warmup" {
      if i + 1 < argv.length {
        match parseOptInt(argv[i + 1]) {
          case Some(n) -> {
            warmupArg = n
            i += 2
          }
          case None -> {
            printErr("bench: --warmup requires an integer")
            return 1
          }
        }
      } else {
        printErr("bench: --warmup requires a value")
        return 1
      }
    } else if arg == "--filter" {
      if i + 1 < argv.length {
        filterArg = argv[i + 1]
        i += 2
      } else {
        printErr("bench: --filter requires a value")
        return 1
      }
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("bench: --manifest requires a path")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // Project-mode: no explicit source file — discover or use --manifest.
  // Scans all [project.packages] source files for @bench_module and runs each.
  if positional.count == 0 {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("bench: missing source file and no lyric.toml found")
        return 1
      }
    }
    val (sourcePaths, hadFatal) = collectProjectSourcePaths(mfPath)
    if hadFatal {
      return 1
    }
    val benchFiles: List[String] = newList()
    var pi = 0
    while pi < sourcePaths.count {
      val sp = sourcePaths[pi]
      pi += 1
      val source = match File.readText(sp) { case Ok(t) -> t; case Err(_) -> "" }
      if source.length > 0 {
        // Detect @bench_module by checking that some source line, stripped of
        // leading/trailing whitespace, is exactly "@bench_module".  This avoids
        // false-positives from the text appearing inside string literals or
        // comments that happen to contain the annotation.
        val lines = Str.split(source, "\n")
        var hasBench = false
        var li = 0
        while li < lines.length {
          if Str.trim(lines[li]) == "@bench_module" {
            hasBench = true
          }
          li += 1
        }
        if hasBench {
          benchFiles.add(sp)
        }
      }
    }
    if benchFiles.count == 0 {
      printErr("bench: no @bench_module files found in project")
      return 1
    }
    var anyFailed = false
    var bi = 0
    while bi < benchFiles.count {
      val bPath = benchFiles[bi]
      bi += 1
      Console.println("== bench: " + bPath)
      val benchArgv: List[String] = newList()
      benchArgv.add("bench")
      benchArgv.add(bPath)
      benchArgv.add("--runs")
      benchArgv.add(toString(runsArg))
      benchArgv.add("--warmup")
      benchArgv.add(toString(warmupArg))
      if filterArg.length > 0 {
        benchArgv.add("--filter")
        benchArgv.add(filterArg)
      }
      val rc = cmdBench(benchArgv.toArray())
      if rc != 0 {
        anyFailed = true
      }
    }
    if anyFailed {
      return 1
    }
    return 0
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("bench: " + IOError.message(e))
      return 1
    }
  }

  val stem = stemOf(Path.basename(sourcePath), 2)
  val outPath = Path.join(Path.join(Path.dirname(sourcePath), ".lyric-bench"), stem + ".dll")

  match BenchSynth.synthesizeBench(source, runsArg, warmupArg, filterArg) {
    case NoBenchModule(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) + ": not a @bench_module — add @bench_module annotation")
      return 1
    }
    case BenchUserMainExists(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) + ": @bench_module cannot define func main()")
      return 1
    }
    case BenchParseFailures(diags) -> {
      for d in diags.toArray() {
        printDiag(d)
      }
      return 1
    }
    case BenchSynthesised(rewritten, benchCount) -> {
      Console.println(toString(benchCount) + " benchmark(s)")

      match File.createDir(Path.dirname(outPath)) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }

      val req = EmitRequest(
        source = rewritten,
        assemblyName = stem,
        outputPath = outPath,
        target = Dotnet,
        packageVersion = ""
      )
      val result = Emitter.emit(req)
      var hadError = false
      for d in result.diagnostics.toArray() {
        match d.severity {
          case DiagError -> {
            hadError = true
          }
          case DiagWarning -> ()
        }
        printDiag(d)
      }
      if hadError {
        return 1
      }
      match result.outputPath {
        case None -> {
          printErr("bench: build failed")
          return 1
        }
        case Some(_) -> ()
      }
      writeRuntimeConfig(outPath)

      val execArgs: List[String] = newList()
      execArgs.add("exec")
      execArgs.add(outPath)
      match Process.run("dotnet", execArgs) {
        case Ok(code) -> code
        case Err(e) -> {
          printErr("bench: failed to start dotnet: " + IOError.message(e))
          1
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §11e. OpenAPI command
// ─────────────────────────────────────────────────────────────────────────────
func cmdOpenApi(argv: in slice[String]): Int {
  var explicitOut: Option[String] = None
  var clientName = "ApiClient"
  var packageName = "Api.Client"
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "-o" {
      if i + 1 < argv.length {
        explicitOut = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("openapi: -o requires a value")
        return 1
      }
    } else if arg == "--client-name" {
      if i + 1 < argv.length {
        clientName = argv[i + 1]
        i += 2
      } else {
        printErr("openapi: --client-name requires a value")
        return 1
      }
    } else if arg == "--package" {
      if i + 1 < argv.length {
        packageName = argv[i + 1]
        i += 2
      } else {
        printErr("openapi: --package requires a value")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  if positional.count == 0 {
    printErr("openapi: missing spec file")
    return 1
  }

  val specPath = positional[0]
  val json = match File.readText(specPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("openapi: " + IOError.message(e))
      return 1
    }
  }

  match OAParser.parseSpec(json) {
    case Err(msg) -> {
      printErr("openapi: " + msg)
      return 1
    }
    case Ok(spec) -> {
      val generated = OAGen.generateOpenApi(spec, clientName, packageName)
      val outPath = match explicitOut {
        case Some(p) -> p
        case None -> {
          val stem = stemOf(Path.basename(specPath), 5)  // strip ".json"
          stem + "_client.l"
        }
      }
      match File.writeText(outPath, generated) {
        case Ok(_) -> {
          Console.println("generated " + outPath)
          0
        }
        case Err(e) -> {
          printErr("openapi: " + IOError.message(e))
          1
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §12. Entry point
// ─────────────────────────────────────────────────────────────────────────────
pub func main(argv: in slice[String]): Int {
  // Bare `lyric` builds the discovered project (the project-aware default).
  // Outside a project it is still a usage error, not a silent no-op.
  if argv.length == 0 {
    match Disc.findNearestManifest(Environment.currentDirectory()) {
      case Some(p) -> {
        // Forward the discovered path so cmdBuild doesn't walk the tree again.
        val buildArgv: List[String] = newList()
        buildArgv.add("build")
        buildArgv.add("--manifest")
        buildArgv.add(p)
        return cmdBuild(buildArgv.toArray())
      }
      case None -> {
        printUsage()
        return 1
      }
    }
  }

  val cmd = argv[0]

  // Internal (#2592 stage-2): emit a driver's transitive `Std.*` import closure
  // into per-package `Lyric.Stdlib.<X>.dll` assemblies via the self-hosted
  // emitter.  `--internal-perpackage-build <entry.l> <outDir> [--target jvm]`.
  // Not a user-facing command; used to produce the self-hosted stdlib layout.
  if cmd == "--internal-perpackage-build" {
    if argv.length < 3 {
      printErr("usage: lyric --internal-perpackage-build <entry.l> <outDir> [--target jvm]")
      return 1
    }
    val entryPath = argv[1]
    val outDir = argv[2]
    val tgt = if argv.length >= 5 and argv[3] == "--target" and argv[4] == "jvm" { Jvm } else { Dotnet }
    match File.readText(entryPath) {
      case Err(e) -> {
        printErr("perpackage: cannot read " + entryPath + ": " + IOError.message(e))
        return 1
      }
      case Ok(entrySrc) -> {
        val res = Emitter.emitPerPackageClosure(entrySrc, outDir, tgt)
        var hadError = false
        for d in res.diagnostics.toArray() {
          printDiag(d)
          match d.severity {
            case DiagError -> {
              hadError = true
            }
            case DiagWarning -> ()
          }
        }
        if hadError {
          return 1
        }
        match res.outputPath {
          case Some(_) -> {
            Console.println("per-package stdlib emitted to " + outDir)
            return 0
          }
          case None -> {
            printErr("perpackage: emit failed")
            return 1
          }
        }
      }
    }
  }

  if cmd == "--version" or cmd == "-v" {
    Console.println("lyric " + VERSION())
    return 0
  }

  if cmd == "--help" or cmd == "-h" or cmd == "help" {
    Console.println(usageText())
    return 0
  }

  if cmd == "build" {
    return cmdBuild(argv)
  }

  if cmd == "run" {
    return cmdRun(argv)
  }

  if cmd == "fmt" {
    return cmdFmt(argv)
  }

  if cmd == "lint" {
    return cmdLint(argv)
  }

  if cmd == "prove" {
    return cmdProve(argv)
  }

  if cmd == "doc" {
    return cmdDoc(argv)
  }

  if cmd == "public-api-diff" {
    return cmdPublicApiDiff(argv)
  }

  if cmd == "restore" {
    return cmdRestore(argv)
  }

  if cmd == "add" {
    return cmdAdd(argv)
  }

  if cmd == "init" {
    return cmdInit(argv)
  }

  if cmd == "publish" {
    return cmdPublish(argv)
  }

  if cmd == "search" {
    return cmdSearch(argv)
  }

  if cmd == "repl" {
    return cmdRepl(argv)
  }

  if cmd == "test" {
    return cmdTest(argv)
  }

  if cmd == "bench" {
    return cmdBench(argv)
  }

  if cmd == "openapi" {
    return cmdOpenApi(argv)
  }

  if cmd == "lsp" {
    // Dispatch to the self-hosted LSP stdio loop in
    // `lyric-compiler/lyric/lsp.l`.  No CLI args are consumed —
    // the language server speaks the Language Server Protocol
    // over stdin/stdout per LSP §3.0.
    Lsp.lspRunLoop()
    return 0
  }

  printErr("unknown command: " + cmd)
  match Suggest.suggestCommand(cmd) {
    case Some(s) -> printErr("did you mean '" + s + "'?")
    case None -> ()
  }
  printUsage()
  1
}
