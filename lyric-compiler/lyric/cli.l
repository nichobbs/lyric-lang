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
import Std.Sort as Sort
import Std.Hash as Hash       // sha512OfFile / sha512OfBytes for #738 lock integrity
import Std.Json as Json       // encodeString — RFC 8259 string literal escaping (#1093)

import Lyric.Manifest as Mf   // parseManifest(text, filePath) -> Result[Manifest, ManifestError]
import Lyric.Pack as Pack     // publishCsproj, restoreCsproj, xmlEscape, sanitisedPackageName
import Lyric.Lexer             // Diagnostic, DiagnosticSeverity, DiagError, DiagWarning, Span, Position
import Lyric.Workspace as Ws   // findWorkspaceRoot, findMember, resolveDep, WorkspaceContext
import Lyric.GitDep as GitDep  // resolve(url, ref, subdir) -> Result[GitDepResult, String]
import Lyric.Lockfile as LF    // emptyLockFile, addOrUpdatePackage, serializeLockFile, parseLockFile
import Std.ProcessCapture as ProcessCapture  // runCapture(exe, args, stdin) -> String
import Std.Char as Ch
import Lyric.Generator as Generator          // preprocess(source, manifestPath, sourceFile) -> Result[String, String]

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
import Lyric.BenchSynth as BenchSynth  // synthesizeBench
import Lyric.OpenApiParser as OAParser // parseSpec(json) -> Result[ParsedSpec, String]
import Lyric.OpenApiGen as OAGen       // generateOpenApi(spec, clientName, packageName) -> String
import Lyric.Lsp as Lsp                // lspRunLoop() — language server stdio loop

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
  printErr("  lyric restore [--manifest <lyric.toml>] [--locked]")
  printErr("  lyric publish [--manifest <lyric.toml>] [--dll <path>] [-o <dir>] [--registry <url>] [--api-key <key>]")
  printErr("  lyric search  <term>")
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

// Shared runtimeconfig skeleton — the TFM + framework version live here
// so they're maintained in one place (#1093).  `extra` is inserted at
// the end of the `runtimeOptions` block; pass an empty string for the
// minimal form, or the comma-prefixed `additionalProbingPaths` section.
func runtimeConfigJson(extra: in String): String {
  "{\n" +
  "  \"runtimeOptions\": {\n" +
  "    \"tfm\": \"net10.0\",\n" +
  "    \"framework\": {\n" +
  "      \"name\": \"Microsoft.NETCore.App\",\n" +
  "      \"version\": \"10.0.0\"\n" +
  "    }" + extra + "\n" +
  "  }\n" +
  "}\n"
}

// Write a minimal runtimeconfig.json next to `dllPath` so `dotnet exec`
// resolves the right runtime.  Failures are reported as warnings, not
// hard errors, because the DLL is already written at this point.
func writeRuntimeConfig(dllPath: in String): Unit {
  val dir  = Path.dirname(dllPath)
  val base = stemOf(Path.basename(dllPath), 4)  // strip ".dll"
  val cfgPath = Path.join(dir, base + ".runtimeconfig.json")
  val json = runtimeConfigJson("")
  match File.writeText(cfgPath, json) {
    case Ok(_) -> ()
    case Err(e) ->
      printErr("build: warning: runtimeconfig: " + IOError.message(e))
  }
}

// Like writeRuntimeConfig but includes additionalProbingPaths in the JSON so
// that `dotnet exec` can locate referenced DLLs (e.g. Lyric.Stdlib.Testing)
// that live in dependency bin directories rather than the output directory.
func writeRuntimeConfigWithProbing(dllPath: in String, probingPaths: in List[String]): Unit {
  val dir  = Path.dirname(dllPath)
  val base = stemOf(Path.basename(dllPath), 4)  // strip ".dll"
  val cfgPath = Path.join(dir, base + ".runtimeconfig.json")
  var probingSection = ""
  if probingPaths.count > 0 {
    probingSection = ",\n    \"additionalProbingPaths\": [\n"
    var pi = 0
    while pi < probingPaths.count {
      if pi > 0 { probingSection = probingSection + ",\n" }
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
    case Err(e) ->
      printErr("build: warning: runtimeconfig: " + IOError.message(e))
  }
}

// Compile `sourcePath` to a DLL at `outPath`.
// Returns the exit code: 0 on success, 1 on error.
// `manifestPath` is forwarded to the generator pre-processor so custom
// @generate(Pkg.Name) annotations can resolve their generator DLLs.
func buildOne(sourcePath: in String, outPath: in String, target: in CompileTarget, manifestPath: in Option[String]): Int {
  var source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e)   -> {
      printErr("build: " + IOError.message(e))
      return 1
    }
  }

  // Run custom @generate(X.Y) pre-processing before handing source to the
  // emitter.  Built-in generators (@generate(Json) etc.) are handled later
  // inside the F# bootstrap's Generate.synthesizeItems pass.
  source = match Generator.preprocess(source, manifestPath, sourcePath) {
    case Ok(augmented) -> augmented
    case Err(msg)      -> {
      printErr("build: generator error: " + msg)
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
    return buildProject(mfPath, explicitOut, target, cliFeatures, noDefaultFeatures, allFeatures)
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

  buildOne(sourcePath, outPath, target, manifestArg)
}

// Project-mode build: reads [project.packages] from lyric.toml and
// bundles every package's .l files into a single DLL.
func buildProject(
  mfPath:           in String,
  explicitOut:      in Option[String],
  target:           in CompileTarget,
  cliFeatures:      in List[String],
  noDefaultFeatures: in Bool,
  allFeatures:      in Bool
): Int {
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

  if proj.packages.count == 0 {
    printErr("build: " + mfPath + " [project.packages] is empty — single-DLL projects require explicit per-package source dirs (auto-discovery not yet wired)")
    return 1
  }

  // Collect sources for each package entry individually (not concatenated).
  // Each package entry may be a single .l file or a directory of .l files.
  val pkgs: List[ProjectPackage] = newList()
  var hadFatal = false
  var pi = 0
  while pi < proj.packages.count {
    val pkgEntry = proj.packages[pi]
    val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path }
              else { Path.join(mfDir, pkgEntry.path) }
    val pkgSources: List[String] = newList()
    if File.fileExists(abs) {
      // Single .l file: read it directly.
      match File.readText(abs) {
        case Ok(t)  -> pkgSources.add(t)
        case Err(e) -> {
          printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
        }
      }
    } else if File.dirExists(abs) {
      // Directory: collect all .l files recursively, sorted for determinism.
      val allFiles = match File.listFilesRecursive(abs) {
        case Ok(fs)  -> fs
        case Err(e)  -> {
          printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
          newList()
        }
      }
      val lFiles: List[String] = newList()
      for f in allFiles.toArray() {
        if Str.endsWith(f, ".l") { lFiles.add(f) }
      }
      if lFiles.count == 0 {
        printErr("build: package '" + pkgEntry.name + "': no .l files found in " + abs)
        hadFatal = true
      } else {
        val sorted = Sort.sortStrings(lFiles.toArray())
        for f in sorted {
          match File.readText(f) {
            case Ok(t)  -> pkgSources.add(t)
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
        val depDir = if Path.isAbsolute(dir) { dir }
                     else { Path.join(mfDir, dir) }
        val depToml = Path.join(depDir, "lyric.toml")
        val depBinDir = Path.join(depDir, "bin")
        if File.fileExists(depToml) {
          match File.readText(depToml) {
            case Ok(depMfText) -> {
              match Mf.parseManifest(depMfText, depToml) {
                case Ok(depMf) -> {
                  val dllName = match depMf.project {
                    case Some(p) -> match p.outputAssembly {
                      case Some(asm) -> asm
                      case None      -> p.name + ".dll"
                    }
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
          printErr("build: local dep '" + dep.name + "' — no lyric.toml found at '" + depToml + "'; check the path = \"...\" entry in your lyric.toml")
        }
      }
      case _ -> ()
    }
    di += 1
  }

  val asmName = stemOf(Path.basename(outPath), 4)
  val projReq = EmitProjectRequest(
    packages         = pkgs,
    assemblyName     = asmName,
    outputPath       = outPath,
    target           = target,
    restoredDllPaths = restoredDlls,
    activeFeatures   = activeFeatures
  )

  val result  = Emitter.emitProject(projReq)
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

  val buildExit = buildOne(sourcePath, outPath, Dotnet, None)
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

// Emit the <PackageReference> elements for a manifest's registry Lyric deps +
// all [nuget] entries.  Used in the generated restore csproj.
// Convert a Lyric.Manifest.GitRef to the Lyric.GitDep.GitRef expected by GitDep.resolve.
func toGitDepRef(r: in Mf.GitRef): GitDep.GitRef {
  match r {
    case Mf.Tag(name)    -> GitDep.Tag(name = name)
    case Mf.Rev(sha)     -> GitDep.Rev(sha = sha)
    case Mf.Branch(name) -> GitDep.Branch(name = name)
  }
}

func buildRestoreCsproj(manifest: in Manifest, target: in String): String {
  var refs = ""
  var di = 0
  while di < manifest.deps.count {
    val d = manifest.deps[di]
    match d.source {
      case Registry(version) -> {
        refs = refs +
          "    <PackageReference Include=\"" + Pack.xmlEscape(d.name) +
          "\" Version=\"" + Pack.xmlEscape(version) + "\" />\n"
      }
      case _ -> ()
    }
    di = di + 1
  }
  match manifest.nuget {
    case None    -> ()
    case Some(n) -> {
      var ni = 0
      while ni < n.entries.count {
        val e = n.entries[ni]
        refs = refs +
          "    <PackageReference Include=\"" + Pack.xmlEscape(e.name) +
          "\" Version=\"" + Pack.xmlEscape(e.version) + "\" />\n"
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
  if localDir.length == 0 { return None }
  val manifestPath = Path.join(localDir, "lyric.toml")
  match Hash.sha512OfFile(manifestPath) {
    case Ok(hex) -> Some(value = hex)
    case Err(_)  -> None
  }
}

/// SHA-512 of the resolved NuGet `.nupkg` for a registry dep.  Layout is
/// `~/.nuget/packages/<name-lower>/<version>/<name-lower>.<version>.nupkg`
/// — populated by `dotnet restore` before this is called.
///
/// Returns `None` when the file is missing (e.g. on a host where the
/// NuGet cache lives elsewhere, or when `dotnet restore` was skipped).
func lockSha512OfNupkg(name: in String, version: in String): Option[String] {
  if name.length == 0 or version.length == 0 { return None }
  val lower = name.toLower()
  // NUGET_PACKAGES overrides the cache root (CI uses this); empty falls through so `--locked` isn't soft-bypassed.
  val nugetPkgVar: Option[String] = match Environment.getVar("NUGET_PACKAGES") {
    case Ok(p)  -> if p.length > 0 { Some(value = p) } else { None }
    case Err(_) -> None
  }
  val cacheRoot = match nugetPkgVar {
    case Some(p) -> p
    case None    -> {
      val home = match Environment.getVar("HOME") {
        case Ok(h)  -> h
        case Err(_) ->
          match Environment.getVar("USERPROFILE") {
            case Ok(h)  -> h
            case Err(_) -> return None
          }
      }
      Path.join(home, ".nuget/packages")
    }
  }
  val cacheDir = Path.join(cacheRoot, lower)
  val versionDir = Path.join(cacheDir, version)
  val nupkgPath = Path.join(versionDir, lower + "." + version + ".nupkg")
  match Hash.sha512OfFile(nupkgPath) {
    case Ok(hex) -> Some(value = hex)
    case Err(_)  -> None
  }
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

  val mfDir   = Path.dirname(mfPath)
  val pkgName = manifest.packageSection.name

  // Find workspace context (if any) for resolving workspace/path deps.
  val wsCtx: Option[WorkspaceContext] = Ws.findWorkspaceRoot(mfDir)

  // Read existing lock file (if present).
  val lockPath = match wsCtx {
    case Some(ctx) -> Path.join(ctx.rootDir, "lyric.lock")
    case None      -> Path.join(mfDir, "lyric.lock")
  }
  var lockFileExists = false
  var lockParseError = false
  val existingLf = match File.readText(lockPath) {
    case Err(_)     -> LF.emptyLockFile()
    case Ok(locked) -> {
      lockFileExists = true
      match LF.parseLockFile(locked) {
        case Err(e)  -> { printErr("restore: lock file parse error: " + e); lockParseError = true; LF.emptyLockFile() }
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
          case None      ->
            match manifest.registry {
              case Some(rc) ->
                match rc.dotnet {
                  case Some(url) -> "nuget:" + url
                  case None      -> nugetBase
                }
              case None -> nugetBase
            }
        }
        lf = LF.addOrUpdatePackage(lf, LF.LockedPackage(
          name    = dep.name,
          version = version,
          source  = src,
          sha512  = None,                       // populated after `dotnet restore` below
          path    = None))
      }
      case Workspace(versionConstraint) -> {
        // Workspace dep — resolve to local path via workspace index.
        val resolvedDir = match wsCtx {
          case None -> {
            printErr("restore: '" + dep.name + "' declared workspace = true but no workspace root found")
            exitCode = 1
            ""
          }
          case Some(ctx) ->
            match Ws.resolveDep(dep.name, ctx) {
              case None -> {
                printErr("restore: '" + dep.name + "' declared workspace = true but not found in workspace")
                exitCode = 1
                ""
              }
              case Some(dir) -> dir
            }
        }
        if resolvedDir != "" {
          // Optional version constraint check.
          match versionConstraint {
            case None -> ()
            case Some(constraint) -> {
              val memberToml = Path.join(resolvedDir, "lyric.toml")
              match File.readText(memberToml) {
                case Err(_) -> ()
                case Ok(memberText) ->
                  match Mf.parseManifest(memberText, memberToml) {
                    case Err(_) -> ()
                    case Ok(memberMf) -> {
                      if memberMf.packageSection.version != constraint {
                        printErr("restore: workspace member '" + dep.name + "' version " +
                          memberMf.packageSection.version + " does not satisfy constraint " + constraint)
                        exitCode = 1
                      }
                    }
                  }
              }
            }
          }
          if exitCode == 0 {
            lf = LF.addOrUpdatePackage(lf, LF.LockedPackage(
              name    = dep.name,
              version = "",
              source  = "workspace",
              sha512  = lockSha512OfLocalManifest(resolvedDir),
              path    = Some(value = resolvedDir)))
            Console.println("restore: " + dep.name + " -> " + resolvedDir + " (workspace)")
          }
        }
      }
      case Path(relDir) -> {
        val absDir =
          if Path.isAbsolute(relDir) { relDir }
          else { Path.join(mfDir, relDir) }
        lf = LF.addOrUpdatePackage(lf, LF.LockedPackage(
          name    = dep.name,
          version = "",
          source  = "path:" + absDir,
          sha512  = lockSha512OfLocalManifest(absDir),
          path    = Some(value = absDir)))
        Console.println("restore: " + dep.name + " -> " + absDir + " (path)")
      }
      case Git(url, ref, subdir) -> {
        Console.println("restore: fetching " + dep.name + " from git " + url + "...")
        match GitDep.resolve(url, toGitDepRef(ref), subdir) {
          case Err(e) -> {
            printErr("restore: git dep '" + dep.name + "': " + e)
            exitCode = 1
          }
          case Ok(result) -> {
            val srcTag = "git:" + url + "#" + result.resolvedRev
            lf = LF.addOrUpdatePackage(lf, LF.LockedPackage(
              name    = dep.name,
              version = result.resolvedRev,
              source  = srcTag,
              sha512  = lockSha512OfLocalManifest(result.localDir),
              path    = Some(value = result.localDir)))
            Console.println("restore: " + dep.name + " -> " + result.localDir + " (" + result.resolvedRev + ")")
          }
        }
      }
    }
  }

  if exitCode != 0 { return exitCode }

  // Run `dotnet restore` for registry and [nuget] deps.
  val nugetCount = match manifest.nuget {
    case Some(n) -> n.entries.count
    case None    -> 0
  }
  var registryCount = 0
  var ri = 0
  while ri < manifest.deps.count {
    match manifest.deps[ri].source {
      case Registry(_) -> { registryCount += 1 }
      case _           -> ()
    }
    ri += 1
  }

  if nugetCount > 0 or registryCount > 0 {
    val target = match manifest.nuget {
      case Some(n) -> match n.target {
        case Some(t) -> t
        case None    -> "net10.0"
      }
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
      case Err(e)   -> {
        printErr("restore: dotnet restore failed: " + IOError.message(e))
        return 1
      }
    }
    if dotnetExit != 0 { return dotnetExit }
  }

  // Second pass: now that `dotnet restore` has populated the NuGet cache,
  // compute SHA-512 of each registry dep's `.nupkg` and write it back into
  // the lock entry (#738 supply-chain integrity).  Path / Workspace / Git
  // deps already had their digests written in the resolution loop above.
  val upgraded: List[LF.LockedPackage] = newList()
  var ui = 0
  while ui < lf.packages.count {
    val pkgEntry = lf.packages[ui]
    val nupkgSha: Option[String] =
      if Str.startsWith(pkgEntry.source, "nuget:") {
        match pkgEntry.sha512 {
          case Some(_) -> pkgEntry.sha512    // unlikely — kept defensively
          case None    -> lockSha512OfNupkg(pkgEntry.name, pkgEntry.version)
        }
      } else {
        pkgEntry.sha512
      }
    upgraded.add(LF.LockedPackage(
      name    = pkgEntry.name,
      version = pkgEntry.version,
      source  = pkgEntry.source,
      sha512  = nupkgSha,
      path    = pkgEntry.path))
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
          printErr("restore: --locked: '" + resolved.name + "' is not recorded in the lock file (lyric.lock is stale — run 'lyric restore')")
          lockMismatch = true
        }
        case Some(locked) -> {
          if locked.source != resolved.source {
            printErr("restore: --locked: '" + resolved.name + "' source changed: locked='" + locked.source + "' resolved='" + resolved.source + "'")
            lockMismatch = true
          } else if locked.version != resolved.version {
            printErr("restore: --locked: '" + resolved.name + "' version changed: locked='" + locked.version + "' resolved='" + resolved.version + "'")
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
              case None ->
                match resolved.sha512 {
                  case None ->
                    // Both None — soft-pass with a warning so the operator knows the integrity check was skipped (typical for pre-#738 lock files).
                    printErr("restore: --locked: warning: '" + resolved.name + "' has no SHA-512 on either side; integrity check skipped (regenerate lyric.lock with 'lyric restore' to populate digests)")
                  case Some(_) -> {
                    printErr("restore: --locked: '" + resolved.name + "' has no SHA-512 in the lock file; lyric.lock pre-dates content-integrity enforcement — run 'lyric restore' to regenerate")
                    lockMismatch = true
                  }
                }
              case Some(lockedHash) ->
                match resolved.sha512 {
                  case None ->
                    printErr("restore: --locked: warning: '" + resolved.name + "' could not be re-hashed; integrity check skipped (locked='" + lockedHash + "')")
                  case Some(resolvedHash) ->
                    if lockedHash != resolvedHash {
                      printErr("restore: --locked: '" + resolved.name + "' content changed: locked SHA-512 != resolved SHA-512")
                      printErr("  locked   : " + lockedHash)
                      printErr("  resolved : " + resolvedHash)
                      printErr("  (a registry-poisoning attack would surface here; if the package was legitimately updated, run 'lyric restore' to regenerate the lock)")
                      lockMismatch = true
                    }
                }
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
          printErr("restore: --locked: '" + locked.name + "' is in the lock file but not in lyric.toml (lyric.lock is stale — run 'lyric restore')")
          lockMismatch = true
        }
        case Some(_) -> {}
      }
      ri += 1
    }
    if lockMismatch { return 1 }
    Console.println("restore: --locked: lock file verified")
  } else {
    val lockText = LF.serializeLockFile(lf)
    match File.writeText(lockPath, lockText) {
      case Err(e) -> printErr("restore: warning: could not write lock file: " + IOError.message(e))
      case Ok(_)  -> ()
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
  var outputDir:   Option[String] = None
  var registryUrl: Option[String] = None
  var apiKey:      Option[String] = None

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

  // Warn when [workspace.overrides] are present — these should not ship.
  match manifest.workspace {
    case Some(ws) ->
      if ws.overrides.count > 0 {
        printErr("publish: warning: [workspace.overrides] is non-empty — override entries should not be committed")
      }
    case None -> ()
  }

  // Reject branch-form git deps — mutable refs cannot appear in a published manifest.
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Git(url, ref, _) ->
        match ref {
          case Branch(name) -> {
            printErr("publish: dep '" + dep.name + "' uses git branch '" + name +
              "' — mutable refs are not allowed in published packages")
            return 1
          }
          case _ -> ()
        }
      case _ -> ()
    }
    di += 1
  }

  val pkg: PackageSection = manifest.packageSection
  val mfDir   = Path.dirname(mfPath)
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
  match File.createDir(outDir) {
    case Ok(_)  -> ()
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
          case None      -> {
            printErr("publish: workspace dep '" + dep.name + "' cannot be resolved — no workspace root")
            return 1
          }
        }
        val memberDir = match Ws.resolveDep(dep.name, publishWsCtx) {
          case Some(dir) -> dir
          case None      -> {
            printErr("publish: workspace dep '" + dep.name + "' not found in workspace")
            return 1
          }
        }
        val memberToml = Path.join(memberDir, "lyric.toml")
        val memberText = match File.readText(memberToml) {
          case Ok(t)  -> t
          case Err(e) -> {
            printErr("publish: cannot read workspace member manifest: " + IOError.message(e))
            return 1
          }
        }
        match Mf.parseManifest(memberText, memberToml) {
          case Err(e)  -> {
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
      case Git(_, gitRef, _) ->
        match gitRef {
          case Tag(tagName)  -> tagName
          case Rev(sha)      -> sha
          case Branch(bName) -> bName  // already rejected above; should not reach here
        }
    }
    nuspecDeps = nuspecDeps +
      "    <PackageReference Include=\"" + dep.name + "\" Version=\"" + version + "\" />\n"
    si += 1
  }

  val absDllPath = if Path.isAbsolute(dllPath) { dllPath } else { Path.join(mfDir, dllPath) }
  val dllBase    = Path.basename(absDllPath)
  var csproj     = "<Project Sdk=\"Microsoft.NET.Sdk\">\n"
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
    case Some(r) -> { csproj = csproj + "    <RepositoryUrl>" + Pack.xmlEscape(r) + "</RepositoryUrl>\n" }
    case None    -> ()
  }
  csproj = csproj + "    <PackageTags>lyric-package</PackageTags>\n"
  csproj = csproj + "  </PropertyGroup>\n"
  csproj = csproj + "  <ItemGroup>\n"
  csproj = csproj +
    "    <None Include=\"" + Pack.xmlEscape(absDllPath) +
    "\" Pack=\"true\" PackagePath=\"lib/net10.0/" + Pack.xmlEscape(dllBase) + "\" />\n"
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
    case Err(e)   -> {
      printErr("publish: dotnet pack failed: " + IOError.message(e))
      return 1
    }
  }
  if packExit != 0 { return packExit }

  val nupkgPath = Path.join(outDir, pkg.name + "." + pkg.version + ".nupkg")
  Console.println("publish: packed " + nupkgPath)

  // Determine push registry and API key.
  val pushRegistry = match registryUrl {
    case Some(url) -> url
    case None      ->
      match manifest.registry {
        case Some(rc) ->
          match rc.dotnet {
            case Some(url) -> url
            case None      -> "https://api.nuget.org/v3/index.json"
          }
        case None -> "https://api.nuget.org/v3/index.json"
      }
  }

  val pushKey = match apiKey {
    case Some(k) -> k
    case None    ->
      match Environment.getVar("LYRIC_NUGET_API_KEY") {
        case Ok(k)  -> k
        case Err(_) -> ""
      }
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
    case Err(e)   -> {
      printErr("publish: dotnet nuget push failed: " + IOError.message(e))
      return 1
    }
  }
  if pushExit != 0 { return pushExit }

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
  val idNeedle   = "\"id\":\""
  val verNeedle  = "\"version\":\""
  val descNeedle = "\"description\":\""
  var pos = 0
  while pos < raw.length {
    val tail = Str.substring(raw, pos, raw.length - pos)
    match Str.indexOf(tail, idNeedle) {
      case None -> { pos = raw.length }
      case Some(rel) -> {
        val idStart = pos + rel + idNeedle.length
        val (idVal, afterId) = jsonStringAt(raw, idStart)
        if idVal == "" {
          pos = pos + rel + 1
        } else {
          // Look for "version" and "description" in the remainder of this entry.
          val rest = Str.substring(raw, afterId, raw.length - afterId)
          val versionVal = match Str.indexOf(rest, verNeedle) {
            case None    -> ""
            case Some(rv) -> {
              val (v, _) = jsonStringAt(raw, afterId + rv + verNeedle.length)
              v
            }
          }
          val descVal = match Str.indexOf(rest, descNeedle) {
            case None    -> ""
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
    if c == ' '  { r = r + "%20" }
    else if c == '%' { r = r + "%25" }
    else if c == '&' { r = r + "%26" }
    else if c == '+' { r = r + "%2B" }
    else if c == '#' { r = r + "%23" }
    else if c == '=' { r = r + "%3D" }
    else if c == '?' { r = r + "%3F" }
    else             { r = r + ("" + c) }
    qi += 1
  }
  r
}

// Extract a JSON string value starting at `startPos` (position right after the
// opening double-quote).  Returns (value, endPos) where endPos is the position
// after the closing double-quote.  Handles `\"` escapes.
func jsonStringAt(json: in String, startPos: in Int): (String, Int) {
  if startPos >= json.length { return ("", startPos) }
  var s = ""
  var j = startPos
  var escaping = false
  while j < json.length {
    val c = json[j]
    if escaping {
      if c == 'n'      { s = s + "\n" }
      else if c == 't' { s = s + "\t" }
      else if c == 'r' { s = s + "\r" }
      else if c == 'b' { s = s + "\u{08}" }
      else if c == 'f' { s = s + "\u{0C}" }
      else             { s = s + ("" + c) }
      escaping = false
    } else if c == '\\' {
      escaping = true
    } else if c == '"' {
      return (s, j + 1)
    } else {
      s = s + ("" + c)
    }
    j += 1
  }
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

func cmdTest(argv: in slice[String]): Int {
  var filterArg: Option[String] = None
  var manifestArg: Option[String] = None
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
  match manifestArg {
    case Some(p) -> return cmdTestManifest(p, filterArg)
    case None    -> ()
  }

  if positional.count == 0 {
    printErr("test: missing source file (or pass --manifest <lyric.toml>)")
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

// Returns true when a package source is entirely gated behind a @cfg feature
// that is not in activeFeatures, meaning the package should be compiled as an
// empty stub rather than skipped (the import in the parent package still needs
// to resolve; the @cfg-gated impl items in the parent are elided by the emitter).
//
// Detection strategy: prepend "\n" so that both the @cfg annotation and the
// package declaration are always detectable via "\n@cfg(feature = \"" and
// "\npackage " even when they appear at the very start of the source.  This
// avoids false-positives from occurrences of the substring "package " inside
// doc-comments (e.g. "extern package StackExchange.Redis") that precede the
// real package declaration.
func isCfgGatedOut(source: in String, activeFeatures: in List[String]): Bool {
  val searchable = "\n" + source
  val cfgMark   = "\n@cfg(feature = \""
  val pkgMark   = "\npackage "
  val cfgIdxOpt = Str.indexOf(searchable, cfgMark)
  match cfgIdxOpt {
    case None -> false
    case Some(cfgIdx) -> {
      val pkgIdxOpt = Str.indexOf(searchable, pkgMark)
      match pkgIdxOpt {
        case None -> false
        case Some(pkgIdx) -> {
          if cfgIdx >= pkgIdx { false }
          else {
            val cfgStart = cfgIdx + cfgMark.length
            val afterCfg = Str.substring(searchable, cfgStart, searchable.length - cfgStart)
            val closeOpt = Str.indexOf(afterCfg, "\"")
            match closeOpt {
              case None -> false
              case Some(closeIdx) -> {
                val featName = Str.substring(afterCfg, 0, closeIdx)
                var featActive = false
                var fai = 0
                while fai < activeFeatures.count {
                  if activeFeatures[fai] == featName { featActive = true }
                  fai += 1
                }
                not featActive
              }
            }
          }
        }
      }
    }
  }
}

func cmdTestManifest(mfPath: in String, filterArg: in Option[String]): Int {
  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e)   -> {
      printErr("test: " + IOError.message(e))
      return 1
    }
  }
  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m)  -> m
    case Err(e) -> {
      printErr("test: " + ManifestError.message(e))
      return 1
    }
  }
  val proj: ProjectSection = match manifest.project {
    case Some(p) -> p
    case None    -> {
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
    val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path }
              else { Path.join(mfDir, pkgEntry.path) }
    val pkgSources: List[String] = newList()
    if File.fileExists(abs) {
      match File.readText(abs) {
        case Ok(t) -> {
          if isCfgGatedOut(t, activeFeatures) {
            // Package is gated by an inactive feature: substitute an empty stub
            // so that imports of this package from sibling packages resolve, while
            // the @cfg-gated items in those packages are properly elided.
            pkgSources.add("package " + pkgEntry.name + "\n")
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
        case Ok(fs)  -> fs
        case Err(e)  -> {
          printErr("test: package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
          newList()
        }
      }
      val lFiles: List[String] = newList()
      for f in allFiles.toArray() {
        if Str.endsWith(f, ".l") { lFiles.add(f) }
      }
      if lFiles.count == 0 {
        printErr("test: package '" + pkgEntry.name + "': no .l files found in " + abs)
        hadFatal = true
      } else {
        val sorted = Sort.sortStrings(lFiles.toArray())
        for f in sorted {
          match File.readText(f) {
            case Ok(t) -> {
              if isCfgGatedOut(t, activeFeatures) {
                pkgSources.add("package " + pkgEntry.name + "\n")
              } else {
                pkgSources.add(t)
              }
            }
            case Err(e) -> {
              printErr("test: package '" + pkgEntry.name + "': " + IOError.message(e))
              hadFatal = true
            }
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

  if hadFatal { return 1 }

  // Resolve local-path dependencies to DLL paths, matching buildProject.
  // Also track unique dep bin directories so the test runtimeconfig can
  // include additionalProbingPaths — this lets dotnet exec locate stdlib
  // DLLs (e.g. Lyric.Stdlib.Testing) that live in the dep's bin dir but
  // are not merged into the main dep bundle (e.g. Lyric.Stdlib.dll).
  val restoredDlls: List[String] = newList()
  val depBinDirs:   List[String] = newList()
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Path(dir) -> {
        val depDir = if Path.isAbsolute(dir) { dir }
                     else { Path.join(mfDir, dir) }
        val depToml = Path.join(depDir, "lyric.toml")
        val depBinDir = Path.join(depDir, "bin")
        if File.fileExists(depToml) {
          match File.readText(depToml) {
            case Ok(depMfText) -> {
              match Mf.parseManifest(depMfText, depToml) {
                case Ok(depMf) -> {
                  val dllName = match depMf.project {
                    case Some(p) -> match p.outputAssembly {
                      case Some(asm) -> asm
                      case None      -> p.name + ".dll"
                    }
                    case None -> depMf.packageSection.name + ".dll"
                  }
                  val dllPath = Path.join(depBinDir, dllName)
                  if File.fileExists(dllPath) {
                    restoredDlls.add(dep.name + "\t" + dllPath)
                    // Collect unique dep bin directories for runtime probing.
                    var alreadyHave = false
                    var ddi = 0
                    while ddi < depBinDirs.count {
                      if depBinDirs[ddi] == depBinDir { alreadyHave = true }
                      ddi += 1
                    }
                    if not alreadyHave { depBinDirs.add(depBinDir) }
                  } else {
                    printErr("test: local dep '" + dep.name + "' not built — run `lyric build --manifest " + depToml + "` first")
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
  // that host-shim DLLs compiled alongside it (e.g. Lyric.Auth.Host.dll) are
  // locatable when the compiled test DLL runs via `dotnet exec`.
  // LYRIC_CLI_DLL is set by Program.fs when the CLI is a dotnet exec DLL
  // (the typical CI case); it is unset for native AOT binaries.
  val cliDll = Environment.getVarOrDefault("LYRIC_CLI_DLL", "")
  if cliDll.length > 0 {
    val cliDir = Path.dirname(cliDll)
    var haveCliDir = false
    var hdi = 0
    while hdi < depBinDirs.count {
      if depBinDirs[hdi] == cliDir { haveCliDir = true }
      hdi += 1
    }
    if not haveCliDir { depBinDirs.add(cliDir) }
  }

  val testOutDir = Path.join(mfDir, ".lyric-test")
  match File.createDir(testOutDir) {
    case Ok(_)  -> ()
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
    val abs = if Path.isAbsolute(testEntry.path) { testEntry.path }
              else { Path.join(mfDir, testEntry.path) }
    Console.println("== " + testEntry.name + " (" + testEntry.path + ")")

    val testSource = match File.readText(abs) {
      case Ok(t)  -> t
      case Err(e) -> {
        printErr("test: " + IOError.message(e))
        totalFailed += 1
        ti += 1
        continue
      }
    }

    val rewritten: String = match TestSynth.synthesize(testSource, filterArg) {
      case Synthesised(rw, _, _) -> rw
      case NoTestModule(span)    -> {
        printErr(abs + ":" + toString(span.startPos.line) +
                 ": not a @test_module — add @test_module annotation")
        totalFailed += 1
        ti += 1
        continue
      }
      case UserMainExists(span) -> {
        printErr(abs + ":" + toString(span.startPos.line) +
                 ": @test_module cannot define func main()")
        totalFailed += 1
        ti += 1
        continue
      }
      case FixtureUnsupported(span) -> {
        printErr(abs + ":" + toString(span.startPos.line) +
                 ": fixture types are not yet supported by `lyric test`")
        totalFailed += 1
        ti += 1
        continue
      }
      case ParseFailures(diags) -> {
        for d in diags.toArray() { printDiag(d) }
        totalFailed += 1
        ti += 1
        continue
      }
    }

    // Compile the library packages together with the synthesised test package
    // via emitProject so each package declaration is a separate compilation
    // unit — concatenating sources into a single-file emit is invalid when
    // the project contains more than one `package` declaration.
    val allPkgs: List[ProjectPackage] = newList()
    var si = 0
    while si < libPkgs.count {
      allPkgs.add(libPkgs[si])
      si += 1
    }
    val testSrcs: List[String] = newList()
    testSrcs.add(rewritten)
    allPkgs.add(ProjectPackage(name = testEntry.name, sources = testSrcs))

    val asmStem = stemOf(Path.basename(testEntry.path), 2)
    val outPath = Path.join(testOutDir, asmStem + ".dll")

    val projReq = EmitProjectRequest(
      packages         = allPkgs,
      assemblyName     = asmStem,
      outputPath       = outPath,
      target           = Dotnet,
      restoredDllPaths = restoredDlls,
      activeFeatures   = activeFeatures
    )
    val result  = Emitter.emitProject(projReq)
    var hadBuildError = false
    for d in result.diagnostics.toArray() {
      match d.severity {
        case DiagError   -> { hadBuildError = true }
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
    // Stdlib DLLs compiled on-demand during --internal-project-build are
    // already in testOutDir: Program.fs copies every DLL from the
    // subprocess's per-PID stdlib cache to Path.GetDirectoryName(outPath)
    // before the subprocess exits.  No /tmp scanning needed here.
    writeRuntimeConfigWithProbing(outPath, depBinDirs)

    val execArgs: List[String] = newList()
    execArgs.add("exec")
    execArgs.add(outPath)
    val testExitCode = match Process.run("dotnet", execArgs) {
      case Ok(code) -> code
      case Err(e)   -> {
        printErr("test: failed to start dotnet: " + IOError.message(e))
        1
      }
    }
    if testExitCode == 0 {
      totalPassed += 1
    } else {
      totalFailed += 1
    }
    ti += 1
  }

  Console.println("")
  Console.println("== summary: " + toString(totalPassed) + " passed, " +
                  toString(totalFailed) + " failed")
  if totalFailed > 0 { 1 } else { 0 }
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
  printUsage()
  1
}
