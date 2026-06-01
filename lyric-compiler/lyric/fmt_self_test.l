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

// A `var`-prefixed mutable record field must survive a format
// round-trip with its `var` marker intact.
func testFormatMutableRecordField(): Unit {
  val src = "package P\nrecord Counter {\n  var count: Int\n  step: Int\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "var count: Int"), "format: var field keeps marker")
  assertTrue(Str.contains(acc, "step: Int"), "format: plain field unchanged")
  assertTrue(not Str.contains(acc, "var step"), "format: plain field stays immutable")
  assertTrue(isFormatted(acc, pr), "format: var field idempotent")
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

func testCommentBeforeContractClause(): Unit {
  // Phase 5 §M5.3 stage 7: a comment immediately before a contract
  // clause must survive — anchored at the clause's own start offset
  // via the new SkContractClause CST node (D-progress-142 scaffolding).
  val src =
    "package P\n" +
    "func divide(x: in Int, y: in Int): Int\n" +
    "  // y must not be zero\n" +
    "  requires: y != 0\n" +
    "  // result times y reconstitutes x\n" +
    "  ensures: result * y == x\n" +
    "  { x / y }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// y must not be zero"),
             "contract: comment before requires preserved")
  assertTrue(Str.contains(acc, "// result times y reconstitutes x"),
             "contract: comment between requires and ensures preserved")
  assertTrue(Str.contains(acc, "requires: y != 0"),
             "contract: requires clause emitted")
  assertTrue(Str.contains(acc, "ensures: result * y == x"),
             "contract: ensures clause emitted")
}

func testBlankLineBetweenContractClauses(): Unit {
  // A blank line between two contract clauses survives via the
  // HiBlank trivia stream + popTriviaBefore at the clause boundary.
  val src =
    "package P\n" +
    "func f(x: in Int): Int\n" +
    "  requires: x > 0\n" +
    "\n" +
    "  ensures: result > 0\n" +
    "  { x }\n"
  val pr = parse(src)
  val acc = format(pr)
  // The blank line shows as `\n\n  ensures` in the output.
  assertTrue(Str.contains(acc, "requires: x > 0\n\n  ensures: result > 0"),
             "contract: blank line between clauses preserved")
}

func testCommentBeforeWhereClause(): Unit {
  // Phase 5 §M5.3 stage 8: a comment immediately before a `where`
  // clause on a function signature must survive — anchored at the
  // where clause's start offset.
  val src =
    "package P\n" +
    "func max[T](a: in T, b: in T): T\n" +
    "  // T must be ordered\n" +
    "  where T: Compare\n" +
    "  { if a > b { a } else { b } }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// T must be ordered"),
             "where: comment before where clause preserved")
  assertTrue(Str.contains(acc, "where T: Compare"),
             "where: where clause itself emitted")
}

func testCommentBetweenWhereAndContract(): Unit {
  // The self-hosted parser expects `where` BEFORE contract clauses on
  // a function signature.  A comment sitting between the where clause
  // and the following contract clause anchors at the contract clause
  // boundary.
  val src =
    "package P\n" +
    "func cap[T](x: in T): T\n" +
    "  where T: Compare\n" +
    "  // x is unchanged\n" +
    "  requires: true\n" +
    "  { x }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "where T: Compare"),
             "where+contract: where clause emitted")
  assertTrue(Str.contains(acc, "// x is unchanged"),
             "where+contract: comment between where and contract preserved")
  assertTrue(Str.contains(acc, "requires: true"),
             "where+contract: requires emitted")
}

func testWhereThenContractRoundTrips(): Unit {
  // Round-trip lock: the self-hosted parser accepts `where` only
  // before contract clauses, so the formatter must output them in
  // that order.  `format(format(parse(src))) == format(parse(src))`
  // and the second parse must succeed without diagnostics.
  val src =
    "package P\n" +
    "func cap[T](x: in T): T\n" +
    "  where T: Compare\n" +
    "  requires: true\n" +
    "  { x }\n"
  val pr1 = parse(src)
  assertEqualInt(pr1.diagnostics.count, 0, "round-trip: first parse clean")
  val once = format(pr1)
  val pr2 = parse(once)
  assertEqualInt(pr2.diagnostics.count, 0, "round-trip: re-parse of format output is clean")
  val twice = format(pr2)
  assertEqual(twice, once, "round-trip: format is idempotent for where+contracts")
  // Lock in the wire order: `where` must precede `requires` in the output.
  val wIdx = match Str.indexOf(once, "where T: Compare") {
    case Some(i) -> i
    case None    -> -1
  }
  val rIdx = match Str.indexOf(once, "requires: true") {
    case Some(i) -> i
    case None    -> -1
  }
  assertTrue(wIdx >= 0 and rIdx >= 0, "round-trip: both clauses emitted")
  assertTrue(wIdx < rIdx, "round-trip: where appears before requires")
}

func testWidthDrivenLongCallBreaks(): Unit {
  // Phase 5 §M5.3 stage 9 (D-progress-145): a function call whose
  // inline rendering would exceed the 120-character line budget at
  // its current column gets broken into one-arg-per-line layout.
  // Use a call comfortably over 120 chars to avoid budget-edge
  // flakiness.
  val src =
    "package P\n" +
    "func go(a: in Int): Int {\n" +
    "  val r = anExtraordinarilyLongFunctionName(a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a)\n" +
    "  r\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "anExtraordinarilyLongFunctionName(\n"),
             "width: long call opens with `(` on the same line and breaks args")
  assertTrue(Str.contains(acc, "  )\n"),
             "width: long call closes with `)` on its own indented line")
}

func testWidthDrivenLongCallIdempotent(): Unit {
  // The width-driven multi-line layout must round-trip: format(format(x)) == format(x).
  val src =
    "package P\n" +
    "func go(a: in Int): Int {\n" +
    "  val r = anExtraordinarilyLongFunctionName(a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a)\n" +
    "  r\n" +
    "}\n"
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(twice, once, "width: long-call layout is idempotent")
}

func testCommentInsideCallArgs(): Unit {
  // A `// ...` comment between two call arguments anchors at the
  // following arg's start offset and renders inside the multi-line
  // call layout, not at the next outer statement boundary.
  val src =
    "package P\n" +
    "func go(): Int {\n" +
    "  val x = foo(\n" +
    "    // first arg\n" +
    "    1,\n" +
    "    2\n" +
    "  )\n" +
    "  x\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "    // first arg\n    1,"),
             "width: comment between call args stays inside the call")
}

func testWidthDrivenLongBinopBreaks(): Unit {
  // A long chain of binary `+` operators breaks to one operand per
  // line with the operator at the end of the previous line.  The
  // test source is long enough to force the break.
  val src =
    "package P\n" +
    "func sum(a: in Int): Int {\n" +
    "  val x = aLongHelper(a) + bLongHelper(a) + cLongHelper(a) + dLongHelper(a) + eLongHelper(a) + fLongHelper(a) + gLongHelper(a)\n" +
    "  x\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  // At least one operator-at-end-of-line break must show up.
  assertTrue(Str.contains(acc, "+\n  "),
             "width: long binop breaks with operator at end-of-line")
}

func testShortExpressionStaysInline(): Unit {
  // Negative test: a short expression must NOT be split.  Locks in
  // the budget threshold: don't over-eagerly break.
  val src = "package P\nfunc f(): Int { val x = a + b; x }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "val x = a + b\n"),
             "width: short expression stays inline")
  assertTrue(not Str.contains(acc, "val x = a +\n"),
             "width: no spurious break for short expression")
}

func testCommentBetweenBinopOperands(): Unit {
  // Phase 5 §M5.3 stage 10 (D-progress-146): a comment between two
  // operands of a binary op survives `lyric fmt` — the multi-line
  // EBinop layout pops trivia at the RHS's start offset.
  val src =
    "package P\n" +
    "func f(): Int {\n" +
    "  val x = a +\n" +
    "    // sum carry\n" +
    "    b\n" +
    "  x\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// sum carry"),
             "binop: comment between operands preserved")
  assertTrue(Str.contains(acc, "a +\n    // sum carry"),
             "binop: comment lands between operator and RHS")
}

func testCommentBetweenListElements(): Unit {
  // A `// primes` comment between two list elements anchors at the
  // following element's start offset and renders inside the multi-
  // line list layout.
  val src =
    "package P\n" +
    "func f(): Int {\n" +
    "  val xs = [\n" +
    "    // primes\n" +
    "    2,\n" +
    "    3,\n" +
    "    5\n" +
    "  ]\n" +
    "  0\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "    // primes\n    2,"),
             "list: comment between elements stays inside the list")
}

func testCommentBeforeFunctionParam(): Unit {
  // A `// x is the input` comment sitting before the first parameter
  // in a multi-line function signature anchors at the first param's
  // leading trivia.  The signature breaks across lines because the
  // formatter detects the comment in the param region.
  val src =
    "package P\n" +
    "func process(\n" +
    "  // x is the input\n" +
    "  x: in Int,\n" +
    "  y: in Int\n" +
    "): Int { x + y }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// x is the input"),
             "param: comment before first param preserved")
  assertTrue(Str.contains(acc, "func process(\n"),
             "param: signature breaks across lines when params have comments")
  assertTrue(Str.contains(acc, "  x: in Int,\n"),
             "param: each param on its own line with trailing comma")
}

func testWidthDrivenLongParamList(): Unit {
  // A function with so many parameters that the inline rendering
  // exceeds the 120-char budget gets a multi-line signature.
  val src =
    "package P\n" +
    "func longSig(aaaa: in Int, bbbb: in Int, cccc: in Int, dddd: in Int, eeee: in Int, ffff: in Int, gggg: in Int, hhhh: in Int, iiii: in Int): Int { 0 }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "func longSig(\n"),
             "param: signature breaks at the (")
  assertTrue(Str.contains(acc, "  aaaa: in Int,\n"),
             "param: first param on its own line")
}

func testOutModeRendersCorrectly(): Unit {
  // Regression test for the `PMOut` → `"acc "` rename slip from the
  // original sed-driven reserved-keyword cleanup.  An `out` parameter
  // must round-trip as `: out Type`.
  val src = "package P\nfunc set(x: out Int): Unit { }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "x: out Int"),
             "param: PMOut renders as `out`, not `acc`")
}

func testCommentInsideLambdaBody(): Unit {
  // Phase 5 §M5.3 stage 11 (D-progress-147): a `// process input`
  // comment inside a lambda body anchors via `blockLines` (the body
  // is parsed as a `Block`).  The lambda renders multi-line because
  // the inner trivia trigger forces it.
  val src =
    "package P\n" +
    "func go(): Int {\n" +
    "  val cb = { x: Int ->\n" +
    "    // process input\n" +
    "    val y = x + 1\n" +
    "    y\n" +
    "  }\n" +
    "  cb(0)\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// process input"),
             "lambda: comment inside body preserved")
  assertTrue(Str.contains(acc, "{ x: Int ->\n"),
             "lambda: opener with params on its own line")
}

func testWidthDrivenLongLambdaBody(): Unit {
  // A lambda whose body — with the lambda braces, params, and
  // arrow — exceeds the 120-char budget breaks across lines.
  val src =
    "package P\n" +
    "func go(): Int {\n" +
    "  val cb = { x: Int, y: Int, z: Int -> aLongHelper(x) + bLongHelper(y) + cLongHelper(z) + dLongHelper(x) + eLongHelper(y) }\n" +
    "  cb(1, 2, 3)\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "{ x: Int, y: Int, z: Int ->\n"),
             "lambda: long body breaks after `->`")
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

func testForallBodyNoBraces(): Unit {
  // forall with a block body should NOT double-wrap in braces.
  // The parser wraps `{ p(i) }` in EBlock; the formatter must strip it.
  // Use a block-body function so the ensures: clause appears in output.
  val src =
    "package P\n" +
    "func q(i: in Int): Bool\n" +
    "  ensures: forall (j: Int) { j > 0 }\n" +
    "{\n" +
    "  return i > 0\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(not Str.contains(acc, "{ { "),
             "forall: no double braces in output")
  assertTrue(Str.contains(acc, "forall (j: Int) { j > 0 }"),
             "forall: single-brace block body round-trips")
}

func testWidthDrivenLongIfBreaks(): Unit {
  // An if-expression whose inline form exceeds 120 chars converts
  // to the brace layout (M5.3 stage 12).
  val src =
    "package P\n" +
    "func go(a: in Bool, b: in Bool): String {\n" +
    "  val r = if aVeryLongConditionThatExceedsTheBudgetWithArgumentsAndStuff(a, b) { \"first-result\" } else { \"second-result\" }\n" +
    "  r\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "if aVeryLongConditionThatExceedsTheBudgetWithArgumentsAndStuff(a, b) {\n"),
             "if-expr: long inline breaks to brace form")
  assertTrue(Str.contains(acc, "} else {\n"),
             "if-expr: else clause on its own line")
}

func testWidthDrivenLongMatchBreaks(): Unit {
  // A match-expression whose inline form exceeds 120 chars converts
  // to the brace layout (M5.3 stage 12).
  val src =
    "package P\n" +
    "func go(x: in Int): String {\n" +
    "  val r = match someVeryLongScrutineeExpressionThatForcesBreaking(x) { case 1 -> \"one\"; case 2 -> \"two\"; case _ -> \"other\" }\n" +
    "  r\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "match someVeryLongScrutineeExpressionThatForcesBreaking(x) {\n"),
             "match-expr: long inline breaks to brace form")
  assertTrue(Str.contains(acc, "case 1 ->"),
             "match-expr: arm rendered in body")
}

func testFBExprWithContracts(): Unit {
  // A func with an expression body AND contract clauses must preserve
  // both; the old FBExpr path dropped the contracts entirely.
  val src =
    "package P\n" +
    "func abs(x: in Int): Int\n" +
    "  ensures: result >= 0\n" +
    "  = if x >= 0 { x } else { -x }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "ensures: result >= 0"), "FBExpr+contracts: ensures preserved")
  assertTrue(Str.contains(acc, "= if x >= 0"), "FBExpr+contracts: expr body preserved")
}

func main(): Unit {
  testFormatPackageOnly()
  testFormatPackageAndImports()
  testFormatTypeAlias()
  testFormatRecord()
  testFormatMutableRecordField()
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
  testCommentBeforeContractClause()
  testBlankLineBetweenContractClauses()
  testCommentBeforeWhereClause()
  testCommentBetweenWhereAndContract()
  testWhereThenContractRoundTrips()
  testWidthDrivenLongCallBreaks()
  testWidthDrivenLongCallIdempotent()
  testCommentInsideCallArgs()
  testWidthDrivenLongBinopBreaks()
  testShortExpressionStaysInline()
  testCommentBetweenBinopOperands()
  testCommentBetweenListElements()
  testCommentBeforeFunctionParam()
  testWidthDrivenLongParamList()
  testOutModeRendersCorrectly()
  testCommentInsideLambdaBody()
  testWidthDrivenLongLambdaBody()
  testForallBodyNoBraces()
  testWidthDrivenLongIfBreaks()
  testWidthDrivenLongMatchBreaks()
  testFBExprWithContracts()
  println("fmt self-test: ok")
}
