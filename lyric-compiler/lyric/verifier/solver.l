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
import Std.String
import Std.File
import Std.ProcessCapture
import Std.VerifierEnvHost
import Std.Environment as Env

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
      val dfLen = "(define-fun ".length
      val header = line.substring(dfLen, line.length - dfLen)
      // Split into: name  ()  sort  rest
      val parts = splitSpaces(header, 4)
      if parts.count >= 3 and parts[1] == "()" {
        val bindName = parts[0]
        // A parenthesised sort such as `(_ BitVec 32)` spans several
        // whitespace-separated parts (#7848).
        val bindSort = if parts.count > 3 { leadingSortText(parts[2] + " " + parts[3]) } else { parts[2] }
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
        // The renderer's `Result`/`Option` sort-instance witnesses are not
        // program values (#8108).
        if not bindName.startsWith("lyric!inst!") {
          result.add(CounterexampleBinding(name = bindName, sort = bindSort, value = allValue))
        }
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

// The sort at the start of `text`: one token, or a balanced parenthesised
// expression such as `(_ BitVec 64)`.
func leadingSortText(text: in String): String {
  val t = text.trim()
  if not t.startsWith("(") {
    return splitSpaces(t, 2)[0]
  }
  var depth = 0
  var i = 0
  while i < t.length {
    match charAt(t, i) {
      case Some(c) -> {
        if c == '(' {
          depth = depth + 1
        } else if c == ')' {
          depth = depth - 1
          if depth == 0 {
            return t.substring(0, i + 1)
          }
        }
      }
      case None -> {
      }
    }
    i = i + 1
  }
  t
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
              val rest = s.substring(i + 1, s.length - i - 1).trim()
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

// `x == x` is false for a NaN, so a float is never closed by reflexivity
// (#8141).
func termIsFloat(t: in Term): Bool {
  sortIsFloat(sortOf(t))
}

func isTautology(t: in Term): Bool {
  match t {
    case TLit(VLBool(true), _) -> true
    case TBuiltin(BOpEq, args) -> args.count == 2 and termEq(args[0], args[1]) and not termIsFloat(args[0])
    case TBuiltin(BOpIff, args) -> args.count == 2 and termEq(args[0], args[1])
    case TBuiltin(BOpLte, args) -> args.count == 2 and termEq(args[0], args[1]) and not termIsFloat(args[0])
    case TBuiltin(BOpGte, args) -> args.count == 2 and termEq(args[0], args[1]) and not termIsFloat(args[0])
    case TBuiltin(BOpImplies, args) -> args.count == 2 and termEq(args[0], args[1])
    case TBuiltin(BOpAnd, args) -> allTautologies(args)
    case TBuiltin(BOpOr, args) -> anyTautology(args)
    // `if c then p else p` is `p`, a tautology only when `p` is (#8102).
    case TIte(_, a, b) -> isTautology(a) and isTautology(b)
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
/// What deciding one goal produced: its outcome, who decided it (`z3`,
/// `cvc5`, the built-in trivial discharger, or no one when no solver is
/// installed), and the solver's raw response, which `lyric prove --verbose`
/// prints (#8320).  `response` is empty when no solver ran.
pub record SolverExchange {
  pub outcome: SolverOutcome
  pub decidedBy: String
  pub response: String
}

/// `decidedBy` of a goal the trivial discharger decided without a solver.
pub func trivialDischargerName(): String {
  "trivial discharger"
}

/// `decidedBy` of a goal no solver could be found to decide.
pub func noSolverName(): String {
  "no solver"
}

// `name` is the solver's kind (`z3`, `cvc5`), whatever its binary is called.
func invokeSolver(name: in String, binPath: in String, args: in List[String], smtSource: in String): SolverExchange {
  val captured = runCaptureWithDiagnostics(binPath, args, smtSource)
  // What the solver wrote: its output, then anything it wrote to stderr.
  val raw = if captured.stderr.length == 0 {
    captured.stdout
  } else if captured.stdout.length == 0 {
    captured.stderr
  } else {
    captured.stdout + "\n" + captured.stderr
  }
  SolverExchange(outcome = solverOutcomeOf(name, captured), decidedBy = name, response = raw)
}

func solverOutcomeOf(name: in String, captured: in CaptureResult): SolverOutcome {
  if captured.timedOut {
    return Unknown(reason = name + " timed out (killed after 10 s)")
  }
  // Both solvers run under a 5 s limit (`-T:5`, `--tlimit=5000`): z3 prints
  // `timeout` when it is reached, cvc5 reports being interrupted by it.
  if solverTimedOut(captured.stdout) or solverTimedOut(captured.stderr) {
    return Unknown(reason = name + " reached its 5 s time limit")
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
    Unknown(reason = name + " returned unknown")
  } else if firstLine.startsWith("(error") {
    // The query itself was malformed: a verifier bug, never a property of
    // the program.  It stays a failed goal (#8102).
    Unknown(reason = solverRejectedMarker() + firstLine)
  } else {
    Unknown(reason = name + " returned unexpected output: " + firstLine)
  }
}

// Whether a solver's output says it stopped at its time limit.
func solverTimedOut(output: in String): Bool {
  val first = firstNonEmptyLine(output)
  first == "timeout" or first.contains("interrupted by timeout")
}

// Prefixes the reason of an `Unknown` outcome whose query the solver
// rejected; the rest of the reason is the solver's own text.
pub func solverRejectedMarker(): String {
  "solver rejected the query: "
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

pub func invokeZ3(z3Path: in String, smtSource: in String): SolverExchange {
  val args: List[String] = newList()
  args.add("-in")
  args.add("-T:5")
  invokeSolver("z3", z3Path, args, smtSource)
}

pub func invokeCvc5(cvc5Path: in String, smtSource: in String): SolverExchange {
  val args: List[String] = newList()
  args.add("--lang=smt2")
  args.add("--tlimit=5000")
  args.add("--produce-models")
  args.add("-")
  invokeSolver("cvc5", cvc5Path, args, smtSource)
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Public discharge function.
// ─────────────────────────────────────────────────────────────────────────────
pub func discharge(g: in Goal): SolverOutcome {
  dischargeExchange(g).outcome
}

/// Decide `g` as `discharge` does, keeping who decided it and the solver's
/// raw response (#8320).
pub func dischargeExchange(g: in Goal): SolverExchange {
  match trivialDischarge(g) {
    case Some(outcome) -> SolverExchange(outcome = outcome, decidedBy = trivialDischargerName(), response = "")
    case None -> {
      val smtSrc = smtRenderGoal(g)
      match findZ3() {
        case Some(z3) -> invokeZ3(z3, smtSrc)
        case None -> {
          match findCvc5() {
            case Some(cvc5) -> invokeCvc5(cvc5, smtSrc)
            case None -> SolverExchange(
              outcome = Unknown(
                reason = "no SMT solver available (set LYRIC_Z3 or LYRIC_CVC5, or install z3/cvc5)"
              ),
              decidedBy = noSolverName(),
              response = ""
            )
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
  Env.isWindows()
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
