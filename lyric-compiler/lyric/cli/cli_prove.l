package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Std.Json as Json
import Lyric.Manifest as Mf
import Lyric.Lexer
import Lyric.Parser as Parser
import Lyric.ModeChecker as MC
import Lyric.Verifier as Verifier
import Lyric.Discovery as Disc
import Lyric.DiagnosticUtil as DiagUtil
import Lyric.BuildDefines as BD
import Lyric.Emitter as Emitter

// ─────────────────────────────────────────────────────────────────────────────
// §7. Prove command
// ─────────────────────────────────────────────────────────────────────────────
// JSON-escape a string value (no surrounding quotes).
func jsonEsc(s: in String): String {
  var r = ""
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
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
      r = r + Str.substring(s, i, 1)
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
  var proofDir: Option[String] = None
  val positional: List[String] = newList()
  // The build the proof's type check mirrors (#8227): its target, features
  // and defines, as `lyric build` takes them.
  var target: Emitter.CompileTarget = Emitter.Dotnet
  val cliFeatures: List[String] = newList()
  var noDefaultFeatures = false
  var allFeatures = false
  val cliDefines: List[String] = newList()

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
    } else if arg == "--proof-dir" {
      if i + 1 < argv.length and argv[i + 1].length > 0 {
        proofDir = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("prove: --proof-dir requires a directory")
        return 1
      }
    } else if arg == "--target" {
      if i + 1 < argv.length {
        val t = argv[i + 1]
        if t == "dotnet" {
          target = Emitter.Dotnet
        } else if t == "jvm" {
          target = Emitter.Jvm
        } else if t == "native" {
          target = Emitter.Native
        } else {
          printErr("prove: --target must be 'dotnet', 'jvm' or 'native', got: " + t)
          return 1
        }
        i += 2
      } else {
        printErr("prove: --target requires an argument (dotnet, jvm or native)")
        return 1
      }
    } else if arg == "--features" {
      if i + 1 < argv.length {
        // Comma-separated, whitespace-trimmed; empty entries dropped.
        for piece in Str.split(argv[i + 1], ",") {
          val trimmed = Str.trim(piece)
          if Str.length(trimmed) > 0 {
            cliFeatures.add(trimmed)
          }
        }
        i += 2
      } else {
        printErr("prove: --features requires a comma-separated list")
        return 1
      }
    } else if arg == "--no-default-features" {
      noDefaultFeatures = true
      i += 1
    } else if arg == "--all-features" {
      allFeatures = true
      i += 1
    } else if arg == "--define" {
      if i + 1 < argv.length {
        val kv = argv[i + 1]
        match Str.indexOf(kv, "=") {
          case Some(eq) -> {
            if eq == 0 {
              printErr("prove: --define requires KEY=VALUE (empty key): " + kv)
              return 1
            }
            cliDefines.add(kv)
          }
          case None -> {
            printErr("prove: --define requires KEY=VALUE, got: " + kv)
            return 1
          }
        }
        i += 2
      } else {
        printErr("prove: --define requires a KEY=VALUE argument")
        return 1
      }
    } else if rejectUnknownOption("prove", arg) {
      return 1
    } else {
      positional.add(arg)
      i += 1
    }
  }

  if positional.count > 1 {
    printErr("prove: expected one source file, got " + toString(positional.count) + ": " + Str.joinList(" ", positional))
    return 1
  }

  val buildSettings = ProveBuild(
    target = target,
    cliFeatures = cliFeatures,
    noDefaultFeatures = noDefaultFeatures,
    allFeatures = allFeatures,
    defines = cliDefines
  )

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
    if isSome(proofDir) {
      printErr("prove: --proof-dir requires a source file")
      return 1
    }
    var projectMfPath = ""
    val sourcePaths = match resolveProjectSources(manifestArg) {
      case ProjSourcesMissingManifest -> {
        printErr("prove: missing source file and no lyric.toml found")
        return 1
      }
      case ProjSourcesFatal -> return 1
      case ProjSourcesFound(mfp, paths) -> {
        projectMfPath = mfp
        paths
      }
    }
    if sourcePaths.count == 0 {
      printErr("prove: no source files found in project")
      return 1
    }
    // A proof of a program the build rejects means nothing (#8227).
    val noTestEntries: List[String] = newList()
    val everyPackage: Option[List[String]] = None
    if not reportProveTypeCheck(typeCheckManifestForProve(projectMfPath, noTestEntries, everyPackage, buildSettings), projectMfPath) {
      return 1
    }
    // Each `[project.packages]` entry's scope over exactly the files the
    // build merges for it (`Lyric.Discovery.projectEntryFiles`), keyed by
    // normalized path; a file in no entry, or in an entry whose files
    // cannot all be read, parsed or listed, has an unknown scope (#8108).
    val fileScopes = projectFileScopes(projectMfPath)
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
      val pkgScope = match mapGet(fileScopes, Disc.pathKey(sp)) {
        case Some(fs) -> fs
        case None -> Verifier.unknownPackageScope()
      }
      val summary = Verifier.proveSourceInScope(source, allowUnverified, pkgScope)
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

  // A proof of a program the type checker rejects means nothing: the file
  // is type-checked as every build that compiles it checks it, and nothing
  // is proved unless it passes (#8227).
  val typeCheck = typeCheckForProveFile(sourcePath, source, buildSettings)
  if jsonOutput and not typeCheck.ok {
    Console.print(
      proveJson(
        sourcePath,
        MC.vlDisplay(Verifier.sourceVerificationLevel(source)),
        "",
        typeCheck.diagnostics,
        ProveCounts(total = 0, discharged = 0, unknown = 0, counterexamples = 0)
      )
    )
    return 1
  }
  if not jsonOutput and not reportProveTypeCheck(typeCheck, sourcePath) {
    return 1
  }

  // The file's package is the build's: its manifest entry's files, or its
  // directory tree (#8108).
  val fileScope = match Disc.packageFileSetForSource(sourcePath) {
    case Some(fs) -> Verifier.scopeFromPackageFiles(
      Some(value = fs.files),
      fs.fromManifest,
      Disc.normalizePath(sourcePath),
      source
    )
    case None -> Verifier.unknownPackageScope()
  }
  val summary = Verifier.proveSourceInScope(source, allowUnverified, fileScope)

  // `--proof-dir`: each obligation's SMT-LIB query, one file per goal.
  val smtPaths: List[Option[String]] = match proofDir {
    case Some(dir) -> match writeProofFiles(dir, summary) {
      case Ok(paths) -> paths
      case Err(message) -> {
        printErr("prove: " + message)
        return 1
      }
    }
    case None -> {
      val none: List[Option[String]] = newList()
      var ni = 0
      while ni < summary.results.count {
        none.add(None)
        ni = ni + 1
      }
      none
    }
  }

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
    var goalsBuf = ""
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
      goalsBuf = goalsBuf + "    {\n"
      goalsBuf = goalsBuf + "      \"index\": " + toString(gi) + ",\n"
      goalsBuf = goalsBuf + "      \"label\": " + jsonStr(gl.label) + ",\n"
      goalsBuf = goalsBuf + "      \"kind\": " + jsonStr(Verifier.goalKindDisplay(gl.kind)) + ",\n"
      goalsBuf = goalsBuf + "      \"line\": " + toString(gl.origin.startPos.line) + ",\n"
      goalsBuf = goalsBuf + "      \"col\": " + toString(gl.origin.startPos.column) + ",\n"
      goalsBuf = goalsBuf + "      \"outcome\": " + jsonStr(outcomeStr) + ",\n"
      goalsBuf = goalsBuf + "      \"model\": " + modelStr + ",\n"
      val smtPathStr = match smtPaths[gi] { case Some(sp) -> jsonStr(sp); case None -> "null" }
      goalsBuf = goalsBuf + "      \"smtPath\": " + smtPathStr + ",\n"
      goalsBuf = goalsBuf + "      \"suggestions\": []\n"
      goalsBuf = goalsBuf + "    }" + comma + "\n"
      gi = gi + 1
    }
    // The type checker's warnings, then the verifier's diagnostics.
    val allDiags: List[DiagUtil.LocatedDiagnostic] = newList()
    for d in typeCheck.diagnostics {
      allDiags.add(d)
    }
    for d in summary.diagnostics {
      allDiags.add(DiagUtil.LocatedDiagnostic(path = sourcePath, diagnostic = d))
    }
    Console.print(proveJson(sourcePath, MC.vlDisplay(summary.level), goalsBuf, allDiags, summaryCounts(summary)))
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
  match proofDir {
    case Some(dir) -> Console.println(
      "SMT-LIB queries for " + toString(countSome(smtPaths)) + " obligation(s) written to " + dir
    )
    case None -> {
    }
  }

  // Exit 1 only for error diagnostics or counterexamples; unknown goals
  // (trivial solver gave up, z3 not available) are not failures.
  if Verifier.summaryHasErrorDiag(summary) or Verifier.summaryHasCounterexample(summary) {
    1
  } else {
    0
  }
}

// The `lyric prove --json` document (docs/15 Appendix A): `goalsBuf` is the
// goal objects already rendered, one per line group.  Each diagnostic object
// also names the file it is in (`file`, an addition to the frozen v1 keys).
// The `summary` object's counts (docs/15 A.4), over the obligations only:
// the vacuity checks behind V0035/V0036 are not obligations (#8307).
record ProveCounts {
  total: Int
  discharged: Int
  unknown: Int
  counterexamples: Int
}

func summaryCounts(summary: in Verifier.ProofSummary): ProveCounts {
  ProveCounts(
    total = Verifier.summaryTotalCount(summary),
    discharged = Verifier.summaryDischargedCount(summary),
    unknown = Verifier.summaryUnknownCount(summary),
    counterexamples = Verifier.summaryCounterexampleCount(summary)
  )
}

func proveJson(
  file: in String,
  level: in String,
  goalsBuf: in String,
  diags: in List[DiagUtil.LocatedDiagnostic],
  counts: in ProveCounts,
): String {
  var jsonBuf = "{\n"
  jsonBuf = jsonBuf + "  \"file\": " + jsonStr(file) + ",\n"
  jsonBuf = jsonBuf + "  \"level\": " + jsonStr(level) + ",\n"
  jsonBuf = jsonBuf + "  \"goals\": [\n"
  jsonBuf = jsonBuf + goalsBuf
  jsonBuf = jsonBuf + "  ],\n"
  jsonBuf = jsonBuf + "  \"diagnostics\": [\n"
  var di = 0
  while di < diags.count {
    val ld = diags[di]
    val d = ld.diagnostic
    val comma = if di + 1 < diags.count { "," } else { "" }
    val sevStr = match d.severity { case DiagError -> "error"; case DiagWarning -> "warning" }
    jsonBuf = jsonBuf + "    {\"code\":" + jsonStr(d.code) + ",\"severity\":" + jsonStr(sevStr) + ",\"message\":" +
      jsonStr(d.message) +
      ",\"line\":" +
      toString(d.span.startPos.line) +
      ",\"col\":" +
      toString(d.span.startPos.column) +
      ",\"file\":" +
      jsonStr(ld.path) +
      "}" +
      comma +
      "\n"
    di = di + 1
  }
  jsonBuf = jsonBuf + "  ],\n"
  jsonBuf = jsonBuf + "  \"summary\": {\n"
  jsonBuf = jsonBuf + "    \"total\": " + toString(counts.total) + ",\n"
  jsonBuf = jsonBuf + "    \"discharged\": " + toString(counts.discharged) + ",\n"
  jsonBuf = jsonBuf + "    \"unknown\": " + toString(counts.unknown) + ",\n"
  jsonBuf = jsonBuf + "    \"counterexamples\": " + toString(counts.counterexamples) + "\n"
  jsonBuf = jsonBuf + "  }\n"
  jsonBuf = jsonBuf + "}\n"
  jsonBuf
}

// ─────────────────────────────────────────────────────────────────────────────
// `--proof-dir`: the obligations' SMT-LIB queries on disk (#8309)
// ─────────────────────────────────────────────────────────────────────────────
// Writes each obligation's SMT-LIB v2.6 query to `<dir>/<n>-<label>.smt2`,
// `<n>` its goal index (as `--explain --goal` and the `--json` goals number
// it), creating `dir` if needed, and returns the path written for each
// obligation in goal order.  An obligation that could not be translated
// into the proof logic (V0033) has no query, so no file and `None`.  A
// trivially discharged obligation still gets its query, which a solver
// would also prove.
func writeProofFiles(dir: in String, summary: in Verifier.ProofSummary): Result[List[Option[String]], String] {
  match File.createDir(dir) {
    case Ok(_) -> {
    }
    case Err(e) -> return Err(error = "cannot create proof directory '" + dir + "': " + IOError.message(e))
  }
  val paths: List[Option[String]] = newList()
  var gi = 0
  while gi < summary.results.count {
    val r = summary.results[gi]
    if r.translated {
      val path = Path.join(dir, toString(gi) + "-" + proofFileStem(r.goal.label) + ".smt2")
      match File.writeText(path, Verifier.smtRenderGoal(r.goal)) {
        case Ok(_) -> paths.add(Some(value = path))
        case Err(e) -> return Err(error = "cannot write '" + path + "': " + IOError.message(e))
      }
    } else {
      paths.add(None)
    }
    gi = gi + 1
  }
  Ok(value = paths)
}

// A goal label as a portable file-name stem: ASCII letters, digits, `_`,
// `-` and `.` are kept, anything else (`$`, `<`, `/`, spaces) becomes `_`.
func proofFileStem(label: in String): String {
  var r = ""
  var i = 0
  while i < label.length {
    val c = Str.charAtOrReplacement(label, i)
    val keep = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-' or
      c == '.'
    r = r + (if keep { Str.substring(label, i, 1) } else { "_" })
    i = i + 1
  }
  r
}

func countSome(xs: in List[Option[String]]): Int {
  var n = 0
  for x in xs {
    if isSome(x) {
      n = n + 1
    }
  }
  n
}

// ─────────────────────────────────────────────────────────────────────────────
// The type check `lyric prove` runs before it proves anything (#8227)
// ─────────────────────────────────────────────────────────────────────────────
// The type checker's diagnostics on the program a proof is about, and
// whether it passed.  `ok` is false too when the program could not be
// loaded to be checked (a manifest or package that cannot be read, a
// dependency that cannot be resolved).
record ProveTypeCheck {
  diagnostics: List[DiagUtil.LocatedDiagnostic]
  ok: Bool
}

func proveTypeCheckOf(diags: in List[DiagUtil.LocatedDiagnostic]): ProveTypeCheck {
  var ok = true
  for d in diags {
    if d.diagnostic.severity == DiagError {
      ok = false
    }
  }
  ProveTypeCheck(diagnostics = diags, ok = ok)
}

// A failure to load the program for the type check, as a diagnostic of the
// manifest or file at `path`.
func proveLoadFailure(path: in String, message: in String): ProveTypeCheck {
  val diags: List[DiagUtil.LocatedDiagnostic] = newList()
  diags.add(
    DiagUtil.LocatedDiagnostic(
      path = path,
      diagnostic = errorDiagnostic("B0001", message, pointSpan(initialPosition()))
    )
  )
  ProveTypeCheck(diagnostics = diags, ok = false)
}

// Print the type check's diagnostics as a build prints them; when it did
// not pass, say that nothing was proved.  Returns whether it passed.
func reportProveTypeCheck(tc: in ProveTypeCheck, subject: in String): Bool {
  for d in tc.diagnostics {
    printErr(DiagUtil.diagFormatLocated(d))
  }
  if not tc.ok {
    printErr("prove: " + subject + " fails the build's checks; no proof obligation was attempted")
  }
  tc.ok
}

// The build a proof's type check mirrors: `lyric build`'s `--target`,
// `--features`, `--no-default-features`, `--all-features` and `--define`.
// No manifest key declares a default target, so it is dotnet unless
// `--target` says otherwise, as for `lyric build`.
record ProveBuild {
  target: Emitter.CompileTarget
  cliFeatures: List[String]
  noDefaultFeatures: Bool
  allFeatures: Bool
  defines: List[String]
}

// The source file at `sourcePath` checked as each build that compiles it
// checks it: within each project whose manifest lists it, its own package
// and the packages it imports, or alone, as `lyric build <file>` does, when
// no manifest lists it.
func typeCheckForProveFile(sourcePath: in String, source: in String, build: in ProveBuild): ProveTypeCheck {
  val entries = match Disc.entriesContainingSource(sourcePath) {
    case Some(es) -> es
    case None -> return proveLoadFailure(
      sourcePath,
      "cannot tell which packages build this file: an enclosing lyric.toml cannot be read, or a package that lists it cannot be listed"
    )
  }
  if entries.count == 0 {
    val req = Emitter.EmitRequest(
      source = source,
      assemblyName = stemOf(Path.basename(sourcePath), 2),
      outputPath = "",
      target = build.target,
      packageVersion = "",
      defines = build.defines,
      path = sourcePath,
      contractsEnabled = true
    )
    return proveTypeCheckOf(Emitter.typeCheckSource(req))
  }
  // Each manifest once, with its entries that list the file: the packages
  // checked there are theirs and what they import.  A `[project.tests]`
  // entry is checked only when it lists the file.
  val manifests: List[String] = newList()
  for e in entries {
    if not stringListContains(manifests, e.manifestPath) {
      manifests.add(e.manifestPath)
    }
  }
  val all: List[DiagUtil.LocatedDiagnostic] = newList()
  for mfPath in manifests {
    val tests: List[String] = newList()
    val focus: List[String] = newList()
    for e in entries {
      if e.manifestPath == mfPath {
        focus.add(e.entryName)
        if e.isTests {
          tests.add(e.entryName)
        }
      }
    }
    val one = typeCheckManifestForProve(mfPath, tests, Some(value = focus), build)
    for d in one.diagnostics {
      all.add(d)
    }
    if not one.ok {
      return ProveTypeCheck(diagnostics = all, ok = false)
    }
  }
  proveTypeCheckOf(all)
}

// A project entry and the packages its files import.
record ProveEntry {
  pkgEntry: Mf.PackageEntry
  imports: List[String]
}

// The packages the files of `entry` import, by dotted name: not the
// `import extern` ones, which name host types, nor a file that cannot be
// read or parsed, which the check itself reports.
func entryImports(entry: in Mf.PackageEntry, mfDir: in String, proj: in Mf.ProjectSection): List[String] {
  val names: List[String] = newList()
  for path in Disc.projectEntryFiles(entry, mfDir, proj).paths {
    match File.readText(path) {
      case Ok(text) -> {
        for imp in Parser.parse(text).file.imports {
          if not imp.isExtern {
            val name = Str.joinList(".", imp.path.segments)
            if not stringListContains(names, name) {
              names.add(name)
            }
          }
        }
      }
      case Err(_) -> ()
    }
  }
  names
}

// The project at `mfPath` checked as `lyric build` for `build.target` checks
// it, without compiling it: the entries named in `focus` and every project
// package they import, directly or not (with `focus` None, every
// `[project.packages]` entry, `test_only` ones included, since a proof covers
// them), plus the `[project.tests]` entries named in `testEntries`.  The
// project's dependencies are resolved only when one of those packages
// imports a package that is neither the standard library's nor the
// project's, and then each must be built or restored: a proof never restores
// or builds one, so an unbuilt dependency stops it, as it does a build.
func typeCheckManifestForProve(
  mfPath: in String,
  testEntries: in List[String],
  focus: in Option[List[String]],
  build: in ProveBuild,
): ProveTypeCheck {
  val mfText = match File.readText(mfPath) {
    case Ok(t) -> t
    case Err(e) -> return proveLoadFailure(mfPath, "cannot read the manifest: " + IOError.message(e))
  }
  val manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> return proveLoadFailure(mfPath, "cannot parse the manifest: " + Mf.ManifestError.message(e))
  }
  val proj = match manifest.project {
    case Some(p) -> p
    case None -> return proveLoadFailure(mfPath, "the manifest has no [project] section")
  }
  val mfDir = Path.dirname(mfPath)
  val (activeFeatures, mfDeclared) = resolveManifestFeatures(
    mfText,
    mfPath,
    build.cliFeatures,
    build.noDefaultFeatures,
    build.allFeatures,
    build.target
  )
  val candidates: List[ProveEntry] = newList()
  for e in proj.packages.toArray() {
    candidates.add(ProveEntry(pkgEntry = e, imports = entryImports(e, mfDir, proj)))
  }
  for e in proj.tests.toArray() {
    if stringListContains(testEntries, e.name) {
      candidates.add(ProveEntry(pkgEntry = e, imports = entryImports(e, mfDir, proj)))
    }
  }
  val projectNames: List[String] = newList()
  for c in candidates {
    projectNames.add(c.pkgEntry.name)
  }
  // The import closure of the focus entries over the project's packages.
  val chosen: List[String] = newList()
  match focus {
    case Some(names) -> {
      for n in names {
        if not stringListContains(chosen, n) {
          chosen.add(n)
        }
      }
    }
    case None -> {
      for e in proj.packages.toArray() {
        chosen.add(e.name)
      }
    }
  }
  for n in testEntries {
    if not stringListContains(chosen, n) {
      chosen.add(n)
    }
  }
  var needsDeps = false
  var ci = 0
  while ci < chosen.count {
    for c in candidates {
      if c.pkgEntry.name == chosen[ci] {
        for imp in c.imports {
          if stringListContains(projectNames, imp) {
            if not stringListContains(chosen, imp) {
              chosen.add(imp)
            }
          } else if imp != "Std" and not Str.startsWith(imp, "Std.") {
            needsDeps = true
          }
        }
      }
    }
    ci = ci + 1
  }
  val gens = resolveGenerators(manifest, mfPath)
  val pkgs: List[Emitter.ProjectPackage] = newList()
  for c in candidates {
    if stringListContains(chosen, c.pkgEntry.name) {
      match readProjectPackageSourcesAs("prove", c.pkgEntry, proj, mfDir, mfPath, Some(value = manifest), gens) {
        case Some(read) -> {
          if read.sources.count > 0 {
            pkgs.add(
              Emitter.ProjectPackage(name = c.pkgEntry.name, sources = read.sources, paths = read.paths, nameFromManifest = true)
            )
          }
        }
        case None -> return proveLoadFailure(mfPath, "package '" + c.pkgEntry.name + "' cannot be read")
      }
    }
  }
  val restoredDlls: List[String] = newList()
  val depSrcs: List[Emitter.ProjectPackage] = newList()
  val nugetPaths: List[String] = newList()
  var depFeatures = Emitter.noPackageFeatures()
  if needsDeps {
    if lockNeedsRestore(mfPath, manifest) {
      return proveLoadFailure(
        mfPath,
        "the project's dependencies are not restored (lyric.lock is missing or out of date); run `lyric restore` or `lyric build` first"
      )
    }
    val resolved = resolveManifestDependenciesAs(
      "prove",
      manifest,
      mfPath,
      build.target,
      build.cliFeatures,
      build.noDefaultFeatures
    )
    if resolved.hadWorkspaceError or resolved.hadUnsupportedDep or resolved.hadUnbuiltLocalDep {
      return proveLoadFailure(
        mfPath,
        "a dependency of the project is not built or cannot be used (see above); run `lyric restore` or `lyric build` first"
      )
    }
    for d in resolved.restoredDlls {
      restoredDlls.add(d)
    }
    for d in resolved.depTemplateSrcs {
      depSrcs.add(d)
    }
    for d in resolved.nugetThirdPartyPaths {
      nugetPaths.add(d)
    }
    depFeatures = resolved.depPackageFeatures
  }
  // `[layers]` give each package its I/O rule, as for a build.
  val layered = match checkProjectLayers(manifest, mfPath, pkgs, depSrcs, restoredDlls, build.target, activeFeatures, mfDeclared) {
    case Some(l) -> l
    case None -> return proveLoadFailure(mfPath, "the project breaks its [layers] rules (see above)")
  }
  // A dependency is compiled from its source on the JVM and native targets.
  if compilesDepsFromSource(build.target) {
    for d in depSrcs {
      layered.add(d)
    }
  }
  val req = Emitter.EmitProjectRequest(
    packages = layered,
    assemblyName = proj.name,
    outputPath = "",
    target = build.target,
    restoredDllPaths = restoredDlls,
    activeFeatures = activeFeatures,
    declaredFeatures = mfDeclared,
    packageVersion = manifest.packageSection.version,
    depTemplateSrcs = depSrcs,
    nugetAssemblyPaths = nugetPaths,
    defines = BD.withManifestDefines(Mf.getManifestBuildDefines(manifest), build.defines),
    packageFeatures = depFeatures,
    contractsEnabled = match manifest.contracts { case Some(cs) -> cs.enabled; case None -> true }
  )
  proveTypeCheckOf(Emitter.typeCheckProject(req))
}

// The scope of every file of the project at `mfPath`: for each
// `[project.packages]` and `[project.tests]` entry, the type names declared
// across exactly the files the build merges for it, keyed by
// `Lyric.Discovery.pathKey`.  A file in two entries gets their union.
func projectFileScopes(mfPath: in String): Map[String, Verifier.PackageScope] {
  val scopes: Map[String, Verifier.PackageScope] = newMap()
  val mf = match File.readText(mfPath) {
    case Ok(text) -> match Mf.parseManifest(text, mfPath) { case Ok(m) -> m; case Err(_) -> { return scopes } }
    case Err(_) -> {
      return scopes
    }
  }
  val proj = match mf.project { case Some(p) -> p; case None -> { return scopes } }
  val mfDir = Path.dirname(mfPath)
  val entries: List[Mf.PackageEntry] = newList()
  for e in proj.packages.toArray() {
    entries.add(e)
  }
  for e in proj.tests.toArray() {
    entries.add(e)
  }
  for entry in entries.toArray() {
    val ef = Disc.projectEntryFiles(entry, mfDir, proj)
    val files: List[String] = newList()
    for p in ef.paths.toArray() {
      files.add(Disc.normalizePath(p))
    }
    val complete = ef.problems.count == 0 and ef.emptyDir.length == 0
    val entryScope = if complete { Verifier.scopeOfFiles(files, "") } else { Verifier.unknownPackageScope() }
    // A file outside the manifest's tree cannot find this manifest from
    // where it is: a single-file proof of it does not see this package.
    val treeKey = Disc.pathKey(mfDir) + "/"
    for f in files.toArray() {
      if not Str.startsWith(Disc.pathKey(f), treeKey) {
        printErr(
          "prove: warning: package '" + entry.name + "' lists " + f + ", outside " + mfDir +
            "; a single-file `lyric prove` of that file does not see this package (prove it with --manifest)"
        )
      }
    }
    for fileKey in files.toArray() {
      val f = Disc.pathKey(fileKey)
      val merged = match mapGet(scopes, f) {
        case None -> entryScope
        case Some(prev) -> {
          if prev.known and entryScope.known {
            val both: List[String] = newList()
            for n in prev.typeNames.toArray() {
              both.add(n)
            }
            for n in entryScope.typeNames.toArray() {
              both.add(n)
            }
            Verifier.packageScopeOf(both)
          } else {
            Verifier.unknownPackageScope()
          }
        }
      }
      if scopes.containsKey(f) {
        val dropped = scopes.remove(f)
      }
      scopes.add(f, merged)
    }
  }
  scopes
}
