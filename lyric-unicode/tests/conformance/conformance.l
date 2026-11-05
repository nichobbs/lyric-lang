//! conformance.l - Unicode.Conformance: Unicode's own conformance suites for
//! `Unicode.Bidi` (UAX #9), `Unicode.LineBreak` (UAX #14) and `Unicode.WordBreak` (UAX #29), Unicode 16.0
//! (#8498, #8497).
//!
//! The suites are vendored, unchanged, next to this file with the Unicode licence
//! (`LICENSE-UNICODE.txt`), and pinned here by SHA-256, so a run never fetches anything:
//!
//!   BidiCharacterTest.txt  https://www.unicode.org/Public/16.0.0/ucd/BidiCharacterTest.txt
//!   LineBreakTest.txt      https://www.unicode.org/Public/16.0.0/ucd/auxiliary/LineBreakTest.txt
//!   WordBreakTest.txt      https://www.unicode.org/Public/16.0.0/ucd/auxiliary/WordBreakTest.txt
//!
//! Every line of each file is run.  For `BidiCharacterTest.txt` that is the paragraph level, the
//! level of every character after rule L1 (characters X9 removes are `x` and not compared) and the
//! visual order of the line.  `conformance_tests.l` runs the suites on dotnet
//! and the JVM (`lyric test`), `main.l` on `--target native`, where manifest test suites do not run.
package Unicode.Conformance

import Std.Core
import Std.Collections
import Std.String
import Std.File
import Std.Path
import Std.Hash
import Std.Environment
import Std.Errors.{IOError}
import Unicode.Bidi
import Unicode.LineBreak
import Unicode.WordBreak
import Unicode.Data as UnicodeData

/// The SHA-256 of the vendored `BidiCharacterTest.txt` (Unicode 16.0.0).
pub val bidiCharacterTestSha256: String = "D04A51A90052DCD71C4E91EE5B3A9D973EE35C12406B5A99875AC8163C8F2804"

/// The SHA-256 of the vendored `LineBreakTest.txt` (Unicode 16.0.0).
pub val lineBreakTestSha256: String = "910759A611A479F37DF4F535D2E64D7589BE3C5AC5F7491CF1FB4FA4CDB211E9"

/// The SHA-256 of the vendored `WordBreakTest.txt` (Unicode 16.0.0).
pub val wordBreakTestSha256: String = "AD985D5721F3FA6B45495663DFE44180F2F68976100DEE0EA7451EF1A8F838E8"

/// The number of test lines in each vendored file.
pub val bidiCharacterTestCases: Int = 91707

pub val lineBreakTestCases: Int = 16672

pub val wordBreakTestCases: Int = 1826

// The most mismatches a report lists.
val maxReported: Int = 12

/// The outcome of one suite: how many lines it ran, how many differed, and the first of them.
pub record SuiteResult {
  cases: Int
  failures: Int
  report: String
}

val dataDir: String = "lyric-unicode/tests/conformance"

/// The path of a vendored file: in the directory the run started in, or below it or one of its
/// parents at `lyric-unicode/tests/conformance`, so a run works from this directory, from
/// `lyric-ui/native` and from the repository root.
pub func dataPath(name: in String): Result[String, String] {
  if fileExists(name) {
    return Ok(value = name)
  }
  val start = Environment.currentDirectory()
  var dir = start
  var steps = 0
  while steps < 32 {
    for rel in [dataDir, "tests/conformance"] {
      val candidate = Path.join(dir, Path.join(rel, name))
      if fileExists(candidate) {
        return Ok(value = candidate)
      }
    }
    if Path.isFilesystemRoot(dir) or Path.dirname(dir) == dir {
      steps = 32
    } else {
      dir = Path.dirname(dir)
      steps = steps + 1
    }
  }
  Err(error = "cannot find " + name + " in " + start + " or below it or a parent at " + dataDir)
}

/// The text of a vendored file, after checking it is the pinned revision.
pub func pinnedText(name: in String, sha256: in String): Result[String, String] {
  val path = match dataPath(name) { case Ok(p) -> p; case Err(e) -> return Err(error = e) }
  val bytes = match readBytes(path) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = "cannot read " + path + ": " + IOError.message(e))
  }
  val actual = sha256OfBytes(bytes)
  if actual != sha256 {
    return Err(error = path + " has SHA-256 " + actual + ", not the pinned Unicode 16.0 revision " + sha256)
  }
  match readText(path) {
    case Ok(t) -> Ok(value = t)
    case Err(e) -> Err(error = "cannot read " + path + ": " + IOError.message(e))
  }
}

func hexValue(s: String): Int {
  var v = 0
  var i = 0
  while i < s.length {
    val c = codeUnitAt(s, i)
    v = v * 16 + (if c >= 97 { c - 87 } else if c >= 65 { c - 55 } else { c - 48 })
    i = i + 1
  }
  v
}

func words(s: String): List[String] {
  val acc: List[String] = newList()
  for w in split(s, " ") {
    val t = trim(w)
    if t.length > 0 {
      acc.add(t)
    }
  }
  acc
}

// The text of a line before its comment, or "" for a comment or a blank line.
func contentOf(line: String): String {
  val hash = indexOfRaw(line, "#")
  trim(if hash >= 0 { substring(line, 0, hash) } else { line })
}

func isRemovedByX9(cp: Int): Bool {
  val t = UnicodeData.bidiClassOf(cp)
  t == 11 or t == 12 or t == 14 or t == 15 or t == 16 or t == 18
}

func joinInts(xs: List[Int]): String {
  var r = ""
  var first = true
  for x in xs {
    r = r + (if first { "" } else { " " }) + fromInt(x)
    first = false
  }
  r
}

/// The paragraph level, the levels after rule L1 and the visual order of `cps` as one line, in the
/// notation of `BidiCharacterTest.txt`: "level;levels;order", with `x` for a character X9 removes.
/// `direction` is the file's field 1: 0 left to right, 1 right to left, 2 from the text (P2, P3).
pub func bidiOutcome(cps: in slice[Int], direction: in Int): String {
  val n = cps.length
  val para = if direction == 2 { Bidi.paragraphLevelOf(cps, 0, n) } else { direction }
  val levels = Bidi.resolveLevels(cps, 0, n, para)
  val runs = Bidi.lineRuns(cps, 0, levels, 0, n, para)
  val lineLevel: List[Int] = newList()
  var i = 0
  while i < n {
    lineLevel.add(0)
    i = i + 1
  }
  val order: List[Int] = newList()
  for run in runs {
    var j = run.from
    while j < run.to {
      lineLevel[j] = run.level
      j = j + 1
    }
    val rtl = run.level % 2 == 1
    var k = if rtl { run.to - 1 } else { run.from }
    while k >= run.from and k < run.to {
      if not isRemovedByX9(cps[k]) {
        order.add(k)
      }
      k = k + (if rtl { 0 - 1 } else { 1 })
    }
  }
  var shown = ""
  i = 0
  while i < n {
    shown = shown + (if i == 0 { "" } else { " " }) + (if isRemovedByX9(cps[i]) { "x" } else { fromInt(lineLevel[i]) })
    i = i + 1
  }
  fromInt(para) + ";" + shown + ";" + joinInts(order)
}

/// Every line of `BidiCharacterTest.txt` (its text) through `Unicode.Bidi`.
pub func runBidiCharacterTest(text: in String): SuiteResult {
  var cases = 0
  var failures = 0
  var report = ""
  for line in split(text, "\n") {
    val content = contentOf(line)
    if content.length > 0 {
      val fields = split(content, ";")
      val cpsList: List[Int] = newList()
      for w in words(fields[0]) {
        cpsList.add(hexValue(w))
      }
      val expected = trim(fields[2]) + ";" + joinList(" ", words(fields[3])) + ";" + joinList(" ", words(fields[4]))
      val got = bidiOutcome(cpsList.toArray(), hexValue(trim(fields[1])))
      cases = cases + 1
      if got != expected {
        failures = failures + 1
        if failures <= maxReported {
          report = report + "\n  " + fields[0] + " (direction " + trim(fields[1]) + "): expected " + expected + ", got " + got
        }
      }
    }
  }
  SuiteResult(cases = cases, failures = failures, report = report)
}

/// Every line of `LineBreakTest.txt` (its text) through `Unicode.LineBreak`.
pub func runLineBreakTest(text: in String): SuiteResult {
  runBoundaryTest(text, { cps: slice[Int] -> lineBreaksOf(cps) })
}

/// Every line of `WordBreakTest.txt` (its text) through `Unicode.WordBreak`.
pub func runWordBreakTest(text: in String): SuiteResult {
  runBoundaryTest(text, { cps: slice[Int] -> WordBreak.boundariesIn(cps, 0, cps.length) })
}

func lineBreaksOf(cps: slice[Int]): List[Bool] {
  val acc: List[Bool] = newList()
  for b in LineBreak.breaksIn(cps, 0, cps.length) {
    acc.add(b != LineBreak.noBreak)
  }
  acc
}

// A suite in the notation of `LineBreakTest.txt` and `WordBreakTest.txt`: code points with `÷` at
// every boundary and `×` where there is none.  `boundaries` gives, for the code points of a line,
// one answer per position (start and end included; those are not compared).
func runBoundaryTest(text: String, boundaries: (slice[Int]) -> List[Bool]): SuiteResult {
  var cases = 0
  var failures = 0
  var report = ""
  for line in split(text, "\n") {
    val content = contentOf(line)
    if content.length > 0 {
      // Marks and code points in turn: "× 0023 ÷ 0020 × 0024 ÷".
      val tokens = words(content)
      val cpsList: List[Int] = newList()
      val expectBreak: List[Bool] = newList()
      var t = 0
      while t < tokens.count {
        if t % 2 == 0 {
          expectBreak.add(tokens[t] == "÷")
        } else {
          cpsList.add(hexValue(tokens[t]))
        }
        t = t + 1
      }
      val cps = cpsList.toArray()
      val got = boundaries(cps)
      var ok = true
      var shown = ""
      var k = 0
      while k <= cps.length {
        if k > 0 and k < cps.length and got[k] != expectBreak[k] {
          ok = false
        }
        shown = shown + (if got[k] { "÷" } else { "×" })
        if k < cps.length {
          shown = shown + " " + tokens[2 * k + 1] + " "
        }
        k = k + 1
      }
      cases = cases + 1
      if not ok {
        failures = failures + 1
        if failures <= maxReported {
          report = report + "\n  expected " + content + "\n  got      " + shown
        }
      }
    }
  }
  SuiteResult(cases = cases, failures = failures, report = report)
}

/// A one-line summary of a suite, with its first mismatches when it failed.
pub func describe(name: in String, expectedCases: in Int, r: in SuiteResult): String {
  val head = name + ": " + fromInt(r.cases) + " of " + fromInt(expectedCases) + " lines run, " + fromInt(r.failures) +
    " differ"
  head + r.report
}

/// True when a suite ran every line of its file and all of them agreed.
pub func passed(expectedCases: in Int, r: in SuiteResult): Bool {
  r.cases == expectedCases and r.failures == 0
}
