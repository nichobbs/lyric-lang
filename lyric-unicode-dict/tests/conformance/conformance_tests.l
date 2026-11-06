//! conformance_tests.l - runs DictionaryBreakTest.txt, ICU 74.2's answers, against
//! `Unicode.Dictionary` on dotnet and the JVM (#8497); `main.l` runs the same suite on
//! `--target native`.  See `conformance.l` for the file and its checksum.
@test_module
package Unicode.Dictionary.ConformanceTests

import Std.Core
import Std.Testing
import Unicode.Dictionary.Conformance

test "DictionaryBreakTest.txt: every line agrees with ICU 74.2" {
  val text = match Conformance.pinnedText("DictionaryBreakTest.txt", Conformance.dictionaryBreakTestSha256) {
    case Ok(t) -> t
    case Err(e) -> panic(e)
  }
  val r = Conformance.runDictionaryBreakTest(text)
  val expected = Conformance.dictionaryBreakTestCases
  assertTrue(Conformance.passed(expected, r), Conformance.describe("DictionaryBreakTest.txt", expected, r))
}
