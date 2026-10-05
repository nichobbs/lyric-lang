//! verifier/driver.l — end-to-end verifier driver for self-hosted use.
//!
//! Orchestrates: parse → mode-check → stability-check → VC-gen → discharge.
//! Simplified vs the F# Driver.fs: no cross-package imports, no persistent
//! z3 session, no counterexample trace analysis, no SMT file writing.
//!
//! Mirrors compiler/src/Lyric.Verifier/Driver.fs (M4.1 subset).
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.Weaver
import Std.File as File
import Std.String as Str

// ─────────────────────────────────────────────────────────────────────────────
// §1. Result types.
// ─────────────────────────────────────────────────────────────────────────────
pub record ProofResult {
  pub goal: Goal
  pub outcome: SolverOutcome
}

pub record ProofSummary {
  pub level: VerificationLevel
  pub diagnostics: List[Diagnostic]
  pub results: List[ProofResult]
}

pub func summaryDischargedCount(s: in ProofSummary): Int {
  var n = 0
  var i = 0
  while i < s.results.count {
    match s.results[i].outcome {
      case Discharged -> {
        n = n + 1
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  n
}

pub func summaryTotalCount(s: in ProofSummary): Int {
  s.results.count
}

pub func summaryHasFailure(s: in ProofSummary): Bool {
  var i = 0
  while i < s.results.count {
    match s.results[i].outcome {
      case Discharged -> {
      }
      case _ -> {
        return true
      }
    }
    i = i + 1
  }
  false
}

pub func summaryHasCounterexample(s: in ProofSummary): Bool {
  var i = 0
  while i < s.results.count {
    match s.results[i].outcome {
      case Counterexample(_) -> {
        return true
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  false
}

pub func summaryHasErrorDiag(s: in ProofSummary): Bool {
  var i = 0
  while i < s.diagnostics.count {
    if s.diagnostics[i].severity == DiagError {
      return true
    }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Outcome → Diagnostic.
// ─────────────────────────────────────────────────────────────────────────────
// Discharged goals produce no diagnostic; counterexample → V0008 error;
// unknown → V0007 warning (or error if allowUnverified = false).
pub func outcomeToDiag(g: in Goal, outcome: in SolverOutcome, allowUnverified: in Bool): Option[Diagnostic] {
  match outcome {
    case Discharged -> None
    case Counterexample(model) -> {
      val body = if model.length > 0 {
        val bindings = parseModel(model)
        if bindings.count == 0 {
          val rawLines = model.split("\n")
          val lines: List[String] = newList()
          for ln in rawLines {
            lines.add(ln)
          }
          val head: List[String] = newList()
          var i = 0
          while i < 6 and i < lines.count {
            head.add(lines[i])
            i = i + 1
          }
          "raw model:\n" + joinLines(head)
        } else {
          renderCounterexample(bindings)
        }
      } else {
        "(no model)"
      }
      Some(
        value = errorDiagnostic(
          "V0008",
          goalKindDisplay(g.kind) + " — proof failed (counterexample below)\n" + body,
          g.origin
        )
      )
    }
    case Unknown(reason) -> {
      // A query the solver rejected is a verifier bug: an error even with
      // --allow-unverified, the solver's text only a detail line (#8102).
      if reason.startsWith(solverRejectedMarker()) {
        val detail = reason.substring(solverRejectedMarker().length, reason.length - solverRejectedMarker().length)
        return Some(
          value = errorDiagnostic(
            "V0007",
            goalKindDisplay(g.kind) + " — internal verifier error: the proof query for goal '" + g.label +
              "' was malformed, so the goal is not proved; please report this\n  solver: " +
              detail,
            g.origin
          )
        )
      }
      if allowUnverified {
        Some(value = warningDiagnostic("V0007", goalKindDisplay(g.kind) + " — solver returned unknown: " + reason, g.origin))
      } else {
        Some(value = errorDiagnostic("V0007", goalKindDisplay(g.kind) + " — solver returned unknown: " + reason, g.origin))
      }
    }
  }
}

func joinLines(lines: in List[String]): String {
  var output = ""
  var i = 0
  while i < lines.count {
    if i > 0 {
      output = output + "\n"
    }
    output = output + lines[i]
    i = i + 1
  }
  output
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Core prove pipeline.
// ─────────────────────────────────────────────────────────────────────────────
pub func proveSource(source: in String): ProofSummary {
  proveSourceWithOptions(source, false)
}

// The other files of the package being proved, as far as the verifier needs
// them: the top-level type names they declare (#8108).  `known` false means
// they could not all be seen, and every name is assumed declared there.
pub record PackageScope {
  pub known: Bool
  pub typeNames: List[String]
}

pub func unknownPackageScope(): PackageScope {
  val none: List[String] = newList()
  PackageScope(known = false, typeNames = none)
}

pub func packageScopeOf(typeNames: in List[String]): PackageScope {
  PackageScope(known = true, typeNames = typeNames)
}

// A source file's package and the top-level type names it declares;
// `parsed` false when it does not parse.  `customGenerator` says it carries
// a custom `@generate(X.Y)`, whose generated code — appended before the
// build merges the package — may declare any type.
pub record PackageTypes {
  pub packageName: String
  pub typeNames: List[String]
  pub parsed: Bool
  pub customGenerator: Bool = false
}

pub func packageTypesOfSource(source: in String): PackageTypes {
  val parsed = parse(source)
  if hasFatalDiag(parsed.diagnostics) {
    val none: List[String] = newList()
    return PackageTypes(packageName = "", typeNames = none, parsed = false)
  }
  PackageTypes(
    packageName = joinPathSegments(parsed.file.packageDecl.path.segments),
    typeNames = declaredTypeNames(parsed.file),
    parsed = true,
    customGenerator = hasCustomGenerator(parsed.file)
  )
}

// Whether an item carries `@generate(X.Y)`: a custom generator, run by the
// build (`Lyric.Generator`).  The built-in `@generate(Json)`-style derives
// add functions, never a type.
func hasCustomGenerator(file: in SourceFile): Bool {
  var i = 0
  while i < file.items.count {
    val anns = file.items[i].annotations
    var k = 0
    while k < anns.count {
      val ann = anns[k]
      if joinPathSegments(ann.name.segments) == "generate" {
        var ai = 0
        while ai < ann.args.count {
          match ann.args[ai] {
            case ABare(name, _) -> {
              if Str.contains(name, ".") {
                return true
              }
            }
            case _ -> ()
          }
          ai = ai + 1
        }
      }
      k = k + 1
    }
    i = i + 1
  }
  false
}

// The scope of a file of a package built from `packageFiles` (every file of
// it, normalized as `ownPath` is; the file itself is read from `ownSource`,
// not disk): the type names every file declares (`scopeOfSources`).  An
// unknown file set (`None`) or an own file that does not parse or carries a
// custom generator makes it unknown.  `lyric prove <file>` and the LSP take
// the set from `Lyric.Discovery.packageFilesForSource`, the build's own
// (#8108).
pub func scopeFromPackageFiles(
  packageFiles: in Option[List[String]], ownPath: in String, ownSource: in String
): PackageScope {
  val files = match packageFiles { case Some(fs) -> fs; case None -> { return unknownPackageScope() } }
  val own = packageTypesOfSource(ownSource)
  if not own.parsed or own.customGenerator {
    return unknownPackageScope()
  }
  scopeOfFilesIn(files, ownPath, own.packageName)
}

// The type names every file of `files` but `skipPath` declares, as
// `scopeOfSources` classifies them; unknown when one cannot be read.
pub func scopeOfFiles(files: in List[String], skipPath: in String): PackageScope {
  scopeOfFilesIn(files, skipPath, "")
}

func scopeOfFilesIn(files: in List[String], skipPath: in String, ownPackage: in String): PackageScope {
  val sources: List[String] = newList()
  var i = 0
  while i < files.count {
    if files[i] != skipPath {
      match File.readText(files[i]) {
        case Ok(t) -> sources.add(t)
        case Err(_) -> return unknownPackageScope()
      }
    }
    i = i + 1
  }
  scopeOfSources(sources, ownPackage)
}

// The type names the other files of a package declare, from their texts.
// A package build does not parse its files one by one: it strips each
// file's `package` and `import` lines, concatenates the bodies and parses
// the result (`Lyric.Emitter.mergePackageSources`), so a file with no
// `package` line is part of it and its declarations are live (#8214).  Each
// file is classified the way the build would treat it:
//   * one that parses contributes the types it declares;
//   * one with no `package` line that does not parse alone is parsed again
//     under a `package` line, as the build reads it, and contributes its
//     types, or makes the scope unknown when it still does not parse;
//   * one whose `package` line names another package than `ownPackage` and
//     that does not parse is skipped: its body fails any build it is part
//     of, and a single-file set holds every `.l` file under the directory,
//     whatever its package;
//   * any other file that does not parse — one of this package, or of a
//     package not known (`ownPackage` "") — makes the scope unknown.
// A custom generator anywhere makes it unknown: its generated code may
// declare any type.
pub func scopeOfSources(sources: in List[String], ownPackage: in String): PackageScope {
  val names: List[String] = newList()
  var i = 0
  while i < sources.count {
    val src = sources[i]
    var pt = packageTypesOfSource(src)
    if not pt.parsed {
      val header = headerPackageName(src)
      if header.length == 0 {
        pt = packageTypesOfSource("package LyricSiblingWithoutHeader\n" + src)
        if not pt.parsed {
          return unknownPackageScope()
        }
      } else if ownPackage.length > 0 and header != ownPackage {
        i = i + 1
        continue
      } else {
        return unknownPackageScope()
      }
    }
    if pt.customGenerator {
      return unknownPackageScope()
    }
    var k = 0
    while k < pt.typeNames.count {
      names.add(pt.typeNames[k])
      k = k + 1
    }
    i = i + 1
  }
  packageScopeOf(names)
}

// The package a file's `package` line names, or "" when its header has
// none.  The header is what precedes the first item: blank lines,
// comments, file-level annotations and the `package` line itself.
pub func headerPackageName(source: in String): String {
  val lines = Str.split(source, "\n")
  var inBlock = false
  var i = 0
  while i < lines.length {
    val line = Str.trim(lines[i])
    if inBlock {
      if Str.contains(line, "*/") {
        inBlock = false
      }
    } else if Str.startsWith(line, "/*") {
      inBlock = not Str.contains(line, "*/")
    } else if Str.startsWith(line, "package ") {
      return Str.trim(line.substring(8, line.length - 8))
    } else if not (line.length == 0 or Str.startsWith(line, "//") or Str.startsWith(line, "@")) {
      return ""
    }
    i = i + 1
  }
  ""
}

// Without a scope, the package's other files are unknown.
pub func proveSourceWithOptions(source: in String, allowUnverified: in Bool): ProofSummary {
  proveSourceInScope(source, allowUnverified, unknownPackageScope())
}

pub func proveSourceInScope(source: in String, allowUnverified: in Bool, pkgScope: in PackageScope): ProofSummary {
  // 1. Parse.
  val parsed = parse(source)
  val parseDiags = parsed.diagnostics
  val parseFatal = hasFatalDiag(parseDiags)

  if parseFatal {
    val results: List[ProofResult] = newList()
    return ProofSummary(level = VLRuntimeChecked, diagnostics = parseDiags, results = results)
  }

  // 2. Mode-check (against parsed file — annotations and aspect decls
  //    still visible).
  val modeResult = checkFile(parsed.file)
  val level = modeResult.level
  val modeDiags = modeResult.diagnostics

  // 3. Stability-check.
  val stabilityDiags = checkStabilityFile(parsed.file)

  val allParseDiags: List[Diagnostic] = newList()
  appendDiags(allParseDiags, parseDiags)
  appendDiags(allParseDiags, modeDiags)
  appendDiags(allParseDiags, stabilityDiags)

  if not vlIsProofRequired(level) {
    val results: List[ProofResult] = newList()
    return ProofSummary(level = level, diagnostics = allParseDiags, results = results)
  }

  // 4. Aspect weave (#336).  Replaces each matched IFunc with a renamed
  //    `__aspect_target` plus a wrapper carrying the composed contracts
  //    so the verifier sees the body the runtime executes.  Identity-op
  //    for files without any `aspect` block.  Uses the with-diagnostics
  //    variant so weave-time errors (A0042 args-mismatch on
  //    @inline_template aspects, A0043 unknown call.<field>, A0044
  //    config.<no-default>) surface in the proof summary instead of
  //    being silently dropped.
  val wovenResult = weaveFileWithDiags(parsed.file)
  val wovenFile = wovenResult.file
  val weaveDiags = wovenResult.diagnostics
  appendDiags(allParseDiags, weaveDiags)

  // Gate on fatal weave diagnostics before VC generation.  A0044 in
  // particular materialises a `panic(...)` stub into the woven body; VC
  // generation would then model the panic as an unconstrained value and may
  // discharge goals as Proved even though the program panics at runtime —
  // producing an unsound result.  Returning early here matches the build
  // path's `reportAndAbort(weaveRes.diagnostics)` guard.
  if hasFatalDiag(weaveDiags) {
    val results: List[ProofResult] = newList()
    return ProofSummary(level = level, diagnostics = allParseDiags, results = results)
  }

  // 5. VC generation against the woven file.
  val (goals, vcDiags) = goalsForFileInScope(wovenFile, level, pkgScope.known, pkgScope.typeNames)

  val modeFatal = hasFatalDiag(modeDiags)
  if modeFatal {
    val results: List[ProofResult] = newList()
    val allDiags: List[Diagnostic] = newList()
    appendDiags(allDiags, allParseDiags)
    appendDiags(allDiags, vcDiags)
    return ProofSummary(level = level, diagnostics = allDiags, results = results)
  }

  // 5. Discharge each goal.
  val results: List[ProofResult] = newList()
  val resultDiags: List[Diagnostic] = newList()
  var i = 0
  while i < goals.count {
    val g = goals[i]
    // Warn before discharging if the goal contains NaN or ±Infinity float
    // literals.  smtRenderFloat silently substitutes 0.0 for non-finite values
    // (no SMT-LIB representation exists for them), so the verification result
    // may be incorrect.  Surface this as V0013 so users know to review it.
    if goalHasNonFiniteFloat(g) {
      resultDiags.add(
        warningDiagnostic(
          "V0013",
          "goal '" + g.label + "' contains NaN or +/-Infinity float literal; " +
            "replaced with 0.0 in SMT-LIB output — verification result may be incorrect",
          g.origin
        )
      )
    }
    // Bring every integer/bitvector operand to one sort before discharge
    // (#7848).  A goal that cannot be reconciled means something other than
    // the source, so it fails closed as V0033 — neither the trivial
    // discharger nor the solver sees it.  A goal carrying a construct VC
    // generation already reported as V0033 fails the same way, without a
    // second report (#7874).
    if goalIsPoisoned(g) {
      results.add(ProofResult(goal = g, outcome = Unknown(reason = "not translatable: a construct reported above (V0033)")))
    } else {
      match reconcileGoalSorts(g) {
        case Ok(rg) -> {
          val outcome = discharge(rg)
          results.add(ProofResult(goal = rg, outcome = outcome))
          match outcomeToDiag(rg, outcome, allowUnverified) {
            case Some(d) -> resultDiags.add(d)
            case None -> {
            }
          }
        }
        case Err(reason) -> {
          results.add(ProofResult(goal = g, outcome = Unknown(reason = "not translatable: " + reason)))
          resultDiags.add(
            errorDiagnostic(
              "V0033",
              goalKindDisplay(g.kind) + " — cannot translate the obligation into the proof logic faithfully: " + reason,
              g.origin
            )
          )
        }
      }
    }
    i = i + 1
  }

  val finalDiags: List[Diagnostic] = newList()
  appendDiags(finalDiags, allParseDiags)
  appendDiags(finalDiags, vcDiags)
  appendDiags(finalDiags, resultDiags)
  ProofSummary(level = level, diagnostics = finalDiags, results = results)
}

// Reconcile the integer/bitvector sorts of every hypothesis and the
// conclusion of `g` (`reconcileTermSorts`).
pub func reconcileGoalSorts(g: in Goal): Result[Goal, String] {
  val hyps: List[Term] = newList()
  var i = 0
  while i < g.hypotheses.count {
    match reconcileTermSorts(g.hypotheses[i]) {
      case Ok(h) -> hyps.add(h)
      case Err(r) -> return Err(error = r)
    }
    i = i + 1
  }
  match reconcileTermSorts(g.conclusion) {
    case Ok(c) -> {
      // A value the verifier does not model has a sort of its own; one
      // compared with or used as a value of another sort makes the query
      // ill-sorted, which the solver would reject.  Fail closed here with
      // what went wrong instead (#8102).
      var hi = 0
      while hi < hyps.count {
        val hp = sortProblem(hyps[hi], SBool)
        if hp.length > 0 {
          return Err(error = hp)
        }
        hi = hi + 1
      }
      val cp = sortProblem(c, SBool)
      if cp.length > 0 {
        return Err(error = cp)
      }
      Ok(
        value = Goal(
          hypotheses = hyps,
          conclusion = c,
          symbols = g.symbols,
          origin = g.origin,
          kind = g.kind,
          label = g.label
        )
      )
    }
    case Err(r) -> Err(error = r)
  }
}

// "" when `t` is well-sorted and of sort `expected`; otherwise what is
// wrong with it.
func sortProblem(t: in Term, expected: in Sort): String {
  val own = sortOf(t)
  // Sorts the solver sees as one (`Float` and `Double` are both `Real`)
  // are the same here.
  if smtRenderSort(own) != smtRenderSort(expected) {
    return "a value the verifier does not model (sort " + sortDisplay(own) + ") is used where a " + sortDisplay(expected) +
      " is needed"
  }
  innerSortProblem(t)
}

func innerSortProblem(t: in Term): String {
  match t {
    case TVar(_, _) -> ""
    case TLit(_, _) -> ""
    case TBuiltin(op, args) -> {
      if isSortUnifyingBuiltin(op) and args.count == 2 {
        val p0 = innerSortProblem(args[0])
        if p0.length > 0 {
          return p0
        }
        sortProblem(args[1], sortOf(args[0]))
      } else {
        val boolArgs = match op { case BOpAnd | BOpOr | BOpNot | BOpImplies | BOpIff | BOpXor -> true; case _ -> false }
        var i = 0
        while i < args.count {
          val p = if boolArgs { sortProblem(args[i], SBool) } else { innerSortProblem(args[i]) }
          if p.length > 0 {
            return p
          }
          i = i + 1
        }
        ""
      }
    }
    case TApp(_, args, _) -> {
      var i = 0
      while i < args.count {
        val p = innerSortProblem(args[i])
        if p.length > 0 {
          return p
        }
        i = i + 1
      }
      ""
    }
    case TLet(bindings, body) -> {
      var i = 0
      while i < bindings.count {
        val p = innerSortProblem(bindings[i].term)
        if p.length > 0 {
          return p
        }
        i = i + 1
      }
      innerSortProblem(body)
    }
    case TIte(c, a, b) -> {
      val pc = sortProblem(c, SBool)
      if pc.length > 0 {
        return pc
      }
      val pa = innerSortProblem(a)
      if pa.length > 0 {
        return pa
      }
      sortProblem(b, sortOf(a))
    }
    case TForall(_, _, body) -> sortProblem(body, SBool)
    case TExists(_, body) -> sortProblem(body, SBool)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Helpers.
// ─────────────────────────────────────────────────────────────────────────────
func hasFatalDiag(diags: in List[Diagnostic]): Bool {
  var i = 0
  while i < diags.count {
    if diags[i].severity == DiagError {
      return true
    }
    i = i + 1
  }
  false
}

func appendDiags(dst: in List[Diagnostic], src: in List[Diagnostic]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Non-finite float detection.
// ─────────────────────────────────────────────────────────────────────────────
// True when a Lit is a NaN or ±Infinity float, which smtRenderFloat silently
// replaces with "0.0" because SMT-LIB Real has no non-finite values.
func litIsNonFiniteFloat(lit: in Lit): Bool {
  match lit {
    case VLFloat(f) -> {
      val s = doubleToString(f)
      s == "NaN" or s == "Infinity" or s == "-Infinity"
    }
    case _ -> false
  }
}

// True when any subterm of `t` is a non-finite float literal.
func termHasNonFiniteFloat(t: in Term): Bool {
  match t {
    case TLit(value, _) -> litIsNonFiniteFloat(value)
    case TVar(_, _) -> false
    case TBuiltin(_, args) -> argsHaveNonFiniteFloat(args)
    case TApp(_, args, _) -> argsHaveNonFiniteFloat(args)
    case TLet(bindings, body) -> {
      var i = 0
      while i < bindings.count {
        if termHasNonFiniteFloat(bindings[i].term) {
          return true
        }
        i = i + 1
      }
      termHasNonFiniteFloat(body)
    }
    case TIte(cond, thenT, elseT) -> termHasNonFiniteFloat(cond) or termHasNonFiniteFloat(thenT) or
      termHasNonFiniteFloat(elseT)
    case TForall(_, triggers, body) -> {
      var i = 0
      while i < triggers.count {
        if argsHaveNonFiniteFloat(triggers[i]) {
          return true
        }
        i = i + 1
      }
      termHasNonFiniteFloat(body)
    }
    case TExists(_, body) -> termHasNonFiniteFloat(body)
  }
}

func argsHaveNonFiniteFloat(args: in List[Term]): Bool {
  var i = 0
  while i < args.count {
    if termHasNonFiniteFloat(args[i]) {
      return true
    }
    i = i + 1
  }
  false
}

// True when any hypothesis or the conclusion of `g` contains a non-finite float.
func goalHasNonFiniteFloat(g: in Goal): Bool {
  var i = 0
  while i < g.hypotheses.count {
    if termHasNonFiniteFloat(g.hypotheses[i]) {
      return true
    }
    i = i + 1
  }
  termHasNonFiniteFloat(g.conclusion)
}
