//! conformance_tests.l - runs Unicode's BidiCharacterTest.txt, LineBreakTest.txt and WordBreakTest.txt (Unicode 16.0)
//! against `Unicode.Bidi` and `Unicode.LineBreak` on dotnet and the JVM (#8498); `main.l` runs
//! the same suites on `--target native`.  See `conformance.l` for the files and their checksums.
@test_module
package Unicode.ConformanceTests

import Std.Core
import Std.Testing
import Unicode.Conformance

func suiteText(name: String, sha256: String): String {
  match Conformance.pinnedText(name, sha256) {
    case Ok(t) -> t
    case Err(e) -> panic(e)
  }
}

test "BidiCharacterTest.txt: every line agrees with Unicode.Bidi" {
  val text = suiteText("BidiCharacterTest.txt", Conformance.bidiCharacterTestSha256)
  val r = Conformance.runBidiCharacterTest(text)
  val expected = Conformance.bidiCharacterTestCases
  assertTrue(Conformance.passed(expected, r), Conformance.describe("BidiCharacterTest.txt", expected, r))
}

test "LineBreakTest.txt: every line agrees with Unicode.LineBreak" {
  val text = suiteText("LineBreakTest.txt", Conformance.lineBreakTestSha256)
  val r = Conformance.runLineBreakTest(text)
  val expected = Conformance.lineBreakTestCases
  assertTrue(Conformance.passed(expected, r), Conformance.describe("LineBreakTest.txt", expected, r))
}

test "WordBreakTest.txt: every line agrees with Unicode.WordBreak" {
  val text = suiteText("WordBreakTest.txt", Conformance.wordBreakTestSha256)
  val r = Conformance.runWordBreakTest(text)
  val expected = Conformance.wordBreakTestCases
  assertTrue(Conformance.passed(expected, r), Conformance.describe("WordBreakTest.txt", expected, r))
}

test "the bidi outcome uses the file's notation" {
  // A Hebrew word in a Latin line, and a zero width space (BN), which X9 removes.
  val cps = [97, 32, 1488, 1489, 8203, 98]
  assertEqual(Conformance.bidiOutcome(cps, 0), "0;0 0 1 1 x 0;0 1 3 2 5", "levels and order")
  assertEqual(Conformance.bidiOutcome([1488, 32, 97], 2), "1;1 1 2;2 1 0", "direction from the text")
}
