//! main.l - Ui.Native.UnicodeConformance.Main: Unicode's BidiCharacterTest.txt and LineBreakTest.txt
//! (Unicode 15.1) on any target, for `--target native`, where `lyric test` does not run manifest
//! suites (scripts/ci/ui-native-e2e.sh builds and runs it).  Prints one line per suite and exits 1
//! when one of them does not pass.
package Ui.Native.UnicodeConformance.Main

import Std.Core
import Std.Console as Console
import Ui.Native.UnicodeConformance

func runSuite(name: String, sha256: String, expected: Int, bidi: Bool): Bool {
  match UnicodeConformance.pinnedText(name, sha256) {
    case Ok(text) -> {
      val r = if bidi { UnicodeConformance.runBidiCharacterTest(text) } else { UnicodeConformance.runLineBreakTest(text) }
      val ok = UnicodeConformance.passed(expected, r)
      Console.println((if ok { "ok " } else { "FAIL " }) + UnicodeConformance.describe(name, expected, r))
      ok
    }
    case Err(e) -> {
      Console.println("FAIL " + name + ": " + e)
      false
    }
  }
}

func main(): Int {
  val bidi = runSuite(
    "BidiCharacterTest.txt",
    UnicodeConformance.bidiCharacterTestSha256,
    UnicodeConformance.bidiCharacterTestCases,
    true
  )
  val lineBreak = runSuite(
    "LineBreakTest.txt",
    UnicodeConformance.lineBreakTestSha256,
    UnicodeConformance.lineBreakTestCases,
    false
  )
  if bidi and lineBreak {
    0
  } else {
    1
  }
}
