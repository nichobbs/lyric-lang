//! main.l - Unicode.Conformance.Main: Unicode's BidiCharacterTest.txt and LineBreakTest.txt
//! (Unicode 16.0) on any target, for `--target native`, where `lyric test` does not run manifest
//! suites (scripts/ci/ui-native-e2e.sh builds and runs it).  Prints one line per suite and exits 1
//! when one of them does not pass.
package Unicode.Conformance.Main

import Std.Core
import Std.Console as Console
import Unicode.Conformance

func runSuite(name: String, sha256: String, expected: Int, bidi: Bool): Bool {
  match Conformance.pinnedText(name, sha256) {
    case Ok(text) -> {
      val r = if bidi { Conformance.runBidiCharacterTest(text) } else { Conformance.runLineBreakTest(text) }
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
    true
  )
  val lineBreak = runSuite("LineBreakTest.txt", Conformance.lineBreakTestSha256, Conformance.lineBreakTestCases, false)
  if bidi and lineBreak {
    0
  } else {
    1
  }
}
