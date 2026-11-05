//! main.l - Unicode.Conformance.Main: Unicode's BidiCharacterTest.txt, LineBreakTest.txt and WordBreakTest.txt
//! (Unicode 16.0) on any target, for `--target native`, where `lyric test` does not run manifest
//! suites (scripts/ci/ui-native-e2e.sh builds and runs it).  Prints one line per suite and exits 1
//! when one of them does not pass.
package Unicode.Conformance.Main

import Std.Core
import Std.Console as Console
import Unicode.Conformance

// `suite` is 0 for the bidi suite, 1 for line breaking and 2 for word boundaries.
func runSuite(name: String, sha256: String, expected: Int, suite: Int): Bool {
  match Conformance.pinnedText(name, sha256) {
    case Ok(text) -> {
      val r = if suite == 0 {
        Conformance.runBidiCharacterTest(text)
      } else if suite == 1 {
        Conformance.runLineBreakTest(text)
      } else {
        Conformance.runWordBreakTest(text)
      }
      val ok = Conformance.passed(expected, r)
      Console.println((if ok { "ok " } else { "FAIL " }) + Conformance.describe(name, expected, r))
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
    Conformance.bidiCharacterTestSha256,
    Conformance.bidiCharacterTestCases,
    0
  )
  val lineBreak = runSuite("LineBreakTest.txt", Conformance.lineBreakTestSha256, Conformance.lineBreakTestCases, 1)
  val wordBreak = runSuite("WordBreakTest.txt", Conformance.wordBreakTestSha256, Conformance.wordBreakTestCases, 2)
  if bidi and lineBreak and wordBreak {
    0
  } else {
    1
  }
}
