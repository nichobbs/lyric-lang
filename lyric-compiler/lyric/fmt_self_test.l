//! fmt_self_test.l — exercises the self-hosted Lyric.Fmt library.
//! Run in CI via native `lyric test` (no F# runner shim).
@test_module
package Lyric.FmtSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.Parser
import Lyric.Fmt

test "format package only" {
  val pr = parse("package Foo.Bar\n")
  val acc = format(pr)
  assertEqual(acc, "package Foo.Bar\n", "format: package-only")
}

test "format package and imports" {
  val src = "package P\nimport Std.Core\nimport Std.Collections\n"
  val pr = parse(src)
  val acc = format(pr)
  val expected = "package P\n\nimport Std.Core\nimport Std.Collections\n"
  assertEqual(acc, expected, "format: package + imports")
}

test "import extern with selector group round trips" {
  // #3728: `importDoc`'s `externKw` logic must not drop the `extern`
  // keyword when rendering a selector-group import.
  val src = "package P\n\nimport extern System.Net.Http.{ HttpClient }\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "import extern group: round-trips")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "import extern group: idempotent")
  assertTrue(
    Str.contains(once, "import extern System.Net.Http.{HttpClient}"),
    "import extern group: extern keyword and selector both preserved"
  )
}

test "pub use extern with selector group round trips" {
  val src = "package P\n\npub use extern Foo.Bar.{ Baz }\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "pub use extern group: round-trips")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "pub use extern group: idempotent")
  assertTrue(
    Str.contains(once, "pub use extern Foo.Bar.{Baz}"),
    "pub use extern group: extern keyword and selector both preserved"
  )
}

test "format type alias" {
  val src = "package P\nalias Name = String\n"
  val pr = parse(src)
  val acc = format(pr)
  val expected = "package P\n\nalias Name = String\n"
  assertEqual(acc, expected, "format: type alias")
}

test "format record" {
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
test "format mutable record field" {
  val src = "package P\nrecord Counter {\n  var count: Int\n  step: Int\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "var count: Int"), "format: var field keeps marker")
  assertTrue(Str.contains(acc, "step: Int"), "format: plain field unchanged")
  assertTrue(not Str.contains(acc, "var step"), "format: plain field stays immutable")
  assertTrue(isFormatted(acc, pr), "format: var field idempotent")
}

test "format function" {
  val src = "package P\nfunc add(x: in Int, y: in Int): Int { x + y }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "func add(x: in Int, y: in Int): Int {"), "format: func signature")
  assertTrue(Str.contains(acc, "x + y"), "format: func body")
}

test "param annotation round trips" {
  // A parameter may carry leading annotations (`@body req: in T`), consumed
  // by libraries such as lyric-web.  The parser records them on `Param`; the
  // formatter renders them inline before the param name (#2454).
  val src = "package P\n\npub func h(@body req: in CreateRequest, authToken: String): Int {\n  0\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "param annotation: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "@body req: in CreateRequest"), "param annotation: rendered inline before the name")
  assertTrue(Str.contains(acc, "authToken: String"), "param annotation: un-annotated param unchanged")
}

test "param mode round trips" {
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

test "is formatted round trip" {
  val src = "package P\n\nalias Name = String\n"
  val pr = parse(src)
  // After parsing + formatting, isFormatted should be true.
  assertTrue(isFormatted(format(pr), pr), "format: idempotent")
}

test "comment preservation between items" {
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

test "comment preservation block comment" {
  val src = "package P\n\n/* block before */\nalias A = Int\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "/* block before */"), "comments: block comment preserved before item")
}

test "comment preservation trailing" {
  val src = "package P\n\nalias A = Int\n\n// trailing after last\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// trailing after last"), "comments: trailing comment preserved")
}

test "end of line comment stays inline" {
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

test "trailing comment alignment preserved" {
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

test "section banner stays between items" {
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

test "last member trailing comment stays inline" {
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

test "statement separator before bracket" {
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

test "format pub func" {
  val src = "package P\npub func foo(): Unit { }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "pub func foo(): Unit"), "format: pub visibility on func")
}

// #6039: the visibility renderers collapsed `Some(_) -> "pub "` regardless of
// whether the underlying `Visibility` was `VisPub` or `VisInternal`, so every
// `internal` declaration was silently rewritten to `pub` — tripping the
// formatter's own loss-check (`token changed: internal -> pub`) and making
// `internal`-bearing files unformattable.
test "internal func round trips and is not rewritten to pub" {
  val src = "package P\n\ninternal func foo(): Unit {}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "internal func: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "internal func foo(): Unit"), "internal func: visibility preserved verbatim")
  assertTrue(not Str.contains(acc, "pub func foo"), "internal func: not rewritten to pub")
  val twice = format(parse(acc))
  assertEqual(acc, twice, "internal func: idempotent")
}

test "internal val round trips and is not rewritten to pub" {
  val src = "package P\n\ninternal val pi: Double = 3.14\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "internal val: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "internal val pi: Double = 3.14"), "internal val: visibility preserved verbatim")
  assertTrue(not Str.contains(acc, "pub val pi"), "internal val: not rewritten to pub")
}

test "internal record and internal record field round trip" {
  val src = "package P\n\ninternal record Point {\n  internal x: Int\n  y: Int\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "internal record: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "internal record Point {"), "internal record: header visibility preserved")
  assertTrue(Str.contains(acc, "internal x: Int"), "internal record: field visibility preserved")
  assertTrue(Str.contains(acc, "y: Int"), "internal record: unmarked field stays unmarked")
  assertTrue(not Str.contains(acc, "pub record Point"), "internal record: header not rewritten to pub")
  assertTrue(not Str.contains(acc, "pub x: Int"), "internal record: field not rewritten to pub")
}

test "internal union round trips and is not rewritten to pub" {
  val src = "package P\n\ninternal union Color { case Red; case Green }\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "internal union: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "internal union Color {"), "internal union: visibility preserved verbatim")
  assertTrue(not Str.contains(acc, "pub union Color"), "internal union: not rewritten to pub")
}

test "internal enum round trips and is not rewritten to pub" {
  val src = "package P\n\ninternal enum Dir { case North; case South }\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "internal enum: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "internal enum Dir {"), "internal enum: visibility preserved verbatim")
  assertTrue(not Str.contains(acc, "pub enum Dir"), "internal enum: not rewritten to pub")
}

test "internal type alias round trips and is not rewritten to pub" {
  val src = "package P\n\ninternal alias Name = String\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "internal alias: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "internal alias Name = String"), "internal alias: visibility preserved verbatim")
  assertTrue(not Str.contains(acc, "pub alias Name"), "internal alias: not rewritten to pub")
}

test "internal distinct type round trips and is not rewritten to pub" {
  val src = "package P\n\ninternal type UserId = Long\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "internal distinct type: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "internal type UserId = Long"), "internal distinct type: visibility preserved verbatim")
  assertTrue(not Str.contains(acc, "pub type UserId"), "internal distinct type: not rewritten to pub")
}

test "internal opaque type round trips and is not rewritten to pub" {
  val src = "package P\n\ninternal opaque type Token {\n  raw: String\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "internal opaque type: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "internal opaque type Token {"), "internal opaque type: visibility preserved verbatim")
  assertTrue(not Str.contains(acc, "pub opaque type Token"), "internal opaque type: not rewritten to pub")
}

test "format union" {
  val src = "package P\nunion Color { case Red; case Green; case Blue }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "union Color {"), "format: union header")
  assertTrue(Str.contains(acc, "case Red"), "format: case Red")
  assertTrue(Str.contains(acc, "case Green"), "format: case Green")
  assertTrue(Str.contains(acc, "case Blue"), "format: case Blue")
}

test "format enum" {
  val src = "package P\nenum Dir { case North; case South; case East; case West }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "enum Dir {"), "format: enum header")
  assertTrue(Str.contains(acc, "case North"), "format: enum case")
}

// `const` is not yet wired through the self-hosted parser; the
// formatter renders it via `IConst` whenever the parser does start
// emitting it.  Skipped for now.
test "format val" {
  val src = "package P\nval pi: Double = 3.14\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "val pi: Double = 3.14"), "format: val")
}

test "numeric literal spelling round trips" {
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

test "format module doc" {
  val src = "//! Module-level doc.\npackage P\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "//! Module-level doc."), "format: module doc preserved")
}

test "module header nested comment preserved" {
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

test "opaque type annotation and body comment" {
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

test "interface method doc and contract preserved" {
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

test "comment inside function body" {
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

test "comment inside record body" {
  // Comments BETWEEN record fields must survive the record body walk.
  val src = "package P\nrecord Point {\n  x: Int\n  // y is the second axis\n  y: Int\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// y is the second axis"), "internal: between-field comment preserved")
  assertTrue(Str.contains(acc, "x: Int"), "internal: first field emitted")
  assertTrue(Str.contains(acc, "y: Int"), "internal: second field emitted")
}

test "comment inside union body" {
  // Comments between union cases.
  val src = "package P\nunion Color {\n  case Red\n  // primaries\n  case Green\n  case Blue\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// primaries"), "internal: between-case comment preserved")
}

test "union case field trailing comments preserved" {
  // Trailing `// note` comments on the individual fields of a multi-field
  // union case were dropped because the union-case printer rendered the
  // field list as a flat single line with no trivia awareness.  The
  // multi-line union-case layout now weaves each field's trailing comment
  // onto its own line.
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

test "union case no comments stays inline" {
  // Without interior trivia, a union case's fields stay on one line — the
  // multi-line split fires only to rescue comments.
  val src = "package P\n\nunion Pair {\n  case P(a: Int, b: Int)\n}\n"
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "case P(a: Int, b: Int)"), "union no comments: fields stay inline")
}

test "comment inside enum body" {
  // Comments between enum cases.
  val src = "package P\nenum Dir {\n  case North\n  // horizontal\n  case East\n  case West\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// horizontal"), "internal: enum between-case comment preserved")
}

test "comment inside nested block" {
  // Comments inside a nested block (if-then-block).
  val src = "package P\nfunc f(x: in Int): Unit {\n  if x > 0 {\n    // positive branch\n    val y = x\n  }\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// positive branch"), "internal: nested-block comment preserved")
}

test "blank line inside function body" {
  // Phase 5 §M5.3 stage 5: a blank line between two statements inside
  // a function body must survive `lyric fmt`.
  val src = "package P\nfunc f(): Unit {\n  val a = 1\n\n  val b = 2\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  val expected = "package P\n\nfunc f(): Unit {\n  val a = 1\n\n  val b = 2\n}\n"
  assertEqual(acc, expected, "blank: between stmts in func body")
}

test "blank line inside record body" {
  val src = "package P\nrecord Point {\n  x: Int\n\n  y: Int\n}\n"
  val pr = parse(src)
  val acc = format(pr)
  val expected = "package P\n\nrecord Point {\n  x: Int\n\n  y: Int\n}\n"
  assertEqual(acc, expected, "blank: between record fields")
}

test "blank lines between comment blocks" {
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

test "multiple blank lines collapse to one" {
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

test "trailing blank before closing brace" {
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

test "comment before contract clause" {
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

test "blank line between contract clauses" {
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

test "comment before where clause" {
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

test "comment between where and contract" {
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

test "where then contract round trips" {
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

test "width driven long call breaks" {
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

test "width driven long call idempotent" {
  // The width-driven multi-line layout must round-trip: format(format(x)) == format(x).
  val src = "package P\n" + "func go(a: in Int): Int {\n" +
    "  val r = anExtraordinarilyLongFunctionName(a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a)\n" +
    "  r\n" +
    "}\n"
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(twice, once, "width: long-call layout is idempotent")
}

test "comment inside call args" {
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

test "width driven long binop breaks" {
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

test "short expression stays inline" {
  // Negative test: a short expression must NOT be split.  Locks in
  // the budget threshold: don't over-eagerly break.
  val src = "package P\nfunc f(): Int { val x = a + b; x }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "val x = a + b\n"), "width: short expression stays inline")
  assertTrue(not Str.contains(acc, "val x = a +\n"), "width: no spurious break for short expression")
}

test "comment between binop operands" {
  // Phase 5 §M5.3 stage 10 (D-progress-146): a comment between two
  // operands of a binary op survives `lyric fmt` — the multi-line
  // EBinop layout pops trivia at the RHS's start offset.
  val src = "package P\n" + "func f(): Int {\n" + "  val x = a +\n" + "    // sum carry\n" + "    b\n" + "  x\n" + "}\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "// sum carry"), "binop: comment between operands preserved")
  assertTrue(Str.contains(acc, "a +\n    // sum carry"), "binop: comment lands between operator and RHS")
}

test "comment between list elements" {
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

test "comment before function param" {
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

test "width driven long param list" {
  // A function with so many parameters that the inline rendering
  // exceeds the 120-char budget gets a multi-line signature.
  val src = "package P\n" +
    "func longSig(aaaa: in Int, bbbb: in Int, cccc: in Int, dddd: in Int, eeee: in Int, ffff: in Int, gggg: in Int, hhhh: in Int, iiii: in Int): Int { 0 }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "func longSig(\n"), "param: signature breaks at the (")
  assertTrue(Str.contains(acc, "  aaaa: in Int,\n"), "param: first param on its own line")
}

test "out mode renders correctly" {
  // Regression test for the `PMOut` → `"acc "` rename slip from the
  // original sed-driven reserved-keyword cleanup.  An `out` parameter
  // must round-trip as `: out Type`.
  val src = "package P\nfunc set(x: out Int): Unit { }\n"
  val pr = parse(src)
  val acc = format(pr)
  assertTrue(Str.contains(acc, "x: out Int"), "param: PMOut renders as `out`, not `acc`")
}

test "comment inside lambda body" {
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

test "width driven long lambda body" {
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

test "format source facade" {
  // String-in / string-out façade — the entry point the F# CLI calls
  // through reflection in M5.3 stage 2 (CLI wiring).
  val src = "package P\n\n// keep me\nalias A = Int\n"
  val acc = formatSource(src)
  assertTrue(Str.contains(acc, "// keep me"), "formatSource: comment preserved")
  assertTrue(Str.contains(acc, "alias A = Int"), "formatSource: item rendered")
  assertTrue(isFormattedSource(acc), "formatSource: output is canonical (idempotent)")
}

test "forall body no braces" {
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

test "width driven long if breaks" {
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

test "width driven long match breaks" {
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

test "then form if arm comments preserved" {
  // A `then`-form if-expression whose then-arm and else-arm each carry an
  // end-of-line comment must keep each comment on its own output line.
  // The flat inline rendering used to fuse them
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

test "then form if arm comments in match arm" {
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

test "then form if expression arm comments preserved" {
  // Same fix for an *expression-form* arm (`case 0 -> if ... then 3 // op`):
  // the body is EOBExpr, so the trivia branch of `matchLines` must detect
  // the interior comment and route through the ctx-aware `exprAtCol`
  // instead of the flat `exprInline` that would drop it.
  val src = "package P\n\nfunc g(x: in Int): Int {\n" + "  match x {\n" + "    case 0 -> if x > 0 then 3   // op\n" +
    "    else 6\n" +
    "    case _ -> 1\n" +
    "  }\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "then-if expression arm: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "// op"), "then-if expression arm: interior comment preserved")
  assertTrue(isFormatted(acc, parse(acc)), "then-if expression arm: idempotent")
}

test "then form if no comments stays inline" {
  // Without interior trivia, a `then`-form if stays on one line — the
  // multi-line split fires only to rescue comments.
  val src = "package P\n\nfunc f(x: in Int): Int {\n  if x > 0 then 3 else 6\n}\n"
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "if x > 0 then 3 else 6"), "then-if no comments: stays inline")
  assertTrue(not Str.contains(acc, "\n  else"), "then-if no comments: no spurious else break")
}

test "then form if else chain comments preserved" {
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

test "fbexpr with contracts" {
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
test "format source checked ok" {
  val c = formatSourceChecked("package P\n\nfunc f(x: in Int): Int {\n  x\n}\n")
  assertTrue(fmtCheckIsOk(c), "checked: clean source is FmtOk")
}

test "format source checked input parse error" {
  // A `///` doc comment before `package` has no item to attach to (P0020),
  // so the input is rejected and never reformatted.
  val c = formatSourceChecked("/// orphan doc\npackage P\n")
  assertTrue(not fmtCheckIsOk(c), "checked: parse-error input is refused")
  assertTrue(Str.contains(fmtCheckMessage(c), "parse error"), "checked: input-parse message")
}

test "string escape canonicalization accepted" {
  // Canonicalising a string escape (here `\u{80}`, a C1 control rendered
  // as its literal scalar) is NOT a code-token change: the loss check
  // compares string literals by decoded value, so the round-trip is
  // accepted rather than refused.  This used to be flagged via raw-spelling
  // comparison — closing that gap was part of #2452.
  val c = formatSourceChecked("package P\n\nfunc f(): Unit {\n  val s = \"a\\u{80}b\"\n}\n")
  assertTrue(fmtCheckIsOk(c), "checked: string-escape canonicalisation accepted")
}

test "structural diff identifier change" {
  // A genuine code-token change (one identifier respelled) is what backs
  // the FmtStructureChanged refusal: the first divergence is reported with
  // its 1-based token index and both spellings.
  val d = structuralSequenceDiff(
    "package P\n\nfunc f(): Int {\n  alpha\n}\n",
    "package P\n\nfunc f(): Int {\n  beta\n}\n"
  )
  assertEqual(d, "token 10 changed: `alpha` -> `beta`", "structural diff: identifier change reported")
}

test "structural diff token count change" {
  // When one token sequence is a strict prefix of the other, the
  // divergence is the length itself, reported as a count change.
  val d = structuralSequenceDiff("package P\n", "package P\n\nfunc f(): Int {\n  1\n}\n")
  assertEqual(d, "token count changed: 2 -> 11", "structural diff: count change reported")
}

test "structural diff string respelling accepted" {
  // String literals compare by decoded value, so an escape respelling
  // (`"\u{41}"` vs `"A"`) is not a structural change.
  val d = structuralSequenceDiff(
    "package P\n\nfunc f(): String {\n  \"\\u{41}\"\n}\n",
    "package P\n\nfunc f(): String {\n  \"A\"\n}\n"
  )
  assertEqual(d, "", "structural diff: same-value string respelling is no diff")
}

test "extern package round trips" {
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

test "extern package member kinds round trip" {
  // Each ExternMember branch in `externMemberLines` must round-trip through
  // `formatSourceChecked`.  These cover the branches not exercised by the
  // `pub func` / `pub exposed type` test above (#2348).
  //
  // `record` member — EMRecord (fields rendered as a block).
  val recSrc = "package P\n\nextern package Host.X {\n  pub record Point {\n    x: Int\n    y: Int\n  }\n}\n"
  val recC = formatSourceChecked(recSrc)
  assertTrue(fmtCheckIsOk(recC), "extern record: round-trips")
  val recAcc = format(parse(recSrc))
  assertTrue(Str.contains(recAcc, "pub record Point"), "extern record: member kind preserved")

  // `union` member — EMUnion.
  val unionSrc = "package P\n\nextern package Host.X {\n  pub union Status {\n    case Active\n    case Inactive\n  }\n}\n"
  val unionC = formatSourceChecked(unionSrc)
  assertTrue(fmtCheckIsOk(unionC), "extern union: round-trips")
  val unionAcc = format(parse(unionSrc))
  assertTrue(Str.contains(unionAcc, "pub union Status"), "extern union: member kind preserved")

  // `enum` member — EMEnum.
  val enumSrc = "package P\n\nextern package Host.X {\n  pub enum Color {\n    case Red\n    case Green\n    case Blue\n  }\n}\n"
  val enumC = formatSourceChecked(enumSrc)
  assertTrue(fmtCheckIsOk(enumC), "extern enum: round-trips")
  val enumAcc = format(parse(enumSrc))
  assertTrue(Str.contains(enumAcc, "pub enum Color"), "extern enum: member kind preserved")

  // bare `opaque type` — EMOpaque without the `exposed` tag.
  val opaqueSrc = "package P\n\nextern package Host.X {\n  pub opaque type Conn\n}\n"
  val opaqueC = formatSourceChecked(opaqueSrc)
  assertTrue(fmtCheckIsOk(opaqueC), "extern opaque: round-trips")
  val opaqueAcc = format(parse(opaqueSrc))
  assertTrue(Str.contains(opaqueAcc, "pub opaque type Conn"), "extern opaque: member kind preserved")

  // `alias` member — EMTypeAlias.
  val aliasSrc = "package P\n\nextern package Host.X {\n  pub alias Name = String\n}\n"
  val aliasC = formatSourceChecked(aliasSrc)
  assertTrue(fmtCheckIsOk(aliasC), "extern alias: round-trips")
  val aliasAcc = format(parse(aliasSrc))
  assertTrue(Str.contains(aliasAcc, "pub alias Name = String"), "extern alias: member kind preserved")

  // `distinct type` member — EMDistinctType.
  val distinctSrc = "package P\n\nextern package Host.X {\n  pub type Id = Int\n}\n"
  val distinctC = formatSourceChecked(distinctSrc)
  assertTrue(fmtCheckIsOk(distinctC), "extern distinct: round-trips")
  val distinctAcc = format(parse(distinctSrc))
  assertTrue(Str.contains(distinctAcc, "pub type Id = Int"), "extern distinct: member kind preserved")
}

test "return try round trips" {
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

test "match arm bare return round trips" {
  // A bare `case P -> return e` arm body is also a parser-synthesised
  // single-statement block; it must render without injected braces.
  val src = "package P\n\nfunc f(o: in Option[Int]): Int {\n  match o {\n    case Some(e) -> return e\n    case None -> 0\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "match-arm bare return: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "case Some(e) -> return e"), "match-arm bare return: stays bare")
}

test "match arm explicit brace preserved" {
  // When the author *did* write braces around a single `return`, the span
  // check distinguishes them from the bare form so they are preserved
  // (no token change) rather than unwrapped.
  val src = "package P\n\nfunc f(o: in Option[Int]): Int {\n  match o {\n    case Some(e) -> { return e }\n    case None -> 0\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "match-arm explicit braces: round-trips")
  val acc = format(parse(src))
  // The formatter may expand the brace body to multi-line, but the braces
  // and the `return e` statement must both be present (not unwrapped to bare
  // `case Some(e) -> return e`).
  assertTrue(Str.contains(acc, "return e"), "match-arm explicit braces: return preserved in output")
  assertTrue(not Str.contains(acc, "-> return e"), "match-arm explicit braces: braces not stripped")
}

test "match arm throw round trips" {
  // `case P -> throw E` is a single-statement block whose statement is
  // SThrow; the formatter's isKeywordExprStmt path must emit it bare.
  val src = "package P\n\nfunc f(o: in Option[Int]): Int {\n  match o {\n    case None -> throw RuntimeError(\"missing\")\n    case Some(v) -> v\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "match-arm throw: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "case None -> throw RuntimeError"), "match-arm throw: bare throw preserved")
}

test "match arm break round trips" {
  // `case P -> break` inside a while loop's match arm is a single-statement
  // block whose statement is SBreak; the formatter must render it bare.
  // The other arm uses a braced block (assignment needs braces in match arms).
  val src = "package P\n\nfunc f(xs: in List[Int]): Int {\n  var i = 0\n  while i < xs.count {\n    match xs[i] {\n      case 0 -> break\n      case _ -> {\n        i = i + 1\n      }\n    }\n  }\n  i\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "match-arm break: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "case 0 -> break"), "match-arm break: bare break preserved")
}

test "match arm continue round trips" {
  // `case P -> continue` inside a while loop is a single-statement SContinue
  // block; the formatter must render it bare.
  // The other arm uses a braced block (assignment needs braces in match arms).
  val src = "package P\n\nfunc f(xs: in List[Int]): Int {\n  var sum = 0\n  var i = 0\n  while i < xs.count {\n    i = i + 1\n    match xs[i - 1] {\n      case 0 -> continue\n      case v -> {\n        sum = sum + v\n      }\n    }\n  }\n  sum\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "match-arm continue: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "case 0 -> continue"), "match-arm continue: bare continue preserved")
}

test "module header auto fix" {
  // A plain `//` header block before `package` is promoted to `//!`.
  val acc = format(parse("// my module\n// second line\npackage P\n"))
  assertTrue(Str.contains(acc, "//! my module"), "auto-fix: // header -> //!")
  assertTrue(Str.contains(acc, "//! second line"), "auto-fix: multi-line header")
  assertTrue(not Str.contains(acc, "// my module"), "auto-fix: old // form gone")
}

test "field doc comment preserved" {
  // A `///` doc comment on a record field survives formatting (the field
  // printer historically dropped it).
  val acc = format(parse("package P\n\nrecord R {\n  /// the x coordinate\n  x: Int\n}\n"))
  assertTrue(Str.contains(acc, "/// the x coordinate"), "field doc: comment preserved")
  assertTrue(Str.contains(acc, "x: Int"), "field doc: field preserved")
}

test "field annotations stay with their field" {
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

test "char literal rendering" {
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

test "unicode escape in string round trips" {
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

test "non bmp escape literal round trips" {
  // A printable non-ASCII scalar (here U+00E9 'é', written `\u{00E9}`)
  // is canonicalised to its literal character, but because the loss
  // check now compares string tokens by decoded value the round-trip is
  // accepted rather than flagged as a code-token change (#2452).
  val src = "package P\n\nfunc f(): String {\n  \"\\u{00E9}\"\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "non-control escape: round-trips losslessly")
}

test "literal dollar brace round trips" {
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

test "interpolated string round trips" {
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

test "while loop invariant round trips" {
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

test "for loop invariant round trips" {
  val src = "package P\n\nfunc f(xs: in List[Int]): Int {\n  var s = 0\n  for x in xs\n    invariant: s >= 0\n  {\n    s = s + x\n  }\n  s\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "for invariant: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "invariant: s >= 0"), "for invariant: clause preserved")
}

test "aspect around ret name round trips" {
  // The `around(args) -> ret { … }` return binder must survive: the
  // parser built it via an `if … { Some(x) } else { None }` value that
  // the stage-0 emitter mis-lowered to `None`, dropping `-> ret` (#2452).
  val src = "package P\n\npub aspect X {\n  around(call) -> ret {\n    ret = call.proceed()\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "aspect around: retName round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "around(call) -> ret {"), "aspect around: `-> ret` preserved")
}

test "aspect config block round trips" {
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

// docs/56 / D115 — `where TArgs has { field: Type, ... }` row clause on the
// `around` advice must round-trip losslessly.
test "aspect args row clause round trips" {
  val src = "package P\n\npub aspect ValidateKey {\n" +
    "  around(call) -> ret where TArgs has { apiKey: String, retries: Int } {\n" +
    "    ret = call.proceed()\n" +
    "  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "aspect args row: round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "around(call) -> ret where TArgs has { apiKey: String, retries: Int } {"),
    "aspect args row: clause preserved"
  )
}

test "aspect from clause round trips" {
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

test "aspect matches name in round trips" {
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

test "aspect matches name in and except round trips" {
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

test "aspect config before matches preserves source order" {
  // #3584: when the author writes `config { }` before `matches:`, the
  // formatter must preserve that order rather than reordering to the
  // docs/26 §8 canonical `matches:`-then-`config` layout — reordering
  // changes the token sequence and trips the loss-check refusal.
  // `aspectDoc` detects this via `aspectMatcherSpanOffset` comparing the
  // first config field's span to the first matcher's span (#3633).
  val src = "package P\n\naspect Tap {\n  config {\n    timeoutMs: Int = 5000\n  }\n  matches: name like \"run*\"\n  around(call) -> ret {\n    ret = call.proceed()\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "aspect config-before-matches: round-trips")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "aspect config-before-matches: idempotent")
  val cfgIdx = match Str.indexOf(once, "config {") { case Some(i) -> i; case None -> -1 }
  val matchIdx = match Str.indexOf(once, "matches:") { case Some(i) -> i; case None -> -1 }
  assertTrue(cfgIdx >= 0 and matchIdx >= 0, "aspect config-before-matches: both clauses emitted")
  assertTrue(cfgIdx < matchIdx, "aspect config-before-matches: config block precedes matches in output")
}

test "nested match trailing comment idempotent" {
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

test "aspect inter member blank idempotent" {
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

test "protected inter member blank idempotent" {
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

test "config block free comment round trips" {
  // A free `//` comment sitting between config fields must survive a fmt
  // round-trip and be idempotent (#2513).
  val src = "package P\n\nconfig Settings {\n  // which env var feeds this\n  enabled: Bool = true\n  threshold: Int = 10\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "config free comment: round-trips")
  val once = format(parse(src))
  assertTrue(Str.contains(once, "// which env var feeds this"), "config free comment: preserved")
  val twice = format(parse(once))
  assertEqual(once, twice, "config free comment: idempotent")
}

test "config block trailing comment round trips" {
  // A trailing `//` comment on a config field line must survive a fmt
  // round-trip and be idempotent (#2513).
  val src = "package P\n\nconfig Settings {\n  enabled: Bool = true\n  threshold: Int = 10  // tuning knob\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "config trailing comment: round-trips")
  val once = format(parse(src))
  assertTrue(Str.contains(once, "// tuning knob"), "config trailing comment: preserved")
  val twice = format(parse(once))
  assertEqual(once, twice, "config trailing comment: idempotent")
}

test "aspect config block free comment round trips" {
  // A free `//` comment between aspect config fields must survive a fmt
  // round-trip and be idempotent (#2513).
  val src = "package P\n\naspect X {\n  config {\n    // which env var feeds this\n    enabled: Bool = true\n  }\n\n  around(call) -> ret {\n    ret = call.proceed()\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "aspect config free comment: round-trips")
  val once = format(parse(src))
  assertTrue(Str.contains(once, "// which env var feeds this"), "aspect config free comment: preserved")
  val twice = format(parse(once))
  assertEqual(once, twice, "aspect config free comment: idempotent")
}

test "aspect config block trailing comment round trips" {
  // A trailing `//` comment on an aspect config field must survive a fmt
  // round-trip and be idempotent (#2513).
  val src = "package P\n\naspect X {\n  config {\n    enabled: Bool = true  // toggle\n  }\n\n  around(call) -> ret {\n    ret = call.proceed()\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "aspect config trailing comment: round-trips")
  val once = format(parse(src))
  assertTrue(Str.contains(once, "// toggle"), "aspect config trailing comment: preserved")
  val twice = format(parse(once))
  assertEqual(once, twice, "aspect config trailing comment: idempotent")
}

test "multi segment leading trivia round trips" {
  // #2435: `appendTriviaInto` accumulates whitespace across multiple trivia
  // segments (blank lines + comments) between items.  A blank line followed by
  // a doc-less `//` comment before an item must round-trip and be idempotent.
  val src = "package P\n\nfunc a(): Int {\n  1\n}\n\n// a free comment\n\nfunc b(): Int {\n  2\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "multi-segment trivia: round-trips")
  val once = format(parse(src))
  assertTrue(Str.contains(once, "// a free comment"), "multi-segment trivia: comment preserved")
  val twice = format(parse(once))
  assertEqual(once, twice, "multi-segment trivia: idempotent")
}

test "match expression arm round trips" {
  // #2470: `matchLines` formats an expression-position arm body via
  // `exprAtCol`; the `bd.count > 0` guard prevents an out-of-bounds read when
  // the formatted arm doc is empty.  A simple expression-arm match must
  // round-trip and be idempotent.
  val src = "package P\n\nfunc f(o: in Option[Int]): Int {\n  match o {\n    case Some(x) -> x\n    case None -> 0\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "match expression arm: round-trips")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "match expression arm: idempotent")
}

test "zero arg closure arrow preserved" {
  // A zero-argument closure `{ -> expr }` must keep its `->` arrow on a
  // format round-trip.  Both `lambdaInlineStr` (inline) and `exprLambdaMulti`
  // (multi-line) dropped the arrow before the #3272 fix, producing a bare
  // `{ expr }` that the parser reads as a block expression rather than a
  // closure — breaking the structural diff loss-check.
  val inlineSrc = "package P\n\nfunc f(): Int {\n  val cb = { -> 42 }\n  cb()\n}\n"
  val c = formatSourceChecked(inlineSrc)
  assertTrue(fmtCheckIsOk(c), "zero-arg closure inline: round-trips losslessly")
  val acc = format(parse(inlineSrc))
  assertTrue(Str.contains(acc, "{ -> 42 }"), "zero-arg closure inline: arrow preserved")
  assertTrue(not Str.contains(acc, "{ 42 }"), "zero-arg closure inline: not rendered as bare block")
  assertTrue(isFormatted(acc, parse(acc)), "zero-arg closure inline: idempotent")

  // Multi-line form: a comment inside the body forces `exprLambdaMulti`.
  val multiSrc = "package P\n\nfunc g(): Int {\n  val cb = { ->\n    // compute\n    42\n  }\n  cb()\n}\n"
  val mc = formatSourceChecked(multiSrc)
  assertTrue(fmtCheckIsOk(mc), "zero-arg closure multi: round-trips losslessly")
  val macc = format(parse(multiSrc))
  assertTrue(Str.contains(macc, "{ ->\n"), "zero-arg closure multi: arrow on opening line")
  assertTrue(not Str.contains(macc, "{\n    // compute"), "zero-arg closure multi: not bare block")
  assertTrue(isFormatted(macc, parse(macc)), "zero-arg closure multi: idempotent")
}

test "extern func declaration round trips" {
  // `extern func ... = "symbol"` (D-N-007) renders as a single line and
  // must round-trip losslessly, including NativePtr[T] parameter types
  // and the C-symbol string.
  val src = "package Std.ProbeHost\n\nextern func write(fd: Int, buf: NativePtr[Byte], n: Long): Long = \"write\"\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "extern func: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "extern func write(fd: Int, buf: NativePtr[Byte], n: Long): Long = \"write\""),
    "extern func: signature and symbol preserved"
  )
  assertTrue(isFormatted(acc, parse(acc)), "extern func: idempotent")
}

test "extern func without return type round trips" {
  // A Unit-returning extern func omits the `: Ret` clause; the formatter
  // must not synthesise one (loss-check parses both forms distinctly).
  val src = "package Std.ProbeHost\n\nextern func free(ptr: NativePtr[Byte]) = \"free\"\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "extern func no-ret: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "extern func free(ptr: NativePtr[Byte]) = \"free\""), "extern func no-ret: preserved")
  assertTrue(not Str.contains(acc, "free(ptr: NativePtr[Byte]):"), "extern func no-ret: no synthesised return type")
  assertTrue(isFormatted(acc, parse(acc)), "extern func no-ret: idempotent")
}

test "extern type quoted form round trips" {
  val src = "package Std.ProbeHost\n\nextern type Enc = \"System.Text.Encoding\"\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "extern type quoted: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "extern type Enc = \"System.Text.Encoding\""), "extern type quoted: form preserved")
  assertTrue(isFormatted(acc, parse(acc)), "extern type quoted: idempotent")
}

// #5472: the formatter always canonicalized `extern type` to the quoted
// string form, so a source using the unquoted dotted-path form (docs/47)
// failed `fmt --write`'s loss-check (a bare identifier path and a string
// literal are different token sequences) and left the file unformatted.
test "extern type unquoted dotted-path form round trips" {
  val src = "package Std.ProbeHost\n\nextern type Enc = System.Text.Encoding\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "extern type unquoted: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "extern type Enc = System.Text.Encoding"), "extern type unquoted: form preserved")
  assertTrue(not Str.contains(acc, "\"System.Text.Encoding\""), "extern type unquoted: not silently re-quoted")
  assertTrue(isFormatted(acc, parse(acc)), "extern type unquoted: idempotent")
}

// The unquoted form combined with generics: the parser appends a
// compiler-derived `` `N `` arity suffix to `clrName` for codegen (never
// present in the unquoted source, since a bare dotted path cannot contain
// a backtick), which the formatter must strip back off when re-rendering
// the unquoted form rather than emitting the internal suffix verbatim.
test "extern type unquoted generic form strips the derived arity suffix" {
  val src = "package Std.ProbeHost\n\nextern type CD[K, V] = System.Collections.Concurrent.ConcurrentDictionary\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "extern type unquoted generic: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "extern type CD[K, V] = System.Collections.Concurrent.ConcurrentDictionary\n"),
    "extern type unquoted generic: arity suffix not rendered"
  )
  assertTrue(isFormatted(acc, parse(acc)), "extern type unquoted generic: idempotent")
}

// #5476: the quoted form combined with generics has the same class of bug
// as #5472's unquoted case. `parseExternTypeBody` appends the same
// compiler-derived `` `N `` arity suffix to `clrName` whenever the quoted
// string literal doesn't already contain a backtick, so the formatter's
// quoted branch must strip it back off too rather than re-quoting the
// internal suffix verbatim (which produced a different string literal
// than the source and tripped the loss-checker).
test "extern type quoted generic form strips the derived arity suffix" {
  val src = "package Std.ProbeHost\n\nextern type CD[K, V] = \"Some.Generic.Type\"\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "extern type quoted generic: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "extern type CD[K, V] = \"Some.Generic.Type\"\n"),
    "extern type quoted generic: arity suffix not rendered"
  )
  assertTrue(isFormatted(acc, parse(acc)), "extern type quoted generic: idempotent")
}

// A quoted `clrName` may legitimately contain a user-authored backtick
// (unlike the unquoted dotted-path form, which cannot lexically contain
// one) — e.g. spelling out the .NET generic-arity suffix explicitly. That
// case must round-trip untouched: the formatter must not treat a
// user-typed backtick as the compiler-derived suffix and strip it.
test "extern type quoted generic form with explicit backtick round trips" {
  val src = "package Std.ProbeHost\n\nextern type CD[K, V] = \"Some.Generic.Type`2\"\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "extern type quoted generic explicit backtick: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "extern type CD[K, V] = \"Some.Generic.Type`2\"\n"),
    "extern type quoted generic explicit backtick: explicit suffix preserved"
  )
  assertTrue(isFormatted(acc, parse(acc)), "extern type quoted generic explicit backtick: idempotent")
}

test "val binding named result round trips" {
  // #4778: a `val` binding named `result` (a valid binding name outside
  // `ensures:` position) was formatted with its name dropped, producing
  // `val  = 1` and tripping the loss-checker's refusal.
  val src = "package T\n\nfunc main(): Unit {\n  val result = 1\n  val x = result + 1\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "val result: round-trips losslessly")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "val result = 1"), "val result: binding name preserved")
  assertTrue(isFormatted(acc, parse(acc)), "val result: idempotent")
}

// ─────────────────────────────────────────────────────────────────────────────
// docs/58 (D121) — wire templates, contributes[T], include, config `from`.
// ─────────────────────────────────────────────────────────────────────────────
test "config from clause round trips" {
  val src = "package P\n\nconfig Assets from Web.StaticFiles {\n  root: String = \"./www\"\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "config-from: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "config Assets from Web.StaticFiles {"), "config-from: header preserved")
}

test "contributes entries with ordering clauses round trip" {
  val src = "package P\n\nwire W {\n" + "  contributes[Mw] cors = make()\n" + "  sealed contributes[Mw] auth = make()\n" +
    "    inside: cors\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "contributes: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "contributes[Mw] cors = make()"), "contributes: plain entry preserved")
  assertTrue(Str.contains(acc, "sealed contributes[Mw] auth = make()"), "contributes: sealed entry preserved")
  assertTrue(Str.contains(acc, "inside: cors"), "contributes: ordering clause preserved")
}

test "include with alias and adjustments round trips" {
  val src = "package P\n\nwire W {\n" + "  include Web.ServerModule as Core {\n" + "    @provided config: appCfg\n" +
    "    Files {\n      root = \"./x\"\n    }\n" +
    "    cors = custom()\n" +
    "    remove logging\n" +
    "    reorder cors wraps: auth\n" +
    "  }\n" +
    "  expose router\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "include: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "include Web.ServerModule as Core {"), "include: header preserved")
  assertTrue(Str.contains(acc, "@provided config: appCfg"), "include: provided mapping preserved")
  assertTrue(Str.contains(acc, "remove logging"), "include: remove preserved")
  assertTrue(Str.contains(acc, "reorder cors wraps: auth"), "include: reorder preserved")
}

test "bare include and empty include body round trip" {
  val src = "package P\n\nwire W {\n  include Web.A\n  include Web.B {\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "bare/empty include: round-trips")
}

test "pub wire template with overridable and wire-body config round trips" {
  val src = "package P\n\npub wire T {\n" + "  @provided cfg: AppConfig\n" +
    "  config Files from Web.StaticFiles {\n    root: String = \"./m\"\n  }\n" +
    "  singleton router: Router = make(Files)\n" +
    "  expose router\n" +
    "  overridable Files, router\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "pub wire template: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "pub wire T {"), "pub wire: visibility preserved")
  assertTrue(Str.contains(acc, "config Files from Web.StaticFiles {"), "pub wire: config-inst preserved")
  assertTrue(Str.contains(acc, "overridable Files, router"), "pub wire: overridable preserved")
}

// #5574 repro: a `///` doc comment before a non-first entry member in a
// protected type body used to cascade the parser into P0201/P0075/P0202,
// which made `formatSourceChecked` fail (its own re-parse of the input
// hit the same cascade) before the fix landed.
test "protected type doc before second entry round trips (#5574)" {
  val src = "package P\n\nprotected type Buf {\n" + "  var n: Int\n\n" +
    "  /// works fine here (first member position is OK)\n" +
    "  entry push(): Unit {\n    n = n + 1\n  }\n\n" +
    "  /// this one used to break the parse\n" +
    "  entry count(): Int {\n    n\n  }\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "protected type doc-before-2nd-entry: round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "/// works fine here (first member position is OK)"),
    "protected type: first doc preserved"
  )
  assertTrue(Str.contains(acc, "/// this one used to break the parse"), "protected type: second doc preserved")
  assertTrue(Str.contains(acc, "entry count(): Int"), "protected type: second entry preserved")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "protected type doc-before-2nd-entry: idempotent")
}

// #5815 repro: a leading `@annotation` before a protected-type member had
// the same dispatch-blinding gap `///` doc comments did before #5574.
// Beyond the parser fix, `PFVar`/`PFLet` gained a new `annotations` field
// that `lyric/fmt/fmt_items.l` must render back out (otherwise
// `formatSourceChecked`'s own re-parse loses the annotation and the
// loss-check refuses to write) — this exercises both an annotated var
// field and an annotated entry in the same protected type.
test "protected type annotated entry and var field round trip (#5815)" {
  val src = "package P\n\nprotected type Buf {\n" + "  @something\n" + "  var total: Int = 0\n\n" + "  var n: Int\n\n" +
    "  @somethingElse\n" +
    "  entry count(): Int {\n    n\n  }\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "protected type annotated members: round-trips")
  val acc = format(parse(src))
  // Adjacency assertions (#5840): a bare contains("@something") is also
  // satisfied by "@somethingElse", and neither would catch an annotation
  // rendered against the wrong member — assert each annotation sits on
  // its own line directly above the member it belongs to.
  assertTrue(
    Str.contains(acc, "@something\n  var total: Int = 0"),
    "protected type: field annotation on its own line above the var field"
  )
  assertTrue(
    Str.contains(acc, "@somethingElse\n  entry count(): Int"),
    "protected type: entry annotation on its own line above the entry"
  )
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "protected type annotated members: idempotent")
}

// ─────────────────────────────────────────────────────────────────────────────
// #2280 Class B: width-aware match-arm expression bodies.
//
// `matchLines`'s `EOBExpr` arm-body branch (fmt/fmt_core.l) used to decide
// between the flat single-line rendering and the ctx-aware `exprAtCol`
// multi-line printer purely on whether the body's source span contained a
// comment — never on whether the rendering actually fit the 120-column
// budget.  A nested `match`/`if` arm body with no interior comment was
// therefore always flattened onto one line via `exprInline`, no matter how
// long the result.  The fix folds the width check into the same
// `exprFitsInline` helper the rest of the width-driven printer family
// already uses, so an overflowing body falls back to its own recursive
// multi-line layout instead of being collapsed.
// ─────────────────────────────────────────────────────────────────────────────
test "width driven nested match arm breaks (#2280 Class B repro)" {
  // The exact repro from the umbrella issue: an outer match arm whose body
  // is itself a match, with no comments anywhere, previously collapsed to
  // a single ~191-column line.
  val src = "package P\n\nfunc parseDbValueLong(elem: in Int): Int {\n" +
    "  match tryGetIntegerValueFromElement(elem) {\n" +
    "    case Some(intermediateResultValue) -> intermediateResultValue\n" +
    "    case None ->\n" +
    "      match tryGetLongIntegerValueFromElement(elem) {\n" +
    "        case Some(longIntermediateResultValue) -> longIntermediateResultValue\n" +
    "        case None -> computeDefaultFallbackIntegerValue(elem)\n" +
    "      }\n" +
    "  }\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "nested-match width: round-trips losslessly")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "nested-match width: idempotent")
  // The outer arm's body must NOT be flattened onto the "case None ->"
  // line: the nested match's head still attaches to the arrow (matching
  // the existing if-expression convention), but its arms and closing
  // brace break onto their own lines instead of being crammed in too.
  assertTrue(
    Str.contains(once, "case None -> match tryGetLongIntegerValueFromElement(elem) {\n"),
    "nested-match width: nested match opens its own brace layout right after the arrow"
  )
  assertTrue(
    Str.contains(once, "case Some(longIntermediateResultValue) -> longIntermediateResultValue\n"),
    "nested-match width: nested arm rendered on its own line"
  )
  assertTrue(
    Str.contains(once, "case None -> computeDefaultFallbackIntegerValue(elem)\n"),
    "nested-match width: nested fallback arm rendered on its own line"
  )
  val lines = Str.split(once, "\n")
  var i = 0
  while i < lines.count {
    assertTrue(lines[i].length <= 120, "nested-match width: no output line exceeds the 120-column budget")
    i = i + 1
  }
}

test "width driven doubly nested match breaks at every level" {
  // Three levels deep: an outer match arm's body is a match whose OWN arm
  // body is yet another (long) match.  Every level must independently
  // width-check and break — the recursion runs through `exprAtCol` calling
  // back into `matchLines` at each level, so a fix scoped to only the
  // outermost call would leave the innermost still flattened.
  val src = "package P\n\nfunc resolveDeep(a: in Int, b: in Int, c: in Int): Int {\n" + "  match lookupOuter(a) {\n" +
    "    case None -> -1\n" +
    "    case Some(_) ->\n" +
    "      match lookupMiddle(b) {\n" +
    "        case None -> -2\n" +
    "        case Some(_) ->\n" +
    "          match lookupInnerLongEnoughToOverflowOnItsOwnLine(c) {\n" +
    "            case Some(deeplyNestedInnerResultValue) -> deeplyNestedInnerResultValue\n" +
    "            case None -> computeDeeplyNestedFallbackValueForTheInnermostMatch(c)\n" +
    "          }\n" +
    "      }\n" +
    "  }\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "doubly-nested match width: round-trips losslessly")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "doubly-nested match width: idempotent")
  assertTrue(
    Str.contains(once, "match lookupInnerLongEnoughToOverflowOnItsOwnLine(c) {\n"),
    "doubly-nested match width: innermost match opens its own brace layout"
  )
  assertTrue(
    Str.contains(once, "case Some(deeplyNestedInnerResultValue) -> deeplyNestedInnerResultValue\n"),
    "doubly-nested match width: innermost arm rendered on its own line"
  )
  val lines = Str.split(once, "\n")
  var i = 0
  while i < lines.count {
    assertTrue(lines[i].length <= 120, "doubly-nested match width: no output line exceeds the 120-column budget")
    i = i + 1
  }
}

test "width driven if-else match-arm body breaks" {
  // `matchLines`'s `EOBExpr` branch is shared by every expression-kind arm
  // body, not just nested matches: a brace-form `if/else` arm body that
  // overflows must also fall back to its recursive multi-line layout
  // (`ifBlockLines`) instead of being flattened.
  val src = "package P\n\nfunc classify(value: in Int): String {\n" + "  match Some(value) {\n" +
    "    case Some(v) -> if aVeryLongConditionThatWillForceThisIfElseArmBodyToOverflowTheLineWidthBudget(v) {\n" +
    "      \"first-result-value\"\n" +
    "    } else {\n" +
    "      \"second-result-value\"\n" +
    "    }\n" +
    "    case None -> \"none\"\n" +
    "  }\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "if-else match-arm body width: round-trips losslessly")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "if-else match-arm body width: idempotent")
  assertTrue(
    Str.contains(once, "aVeryLongConditionThatWillForceThisIfElseArmBodyToOverflowTheLineWidthBudget(v) {\n"),
    "if-else match-arm body width: if-condition opens its own brace layout"
  )
  assertTrue(Str.contains(once, "} else {\n"), "if-else match-arm body width: else clause on its own line")
  val lines = Str.split(once, "\n")
  var i = 0
  while i < lines.count {
    assertTrue(lines[i].length <= 120, "if-else match-arm body width: no output line exceeds the 120-column budget")
    i = i + 1
  }
}

test "width driven multi-arm match stays one-arm-per-line without over-splitting" {
  // Four arms, each individually short, whose combined single-line
  // rendering overflows — the OUTER match must go multi-line (as it
  // already did before this fix), but each individual arm body must stay
  // on its own single line rather than being needlessly broken down
  // further.
  val src = "package P\n\nfunc describe(code: in Int): String {\n" +
    "  match classifyErrorCodeWithAVeryDescriptiveNameThatIsQuiteLong(code) {\n" +
    "    case 1 -> \"one\"\n" +
    "    case 2 -> \"two\"\n" +
    "    case 3 -> \"three\"\n" +
    "    case _ -> \"other\"\n" +
    "  }\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "multi-arm match width: round-trips losslessly")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "multi-arm match width: idempotent")
  assertTrue(Str.contains(once, "case 1 -> \"one\"\n"), "multi-arm match width: arm 1 stays on one line")
  assertTrue(Str.contains(once, "case 2 -> \"two\"\n"), "multi-arm match width: arm 2 stays on one line")
  assertTrue(Str.contains(once, "case 3 -> \"three\"\n"), "multi-arm match width: arm 3 stays on one line")
  assertTrue(Str.contains(once, "case _ -> \"other\"\n"), "multi-arm match width: arm 4 stays on one line")
}

test "short nested match arm body stays inline (no over-splitting)" {
  // A match arm whose body is itself a match must stay on one line when
  // the whole thing comfortably fits the width budget — the fix must not
  // force every nested match onto multiple lines regardless of length.
  val src = "package P\n\nfunc pick(o: in Option[Int], x: in Int): Int {\n" + "  match o {\n" +
    "    case None -> match x { case 0 -> 1; case _ -> 2 }\n" +
    "    case Some(v) -> v\n" +
    "  }\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "short nested match: round-trips losslessly")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "short nested match: idempotent")
  assertTrue(
    Str.contains(once, "case None -> match x { case 0 -> 1; case _ -> 2 }\n"),
    "short nested match: stays inline on a single line"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// #6606: `matchLines`'s width check threads the real absolute column.
//
// The #2280 Class B fix above folded a width check into `matchLines`'s
// `EOBExpr` arm-body branch, but computed it in a *relative* coordinate
// space starting at column 0 (`exprFitsInline(arrow.length, ...)`) — it was
// never given a base `col`, so the check never accounted for the arm's own
// indentation (the enclosing match's column, its arm indent, and any outer
// arrow prefix). A body whose `arrow.length + inlineBody.length` undercounted
// to <= 120 from column 0 could still overflow once real indentation applied,
// exactly the class of bug #2280 exists to eliminate — just one level less
// severe.  `matchLines` now takes a `col` parameter (threaded the same way
// `exprCallMulti`/`bareExprDoc` thread theirs) and checks width at
// `armCol + arrow.length`, where `armCol = col + 2` mirrors the arm's own
// `indentDoc(2, armLines)`.
// ─────────────────────────────────────────────────────────────────────────────
test "width driven nested match arm threads the real absolute column (#6606 repro)" {
  // The inner arm's body is a 96-char call name; its inline rendering
  // (`name(v)`) is 99 chars. The inner arrow ("case Some(v) -> ") is 16
  // chars, so the PRE-FIX relative check (`arrow.length + inlineBody.length`)
  // computes 16 + 99 = 115 <= 120 — it would have wrongly kept this arm on
  // one line, producing a real ~121-column line once the arm's actual
  // indentation (two match levels plus the outer arrow) is accounted for.
  // With `col` threaded through, `matchLines` now measures against the
  // arm's real column instead, so the call correctly opens its own
  // multi-line layout — and every resulting line, including the call's own
  // opening line, still fits the 120-column budget.
  val longName = "computeIntermediateResultValueFromMatchedOptionForTheInnerNestedMatchArmBodyExtraExtraExtraExtra"
  assertEqualInt(longName.length, 96, "repro setup: inner call name is exactly 96 chars")
  val inlineBody = longName + "(v)"
  assertEqualInt(inlineBody.length, 99, "repro setup: inner call inline rendering is exactly 99 chars")
  val innerArrow = "case Some(v) -> "
  assertEqualInt(innerArrow.length, 16, "repro setup: inner arrow is exactly 16 chars")
  assertTrue(
    innerArrow.length + inlineBody.length <= 120,
    "repro setup: pre-fix relative check (arrow.length + inlineBody.length) undercounts to <= 120"
  )
  val src = "package P\n\nfunc classifyNested(x: in Int): Int {\n" + "  match x {\n" + "    case 0 -> 0\n" +
    "    case _ ->\n" +
    "      match lookupOptionalValueForNestedWidthBoundaryCase(x) {\n" +
    "        case Some(v) -> " +
    inlineBody +
    "\n" +
    "        case None -> 0\n" +
    "      }\n" +
    "  }\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "nested-column boundary: round-trips losslessly")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "nested-column boundary: idempotent")
  // The inner arm's call body must NOT be flattened onto the
  // "case Some(v) -> " line: it must open its own multi-line call layout.
  assertTrue(
    not Str.contains(once, innerArrow + inlineBody),
    "nested-column boundary: inner arm no longer collapses onto one over-budget line"
  )
  assertTrue(
    Str.contains(once, innerArrow + longName + "(\n"),
    "nested-column boundary: inner arm call opens its own multi-line layout"
  )
  val lines = Str.split(once, "\n")
  var i = 0
  while i < lines.count {
    assertTrue(lines[i].length <= 120, "nested-column boundary: no output line exceeds the 120-column budget")
    i = i + 1
  }
}

// #2280 item 4 repro: `genParamsStr` normalized every `generics` field to
// the bare-bracket-after-name form (`func foo[T](...)`) regardless of
// which spelling the source actually used, so a function declared with
// the legacy `generic[T] func foo(...)` prefix (grammar §5.1: "Both
// forms are accepted") silently lost its `generic` keyword and bracket
// list on reformat — caught by the loss-check (`formatSourceChecked`
// refused to write), but never actually fixed until now.
// `GenericParams.legacyPrefixForm` (set by `parseGenericParamsOpt`) lets
// the formatter reproduce whichever spelling was used instead of
// normalizing it away.
test "legacy 'generic[T] func' prefix form round trips instead of being silently dropped (#2280 item 4)" {
  val src = "package P\n\ngeneric[T] func identity(x: T): T {\n  x\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "legacy generic[T] func prefix: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "generic[T] func identity"), "legacy generic[T] func prefix: preserved verbatim")
}

// `pub` combines with the legacy prefix, and the item-modifier collection
// loop (`parser_items.l`) accepts either order: `pub generic[T] func …`
// or `generic[T] pub func …`. `GenericParams.legacyPrefixBeforeVis`
// records which order the source used so the formatter can reproduce it
// instead of always rendering `pub generic[T] func …` regardless — the
// latter silently reordered the `generic[T] pub func …` spelling, which
// `formatSourceChecked`'s positional token comparison flags as a
// structural change (review finding on #6827, issue #6834: `lyric fmt
// --write` refused to write for exactly this ordering).
test "pub combined with the legacy 'generic[T]' prefix round trips (pub-before-generics order)" {
  val src = "package P\n\npub generic[T] func identity(x: T): T {\n  x\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "pub + legacy generic[T] prefix (pub first): round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "pub generic[T] func identity"),
    "pub + legacy generic[T] prefix (pub first): preserved verbatim"
  )
}

// The other valid ordering (#6834): `generic[T]` written before `pub`.
test "legacy 'generic[T]' prefix combined with pub round trips (generics-before-pub order, #6834)" {
  val src = "package P\n\ngeneric[T] pub func identity(x: T): T {\n  x\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "legacy generic[T] prefix + pub (generics first): round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "generic[T] pub func identity"),
    "legacy generic[T] prefix + pub (generics first): preserved verbatim"
  )
}

// `internal` shares the same code path as `pub` (review suggestion on
// #6828 — sic, filed against the same-shaped #6827 review): round out
// coverage for the non-`pub` visibility keyword in both orderings.
test "legacy 'generic[T]' prefix combined with internal round trips in both orderings" {
  val src = "package P\n\ninternal generic[T] func identity(x: T): T {\n  x\n}\n\n" +
    "generic[U] internal func identityTwo(x: U): U {\n  x\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "legacy generic[T] prefix + internal (both orderings): round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "internal generic[T] func identity"),
    "legacy generic[T] prefix + internal (internal first): preserved verbatim"
  )
  assertTrue(
    Str.contains(acc, "generic[U] internal func identityTwo"),
    "legacy generic[T] prefix + internal (generics first): preserved verbatim"
  )
}

// `async` combines with the legacy prefix too (review suggestion on
// #6827): `funcSigStr`/`funcDoc` both prepend the vis+legacy-prefix
// combinator before `asyncStr`, per the grammar's `[async] func`
// ordering — lock that in with a dedicated round-trip test instead of
// resting on the fact that it's the same code path as the non-async
// cases above.
test "legacy 'generic[T]' prefix combined with async round trips" {
  val src = "package P\n\ngeneric[T] async func identity(x: T): T {\n  x\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "legacy generic[T] prefix + async: round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "generic[T] async func identity"),
    "legacy generic[T] prefix + async: preserved verbatim"
  )
}

// `visAndLegacyPrefixStr` (the shared vis/legacy-prefix ordering
// combinator) is exercised above only via `func` declarations; every
// other item kind's coverage exercises the bare `generic[T]` form
// without a visibility modifier (review suggestion on #6827). Cover the
// non-canonical `generic[T] pub`/`generic[T] internal` ordering for a
// second item kind (record) to confirm the combinator's correctness
// isn't just accidentally right for `func`.
test "legacy 'generic[T]' prefix combined with pub/internal round trips for a record declaration" {
  val src = "package P\n\ngeneric[T] pub record Box {\n  value: T\n}\n\n" +
    "generic[U] internal record Cell {\n  value: U\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "legacy generic[T] prefix + pub/internal (record, generics first): round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "generic[T] pub record Box"),
    "legacy generic[T] prefix + pub (record, generics first): preserved verbatim"
  )
  assertTrue(
    Str.contains(acc, "generic[U] internal record Cell"),
    "legacy generic[T] prefix + internal (record, generics first): preserved verbatim"
  )
}

// The legacy prefix form applies to every item kind the grammar lists
// (RecordDecl, UnionDecl, OpaqueTypeDecl, ProtectedTypeDecl, FunctionDecl,
// InterfaceDecl, ImplDecl) — not just `func`. Covers a record and an impl
// block (the two shapes whose legacy-prefix rendering differs most from
// `func`'s: a record's generics sit before "record NAME", an impl's sit
// before the bare "impl" keyword with no name in between at all).
test "legacy 'generic[T]' prefix form round trips for record and impl declarations" {
  val src = "package P\n\ngeneric[T] record Box {\n  value: T\n}\n\n" + "interface Shape {\n  func area(): Int\n}\n\n" +
    "generic[T] impl Shape for Box {\n  func area(): Int {\n    0\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "legacy generic[T] prefix (record/impl): round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "generic[T] record Box"), "legacy generic[T] prefix: record preserved verbatim")
  assertTrue(Str.contains(acc, "generic[T] impl Shape for Box"), "legacy generic[T] prefix: impl preserved verbatim")
}

// The remaining item kinds that thread `genLegacyPrefixStr` (review
// suggestion on #6827): union, interface, and type alias. Each has its
// own call-site shape in `fmt_items.l` (`itemDoc`'s IUnion/IInterface
// arms, `typeAliasDoc`), distinct from the func/record/impl cases above.
test "legacy 'generic[T]' prefix form round trips for union, interface, and type alias declarations" {
  val src = "package P\n\ngeneric[T] union Boxed {\n  case Full(value: T)\n  case Blank\n}\n\n" +
    "generic[T] interface Container {\n  func get(): T\n}\n\n" +
    "generic[T] alias BoxAlias = Boxed[T]\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "legacy generic[T] prefix (union/interface/alias): round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "generic[T] union Boxed"), "legacy generic[T] prefix: union preserved verbatim")
  assertTrue(
    Str.contains(acc, "generic[T] interface Container"),
    "legacy generic[T] prefix: interface preserved verbatim"
  )
  assertTrue(Str.contains(acc, "generic[T] alias BoxAlias"), "legacy generic[T] prefix: alias preserved verbatim")
}

// The last three item kinds `genLegacyPrefixStr` covers at the top-level
// item position (review suggestion on #6827): opaque type, distinct type,
// and protected type. All three accept `[ GenericParams ]` right after
// their name per the grammar (`docs/grammar.ebnf` §3.4/§3.7/§3.8), and the
// shared prefix-collection loop in `parseItem` (parser_items.l) threads
// `genericsPrefix` into `parseOpaqueTypeBody`/`parseDistinctTypeBody`/
// `parseProtectedTypeBody` exactly like it does for record/union/func —
// so the legacy `generic[T]` spelling is reachable for these three too,
// each rendered by its own `itemDoc` arm (`IOpaque`/`IDistinctType`/
// `IProtected`) in `fmt_items.l`.
test "legacy 'generic[T]' prefix form round trips for opaque, distinct, and protected type declarations" {
  val src = "package P\n\ngeneric[T] opaque type Box {\n  value: T\n}\n\n" + "generic[T] type Wrapper = List[T]\n\n" +
    "generic[T] protected type Cell {\n  var value: T\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "legacy generic[T] prefix (opaque/distinct/protected): round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "generic[T] opaque type Box"),
    "legacy generic[T] prefix: opaque type preserved verbatim"
  )
  assertTrue(
    Str.contains(acc, "generic[T] type Wrapper ="),
    "legacy generic[T] prefix: distinct type preserved verbatim"
  )
  assertTrue(
    Str.contains(acc, "generic[T] protected type Cell"),
    "legacy generic[T] prefix: protected type preserved verbatim"
  )
}

// The bare-bracket-after-name form (`func identity[T](...)`, the
// "preferred" spelling per grammar §5.1) must be completely unaffected —
// this is the FAR more common spelling in the tree today, so a
// regression here would be much more damaging than the legacy-form bug
// this fix targets.
test "bare-bracket-after-name generic form is unaffected by the legacy-prefix fix" {
  val src = "package P\n\nfunc identity[T](x: T): T {\n  x\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "bare-bracket generic form: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "func identity[T]"), "bare-bracket generic form: preserved verbatim")
  assertTrue(not Str.contains(acc, "generic["), "bare-bracket generic form: no spurious legacy prefix introduced")
}

test "short nested match arm body under the same deep nesting stays inline (#6606 no over-splitting)" {
  // Same nesting depth as the repro above (a match arm's body is itself a
  // match, so `col` threading is exercised), but the SCRUTINEE is long
  // enough on its own to force the inner match into a multi-line layout
  // while both of its own arm bodies ("v" and "0") stay short — confirming
  // `col` threading doesn't over-correct and needlessly split arms that
  // genuinely fit at their real column once the construct is already
  // multi-line for an unrelated reason.
  val src = "package P\n\nfunc classifyNestedShort(x: in Int): Int {\n" + "  match x {\n" + "    case 0 -> 0\n" +
    "    case _ ->\n" +
    "      match lookupOptionalValueForNestedWidthBoundaryCaseWithAMuchLongerScrutineeNameToForceTheOuterBreak(x) {\n" +
    "        case Some(v) -> v\n" +
    "        case None -> 0\n" +
    "      }\n" +
    "  }\n" +
    "}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "short deep-nested arm: round-trips losslessly")
  val once = format(parse(src))
  val twice = format(parse(once))
  assertEqual(once, twice, "short deep-nested arm: idempotent")
  assertTrue(
    Str.contains(
      once,
      "match lookupOptionalValueForNestedWidthBoundaryCaseWithAMuchLongerScrutineeNameToForceTheOuterBreak(x) {\n"
    ),
    "short deep-nested arm: outer scrutinee length alone forces the inner match into a multi-line layout"
  )
  assertTrue(
    Str.contains(once, "case Some(v) -> v\n"),
    "short deep-nested arm: first arm stays inline on a single line despite deep nesting"
  )
  assertTrue(
    Str.contains(once, "case None -> 0\n"),
    "short deep-nested arm: second arm stays inline on a single line despite deep nesting"
  )
  val lines = Str.split(once, "\n")
  var i = 0
  while i < lines.count {
    assertTrue(lines[i].length <= 120, "short deep-nested arm: no output line exceeds the 120-column budget")
    i = i + 1
  }
}

// `..` is a grammar-level synonym for `..<` (§4.2.1: half-open range,
// hi excluded) but `RangeBound.RBHalfOpen` carried no field recording
// which spelling the source used, so `rangeBoundStr` always rendered
// `..<` — silently rewriting every bare `..` on reformat (caught by the
// loss-check, never actually fixed until now; same bug shape as the
// legacy `generic[T]` prefix above). `RBHalfOpen.bareDotDot` (set by
// `parseRangeBound`) lets the formatter reproduce whichever spelling was
// used. Covers the `for`-loop iterator form — the original repro, from
// `for_loop_slice_self_test.l`'s `for i in 1i64 .. 6i64` case.
test "bare '..' range operator round trips instead of being silently rewritten to '..<' (#2280)" {
  val src = "package P\n\nfunc sumTo(n: Int): Int {\n  var total = 0\n  for i in 0 .. n {\n    total = total + i\n  }\n  total\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "bare '..' range operator: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "for i in 0 .. n"), "bare '..' range operator: for-loop form preserved verbatim")
}

// The explicit `..<` spelling (the canonical form `rangeBoundStr` always
// emitted before this fix) must be completely unaffected — a regression
// here would be far more damaging than the bare-`..` bug this fix targets,
// since `..<` is the far more common spelling in the tree today.
test "explicit '..<' range operator is unaffected by the bare-'..' fix" {
  val src = "package P\n\nfunc sumTo(n: Int): Int {\n  var total = 0\n  for i in 0 ..< n {\n    total = total + i\n  }\n  total\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "explicit '..<' range operator: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "for i in 0 ..< n"), "explicit '..<' range operator: preserved verbatim")
  assertTrue(not Str.contains(acc, "0 .. n"), "explicit '..<' range operator: no spurious bare '..' introduced")
}

// The same synonym pair also appears in match-arm range patterns
// (`RangePattern`, grammar §5.1), backed by a distinct AST node
// (`PatternKind.PRange`) with its own `bareDotDot` field — the same bug,
// a second AST location, fixed the same way in `patRangeStr`.
test "bare '..' range pattern round trips instead of being silently rewritten to '..<' (#2280)" {
  val src = "package P\n\nfunc classify(n: Int): Int {\n  match n {\n    case 0 .. 10 -> 1\n    case 10 ..< 20 -> 2\n    case _ -> 0\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "bare '..' range pattern: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "case 0 .. 10 ->"), "bare '..' range pattern: preserved verbatim")
  assertTrue(
    Str.contains(acc, "case 10 ..< 20 ->"),
    "explicit '..<' range pattern: preserved verbatim alongside the bare form"
  )
}

// `patRangeStr`'s operator-selection chain (review suggestion on #6828) has
// a third branch besides `bareDotDot`'s true/false: the inclusive `..=`
// spelling, which short-circuits ahead of `bareDotDot` entirely (`incl`
// is set independently by `RangeBound.RBClosed`/inclusive patterns, not by
// this PR's new field). Cover it explicitly so a future reordering of that
// chain that broke `..=` round-tripping wouldn't go undetected by only the
// two half-open cases above.
test "inclusive '..=' range pattern round trips (unaffected by the bareDotDot chain)" {
  val src = "package P\n\nfunc classify(n: Int): Int {\n  match n {\n    case 0 ..= 10 -> 1\n    case _ -> 0\n  }\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "inclusive '..=' range pattern: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "case 0 ..= 10 ->"), "inclusive '..=' range pattern: preserved verbatim")
}

// A third, distinct call site for the same `rangeBoundStr` fix: a range
// subtype declaration (`docs/01-language-reference.md`'s `TRefined`,
// `type Age = Int range 0 .. 150`). `distinctDoc` renders `dt.rangeClause`
// through the same `rangeBoundStr` as the for-loop and match-pattern
// forms above, so it shares the fix without any change of its own — this
// test just confirms the third reader of `RBHalfOpen.bareDotDot` round-trips
// too.
test "bare '..' range subtype bound round trips instead of being silently rewritten to '..<' (#2280)" {
  val src = "package P\n\ntype Age = Int range 0 .. 150\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "bare '..' range subtype: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "type Age = Int range 0 .. 150"), "bare '..' range subtype: preserved verbatim")
}

// The explicit '..<' counterpart on the same third reader (review
// suggestion on #6828) — the for-loop and match-pattern tests above both
// cover both spellings side by side; this closes the same gap for the
// range-subtype declaration form.
test "explicit '..<' range subtype bound is unaffected by the bare-'..' fix" {
  val src = "package P\n\ntype Age = Int range 0 ..< 150\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "explicit '..<' range subtype: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "type Age = Int range 0 ..< 150"), "explicit '..<' range subtype: preserved verbatim")
}

// A fourth reader of `rangeBoundStr` (review suggestion on #6828): an
// INLINE type refinement (`TRefined`, `typeStr`'s own arm), distinct
// from the named range-subtype *declaration* form covered above —
// `Path range <bound>` is valid anywhere a `TypeExpr` is (see
// `parser_exprs.l`'s `identStr(peekToken(st)) == "range"` branch), e.g.
// as a parameter type. Confirms the bare `..` spelling round-trips
// there too, not just in `distinctDoc`.
test "bare '..' inline type-refinement bound round trips (fourth rangeBoundStr reader, #2280)" {
  val src = "package P\n\nfunc clamp(x: Int range 0 .. 10): Int {\n  x\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "bare '..' inline type refinement: round-trips")
  val acc = format(parse(src))
  assertTrue(Str.contains(acc, "x: Int range 0 .. 10"), "bare '..' inline type refinement: preserved verbatim")
}

// `OpaqueTypeDecl.annotations` (grammar: `'opaque' 'type' IDENT
// [GenericParams] [WhereClause] [Annotation...] [Body]`) is a TRAILING
// annotation position — `@projectable` sits AFTER the name, on the same
// line, e.g. `opaque type User @projectable { ... }`. `opaqueDoc` was
// rendering these as their own LEADING lines (the position every other
// item kind's annotations use), which relocated `@projectable` to
// BEFORE `opaque type` on reformat — corrupting the token sequence
// (caught by the loss-check, never actually fixed until now; same bug
// shape as the other #2280 losslessness gaps). `annotationsInlineSuffix`
// renders them inline on the header line instead. Covers both the
// with-body and bodyless (extern-handle) forms.
test "opaque type's trailing annotation stays on the header line instead of being hoisted before it (#2280)" {
  val src = "package P\n\nopaque type User @projectable {\n  id: Int\n}\n\nopaque type Handle @projectable\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "opaque trailing annotation: round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "opaque type User @projectable {"),
    "opaque trailing annotation: with-body form stays inline on the header line"
  )
  assertTrue(
    Str.contains(acc, "opaque type Handle @projectable"),
    "opaque trailing annotation: bodyless form stays inline on the header line"
  )
}

// An opaque type combines a genuine LEADING annotation (`item.annotations`
// — `@stable`, rendered as its own line before `opaque type`, unaffected
// by this fix) with the TRAILING `od.annotations` (`@projectable`,
// rendered inline) — confirms the two annotation positions the grammar
// distinguishes don't collide or get swapped.
test "opaque type combines a leading annotation with the trailing one correctly" {
  val src = "package P\n\n@stable(since = \"0.1\")\npub opaque type User @projectable {\n  id: Int\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "leading + trailing opaque annotations: round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "@stable(since = \"0.1\")\npub opaque type User @projectable {"),
    "leading + trailing opaque annotations: both preserved in their own distinct positions"
  )
}

// `FieldDecl`'s grammar (`[ 'var' ] IDENT ':' Type [ '=' Expr ]
// [ Annotation ]`) places its OWN trailing annotation after the type
// (and default, if any) on the same line, e.g. `passwordHash: String
// @hidden` — distinct from a leading annotation written on the
// preceding line, e.g. `@proto_field(1)\nid: Long` (already covered by
// the "field annotations stay with their field" test above).
// `parseFieldDecl` concatenates both positions into one `annotations`
// list with no marker, so `fieldMemberLines` rendered every entry as a
// leading line — hoisting `@hidden` up before the field it annotates on
// reformat. `FieldDecl.trailingAnnotationCount` records the split so the
// formatter can render each group in its own place (same bug shape as
// the opaque-type-level fix above, one AST layer down). Covers a record
// field (which `fieldMemberLines` also backs for exposed records,
// opaque-type fields, and `config { }` fields).
test "record field's trailing annotation stays on the field's own line instead of being hoisted above it (#2280)" {
  val src = "package P\n\nrecord Account {\n  accountId: Int\n  passwordHash: String @hidden\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "field trailing annotation: round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "passwordHash: String @hidden"),
    "field trailing annotation: stays inline on the field's own line"
  )
}

// A field combines a genuine LEADING annotation with its own TRAILING
// one — confirms the split doesn't collide or reorder either position,
// mirroring the opaque-type-level combined test above.
test "field combines a leading annotation with its own trailing one correctly" {
  val src = "package P\n\nrecord Account {\n  @proto_field(1)\n  passwordHash: String @hidden\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "leading + trailing field annotations: round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "@proto_field(1)\n  passwordHash: String @hidden"),
    "leading + trailing field annotations: both preserved in their own distinct positions"
  )
}

// `config { }` fields (`ConfigField`) support the identical leading +
// trailing split via the same `parseSameLineTrailingAnnotations` parser
// helper — `configDoc`/`configFieldLine` had the same bug, fixed the
// same way.
test "config field's trailing annotation stays on the field's own line instead of being hoisted above it (#2280)" {
  val src = "package P\n\nconfig AppConfig {\n  port: Int = 8080 @sensitive\n}\n"
  val c = formatSourceChecked(src)
  assertTrue(fmtCheckIsOk(c), "config field trailing annotation: round-trips")
  val acc = format(parse(src))
  assertTrue(
    Str.contains(acc, "port: Int = 8080 @sensitive"),
    "config field trailing annotation: stays inline on the field's own line"
  )
}
