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

func testCommentInsideFunctionBody(): Unit {
  // Phase 5 §M5.3 stage 4 (D-progress-136): comments INSIDE a function
  // body must survive.  The block's harvested comments are popped at
  // each statement boundary and at the closing brace.
  val src = "package P\nfunc f(): Unit {\n  // setup\n  val x = 1\n  // process\n  val y = x\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// setup"),
             "internal: comment before first stmt preserved")
  assertTrue(Str.contains(acc, "// process"),
             "internal: comment between stmts preserved")
  assertTrue(Str.contains(acc, "val x = 1"), "internal: stmt 1 emitted")
  assertTrue(Str.contains(acc, "val y = x"), "internal: stmt 2 emitted")
}

func testCommentInsideRecordBody(): Unit {
  // Comments BETWEEN record fields must survive the record body walk.
  val src = "package P\nrecord Point {\n  x: Int\n  // y is the second axis\n  y: Int\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// y is the second axis"),
             "internal: between-field comment preserved")
  assertTrue(Str.contains(acc, "x: Int"), "internal: first field emitted")
  assertTrue(Str.contains(acc, "y: Int"), "internal: second field emitted")
}

func testCommentInsideUnionBody(): Unit {
  // Comments between union cases.
  val src = "package P\nunion Color {\n  case Red\n  // primaries\n  case Green\n  case Blue\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// primaries"),
             "internal: between-case comment preserved")
}

func testCommentInsideEnumBody(): Unit {
  // Comments between enum cases.
  val src = "package P\nenum Dir {\n  case North\n  // horizontal\n  case East\n  case West\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// horizontal"),
             "internal: enum between-case comment preserved")
}

func testCommentInsideNestedBlock(): Unit {
  // Comments inside a nested block (if-then-block).
  val src = "package P\nfunc f(x: in Int): Unit {\n  if x > 0 {\n    // positive branch\n    val y = x\n  }\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// positive branch"),
             "internal: nested-block comment preserved")
}

func testBlankLineInsideFunctionBody(): Unit {
  // Phase 5 §M5.3 stage 5: a blank line between two statements inside
  // a function body must survive `lyric fmt`.
  val src = "package P\nfunc f(): Unit {\n  val a = 1\n\n  val b = 2\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  val expected = "package P\n\nfunc f(): Unit {\n  val a = 1\n\n  val b = 2\n}\n"
  assertEqual(acc, expected, "blank: between stmts in func body")
}

func testBlankLineInsideRecordBody(): Unit {
  val src = "package P\nrecord Point {\n  x: Int\n\n  y: Int\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  val expected = "package P\n\nrecord Point {\n  x: Int\n\n  y: Int\n}\n"
  assertEqual(acc, expected, "blank: between record fields")
}

func testBlankLinesBetweenCommentBlocks(): Unit {
  // Two comment groups separated by a blank line.  Both comments
  // survive AND the blank between them stays.
  val src = "package P\nfunc f(): Unit {\n  // group 1\n  val a = 1\n\n  // group 2\n  val b = 2\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// group 1"),
             "blank: first comment group preserved")
  assertTrue(Str.contains(acc, "// group 2"),
             "blank: second comment group preserved")
  // The blank line shows as `\n\n` between the two groups.
  assertTrue(Str.contains(acc, "val a = 1\n\n  // group 2"),
             "blank: blank line preserved between comment groups")
}

func testMultipleBlankLinesCollapseToOne(): Unit {
  // 3 consecutive newlines (= 2 blank lines in source) collapse to a
  // single blank line in canonical output.  Use exact-match
  // `assertEqual` rather than `Str.contains` so the assertion locks
  // in the entire surrounding context, not just the substring shape.
  val src = "package P\nfunc f(): Unit {\n  val a = 1\n\n\n\n  val b = 2\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  val expected = "package P\n\nfunc f(): Unit {\n  val a = 1\n\n  val b = 2\n}\n"
  assertEqual(acc, expected, "blank: multiple-newline run collapses to one blank")
}

func testTrailingBlankBeforeClosingBrace(): Unit {
  // A blank line immediately before `}` should be suppressed — the
  // closing brace itself is the visual terminator, and a trailing
  // empty line in the body just looks unfinished.  This locks in the
  // `popCommentsBefore` (not `popTriviaBefore`) choice at the tail of
  // `blockLines` / `recordDoc` / `unionDoc` / `enumDoc`.
  val funcSrc = "package P\nfunc f(): Unit {\n  val a = 1\n\n}\n"
  val funcOut = format(parse(funcSrc))
  val funcExpected = "package P\n\nfunc f(): Unit {\n  val a = 1\n}\n"
  assertEqual(funcOut, funcExpected, "blank: trailing blank before func `}` suppressed")

  val recSrc = "package P\nrecord R {\n  x: Int\n\n}\n"
  val recOut = format(parse(recSrc))
  val recExpected = "package P\n\nrecord R {\n  x: Int\n}\n"
  assertEqual(recOut, recExpected, "blank: trailing blank before record `}` suppressed")
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
  testCommentInsideFunctionBody()
  testCommentInsideRecordBody()
  testCommentInsideUnionBody()
  testCommentInsideEnumBody()
  testCommentInsideNestedBlock()
  testBlankLineInsideFunctionBody()
  testBlankLineInsideRecordBody()
  testBlankLinesBetweenCommentBlocks()
  testMultipleBlankLinesCollapseToOne()
  testTrailingBlankBeforeClosingBrace()
  println("fmt self-test: ok")
}
