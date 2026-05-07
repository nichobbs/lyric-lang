// fmt_self_test.l — exercises the self-hosted Lyric.Fmt library.
// Compiled and executed by the F# Expecto runner at
// compiler/tests/Lyric.Emitter.Tests/SelfHostedFmtTests.fs.  Each
// in-program assertion panics on mismatch; exit 0 + an "ok" line in
// stdout means every check held.
package Lyric.FmtSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.Parser
import Lyric.Fmt

func testFormatPackageOnly(): Unit {
  val pr = parse("package Foo.Bar\n")
  val acc = format(pr)
  assertEqual(acc, "package Foo.Bar\n", "format: package-only")
}

func testFormatPackageAndImports(): Unit {
  val src = "package P\nimport Std.Core\nimport Std.Collections\n"
  val pr = parse(src)
  val acc = format(pr)
  val expected = "package P\n\nimport Std.Core\nimport Std.Collections\n"
  assertEqual(acc, expected, "format: package + imports")
}

func testFormatTypeAlias(): Unit {
  val src = "package P\nalias Name = String\n"
  val pr = parse(src)
  val acc = format(pr)
  val expected = "package P\n\nalias Name = String\n"
  assertEqual(acc, expected, "format: type alias")
}

func testFormatRecord(): Unit {
  val src = "package P\nrecord Point { x: Int; y: Int }\n"
  val pr = parse(src)
  val acc = format(pr)
  // Canonical form puts each field on its own line.
  assertTrue(Str.contains(acc, "record Point {"), "format: record header")
  assertTrue(Str.contains(acc, "x: Int"), "format: record x field")
  assertTrue(Str.contains(acc, "y: Int"), "format: record y field")
}

func testFormatFunction(): Unit {
  val src = "package P\nfunc add(x: in Int, y: in Int): Int { x + y }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "func add(x: in Int, y: in Int): Int {"),
             "format: func signature")
  assertTrue(Str.contains(acc, "x + y"), "format: func body")
}

func testIsFormattedRoundTrip(): Unit {
  val src = "package P\n\nalias Name = String\n"
  val pr = parse(src)
  // After parsing + formatting, isFormatted should be true.
  assertTrue(isFormatted(format(pr), pr), "format: idempotent")
}

func testCommentPreservationBetweenItems(): Unit {
  // Place a non-doc line comment between two items.  The F# formatter
  // would drop it; the self-hosted formatter must keep it because it
  // walks the CST instead of the AST alone.
  val src = "package P\n\n// A leading comment.\nalias A = Int\n\n// Between items.\nalias B = String\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// A leading comment."),
             "comments: preserved before first item")
  assertTrue(Str.contains(acc, "// Between items."),
             "comments: preserved between items")
  assertTrue(Str.contains(acc, "alias A = Int"),
             "comments: first item still emitted")
  assertTrue(Str.contains(acc, "alias B = String"),
             "comments: second item still emitted")
}

func testCommentPreservationBlockComment(): Unit {
  val src = "package P\n\n/* block before */\nalias A = Int\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "/* block before */"),
             "comments: block comment preserved before item")
}

func testCommentPreservationTrailing(): Unit {
  val src = "package P\n\nalias A = Int\n\n// trailing after last\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// trailing after last"),
             "comments: trailing comment preserved")
}

func testFormatPubFunc(): Unit {
  val src = "package P\npub func foo(): Unit { }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "pub func foo(): Unit"),
             "format: pub visibility on func")
}

func testFormatUnion(): Unit {
  val src = "package P\nunion Color { case Red; case Green; case Blue }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "union Color {"), "format: union header")
  assertTrue(Str.contains(acc, "case Red"),   "format: case Red")
  assertTrue(Str.contains(acc, "case Green"), "format: case Green")
  assertTrue(Str.contains(acc, "case Blue"),  "format: case Blue")
}

func testFormatEnum(): Unit {
  val src = "package P\nenum Dir { case North; case South; case East; case West }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "enum Dir {"), "format: enum header")
  assertTrue(Str.contains(acc, "case North"), "format: enum case")
}

// `const` is not yet wired through the self-hosted parser; the
// formatter renders it via `IConst` whenever the parser does start
// emitting it.  Skipped for now.

func testFormatVal(): Unit {
  val src = "package P\nval pi: Double = 3.14\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "val pi: Double = 3.14"), "format: val")
}

func testFormatModuleDoc(): Unit {
  val src = "//! Module-level doc.\npackage P\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "//! Module-level doc."),
             "format: module doc preserved")
}

func testFormatSourceFacade(): Unit {
  // String-in / string-out façade — the entry point the F# CLI calls
  // through reflection in M5.3 stage 2 (CLI wiring).
  val src = "package P\n\n// keep me\nalias A = Int\n"
  val acc = formatSource(src)
  assertTrue(Str.contains(acc, "// keep me"),
             "formatSource: comment preserved")
  assertTrue(Str.contains(acc, "alias A = Int"),
             "formatSource: item rendered")
  assertTrue(isFormattedSource(acc),
             "formatSource: output is canonical (idempotent)")
}

func main(): Unit {
  testFormatPackageOnly()
  testFormatPackageAndImports()
  testFormatTypeAlias()
  testFormatRecord()
  testFormatFunction()
  testIsFormattedRoundTrip()
  testCommentPreservationBetweenItems()
  testCommentPreservationBlockComment()
  testCommentPreservationTrailing()
  testFormatPubFunc()
  testFormatUnion()
  testFormatEnum()
  testFormatVal()
  testFormatModuleDoc()
  testFormatSourceFacade()
  println("fmt self-test: ok")
}
