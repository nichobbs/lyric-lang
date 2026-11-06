//! main.l - Unicode.Dictionary.Conformance.Main: DictionaryBreakTest.txt on any target, for
//! `--target native`, where `lyric test` does not run manifest suites (scripts/ci/ui-native-e2e.sh
//! builds and runs it).  Prints one line and exits 1 when the suite does not pass.
package Unicode.Dictionary.Conformance.Main

import Std.Core
import Std.Console as Console
import Unicode.Dictionary.Conformance

func main(): Int {
  val name = "DictionaryBreakTest.txt"
  val expected = Conformance.dictionaryBreakTestCases
  match Conformance.pinnedText(name, Conformance.dictionaryBreakTestSha256) {
    case Ok(text) -> {
      val r = Conformance.runDictionaryBreakTest(text)
      val ok = Conformance.passed(expected, r)
      Console.println((if ok { "ok " } else { "FAIL " }) + Conformance.describe(name, expected, r))
      if ok {
        0
      } else {
        1
      }
    }
    case Err(e) -> {
      Console.println("FAIL " + name + ": " + e)
      1
    }
  }
}
