//! conformance.l - Ui.Native.UnicodeConformance: Unicode's own conformance suites for
//! `Ui.Native.Bidi` (UAX #9) and `Ui.Native.LineBreak` (UAX #14), Unicode 15.1 (#8498).
//!
//! The suites are vendored, unchanged, next to this file with the Unicode licence
//! (`LICENSE-UNICODE.txt`), and pinned here by SHA-256, so a run never fetches anything:
//!
//!   BidiCharacterTest.txt  https://www.unicode.org/Public/15.1.0/ucd/BidiCharacterTest.txt
//!   LineBreakTest.txt      https://www.unicode.org/Public/15.1.0/ucd/auxiliary/LineBreakTest.txt
//!
//! Every line of both files is run.  For `BidiCharacterTest.txt` that is the paragraph level, the
//! level of every character after rule L1 (characters X9 removes are `x` and not compared) and the
//! visual order of the line.  `LineBreakTest.txt` follows the number tailoring of UAX #14 section 8.2
//! example 7, which `LineBreak.breaksIn` implements.  `conformance_tests.l` runs the suites on dotnet
//! and the JVM (`lyric test`), `main.l` on `--target native`, where manifest test suites do not run.
package Ui.Native.UnicodeConformance

import Std.Core
import Std.Collections
import Std.String
import Std.File
import Std.Path
import Std.Hash
import Std.Environment
import Ui.Native.Bidi
import Ui.Native.LineBreak
import Ui.Native.UnicodeData

/// The SHA-256 of the vendored `BidiCharacterTest.txt` (Unicode 15.1.0).
pub val bidiCharacterTestSha256: String = "18507F7EC57EC8155B7771DBC88F3E3201AD08EBA4DBA70E4E095EF628020FA8"

/// The SHA-256 of the vendored `LineBreakTest.txt` (Unicode 15.1.0).
pub val lineBreakTestSha256: String = "AE7AF38CEB2D34E8382B43F08ABCE0835B1D44ABA3B98A1D17EA8F5252284376"

/// The number of test lines in each vendored file.
pub val bidiCharacterTestCases: Int = 91707

pub val lineBreakTestCases: Int = 10274

// The most mismatches a report lists.
val maxReported: Int = 12

/// The outcome of one suite: how many lines it ran, how many differed, and the first of them.
pub record SuiteResult {
  cases: Int
  failures: Int
  report: String
}

val dataDir: String = "lyric-ui/native/tests/unicode"

/// The path of a vendored file: in the directory the run started in, or below it or one of its
/// parents at `lyric-ui/native/tests/unicode`, so a run works from this directory, from
/// `lyric-ui/native` and from the repository root.
pub func dataPath(name: in String): Result[String, String] {
  if fileExists(name) {
    return Ok(value = name)
  }
  val start = Environment.currentDirectory()
  var dir = start
  var steps = 0
  while steps < 32 {
    for rel in [dataDir, "tests/unicode"] {
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
    return Err(error = path + " has SHA-256 " + actual + ", not the pinned Unicode 15.1 revision " + sha256)
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

/// Every line of `BidiCharacterTest.txt` (its text) through `Ui.Native.Bidi`.
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

/// Every line of `LineBreakTest.txt` (its text) through `Ui.Native.LineBreak`.
pub func runLineBreakTest(text: in String): SuiteResult {
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
      val breaks = LineBreak.breaksIn(cps, 0, cps.length)
      var ok = true
      var shown = ""
      var k = 0
      while k <= cps.length {
        val got = breaks[k] != LineBreak.noBreak
        if k > 0 and k < cps.length and got != expectBreak[k] {
          ok = false
        }
        shown = shown + (if got { "÷" } else { "×" })
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
