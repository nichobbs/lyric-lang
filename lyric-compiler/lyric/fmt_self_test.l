//! fmt_self_test.l — exercises the self-hosted Lyric.Fmt library.
//! Compiled and executed by the F# Expecto runner at
//! compiler/tests/Lyric.Emitter.Tests/SelfHostedFmtTests.fs.  Each
//! in-program assertion panics on mismatch; exit 0 + an "ok" line in
//! stdout means every check held.
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
  assertTrue(Str.contains(acc, "func add(x: in Int, y: in Int): Int {"), "format: func signature")
  assertTrue(Str.contains(acc, "x + y"), "format: func body")
}

func testParamModeRoundTrips(): Unit {
  // A param with no mode keyword (`x: Int`) is sugar for `in`, but the
  // formatter must not synthesise an `in` the author never wrote.
  // Explicit `in`/`out`/`inout` are preserved verbatim.
  val src = "package P\n\nfunc f(x: Int, y: in String, z: out Int): Int {\n  z = x\n  x\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "param mode: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "x: Int,"), "param mode: bare param stays bare")
  assertTrue(not Str.contains(acc, "x: in Int"), "param mode: no synthesised `in`")
  assertTrue(Str.contains(acc, "y: in String"), "param mode: explicit `in` preserved")
  assertTrue(Str.contains(acc, "z: out Int"), "param mode: explicit `out` preserved")
}

func testParamAnnotationsRoundTrip(): Unit {
  // Leading parameter annotations (`@body req: in T`, `@query page: Int`)
  // must round-trip — they render inline before the parameter name (#2515).
  val src = "package P\n\nfunc h(@body req: in CreateReq, @query page: Int, plain: Int): Int {\n  page\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "param ann: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "@body req: in CreateReq"), "param ann: @body rendered inline before name")
  assertTrue(Str.contains(acc, "@query page: Int"), "param ann: @query rendered inline")
  assertTrue(Str.contains(acc, "plain: Int"), "param ann: un-annotated param unchanged")
}

func testParamAnnotationWithArgsRoundTrip(): Unit {
  // An annotation carrying arguments (`@header("X-Tenant")`) round-trips.
  val src = "package P\n\nfunc h(@header(\"X-Tenant\") tenant: String): Int {\n  0\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "param ann args: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "@header(\"X-Tenant\") tenant: String"), "param ann args: rendered with args")
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
  assertTrue(Str.contains(acc, "// A leading comment."), "comments: preserved before first item")
  assertTrue(Str.contains(acc, "// Between items."), "comments: preserved between items")
  assertTrue(Str.contains(acc, "alias A = Int"), "comments: first item still emitted")
  assertTrue(Str.contains(acc, "alias B = String"), "comments: second item still emitted")
}

func testCommentPreservationBlockComment(): Unit {
  val src = "package P\n\n/* block before */\nalias A = Int\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "/* block before */"), "comments: block comment preserved before item")
}

func testCommentPreservationTrailing(): Unit {
  val src = "package P\n\nalias A = Int\n\n// trailing after last\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// trailing after last"), "comments: trailing comment preserved")
}

func testEndOfLineCommentStaysInline(): Unit {
  // An end-of-line comment (on the same source line as the code) must be
  // re-attached to that line, not relocated to a standalone line before
  // the next item.  Covers record fields, statements, and match arms.
  val src = "package P\n\nrecord R {\n  owner: String  // who owns it\n  count: Int\n}\n\nfunc f(x: in Int): Int {\n  val a = x + 1  // bump\n  match a {\n    case 0 -> 0  // none\n    case _ -> a\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "trailing comment: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "owner: String  // who owns it"), "trailing: field comment stays inline")
  assertTrue(Str.contains(acc, "val a = x + 1  // bump"), "trailing: statement comment stays inline")
  assertTrue(Str.contains(acc, "case 0 -> 0  // none"), "trailing: match-arm comment stays inline")
}

func testTrailingCommentAlignmentPreserved(): Unit {
  // Hand-aligned trailing-comment columns are preserved: the formatter
  // re-emits the exact source gap before each `//` rather than collapsing
  // to a single two-space gap.  The code renders at its source width, so
  // preserving the gap preserves the alignment.
  val src = "package P\n\nfunc f(w: in Int): Int {\n  g(w, 0x014C)  // a\n  g(w, 1)       // b\n  0\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "alignment: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "g(w, 0x014C)  // a"), "alignment: first comment gap preserved")
  assertTrue(Str.contains(acc, "g(w, 1)       // b"), "alignment: wider gap preserved (columns stay aligned)")
}

func testSectionBannerStaysBetweenItems(): Unit {
  // A section-banner comment between two top-level items must stay between
  // them, not be pulled inside the preceding item's `}`.  Regression guard
  // for the item-span overshoot (`endSpan` was the next token past the
  // banner, so the body trivia pop swallowed it).
  val src = "package P\n\npub record A {\n  x: Int\n}\n\n// --- Section ---\n\npub record B {\n  y: Int\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "section banner: round-trips")
  val acc = format(parse(src))
  // The banner is preserved and is NOT indented into A's body (an
  // in-body comment would render with a two-space indent).
  assertTrue(Str.contains(acc, "// --- Section ---"), "section banner: preserved")
  assertTrue(not Str.contains(acc, "  // --- Section ---"), "section banner: not indented into A's body")
}

func testLastMemberTrailingCommentStaysInline(): Unit {
  // A trailing comment on the LAST member of a record / union body must
  // stay on the member's line; previously the closing-brace tail used
  // `popCommentsBefore` (leading) and split it onto its own line.
  val src = "package P\n\npub record A {\n  x: Int  // the x\n}\n\npub union U {\n  case Foo  // a foo\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "last-member comment: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "x: Int  // the x"), "last record field comment stays inline")
  assertTrue(Str.contains(acc, "case Foo  // a foo"), "last union case comment stays inline")
}

func testStatementSeparatorBeforeBracket(): Unit {
  // Two statements separated by `;` where the second begins with `(`
  // (here a unit expression).  The lexer synthesises no STMT_END inside
  // `{ }`, so dropping the `;` would let re-parse merge `g(x)` and `()`
  // into the call `g(x)()`.  The formatter must keep the `;`.
  val src = "package P\n\nfunc g(x: in Int): Unit {\n  ()\n}\n\nfunc f(x: in Int): Unit {\n  g(x); ()\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "stmt separator: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "g(x);"), "stmt separator: `;` kept before bracket-leading statement")
  assertTrue(not Str.contains(acc, "g(x)()"), "stmt separator: statements not merged into a call")
}

func testFormatPubFunc(): Unit {
  val src = "package P\npub func foo(): Unit { }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "pub func foo(): Unit"), "format: pub visibility on func")
}

func testFormatUnion(): Unit {
  val src = "package P\nunion Color { case Red; case Green; case Blue }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "union Color {"), "format: union header")
  assertTrue(Str.contains(acc, "case Red"), "format: case Red")
  assertTrue(Str.contains(acc, "case Green"), "format: case Green")
  assertTrue(Str.contains(acc, "case Blue"), "format: case Blue")
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

func testNumericLiteralSpellingRoundTrips(): Unit {
  // Numeric literals keep their verbatim source spelling rather than
  // canonicalising the parsed value: `0xFF` must not become `255`,
  // `100_000` must keep its underscore, the `i64` suffix must survive,
  // and `2.99` must not widen to `2.9899999999999998`.
  val src = "package P\n\nfunc f(): Int {\n  val a = 0xFF\n  val b = 100_000\n  val c = 1i64\n  val d = 2.99\n  a\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "numeric literals: round-trip")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "= 0xFF"), "numeric: hex spelling preserved")
  assertTrue(Str.contains(acc, "= 100_000"), "numeric: underscore preserved")
  assertTrue(Str.contains(acc, "= 1i64"), "numeric: suffix preserved")
  assertTrue(Str.contains(acc, "= 2.99"), "numeric: float spelling preserved")
  assertTrue(not Str.contains(acc, "255"), "numeric: hex not canonicalised")
}

func testFormatModuleDoc(): Unit {
  val src = "//! Module-level doc.\npackage P\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "//! Module-level doc."), "format: module doc preserved")
}

func testModuleHeaderNestedCommentPreserved(): Unit {
  // A plain `//` file header is auto-fixed to `//!`.  A header line whose
  // text contains a nested `//` (a code example like `//   // note`) must
  // survive: the loss guard normalises doc-comment payloads without
  // re-stripping a marker (the lexer already removed it), so the inner
  // `//` is not falsely counted as a dropped comment.
  val src = "// Banner.\n//\n//   // run the thing\n//   var x = 1\npackage P\n\nfunc f(): Int { 0 }\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "header nested comment: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "//!   // run the thing"), "header nested comment: preserved as //! line")
}

func testOpaqueTypeAnnotationAndBodyComment(): Unit {
  // `itemDoc` dispatches opaque types without the shared header, so the
  // leading annotation must be emitted by `opaqueDoc`; and a comment in an
  // (otherwise empty) opaque body must be popped before the closing brace.
  val src = "package P\n\n@stable(since = \"0.1\")\npub opaque type T {\n  // kernel-held handle\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "opaque type: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "@stable(since = \"0.1\")"), "opaque type: leading annotation preserved")
  assertTrue(Str.contains(acc, "// kernel-held handle"), "opaque type: body comment preserved")
}

func testInterfaceMethodDocAndContractPreserved(): Unit {
  // A body-less interface method's `///` doc comment and contract clauses
  // are stored on the `FunctionSig` and must survive formatting (they were
  // dropped previously because `FunctionSig` had no doc-comment field and
  // `interfaceDoc` rendered the bare signature only).
  val src = "package P\n\ninterface Store {\n  /// Fetch by key.\n  func get(key: in String): Int\n    requires: key.length > 0\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "interface method: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "/// Fetch by key."), "interface method: doc comment preserved")
  assertTrue(Str.contains(acc, "func get(key: in String): Int"), "interface method: signature preserved")
  assertTrue(Str.contains(acc, "requires: key.length > 0"), "interface method: contract preserved")
}

func testCommentInsideFunctionBody(): Unit {
  // Phase 5 §M5.3 stage 4 (D-progress-136): comments INSIDE a function
  // body must survive.  The block's harvested comments are popped at
  // each statement boundary and at the closing brace.
  val src = "package P\nfunc f(): Unit {\n  // setup\n  val x = 1\n  // process\n  val y = x\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// setup"), "internal: comment before first stmt preserved")
  assertTrue(Str.contains(acc, "// process"), "internal: comment between stmts preserved")
  assertTrue(Str.contains(acc, "val x = 1"), "internal: stmt 1 emitted")
  assertTrue(Str.contains(acc, "val y = x"), "internal: stmt 2 emitted")
}

func testCommentInsideRecordBody(): Unit {
  // Comments BETWEEN record fields must survive the record body walk.
  val src = "package P\nrecord Point {\n  x: Int\n  // y is the second axis\n  y: Int\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// y is the second axis"), "internal: between-field comment preserved")
  assertTrue(Str.contains(acc, "x: Int"), "internal: first field emitted")
  assertTrue(Str.contains(acc, "y: Int"), "internal: second field emitted")
}

func testCommentInsideUnionBody(): Unit {
  // Comments between union cases.
  val src = "package P\nunion Color {\n  case Red\n  // primaries\n  case Green\n  case Blue\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// primaries"), "internal: between-case comment preserved")
}

func testUnionCaseFieldTrailingCommentsPreserved(): Unit {
  // Issue #2453: trailing `// note` comments on the individual fields of a
  // multi-field union case (the `MEHClause` case in
  // lyric-compiler/msil/lowering.l) were dropped because the union-case
  // printer rendered the field list as a flat single line with no trivia
  // awareness.  The multi-line union-case layout now weaves each field's
  // trailing comment onto its own line.
  val src = "package P\n\nunion Insn {\n" + "  case Nop\n" + "  case EH(\n" +
    "    flags: Int,        // 0=catch, 2=finally\n" +
    "    tryStart: Int,     // start label\n" +
    "    catchToken: Int)   // type token\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "union field comments: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "// 0=catch, 2=finally"), "union field comments: first field comment preserved")
  assertTrue(Str.contains(acc, "// start label"), "union field comments: middle field comment preserved")
  assertTrue(Str.contains(acc, "// type token"), "union field comments: last field comment preserved")
  // Each field lands on its own line.
  assertTrue(Str.contains(acc, "\n    flags: Int,"), "union field comments: fields split across lines")
  assertTrue(isFormatted(acc, parse(acc)), "union field comments: idempotent")
}

func testUnionCaseNoCommentsStaysInline(): Unit {
  // Without interior trivia, a union case's fields stay on one line — the
  // multi-line split fires only to rescue comments.
  val src = "package P\n\nunion Pair {\n  case P(a: Int, b: Int)\n}\n"
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "case P(a: Int, b: Int)"), "union no comments: fields stay inline")
}

func testCommentInsideEnumBody(): Unit {
  // Comments between enum cases.
  val src = "package P\nenum Dir {\n  case North\n  // horizontal\n  case East\n  case West\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// horizontal"), "internal: enum between-case comment preserved")
}

func testCommentInsideNestedBlock(): Unit {
  // Comments inside a nested block (if-then-block).
  val src = "package P\nfunc f(x: in Int): Unit {\n  if x > 0 {\n    // positive branch\n    val y = x\n  }\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// positive branch"), "internal: nested-block comment preserved")
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
  assertTrue(Str.contains(acc, "// group 1"), "blank: first comment group preserved")
  assertTrue(Str.contains(acc, "// group 2"), "blank: second comment group preserved")
  // The blank line shows as `\n\n` between the two groups.
  assertTrue(Str.contains(acc, "val a = 1\n\n  // group 2"), "blank: blank line preserved between comment groups")
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
  val src = "package P\n" + "func divide(x: in Int, y: in Int): Int\n" + "  // y must not be zero\n" +
    "  requires: y != 0\n" +
    "  // result times y reconstitutes x\n" +
    "  ensures: result * y == x\n" +
    "  { x / y }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// y must not be zero"), "contract: comment before requires preserved")
  assertTrue(
    Str.contains(acc, "// result times y reconstitutes x"),
    "contract: comment between requires and ensures preserved"
  )
  assertTrue(Str.contains(acc, "requires: y != 0"), "contract: requires clause emitted")
  assertTrue(Str.contains(acc, "ensures: result * y == x"), "contract: ensures clause emitted")
}

func testBlankLineBetweenContractClauses(): Unit {
  // A blank line between two contract clauses survives via the
  // HiBlank trivia stream + popTriviaBefore at the clause boundary.
  val src = "package P\n" + "func f(x: in Int): Int\n" + "  requires: x > 0\n" + "\n" + "  ensures: result > 0\n" +
    "  { x }\n"
  val pr = parse(src)
  val acc = format(pr)
  // The blank line shows as `\n\n  ensures` in the output.
  assertTrue(
    Str.contains(acc, "requires: x > 0\n\n  ensures: result > 0"),
    "contract: blank line between clauses preserved"
  )
}

func testCommentBeforeWhereClause(): Unit {
  // Phase 5 §M5.3 stage 8: a comment immediately before a `where`
  // clause on a function signature must survive — anchored at the
  // where clause's start offset.
  val src = "package P\n" + "func max[T](a: in T, b: in T): T\n" + "  // T must be ordered\n" + "  where T: Compare\n" +
    "  { if a > b { a } else { b } }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// T must be ordered"), "where: comment before where clause preserved")
  assertTrue(Str.contains(acc, "where T: Compare"), "where: where clause itself emitted")
}

func testCommentBetweenWhereAndContract(): Unit {
  // The self-hosted parser expects `where` BEFORE contract clauses on
  // a function signature.  A comment sitting between the where clause
  // and the following contract clause anchors at the contract clause
  // boundary.
  val src = "package P\n" + "func cap[T](x: in T): T\n" + "  where T: Compare\n" + "  // x is unchanged\n" +
    "  requires: true\n" +
    "  { x }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "where T: Compare"), "where+contract: where clause emitted")
  assertTrue(Str.contains(acc, "// x is unchanged"), "where+contract: comment between where and contract preserved")
  assertTrue(Str.contains(acc, "requires: true"), "where+contract: requires emitted")
}

func testWhereThenContractRoundTrips(): Unit {
  // Round-trip lock: the self-hosted parser accepts `where` only
  // before contract clauses, so the formatter must output them in
  // that order.  `format(format(parse(src))) == format(parse(src))`
  // and the second parse must succeed without diagnostics.
  val src = "package P\n" + "func cap[T](x: in T): T\n" + "  where T: Compare\n" + "  requires: true\n" + "  { x }\n"
  val pr1 = parse(src)
  assertEqualInt(pr1.diagnostics.count, 0, "round-trip: first parse clean")
  val once = format(pr1)
  val pr2 = parse(once)
  assertEqualInt(pr2.diagnostics.count, 0, "round-trip: re-parse of format output is clean")
  val twice = format(pr2)
  assertEqual(twice, once, "round-trip: format is idempotent for where+contracts")
  // Lock in the wire order: `where` must precede `requires` in the output.
  val wIdx = match Str.indexOf(once, "where T: Compare") { case Some(i) -> i; case None -> -1 }
  val rIdx = match Str.indexOf(once, "requires: true") { case Some(i) -> i; case None -> -1 }
  assertTrue(wIdx >= 0 and rIdx >= 0, "round-trip: both clauses emitted")
  assertTrue(wIdx < rIdx, "round-trip: where appears before requires")
}

func testWidthDrivenLongCallBreaks(): Unit {
  // Phase 5 §M5.3 stage 9 (D-progress-145): a function call whose
  // inline rendering would exceed the 120-character line budget at
  // its current column gets broken into one-arg-per-line layout.
  // Use a call comfortably over 120 chars to avoid budget-edge
  // flakiness.
  val src = "package P\n" + "func go(a: in Int): Int {\n" +
    "  val r = anExtraordinarilyLongFunctionName(a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a)\n" +
    "  r\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(
    Str.contains(acc, "anExtraordinarilyLongFunctionName(\n"),
    "width: long call opens with `(` on the same line and breaks args"
  )
  assertTrue(Str.contains(acc, "  )\n"), "width: long call closes with `)` on its own indented line")
}

func testWidthDrivenLongCallIdempotent(): Unit {
  // The width-driven multi-line layout must round-trip: format(format(x)) == format(x).
  val src = "package P\n" + "func go(a: in Int): Int {\n" +
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
  val src = "package P\n" + "func go(): Int {\n" + "  val x = foo(\n" + "    // first arg\n" + "    1,\n" + "    2\n" +
    "  )\n" +
    "  x\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "    // first arg\n    1,"), "width: comment between call args stays inside the call")
}

func testWidthDrivenLongBinopBreaks(): Unit {
  // A long chain of binary `+` operators breaks to one operand per
  // line with the operator at the end of the previous line.  The
  // test source is long enough to force the break.
  val src = "package P\n" + "func sum(a: in Int): Int {\n" +
    "  val x = aLongHelper(a) + bLongHelper(a) + cLongHelper(a) + dLongHelper(a) + eLongHelper(a) + fLongHelper(a) + gLongHelper(a)\n" +
    "  x\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  // At least one operator-at-end-of-line break must show up.
  assertTrue(Str.contains(acc, "+\n  "), "width: long binop breaks with operator at end-of-line")
}

func testShortExpressionStaysInline(): Unit {
  // Negative test: a short expression must NOT be split.  Locks in
  // the budget threshold: don't over-eagerly break.
  val src = "package P\nfunc f(): Int { val x = a + b; x }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "val x = a + b\n"), "width: short expression stays inline")
  assertTrue(not Str.contains(acc, "val x = a +\n"), "width: no spurious break for short expression")
}

func testCommentBetweenBinopOperands(): Unit {
  // Phase 5 §M5.3 stage 10 (D-progress-146): a comment between two
  // operands of a binary op survives `lyric fmt` — the multi-line
  // EBinop layout pops trivia at the RHS's start offset.
  val src = "package P\n" + "func f(): Int {\n" + "  val x = a +\n" + "    // sum carry\n" + "    b\n" + "  x\n" + "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// sum carry"), "binop: comment between operands preserved")
  assertTrue(Str.contains(acc, "a +\n    // sum carry"), "binop: comment lands between operator and RHS")
}

func testCommentBetweenListElements(): Unit {
  // A `// primes` comment between two list elements anchors at the
  // following element's start offset and renders inside the multi-
  // line list layout.
  val src = "package P\n" + "func f(): Int {\n" + "  val xs = [\n" + "    // primes\n" + "    2,\n" + "    3,\n" +
    "    5\n" +
    "  ]\n" +
    "  0\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "    // primes\n    2,"), "list: comment between elements stays inside the list")
}

func testCommentBeforeFunctionParam(): Unit {
  // A `// x is the input` comment sitting before the first parameter
  // in a multi-line function signature anchors at the first param's
  // leading trivia.  The signature breaks across lines because the
  // formatter detects the comment in the param region.
  val src = "package P\n" + "func process(\n" + "  // x is the input\n" + "  x: in Int,\n" + "  y: in Int\n" +
    "): Int { x + y }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// x is the input"), "param: comment before first param preserved")
  assertTrue(Str.contains(acc, "func process(\n"), "param: signature breaks across lines when params have comments")
  assertTrue(Str.contains(acc, "  x: in Int,\n"), "param: each param on its own line with trailing comma")
}

func testWidthDrivenLongParamList(): Unit {
  // A function with so many parameters that the inline rendering
  // exceeds the 120-char budget gets a multi-line signature.
  val src = "package P\n" +
    "func longSig(aaaa: in Int, bbbb: in Int, cccc: in Int, dddd: in Int, eeee: in Int, ffff: in Int, gggg: in Int, hhhh: in Int, iiii: in Int): Int { 0 }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "func longSig(\n"), "param: signature breaks at the (")
  assertTrue(Str.contains(acc, "  aaaa: in Int,\n"), "param: first param on its own line")
}

func testOutModeRendersCorrectly(): Unit {
  // Regression test for the `PMOut` → `"acc "` rename slip from the
  // original sed-driven reserved-keyword cleanup.  An `out` parameter
  // must round-trip as `: out Type`.
  val src = "package P\nfunc set(x: out Int): Unit { }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "x: out Int"), "param: PMOut renders as `out`, not `acc`")
}

func testCommentInsideLambdaBody(): Unit {
  // Phase 5 §M5.3 stage 11 (D-progress-147): a `// process input`
  // comment inside a lambda body anchors via `blockLines` (the body
  // is parsed as a `Block`).  The lambda renders multi-line because
  // the inner trivia trigger forces it.
  val src = "package P\n" + "func go(): Int {\n" + "  val cb = { x: Int ->\n" + "    // process input\n" +
    "    val y = x + 1\n" +
    "    y\n" +
    "  }\n" +
    "  cb(0)\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// process input"), "lambda: comment inside body preserved")
  assertTrue(Str.contains(acc, "{ x: Int ->\n"), "lambda: opener with params on its own line")
}

func testWidthDrivenLongLambdaBody(): Unit {
  // A lambda whose body — with the lambda braces, params, and
  // arrow — exceeds the 120-char budget breaks across lines.
  val src = "package P\n" + "func go(): Int {\n" +
    "  val cb = { x: Int, y: Int, z: Int -> aLongHelper(x) + bLongHelper(y) + cLongHelper(z) + dLongHelper(x) + eLongHelper(y) }\n" +
    "  cb(1, 2, 3)\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "{ x: Int, y: Int, z: Int ->\n"), "lambda: long body breaks after `->`")
}

func testFormatSourceFacade(): Unit {
  // String-in / string-out façade — the entry point the F# CLI calls
  // through reflection in M5.3 stage 2 (CLI wiring).
  val src = "package P\n\n// keep me\nalias A = Int\n"
  val acc = formatSource(src)
  assertTrue(Str.contains(acc, "// keep me"), "formatSource: comment preserved")
  assertTrue(Str.contains(acc, "alias A = Int"), "formatSource: item rendered")
  assertTrue(isFormattedSource(acc), "formatSource: output is canonical (idempotent)")
}

func testForallBodyNoBraces(): Unit {
  // forall with a block body should NOT double-wrap in braces.
  // The parser wraps `{ p(i) }` in EBlock; the formatter must strip it.
  // Use a block-body function so the ensures: clause appears in output.
  val src = "package P\n" + "func q(i: in Int): Bool\n" + "  ensures: forall (j: Int) { j > 0 }\n" + "{\n" +
    "  return i > 0\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(not Str.contains(acc, "{ { "), "forall: no double braces in output")
  assertTrue(Str.contains(acc, "forall (j: Int) { j > 0 }"), "forall: single-brace block body round-trips")
}

func testWidthDrivenLongIfBreaks(): Unit {
  // An if-expression whose inline form exceeds 120 chars converts
  // to the brace layout (M5.3 stage 12).
  val src = "package P\n" + "func go(a: in Bool, b: in Bool): String {\n" +
    "  val r = if aVeryLongConditionThatExceedsTheBudgetWithArgumentsAndStuff(a, b) { \"first-result\" } else { \"second-result\" }\n" +
    "  r\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(
    Str.contains(acc, "if aVeryLongConditionThatExceedsTheBudgetWithArgumentsAndStuff(a, b) {\n"),
    "if-expr: long inline breaks to brace form"
  )
  assertTrue(Str.contains(acc, "} else {\n"), "if-expr: else clause on its own line")
}

func testWidthDrivenLongMatchBreaks(): Unit {
  // A match-expression whose inline form exceeds 120 chars converts
  // to the brace layout (M5.3 stage 12).
  val src = "package P\n" + "func go(x: in Int): String {\n" +
    "  val r = match someVeryLongScrutineeExpressionThatForcesBreaking(x) { case 1 -> \"one\"; case 2 -> \"two\"; case _ -> \"other\" }\n" +
    "  r\n" +
    "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(
    Str.contains(acc, "match someVeryLongScrutineeExpressionThatForcesBreaking(x) {\n"),
    "match-expr: long inline breaks to brace form"
  )
  assertTrue(Str.contains(acc, "case 1 ->"), "match-expr: arm rendered in body")
}

func testThenFormIfArmCommentsPreserved(): Unit {
  // Issue #2453: a `then`-form if-expression whose then-arm and else-arm
  // each carry an end-of-line comment must keep each comment on its own
  // output line.  The flat inline rendering used to fuse them
  // (`then 3 else 6  // a  // b`), merging two comments into one on
  // re-lex; `lyric fmt --write` then refused with "would drop 2
  // comment(s)".  The trivia-aware `then`-form layout splits the arms.
  val src = "package P\n\nfunc f(x: in Int): Int {\n" + "  if x > 0 then 3   // three\n" +
    "  else 6            // six\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "then-if arm comments: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "then 3"), "then-if arm comments: then-arm value preserved")
  assertTrue(Str.contains(acc, "// three"), "then-if arm comments: then-arm comment preserved")
  assertTrue(Str.contains(acc, "// six"), "then-if arm comments: else-arm comment preserved")
  // The `else` must start a fresh line so the two `//` comments do not
  // collapse into one on re-lex.
  assertTrue(Str.contains(acc, "\n  else 6"), "then-if arm comments: else on its own line")
  // Idempotent: formatting the result is a fixed point.
  assertTrue(isFormatted(acc, parse(acc)), "then-if arm comments: idempotent")
}

func testThenFormIfArmCommentsInMatchArm(): Unit {
  // The same fix must apply when the `then`-form if is a match-arm body
  // (the `lyric-compiler/jvm/bytecode.l` `insnSize` case): the arm body
  // routes through the ctx-aware printer so the interior comment survives.
  val src = "package P\n\nfunc g(x: in Int): Int {\n" + "  match x {\n" + "    case 0 ->\n" +
    "      if x > 0 then 3   // op + u1\n" +
    "      else 6            // wide + op\n" +
    "    case _ -> 1\n" +
    "  }\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "then-if in match arm: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "// op + u1"), "then-if in match arm: then-arm comment preserved")
  assertTrue(Str.contains(acc, "// wide + op"), "then-if in match arm: else-arm comment preserved")
  assertTrue(isFormatted(acc, parse(acc)), "then-if in match arm: idempotent")
}

func testThenFormIfNoCommentsStaysInline(): Unit {
  // Without interior trivia, a `then`-form if stays on one line — the
  // multi-line split fires only to rescue comments.
  val src = "package P\n\nfunc f(x: in Int): Int {\n  if x > 0 then 3 else 6\n}\n"
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "if x > 0 then 3 else 6"), "then-if no comments: stays inline")
  assertTrue(not Str.contains(acc, "\n  else"), "then-if no comments: no spurious else break")
}

func testThenFormIfElseChainCommentsPreserved(): Unit {
  // An `else if` chain in `then`-form with a comment on an intermediate
  // arm: the recursion through `ifThenFormDoc` weaves each comment in.
  val src = "package P\n\nfunc f(x: in Int): Int {\n" + "  if x > 2 then 9   // big\n" +
    "  else if x > 0 then 3   // mid\n" +
    "  else 0                 // zero\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "then-if else-chain: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "// big"), "then-if else-chain: first comment preserved")
  assertTrue(Str.contains(acc, "// mid"), "then-if else-chain: middle comment preserved")
  assertTrue(Str.contains(acc, "// zero"), "then-if else-chain: last comment preserved")
  assertTrue(isFormatted(acc, parse(acc)), "then-if else-chain: idempotent")
}

func testFBExprWithContracts(): Unit {
  // A func with an expression body AND contract clauses must preserve
  // both; the old FBExpr path dropped the contracts entirely.
  val src = "package P\n" + "func abs(x: in Int): Int\n" + "  ensures: result >= 0\n" +
    "  = if x >= 0 { x } else { -x }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "ensures: result >= 0"), "FBExpr+contracts: ensures preserved")
  assertTrue(Str.contains(acc, "= if x >= 0"), "FBExpr+contracts: expr body preserved")
}

// ─── Loss-checked guard + module-comment auto-fix + field-doc preservation ───
func testFormatSourceCheckedOk(): Unit {
  val c = formatSourceChecked("package P\n\nfunc f(x: in Int): Int {\n  x\n}\n")
  assertTrue(fmtCheckIsOk(c), "checked: clean source is FmtOk")
}

func testFormatSourceCheckedInputParseError(): Unit {
  // A `///` doc comment before `package` has no item to attach to (P0020),
  // so the input is rejected and never reformatted.
  val c = formatSourceChecked("/// orphan doc\npackage P\n")
  assertTrue(not fmtCheckIsOk(c), "checked: parse-error input is refused")
  assertTrue(Str.contains(fmtCheckMessage(c), "parse error"), "checked: input-parse message")
}

func testStringEscapeCanonicalizationAccepted(): Unit {
  // Canonicalising a string escape (here `\u{80}`, a C1 control rendered
  // as its literal scalar) is NOT a code-token change: the loss check
  // compares string literals by decoded value, so the round-trip is
  // accepted rather than refused.  This used to be flagged via raw-spelling
  // comparison — closing that gap was part of #2452.
  val c = formatSourceChecked("package P\n\nfunc f(): Unit {\n  val s = \"a\\u{80}b\"\n}\n")
  assertTrue(fmtCheckIsOk(c), "checked: string-escape canonicalisation accepted")
}

func testExternPackageRoundTrips(): Unit {
  // Extern packages round-trip: the `package` keyword, each member's
  // visibility, doc comments, and contracts, and the `exposed type`
  // spelling are all preserved (previously the formatter dropped the
  // `package` keyword and every member's `pub`/doc/contract, so the guard
  // refused the whole file).
  val src = "package P\n\nextern package Host.X {\n  /// Doc.\n  pub func f(x: in Int): Int\n    requires: x > 0\n\n  pub exposed type Handle\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "extern package: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "extern package Host.X {"), "extern package: keyword preserved")
  assertTrue(Str.contains(acc, "pub func f(x: in Int): Int"), "extern package: member visibility preserved")
  assertTrue(Str.contains(acc, "requires: x > 0"), "extern package: member contract preserved")
  assertTrue(Str.contains(acc, "pub exposed type Handle"), "extern package: exposed type preserved")
  assertTrue(Str.contains(acc, "/// Doc."), "extern package: member doc preserved")
}

func testReturnTryRoundTrips(): Unit {
  // The parser models `return try { … } catch { … }` as a `return` whose
  // value is a single-statement block wrapping the `try`.  The formatter
  // must render the bare `return try …` rather than injecting an extra
  // `{ … }` and collapsing the multi-statement body onto one line.
  val src = "package P\n\nfunc run(): Int {\n  return try {\n    f(1)\n  } catch Bug as e {\n    0\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "return-try: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "return try {"), "return-try: bare try preserved")
  assertTrue(not Str.contains(acc, "return {"), "return-try: no injected wrapping brace")
}

func testMatchArmBareReturnRoundTrips(): Unit {
  // A bare `case P -> return e` arm body is also a parser-synthesised
  // single-statement block; it must render without injected braces.
  val src = "package P\n\nfunc f(o: in Option[Int]): Int {\n  match o {\n    case Some(e) -> return e\n    case None -> 0\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "match-arm bare return: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "case Some(e) -> return e"), "match-arm bare return: stays bare")
}

func testMatchArmExplicitBracePreserved(): Unit {
  // When the author *did* write braces around a single `return`, the span
  // check distinguishes them from the bare form so they are preserved
  // (no token change) rather than unwrapped.
  val src = "package P\n\nfunc f(o: in Option[Int]): Int {\n  match o {\n    case Some(e) -> { return e }\n    case None -> 0\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "match-arm explicit braces: round-trips")
}

func testModuleHeaderAutoFix(): Unit {
  // A plain `//` header block before `package` is promoted to `//!`.
  val acc = format(parse("// my module\n// second line\npackage P\n"))
  assertTrue(Str.contains(acc, "//! my module"), "auto-fix: // header -> //!")
  assertTrue(Str.contains(acc, "//! second line"), "auto-fix: multi-line header")
  assertTrue(not Str.contains(acc, "// my module"), "auto-fix: old // form gone")
}

func testFieldDocCommentPreserved(): Unit {
  // A `///` doc comment on a record field survives formatting (the field
  // printer historically dropped it).
  val acc = format(parse("package P\n\nrecord R {\n  /// the x coordinate\n  x: Int\n}\n"))
  assertTrue(Str.contains(acc, "/// the x coordinate"), "field doc: comment preserved")
  assertTrue(Str.contains(acc, "x: Int"), "field doc: field preserved")
}

func testFieldAnnotationsStayWithTheirField(): Unit {
  // A record (or config) field's leading annotation must stay attached to
  // that field across a round-trip.  Inside a `{ }` body the lexer emits no
  // statement-end tokens, so the parser's trailing-annotation scan used to
  // swallow the *next* field's leading annotation, clumping both onto the
  // first field and reordering the token stream (#2454).  The fix
  // (`parseSameLineTrailingAnnotations`) only treats an annotation as
  // trailing when it shares the field's source line.
  val src = "package P\n\nrecord R {\n  @proto_field(1) id: Long\n  @proto_field(2) name: String\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "field annotations: round-trips")
  val acc = format(parse(src))
  // Each annotation renders on its own line directly above its own field.
  assertTrue(Str.contains(acc, "@proto_field(1)\n  id: Long"), "field annotations: first stays with id")
  assertTrue(Str.contains(acc, "@proto_field(2)\n  name: String"), "field annotations: second stays with name")
}

func testCharLiteralRendering(): Unit {
  // Char literals must round-trip.  `intToChar` once mangled every char
  // outside 0-31 / digits / a-f into `'?'`, corrupting ordinary letters,
  // space, and punctuation on every format pass (#2280 item 3).
  val z = format(parse("package P\n\nfunc f(): Char {\n  'z'\n}\n"))
  assertTrue(Str.contains(z, "'z'"), "char: 'z' preserved")
  assertTrue(not Str.contains(z, "'?'"), "char: 'z' not mangled to '?'")
  val up = format(parse("package P\n\nfunc g(): Char {\n  'A'\n}\n"))
  assertTrue(Str.contains(up, "'A'"), "char: uppercase 'A' preserved")
  val slash = format(parse("package P\n\nfunc h(): Char {\n  '/'\n}\n"))
  assertTrue(Str.contains(slash, "'/'"), "char: '/' preserved")
}

func testUnicodeEscapeInStringRoundTrips(): Unit {
  // A `\u{…}` escape inside a string literal must round-trip with its
  // braces intact.  `escapeStr` once emitted the legacy braceless
  // `\uXXXX` form for control characters, which the lexer rejects with
  // L0021 ("expected '{' after \u"), so the guard refused every file
  // containing a control-character escape (#2452).
  val src = "package P\n\nfunc f(): String {\n  \"\\u{0000}\"\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "unicode escape: control char round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "\\u{0000}"), "unicode escape: braces preserved")
  assertTrue(not Str.contains(acc, "\\u0000"), "unicode escape: no braceless form")
}

func testNonBmpEscapeLiteralRoundTrips(): Unit {
  // A printable non-ASCII scalar (here U+00E9 'é', written `\u{00E9}`)
  // is canonicalised to its literal character, but because the loss
  // check now compares string tokens by decoded value the round-trip is
  // accepted rather than flagged as a code-token change (#2452).
  val src = "package P\n\nfunc f(): String {\n  \"\\u{00E9}\"\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "non-control escape: round-trips losslessly")
}

func testLiteralDollarBraceRoundTrips(): Unit {
  // A plain string whose content contains a literal `${` must round-trip
  // as `\${`: an unescaped `${` re-lexes as an interpolation hole.  Build
  // the source by concatenation so this test file itself never carries an
  // adjacent `${` (#2452).
  val bs = "\\"
  val dollar = "$"
  val src = "package P\n\nfunc f(): String {\n  \"" + bs + dollar + "{\"\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "literal dollar-brace: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, bs + dollar + "{"), "literal dollar-brace: escape preserved")
}

func testInterpolatedStringRoundTrips(): Unit {
  // A real interpolation `"x${s}y"` must round-trip — the formatter's own
  // `interpolatedStr` was silently mis-lexed (its `"${"` literal became an
  // interpolation hole), so every formatted hole collapsed to a constant.
  // Build the source by concatenation to keep `${` out of this file's text.
  val dollar = "$"
  val src = "package P\n\nfunc f(s: in String): String {\n  \"x" + dollar + "{s}y\"\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "interpolation: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "x" + dollar + "{s}y"), "interpolation: hole preserved")
}

func testWhileLoopInvariantRoundTrips(): Unit {
  // Loop invariants live in the source header (between the condition and
  // the `{`); the parser prepends them as `SInvariant` statements at the
  // top of the body.  The formatter must lift them back into the header —
  // a bare `invariant:` statement inside a block is a P0050 parse error
  // (#2452).
  val src = "package P\n\nfunc f(): Int {\n  var i = 0\n  while i < 5\n    invariant: i >= 0\n  {\n    i = i + 1\n  }\n  i\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "while invariant: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "invariant: i >= 0"), "while invariant: clause preserved")
}

func testForLoopInvariantRoundTrips(): Unit {
  val src = "package P\n\nfunc f(xs: in List[Int]): Int {\n  var s = 0\n  for x in xs\n    invariant: s >= 0\n  {\n    s = s + x\n  }\n  s\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "for invariant: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "invariant: s >= 0"), "for invariant: clause preserved")
}

func testAspectAroundRetNameRoundTrips(): Unit {
  // The `around(args) -> ret { … }` return binder must survive: the
  // parser built it via an `if … { Some(x) } else { None }` value that
  // the stage-0 emitter mis-lowered to `None`, dropping `-> ret` (#2452).
  val src = "package P\n\npub aspect X {\n  around(call) -> ret {\n    ret = call.proceed()\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "aspect around: retName round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "around(call) -> ret {"), "aspect around: `-> ret` preserved")
}

func testAspectConfigBlockRoundTrips(): Unit {
  // An aspect's anonymous `config { }` block was dropped entirely by the
  // formatter; it must now be emitted between `matches:` and the `around`
  // advice (#2452).
  val src = "package P\n\npub aspect X {\n  config {\n    enabled: Bool = true\n  }\n\n  around(call) -> ret {\n    ret = call.proceed()\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "aspect config: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "config {"), "aspect config: block preserved")
  assertTrue(Str.contains(acc, "enabled: Bool = true"), "aspect config: field preserved")
  assertTrue(Str.contains(acc, "around(call) -> ret {"), "aspect config: around still present")
}

func testAspectFromClauseRoundTrips(): Unit {
  // The instantiation form `aspect Name from Pkg.Template { … }` must
  // preserve its `from Pkg.Template` header clause.  The renderer dropped
  // `ad.from` entirely, so a `from`-form aspect could not round-trip
  // through `lyric fmt` (the missing tokens tripped the loss check) (#2451).
  val src = "package P\n\naspect Throttle from Web.Aspects.RateLimit {\n  matches: name like \"handle*\"\n  config {\n    requestsPerMinute: Int = 120\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "aspect from: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "aspect Throttle from Web.Aspects.RateLimit {"), "aspect from: clause preserved")
  assertTrue(Str.contains(acc, "    requestsPerMinute: Int = 120"), "aspect from: config field at 4-space indent")
}

func testAspectMatchesNameInRoundTrips(): Unit {
  // The set-membership matcher `matches: name in { fn1, fn2 }` must parse and
  // round-trip through `lyric fmt` — previously the parser rejected it with
  // P0298 ("expected 'like' after 'name'"), blocking the examples/* files
  // (rbac, ledger, jobqueue, …) that use it heavily (#2450).
  val src = "package P\n\naspect Auth from Web.Aspects.RequiresAuth {\n  matches: name in { handleCreateAccount, handleCreateTransfer }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "aspect name-in: round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "  matches: name in { handleCreateAccount, handleCreateTransfer }"),
    "aspect name-in: matcher rendered with canonical spacing"
  )
}

func testAspectMatchesNameInAndExceptRoundTrips(): Unit {
  // `name in { … }` composes with `and` and the `except name in { … }`
  // exclusion clause — both use the shared set parser.
  val src = "package P\n\naspect A {\n  matches: name in { foo, bar } and visibility: pub except name in { baz }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "aspect name-in + and + except: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "name in { foo, bar }"), "aspect name-in: positive set preserved")
  assertTrue(Str.contains(acc, "visibility: pub"), "aspect name-in: and-joined predicate preserved")
  assertTrue(Str.contains(acc, "except name in { baz }"), "aspect name-in: except clause preserved")
}

func testNestedMatchTrailingCommentIdempotent(): Unit {
  // A trailing comment on the LAST arm of a *nested* match (a match that is
  // itself the body of an enclosing match arm) must stay attached to that
  // arm across repeated format passes.  Previously `matchLines` left it
  // unconsumed at the closing brace, so it bubbled out to the outer match —
  // moving the comment and flipping the nested match between multi-line and
  // inline on the second pass (an idempotency break exposed by #2452).
  val src = "package P\n\nfunc f(o: in Option[Int], lv: in String): Bool {\n  match o {\n    case None -> return true\n    case Some(locked) ->\n      match lv {\n        case \"x\" -> if lv != \"y\" { return true }\n        case _   -> ()  // presence suffices for the cheap check\n      }\n  }\n  false\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "nested-match comment: round-trips")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "nested-match comment: idempotent")
  assertTrue(
    Str.contains(once, "()  // presence suffices for the cheap check"),
    "nested-match comment: stays on the arm"
  )
}

func testAspectInterMemberBlankIdempotent(): Unit {
  // Blank lines between aspect members (config / ensures / around) must not
  // leak into the around body: `aspectDoc` consumes the pre-around trivia,
  // so two separate source blank-runs can't land adjacent inside the body
  // and collapse on the next pass (#2452).
  val src = "package P\n\npub aspect X {\n  config {\n    enabled: Bool = true\n  }\n\n  ensures: true\n\n  around(call) -> ret {\n    ret = call.proceed()\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "aspect inter-member blank: round-trips")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "aspect inter-member blank: idempotent")
}

func testProtectedInterMemberBlankIdempotent(): Unit {
  // The same leak occurs in protected types: a blank between a type-level
  // `invariant:` and an `entry` body would otherwise be dumped into the
  // entry body and collapse on re-format.  `protectedTypeDoc` consumes
  // inter-member trivia (#2452).
  val src = "package P\n\npub protected type Counter {\n  var n: Int = 0\n  invariant: n >= 0\n\n  entry bump(): Unit {\n    n = n + 1\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "protected inter-member blank: round-trips")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "protected inter-member blank: idempotent")
}

func main(): Unit {
  testFieldAnnotationsStayWithTheirField()
  testAspectInterMemberBlankIdempotent()
  testProtectedInterMemberBlankIdempotent()
  testNestedMatchTrailingCommentIdempotent()
  testUnicodeEscapeInStringRoundTrips()
  testNonBmpEscapeLiteralRoundTrips()
  testLiteralDollarBraceRoundTrips()
  testInterpolatedStringRoundTrips()
  testWhileLoopInvariantRoundTrips()
  testForLoopInvariantRoundTrips()
  testAspectAroundRetNameRoundTrips()
  testAspectConfigBlockRoundTrips()
  testAspectFromClauseRoundTrips()
  testAspectMatchesNameInRoundTrips()
  testAspectMatchesNameInAndExceptRoundTrips()
  testCharLiteralRendering()
  testFormatSourceCheckedOk()
  testFormatSourceCheckedInputParseError()
  testStringEscapeCanonicalizationAccepted()
  testExternPackageRoundTrips()
  testReturnTryRoundTrips()
  testMatchArmBareReturnRoundTrips()
  testMatchArmExplicitBracePreserved()
  testModuleHeaderAutoFix()
  testFieldDocCommentPreserved()
  testFormatPackageOnly()
  testFormatPackageAndImports()
  testFormatTypeAlias()
  testFormatRecord()
  testFormatMutableRecordField()
  testFormatFunction()
  testParamModeRoundTrips()
  testParamAnnotationsRoundTrip()
  testParamAnnotationWithArgsRoundTrip()
  testIsFormattedRoundTrip()
  testCommentPreservationBetweenItems()
  testCommentPreservationBlockComment()
  testCommentPreservationTrailing()
  testEndOfLineCommentStaysInline()
  testTrailingCommentAlignmentPreserved()
  testSectionBannerStaysBetweenItems()
  testLastMemberTrailingCommentStaysInline()
  testStatementSeparatorBeforeBracket()
  testFormatPubFunc()
  testFormatUnion()
  testFormatEnum()
  testFormatVal()
  testNumericLiteralSpellingRoundTrips()
  testFormatModuleDoc()
  testModuleHeaderNestedCommentPreserved()
  testOpaqueTypeAnnotationAndBodyComment()
  testInterfaceMethodDocAndContractPreserved()
  testFormatSourceFacade()
  testCommentInsideFunctionBody()
  testCommentInsideRecordBody()
  testCommentInsideUnionBody()
  testUnionCaseFieldTrailingCommentsPreserved()
  testUnionCaseNoCommentsStaysInline()
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
  testThenFormIfArmCommentsPreserved()
  testThenFormIfArmCommentsInMatchArm()
  testThenFormIfNoCommentsStaysInline()
  testThenFormIfElseChainCommentsPreserved()
  testWidthDrivenLongMatchBreaks()
  testFBExprWithContracts()
  println("fmt self-test: ok")
}
