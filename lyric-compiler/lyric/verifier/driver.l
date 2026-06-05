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

pub func proveSourceWithOptions(source: in String, allowUnverified: in Bool): ProofSummary {
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

  // 5. VC generation against the woven file.
  val (goals, vcDiags) = goalsForFile(wovenFile, level)

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
    val outcome = discharge(g)
    results.add(ProofResult(goal = g, outcome = outcome))
    match outcomeToDiag(g, outcome, allowUnverified) {
      case Some(d) -> resultDiags.add(d)
      case None -> {
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
    case TIte(cond, thenT, elseT) -> termHasNonFiniteFloat(cond) or termHasNonFiniteFloat(thenT) or termHasNonFiniteFloat(elseT)
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
