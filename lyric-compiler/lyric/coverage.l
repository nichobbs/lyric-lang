//! coverage.l — statement-level line coverage for `lyric test --coverage`
//! (#5294, D246).
//!
//! `instrumentSource` rewrites a source file so that every statement of every
//! function body starts with a call `__lyric_cov.hit(<id>); `, where
//! `__lyric_cov` is `import Std.Coverage as __lyric_cov`, added on the
//! `package` line.  Every insertion is text on the line the statement (or the
//! package declaration) is already on, so no line of the file moves.  One
//! rewrite feeds the MSIL and the JVM backend, which is what makes the two
//! targets report the same lines by construction.  `Std.Coverage` counts the
//! hits; the test binary writes them to the file named by
//! `LYRIC_COVERAGE_OUT` when its `main` ends (`TestSynth.withCoverageDump`),
//! and `lcovReport` / `coberturaReport` / `summaryText` turn the ids back into
//! source lines.
//!
//! Left as written, with no points: a file that does not parse, a file of a
//! `@pure`, `@proof_required` or `@axiom` package (a call to the counter would
//! fail the effect and proof checks), a package of the standard library (it
//! is what the counter is built from, so instrumenting it would be a cycle),
//! and a function annotated `@pure` or `@axiom`.  A `test` item is not a
//! function until the test runner rewrites it, which happens after this pass,
//! so tests are never counted; the helper functions of a test module are.
package Lyric.Coverage

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Char
import Lyric.Lexer
import Lyric.Parser

/// A counted statement: `id` is what the inserted call passes to
/// `Std.Coverage.hit`, `line` the source line the statement starts on.
pub record CoverPoint {
  id: Int
  line: Int
}

/// A function whose body has counted statements: `line` is where the function
/// is declared, `entryId` the id of its first counted statement.
pub record CoverFunction {
  name: String
  line: Int
  entryId: Int
}

/// What one file contributes to a coverage run.
pub record CoverFile {
  path: String
  points: List[CoverPoint]
  functions: List[CoverFunction]
}

/// The files of one coverage run and the id the next instrumented file starts
/// at (`next[0]`).
pub record CoverSession {
  files: List[CoverFile]
  next: List[Int]
}

pub func newSession(): CoverSession {
  val next: List[Int] = newList()
  next.add(0)
  CoverSession(files = newList(), next = next)
}

pub record InstrumentResult {
  source: String
  file: CoverFile
  /// The id the next file starts at.
  nextId: Int
}

record Insertion {
  offset: Int
  text: String
}

// One file's walk: the next id (`nextId[0]`), the insertions made and the
// points and functions recorded.
record Walk {
  nextId: List[Int]
  insertions: List[Insertion]
  points: List[CoverPoint]
  functions: List[CoverFunction]
}

/// `rawSource` instrumented as part of `session` (ids continue where the
/// session's last file stopped, and the file is recorded in it); returns the
/// new text.  The file is returned as it is when it is not instrumented.
pub func instrumentInto(session: in CoverSession, rawSource: in String, path: in String): String {
  val r = instrumentSource(rawSource, path, session.next[0])
  if r.file.points.count > 0 {
    session.files.add(r.file)
    session.next[0] = r.nextId
  }
  r.source
}

/// A test module prepared for a coverage run: with `countHelpers` its helper
/// functions are instrumented like any other code under test, and in any case
/// the module gets the counter import its synthesised `main` calls to dump the
/// counts.
pub func instrumentTestModule(
  session: in CoverSession, rawSource: in String, path: in String, countHelpers: in Bool
): String {
  val body = if countHelpers { instrumentInto(session, rawSource, path) } else { rawSource }
  withCounterImport(body)
}

// `source` with the counter import on its `package` line, unless it has it.
func withCounterImport(source: in String): String {
  if Str.contains(source, "import Std.Coverage as __lyric_cov") {
    return source
  }
  val pf = parse(source)
  for d in pf.diagnostics {
    match d.severity {
      case DiagError -> return source
      case _ -> ()
    }
  }
  val at = pf.file.packageDecl.span.endPos.offset
  pf.source.substring(0, at) + "; import Std.Coverage as __lyric_cov" + pf.source.substring(at, pf.source.length - at)
}

func annotationNamed(anns: in List[Annotation], name: in String): Bool {
  for a in anns {
    if a.name.segments.count == 1 and a.name.segments[0] == name {
      return true
    }
  }
  false
}

func skipsFile(file: in SourceFile): Bool {
  var pkg = ""
  var i = 0
  while i < file.packageDecl.path.segments.count {
    pkg = if i == 0 { file.packageDecl.path.segments[i] } else { pkg + "." + file.packageDecl.path.segments[i] }
    i += 1
  }
  pkg == "Std" or Str.startsWith(pkg, "Std.") or annotationNamed(file.fileAnnotations, "pure") or
    annotationNamed(file.fileAnnotations, "proof_required") or
    annotationNamed(file.fileAnnotations, "axiom")
}

/// `rawSource` with a counter call at the start of every statement of every
/// function body, ids starting at `firstId`; `path` names the file in the
/// report.
pub func instrumentSource(rawSource: in String, path: in String, firstId: in Int): InstrumentResult {
  val pf = parse(rawSource)
  val noPoints: List[CoverPoint] = newList()
  val noFunctions: List[CoverFunction] = newList()
  val untouched = InstrumentResult(
    source = rawSource,
    file = CoverFile(path = path, points = noPoints, functions = noFunctions),
    nextId = firstId
  )
  for d in pf.diagnostics {
    match d.severity {
      case DiagError -> return untouched
      case _ -> ()
    }
  }
  if skipsFile(pf.file) {
    return untouched
  }
  val ids: List[Int] = newList()
  ids.add(firstId)
  val w = Walk(nextId = ids, insertions = newList(), points = newList(), functions = newList())
  for item in pf.file.items {
    walkItem(w, item)
  }
  if w.insertions.count == 0 {
    return untouched
  }
  w.insertions.add(
    Insertion(offset = pf.file.packageDecl.span.endPos.offset, text = "; import Std.Coverage as __lyric_cov")
  )
  InstrumentResult(
    source = applyInsertions(pf.source, w.insertions),
    file = CoverFile(path = path, points = w.points, functions = w.functions),
    nextId = w.nextId[0]
  )
}

// The insertions in offset order (a stable insertion sort: equal offsets keep
// the order they were made in).
func applyInsertions(source: in String, ins: in List[Insertion]): String {
  val order: List[Insertion] = newList()
  for x in ins {
    order.add(x)
    var at = order.count - 1
    while at > 0 and order[at - 1].offset > x.offset {
      order[at] = order[at - 1]
      at -= 1
    }
    order[at] = x
  }
  var sb = ""
  var cursor = 0
  for x in order {
    if x.offset > cursor {
      sb = sb + source.substring(cursor, x.offset - cursor)
      cursor = x.offset
    }
    sb = sb + x.text
  }
  if cursor < source.length {
    sb = sb + source.substring(cursor, source.length - cursor)
  }
  sb
}

func walkItem(w: in Walk, item: in Item): Unit {
  match item.kind {
    case IFunc(fn) -> walkFunction(w, fn)
    case IRecord(r) -> walkRecordMembers(w, r.members)
    case IExposedRec(r) -> walkRecordMembers(w, r.members)
    case IImpl(im) -> {
      for m in im.members {
        match m {
          case IMplFunc(fn) -> walkFunction(w, fn)
          case _ -> ()
        }
      }
    }
    case IInterface(i) -> {
      for m in i.members {
        match m {
          case IMFunc(fn) -> walkFunction(w, fn)
          case _ -> ()
        }
      }
    }
    case _ -> ()
  }
}

func walkRecordMembers(w: in Walk, members: in List[RecordMember]): Unit {
  for m in members {
    match m {
      case RMFunc(fn) -> walkFunction(w, fn)
      case _ -> ()
    }
  }
}

func walkFunction(w: in Walk, fn: in FunctionDecl): Unit {
  if annotationNamed(fn.annotations, "pure") or annotationNamed(fn.annotations, "axiom") {
    return
  }
  match fn.body {
    case Some(body) -> {
      match body {
        case FBBlock(block) -> {
          val before = w.points.count
          walkBlock(w, block)
          if w.points.count > before {
            w.functions.add(CoverFunction(name = fn.name, line = fn.span.startPos.line, entryId = w.points[before].id))
          }
        }
        case FBExpr(e) -> walkExpr(w, e)
      }
    }
    case None -> ()
  }
}

func walkBlock(w: in Walk, block: in Block): Unit {
  for st in block.statements {
    if countable(st) {
      val id = w.nextId[0]
      w.nextId[0] = id + 1
      w.insertions.add(Insertion(offset = st.span.startPos.offset, text = "__lyric_cov.hit(" + toString(id) + "); "))
      w.points.add(CoverPoint(id = id, line = st.span.startPos.line))
    }
    walkStatement(w, st)
  }
}

// A loop `invariant:` and a local item are not code that runs on its own, and
// a call inserted before them would change what they attach to.
func countable(st: in Statement): Bool {
  match st.kind {
    case SInvariant(_) -> false
    case SRule(_, _) -> false
    case SItem(_) -> false
    case _ -> true
  }
}

func walkStatement(w: in Walk, st: in Statement): Unit {
  match st.kind {
    case SLocal(b) -> {
      match b {
        case LBVal(_, _, init) -> walkExpr(w, init)
        case LBVar(_, _, init) -> {
          match init {
            case Some(e) -> walkExpr(w, e)
            case None -> ()
          }
        }
        case LBLet(_, _, init) -> walkExpr(w, init)
      }
    }
    case SAssign(target, _, value) -> {
      walkExpr(w, target)
      walkExpr(w, value)
    }
    case SReturn(v) -> {
      match v {
        case Some(e) -> walkExpr(w, e)
        case None -> ()
      }
    }
    case SThrow(e) -> walkExpr(w, e)
    case STry(body, catches, fin) -> {
      walkBlock(w, body)
      for c in catches {
        walkBlock(w, c.body)
      }
      match fin {
        case Some(b) -> walkBlock(w, b)
        case None -> ()
      }
    }
    case SDefer(b) -> walkBlock(w, b)
    case SScope(_, b) -> walkBlock(w, b)
    case SFor(_, _, iter, body) -> {
      walkExpr(w, iter)
      walkBlock(w, body)
    }
    case SWhile(_, cond, body) -> {
      walkExpr(w, cond)
      walkBlock(w, body)
    }
    case SLoop(_, body) -> walkBlock(w, body)
    case SExpr(e) -> walkExpr(w, e)
    case _ -> ()
  }
}

func walkExprOrBlock(w: in Walk, eb: in ExprOrBlock): Unit {
  match eb {
    case EOBExpr(e) -> walkExpr(w, e)
    case EOBBlock(b) -> walkBlock(w, b)
  }
}

func walkExprs(w: in Walk, es: in List[Expr]): Unit {
  for e in es {
    walkExpr(w, e)
  }
}

// Every block reachable from an expression: the branches of an `if`, the arms
// of a `match`, a lambda body, a block expression.
func walkExpr(w: in Walk, e: in Expr): Unit {
  match e.kind {
    case EParen(inner) -> walkExpr(w, inner)
    case ETuple(xs) -> walkExprs(w, xs)
    case EList(xs) -> walkExprs(w, xs)
    case EIf(cond, thenB, elseB, _) -> {
      walkExpr(w, cond)
      walkExprOrBlock(w, thenB)
      match elseB {
        case Some(b) -> walkExprOrBlock(w, b)
        case None -> ()
      }
    }
    case EMatch(scrut, arms) -> {
      walkExpr(w, scrut)
      for arm in arms {
        match arm.guard {
          case Some(g) -> walkExpr(w, g)
          case None -> ()
        }
        walkExprOrBlock(w, arm.body)
      }
    }
    case EAwait(x) -> walkExpr(w, x)
    case ESpawn(x) -> walkExpr(w, x)
    case ETry(x) -> walkExpr(w, x)
    case ELambda(_, body) -> walkBlock(w, body)
    case ECall(fn, args) -> {
      walkExpr(w, fn)
      for a in args {
        match a {
          case CANamed(_, v, _) -> walkExpr(w, v)
          case CAPositional(x) -> walkExpr(w, x)
        }
      }
    }
    case EIndex(recv, idx) -> {
      walkExpr(w, recv)
      walkExprs(w, idx)
    }
    case EMember(recv, _) -> walkExpr(w, recv)
    case EPropagate(x) -> walkExpr(w, x)
    case EPrefix(_, x) -> walkExpr(w, x)
    case EBinop(_, l, r) -> {
      walkExpr(w, l)
      walkExpr(w, r)
    }
    case EAssign(t, _, v) -> {
      walkExpr(w, t)
      walkExpr(w, v)
    }
    case EBlock(b) -> walkBlock(w, b)
    case _ -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hits and reports
// ─────────────────────────────────────────────────────────────────────────────
/// Sums the `<id> <count>` lines `Std.Coverage.dumpFromEnv` wrote into `hits`,
/// which has one slot per id of the session (`emptyHits`).  A line that is not
/// two numbers is ignored.
pub func addHits(hits: in List[Int], text: in String): Unit {
  for line in Str.split(text, "\n") {
    val parts = Str.split(Str.trim(line), " ")
    if parts.length == 2 {
      val id = digitsToInt(parts[0])
      val n = digitsToInt(parts[1])
      if id >= 0 and n >= 0 and id < hits.count {
        hits[id] = hits[id] + n
      }
    }
  }
}

// The non-negative integer `s` spells, or -1.
func digitsToInt(s: in String): Int {
  if s.length == 0 {
    return -1
  }
  var acc = 0
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    if c < '0' or c > '9' {
      return -1
    }
    acc = acc * 10 + (toInt(c) - toInt('0'))
    i += 1
  }
  acc
}

/// A zeroed hit table for `session`.
pub func emptyHits(session: in CoverSession): List[Int] {
  val hits: List[Int] = newList()
  var i = 0
  while i < session.next[0] {
    hits.add(0)
    i += 1
  }
  hits
}

// One source line of a file: how often its counted statements ran (the most
// any of them did).
record LineHit {
  line: Int
  hits: Int
}

// The file's lines in order, each with its hit count.
func lineHits(file: in CoverFile, hits: in List[Int]): List[LineHit] {
  val lines: List[LineHit] = newList()
  for p in file.points {
    val n = if p.id < hits.count { hits[p.id] } else { 0 }
    var at = 0
    while at < lines.count and lines[at].line < p.line {
      at += 1
    }
    if at < lines.count and lines[at].line == p.line {
      if n > lines[at].hits {
        lines[at] = LineHit(line = p.line, hits = n)
      }
    } else {
      lines.add(LineHit(line = p.line, hits = n))
      var k = lines.count - 1
      while k > at {
        lines[k] = lines[k - 1]
        k -= 1
      }
      lines[at] = LineHit(line = p.line, hits = n)
    }
  }
  lines
}

/// The lines of a file (or a run) that ran, and the lines that could.
pub record FileTotals {
  covered: Int
  total: Int
}

pub func fileTotals(file: in CoverFile, hits: in List[Int]): FileTotals {
  var covered = 0
  val ls = lineHits(file, hits)
  for l in ls {
    if l.hits > 0 {
      covered += 1
    }
  }
  FileTotals(covered = covered, total = ls.count)
}

pub func sessionTotals(session: in CoverSession, hits: in List[Int]): FileTotals {
  var covered = 0
  var total = 0
  for f in session.files {
    val t = fileTotals(f, hits)
    covered += t.covered
    total += t.total
  }
  FileTotals(covered = covered, total = total)
}

/// `part` of `whole` as a percentage with one decimal ("100.0", "83.3");
/// an empty whole is fully covered.
pub func percentText(part: in Int, whole: in Int): String {
  if whole == 0 {
    return "100.0"
  }
  val tenths = (part * 1000 + whole / 2) / whole
  toString(tenths / 10) + "." + toString(tenths % 10)
}

/// Whether `totals` reach `minPercent` percent.
pub func meetsMinimum(totals: in FileTotals, minPercent: in Int): Bool {
  totals.covered * 100 >= minPercent * totals.total
}

/// The run as an lcov tracefile: `SF`, `FN`/`FNDA`/`FNF`/`FNH`, `DA` and
/// `LF`/`LH` for every instrumented file.
pub func lcovReport(session: in CoverSession, hits: in List[Int]): String {
  var sb = ""
  for f in session.files {
    sb = sb + "TN:\nSF:" + f.path + "\n"
    var fnHit = 0
    for fn in f.functions {
      sb = sb + "FN:" + toString(fn.line) + "," + fn.name + "\n"
    }
    for fn in f.functions {
      val n = if fn.entryId < hits.count { hits[fn.entryId] } else { 0 }
      sb = sb + "FNDA:" + toString(n) + "," + fn.name + "\n"
      if n > 0 {
        fnHit += 1
      }
    }
    sb = sb + "FNF:" + toString(f.functions.count) + "\nFNH:" + toString(fnHit) + "\n"
    val ls = lineHits(f, hits)
    var covered = 0
    for l in ls {
      sb = sb + "DA:" + toString(l.line) + "," + toString(l.hits) + "\n"
      if l.hits > 0 {
        covered += 1
      }
    }
    sb = sb + "LF:" + toString(ls.count) + "\nLH:" + toString(covered) + "\nend_of_record\n"
  }
  sb
}

func xmlEscape(s: in String): String {
  Str.replace(Str.replace(Str.replace(Str.replace(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"), "\"", "&quot;")
}

// Cobertura rates are fractions: "1", "0.5", "0.833".
func rateText(part: in Int, whole: in Int): String {
  if whole == 0 or part >= whole {
    return "1"
  }
  val thousandths = (part * 1000 + whole / 2) / whole
  val pad = if thousandths < 10 { "00" } else if thousandths < 100 { "0" } else { "" }
  "0." + pad + toString(thousandths)
}

/// The run as a Cobertura XML report, one class per instrumented file.
pub func coberturaReport(session: in CoverSession, hits: in List[Int]): String {
  val totals = sessionTotals(session, hits)
  val rate = rateText(totals.covered, totals.total)
  var sb = "<?xml version=\"1.0\" ?>\n"
  sb = sb + "<coverage line-rate=\"" + rate + "\" branch-rate=\"1\" lines-covered=\"" + toString(totals.covered) +
    "\" lines-valid=\"" +
    toString(totals.total) +
    "\" branches-covered=\"0\" branches-valid=\"0\" complexity=\"0\" version=\"1\" timestamp=\"0\">\n"
  sb = sb + "  <packages>\n    <package name=\"lyric\" line-rate=\"" + rate +
    "\" branch-rate=\"1\" complexity=\"0\">\n      <classes>\n"
  for f in session.files {
    val t = fileTotals(f, hits)
    sb = sb + "        <class name=\"" + xmlEscape(f.path) + "\" filename=\"" + xmlEscape(f.path) + "\" line-rate=\"" +
      rateText(t.covered, t.total) +
      "\" branch-rate=\"1\" complexity=\"0\">\n          <methods/>\n          <lines>\n"
    for l in lineHits(f, hits) {
      sb = sb + "            <line number=\"" + toString(l.line) + "\" hits=\"" + toString(l.hits) + "\"/>\n"
    }
    sb = sb + "          </lines>\n        </class>\n"
  }
  sb + "      </classes>\n    </package>\n  </packages>\n</coverage>\n"
}

/// The console summary: one row per file and the total.
pub func summaryText(session: in CoverSession, hits: in List[Int]): String {
  var sb = "coverage (statement lines):\n"
  for f in session.files {
    val t = fileTotals(f, hits)
    sb = sb + "  " + percentText(t.covered, t.total) + "%  " + toString(t.covered) + "/" + toString(t.total) + "  " +
      f.path +
      "\n"
  }
  val all = sessionTotals(session, hits)
  sb + "  total: " + percentText(all.covered, all.total) + "%  " + toString(all.covered) + "/" + toString(all.total) +
    "\n"
}
