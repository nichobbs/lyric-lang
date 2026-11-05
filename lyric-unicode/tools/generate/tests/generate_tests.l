@test_module
package Unicode.GenerateTests

import Std.Core
import Std.Collections
import Std.String
import Std.Testing
import Unicode.Generate

func isErrWith(r: Result[List[UcdEntry], String], text: String): Bool {
  match r {
    case Ok(_) -> false
    case Err(e) -> contains(e, text)
  }
}

test "data lines give their code points and value, comments and blank lines are skipped" {
  val text = "# a comment\n\n0041..005A ; L # LATIN\n00C0;L\n"
  match Generate.entriesOf("T.txt", text, false) {
    case Ok(es) -> {
      assertEqualInt(es.count, 2, "two entries")
      assertEqualInt(es[0].first, 0x41, "first of a range")
      assertEqualInt(es[0].last, 0x5A, "last of a range")
      assertEqual(es[0].value, "L", "the value, trimmed")
      assertEqualInt(es[1].first, es[1].last, "a single code point")
    }
    case Err(e) -> assertTrue(false, "unexpected error: " + e)
  }
}

test "the defaults are the @missing lines, in file order" {
  val text = "# @missing: 0000..10FFFF; L\n# @missing: 0600..07BF; AL\n0041;R\n"
  match Generate.entriesOf("T.txt", text, true) {
    case Ok(es) -> {
      assertEqualInt(es.count, 2, "two defaults")
      assertEqual(es[1].value, "AL", "in file order")
    }
    case Err(e) -> assertTrue(false, "unexpected error: " + e)
  }
}

test "a malformed line is reported with its file and line number" {
  assertTrue(isErrWith(Generate.entriesOf("T.txt", "0041;L\n0042\n", false), "T.txt:2:"), "a line with no value")
  assertTrue(isErrWith(Generate.entriesOf("T.txt", "00G1;L\n", false), "is not a code point"), "a bad hex digit")
  assertTrue(isErrWith(Generate.entriesOf("T.txt", "0042..0041;L\n", false), "is not a range"), "a reversed range")
  assertTrue(isErrWith(Generate.entriesOf("T.txt", "110000;L\n", false), "is not a range"), "past the code space")
}

func tablesOf(names: slice[String]): Map[String, String] {
  val m: Map[String, String] = newMap()
  for n in names {
    m.add(n, "val " + n + ": slice[String] = [\"new\"]")
  }
  m
}

test "only the table lines are rewritten" {
  val names = ["bidiRuns", "lineBreakRuns", "mirrorPairs", "bracketPairs"]
  var source = "// header\n"
  for n in names {
    source = source + "val " + n + ": slice[String] = [\"old\"]\n"
  }
  source = source + "func f(): Int { 1 }"
  match Generate.withTables(source, tablesOf(names)) {
    case Ok(written) -> {
      assertFalse(contains(written, "old"), "every table replaced")
      assertTrue(startsWith(written, "// header\n"), "the rest kept")
      assertTrue(contains(written, "func f(): Int { 1 }"), "the code kept")
    }
    case Err(e) -> assertTrue(false, "unexpected error: " + e)
  }
}

test "a source missing a table line is refused" {
  val names = ["bidiRuns", "lineBreakRuns", "mirrorPairs", "bracketPairs"]
  val source = "val bidiRuns: slice[String] = []\nval mirrorPairs: slice[String] = []\n"
  match Generate.withTables(source, tablesOf(names)) {
    case Ok(_) -> assertTrue(false, "accepted a source with two of its table lines")
    case Err(e) -> assertTrue(contains(e, "2 of its 4 table lines"), "names the count")
  }
}
