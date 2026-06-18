// lyric/emitter.l — Lyric.Emitter bootstrap package.
//
// Implements the `emit(req): EmitResult` contract that cli.l and repl.l
// depend on.
//
// `--target dotnet` compilation — both single-source and multi-package
// — runs IN-PROCESS via `Msil.Bridge.compileToMsilWithVersion` /
// `compileProjectToMsilWithRestoredAndVersion`.  No subprocess hop, no
// F# emitter touched at runtime.  Restored-deps, feature flags, and
// manifest-threaded `[package].version` all flow through the same
// in-process path.
//
// `--target jvm` still shells out to `lyric --internal-build` (single)
// or `lyric --internal-project-build` (project) because the
// self-hosted JVM bridge does not yet have a multi-package entry
// point.  The F# CLI handlers in `bootstrap/src/Lyric.Cli/Program.fs`
// are kept alive solely for this path; the `--target dotnet` arms of
// those handlers are unreachable from this file's `emit` /
// `emitProject` after the slice 3+ retirements.  They survive until
// the JVM in-process bridge lands.
//
// Environment variables:
//   LYRIC_BIN              — path to the dotnet (or lyric) executable.
//                            Used by the JVM subprocess shim only.
//                            Set automatically by Program.fs before
//                            routing to the self-hosted CLI.
//                            Defaults to "lyric".
//   LYRIC_CLI_DLL          — when the CLI is a dotnet exec DLL rather
//                            than a native binary, this is set to the
//                            DLL path.  JVM subprocess shim only.
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
import Jvm.Bridge as JvmBridge

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
  /// `[package].version` from the manifest, threaded through to the
  /// bridge so the Assembly row + embedded `Lyric.Contract` resource
  /// carry the real semver instead of the bootstrap-grade `0.0.0.0`.
  /// Empty string means "no manifest in scope" (ad-hoc compiles via
  /// the REPL / direct API use), and the bridge falls back to the
  /// legacy default.  See #1364.
  packageVersion: String
  /// Build kind: "lib" for DLL, "exe" for EXE. Controls PE header
  /// characteristics for standalone executables.
  buildKind: String
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
  /// `[package].version` from the manifest, threaded through to the
  /// bridge so the bundled Assembly row + per-package
  /// `Lyric.Contract.<Pkg>` resources carry the real semver.  Empty
  /// string falls back to the bootstrap-grade `0.0.0.0` (#1364).
  packageVersion: String
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

// Walk up from `start` looking for the `lyric-compiler/lyric/` directory.
// Returns "" if no such ancestor is found within 32 hops.
// Used by `emitMsilInProcess` (LYRIC_LOAD_COMPILER=1) to locate compiler
// source packages at runtime.
func walkUpForCompilerDir(start: in String): String {
  if start.length == 0 { return "" }
  var dir = start
  var hop = 0
  while hop < 32 {
    val candidate = Path.join(Path.join(dir, "lyric-compiler"), "lyric")
    if File.dirExists(candidate) { return candidate }
    val parent = Path.dirname(dir)
    if parent.length == 0 or parent == dir { return "" }
    dir = parent
    hop = hop + 1
  }
  ""
}

// Locate the `lyric-stdlib/std/` directory at runtime, then read every
// `.l` source file — both top-level files (the public stdlib surface)
// AND the `_kernel/` subdirectory (extern type / @externTarget kernels
// that the public files reference via `import Std.XHost`).
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
// callers fall back to advisory-only type checking).
//
// MSIL-target only: `_kernel_jvm/` is never loaded here, and the two
// JVM-only kernel files in `_kernel/` (`jvm.l`, `jvm_exception.l`) are
// skipped by name so `Std.Jvm.catch` and its `JvmException` extern type
// don't leak into the .NET symbol table.  A future JVM in-process
// bridge will need its own target-aware source loader.
// No caching yet — re-reads ~30 stdlib files per emit call; see #1907.
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
  // Load `_kernel/` files FIRST so their extern type declarations
  // (`extern type List[T] = "System.Collections.Generic.List`1"`,
  // `Map[K, V]`, `Random`, `HttpClient`, …) reach the typechecker's
  // symbol table before the public files' re-export aliases
  // (`pub alias Random = Std.RandomHost.Random`, etc.).  The
  // self-hosted typechecker's `symTableTryFindOne` is first-in-wins,
  // and `DKTypeAlias` carries no `TypeId`, so registering an alias
  // before its target type makes every reference to the bare name
  // resolve to the alias and fail with T0013 '<name> is not a type'.
  appendLyricFiles(sources, Path.join(stdlibDir, "_kernel"), true)
  // Public surface: every top-level `*.l` file in `lyric-stdlib/std/`.
  appendLyricFiles(sources, stdlibDir, false)
  sources
}

// Read every `*.l` file in `dir` (non-recursive), sort the matches by
// basename for deterministic order, and append their contents to
// `sources`.  When `skipJvmKernel` is true, files whose basename starts
// with `jvm` are skipped — used for `_kernel/` to drop the JVM-only
// `jvm.l` and `jvm_exception.l` files on MSIL builds.
//
// Within-batch sorting matters: `File.listFiles` returns whatever order
// the host filesystem hands back (`Directory.GetFiles` is documented as
// "no guarantee"), so without explicit sorting two machines could
// register stdlib `_kernel/` items in different sequences, and the
// typechecker's first-in-wins `symTableTryFindOne` would pick different
// declarations on each.  Sorting by basename makes the build
// reproducible (#1385).
func appendLyricFiles(
  sources:       in List[String],
  dir:           in String,
  skipJvmKernel: in Bool
): Unit {
  if not File.dirExists(dir) { return }
  val files = match File.listFiles(dir) {
    case Ok(fs)  -> fs
    case Err(_)  -> newList()
  }
  // Filter (`.l` + JVM-kernel skip) then sort by basename.  See
  // `sortPathsByBasename` below for the sort algorithm and rationale.
  val keep: List[String] = newList()
  var fi = 0
  while fi < files.count {
    val f = files[fi]
    if Str.endsWith(f, ".l") {
      val base = Path.basename(f)
      val skip = skipJvmKernel and Str.startsWith(base, "jvm")
      if not skip { keep.add(f) }
    }
    fi = fi + 1
  }
  val sorted = sortPathsByBasename(keep)
  var si = 0
  while si < sorted.count {
    match File.readText(sorted[si]) {
      case Ok(text) -> sources.add(text)
      case Err(_)   -> ()
    }
    si = si + 1
  }
}

// Return a fresh list with `paths` arranged in ascending basename
// order.  Selection sort over a copy of the input, building the output
// one minimum-basename element at a time.  Quadratic but the input is
// small (a few dozen `.l` files per directory); avoids depending on
// `List[T].Insert` or indexer assignment, neither of which the bridge's
// codegen carries dedicated arms for.
func sortPathsByBasename(paths: in List[String]): List[String] {
  val remaining: List[String] = newList()
  var c = 0
  while c < paths.count {
    remaining.add(paths[c])
    c = c + 1
  }
  val sorted: List[String] = newList()
  while remaining.count > 0 {
    // Find the index of the smallest basename in `remaining`.
    var bestIdx = 0
    var bestBase = Path.basename(remaining[0])
    var i = 1
    while i < remaining.count {
      val candidate = Path.basename(remaining[i])
      if candidate < bestBase {
        bestIdx = i
        bestBase = candidate
      }
      i = i + 1
    }
    val picked = remaining[bestIdx]
    sorted.add(picked)
    // Rebuild `remaining` with everything except index `bestIdx`.
    val rest: List[String] = newList()
    var k = 0
    while k < remaining.count {
      if k != bestIdx { rest.add(remaining[k]) }
      k = k + 1
    }
    remaining.clear()
    var rk = 0
    while rk < rest.count {
      remaining.add(rest[rk])
      rk = rk + 1
    }
  }
  sorted
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
// §3b. LYRIC_LOAD_COMPILER helpers
// ─────────────────────────────────────────────────────────────────────────────

// Scan `source` for the first line that starts with "package " and return
// the declared package name.  Returns "" if no such line is found.
// Used by `emitMsilInProcess` (LYRIC_LOAD_COMPILER=1) to build the correct
// `ProjectPackagePayload` name when the declared package name differs from
// the CLI-chosen assembly stem (`stem = stemOf(basename, 2)`).
func extractPackageName(source: in String): String {
  val prefix = "package "
  var pos = 0
  var atLineStart = true
  while pos < source.length {
    if atLineStart and pos + prefix.length <= source.length {
      val candidate = source.substring(pos, prefix.length)
      if candidate == prefix {
        var nameEnd = pos + prefix.length
        while nameEnd < source.length and source.substring(nameEnd, 1) != "\n" {
          nameEnd = nameEnd + 1
        }
        val nameLen = nameEnd - (pos + prefix.length)
        if nameLen > 0 {
          return source.substring(pos + prefix.length, nameLen)
        }
      }
    }
    atLineStart = source.substring(pos, 1) == "\n"
    pos = pos + 1
  }
  ""
}

// Return `source` with every line beginning with "package " or "import "
// removed.  Used to strip the redundant preamble from files 2-N when
// merging a multi-file package (e.g. `Lyric.Parser`'s five `.l` files)
// into a single source string for the bridge.
func stripPackageAndImports(source: in String): String {
  val lines: List[String] = newList()
  var lineStart = 0
  var pos = 0
  while pos <= source.length {
    val atEnd = pos == source.length
    val isNewline = not atEnd and source.substring(pos, 1) == "\n"
    if atEnd or isNewline {
      val lineLen = pos - lineStart
      val line = if lineLen > 0 { source.substring(lineStart, lineLen) } else { "" }
      val skip = Str.startsWith(line, "package ") or Str.startsWith(line, "import ")
      if not skip {
        lines.add(line)
      }
      lineStart = pos + 1
    }
    pos = pos + 1
  }
  Str.joinList("\n", lines)
}

// Combine multiple source files of the same package into one source string.
// File 0 is kept verbatim (its `package` / `import` preamble is canonical);
// files 1-N have their `package` and `import` lines stripped before
// concatenation.  The result is a valid single-file representation of the
// multi-file package.
func joinPackageFiles(fileContents: in List[String]): String {
  if fileContents.count == 0 { return "" }
  if fileContents.count == 1 { return fileContents[0] }
  var combined = fileContents[0]
  var i = 1
  while i < fileContents.count {
    val stripped = stripPackageAndImports(fileContents[i])
    if stripped.length > 0 {
      combined = combined + "\n" + stripped
    }
    i = i + 1
  }
  combined
}

// Build `ProjectPackagePayload` entries for the self-hosted compiler
// packages that a `@test_module` under `lyric-compiler/lyric/` may import:
//   Lyric.Lexer   — single file (`lexer.l`), mandatory
//   Lyric.Parser  — five files combined (`parser/*.l`), optional
//   Lyric.Weaver  — single file (`weaver/weaver.l`), optional
//   Lyric.CfgGate — single file (`cfg_gate.l`), optional
// Returns an empty list if `Lyric.Lexer` cannot be loaded.
func loadCompilerPayloads(compilerDir: in String): List[ProjectPackagePayload] {
  val payloads: List[ProjectPackagePayload] = newList()

  // Lyric.Lexer — mandatory base.
  val lexerPath = Path.join(compilerDir, "lexer.l")
  match File.readText(lexerPath) {
    case Ok(src) -> payloads.add(ProjectPackagePayload(name = "Lyric.Lexer", source = src))
    case Err(_)  -> return payloads
  }

  // Lyric.Parser — five files in deterministic (alphabetical) order.
  // MAINTENANCE NOTE: this list must be kept in sync with `parser/*.l`.
  // A new parser source file added without being appended here will be
  // silently absent from the `LYRIC_LOAD_COMPILER=1` payload — the
  // `compilerPayloads.count > 0` guard still passes because Lexer
  // loads, and consumers fail downstream with confusing missing-symbol
  // diagnostics rather than a clear "incomplete parser" message.
  // Revisit when `Std.FileSystem.listDirectory` is available to
  // enumerate `parser/*.l` directly.
  val parserDir = Path.join(compilerDir, "parser")
  val parserNames: List[String] = newList()
  parserNames.add("parser_ast.l")
  parserNames.add("parser_core.l")
  parserNames.add("parser_cst.l")
  parserNames.add("parser_exprs.l")
  parserNames.add("parser_items.l")
  val parserContents: List[String] = newList()
  var pi = 0
  var parserOk = true
  while pi < parserNames.count and parserOk {
    val fp = Path.join(parserDir, parserNames[pi])
    match File.readText(fp) {
      case Ok(src) -> parserContents.add(src)
      case Err(_)  -> { parserOk = false }
    }
    pi = pi + 1
  }
  if parserOk and parserContents.count > 0 {
    val parserSrc = joinPackageFiles(parserContents)
    payloads.add(ProjectPackagePayload(name = "Lyric.Parser", source = parserSrc))
  }

  // Lyric.Weaver — optional; skip silently if absent.
  val weaverPath = Path.join(Path.join(compilerDir, "weaver"), "weaver.l")
  match File.readText(weaverPath) {
    case Ok(src) -> payloads.add(ProjectPackagePayload(name = "Lyric.Weaver", source = src))
    case Err(_)  -> ()
  }

  // Lyric.CfgGate — single file (`cfg_gate.l`), optional.  Independent
  // of Lexer/Parser/Weaver; only depends on Std.Core/Collections/String.
  // Lets `cfg_gate_self_test.l` resolve `import Lyric.CfgGate` under the
  // `LYRIC_LOAD_COMPILER=1` path.
  val cfgGatePath = Path.join(compilerDir, "cfg_gate.l")
  match File.readText(cfgGatePath) {
    case Ok(src) -> payloads.add(ProjectPackagePayload(name = "Lyric.CfgGate", source = src))
    case Err(_)  -> ()
  }

  // Lyric.CliSuggest — single file (`cli_suggest.l`), optional.  Only depends
  // on Std.Core/Collections.  Lets `cli_suggest_self_test.l` resolve
  // `import Lyric.CliSuggest`.
  val cliSuggestPath = Path.join(compilerDir, "cli_suggest.l")
  match File.readText(cliSuggestPath) {
    case Ok(src) -> payloads.add(ProjectPackagePayload(name = "Lyric.CliSuggest", source = src))
    case Err(_)  -> ()
  }

  // Lyric.Release — single file (`release.l`), optional.  Lets
  // `release_self_test.l` resolve `import Lyric.Release` for the pure
  // entry-detection helpers (packageNameOf / declaresEntryMain).
  val releasePath = Path.join(compilerDir, "release.l")
  match File.readText(releasePath) {
    case Ok(src) -> payloads.add(ProjectPackagePayload(name = "Lyric.Release", source = src))
    case Err(_)  -> ()
  }

  payloads
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
/// `--target dotnet` runs IN-PROCESS via
/// `Msil.Bridge.compileProjectToMsilWithRestoredAndVersion`.  Restored
/// dependencies (loaded + synthesised in `emitProjectInProcess`),
/// active feature flags, and manifest-threaded `[package].version` all
/// flow through the in-process path.  No F# emitter shellout.
///
/// `--target jvm` still shells out to `lyric --internal-project-build`
/// because the self-hosted JVM bridge has no project-level entry point
/// yet.  Will retire when the JVM in-process bridge lands.
@stable(since="0.1")
pub func emitProject(req: in EmitProjectRequest): EmitResult {
  val outDir = Path.dirname(req.outputPath)
  if Str.isNotEmpty(outDir) {
    match File.createDir(outDir) {
      case Ok(_)  -> ()
      case Err(_) -> ()
    }
  }

  match req.target {
    case Dotnet -> emitProjectInProcess(req)
    case Jvm    -> emitProjectJvmViaSubprocess(req)
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
  // entries are "depName\tdllPath"; only the dllPath portion matters
  // for the in-process loader (the leading depName is informational).
  // Load / synthesise failures (DllMissing, NoContractResource,
  // MalformedContract, SynthesisDiagnostics) bubble up as a single
  // `EmitResult` failure — the previous behaviour of silently falling
  // back to the F# `--internal-project-build` subprocess was retired
  // once slice 3 (#1372) proved the self-hosted bridge round-trips
  // restored deps end-to-end.
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
      case Err(e) ->
        return failResult("restored dep '" + dllPath +
                          "' failed to load: " + RP.errorMessage(e))
      case Ok(arts) -> {
        var ai = 0
        while ai < arts.count {
          // Fresh preamble per call so a mutation by `synthesiseArtifact`
          // (intended read-only but not enforced by the type system)
          // can't leak across iterations.
          val preamble: List[Meta.ContractDecl] = newList()
          match RP.synthesiseArtifact(arts[ai], preamble) {
            case Err(e) ->
              return failResult("restored dep '" + dllPath +
                                "' failed to synthesise: " +
                                RP.errorMessage(e))
            case Ok(syn) -> restoredArtifacts.add(syn)
          }
          ai = ai + 1
        }
      }
    }
    ri = ri + 1
  }

  val ok = MsilBridge.compileProjectToMsilWithRestoredAndVersion(
    payloads, req.assemblyName, req.outputPath,
    stdlibSources, req.activeFeatures, req.declaredFeatures,
    restoredArtifacts, req.packageVersion, req.buildKind)
  if ok {
    val okDiags: List[Diagnostic] = newList()
    EmitResult(outputPath = Some(value = req.outputPath), diagnostics = okDiags)
  } else {
    failResult("project build failed (see stderr)")
  }
}

// Subprocess project emit — JVM target only.  Writes each package's
// sources to temp files, builds a tab-encoded spec, and shells to
// `lyric --internal-project-build`.  Will retire when the self-hosted
// JVM bridge gains a project-level entry point.
func emitProjectJvmViaSubprocess(req: in EmitProjectRequest): EmitResult {
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
/// `--target dotnet` runs IN-PROCESS via
/// `Msil.Bridge.compileToMsilWithVersion`.  `--target jvm` still
/// shells out to `lyric --internal-build` because the self-hosted JVM
/// bridge does not yet have a single-file entry point reachable from
/// here.  Will retire when the JVM in-process bridge lands.
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

  match req.target {
    case Dotnet -> emitMsilInProcess(req)
    case Jvm    -> emitJvmInProcess(req)
  }
}

// In-process single-source JVM emit — direct call into the self-hosted
// `Jvm.Bridge.compileToJarBundled` (#1611).  Replaces the legacy
// `--internal-build --target jvm` subprocess hop into the F# emitter, whose
// stage-0 parser can't handle self-hosted-only surface (e.g. the bitwise
// integer methods).  The bundled entry compiles the user package plus the
// transitive closure of its stdlib imports into one runnable JAR, so a
// program that calls stdlib functions (e.g. `Std.Testing` asserts) links at
// runtime.  Diagnostics land on stderr via `Lyric.DiagnosticUtil`, matching
// the MSIL in-process path.
func emitJvmInProcess(req: in EmitRequest): EmitResult {
  val stdlibSources = findStdlibSources()
  val pkgName = extractPackageName(req.source)
  val name = if pkgName.length > 0 { pkgName } else { req.assemblyName }
  val ok = JvmBridge.compileToJarBundled(req.source, req.outputPath, name, stdlibSources)
  if ok {
    val okDiags: List[Diagnostic] = newList()
    EmitResult(outputPath = Some(value = req.outputPath), diagnostics = okDiags)
  } else {
    failResult("JVM compilation failed (see stderr)")
  }
}

// In-process MSIL emit — direct call into `Msil.Bridge.compileToMsil`.
// Diagnostics from the bridge land on **stderr** (#893) via
// `Lyric.DiagnosticUtil`, matching the F# bootstrap CLI convention so
// IDE integrations, CI scripts, and `2>errors.txt` redirects continue
// to work the same way they did with the old subprocess path.  The
// bridge returns true on success and false on any error (parse,
// type-check, mode-check, codegen).
//
// When `LYRIC_LOAD_COMPILER=1` is set, switches to the multi-package
// bridge path: loads `Lyric.Lexer`, `Lyric.Parser`, and `Lyric.Weaver`
// from `lyric-compiler/lyric/` and compiles together with the requested
// source so @test_module files in that tree can import those packages
// (issue #1324).
func emitMsilInProcess(req: in EmitRequest): EmitResult {
  // Auto-resolve `lyric-stdlib/std/*.l` so the bridge's typechecker sees
  // stdlib types at typecheck.  Mirrors the F# bootstrap shim
  // `Lyric.Cli.SelfHostedBridge.findStdlibSources` — see the parallel
  // comment in `emitProjectInProcess` for the rationale.
  val stdlibSources = findStdlibSources()
  val loadCompiler = Environment.getVarOrDefault("LYRIC_LOAD_COMPILER", "")
  if loadCompiler == "1" {
    var compilerDir = walkUpForCompilerDir(Environment.appBaseDirectory())
    if compilerDir.length == 0 {
      compilerDir = walkUpForCompilerDir(Environment.currentDirectory())
    }
    if compilerDir.length > 0 {
      val compilerPayloads = loadCompilerPayloads(compilerDir)
      if compilerPayloads.count > 0 {
        val testPkgName = extractPackageName(req.source)
        val pkgName = if testPkgName.length > 0 { testPkgName } else { req.assemblyName }
        val allPayloads: List[ProjectPackagePayload] = newList()
        var ci = 0
        while ci < compilerPayloads.count {
          allPayloads.add(compilerPayloads[ci])
          ci = ci + 1
        }
        allPayloads.add(ProjectPackagePayload(name = pkgName, source = req.source))
        val noFeatures: List[String] = newList()
        val noArtifacts: List[SynthesisedArtifact] = newList()
        val ok = MsilBridge.compileProjectToMsilWithRestoredAndVersion(
          allPayloads, req.assemblyName, req.outputPath,
          stdlibSources, noFeatures, noFeatures, noArtifacts, req.packageVersion, req.buildKind)
        if ok {
          val okDiags: List[Diagnostic] = newList()
          return EmitResult(outputPath = Some(value = req.outputPath), diagnostics = okDiags)
        } else {
          return failResult("MSIL compilation failed (see stderr)")
        }
      }
    }
  }
  val ok = MsilBridge.compileToMsilWithVersion(
    req.source, req.outputPath, stdlibSources, req.packageVersion, req.buildKind)
  if ok {
    val okDiags: List[Diagnostic] = newList()
    EmitResult(outputPath = Some(value = req.outputPath), diagnostics = okDiags)
  } else {
    failResult("MSIL compilation failed (see stderr)")
  }
}

// Subprocess single-file emit — JVM target only.  Writes `req.source`
// to a temp file and shells to `lyric --internal-build`, which the F#
// bootstrap CLI dispatches through `Program.fs::internalBuild`.  Will
// retire when the self-hosted JVM bridge gains a reachable single-file
// entry point.
func emitJvmViaSubprocess(req: in EmitRequest): EmitResult {
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
