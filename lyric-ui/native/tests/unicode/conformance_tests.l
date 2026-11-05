//! conformance_tests.l - runs Unicode's BidiCharacterTest.txt and LineBreakTest.txt (Unicode 15.1)
//! against `Ui.Native.Bidi` and `Ui.Native.LineBreak` on dotnet and the JVM (#8498); `main.l` runs
//! the same suites on `--target native`.  See `conformance.l` for the files and their checksums.
@test_module
package Ui.Native.UnicodeConformanceTests

import Std.Core
import Std.Testing
import Ui.Native.UnicodeConformance

func suiteText(name: String, sha256: String): String {
  match UnicodeConformance.pinnedText(name, sha256) {
    case Ok(t) -> t
    case Err(e) -> panic(e)
  }
}

test "BidiCharacterTest.txt: every line agrees with Ui.Native.Bidi" {
  val text = suiteText("BidiCharacterTest.txt", UnicodeConformance.bidiCharacterTestSha256)
  val r = UnicodeConformance.runBidiCharacterTest(text)
  val expected = UnicodeConformance.bidiCharacterTestCases
  assertTrue(UnicodeConformance.passed(expected, r), UnicodeConformance.describe("BidiCharacterTest.txt", expected, r))
}

test "LineBreakTest.txt: every line agrees with Ui.Native.LineBreak" {
  val text = suiteText("LineBreakTest.txt", UnicodeConformance.lineBreakTestSha256)
  val r = UnicodeConformance.runLineBreakTest(text)
  val expected = UnicodeConformance.lineBreakTestCases
  assertTrue(UnicodeConformance.passed(expected, r), UnicodeConformance.describe("LineBreakTest.txt", expected, r))
}

test "the bidi outcome uses the file's notation" {
  // A Hebrew word in a Latin line, and a zero width space (BN), which X9 removes.
  val cps = [97, 32, 1488, 1489, 8203, 98]
  assertEqual(UnicodeConformance.bidiOutcome(cps, 0), "0;0 0 1 1 x 0;0 1 3 2 5", "levels and order")
  assertEqual(UnicodeConformance.bidiOutcome([1488, 32, 97], 2), "1;1 1 2;2 1 0", "direction from the text")
}
