//! verifier/solver.l — solver back-end: discharge a Goal to {unsat, sat, unknown}.
//!
//! Ships two implementations:
//!   * Trivial syntactic discharger: closes tautological goals.
//!   * z3/cvc5 shell-output via Std.ProcessCapture.
//!
//! Persistent session (decision 5c) is deferred: the initial port uses
//! one subprocess invocation per goal.
//!
//! Mirrors compiler/src/Lyric.Verifier/Solver.fs.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Std.File
import Std.ProcessCapture
import Std.VerifierEnvHost

// ─────────────────────────────────────────────────────────────────────────────
// §1. Solver outcome.
// ─────────────────────────────────────────────────────────────────────────────
pub union SolverOutcome {
  case Discharged
  case Counterexample(model: String)
  case Unknown(reason: String)
}

pub func solverOutcomeDisplay(o: in SolverOutcome): String {
  match o {
    case Discharged -> "discharged"
    case Counterexample(m) -> "counterexample:\n" + m
    case Unknown(r) -> "unknown (" + r + ")"
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Counterexample binding (parsed from Z3 model).
// ─────────────────────────────────────────────────────────────────────────────
pub record CounterexampleBinding {
  pub name: String
  pub sort: String
  pub value: String
}

func splitLines(s: in String): List[String] {
  val raw = s.split("\n")
  val result: List[String] = newList()
  for line in raw {
    result.add(line)
  }
  result
}

// Pull (define-fun NAME () SORT VALUE) clauses output of a Z3 model blob.
// Uses parenthesis-depth counting to handle multi-line and nested values
// such as `(- 5)`, `(_ bv42 32)`, and `(mk-Record 1 2)`.
pub func parseModel(modelText: in String): List[CounterexampleBinding] {
  val lines = splitLines(modelText)
  val result: List[CounterexampleBinding] = newList()
  var i = 0
  while i < lines.count {
    val line = lines[i].trim()
    if line.startsWith("(define-fun ") {
      val header = line.substring("(define-fun ".length)
      // Split into: name  ()  sort  rest
      val parts = splitSpaces(header, 4)
      if parts.count >= 3 and parts[1] == "()" {
        val bindName = parts[0]
        val bindSort = parts[2]
        // Collect value using paren-depth counting.  depth=1 because we
        // are inside the (define-fun ...) block.  When depth reaches 0
        // we have consumed the closing ) that ends define-fun; the value
        // is everything before that ).
        var depth: Int = 1
        var valueParts: List[String] = newList()
        var j: Int = i + 1
        var done: Bool = false
        while j < lines.count and not done {
          val rawLine = lines[j].trim()
          if rawLine.length > 0 {
            var kk: Int = 0
            var cutAt: Int = rawLine.length
            while kk < rawLine.length and not done {
              match charAt(rawLine, kk) {
                case Some(c) -> {
                  if c == '(' {
                    depth = depth + 1
                  } else if c == ')' {
                    depth = depth - 1
                    if depth == 0 {
                      cutAt = kk
                      // exclude the define-fun closing ')'
                      done = true
                    }
                  }
                }
                case None -> {
                }
              }
              kk = kk + 1
            }
            val part = rawLine.substring(0, cutAt).trimEnd()
            if part.length > 0 {
              valueParts.add(part)
            }
          }
          j = j + 1
        }
        var allValue: String = ""
        var k: Int = 0
        while k < valueParts.count {
          if k > 0 {
            allValue = allValue + " "
          }
          allValue = allValue + valueParts[k]
          k = k + 1
        }
        result.add(CounterexampleBinding(name = bindName, sort = bindSort, value = allValue))
        i = j
      } else {
        i = i + 1
      }
    } else {
      i = i + 1
    }
  }
  result
}

pub func renderCounterexample(bindings: in List[CounterexampleBinding]): String {
  if bindings.count == 0 {
    "(no model bindings)"
  } else {
    var output = ""
    var i = 0
    while i < bindings.count {
      val b = bindings[i]
      if i > 0 {
        output = output + "\n"
      }
      output = output + "  " + b.name + " : " + b.sort + " = " + b.value
      i = i + 1
    }
    output
  }
}

// Split a string into at most `maxParts` parts by whitespace.
func splitSpaces(s: in String, maxParts: in Int): List[String] {
  val result: List[String] = newList()
  var current = ""
  var i = 0
  while i < s.length {
    match charAt(s, i) {
      case Some(c) -> {
        if c == ' ' or c == '\t' {
          if current.length > 0 {
            result.add(current)
            current = ""
            if result.count >= maxParts - 1 {
              // Remainder goes into last part.
              val rest = s.substring(i + 1).trim()
              if rest.length > 0 {
                result.add(rest)
              }
              return result
            }
          }
        } else {
          current = current + charToString(c)
        }
      }
      case None -> {
      }
    }
    i = i + 1
  }
  if current.length > 0 {
    result.add(current)
  }
  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Trivial syntactic discharger.
// ─────────────────────────────────────────────────────────────────────────────
pub func trivialDischarge(g: in Goal): Option[SolverOutcome] {
  if closesGiven(g.hypotheses, g.conclusion) {
    Some(value = Discharged)
  } else {
    None
  }
}

func isTautology(t: in Term): Bool {
  match t {
    case TLit(VLBool(true), _) -> true
    case TBuiltin(BOpEq, args) -> args.count == 2 and termEq(args[0], args[1])
    case TBuiltin(BOpIff, args) -> args.count == 2 and termEq(args[0], args[1])
    case TBuiltin(BOpLte, args) -> args.count == 2 and termEq(args[0], args[1])
    case TBuiltin(BOpGte, args) -> args.count == 2 and termEq(args[0], args[1])
    case TBuiltin(BOpImplies, args) -> args.count == 2 and termEq(args[0], args[1])
    case TBuiltin(BOpAnd, args) -> allTautologies(args)
    case TBuiltin(BOpOr, args) -> anyTautology(args)
    case TIte(_, a, b) -> termEq(a, b) or (isTautology(a) and isTautology(b))
    case _ -> false
  }
}

func allTautologies(xs: in List[Term]): Bool {
  var i = 0
  while i < xs.count {
    if not isTautology(xs[i]) {
      return false
    }
    i = i + 1
  }
  true
}

func anyTautology(xs: in List[Term]): Bool {
  var i = 0
  while i < xs.count {
    if isTautology(xs[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func termInList(t: in Term, xs: in List[Term]): Bool {
  var i = 0
  while i < xs.count {
    if termEq(t, xs[i]) {
      return true
    }
    i = i + 1
  }
  false
}

// Flatten an And term into its conjuncts (recursing into nested ands).
func flattenAnd(t: in Term): List[Term] {
  val result: List[Term] = newList()
  flattenAndInto(t, result)
  result
}

func flattenAndInto(t: in Term, output: in List[Term]): Unit {
  match t {
    case TBuiltin(BOpAnd, args) -> {
      var i = 0
      while i < args.count {
        flattenAndInto(args[i], output)
        i = i + 1
      }
    }
    case _ -> output.add(t)
  }
}

func closesGiven(hyps: in List[Term], conclusion: in Term): Bool {
  if isTautology(conclusion) {
    return true
  }
  if termInList(conclusion, hyps) {
    return true
  }
  match conclusion {
    case TBuiltin(BOpAnd, conjuncts) -> {
      // All conjuncts must close individually.
      var i = 0
      while i < conjuncts.count {
        if not closesGiven(hyps, conjuncts[i]) {
          return false
        }
        i = i + 1
      }
      true
    }
    case TBuiltin(BOpImplies, args) -> {
      if args.count == 2 {
        val p = args[0]
        val q = args[1]
        if termEq(p, q) {
          return true
        }
        // Adopt p (flattened) as a hypothesis and check q.
        val hyps2: List[Term] = newList()
        var i = 0
        while i < hyps.count {
          hyps2.add(hyps[i])
          i = i + 1
        }
        val pFlat = flattenAnd(p)
        i = 0
        while i < pFlat.count {
          hyps2.add(pFlat[i])
          i = i + 1
        }
        closesGiven(hyps2, q)
      } else {
        false
      }
    }
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Solver binary lookup.
// ─────────────────────────────────────────────────────────────────────────────
func findBinary(envVar: in String, name: in String): Option[String] {
  // Check explicit environment variable.
  val explicit = getEnv(envVar)
  if explicit.length > 0 {
    if fileExists(explicit) {
      return Some(value = explicit)
    }
  }
  // Walk PATH.
  val pathVal = getEnv("PATH")
  if pathVal.length == 0 {
    return None
  }
  val sep = if isWindows() { ";" } else { ":" }
  val rawDirs = pathVal.split(sep)
  val dirs: List[String] = newList()
  for d in rawDirs {
    dirs.add(d)
  }
  var i = 0
  while i < dirs.count {
    val dir = dirs[i]
    val candidate = pathJoin(dir, name)
    if fileExists(candidate) {
      return Some(value = candidate)
    }
    val candidateExe = pathJoin(dir, name + ".exe")
    if fileExists(candidateExe) {
      return Some(value = candidateExe)
    }
    i = i + 1
  }
  None
}

pub func findZ3(): Option[String] {
  findBinary("LYRIC_Z3", "z3")
}

pub func findCvc5(): Option[String] {
  findBinary("LYRIC_CVC5", "cvc5")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Solver invocation.
// ─────────────────────────────────────────────────────────────────────────────
func invokeSolver(binPath: in String, args: in List[String], smtSource: in String): SolverOutcome {
  val captured = runCaptureWithDiagnostics(binPath, args, smtSource)
  if captured.timedOut {
    return Unknown(reason = pathBaseName(binPath) + " timed out (killed after 10 s)")
  }
  if captured.stdout.length == 0 {
    val stderrDetail = if captured.stderr != "" { ": " + captured.stderr } else { "" }
    val exitDetail = if captured.exitCode != 0 { " (exit " + intToString(captured.exitCode) + ")" } else { "" }
    return Unknown(reason = "solver produced no output" + exitDetail + stderrDetail)
  }
  val firstLine = firstNonEmptyLine(captured.stdout)
  if firstLine == "unsat" {
    Discharged
  } else if firstLine == "sat" {
    Counterexample(model = captured.stdout)
  } else if firstLine == "unknown" {
    Unknown(reason = pathBaseName(binPath) + " returned unknown")
  } else {
    Unknown(reason = pathBaseName(binPath) + " returned unexpected output: " + firstLine)
  }
}

func firstNonEmptyLine(s: in String): String {
  val lines = splitLines(s)
  var i = 0
  while i < lines.count {
    val t = lines[i].trim()
    if t.length > 0 {
      return t
    }
    i = i + 1
  }
  ""
}

pub func invokeZ3(z3Path: in String, smtSource: in String): SolverOutcome {
  val args: List[String] = newList()
  args.add("-in")
  args.add("-T:5")
  invokeSolver(z3Path, args, smtSource)
}

pub func invokeCvc5(cvc5Path: in String, smtSource: in String): SolverOutcome {
  val args: List[String] = newList()
  args.add("--lang=smt2")
  args.add("--tlimit=5000")
  args.add("--produce-models")
  args.add("-")
  invokeSolver(cvc5Path, args, smtSource)
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Public discharge function.
// ─────────────────────────────────────────────────────────────────────────────
pub func discharge(g: in Goal): SolverOutcome {
  match trivialDischarge(g) {
    case Some(outcome) -> outcome
    case None -> {
      val smtSrc = smtRenderGoal(g)
      match findZ3() {
        case Some(z3) -> invokeZ3(z3, smtSrc)
        case None -> {
          match findCvc5() {
            case Some(cvc5) -> invokeCvc5(cvc5, smtSrc)
            case None -> Unknown(reason = "no SMT solver available (set LYRIC_Z3 or LYRIC_CVC5, or install z3/cvc5)")
          }
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. OS/path helpers.
// ─────────────────────────────────────────────────────────────────────────────
// These are thin wrappers; actual env/file ops come from kernel externs
// via Std.Environment and Std.File (assumed already imported transitively).
func getEnv(name: in String): String {
  hostGetEnv(name)
}

func isWindows(): Bool {
  hostIsWindows()
}

func pathJoin(dir: in String, file: in String): String {
  if dir.length == 0 {
    return file
  }
  val last = charAt(dir, dir.length - 1)
  val sep = if isWindows() { "\\" } else { "/" }
  match last {
    case Some(c) -> {
      if c == '/' or c == '\\' {
        dir + file
      } else {
        dir + sep + file
      }
    }
    case None -> file
  }
}

func pathBaseName(path: in String): String {
  // BCL lastIndexOf returns int (-1 if not found), use directly.
  val sep1 = path.lastIndexOf("/")
  val sep2 = path.lastIndexOf("\\")
  val pos = if sep1 > sep2 { sep1 } else { sep2 }
  if pos < 0 {
    path
  } else {
    path.substring(pos + 1)
  }
}
