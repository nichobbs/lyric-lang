//! jacoco_cobertura.l — JaCoCo XML report -> Cobertura XML report converter.
//!
//! Backs `lyric test --target jvm --coverage` (docs/03-decision-log.md).
//! JaCoCo's own `jacococli.jar report --xml` output uses JaCoCo's native
//! report schema (`report.dtd`), not the Cobertura schema that most CI
//! coverage tooling (Codecov, GitHub coverage actions, coverage-badge
//! generators) expects. This module is a pure-Lyric, dependency-free
//! translator between the two — no F#, no new host shim, just an AST walk
//! over `Std.Xml`'s parse tree and a hand-built Cobertura XML string.
//!
//! Fidelity notes (the schemas are not 1:1):
//!   - Cobertura's per-line `hits` field means "number of times this line
//!     executed"; JaCoCo's `<line>` element only records missed/covered
//!     *instruction* and *branch* counts, not an execution count. Per the
//!     conventional JaCoCo->Cobertura mapping used by every existing
//!     converter (e.g. the community `cover2cover.py` script), a covered
//!     line (`ci > 0`) is reported as `hits="1"`; an uncovered line
//!     (`ci == 0`) as `hits="0"`. This is lossy but is the accepted
//!     convention — Cobertura consumers care about line-covered/line-total,
//!     not true hit counts.
//!   - `line-rate` / `branch-rate` are computed from JaCoCo's own `LINE`
//!     and `BRANCH` `<counter>` elements at class/package/report scope
//!     (covered / (covered + missed)); a scope with zero of that counter
//!     type (e.g. a branch-free class) reports a rate of `1.0`, matching
//!     Cobertura's own convention for "nothing to miss".
//!   - `complexity` is always emitted as `0` — JaCoCo's `COMPLEXITY`
//!     counter is a McCabe complexity *count*, not a rate, and Cobertura's
//!     schema wants a per-class/method complexity score that has no direct
//!     JaCoCo analog worth fabricating.
//!   - `<sources>` always emits a single `.` entry — the JaCoCo XML report
//!     does not carry the original source-root path(s) used to build it.
@runtime_checked
package Lyric.JacocoCobertura

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Xml as Xml
import Std.Parse as Parse
import Std.Format as Format

pub union CoberturaError {
  case XmlParseError(message: String)
  case MissingReportRoot
}

pub func CoberturaError.message(e: in CoberturaError): String {
  match e {
    case XmlParseError(m) -> "failed to parse JaCoCo XML report: " + m
    case MissingReportRoot -> "JaCoCo XML report has no <report> root element"
  }
}

// ── XML text helpers ─────────────────────────────────────────────────────────
func xmlEscape(s: in String): String {
  var r = Str.replace(s, "&", "&amp;")
  r = Str.replace(r, "<", "&lt;")
  r = Str.replace(r, ">", "&gt;")
  r = Str.replace(r, "\"", "&quot;")
  r
}

func slashToDotted(s: in String): String {
  Str.replace(s, "/", ".")
}

// ── Tree-walk helpers ────────────────────────────────────────────────────────
// Direct (non-recursive) element children matching `tag`.  `Std.Xml.findAll`
// walks every descendant, which would also pick up e.g. a class's nested
// `<method>` counters when looking for a package's own `<counter>` children —
// this stays scoped to one level, matching the JaCoCo report's own nesting
// (report > package > {class, sourcefile, counter}, class > {method, counter}).
func directChildren(node: in Xml.XmlNode, tag: in String): List[Xml.XmlNode] {
  val result: List[Xml.XmlNode] = newList()
  val kids = Xml.elementChildren(node)
  var i = 0
  while i < kids.count {
    match Xml.elementTag(kids[i]) {
      case Some(t) -> {
        if t == tag {
          result.add(kids[i])
        }
      }
      case None -> ()
    }
    i += 1
  }
  result
}

func attrInt(node: in Xml.XmlNode, name: in String): Int {
  match Xml.getAttribute(node, name) {
    case Some(v) -> match Parse.parseOptInt(v) { case Some(i) -> i; case None -> 0 }
    case None -> 0
  }
}

func attrOr(node: in Xml.XmlNode, name: in String, fallback: in String): String {
  match Xml.getAttribute(node, name) {
    case Some(v) -> v
    case None -> fallback
  }
}

record Counter {
  covered: Int
  missed: Int
}

func zeroCounter(): Counter {
  Counter(covered = 0, missed = 0)
}

// Find a direct `<counter type="...">` child of `node` by counter type
// (INSTRUCTION / BRANCH / LINE / COMPLEXITY / METHOD / CLASS); zero if absent.
func findCounter(node: in Xml.XmlNode, counterType: in String): Counter {
  val counters = directChildren(node, "counter")
  var i = 0
  var result = zeroCounter()
  var found = false
  while i < counters.count and not found {
    match Xml.getAttribute(counters[i], "type") {
      case Some(t) -> {
        if t == counterType {
          found = true
          result = Counter(covered = attrInt(counters[i], "covered"), missed = attrInt(counters[i], "missed"))
        }
      }
      case None -> ()
    }
    i += 1
  }
  result
}

func rateOf(c: in Counter): Double {
  val total = c.covered + c.missed
  if total == 0 {
    1.0
  } else {
    c.covered.toDouble() / total.toDouble()
  }
}

func addCounter(a: in Counter, b: in Counter): Counter {
  Counter(covered = a.covered + b.covered, missed = a.missed + b.missed)
}

func fmtRate(r: in Double): String {
  Format.formatFixed(r, 4)
}

// ── Per-sourcefile line-hit lookup ───────────────────────────────────────────
record LineHit {
  number: Int
  hits: Int
  branch: Bool
}

func parseSourcefileLines(sourcefile: in Xml.XmlNode): List[LineHit] {
  val result: List[LineHit] = newList()
  val lines = directChildren(sourcefile, "line")
  var i = 0
  while i < lines.count {
    val ln = lines[i]
    val ci = attrInt(ln, "ci")
    val mb = attrInt(ln, "mb")
    val cb = attrInt(ln, "cb")
    result.add(LineHit(number = attrInt(ln, "nr"), hits = if ci > 0 { 1 } else { 0 }, branch = mb + cb > 0))
    i += 1
  }
  result
}

func findSourcefile(pkg: in Xml.XmlNode, name: in String): Option[Xml.XmlNode] {
  val sfs = directChildren(pkg, "sourcefile")
  var i = 0
  var result: Option[Xml.XmlNode] = None
  while i < sfs.count and isNone(result) {
    if attrOr(sfs[i], "name", "") == name {
      result = Some(value = sfs[i])
    }
    i += 1
  }
  result
}

func linesXml(lines: in List[LineHit]): String {
  var outXml = "<lines>"
  var i = 0
  while i < lines.count {
    val l = lines[i]
    if l.branch {
      outXml = outXml + "<line number=\"" + toString(l.number) + "\" hits=\"" + toString(l.hits) + "\" branch=\"true\"/>"
    } else {
      outXml = outXml + "<line number=\"" + toString(l.number) + "\" hits=\"" + toString(l.hits) + "\" branch=\"false\"/>"
    }
    i += 1
  }
  outXml + "</lines>"
}

// ── Method-level XML ─────────────────────────────────────────────────────────
func methodXml(method: in Xml.XmlNode, allLines: in List[LineHit]): String {
  val name = attrOr(method, "name", "")
  val desc = attrOr(method, "desc", "()V")
  val startLine = attrInt(method, "line")
  val lineRate = rateOf(findCounter(method, "LINE"))
  val branchRate = rateOf(findCounter(method, "BRANCH"))
  var hits = 0
  var i = 0
  while i < allLines.count {
    if allLines[i].number == startLine {
      hits = allLines[i].hits
    }
    i += 1
  }
  val startLineHit: List[LineHit] = newList()
  startLineHit.add(LineHit(number = startLine, hits = hits, branch = false))
  "<method name=\"" + xmlEscape(name) + "\" signature=\"" + xmlEscape(desc) + "\" line-rate=\"" + fmtRate(lineRate) +
    "\" branch-rate=\"" +
    fmtRate(branchRate) +
    "\">" +
    linesXml(startLineHit) +
    "</method>"
}

// ── Class-level XML ──────────────────────────────────────────────────────────
// Resolves the class's own source-line hit list by finding the package's
// matching `<sourcefile>` sibling (classes carry no line data of their own —
// only per-method counter summaries — the full line table lives on the
// package's `<sourcefile>` element, keyed by `sourcefilename`).
func classXml(cls: in Xml.XmlNode, pkg: in Xml.XmlNode, pkgPathSlash: in String): String {
  val nameSlash = attrOr(cls, "name", "")
  val sourceFileName = attrOr(cls, "sourcefilename", "")
  // Cobertura's `filename` is the source-relative path; JaCoCo's class
  // `name` already carries the package path, so swap the trailing class
  // name for the source file's own name.
  val filename = if pkgPathSlash.length > 0 { pkgPathSlash + "/" + sourceFileName } else { sourceFileName }
  val dottedClassName = slashToDotted(nameSlash)
  val lineRate = rateOf(findCounter(cls, "LINE"))
  val branchRate = rateOf(findCounter(cls, "BRANCH"))

  val allLines: List[LineHit] = match findSourcefile(pkg, sourceFileName) {
    case Some(sf) -> parseSourcefileLines(sf)
    case None -> newList()
  }

  var methodsXml = "<methods>"
  val methods = directChildren(cls, "method")
  var mi = 0
  while mi < methods.count {
    methodsXml = methodsXml + methodXml(methods[mi], allLines)
    mi += 1
  }
  methodsXml = methodsXml + "</methods>"

  "<class name=\"" + xmlEscape(dottedClassName) + "\" filename=\"" + xmlEscape(filename) + "\" line-rate=\"" +
    fmtRate(lineRate) +
    "\" branch-rate=\"" +
    fmtRate(branchRate) +
    "\" complexity=\"0\">" +
    methodsXml +
    linesXml(allLines) +
    "</class>"
}

// ── Package-level XML ────────────────────────────────────────────────────────
func packageXml(pkg: in Xml.XmlNode): (String, Counter, Counter) {
  val nameSlash = attrOr(pkg, "name", "")
  val dottedName = slashToDotted(nameSlash)
  val lineCounter = findCounter(pkg, "LINE")
  val branchCounter = findCounter(pkg, "BRANCH")

  var classesXml = "<classes>"
  val classes = directChildren(pkg, "class")
  var ci = 0
  while ci < classes.count {
    classesXml = classesXml + classXml(classes[ci], pkg, nameSlash)
    ci += 1
  }
  classesXml = classesXml + "</classes>"

  val xml = "<package name=\"" + xmlEscape(dottedName) + "\" line-rate=\"" + fmtRate(rateOf(lineCounter)) +
    "\" branch-rate=\"" +
    fmtRate(rateOf(branchCounter)) +
    "\" complexity=\"0\">" +
    classesXml +
    "</package>";
  (xml, lineCounter, branchCounter)
}

// ── Top-level entry point ────────────────────────────────────────────────────
/// Convert a JaCoCo XML report (as produced by
/// `java -jar jacococli.jar report <exec> --xml <file>`) into a Cobertura
/// XML report string. See the module header for the fidelity notes on the
/// (necessarily lossy) schema mapping.
pub func jacocoXmlToCobertura(jacocoXml: in String): Result[String, CoberturaError] {
  val doc = match Xml.parseXml(jacocoXml) {
    case Ok(d) -> d
    case Err(e) -> return Err(error = XmlParseError(message = e.message()))
  }
  val root = Xml.documentRoot(doc)
  match Xml.elementTag(root) {
    case Some(t) -> {
      if t != "report" {
        return Err(error = MissingReportRoot)
      }
    }
    case None -> return Err(error = MissingReportRoot)
  }

  val packages = directChildren(root, "package")
  var packagesXml = "<packages>"
  var totalLine = zeroCounter()
  var totalBranch = zeroCounter()
  var pi = 0
  while pi < packages.count {
    val (pkgXml, lineC, branchC) = packageXml(packages[pi])
    packagesXml = packagesXml + pkgXml
    totalLine = addCounter(totalLine, lineC)
    totalBranch = addCounter(totalBranch, branchC)
    pi += 1
  }
  packagesXml = packagesXml + "</packages>"

  // Prefer the session dump timestamp (epoch millis, already what Cobertura
  // expects) when present; fall back to "0" for a hand-built/test report
  // that omits `<sessioninfo>`.
  var timestamp = "0"
  match Xml.findFirst(root, "sessioninfo") {
    case Some(si) -> {
      timestamp = attrOr(si, "dump", "0")
    }
    case None -> ()
  }

  val outXml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + "<coverage line-rate=\"" + fmtRate(rateOf(totalLine)) +
    "\" branch-rate=\"" +
    fmtRate(rateOf(totalBranch)) +
    "\" lines-covered=\"" +
    toString(totalLine.covered) +
    "\" lines-valid=\"" +
    toString(totalLine.covered + totalLine.missed) +
    "\" branches-covered=\"" +
    toString(totalBranch.covered) +
    "\" branches-valid=\"" +
    toString(totalBranch.covered + totalBranch.missed) +
    "\" complexity=\"0\" version=\"lyric-jacoco-cobertura-1\" timestamp=\"" +
    timestamp +
    "\">" +
    "<sources><source>.</source></sources>" +
    packagesXml +
    "</coverage>"
  Ok(value = outXml)
}
