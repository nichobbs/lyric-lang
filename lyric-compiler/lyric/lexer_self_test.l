// lyric/lexer_self_test.l — Lyric.LexerSelfTest consumer of the
// `Lyric.Lexer` library.  Compiled and executed by the F# Expecto
// runner at `compiler/tests/Lyric.Emitter.Tests/SelfHostedLexerTests.fs`:
// each in-program assertion panics via `Std.Testing` on mismatch;
// exit 0 + an "ok" line in stdout means every check held.
//
// Stage 2b of M5.1 split this out from the lexer module so
// `Lyric.Lexer` is a reusable library.  The split exercises every
// cross-package surface the M5.1 follow-up depends on (record field
// access, union case match, function call, generic Option) end to end.
package Lyric.LexerSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing
import Lyric.Lexer

// ─────────────────────────────────────────────────────────────────────────────
// Token-shape predicates.
// ─────────────────────────────────────────────────────────────────────────────

func tokenName(t: in Token): String {
  match t {
    case TKeyword(_)          -> "keyword"
    case TIdent(_)            -> "ident"
    case TInt(_, _)           -> "int"
    case TFloat(_, _)         -> "float"
    case TChar(_)             -> "char"
    case TString(_)           -> "string"
    case TStringStart         -> "string_start"
    case TStringPart(_)       -> "string_part"
    case TStringHoleStart     -> "string_hole_start"
    case TStringEnd           -> "string_end"
    case TTripleString(_)     -> "triple_string"
    case TRawString(_)        -> "raw_string"
    case TBool(_)             -> "bool"
    case TPunct(_)            -> "punct"
    case TStmtEnd             -> "stmt_end"
    case TDocComment(_)       -> "doc"
    case TModuleDocComment(_) -> "module_doc"
    case TEof                 -> "eof"
  }
}

func tokenAt(lr: in LexResult, i: in Int): SpannedToken {
  lr.tokens[i]
}

func tokenKindAt(lr: in LexResult, i: in Int): String {
  tokenName(tokenAt(lr, i).token)
}

func intValueAt(lr: in LexResult, i: in Int): Long {
  match tokenAt(lr, i).token {
    case TInt(v, _) -> v
    case _          -> -1i64
  }
}

func floatValueAt(lr: in LexResult, i: in Int): Double {
  match tokenAt(lr, i).token {
    case TFloat(v, _) -> v
    case _            -> -1.0
  }
}

func identNameAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TIdent(name) -> name
    case _            -> "<not-ident>"
  }
}

func stringValueAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TString(t) -> t
    case _          -> "<not-string>"
  }
}

func boolValueAt(lr: in LexResult, i: in Int): Bool {
  match tokenAt(lr, i).token {
    case TBool(b) -> b
    case _        -> false
  }
}

func stringPartAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TStringPart(t) -> t
    case _              -> "<not-string-part>"
  }
}

func tripleStringAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TTripleString(t) -> t
    case _                -> "<not-triple-string>"
  }
}

func rawStringAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TRawString(t) -> t
    case _             -> "<not-raw-string>"
  }
}

func charCodepointAt(lr: in LexResult, i: in Int): Int {
  match tokenAt(lr, i).token {
    case TChar(cp) -> cp
    case _         -> -1
  }
}

func keywordSpellingAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TKeyword(kw) -> keywordSpelling(kw)
    case _            -> "<not-keyword>"
  }
}

func punctNameAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TPunct(p) -> punctName(p)
    case _         -> "<not-punct>"
  }
}

func punctName(p: in Punct): String {
  match p {
    case DotDotEq         -> "..="
    case DotDotLt         -> "..<"
    case DotDot           -> ".."
    case Arrow            -> "->"
    case FatArrow         -> "=>"
    case ColonColon       -> "::"
    case Question         -> "?"
    case QuestionQuestion -> "??"
    case At               -> "@"
    case EqEq             -> "=="
    case NotEq            -> "!="
    case LtEq             -> "<="
    case GtEq             -> ">="
    case Lt               -> "<"
    case Gt               -> ">"
    case PlusEq           -> "+="
    case MinusEq          -> "-="
    case StarEq           -> "*="
    case SlashEq          -> "/="
    case PercentEq        -> "%="
    case Plus             -> "+"
    case Minus            -> "-"
    case Star             -> "*"
    case Slash            -> "/"
    case Percent          -> "%"
    case Eq               -> "="
    case Bang             -> "!"
    case Pipe             -> "|"
    case Amp              -> "&"
    case LParen           -> "("
    case RParen           -> ")"
    case LBracket         -> "["
    case RBracket         -> "]"
    case LBrace           -> "{"
    case RBrace           -> "}"
    case Comma            -> ","
    case Semi             -> ";"
    case Colon            -> ":"
    case Dot              -> "."
  }
}

func diagCount(lr: in LexResult): Int {
  lr.diagnostics.count
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

func testEmptyInput(): Unit {
  val r = lex("")
  // Just an EOF.
  assertEqualInt(r.tokens.count, 1, "empty: token count")
  assertEqual(tokenKindAt(r, 0), "eof", "empty: only eof")
  assertEqualInt(diagCount(r), 0, "empty: no diagnostics")
}

func testIdentAndKeyword(): Unit {
  val r = lex("foo bar package self")
  // foo, bar, package, self, EOF — no STMT_END (no newline).
  assertEqualInt(r.tokens.count, 5, "ident+kw: token count")
  assertEqual(tokenKindAt(r, 0), "ident",    "ident+kw: foo is ident")
  assertEqual(identNameAt(r, 0), "foo",      "ident+kw: foo name")
  assertEqual(tokenKindAt(r, 1), "ident",    "ident+kw: bar is ident")
  assertEqual(identNameAt(r, 1), "bar",      "ident+kw: bar name")
  assertEqual(tokenKindAt(r, 2), "keyword",  "ident+kw: package is keyword")
  assertEqual(keywordSpellingAt(r, 2), "package", "ident+kw: package spelling")
  assertEqual(tokenKindAt(r, 3), "keyword",  "ident+kw: self is keyword")
  assertEqual(keywordSpellingAt(r, 3), "self", "ident+kw: self spelling")
  assertEqual(tokenKindAt(r, 4), "eof",      "ident+kw: trailing eof")
  assertEqualInt(diagCount(r), 0, "ident+kw: no diagnostics")
}

func testBoolKeyword(): Unit {
  val r = lex("true false")
  assertEqualInt(r.tokens.count, 3, "bool: token count")
  assertEqual(tokenKindAt(r, 0), "bool", "bool: true is bool token")
  assertTrue(boolValueAt(r, 0), "bool: true value")
  assertEqual(tokenKindAt(r, 1), "bool", "bool: false is bool token")
  assertTrue(not boolValueAt(r, 1), "bool: false value")
}

func testDecimalInts(): Unit {
  val r = lex("0 42 1_000_000")
  assertEqualInt(r.tokens.count, 4, "decimal: token count (incl eof)")
  assertEqual(tokenKindAt(r, 0), "int", "decimal: 0 is int")
  assertTrue(intValueAt(r, 0) == 0i64, "decimal: 0 value")
  assertTrue(intValueAt(r, 1) == 42i64, "decimal: 42 value")
  assertTrue(intValueAt(r, 2) == 1000000i64, "decimal: underscore-separated")
}

func testHexOctBinInts(): Unit {
  val r = lex("0xFF 0o755 0b1010")
  assertEqualInt(r.tokens.count, 4, "based: token count")
  assertTrue(intValueAt(r, 0) == 255i64, "based: 0xFF")
  assertTrue(intValueAt(r, 1) == 493i64, "based: 0o755")
  assertTrue(intValueAt(r, 2) == 10i64,  "based: 0b1010")
  assertEqualInt(diagCount(r), 0, "based: no diagnostics")
}

func testIntSuffix(): Unit {
  val r = lex("100u32 7i64")
  assertTrue(intValueAt(r, 0) == 100i64, "int-suffix: 100")
  assertTrue(intValueAt(r, 1) == 7i64,   "int-suffix: 7")
  assertEqualInt(diagCount(r), 0, "int-suffix: no diagnostics")
}

func testLeadingZeroDecimalRejected(): Unit {
  val r = lex("0755")
  assertEqualInt(diagCount(r), 1, "leading-zero: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0012", "leading-zero: L0012")
}

func testFloatLiterals(): Unit {
  val r = lex("3.14 2.5e2 1.0f64")
  assertEqual(tokenKindAt(r, 0), "float", "float: 3.14 kind")
  assertTrue(floatValueAt(r, 0) > 3.13 and floatValueAt(r, 0) < 3.15, "float: 3.14 value")
  assertEqual(tokenKindAt(r, 1), "float", "float: 2.5e2 kind")
  assertTrue(floatValueAt(r, 1) > 249.9 and floatValueAt(r, 1) < 250.1, "float: 2.5e2 == 250")
  assertEqual(tokenKindAt(r, 2), "float", "float: 1.0f64 kind")
  assertTrue(floatValueAt(r, 2) > 0.99 and floatValueAt(r, 2) < 1.01, "float: 1.0f64 value")
  assertEqualInt(diagCount(r), 0, "float: no diagnostics")
}

func testStringLiteral(): Unit {
  val r = lex("\"hello\"")
  assertEqual(tokenKindAt(r, 0), "string", "string: kind")
  assertEqual(stringValueAt(r, 0), "hello", "string: value")
  assertEqualInt(diagCount(r), 0, "string: no diagnostics")
}

func testStringEscapes(): Unit {
  val r = lex("\"a\\nb\\tc\\\\d\"")
  assertEqual(tokenKindAt(r, 0), "string", "string-esc: kind")
  assertEqual(stringValueAt(r, 0), "a\nb\tc\\d", "string-esc: value")
}

func testUnterminatedString(): Unit {
  val r = lex("\"oops")
  assertEqualInt(diagCount(r), 1, "unterm: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0025", "unterm: L0025")
}

// Unicode escapes in the full BMP must decode correctly.
// The surrogate range U+D800..U+DFFF must be rejected with L0023.
func testUnicodeEscapeBmpRange(): Unit {
  // \u{80} — first non-ASCII BMP scalar.  Previously decoded to U+FFFD
  // under the 96-char ASCII lookup table.
  val r1 = lex("\"\\u{80}\"")
  assertEqualInt(diagCount(r1), 0, "u80: no diagnostics")
  assertEqual(stringValueAt(r1, 0), "\u{80}", "u80: round-trips")

  // \u{00FF} — Latin-1 supplement boundary.
  val r2 = lex("\"\\u{00FF}\"")
  assertEqualInt(diagCount(r2), 0, "u00FF: no diagnostics")
  assertEqual(stringValueAt(r2, 0), "\u{00FF}", "u00FF: round-trips")

  // \u{FFFF} — highest BMP scalar (last code point before surrogate
  // range, well above the surrogate range itself).
  val r3 = lex("\"\\u{FFFF}\"")
  assertEqualInt(diagCount(r3), 0, "uFFFF: no diagnostics")
  assertEqual(stringValueAt(r3, 0), "\u{FFFF}", "uFFFF: round-trips")
}

func testUnicodeEscapeSurrogateRejected(): Unit {
  // U+D800 — first high (lead) surrogate.  Must produce L0023 (surrogate range)
  // and substitute U+FFFD without panicking.
  val r1 = lex("\"\\u{D800}\"")
  assertEqualInt(diagCount(r1), 1, "uD800: one diagnostic")
  assertEqual(r1.diagnostics[0].code, "L0023", "uD800: L0023")
  assertEqual(stringValueAt(r1, 0), "\u{FFFD}", "uD800: U+FFFD substituted")

  // U+DFFF — last low (trail) surrogate.
  val r2 = lex("\"\\u{DFFF}\"")
  assertEqualInt(diagCount(r2), 1, "uDFFF: one diagnostic")
  assertEqual(r2.diagnostics[0].code, "L0023", "uDFFF: L0023")
  assertEqual(stringValueAt(r2, 0), "\u{FFFD}", "uDFFF: U+FFFD substituted")
}

func testUnicodeEscapeNonBmpRejected(): Unit {
  // \u{1F600} — non-BMP scalar (emoji).  The current Char-returning
  // surface cannot express a UTF-16 surrogate pair, so non-BMP escapes
  // produce an L0022 + U+FFFD substitution.
  val r = lex("\"\\u{1F600}\"")
  assertEqualInt(diagCount(r), 1, "u1F600: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0022", "u1F600: L0022")
  assertEqual(stringValueAt(r, 0), "\u{FFFD}", "u1F600: U+FFFD substituted")
}

// Phase 5 §M5.1 stage 3 — interpolated / triple / raw strings.
//
// Note on quoting: every time the body of a `lex(...)` call below
// contains a `${`, the bootstrap lexer (parsing this source file)
// would otherwise interpret it as its own interpolation hole.  The
// `\$` escape in the outer string keeps the bootstrap from doing
// that — the lexer-under-test still sees a literal `${` because
// `\$` decodes to `$`.
func testInterpolatedString(): Unit {
  // The string passed to `lex` is `"hello, ${name}"` — three logical
  // chunks: the literal `hello, `, the hole's expression token (an
  // ident), and the closing sequence.  Tokens: TStringStart,
  // TStringPart, TStringHoleStart, TIdent, TPunct(}), TStringEnd,
  // TEof.
  val r = lex("\"hello, \${name}\"")
  assertEqualInt(diagCount(r), 0, "interp: no diagnostics")
  assertEqual(tokenKindAt(r, 0), "string_start",      "interp: TStringStart")
  assertEqual(tokenKindAt(r, 1), "string_part",       "interp: TStringPart")
  assertEqual(stringPartAt(r, 1), "hello, ",          "interp: chunk text")
  assertEqual(tokenKindAt(r, 2), "string_hole_start", "interp: TStringHoleStart")
  assertEqual(tokenKindAt(r, 3), "ident",             "interp: hole ident")
  assertEqual(tokenKindAt(r, 4), "punct",             "interp: closing }")
  assertEqual(tokenKindAt(r, 5), "string_end",        "interp: TStringEnd")
}

func testInterpolatedStringNoHoles(): Unit {
  // No `${`, so the simple `TString` path runs even though the
  // dispatcher consulted `hasInterpolation`.
  val r = lex("\"plain ascii\"")
  assertEqual(tokenKindAt(r, 0), "string", "interp-fallback: simple TString")
  assertEqual(stringValueAt(r, 0), "plain ascii", "interp-fallback: text")
}

func testTripleString(): Unit {
  val r = lex("\"\"\"line1\nline2\"\"\"")
  assertEqualInt(diagCount(r), 0, "triple: no diagnostics")
  assertEqual(tokenKindAt(r, 0), "triple_string", "triple: TTripleString")
  assertEqual(tripleStringAt(r, 0), "line1\nline2", "triple: body preserved")
}

func testUnterminatedTripleString(): Unit {
  val r = lex("\"\"\"missing close")
  assertEqualInt(diagCount(r), 1, "unterm-triple: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0026", "unterm-triple: L0026")
}

func testRawStringNoHashes(): Unit {
  val r = lex("r\"raw\\nbody\"")
  assertEqualInt(diagCount(r), 0, "raw: no diagnostics")
  assertEqual(tokenKindAt(r, 0), "raw_string", "raw: TRawString")
  // No escape processing — the literal `\n` survives as two chars.
  assertEqual(rawStringAt(r, 0), "raw\\nbody", "raw: body byte-for-byte")
}

func testRawStringWithHashes(): Unit {
  val r = lex("r#\"with \"quotes\"\"#")
  assertEqualInt(diagCount(r), 0, "raw#: no diagnostics")
  assertEqual(tokenKindAt(r, 0), "raw_string", "raw#: TRawString")
  assertEqual(rawStringAt(r, 0), "with \"quotes\"", "raw#: embedded quotes")
}

func testUnterminatedRawString(): Unit {
  val r = lex("r\"oops")
  assertEqualInt(diagCount(r), 1, "unterm-raw: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0028", "unterm-raw: L0028")
}

func testCharLiteral(): Unit {
  val r = lex("'a' '\\n'")
  assertEqual(tokenKindAt(r, 0), "char", "char: 'a' kind")
  assertEqualInt(charCodepointAt(r, 0), 97, "char: 'a' codepoint")
  assertEqual(tokenKindAt(r, 1), "char", "char: '\\n' kind")
  assertEqualInt(charCodepointAt(r, 1), 10, "char: '\\n' codepoint")
}

func testPunctuation(): Unit {
  val r = lex("-> => ..= < <= == != +=")
  assertEqual(punctNameAt(r, 0), "->",  "punct: ->")
  assertEqual(punctNameAt(r, 1), "=>",  "punct: =>")
  assertEqual(punctNameAt(r, 2), "..=", "punct: ..=")
  assertEqual(punctNameAt(r, 3), "<",   "punct: <")
  assertEqual(punctNameAt(r, 4), "<=",  "punct: <=")
  assertEqual(punctNameAt(r, 5), "==",  "punct: ==")
  assertEqual(punctNameAt(r, 6), "!=",  "punct: !=")
  assertEqual(punctNameAt(r, 7), "+=",  "punct: +=")
}

func testStmtEndInsertion(): Unit {
  val r = lex("foo\nbar")
  assertEqualInt(r.tokens.count, 4, "stmt-end: foo STMT_END bar EOF")
  assertEqual(tokenKindAt(r, 0), "ident",    "stmt-end: foo")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "stmt-end: synthesised")
  assertEqual(tokenKindAt(r, 2), "ident",    "stmt-end: bar")
}

func testStmtEndSuppressedAfterOperator(): Unit {
  val r = lex("a +\nb")
  assertEqualInt(r.tokens.count, 4, "stmt-end suppressed: token count")
  assertEqual(tokenKindAt(r, 0), "ident", "stmt-end suppressed: a")
  assertEqual(tokenKindAt(r, 1), "punct", "stmt-end suppressed: +")
  assertEqual(tokenKindAt(r, 2), "ident", "stmt-end suppressed: b — no STMT_END between + and b")
}

func testStmtEndSuppressedInsideBrackets(): Unit {
  val r = lex("(a\nb)")
  assertEqualInt(r.tokens.count, 5, "brackets: token count")
  assertEqual(tokenKindAt(r, 0), "punct", "brackets: (")
  assertEqual(tokenKindAt(r, 1), "ident", "brackets: a")
  assertEqual(tokenKindAt(r, 2), "ident", "brackets: b")
  assertEqual(tokenKindAt(r, 3), "punct", "brackets: )")
}

func testExplicitSemicolon(): Unit {
  val r = lex("a;b")
  assertEqualInt(r.tokens.count, 4, "semi: token count")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "semi: STMT_END from ;")
}

func testLineComment(): Unit {
  val r = lex("foo // ignored\nbar")
  assertEqualInt(r.tokens.count, 4, "line comment: foo STMT_END bar EOF")
  assertEqual(tokenKindAt(r, 0), "ident",    "line comment: foo")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "line comment: STMT_END after newline")
  assertEqual(tokenKindAt(r, 2), "ident",    "line comment: bar")
}

func testBlockComment(): Unit {
  val r = lex("foo /* /* nested */ */ bar")
  assertEqualInt(r.tokens.count, 3, "block comment: token count")
  assertEqual(identNameAt(r, 0), "foo", "block comment: foo")
  assertEqual(identNameAt(r, 1), "bar", "block comment: bar")
  assertEqualInt(diagCount(r), 0, "block comment: no diagnostics")
}

func testUnterminatedBlockComment(): Unit {
  val r = lex("foo /* unclosed")
  assertEqualInt(diagCount(r), 1, "unterm block: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0001", "unterm block: L0001")
}

// #425 item 5 / #1174 review finding: a bare decimal literal of
// `9223372036854775808` (the absolute value of Long.MinValue) fires
// L0010 — the value only fits as a bit pattern, so a programmer who
// writes `val x: Long = 9223372036854775808` must see the diagnostic.
// The literal still emits a TInt(Long.MinValue) so the parser can
// collapse `PreNeg + literal` into Long.MinValue and cancel the
// diagnostic (parser-side coverage in `parser_self_test.l`).
func testBareMinValueAbsLiteralFiresL0010(): Unit {
  val r = lex("val x = 9223372036854775808")
  assertTrue(diagCount(r) >= 1, "9223372036854775808: L0010 fires")
  var sawL0010 = false
  var i = 0
  while i < r.diagnostics.count {
    if r.diagnostics[i].code == "L0010" { sawL0010 = true }
    i = i + 1
  }
  assertTrue(sawL0010, "9223372036854775808: L0010 present")
  // The bit pattern is preserved so `-9223372036854775808` downstream
  // can produce Long.MinValue — that's a separate parser test.
  // The literal itself is the third token (val, ident, =, int).
  assertEqual(tokenKindAt(r, 3), "int", "9223372036854775808: TInt emitted")
  assertTrue(intValueAt(r, 3) == -9223372036854775808i64,
             "9223372036854775808: bit pattern is Long.MinValue")
}

// Sanity check that other huge literals still hit the regular
// overflow path (not the MinValue special case).
func testTrulyOverflowingLiteralStillFiresL0010(): Unit {
  val r = lex("val x = 9223372036854775809")  // one past Long.MaxValue+1
  var sawL0010 = false
  var i = 0
  while i < r.diagnostics.count {
    if r.diagnostics[i].code == "L0010" { sawL0010 = true }
    i = i + 1
  }
  assertTrue(sawL0010, "regular overflow: L0010 present")
  assertEqual(tokenKindAt(r, 3), "int", "regular overflow: TInt emitted (value 0)")
  assertTrue(intValueAt(r, 3) == 0i64,
             "regular overflow: value substituted with 0")
}

// #425 item 2: a `// /*` sequence inside a line comment must NOT
// open a block comment.  The line-comment scanner is checked before
// the block-comment scanner (`skipTrivia` dispatch order), so a
// leading `//` claims the whole line — the `/*` is just comment text.
// Regression test: `foo // /*\nbar` must produce two real tokens
// (foo, bar) and no unterminated-comment diagnostic.
func testLineCommentSwallowsBlockOpen(): Unit {
  val r = lex("foo // /*\nbar")
  assertEqualInt(diagCount(r), 0, "line // /*: no unterminated-block diagnostic")
  assertEqual(tokenKindAt(r, 0), "ident",    "line // /*: foo")
  assertEqual(identNameAt(r, 0), "foo",      "line // /*: foo name")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "line // /*: STMT_END after newline")
  assertEqual(tokenKindAt(r, 2), "ident",    "line // /*: bar")
  assertEqual(identNameAt(r, 2), "bar",      "line // /*: bar name")
}

func testDocComment(): Unit {
  val r = lex("/// documentation\nfoo")
  assertEqualInt(r.tokens.count, 4, "doc: doc STMT_END foo EOF")
  assertEqual(tokenKindAt(r, 0), "doc", "doc: kind")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "doc: STMT_END after newline")
  assertEqual(identNameAt(r, 2), "foo", "doc: foo follows")
}

func testModuleDocComment(): Unit {
  val r = lex("//! module overview\n")
  assertEqualInt(r.tokens.count, 3, "module doc: token count")
  assertEqual(tokenKindAt(r, 0), "module_doc", "module doc: kind")
}

func testCrlfNormalisation(): Unit {
  val r = lex("foo\r\nbar")
  assertEqualInt(r.tokens.count, 4, "crlf: token count")
  assertEqual(tokenKindAt(r, 0), "ident",    "crlf: foo")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "crlf: STMT_END")
  assertEqual(tokenKindAt(r, 2), "ident",    "crlf: bar")
}

// Phase 5 §M5.1 stage 4 — L0040 reserved-name diagnostic for `_X`
// (underscore followed by an ASCII uppercase letter).  #425 item 1
// hardened the lexer so the rejected lexeme is rewritten to a
// `__error_<offset>` placeholder before TIdent emission; this prevents
// the original `_Foo` lexeme from clashing with compiler-generated
// names like `_Async` / `_StateMachine` further down the pipeline.
func testReservedUnderscoreUpperRejected(): Unit {
  val r = lex("_Hidden")
  assertEqual(tokenKindAt(r, 0), "ident", "L0040: still emitted as TIdent")
  assertEqual(identNameAt(r, 0), "__error_0",
              "L0040: lexeme rewritten to placeholder (offset 0)")
  assertEqualInt(diagCount(r), 1, "L0040: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0040", "L0040: code")
}

// #425 item 1: each `_UpperCase` occurrence gets a span-keyed
// placeholder, so two rejections in the same source produce distinct
// TIdent names that cannot clash with each other or with the
// `_StateMachine` / `_Async` family of compiler-generated names.
func testReservedUnderscoreUpperPlaceholdersDistinct(): Unit {
  val r = lex("_Foo  _Bar")
  assertEqualInt(diagCount(r), 2, "L0040: two diagnostics")
  assertEqual(identNameAt(r, 0), "__error_0", "L0040: first placeholder")
  // `_Bar` starts at byte offset 6 ("_Foo  " is six bytes).
  assertEqual(identNameAt(r, 1), "__error_6", "L0040: second placeholder")
}

func testReservedUnderscoreLowerOK(): Unit {
  // Underscore followed by a *lowercase* letter is fine — those
  // aren't compiler-generated.
  val r = lex("_hidden")
  assertEqualInt(diagCount(r), 0, "L0040: no diagnostic for _hidden")
}

func testReservedUnderscoreDigitOK(): Unit {
  // Underscore + digit is also fine (e.g. `_0` is a destructured
  // tuple slot in some style guides).
  val r = lex("_0name")
  assertEqualInt(diagCount(r), 0, "L0040: no diagnostic for _0…")
}

func testReservedUnderscoreAlone(): Unit {
  // Pure underscore is the wildcard pattern; no diagnostic.
  val r = lex("_")
  assertEqualInt(diagCount(r), 0, "L0040: no diagnostic for `_`")
}

// Phase 5 §M5.1 stage 4 — non-ASCII (UAX #31 XID_Start /
// XID_Continue) identifier acceptance via `Std.UnicodeHost`'s
// `System.Char.GetUnicodeCategory` extern.
func testNonAsciiIdentifier(): Unit {
  // Greek-letter identifier — `α` is `LowercaseLetter`,
  // `β` is `LowercaseLetter`.  No diagnostics; one TIdent token.
  val r = lex("\u{03B1}\u{03B2}")
  assertEqualInt(diagCount(r), 0, "uax31: greek ident no diagnostics")
  assertEqual(tokenKindAt(r, 0), "ident", "uax31: TIdent kind")
  assertEqual(identNameAt(r, 0), "\u{03B1}\u{03B2}", "uax31: lexeme preserved")
}

func testCyrillicIdentifier(): Unit {
  // Cyrillic capital letter `И` (U+0418) is `UppercaseLetter`;
  // followed by lowercase `и` (U+0438) which is `LowercaseLetter`.
  val r = lex("\u{0418}\u{0438}")
  assertEqualInt(diagCount(r), 0, "uax31: cyrillic ident no diagnostics")
  assertEqual(tokenKindAt(r, 0), "ident", "uax31: TIdent kind")
}

func testIdentDigitsContinueOnly(): Unit {
  // `α0` — letter then ASCII digit.  Digits are XID_Continue but
  // not XID_Start, so the leading letter is required.  Should
  // produce one TIdent.
  val r = lex("\u{03B1}0")
  assertEqualInt(diagCount(r), 0, "uax31: letter+digit no diagnostics")
  assertEqual(tokenKindAt(r, 0), "ident", "uax31: starts as TIdent")
  assertEqual(identNameAt(r, 0), "\u{03B1}0", "uax31: digits trail")
}

// ─────────────────────────────────────────────────────────────────────────────
// Trivia capture (Phase 5 §M5.1 stage 5' — red/green CST foundation).
// `SpannedToken.leadingTrivia` carries every whitespace, newline, and
// non-doc comment that preceded the token in source order.  These
// tests cover each `TriviaKind` plus the basic invariant that a token
// stream's leading-trivia text concatenated with its lexeme text
// reproduces the original source byte-for-byte (modulo CR/LF
// normalisation already applied by `lex`).
// ─────────────────────────────────────────────────────────────────────────────

func triviaKindName(k: in TriviaKind): String {
  match k {
    case TKWhitespace   -> "ws"
    case TKNewline      -> "nl"
    case TKLineComment  -> "line"
    case TKBlockComment -> "block"
  }
}

func leadingTriviaCount(lr: in LexResult, i: in Int): Int {
  tokenAt(lr, i).leadingTrivia.count
}

func leadingTriviaKindAt(lr: in LexResult, ti: in Int, idx: in Int): String {
  triviaKindName(tokenAt(lr, ti).leadingTrivia[idx].kind)
}

func leadingTriviaTextAt(lr: in LexResult, ti: in Int, idx: in Int): String {
  tokenAt(lr, ti).leadingTrivia[idx].text
}

/// Concatenate every token's leading-trivia text plus its source
/// extent.  Used to assert lossless reconstruction of the original
/// source string from the captured trivia + token spans.
func reconstructSource(src: in String, lr: in LexResult): String {
  var s = ""
  var i = 0
  while i < lr.tokens.count {
    val t = tokenAt(lr, i)
    var j = 0
    while j < t.leadingTrivia.count {
      s = s + t.leadingTrivia[j].text
      j = j + 1
    }
    val len = t.span.endPos.offset - t.span.startPos.offset
    if len > 0 {
      s = s + Str.substring(src, t.span.startPos.offset, len)
    }
    i = i + 1
  }
  s
}

func testTriviaLeadingWhitespace(): Unit {
  val r = lex("   foo")
  // Tokens: foo, EOF.  `foo` carries the leading "   " whitespace.
  assertEqual(tokenKindAt(r, 0), "ident", "trivia-ws: ident")
  assertEqualInt(leadingTriviaCount(r, 0), 1, "trivia-ws: one trivium")
  assertEqual(leadingTriviaKindAt(r, 0, 0), "ws", "trivia-ws: kind")
  assertEqual(leadingTriviaTextAt(r, 0, 0), "   ", "trivia-ws: text")
}

func testTriviaLineComment(): Unit {
  val r = lex("// hi\nfoo")
  // Tokens: foo, EOF.  Leading trivia on `foo`: line-comment then newline.
  assertEqual(tokenKindAt(r, 0), "ident", "trivia-line: ident")
  assertEqualInt(leadingTriviaCount(r, 0), 2, "trivia-line: two trivia")
  assertEqual(leadingTriviaKindAt(r, 0, 0), "line", "trivia-line: comment kind")
  assertEqual(leadingTriviaTextAt(r, 0, 0), "// hi", "trivia-line: comment text")
  assertEqual(leadingTriviaKindAt(r, 0, 1), "nl", "trivia-line: newline kind")
  assertEqual(leadingTriviaTextAt(r, 0, 1), "\n", "trivia-line: newline text")
}

func testTriviaBlockComment(): Unit {
  val r = lex("/* hi */foo")
  // Tokens: foo, EOF.  Leading trivia on `foo`: block-comment.
  assertEqual(tokenKindAt(r, 0), "ident", "trivia-block: ident")
  assertEqualInt(leadingTriviaCount(r, 0), 1, "trivia-block: one trivium")
  assertEqual(leadingTriviaKindAt(r, 0, 0), "block", "trivia-block: kind")
  assertEqual(leadingTriviaTextAt(r, 0, 0), "/* hi */", "trivia-block: text")
}

func testTriviaNewlineRun(): Unit {
  val r = lex("a\n\nb")
  // Tokens: a, STMT_END (synthesised), b, EOF.  Each `\n` becomes its
  // own TKNewline trivium so a formatter can preserve blank lines.
  // The trivia accumulated between two real tokens flushes onto the
  // first emit that follows — the synthetic STMT_END here — so both
  // newlines belong to STMT_END, and `b` has no leading trivia.
  assertEqual(tokenKindAt(r, 0), "ident", "trivia-nl: a is ident")
  assertEqualInt(leadingTriviaCount(r, 0), 0, "trivia-nl: a no trivia")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "trivia-nl: synth stmt_end")
  assertEqualInt(leadingTriviaCount(r, 1), 2, "trivia-nl: stmt_end picks up both newlines")
  assertEqual(leadingTriviaKindAt(r, 1, 0), "nl", "trivia-nl: first newline kind")
  assertEqual(leadingTriviaKindAt(r, 1, 1), "nl", "trivia-nl: second newline kind")
  assertEqual(tokenKindAt(r, 2), "ident", "trivia-nl: b is ident")
  assertEqualInt(leadingTriviaCount(r, 2), 0, "trivia-nl: b drained")
}

func testTriviaDocCommentNotInTrivia(): Unit {
  // Doc comments remain real tokens (TDocComment) — they must NOT be
  // captured as `TriviaKind.TKLineComment`.  Plain `//` line comments
  // before the doc comment do attach as trivia on the doc-comment
  // token, however.
  val r = lex("// plain\n/// doc\nfoo")
  // Tokens: TDocComment, foo, EOF.  `TDocComment` carries the plain
  // line-comment + newline as its leading trivia.
  assertEqual(tokenKindAt(r, 0), "doc", "trivia-doc: doc-comment is its own token")
  assertEqualInt(leadingTriviaCount(r, 0), 2, "trivia-doc: doc has plain comment + newline trivia")
  assertEqual(leadingTriviaKindAt(r, 0, 0), "line", "trivia-doc: leading line-comment")
  assertEqual(leadingTriviaTextAt(r, 0, 0), "// plain", "trivia-doc: leading text")
}

func testTriviaLossless(): Unit {
  // Round-trip a moderately mixed source through the lexer and verify
  // that the captured token + trivia text equals the (post-CRLF
  // normalised) input.  Doc-comment tokens have no `text` field on
  // SpannedToken, but their span covers the full `///…` lexeme so the
  // source-substring path reproduces them exactly.
  val src = "package P\n\n  // a comment\n  func f(): Unit { /* inline */ }\n"
  val r = lex(src)
  val rebuilt = reconstructSource(src, r)
  assertEqual(rebuilt, src, "trivia-rt: lossless round-trip")
}

func testFullPackageHeader(): Unit {
  val r = lex("package Foo.Bar\n\nimport Std.Core\n\nfunc add(x: in Int, y: in Int): Int {\n  x + y\n}\n")
  assertEqualInt(diagCount(r), 0, "full: no diagnostics")
  val last = r.tokens.count - 1
  assertEqual(tokenKindAt(r, last), "eof", "full: ends in eof")
  assertEqual(tokenKindAt(r, 0), "keyword", "full: package keyword")
  assertEqual(keywordSpellingAt(r, 0), "package", "full: package spelling")
  assertEqual(tokenKindAt(r, 1), "ident", "full: Foo ident")
  assertEqual(tokenKindAt(r, 2), "punct", "full: . punct")
  assertEqual(punctNameAt(r, 2), ".", "full: dot")
}

func main(): Unit {
  testEmptyInput()
  testIdentAndKeyword()
  testBoolKeyword()
  testDecimalInts()
  testHexOctBinInts()
  testIntSuffix()
  testLeadingZeroDecimalRejected()
  testFloatLiterals()
  testStringLiteral()
  testStringEscapes()
  testUnterminatedString()
  testUnicodeEscapeBmpRange()
  testUnicodeEscapeSurrogateRejected()
  testUnicodeEscapeNonBmpRejected()
  testInterpolatedString()
  testInterpolatedStringNoHoles()
  testTripleString()
  testUnterminatedTripleString()
  testRawStringNoHashes()
  testRawStringWithHashes()
  testUnterminatedRawString()
  testCharLiteral()
  testPunctuation()
  testStmtEndInsertion()
  testStmtEndSuppressedAfterOperator()
  testStmtEndSuppressedInsideBrackets()
  testExplicitSemicolon()
  testLineComment()
  testBlockComment()
  testUnterminatedBlockComment()
  testBareMinValueAbsLiteralFiresL0010()
  testTrulyOverflowingLiteralStillFiresL0010()
  testLineCommentSwallowsBlockOpen()
  testDocComment()
  testModuleDocComment()
  testCrlfNormalisation()
  testReservedUnderscoreUpperRejected()
  testReservedUnderscoreUpperPlaceholdersDistinct()
  testReservedUnderscoreLowerOK()
  testReservedUnderscoreDigitOK()
  testReservedUnderscoreAlone()
  testNonAsciiIdentifier()
  testCyrillicIdentifier()
  testIdentDigitsContinueOnly()
  testFullPackageHeader()
  testTriviaLeadingWhitespace()
  testTriviaLineComment()
  testTriviaBlockComment()
  testTriviaNewlineRun()
  testTriviaDocCommentNotInTrivia()
  testTriviaLossless()
  println("lexer self-test: ok")
}
