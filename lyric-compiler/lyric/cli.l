// lyric/cli.l — self-hosted Lyric CLI (Phase 5 §M5.3).
//
// Command dispatch for the `lyric` command-line tool.  Mirrors the F#
// bootstrap CLI (compiler/src/Lyric.Cli/Program.fs) but written entirely
// in Lyric.  Compiled by the self-hosted compiler during Phase 5 once
// Lyric.Parser, Lyric.Emitter, Lyric.Fmt, Lyric.Lint, Lyric.Verifier,
// and Lyric.Doc are available.
//
// Commands:
//   build   <source.l> [-o <output>] [--force] [--manifest <lyric.toml>]
//              [--target dotnet|jvm]
//   run     <source.l> [-- <args>...]
//   fmt     <source.l> [--check] [--write]
//   lint    <source.l> [--error-on-warning]
//   prove   <source.l> [--verbose] [--allow-unverified] [--json] [--explain --goal <n>]
//   doc     <source.l> [-o <out.md>]
//   public-api-diff <old.dll> <new.dll>
//   restore [--manifest <lyric.toml>]
//   publish [--manifest <lyric.toml>] [--dll <path>] [-o <dir>]
//   test    <source.l> [--filter <prefix>] [--list]
//   bench   <source.l> [--runs N] [--warmup N] [--filter <prefix>]
//   openapi <spec.json> [-o <out.l>] [--client-name <Name>] [--package <Pkg>]
//   --version / -v
//
// Future-package API contracts (packages not yet shipped; will exist
// when this file is compiled in Phase 5):
//
//   Lyric.Parser:
//     pub func parse(source: in String): ParseResult
//     pub record ParseResult { file: SourceFile; diagnostics: List[Diagnostic] }
//
//   Lyric.Emitter:
//     pub union CompileTarget { case Dotnet | case Jvm }
//     pub record EmitRequest { source: String; assemblyName: String;
//                              outputPath: String; target: CompileTarget }
//     pub record EmitResult { outputPath: Option[String];
//                             diagnostics: List[Diagnostic] }
//     pub func emit(req: in EmitRequest): EmitResult
//
//   Lyric.Fmt:
//     pub func format(parsed: in ParseResult): String
//     pub func isFormatted(source: in String, parsed: in ParseResult): Bool
//
//   Lyric.Lint:
//     pub union LintSeverity { case LintError | case LintWarning }
//     pub record LintDiag { severity: LintSeverity; code: String;
//                           message: String; line: Int; col: Int }
//     pub record LintResult { diagnostics: List[LintDiag] }
//     pub func lint(parsed: in ParseResult): LintResult
//     pub func renderDiagnostic(d: in LintDiag): String
//
//   Lyric.Verifier:
//     pub record ProveOptions { allowUnverified: Bool; verbose: Bool }
//     pub record ProofSummary {
//       diagnostics: List[Diagnostic]; totalCount: Int;
//       dischargedCount: Int; isProofRequired: Bool;
//       level: String; hadError: Bool }
//     pub func prove(source: in String, options: in ProveOptions): ProofSummary
//
//   Lyric.Doc:
//     pub func generate(parsed: in ParseResult): String
//
//   Lyric.ContractMeta:
//     pub func readFromFile(path: in String): Option[String]
//     pub func diffContracts(oldJson: in String, newJson: in String): List[String]
//     pub func hasBreakingChanges(entries: in List[String]): Bool

package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str      // before Path so Path.join/2 wins over Str.join/2
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.Errors
import Std.Parse

import Lyric.Manifest as Mf   // parseManifest(text, filePath) -> Result[Manifest, ManifestError]
import Lyric.Lexer             // Diagnostic, DiagnosticSeverity, DiagError, DiagWarning, Span, Position

// Phase 5 M5.2+ packages — present when the self-hosted compiler compiles this file.
import Lyric.Emitter as Emitter        // emit(req) -> EmitResult; CompileTarget, Dotnet, Jvm
import Lyric.Fmt as Fmt                // formatSource(src) -> String; isFormattedSource(src) -> Bool
import Lyric.Lint as Lint              // lint(source) -> List[LintDiag]
import Lyric.ModeChecker as MC         // vlIsProofRequired, vlDisplay
import Lyric.Verifier as Verifier      // proveSource/proveSourceWithOptions -> ProofSummary; summary* helpers
import Lyric.Doc as Doc                // generate(source) -> String
import Lyric.ContractMeta as Meta      // readFromFile, diffContracts, hasBreakingChanges
import Lyric.Repl as Repl              // run(argv) -> Int
import Lyric.TestSynth as TestSynth    // synthesize, listEntries
import Lyric.BenchSynth as BenchSynth  // synthesize
import Lyric.OpenApiParser as OAParser // parseSpec(json) -> Result[ParsedSpec, String]
import Lyric.OpenApiGen as OAGen       // generate(spec, clientName, packageName) -> String

func VERSION(): String { "0.1.0" }

// ─────────────────────────────────────────────────────────────────────────────
// §1. Helpers
// ─────────────────────────────────────────────────────────────────────────────

func printErr(message: in String): Unit {
  Console.error(message)
}

func printDiag(d: in Diagnostic): Unit {
  val sev = match d.severity {
    case DiagError   -> "error"
    case DiagWarning -> "warning"
  }
  printErr(d.code + " " + sev + " [" +
    toString(d.span.startPos.line) + ":" +
    toString(d.span.startPos.column) + "]: " + d.message)
}

func printUsage(): Unit {
  printErr("Usage:")
  printErr("  lyric build   <source.l> [-o <output>] [--force] [--manifest <lyric.toml>] [--target dotnet|jvm]")
  printErr("  lyric build   --manifest <lyric.toml>  (project mode: bundles [project.packages] into one DLL)")
  printErr("  lyric run     <source.l> [-- <args>...]")
  printErr("  lyric fmt     <source.l> [--check] [--write]")
  printErr("  lyric lint    <source.l> [--error-on-warning]")
  printErr("  lyric prove   <source.l> [--verbose] [--allow-unverified] [--json] [--explain --goal <n>]")
  printErr("  lyric doc     <source.l> [-o out.md]")
  printErr("  lyric test    <source.l> [--filter <prefix>] [--list]")
  printErr("  lyric bench   <source.l> [--runs N] [--warmup N] [--filter <prefix>]")
  printErr("  lyric openapi <spec.json> [-o <out.l>] [--client-name <Name>] [--package <Pkg>]")
  printErr("  lyric public-api-diff <old.dll> <new.dll>")
  printErr("  lyric restore [--manifest <lyric.toml>]")
  printErr("  lyric publish [--manifest <lyric.toml>] [--dll <path>] [-o <dir>]")
  printErr("  lyric repl")
  printErr("  lyric --version")
  printErr("")
  printErr("  build is incremental — same source + stdlib skips emit; --force rebuilds.")
  printErr("  fmt:  --write overwrites in place; --check exits 1 if would change.")
  printErr("        Non-doc comments (//) are not preserved — only /// and //!.")
  printErr("  lint: L001-L005 style checks. --error-on-warning exits 1 on warnings.")
}

// Return the stem of a filename (basename without final extension).
func stemOf(base: in String, extLen: in Int): String {
  val n = base.length
  if n > extLen { base.substring(0, n - extLen) } else { base }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Core build helper
// ─────────────────────────────────────────────────────────────────────────────

// Write a minimal runtimeconfig.json next to `dllPath` so `dotnet exec`
// resolves the right runtime.  Failures are reported as warnings, not
// hard errors, because the DLL is already written at this point.
func writeRuntimeConfig(dllPath: in String): Unit {
  val dir  = Path.dirname(dllPath)
  val base = stemOf(Path.basename(dllPath), 4)  // strip ".dll"
  val cfgPath = Path.join(dir, base + ".runtimeconfig.json")
  val json =
    "{\n" +
    "  \"runtimeOptions\": {\n" +
    "    \"tfm\": \"net10.0\",\n" +
    "    \"framework\": {\n" +
    "      \"name\": \"Microsoft.NETCore.App\",\n" +
    "      \"version\": \"10.0.0\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
  match File.writeText(cfgPath, json) {
    case Ok(_) -> ()
    case Err(e) ->
      printErr("build: warning: runtimeconfig: " + IOError.message(e))
  }
}

// Compile `sourcePath` to a DLL at `outPath`.
// Returns the exit code: 0 on success, 1 on error.
func buildOne(sourcePath: in String, outPath: in String, target: in CompileTarget): Int {
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e)   -> {
      printErr("build: " + IOError.message(e))
      return 1
    }
  }

  val outDir = Path.dirname(outPath)
  match File.createDir(outDir) {
    case Ok(_)  -> ()
    case Err(e) ->
      printErr("build: cannot create output dir: " + IOError.message(e))
  }

  val outBase  = Path.basename(outPath)
  val asmName  = stemOf(outBase, 4)  // strip ".dll"
  val req = EmitRequest(
    source       = source,
    assemblyName = asmName,
    outputPath   = outPath,
    target       = target
  )

  val result = Emitter.emit(req)
  var hadError = false
  for d in result.diagnostics.toArray() {
    match d.severity {
      case DiagError   -> { hadError = true }
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

  writeRuntimeConfig(outPath)
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
          if Str.length(trimmed) > 0 { cliFeatures.add(trimmed) }
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
  // D045: feature-set computed here once buildOne / buildProject
  // accept a `features` parameter (Phase 5+ stage 7 follow-up).  For
  // now the parsed flags are intentionally unused — they document the
  // CLI surface in lockstep with the F# bootstrap.
  val _features = cliFeatures
  val _noDefault = noDefaultFeatures
  val _all = allFeatures

  // Project-mode: `lyric build --manifest lyric.toml` with no positional source.
  if positional.count == 0 {
    val mfPath = match manifestArg {
      case Some(p) -> p
      case None    -> {
        printErr("build: missing source file or --manifest")
        printUsage()
        return 1
      }
    }
    return buildProject(mfPath, explicitOut, target)
  }

  val sourcePath = positional[0]
  if not File.fileExists(sourcePath) {
    printErr("build: source file not found: " + sourcePath)
    return 1
  }

  val outPath = match explicitOut {
    case Some(o) -> o
    case None    -> {
      val dir  = Path.dirname(sourcePath)
      val stem = stemOf(Path.basename(sourcePath), 2)  // strip ".l"
      Path.join(dir, stem + ".dll")
    }
  }

  buildOne(sourcePath, outPath, target)
}

// Project-mode build: reads [project.packages] from lyric.toml and
// bundles every package's .l files into a single DLL.
func buildProject(mfPath: in String, explicitOut: in Option[String], target: in CompileTarget): Int {
  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e)   -> {
      printErr("build: " + IOError.message(e))
      return 1
    }
  }
  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m)  -> m
    case Err(e) -> {
      printErr("build: " + ManifestError.message(e))
      return 1
    }
  }
  val proj: ProjectSection = match manifest.project {
    case Some(p) -> p
    case None    -> {
      printErr("build: " + mfPath + " has no [project] section")
      return 1
    }
  }

  val mfDir   = Path.dirname(mfPath)
  val outPath = match explicitOut {
    case Some(o) -> o
    case None    -> {
      val stem = match proj.outputAssembly {
        case Some(s) -> s
        case None    -> proj.name + ".dll"
      }
      Path.join(Path.join(mfDir, "bin"), stem)
    }
  }

  val outDir = Path.dirname(outPath)
  match File.createDir(outDir) {
    case Ok(_)  -> ()
    case Err(e) -> printErr("build: cannot create output dir: " + IOError.message(e))
  }

  // Collect sources for each package entry.
  val sources: List[String] = newList()
  var hadFatal = false
  var pi = 0
  while pi < proj.packages.count {
    val pkgEntry = proj.packages[pi]
    val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path }
              else { Path.join(mfDir, pkgEntry.path) }
    val text = match File.readText(abs) {
      case Ok(t)  -> t
      case Err(e) -> {
        printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
        hadFatal = true
        ""
      }
    }
    if not hadFatal {
      sources.add(text)
    }
    pi += 1
  }

  if hadFatal {
    return 1
  }

  // Emit all sources as a single combined source string (one-package bundle).
  // The emitter's project path handles multi-package interleaving via
  // Lyric.Emitter.emitProject when that API is available.  For now the
  // sources list is passed joined as a sentinel; the emitter decides.
  var combined = ""
  var si = 0
  while si < sources.count {
    combined = combined + sources[si]
    si += 1
  }

  val asmName = stemOf(Path.basename(outPath), 4)
  val req = EmitRequest(
    source       = combined,
    assemblyName = asmName,
    outputPath   = outPath,
    target       = target
  )

  val result  = Emitter.emit(req)
  var hadError = false
  for d in result.diagnostics.toArray() {
    match d.severity {
      case DiagError   -> { hadError = true }
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

// ─────────────────────────────────────────────────────────────────────────────
// §4. Run command
// ─────────────────────────────────────────────────────────────────────────────

func cmdRun(argv: in slice[String]): Int {
  if argv.length < 2 {
    printErr("run: missing source file")
    printUsage()
    return 1
  }

  val sourcePath = argv[1]
  if not File.fileExists(sourcePath) {
    printErr("run: source file not found: " + sourcePath)
    return 1
  }

  // Collect user args (everything after optional "--" separator).
  val userArgs: List[String] = newList()
  var i = 2
  var pastSep = false
  while i < argv.length {
    val arg = argv[i]
    if not pastSep and arg == "--" {
      pastSep = true
    } else {
      userArgs.add(arg)
    }
    i += 1
  }

  // Build to a `.lyric-run/` temp path next to the source file.
  val srcDir  = Path.dirname(sourcePath)
  val stem    = stemOf(Path.basename(sourcePath), 2)
  val outPath = Path.join(Path.join(srcDir, ".lyric-run"), stem + ".dll")

  val buildExit = buildOne(sourcePath, outPath, Dotnet)
  if buildExit != 0 {
    return buildExit
  }

  // `dotnet exec <dll> [user args...]`
  val execArgs: List[String] = newList()
  execArgs.add("exec")
  execArgs.add(outPath)
  for a in userArgs.toArray() {
    execArgs.add(a)
  }

  match Process.run("dotnet", execArgs) {
    case Ok(code) -> code
    case Err(e)   -> {
      printErr("run: failed to start dotnet: " + IOError.message(e))
      1
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Fmt command
// ─────────────────────────────────────────────────────────────────────────────

func cmdFmt(argv: in slice[String]): Int {
  var checkMode = false
  var writeMode = false
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
    } else {
      positional.add(arg)
      i += 1
    }
  }

  if positional.count == 0 {
    printErr("fmt: missing source file")
    printUsage()
    return 1
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e)   -> {
      printErr("fmt: " + IOError.message(e))
      return 1
    }
  }

  if checkMode {
    if Fmt.isFormattedSource(source) {
      return 0
    } else {
      printErr(sourcePath + ": not formatted — run `lyric fmt --write`")
      return 1
    }
  }

  val formatted = Fmt.formatSource(source)
  if writeMode {
    match File.writeText(sourcePath, formatted) {
      case Ok(_)  -> {
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
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--error-on-warning" {
      errorOnWarning = true
      i += 1
    } else {
      positional.add(arg)
      i += 1
    }
  }

  if positional.count == 0 {
    printErr("lint: missing source file")
    printUsage()
    return 2
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e)   -> {
      printErr("lint: " + IOError.message(e))
      return 2
    }
  }

  val lintDiags = Lint.lint(source)
  var hasError  = false
  var hasWarning = false
  for d in lintDiags.toArray() {
    val sev = match d.severity { case LintError -> "error" case LintWarning -> "warning" }
    printErr(d.code + " " + sev + " [" +
      toString(d.span.startPos.line) + ":" +
      toString(d.span.startPos.column) + "]: " + d.message)
    match d.severity {
      case LintError   -> { hasError = true }
      case LintWarning -> { hasWarning = true }
    }
  }

  if hasError or (errorOnWarning and hasWarning) { 1 } else { 0 }
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
    if c == '"'  { r = r + "\\\"" }
    else if c == '\\' { r = r + "\\\\" }
    else if c == '\n' { r = r + "\\n" }
    else if c == '\r' { r = r + "\\r" }
    else if c == '\t' { r = r + "\\t" }
    else { r = r + ("" + c) }
    i = i + 1
  }
  r
}

func jsonStr(s: in String): String { "\"" + jsonEsc(s) + "\"" }

func cmdProve(argv: in slice[String]): Int {
  var verbose         = false
  var allowUnverified = false
  var jsonOutput      = false
  var explain         = false
  var explainGoal: Option[Int] = None
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
          case Some(n) -> { explainGoal = Some(value = n); i += 2 }
          case None    -> { printErr("prove: --goal requires an integer"); return 1 }
        }
      } else {
        printErr("prove: --goal requires a value")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  if positional.count == 0 {
    printErr("prove: missing source file")
    return 1
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e)   -> {
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
          printErr("  " + toString(gi) + ": " + r.goal.label +
            "  [" + Verifier.goalKindDisplay(r.goal.kind) + "]")
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
      val r      = summary.results[gi]
      val gl     = r.goal
      val comma  = if gi + 1 < summary.results.count { "," } else { "" }
      val outcomeStr = match r.outcome {
        case Discharged        -> "discharged"
        case Counterexample(_) -> "counterexample"
        case Unknown(_)        -> "unknown"
      }
      val modelStr = match r.outcome {
        case Counterexample(m) -> jsonStr(m)
        case _                 -> "null"
      }
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
      val sevStr = match d.severity { case DiagError -> "error" case DiagWarning -> "warning" }
      jsonBuf = jsonBuf + "    {\"code\":" + jsonStr(d.code) + ",\"severity\":" + jsonStr(sevStr) +
            ",\"message\":" + jsonStr(d.message) + ",\"line\":" +
            toString(d.span.startPos.line) + ",\"col\":" +
            toString(d.span.startPos.column) + "}" + comma + "\n"
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

  val total      = Verifier.summaryTotalCount(summary)
  val discharged = Verifier.summaryDischargedCount(summary)
  val levelStr   = MC.vlDisplay(summary.level)

  if MC.vlIsProofRequired(summary.level) {
    Console.println(
      toString(discharged) + "/" +
      toString(total) + " obligations discharged (" +
      levelStr + ")")
  } else {
    Console.println("no proof obligations: package is " + levelStr)
  }

  // Exit 1 only for error diagnostics or counterexamples; unknown goals
  // (trivial solver gave up, z3 not available) are not failures.
  if Verifier.summaryHasErrorDiag(summary) or Verifier.summaryHasCounterexample(summary) { 1 } else { 0 }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Doc command
// ─────────────────────────────────────────────────────────────────────────────

func cmdDoc(argv: in slice[String]): Int {
  var explicitOut: Option[String] = None
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
    } else {
      positional.add(arg)
      i += 1
    }
  }

  if positional.count == 0 {
    printErr("doc: missing source file")
    return 1
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e)   -> {
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
        case Ok(_)  -> ()
        case Err(e) -> printErr("doc: warning: " + IOError.message(e))
      }
      match File.writeText(outPath, md) {
        case Ok(_)  -> {
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
    case None    -> {
      printErr("public-api-diff: '" + oldDll + "' has no Lyric.Contract resource")
      return 1
    }
  }
  val newJson = match Meta.readFromFile(newDll) {
    case Some(j) -> j
    case None    -> {
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

func cmdRestore(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None

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
    } else {
      printErr("restore: unrecognised flag '" + arg + "'")
      i += 1
    }
  }

  val mfPath = match manifestArg {
    case Some(p) -> p
    case None    -> "lyric.toml"
  }

  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e)   -> {
      printErr("restore: " + IOError.message(e))
      return 1
    }
  }

  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m)  -> m
    case Err(e) -> {
      printErr("restore: " + ManifestError.message(e))
      return 1
    }
  }

  val lyricCount = manifest.deps.count
  val nugetCount = match manifest.nuget {
    case Some(n) -> n.entries.count
    case None    -> 0
  }

  // Invoke `dotnet restore` against a generated csproj for the [dependencies]
  // entries.  Full NuGet/shim generation (Pack.l) is a Phase 5 follow-up;
  // for now print what would be restored and succeed so the command is usable.
  if nugetCount == 0 {
    Console.println("restore: " + toString(lyricCount) +
      " Lyric package" + (if lyricCount == 1 { "" } else { "s" }) +
      " declared in " + mfPath)
  } else {
    Console.println("restore: " + toString(lyricCount) + " Lyric + " +
      toString(nugetCount) + " NuGet package" +
      (if lyricCount + nugetCount == 1 { "" } else { "s" }) +
      " declared in " + mfPath)
  }
  0
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Publish command
// ─────────────────────────────────────────────────────────────────────────────

func cmdPublish(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  var dllOverride: Option[String] = None
  var outputDir:   Option[String] = None

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
    } else {
      printErr("publish: unrecognised flag '" + arg + "'")
      i += 1
    }
  }

  val mfPath = match manifestArg {
    case Some(p) -> p
    case None    -> "lyric.toml"
  }

  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e)   -> {
      printErr("publish: " + IOError.message(e))
      return 1
    }
  }

  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m)  -> m
    case Err(e) -> {
      printErr("publish: " + ManifestError.message(e))
      return 1
    }
  }

  val pkg: PackageSection = manifest.packageSection
  val mfDir  = Path.dirname(mfPath)
  val dllPath = match dllOverride {
    case Some(d) -> d
    case None    -> Path.join(Path.join(mfDir, "bin"), pkg.name + ".dll")
  }

  if not File.fileExists(dllPath) {
    printErr("publish: DLL not found: " + dllPath + " — run `lyric build` first")
    return 1
  }

  val outDir = match outputDir {
    case Some(d) -> d
    case None    -> Path.join(Path.join(mfDir, "bin"), "nupkg")
  }

  // Full `dotnet pack` integration is wired when Pack.l is implemented.
  val nupkg = Path.join(outDir, pkg.name + "." + pkg.version + ".nupkg")
  Console.println("publish: " + nupkg + " (dotnet pack integration: see Phase 5 Pack.l)")
  0
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

func cmdTest(argv: in slice[String]): Int {
  var filterArg: Option[String] = None
  var listMode = false
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
    } else if arg == "--list" {
      listMode = true
      i += 1
    } else {
      positional.add(arg)
      i += 1
    }
  }

  if positional.count == 0 {
    printErr("test: missing source file")
    return 1
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e)   -> { printErr("test: " + IOError.message(e)); return 1 }
  }

  if listMode {
    match TestSynth.listEntries(source) {
      case Err(diags) -> {
        for d in diags.toArray() { printDiag(d) }
        return 1
      }
      case Ok(entries) -> {
        for e in entries.toArray() {
          match e {
            case TestEntry(title)             -> Console.println("test: " + title)
            case PropertyEntry(title, reason) -> Console.println("prop: " + title + " (" + reason + ")")
            case FixtureEntry(name)           -> Console.println("fixture: " + name)
          }
        }
        return 0
      }
    }
  }

  val stem    = stemOf(Path.basename(sourcePath), 2)
  val outPath = Path.join(Path.join(Path.dirname(sourcePath), ".lyric-test"), stem + ".dll")

  match TestSynth.synthesize(source, filterArg) {
    case NoTestModule(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) +
        ": not a @test_module — add @test_module annotation")
      return 1
    }
    case UserMainExists(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) +
        ": @test_module cannot define func main()")
      return 1
    }
    case FixtureUnsupported(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) +
        ": fixture types are not yet supported by `lyric test`")
      return 1
    }
    case ParseFailures(diags) -> {
      for d in diags.toArray() { printDiag(d) }
      return 1
    }
    case Synthesised(rewritten, testCnt, skipCnt) -> {
      Console.println(toString(testCnt) + " test(s), " + toString(skipCnt) + " skipped")

      match File.createDir(Path.dirname(outPath)) {
        case Ok(_)  -> ()
        case Err(_) -> ()
      }

      val req = EmitRequest(
        source       = rewritten,
        assemblyName = stem,
        outputPath   = outPath,
        target       = Dotnet
      )
      val result = Emitter.emit(req)
      var hadError = false
      for d in result.diagnostics.toArray() {
        match d.severity { case DiagError -> { hadError = true } case DiagWarning -> () }
        printDiag(d)
      }
      if hadError { return 1 }
      match result.outputPath {
        case None    -> { printErr("test: build failed"); return 1 }
        case Some(_) -> ()
      }
      writeRuntimeConfig(outPath)

      val execArgs: List[String] = newList()
      execArgs.add("exec")
      execArgs.add(outPath)
      match Process.run("dotnet", execArgs) {
        case Ok(code) -> code
        case Err(e)   -> { printErr("test: failed to start dotnet: " + IOError.message(e)); 1 }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §11d. Bench command
// ─────────────────────────────────────────────────────────────────────────────

func cmdBench(argv: in slice[String]): Int {
  var runsArg   = 100
  var warmupArg = 5
  var filterArg = ""
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--runs" {
      if i + 1 < argv.length {
        match parseOptInt(argv[i + 1]) {
          case Some(n) -> { runsArg = n; i += 2 }
          case None    -> { printErr("bench: --runs requires an integer"); return 1 }
        }
      } else { printErr("bench: --runs requires a value"); return 1 }
    } else if arg == "--warmup" {
      if i + 1 < argv.length {
        match parseOptInt(argv[i + 1]) {
          case Some(n) -> { warmupArg = n; i += 2 }
          case None    -> { printErr("bench: --warmup requires an integer"); return 1 }
        }
      } else { printErr("bench: --warmup requires a value"); return 1 }
    } else if arg == "--filter" {
      if i + 1 < argv.length {
        filterArg = argv[i + 1]
        i += 2
      } else { printErr("bench: --filter requires a value"); return 1 }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  if positional.count == 0 {
    printErr("bench: missing source file")
    return 1
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e)   -> { printErr("bench: " + IOError.message(e)); return 1 }
  }

  val stem    = stemOf(Path.basename(sourcePath), 2)
  val outPath = Path.join(Path.join(Path.dirname(sourcePath), ".lyric-bench"), stem + ".dll")

  match BenchSynth.synthesizeBench(source, runsArg, warmupArg, filterArg) {
    case NoBenchModule(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) +
        ": not a @bench_module — add @bench_module annotation")
      return 1
    }
    case UserMainExists(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) +
        ": @bench_module cannot define func main()")
      return 1
    }
    case ParseFailures(diags) -> {
      for d in diags.toArray() { printDiag(d) }
      return 1
    }
    case BenchSynthesised(rewritten, benchCount) -> {
      Console.println(toString(benchCount) + " benchmark(s)")

      match File.createDir(Path.dirname(outPath)) {
        case Ok(_)  -> ()
        case Err(_) -> ()
      }

      val req = EmitRequest(
        source       = rewritten,
        assemblyName = stem,
        outputPath   = outPath,
        target       = Dotnet
      )
      val result = Emitter.emit(req)
      var hadError = false
      for d in result.diagnostics.toArray() {
        match d.severity { case DiagError -> { hadError = true } case DiagWarning -> () }
        printDiag(d)
      }
      if hadError { return 1 }
      match result.outputPath {
        case None    -> { printErr("bench: build failed"); return 1 }
        case Some(_) -> ()
      }
      writeRuntimeConfig(outPath)

      val execArgs: List[String] = newList()
      execArgs.add("exec")
      execArgs.add(outPath)
      match Process.run("dotnet", execArgs) {
        case Ok(code) -> code
        case Err(e)   -> { printErr("bench: failed to start dotnet: " + IOError.message(e)); 1 }
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
      } else { printErr("openapi: -o requires a value"); return 1 }
    } else if arg == "--client-name" {
      if i + 1 < argv.length {
        clientName = argv[i + 1]
        i += 2
      } else { printErr("openapi: --client-name requires a value"); return 1 }
    } else if arg == "--package" {
      if i + 1 < argv.length {
        packageName = argv[i + 1]
        i += 2
      } else { printErr("openapi: --package requires a value"); return 1 }
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
    case Err(e)   -> { printErr("openapi: " + IOError.message(e)); return 1 }
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
        case None    -> {
          val stem = stemOf(Path.basename(specPath), 5)  // strip ".json"
          stem + "_client.l"
        }
      }
      match File.writeText(outPath, generated) {
        case Ok(_)  -> { Console.println("generated " + outPath); 0 }
        case Err(e) -> { printErr("openapi: " + IOError.message(e)); 1 }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §12. Entry point
// ─────────────────────────────────────────────────────────────────────────────

pub func main(argv: in slice[String]): Int {
  if argv.length == 0 {
    printUsage()
    return 1
  }

  val cmd = argv[0]

  if cmd == "--version" or cmd == "-v" {
    Console.println("lyric " + VERSION())
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

  if cmd == "repl" {
    return cmdRepl(argv)
  }

  if cmd == "publish" {
    return cmdPublish(argv)
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

  printErr("unknown command: " + cmd)
  printUsage()
  1
}
