//! lyric/emitter.l — Lyric.Emitter bootstrap package.
//!
//! Implements the `emit(req): EmitResult` contract that cli.l and repl.l
//! depend on.
//!
//! `--target dotnet` compilation — both single-source and multi-package
//! — runs IN-PROCESS via `Msil.Bridge.compileToMsilWithVersion` /
//! `compileProjectToMsilWithRestoredAndVersion`.  No subprocess hop, no
//! F# emitter touched at runtime.  Restored-deps, feature flags, and
//! manifest-threaded `[package].version` all flow through the same
//! in-process path.
//!
//! `--target jvm` still shells out to `lyric --internal-build` (single)
//! or `lyric --internal-project-build` (project) because the
//! self-hosted JVM bridge does not yet have a multi-package entry
//! point.  The F# CLI handlers in `bootstrap/src/Lyric.Cli/Program.fs`
//! are kept alive solely for this path; the `--target dotnet` arms of
//! those handlers are unreachable from this file's `emit` /
//! `emitProject` after the slice 3+ retirements.  They survive until
//! the JVM in-process bridge lands.
//!
//! Environment variables:
//!   LYRIC_BIN              — path to the dotnet (or lyric) executable.
//!                            Used by the JVM subprocess shim only.
//!                            Set automatically by Program.fs before
//!                            routing to the self-hosted CLI.
//!                            Defaults to "lyric".
//!   LYRIC_CLI_DLL          — when the CLI is a dotnet exec DLL rather
//!                            than a native binary, this is set to the
//!                            DLL path.  JVM subprocess shim only.
//!                            Program.fs populates it from
//!                            Assembly.GetEntryAssembly.
//!
//! Thread safety: emit() has no shared mutable state; it is safe to call
//! concurrently.
@runtime_checked
package Lyric.Emitter

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
// before Path so Path.join/2 wins over Str.join/2
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
  source: String
  assemblyName: String
  outputPath: String
  target: CompileTarget
  /// `[package].version` from the manifest, threaded through to the
  /// bridge so the Assembly row + embedded `Lyric.Contract` resource
  /// carry the real semver instead of the bootstrap-grade `0.0.0.0`.
  /// Empty string means "no manifest in scope" (ad-hoc compiles via
  /// the REPL / direct API use), and the bridge falls back to the
  /// legacy default.  See #1364.
  packageVersion: String
}

pub record EmitResult {
  outputPath: Option[String]
  diagnostics: List[Diagnostic]
}

/// Per-package source feed for `emitProject`.  Each package's `sources` list
/// holds the `.l` file contents in deterministic order (multi-file packages
/// should already be resolved by the caller).
pub record ProjectPackage {
  name: String
  sources: List[String]
}

pub record EmitProjectRequest {
  packages: List[ProjectPackage]
  assemblyName: String
  outputPath: String
  target: CompileTarget
  /// Restored dependency DLL paths.  Each entry is "depName\tdllPath".
  /// Written to the spec file as `DEP\tdepName\tdllPath` lines.
  restoredDllPaths: List[String]
  /// Active feature flags for @cfg erasure.  Each entry is a feature name.
  /// Written to the spec file as `FEATURE\t<name>` lines.
  activeFeatures: List[String]
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
}

func cliShellExe(): String {
  CliShell.lyrExe()
}

func cliShellArgs(subcmd: in List[String]): List[String] {
  CliShell.lyrArgs(subcmd)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Temporary source file
// ─────────────────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

// Walk up from `start` looking for a directory whose direct child
// `lyric-stdlib/std/` exists.  Returns "" if no such ancestor is found
// within 32 hops.  Used by `findStdlibSources` to try multiple anchor
// points (app-base directory first, then CWD).
func walkUpForStdlib(start: in String): String {
  if start.length == 0 {
    return ""
  }
  var dir = start
  var hop = 0
  while hop < 32 {
    val candidate = Path.join(Path.join(dir, "lyric-stdlib"), "std")
    if File.dirExists(candidate) {
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

// Walk up from `start` looking for the `lyric-compiler/lyric/` directory.
// Returns "" if no such ancestor is found within 32 hops.
// Used by `emitMsilInProcess` (LYRIC_LOAD_COMPILER=1) to locate compiler
// source packages at runtime.
func walkUpForCompilerDir(start: in String): String {
  if start.length == 0 {
    return ""
  }
  var dir = start
  var hop = 0
  while hop < 32 {
    // Return the `lyric-compiler/` root (not `lyric-compiler/lyric/`) so the
    // loader's recursive scan covers every backend subtree — `lyric/`
    // (`Lyric.*`), `msil/` (`Msil.*`), and `jvm/` (`Jvm.*`).  A test that
    // imports `Msil.MetadataReader` / `Msil.Bridge` / `Lyric.Emitter` then
    // resolves its full compiler-package closure (#1488 compiler-internal tests).
    val candidate = Path.join(dir, "lyric-compiler")
    if File.dirExists(candidate) {
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
  if stdlibDir.length == 0 {
    return sources
  }
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
func appendLyricFiles(sources: in List[String], dir: in String, skipJvmKernel: in Bool): Unit {
  if not File.dirExists(dir) {
    return
  }
  val files = match File.listFiles(dir) { case Ok(fs) -> fs; case Err(_) -> newList() }
  // Filter (`.l` + JVM-kernel skip) then sort by basename.  See
  // `sortPathsByBasename` below for the sort algorithm and rationale.
  val keep: List[String] = newList()
  var fi = 0
  while fi < files.count {
    val f = files[fi]
    if Str.endsWith(f, ".l") {
      val base = Path.basename(f)
      val skip = skipJvmKernel and Str.startsWith(base, "jvm")
      if not skip {
        keep.add(f)
      }
    }
    fi = fi + 1
  }
  val sorted = sortPathsByBasename(keep)
  var si = 0
  while si < sorted.count {
    match File.readText(sorted[si]) {
      case Ok(text) -> sources.add(text)
      case Err(_) -> ()
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
      if k != bestIdx {
        rest.add(remaining[k])
      }
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
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  // ignore; dir may already exist
  val path = Path.join(dir, assemblyName + "__src.l")
  match File.writeText(path, source) {
    case Ok(_) -> Ok(value = path)
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
  var seenPackage = false
  while pos <= source.length {
    val atEnd = pos == source.length
    val isNewline = not atEnd and source.substring(pos, 1) == "\n"
    if atEnd or isNewline {
      val lineLen = pos - lineStart
      val line = if lineLen > 0 { source.substring(lineStart, lineLen) } else { "" }
      // Skip `package` / `import` lines (each file re-declares them) and
      // `//!` module-doc header lines.  A multi-file package's bodies are
      // concatenated into one source; a `//!` is only valid *before*
      // `package`, so any `//!` left in a stripped body would land
      // mid-stream once concatenated and parse as `P0040` "expected an
      // item declaration".  The on-disk files keep their `//!`; only this
      // in-memory concatenation drops it.
      //
      // The same applies to a **file-level annotation** before `package`
      // (`@runtime_checked`, `@proof_required`, …): it annotates the module,
      // so once `package` is stripped it would dangle and parse as `P0040`.
      // Item-level annotations (after `package`) must be kept, so only `@`
      // lines seen *before* the package decl are dropped.
      val isPackage = Str.startsWith(line, "package ")
      val skip = isPackage or Str.startsWith(line, "import ") or Str.startsWith(line, "//!") or
        (not seenPackage and Str.startsWith(line, "@"))
      if isPackage {
        seenPackage = true
      }
      if not skip {
        lines.add(line)
      }
      lineStart = pos + 1
    }
    pos = pos + 1
  }
  Str.joinList("\n", lines)
}

// Given an `import ...` line, return the imported package path (the
// segment before any ` as <alias>` suffix).  Returns "" for any line
// that is not an import.  E.g. `import Lyric.ContractMeta as Meta` ->
// "Lyric.ContractMeta"; `import Std.Core` -> "Std.Core".
func importLinePackage(line: in String): String {
  val trimmed = Str.trim(line)
  val prefix = "import "
  if not Str.startsWith(trimmed, prefix) {
    return ""
  }
  val rest = Str.trim(trimmed.substring(prefix.length))
  // The package path is the first whitespace-delimited token; an ` as
  // <alias>` clause (or a trailing comment) follows a space.
  val parts = Str.split(rest, " ")
  if parts.length == 0 {
    return ""
  }
  Str.trim(parts[0])
}

// Append every distinct raw `import ...` line in `source` to `acc`
// (preserving the source text verbatim, including any ` as <alias>`
// clause).  Used to union the import preambles across the several
// source files that make up a multi-file compiler package.
func collectImportLines(source: in String, acc: in List[String]) {
  val lines = Str.split(source, "\n")
  var i = 0
  while i < lines.length {
    val line = lines[i]
    val trimmed = Str.trim(line)
    if Str.startsWith(trimmed, "import ") {
      var seen = false
      var j = 0
      while j < acc.count {
        if acc[j] == trimmed {
          seen = true
        }
        j = j + 1
      }
      if not seen {
        acc.add(trimmed)
      }
    }
    i = i + 1
  }
}

// Linear lookup of `s` in `list`; returns the index or -1.
func indexOfString(list: in List[String], s: in String): Int {
  var i = 0
  while i < list.count {
    if list[i] == s {
      return i
    }
    i = i + 1
  }
  -1
}

// True when `pkg` is one of the self-hosted compiler namespaces that
// `loadCompilerPayloads` discovers from disk (as opposed to a `Std.*`
// package, which the bridge resolves from `lyric-stdlib/std/`).
func isCompilerPackage(pkg: in String): Bool {
  Str.startsWith(pkg, "Lyric.") or Str.startsWith(pkg, "Msil.") or Str.startsWith(pkg, "Jvm.")
}

// Discover the self-hosted compiler packages under `compilerDir` and
// return `ProjectPackagePayload` entries for exactly the import-closure
// of `testSource` — the packages it `import`s, plus their transitive
// compiler-package dependencies.  Each package's several source files
// are merged into one payload (union of import preambles + each file
// body with its `package`/`import` lines stripped), so a multi-file
// package such as `Lyric.Parser` or `Lyric.TypeChecker` resolves
// without any hand-maintained file list.
//
// `*_self_test.l` / `*_ci_test.l` files are excluded from discovery
// (they are programs, not library packages, and the module under test
// is added separately by the caller).  Returns an empty list if the
// directory cannot be read or `Lyric.Lexer` is absent.
func loadCompilerPayloads(compilerDir: in String, testSource: in String): List[ProjectPackagePayload] {
  val empty: List[ProjectPackagePayload] = newList()

  val files = match File.listFilesRecursive(compilerDir) { case Ok(fs) -> fs; case Err(_) -> return empty }

  // Pass 1: build a registry of every compiler package, grouping each
  // package's source files (sorted for determinism) into parallel
  // lists: name, accumulated body text, and the union of import lines.
  val regNames: List[String] = newList()
  val regBodies: List[String] = newList()
  val regImports: List[List[String]] = newList()

  val sortedFiles = sortStrings(files)
  var fi = 0
  while fi < sortedFiles.count {
    val path = sortedFiles[fi]
    fi = fi + 1
    if not Str.endsWith(path, ".l") {
      continue
    }
    if Str.endsWith(path, "_self_test.l") or Str.endsWith(path, "_ci_test.l") {
      continue
    }
    val src = match File.readText(path) { case Ok(s) -> s; case Err(_) -> "" }
    if Str.length(src) == 0 {
      continue
    }
    val pkg = extractPackageName(src)
    if Str.length(pkg) == 0 or not isCompilerPackage(pkg) {
      continue
    }

    var idx = indexOfString(regNames, pkg)
    if idx < 0 {
      regNames.add(pkg)
      regBodies.add("")
      val imps: List[String] = newList()
      regImports.add(imps)
      idx = regNames.count - 1
    }
    val body = stripPackageAndImports(src)
    val prior = regBodies[idx]
    regBodies[idx] = if Str.length(prior) == 0 { body } else { prior + "\n" + body }
    collectImportLines(src, regImports[idx])
  }

  // `Lyric.Lexer` is the mandatory base — every compiler package depends
  // on it transitively.  Its absence means the discovery root is wrong.
  if indexOfString(regNames, "Lyric.Lexer") < 0 {
    return empty
  }

  // Pass 2: compute the import-closure of `testSource` over the registry.
  val needed: List[String] = newList()
  val queue: List[String] = newList()
  val testImports: List[String] = newList()
  collectImportLines(testSource, testImports)
  var qi = 0
  while qi < testImports.count {
    val p = importLinePackage(testImports[qi])
    if isCompilerPackage(p) and indexOfString(regNames, p) >= 0 {
      queue.add(p)
    }
    qi = qi + 1
  }
  while queue.count > 0 {
    val name = queue[queue.count - 1]
    queue.removeAt(queue.count - 1)
    if indexOfString(needed, name) >= 0 {
      continue
    }
    val ridx = indexOfString(regNames, name)
    if ridx < 0 {
      continue
    }
    needed.add(name)
    val imps = regImports[ridx]
    var ii = 0
    while ii < imps.count {
      val dep = importLinePackage(imps[ii])
      if isCompilerPackage(dep) and indexOfString(regNames, dep) >= 0 and indexOfString(needed, dep) < 0 {
        queue.add(dep)
      }
      ii = ii + 1
    }
  }

  // Pass 3: topologically order the needed packages so a dependency is
  // always emitted before the package that imports it.  The bridge's
  // codegen threads one shared `CodegenCtx` across packages in list
  // order (phase 3 token pre-scan), so a dependent compiled before its
  // dependency would reference not-yet-allocated TypeRef / MemberRef
  // rows and emit invalid IL (a runtime `InvalidProgramException`).
  // Repeated "emit when all in-closure deps are already emitted" passes
  // suffice for the acyclic compiler-package graph; any residue from an
  // unexpected cycle is appended verbatim so we never loop forever.
  val ordered: List[String] = newList()
  var madeProgress = true
  while ordered.count < needed.count and madeProgress {
    madeProgress = false
    var oi = 0
    while oi < needed.count {
      val name = needed[oi]
      oi = oi + 1
      if indexOfString(ordered, name) >= 0 {
        continue
      }
      val ridx = indexOfString(regNames, name)
      val imps = regImports[ridx]
      var depsReady = true
      var di2 = 0
      while di2 < imps.count {
        val dep = importLinePackage(imps[di2])
        if indexOfString(needed, dep) >= 0 and indexOfString(ordered, dep) < 0 {
          depsReady = false
        }
        di2 = di2 + 1
      }
      if depsReady {
        ordered.add(name)
        madeProgress = true
      }
    }
  }
  var fi2 = 0
  while fi2 < needed.count {
    if indexOfString(ordered, needed[fi2]) < 0 {
      ordered.add(needed[fi2])
    }
    fi2 = fi2 + 1
  }

  // Pass 4: materialise a payload per package in dependency order —
  // `package <name>`, the unioned import preamble, then merged bodies.
  val payloads: List[ProjectPackagePayload] = newList()
  var ni = 0
  while ni < ordered.count {
    val name = ordered[ni]
    val ridx = indexOfString(regNames, name)
    val combined = "package " + name + "\n" + Str.joinList("\n", regImports[ridx]) + "\n" + regBodies[ridx]
    payloads.add(ProjectPackagePayload(name = name, source = combined))
    ni = ni + 1
  }
  payloads
}

// ─────────────────────────────────────────────────────────────────────────────
// §3b. Per-package closure emit (#2592 stage-2: self-hosted stdlib bundle).
// ─────────────────────────────────────────────────────────────────────────────
// The self-hosted analogue of the F# emitter's auto-resolve: compile a driver's
// transitive `Std.*` import closure into SEPARATE per-package DLLs
// (`Lyric.Stdlib.<X>.dll`), in dependency order, in one output directory.  Each
// package is emitted as its own assembly via `emitProject`; the MSIL bridge
// resolves stdlib imports from source for type-checking and emits cross-assembly
// references by assembly name, so a dependency emitted earlier into the same
// directory satisfies the dependent at runtime — no restored-dep threading is
// needed for stdlib.  This produces the per-package layout the toolchain links,
// including packages the F# stage-0 emitter cannot compile (e.g. `Std.Sort`,
// whose typed-lambda generics defeat the F# codegen).  Compiler-package
// (`Lyric.*` / `Msil.*`) per-package emit, which needs restored-dep threading,
// is a follow-up.
func isStdlibPackage(pkg: in String): Bool {
  Str.startsWith(pkg, "Std.") or pkg == "Std"
}

// `Std.X` → `Lyric.Stdlib.X`; multi-segment tails join without dots
// (`Std.Testing.Mocking` → `Lyric.Stdlib.TestingMocking`), matching the F#
// emitter's `assemblyName` derivation so the output is a drop-in for the
// existing per-package DLLs.  `--target jvm` appends `.Jvm`.
pub func perPackageAssemblyName(pkg: in String, target: in CompileTarget): String {
  val segs = Str.split(pkg, ".")
  var tail = ""
  var i = 1
  while i < segs.length {
    tail = tail + segs[i]
    i = i + 1
  }
  val base = if segs.length > 0 and segs[0] == "Std" {
    "Lyric.Stdlib." + tail
  } else if segs.length > 0 {
    "Lyric." + segs[0] + "." + tail
  } else {
    "Lyric.Unknown"
  }
  match target {
    case Jvm -> base + ".Jvm"
    case Dotnet -> base
  }
}

// Locate `lyric-stdlib/std/` the same way `findStdlibSources` does: explicit
// `$LYRIC_STD_PATH`, else walk up from the binary's base dir, else from the CWD.
func locateStdlibDir(): String {
  val envOverride = Environment.getVarOrDefault("LYRIC_STD_PATH", "")
  if envOverride.length > 0 and File.dirExists(envOverride) {
    return envOverride
  }
  var dir = walkUpForStdlib(Environment.appBaseDirectory())
  if dir.length == 0 {
    dir = walkUpForStdlib(Environment.currentDirectory())
  }
  dir
}

// Discover the `Std.*` packages under `stdlibDir` and return
// `ProjectPackagePayload` entries for exactly the import-closure of
// `entrySource`, in dependency order.  Mirrors `loadCompilerPayloads` but for
// stdlib: multi-file packages are merged by their declared `package` name, and
// the JVM-only kernel files (`_kernel_jvm/`, `_kernel/jvm*.l`) are skipped on the
// .NET target so they don't collide with their `_kernel/` counterparts.
func loadStdlibPayloads(stdlibDir: in String, entrySource: in String): List[ProjectPackagePayload] {
  val empty: List[ProjectPackagePayload] = newList()
  val files = match File.listFilesRecursive(stdlibDir) { case Ok(fs) -> fs; case Err(_) -> return empty }

  val regNames: List[String] = newList()
  val regBodies: List[String] = newList()
  val regImports: List[List[String]] = newList()

  val sortedFiles = sortStrings(files)
  var fi = 0
  while fi < sortedFiles.count {
    val path = sortedFiles[fi]
    fi = fi + 1
    if not Str.endsWith(path, ".l") {
      continue
    }
    if Str.endsWith(path, "_self_test.l") or Str.endsWith(path, "_ci_test.l") {
      continue
    }
    // .NET target: drop the JVM-only kernel files (they declare the same
    // `Std.*Host` packages as `_kernel/` and would otherwise merge / collide).
    if Str.contains(path, "_kernel_jvm") {
      continue
    }
    val base = Path.basename(path)
    if Str.startsWith(base, "jvm") {
      continue
    }
    val src = match File.readText(path) { case Ok(s) -> s; case Err(_) -> "" }
    if Str.length(src) == 0 {
      continue
    }
    val pkg = extractPackageName(src)
    if Str.length(pkg) == 0 or not isStdlibPackage(pkg) {
      continue
    }
    var idx = indexOfString(regNames, pkg)
    if idx < 0 {
      regNames.add(pkg)
      regBodies.add("")
      val imps: List[String] = newList()
      regImports.add(imps)
      idx = regNames.count - 1
    }
    val body = stripPackageAndImports(src)
    val prior = regBodies[idx]
    regBodies[idx] = if Str.length(prior) == 0 { body } else { prior + "\n" + body }
    collectImportLines(src, regImports[idx])
  }

  // Import-closure of `entrySource` over the registry (Std.* only).
  val needed: List[String] = newList()
  val queue: List[String] = newList()
  val entryImports: List[String] = newList()
  collectImportLines(entrySource, entryImports)
  var qi = 0
  while qi < entryImports.count {
    val p = importLinePackage(entryImports[qi])
    if isStdlibPackage(p) and indexOfString(regNames, p) >= 0 {
      queue.add(p)
    }
    qi = qi + 1
  }
  while queue.count > 0 {
    val name = queue[queue.count - 1]
    queue.removeAt(queue.count - 1)
    if indexOfString(needed, name) >= 0 {
      continue
    }
    val ridx = indexOfString(regNames, name)
    if ridx < 0 {
      continue
    }
    needed.add(name)
    val imps = regImports[ridx]
    var ii = 0
    while ii < imps.count {
      val dep = importLinePackage(imps[ii])
      if isStdlibPackage(dep) and indexOfString(regNames, dep) >= 0 and indexOfString(needed, dep) < 0 {
        queue.add(dep)
      }
      ii = ii + 1
    }
  }

  // Topologically order so a dependency is emitted before its dependent.
  val ordered: List[String] = newList()
  var madeProgress = true
  while ordered.count < needed.count and madeProgress {
    madeProgress = false
    var oi = 0
    while oi < needed.count {
      val name = needed[oi]
      oi = oi + 1
      if indexOfString(ordered, name) >= 0 {
        continue
      }
      val ridx = indexOfString(regNames, name)
      val imps = regImports[ridx]
      var depsReady = true
      var di2 = 0
      while di2 < imps.count {
        val dep = importLinePackage(imps[di2])
        if indexOfString(needed, dep) >= 0 and indexOfString(ordered, dep) < 0 {
          depsReady = false
        }
        di2 = di2 + 1
      }
      if depsReady {
        ordered.add(name)
        madeProgress = true
      }
    }
  }
  var fi2 = 0
  while fi2 < needed.count {
    if indexOfString(ordered, needed[fi2]) < 0 {
      ordered.add(needed[fi2])
    }
    fi2 = fi2 + 1
  }

  val payloads: List[ProjectPackagePayload] = newList()
  var ni = 0
  while ni < ordered.count {
    val name = ordered[ni]
    val ridx = indexOfString(regNames, name)
    val combined = "package " + name + "\n" + Str.joinList("\n", regImports[ridx]) + "\n" + regBodies[ridx]
    payloads.add(ProjectPackagePayload(name = name, source = combined))
    ni = ni + 1
  }
  payloads
}

/// Compile `entrySource`'s transitive `Std.*` import closure into separate
/// per-package `Lyric.Stdlib.<X>.dll` assemblies in `outDir`, in dependency
/// order.  Returns the first failing package's diagnostics, or an empty
/// success result once every package emits.  This is the linchpin of the
/// self-hosted stdlib bundle (#2592 stage-2): it produces, via the self-hosted
/// emitter, the per-package DLLs the toolchain links — including packages the
/// F# stage-0 emitter cannot compile.
pub func emitPerPackageClosure(entrySource: in String, outDir: in String, target: in CompileTarget): EmitResult {
  match File.createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  val stdlibDir = locateStdlibDir()
  if stdlibDir.length == 0 {
    return failResult("per-package emit: could not locate lyric-stdlib/std")
  }
  val payloads = loadStdlibPayloads(stdlibDir, entrySource)
  if payloads.count == 0 {
    return failResult("per-package emit: no Std.* packages in the import closure")
  }
  var pi = 0
  while pi < payloads.count {
    val payload = payloads[pi]
    pi = pi + 1
    val asmName = perPackageAssemblyName(payload.name, target)
    val outPath = Path.join(outDir, asmName + ".dll")
    val pkgs: List[ProjectPackage] = newList()
    val srcs: List[String] = newList()
    srcs.add(payload.source)
    pkgs.add(ProjectPackage(name = payload.name, sources = srcs))
    val noFeatures: List[String] = newList()
    val noRestored: List[String] = newList()
    val req = EmitProjectRequest(
      packages = pkgs,
      assemblyName = asmName,
      outputPath = outPath,
      target = target,
      restoredDllPaths = noRestored,
      activeFeatures = noFeatures,
      declaredFeatures = noFeatures,
      packageVersion = "0.1.0"
    )
    val res = emitProject(req)
    match res.outputPath {
      case None -> return failResult("per-package emit: package '" + payload.name + "' failed to build")
      case Some(_) -> ()
    }
  }
  EmitResult(outputPath = Some(value = outDir), diagnostics = newList())
}

// #2364 Stage 5: compute the restored-DLL list for a `@test_module` that imports
// `Lyric.*` compiler packages.  Reuses `loadCompilerPayloads` to resolve the
// transitive compiler-package import closure from source, then maps each closure
// package to its already-compiled DLL in `libDir` (the F#-built compiler DLLs are
// named `Lyric.<package>.dll`, e.g. `Lyric.Lyric.Weaver.dll`).  Returns
// "<pkg>\t<dllPath>" entries (the `restoredDllPaths` encoding); empty when the
// test imports no compiler packages or the compiler source / libDir is absent.
// This is the linked-DLL replacement for the `LYRIC_LOAD_COMPILER` recompile path:
// the test links the compiler DLLs as restored deps instead of recompiling them.
pub func compilerClosureDllPaths(testSource: in String, libDir: in String): List[String] {
  val dlls: List[String] = newList()
  if libDir.length == 0 {
    return dlls
  }
  var compilerDir = walkUpForCompilerDir(Environment.appBaseDirectory())
  if compilerDir.length == 0 {
    compilerDir = walkUpForCompilerDir(Environment.currentDirectory())
  }
  if compilerDir.length == 0 {
    return dlls
  }
  val payloads = loadCompilerPayloads(compilerDir, testSource)
  var i = 0
  while i < payloads.count {
    val pkg = payloads[i].name
    val dll = Path.join(libDir, "Lyric." + pkg + ".dll")
    if File.fileExists(dll) {
      dlls.add(pkg + "\t" + dll)
    }
    i = i + 1
  }
  dlls
}

// Selection sort over a copy of `xs` — small inputs (the compiler-tree
// file list), so an O(n^2) sort is fine and keeps the discovery order
// deterministic across platforms regardless of `listFilesRecursive`'s
// traversal order.
func sortStrings(xs: in List[String]): List[String] {
  if xs.count == 0 {
    return newList()
  }

  // Pre-filter: separate non-empty strings from empty ones to avoid
  // comparison issues. Empty strings sort to end.
  val nonEmpty: List[String] = newList()
  val empty: List[String] = newList()
  var c = 0
  while c < xs.count {
    val s = xs[c]
    if Str.isNotEmpty(s) {
      nonEmpty.add(s)
    } else {
      empty.add(s)
    }
    c = c + 1
  }

  if nonEmpty.count == 0 {
    return empty
  }

  // Sort non-empty strings via selection sort.
  val remaining: List[String] = newList()
  var nc = 0
  while nc < nonEmpty.count {
    remaining.add(nonEmpty[nc])
    nc = nc + 1
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

  // Append empty strings at the end.
  var ec = 0
  while ec < empty.count {
    sorted.add(empty[ec])
    ec = ec + 1
  }
  sorted
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. emit
// ─────────────────────────────────────────────────────────────────────────────
func failResult(msg: in String): EmitResult {
  val sp = pointSpan(initialPosition())
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
@stable(since = "0.1")
pub func emitProject(req: in EmitProjectRequest): EmitResult {
  val outDir = Path.dirname(req.outputPath)
  if Str.isNotEmpty(outDir) {
    match File.createDir(outDir) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
  }

  match req.target {
    case Dotnet -> emitProjectInProcess(req)
    case Jvm -> emitProjectJvmViaSubprocess(req)
  }
}

// True when a contract decl kind declares a *type* (vs a function).  Such
// decls are what a sibling package's signatures may reference, so they make
// up the cross-DLL validation preamble.
func isTypeDeclKind(kind: in String): Bool {
  kind == "record" or kind == "union" or kind == "enum" or kind == "extern_type" or kind == "interface" or
    kind == "alias" or
    kind == "distinct" or
    kind == "opaque" or
    kind == "type"
}

// Collect the type-declaring decls of every restored artifact whose package
// is NOT `selfPkg`, de-duplicated by declaration name.  Names that `selfPkg`
// itself declares are excluded too: a shared `extern type` (e.g. several
// stdlib packages each declaring `TextWriter`) would otherwise appear both in
// the preamble and in the target's own decls, producing a `duplicate name`
// error when the synthesised source re-type-checks.  Used as the validation
// preamble when synthesising one restored package so its signatures can name
// sibling packages' types.
// Return the leading identifier of `s` — the prefix up to the first
// non-identifier delimiter.  Used to pull a case name out of the tail of
// a `case `-split fragment (e.g. "Header; case Cookie }" -> "Header").
func leadingIdent(s: in String): String {
  var cut = Str.length(s)
  val delims: List[String] = newList()
  delims.add("(")
  delims.add(" ")
  delims.add(";")
  delims.add(",")
  delims.add("}")
  delims.add("\n")
  delims.add("\t")
  var di = 0
  while di < delims.count {
    match Str.indexOf(s, delims[di]) {
      case Some(idx) -> if idx < cut { cut = idx }
      case None -> ()
    }
    di = di + 1
  }
  Str.substring(s, 0, cut)
}

// Extract the case names declared by an enum/union `repr` string (the
// identifiers following each `case ` keyword).  Enum/union cases are
// registered as package-level symbols, so when several packages are
// flattened into one synthesised validation source these names can
// collide with a sibling package's type of the same name (#2514 —
// `Web.OpenApi.ParameterLocation.Header` vs `Web.Header`).  Seeding the
// preamble's dedup set with the synthesised package's own case names lets
// `siblingTypeDecls` drop the colliding sibling type, which the package's
// signatures never reference in type position anyway.
func collectCaseNames(repr: in String): List[String] {
  val names: List[String] = newList()
  val parts = Str.split(repr, "case ")
  var i = 1
  while i < parts.length {
    val nm = leadingIdent(parts[i])
    if Str.length(nm) > 0 {
      names.add(nm)
    }
    i = i + 1
  }
  names
}

func siblingTypeDecls(arts: in List[RestoredArtifact], selfPkg: in String): List[Meta.ContractDecl] {
  val acc: List[Meta.ContractDecl] = newList()
  val seen: List[String] = newList()
  // Seed the seen-set with every name `selfPkg` declares so they are never
  // re-emitted into its own validation preamble.
  var sa = 0
  while sa < arts.count {
    val art = arts[sa]
    sa = sa + 1
    if art.packageName != selfPkg {
      continue
    }
    val ownDecls = art.contract.decls
    var oi = 0
    while oi < ownDecls.count {
      val od = ownDecls[oi]
      if indexOfString(seen, od.name) < 0 {
        seen.add(od.name)
      }
      // Also exclude any sibling type whose name matches one of this
      // package's enum/union case names: the case name is a package-level
      // symbol in the flattened synthesised source and would collide with
      // the sibling type (#2514).
      if od.kind == "enum" or od.kind == "union" {
        val caseNames = collectCaseNames(od.repr)
        var ci = 0
        while ci < caseNames.count {
          if indexOfString(seen, caseNames[ci]) < 0 {
            seen.add(caseNames[ci])
          }
          ci = ci + 1
        }
      }
      oi = oi + 1
    }
  }
  var ai = 0
  while ai < arts.count {
    val art = arts[ai]
    ai = ai + 1
    if art.packageName == selfPkg {
      continue
    }
    val decls = art.contract.decls
    var di = 0
    while di < decls.count {
      val d = decls[di]
      di = di + 1
      if not isTypeDeclKind(d.kind) {
        continue
      }
      if indexOfString(seen, d.name) >= 0 {
        continue
      }
      seen.add(d.name)
      acc.add(d)
    }
  }
  acc
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
      if si > 0 {
        combined = combined + "\n"
      }
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
  // Pass 1: load every restored DLL into its `RestoredArtifact`s (a
  // bundled DLL yields one per contained package).  Defer synthesis so
  // we can first gather the union of all packages' type declarations —
  // the cross-DLL preamble.
  val allArts: List[RestoredArtifact] = newList()
  var ri = 0
  while ri < req.restoredDllPaths.count {
    val depEntry = req.restoredDllPaths[ri]
    val tabPos = depEntry.indexOf("\t")
    val dllPath = if tabPos >= 0 { depEntry.substring(tabPos + 1, depEntry.length - tabPos - 1) } else { depEntry }
    match RP.loadRestoredPackage(dllPath) {
      case Err(e) -> return failResult("restored dep '" + dllPath + "' failed to load: " + RP.errorMessage(e))
      case Ok(arts) -> {
        var ai = 0
        while ai < arts.count {
          allArts.add(arts[ai])
          ai = ai + 1
        }
      }
    }
    ri = ri + 1
  }

  // Pass 2: synthesise each artifact, supplying the type declarations of
  // every OTHER restored package as a validation preamble so a signature
  // that names a sibling's type (e.g. `Lyric.ModeChecker.checkFile(file:
  // SourceFile)` referencing `Lyric.Parser.SourceFile`) re-type-checks in
  // isolation.  The stored source still carries only own decls
  // (synthesiseArtifact strips the preamble), so the bundle's item pool
  // registers each type exactly once.
  val restoredArtifacts: List[SynthesisedArtifact] = newList()
  var si2 = 0
  while si2 < allArts.count {
    val art = allArts[si2]
    val preamble = siblingTypeDecls(allArts, art.packageName)
    match RP.synthesiseArtifact(art, preamble) {
      case Err(e) -> return failResult("restored dep '" + art.dllPath + "' failed to synthesise: " + RP.errorMessage(e))
      case Ok(syn) -> restoredArtifacts.add(syn)
    }
    si2 = si2 + 1
  }

  val ok = MsilBridge.compileProjectToMsilWithRestoredAndVersion(
    payloads,
    req.assemblyName,
    req.outputPath,
    stdlibSources,
    req.activeFeatures,
    req.declaredFeatures,
    restoredArtifacts,
    req.packageVersion
  )
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
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  val tmpDir = Path.join(tmpRoot, Uuid.uuidToString(Uuid.newUuid()))
  match File.createDir(tmpDir) {
    case Ok(_) -> ()
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
        case Ok(_) -> ()
        case Err(e) -> {
          failMsg = "cannot write temp source: " + IOError.message(e)
        }
      }
      line = line + "\t" + srcPath
      si += 1
    }
    specLines.add(line)
    pi += 1
  }

  if failMsg != "" {
    match File.deleteDirRecursive(tmpDir) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
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
    case Ok(_) -> ()
    case Err(e) -> {
      failMsg = "cannot write project spec: " + IOError.message(e)
    }
  }

  if failMsg != "" {
    match File.deleteDirRecursive(tmpDir) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
    return failResult(failMsg)
  }

  val targetStr = match req.target { case Dotnet -> "dotnet"; case Jvm -> "jvm" }

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
    case Err(e) -> failResult("cannot launch compiler: " + IOError.message(e))
  }

  match File.deleteDirRecursive(tmpDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  result
}

/// Compile Lyric source to a .NET DLL or JVM JAR.
///
/// `--target dotnet` runs IN-PROCESS via
/// `Msil.Bridge.compileToMsilWithVersion`.  `--target jvm` still
/// shells out to `lyric --internal-build` because the self-hosted JVM
/// bridge does not yet have a single-file entry point reachable from
/// here.  Will retire when the JVM in-process bridge lands.
@stable(since = "0.1")
pub func emit(req: in EmitRequest): EmitResult {
  // Ensure the output directory exists so the bridges' raw byte-write
  // doesn't fail with ENOENT on the first build into a fresh tree.
  val outDir = Path.dirname(req.outputPath)
  if Str.isNotEmpty(outDir) {
    match File.createDir(outDir) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
    // non-fatal; the bridge / subprocess will report
  }

  match req.target {
    case Dotnet -> emitMsilInProcess(req)
    case Jvm -> emitJvmInProcess(req)
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
// bridge path: `loadCompilerPayloads` discovers the self-hosted
// compiler packages under `lyric-compiler/lyric/` and loads the
// import-closure of the requested source, compiling them together so
// `@test_module` files in that tree can import any front/middle-end
// compiler package (`Lyric.Lexer`, `Lyric.Parser`, `Lyric.TypeChecker`,
// `Lyric.Verifier`, …) directly (issue #1324).
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
      val compilerPayloads = loadCompilerPayloads(compilerDir, req.source)
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
          allPayloads,
          req.assemblyName,
          req.outputPath,
          stdlibSources,
          noFeatures,
          noFeatures,
          noArtifacts,
          req.packageVersion
        )
        if ok {
          val okDiags: List[Diagnostic] = newList()
          return EmitResult(outputPath = Some(value = req.outputPath), diagnostics = okDiags)
        } else {
          return failResult("MSIL compilation failed (see stderr)")
        }
      }
    }
  }
  val ok = MsilBridge.compileToMsilWithVersion(req.source, req.outputPath, stdlibSources, req.packageVersion)
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
    case Ok(p) -> p
    case Err(e) -> return failResult("cannot write temp source: " + IOError.message(e))
  }

  val targetStr = match req.target { case Dotnet -> "dotnet"; case Jvm -> "jvm" }

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
    case Err(e) -> return failResult("cannot launch compiler: " + IOError.message(e))
  }
}
