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
import Lyric.ModeChecker as MC
import Lyric.Verifier as Verifier
import Lyric.Discovery as Disc

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
