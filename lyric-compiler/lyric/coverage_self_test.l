//! coverage_self_test.l — exercises `Lyric.Coverage` (`lyric test --coverage`,
//! #5294, D246): the statement instrumentation and the lcov / Cobertura
//! reports built from the counts a run writes.
//!
//! Run via `lyric test lyric-compiler/lyric/coverage_self_test.l`.
@test_module
package Lyric.CoverageSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.Coverage

func sample(): String {
  "package Calc\n\npub func classify(n: in Int): String {\n  if n < 0 {\n    return \"negative\"\n  }\n  if n == 0 {\n    return \"zero\"\n  }\n  \"positive\"\n}\n\npub func unused(): Int {\n  1\n}\n"
}

func lineCount(s: in String): Int {
  Str.split(s, "\n").length
}

test "every statement of a function body is counted, on its own line" {
  val r = instrumentSource(sample(), "calc.l", 0)
  assertEqualInt(r.file.points.count, 6, "if, return, if, return, tail expression, unused body")
  assertEqualInt(r.nextId, 6, "ids continue from the last one used")
  assertEqualInt(lineCount(r.source), lineCount(sample()), "no line is added or removed")
  assertTrue(
    Str.contains(r.source, "package Calc; import Std.Coverage as __lyric_cov\n"),
    "the counter import is on the package line"
  )
  assertTrue(
    Str.contains(r.source, "  __lyric_cov.hit(0); if n < 0 {\n"),
    "the first statement starts with the first id"
  )
  assertTrue(
    Str.contains(r.source, "    __lyric_cov.hit(1); return \"negative\"\n"),
    "a nested statement is counted too"
  )
  assertTrue(Str.contains(r.source, "  __lyric_cov.hit(4); \"positive\"\n"), "a tail expression is counted")
  assertEqualInt(r.file.points[0].line, 4, "the point records the statement's line")
  assertEqualInt(r.file.points[5].line, 14, "a second function's body is counted")
  assertEqualInt(r.file.functions.count, 2, "both functions are recorded")
  assertEqualInt(r.file.functions[0].line, 3, "a function is recorded at its declaration")
  assertEqualInt(r.file.functions[1].entryId, 5, "and by the id of its first statement")
}

test "a session numbers files one after the other" {
  val session = newSession()
  val a = instrumentInto(session, sample(), "a.l")
  val b = instrumentInto(session, sample(), "b.l")
  assertTrue(Str.contains(a, "hit(5); 1"), "the first file ends at id 5")
  assertTrue(Str.contains(b, "hit(6); if n < 0"), "the second starts at id 6")
  assertEqualInt(session.files.count, 2, "both files are in the report")
  assertEqualInt(session.next[0], 12, "twelve ids were handed out")
}

test "match arms, loops and lambdas are walked" {
  val src = "package P\n\nfunc f(xs: in List[Int]): Int {\n  var t = 0\n  for x in xs {\n    t = t + x\n  }\n  val r = match t {\n    case 0 -> {\n      1\n    }\n    case _ -> 2\n  }\n  r\n}\n"
  val r = instrumentSource(src, "p.l", 0)
  assertEqualInt(r.file.points.count, 6, "var, for, the loop body, val, the arm's block, the tail")
  assertEqualInt(lineCount(r.source), lineCount(src), "no line moves")
}

test "files that are not code under test are left alone" {
  val pure = "@pure\npackage P\n\nfunc f(): Int {\n  1\n}\n"
  assertEqual(instrumentSource(pure, "p.l", 0).source, pure, "a @pure package is not instrumented")
  val std = "package Std.Thing\n\nfunc f(): Int {\n  1\n}\n"
  assertEqual(instrumentSource(std, "t.l", 0).source, std, "a standard library package is not instrumented")
  val bad = "package P\n\nfunc f(: Int {\n"
  assertEqual(instrumentSource(bad, "b.l", 0).source, bad, "a file that does not parse is not instrumented")
  val pureFn = "package P\n\n@pure\nfunc f(): Int {\n  1\n}\n\nfunc g(): Int {\n  2\n}\n"
  assertEqualInt(
    instrumentSource(pureFn, "q.l", 0).file.points.count,
    1,
    "a @pure function is skipped, its neighbour is not"
  )
  val testItem = "@test_module\npackage P\n\nimport Std.Testing\n\nfunc helper(): Int {\n  1\n}\n\ntest \"t\" {\n  assertTrue(true, \"x\")\n}\n"
  assertEqualInt(
    instrumentSource(testItem, "t.l", 0).file.points.count,
    1,
    "only the helper of a test module counts, not its test items"
  )
}

test "a test module gets the counter import its main needs" {
  val session = newSession()
  val src = "@test_module\npackage P\n\nimport Std.Testing\n\ntest \"t\" {\n  assertTrue(true, \"x\")\n}\n"
  val prepared = instrumentTestModule(session, src, "t.l", false)
  assertTrue(Str.contains(prepared, "package P; import Std.Coverage as __lyric_cov\n"), "the import is added")
  assertEqual(instrumentTestModule(session, prepared, "t.l", false), prepared, "adding it twice changes nothing")
  assertEqualInt(session.files.count, 0, "a module with no helpers measures nothing")
}

test "hits are summed per id and malformed lines are ignored" {
  val session = newSession()
  val src = instrumentInto(session, sample(), "calc.l")
  assertTrue(Str.contains(src, "hit(0)"), "instrumented")
  val hits = emptyHits(session)
  assertEqualInt(hits.count, 6, "one slot per id")
  addHits(hits, "0 2\n1 1\n3 1\nnot a line\n99 4\n-1 3\n")
  addHits(hits, "0 1\n")
  assertEqualInt(hits[0], 3, "counts of several runs add up")
  assertEqualInt(hits[1], 1, "a single count")
  assertEqualInt(hits[2], 0, "an id that never ran")
  assertEqualInt(hits[3], 1, "another")
}

test "lcov report lists lines, functions and totals" {
  val session = newSession()
  val src = instrumentInto(session, sample(), "calc.l")
  assertTrue(src.length > 0, "instrumented")
  val hits = emptyHits(session)
  addHits(hits, "0 2\n1 1\n2 1\n4 1\n")
  val expected = "TN:\nSF:calc.l\nFN:3,classify\nFN:13,unused\nFNDA:2,classify\nFNDA:0,unused\nFNF:2\nFNH:1\nDA:4,2\nDA:5,1\nDA:7,1\nDA:8,0\nDA:10,1\nDA:14,0\nLF:6\nLH:4\nend_of_record\n"
  assertEqual(lcovReport(session, hits), expected, "exact lcov")
  val totals = sessionTotals(session, hits)
  assertEqualInt(totals.covered, 4, "covered lines")
  assertEqualInt(totals.total, 6, "countable lines")
  assertEqual(percentText(totals.covered, totals.total), "66.7", "percentage")
  assertTrue(meetsMinimum(totals, 66), "66.7% meets 66")
  assertTrue(not meetsMinimum(totals, 67), "66.7% does not meet 67")
}

test "cobertura report carries the same lines" {
  val session = newSession()
  val src = instrumentInto(session, sample(), "calc.l")
  assertTrue(src.length > 0, "instrumented")
  val hits = emptyHits(session)
  addHits(hits, "0 2\n1 1\n2 1\n4 1\n")
  val xml = coberturaReport(session, hits)
  assertTrue(Str.contains(xml, "lines-covered=\"4\" lines-valid=\"6\""), "totals")
  assertTrue(Str.contains(xml, "line-rate=\"0.667\""), "rate")
  assertTrue(Str.contains(xml, "<line number=\"8\" hits=\"0\"/>"), "an uncovered line")
  assertTrue(Str.contains(xml, "<line number=\"4\" hits=\"2\"/>"), "a covered line")
  assertTrue(Str.contains(xml, "filename=\"calc.l\""), "the file")
}

test "percentages round to one decimal and an empty run is whole" {
  assertEqual(percentText(1, 3), "33.3", "one third")
  assertEqual(percentText(2, 3), "66.7", "two thirds")
  assertEqual(percentText(3, 3), "100.0", "all")
  assertEqual(percentText(0, 0), "100.0", "nothing to cover")
}
