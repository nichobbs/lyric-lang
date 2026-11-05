//! conformance.l - Unicode.Dictionary.Conformance: `Unicode.Dictionary` against ICU 74.2's own line and
//! word break iterators (#8497, D414).
//!
//! `DictionaryBreakTest.txt`, next to this file, holds 4000 lines of Thai, Lao, Khmer and Myanmar
//! text with the positions ICU 74.2's line and word break iterators stop at; `tools/reference` wrote
//! it, and it is pinned here by SHA-256, so a run never needs ICU or the network.  Every line is run,
//! through `Dictionary.lineBreaksIn` and `Dictionary.wordBoundariesIn`.  `conformance_tests.l` runs
//! the suite on dotnet and the JVM (`lyric test`), `main.l` on `--target native`, where manifest test
//! suites do not run.
package Unicode.Dictionary.Conformance

import Std.Core
import Std.Collections
import Std.String
import Std.File
import Std.Path
import Std.Hash
import Std.Environment
import Std.Errors.{IOError}
import Std.Encoding.{tryDecodeUtf8}
import Unicode.LineBreak
import Unicode.Dictionary

/// The SHA-256 of the checked-in `DictionaryBreakTest.txt`.
pub val dictionaryBreakTestSha256: String = "02C4CB747DFCF144AF9455D1394EA18BF669CCA2C88414012D63C496CC3B25CA"

/// The number of test lines in it.
pub val dictionaryBreakTestCases: Int = 4000

// The most mismatches a report lists.
val maxReported: Int = 12

/// The outcome of the suite: how many lines it ran, how many differed, and the first of them.
pub record SuiteResult {
  cases: Int
  failures: Int
  report: String
}

val dataDir: String = "lyric-unicode-dict/tests/conformance"

/// The path of the suite: in the directory the run started in, or below it or one of its parents at
/// `lyric-unicode-dict/tests/conformance`, so a run works from this directory, the library's and the
/// repository root.
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

/// The text of the suite, after checking it is the pinned revision.
pub func pinnedText(name: in String, sha256: in String): Result[String, String] {
  val path = match dataPath(name) { case Ok(p) -> p; case Err(e) -> return Err(error = e) }
  val bytes = match readBytes(path) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = "cannot read " + path + ": " + IOError.message(e))
  }
  val actual = sha256OfBytes(bytes)
  if actual != sha256 {
    return Err(error = path + " has SHA-256 " + actual + ", not the pinned revision " + sha256)
  }
  match tryDecodeUtf8(bytes) {
    case Some(t) -> Ok(value = t)
    case None -> Err(error = path + " is not UTF-8")
  }
}

func positions(s: String): String {
  var r = ""
  for w in split(s, " ") {
    if w.length > 0 {
      r = r + (if r.length > 0 { " " } else { "" }) + w
    }
  }
  r
}

func lineStops(cps: slice[Int]): String {
  val bs = Dictionary.lineBreaksIn(cps, 0, cps.length)
  var r = "0"
  var k = 1
  while k <= cps.length {
    if bs[k] != LineBreak.noBreak {
      r = r + " " + k.toString()
    }
    k = k + 1
  }
  r
}

func wordStops(cps: slice[Int]): String {
  val bs = Dictionary.wordBoundariesIn(cps, 0, cps.length)
  var r = "0"
  var k = 1
  while k <= cps.length {
    if bs[k] {
      r = r + " " + k.toString()
    }
    k = k + 1
  }
  r
}

/// Runs every line of the suite.  A line that is not text, line stops and word stops separated by
/// tabs counts as a failure.
pub func runDictionaryBreakTest(text: in String): SuiteResult {
  var cases = 0
  var failures = 0
  var report = ""
  for line in split(text, "\n") {
    if line.length == 0 or startsWith(line, "#") {
      continue
    }
    cases = cases + 1
    val fields = split(line, "\t")
    if fields.count != 3 {
      failures = failures + 1
      if failures <= maxReported {
        report = report + "\n  not text, line stops and word stops: " + line
      }
      continue
    }
    val cps = codePoints(fields[0])
    val gotLine = lineStops(cps)
    val gotWord = wordStops(cps)
    val wantLine = positions(fields[1])
    val wantWord = positions(fields[2])
    if gotLine != wantLine or gotWord != wantWord {
      failures = failures + 1
      if failures <= maxReported {
        report = report + "\n  " + fields[0] + "\n    lines: ICU " + wantLine + ", got " + gotLine + "\n    words: ICU " +
          wantWord +
          ", got " +
          gotWord
      }
    }
  }
  SuiteResult(cases = cases, failures = failures, report = report)
}

/// One line about a run: how many lines ran and differed, then the first differences.
pub func describe(name: in String, expectedCases: in Int, r: in SuiteResult): String {
  name + ": " + r.cases.toString() + " of " + expectedCases.toString() + " lines run, " + r.failures.toString() +
    " differ" +
    r.report
}

/// True when the suite ran every line and all of them agreed.
pub func passed(expectedCases: in Int, r: in SuiteResult): Bool {
  r.cases == expectedCases and r.failures == 0
}
