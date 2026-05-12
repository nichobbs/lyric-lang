// verifier/driver.l — end-to-end verifier driver for self-hosted use.
//
// Orchestrates: parse → mode-check → stability-check → VC-gen → discharge.
// Simplified vs the F# Driver.fs: no cross-package imports, no persistent
// z3 session, no counterexample trace analysis, no SMT file writing.
//
// Mirrors compiler/src/Lyric.Verifier/Driver.fs (M4.1 subset).
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker

// ─────────────────────────────────────────────────────────────────────────────
// §1. Result types.
// ─────────────────────────────────────────────────────────────────────────────

pub record ProofResult {
  pub goal:    Goal
  pub outcome: SolverOutcome
}

pub record ProofSummary {
  pub level:       VerificationLevel
  pub diagnostics: List[Diagnostic]
  pub results:     List[ProofResult]
}

pub func summaryDischargedCount(s: in ProofSummary): Int {
  var n = 0
  var i = 0
  while i < s.results.count {
    match s.results[i].outcome {
      case Discharged -> { n = n + 1 }
      case _          -> {}
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
      case Discharged -> {}
      case _          -> { return true }
    }
    i = i + 1
  }
  false
}

pub func summaryHasCounterexample(s: in ProofSummary): Bool {
  var i = 0
  while i < s.results.count {
    match s.results[i].outcome {
      case Counterexample(_) -> { return true }
      case _                 -> {}
    }
    i = i + 1
  }
  false
}

pub func summaryHasErrorDiag(s: in ProofSummary): Bool {
  var i = 0
  while i < s.diagnostics.count {
    if s.diagnostics[i].severity == DiagError { return true }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Outcome → Diagnostic.
// ─────────────────────────────────────────────────────────────────────────────

// Discharged goals produce no diagnostic; counterexample → V0008 error;
// unknown → V0007 warning (or error if allowUnverified = false).
pub func outcomeToDiag(
    g:               in Goal,
    outcome:         in SolverOutcome,
    allowUnverified: in Bool
): Option[Diagnostic] {
  match outcome {
    case Discharged -> None
    case Counterexample(model) -> {
      val body = if model.length > 0 {
        val bindings = parseModel(model)
        if bindings.count == 0 {
          val rawLines = model.split("\n")
          val lines: List[String] = newList()
          for ln in rawLines { lines.add(ln) }
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
      Some(value = errorDiagnostic("V0008",
        goalKindDisplay(g.kind) + " — proof failed (counterexample below)\n" + body,
        g.origin))
    }
    case Unknown(reason) -> {
      if allowUnverified {
        Some(value = warningDiagnostic("V0007",
          goalKindDisplay(g.kind) + " — solver returned unknown: " + reason,
          g.origin))
      } else {
        Some(value = errorDiagnostic("V0007",
          goalKindDisplay(g.kind) + " — solver returned unknown: " + reason,
          g.origin))
      }
    }
  }
}

func joinLines(lines: in List[String]): String {
  var output = ""
  var i = 0
  while i < lines.count {
    if i > 0 { output = output + "\n" }
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

pub func proveSourceWithOptions(source: in String, allowUnverified: in Bool): ProofSummary {
  // 1. Parse.
  val parsed = parse(source)
  val parseDiags = parsed.diagnostics
  val parseFatal = hasFatalDiag(parseDiags)

  if parseFatal {
    val results: List[ProofResult] = newList()
    return ProofSummary(
      level       = VLRuntimeChecked,
      diagnostics = parseDiags,
      results     = results)
  }

  // 2. Mode-check.
  val modeResult  = checkFile(parsed.file)
  val level       = modeResult.level
  val modeDiags   = modeResult.diagnostics

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

  // 4. VC generation.
  val (goals, vcDiags) = goalsForFile(parsed.file, level)

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
    val outcome = discharge(g)
    results.add(ProofResult(goal = g, outcome = outcome))
    match outcomeToDiag(g, outcome, allowUnverified) {
      case Some(d) -> resultDiags.add(d)
      case None    -> {}
    }
    i = i + 1
  }

  val finalDiags: List[Diagnostic] = newList()
  appendDiags(finalDiags, allParseDiags)
  appendDiags(finalDiags, vcDiags)
  appendDiags(finalDiags, resultDiags)
  ProofSummary(level = level, diagnostics = finalDiags, results = results)
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Helpers.
// ─────────────────────────────────────────────────────────────────────────────

func hasFatalDiag(diags: in List[Diagnostic]): Bool {
  var i = 0
  while i < diags.count {
    if diags[i].severity == DiagError { return true }
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
