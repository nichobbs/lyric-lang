//! lyric/lexer_self_test.l — Lyric.LexerSelfTest consumer of the
//! `Lyric.Lexer` library.  Run in CI via native `lyric test` (no F#
//! runner shim).
//!
//! Stage 2b of M5.1 split this out from the lexer module so
//! `Lyric.Lexer` is a reusable library.  The split exercises every
//! cross-package surface the M5.1 follow-up depends on (record field
//! access, union case match, function call, generic Option) end to end.
@test_module
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
    case TKeyword(_) -> "keyword"
    case TIdent(_) -> "ident"
    case TInt(_, _, _) -> "int"
    case TFloat(_, _, _) -> "float"
    case TChar(_) -> "char"
    case TString(_) -> "string"
    case TStringStart -> "string_start"
    case TStringPart(_) -> "string_part"
    case TStringHoleStart -> "string_hole_start"
    case TStringEnd -> "string_end"
    case TTripleString(_) -> "triple_string"
    case TRawString(_) -> "raw_string"
    case TBool(_) -> "bool"
    case TPunct(_) -> "punct"
    case TStmtEnd -> "stmt_end"
    case TDocComment(_) -> "doc"
    case TModuleDocComment(_) -> "module_doc"
    case TEof -> "eof"
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
    case TInt(v, _, _) -> v
    case _ -> -1i64
  }
}

func floatValueAt(lr: in LexResult, i: in Int): Double {
  match tokenAt(lr, i).token {
    case TFloat(v, _, _) -> v
    case _ -> -1.0
  }
}

func identNameAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TIdent(name) -> name
    case _ -> "<not-ident>"
  }
}

func stringValueAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TString(t) -> t
    case _ -> "<not-string>"
  }
}

func boolValueAt(lr: in LexResult, i: in Int): Bool {
  match tokenAt(lr, i).token {
    case TBool(b) -> b
    case _ -> false
  }
}

func stringPartAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TStringPart(t) -> t
    case _ -> "<not-string-part>"
  }
}

func tripleStringAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TTripleString(t) -> t
    case _ -> "<not-triple-string>"
  }
}

func rawStringAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TRawString(t) -> t
    case _ -> "<not-raw-string>"
  }
}

func charCodepointAt(lr: in LexResult, i: in Int): Int {
  match tokenAt(lr, i).token {
    case TChar(cp) -> cp
    case _ -> -1
  }
}

func keywordSpellingAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TKeyword(kw) -> keywordSpelling(kw)
    case _ -> "<not-keyword>"
  }
}

func punctNameAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TPunct(p) -> punctName(p)
    case _ -> "<not-punct>"
  }
}

func punctName(p: in Punct): String {
  match p {
    case DotDotEq -> "..="
    case DotDotLt -> "..<"
    case DotDot -> ".."
    case Arrow -> "->"
    case FatArrow -> "=>"
    case ColonColon -> "::"
    case Question -> "?"
    case QuestionQuestion -> "??"
    case At -> "@"
    case EqEq -> "=="
    case NotEq -> "!="
    case LtEq -> "<="
    case GtEq -> ">="
    case Lt -> "<"
    case Gt -> ">"
    case PlusEq -> "+="
    case MinusEq -> "-="
    case StarEq -> "*="
    case SlashEq -> "/="
    case PercentEq -> "%="
    case Plus -> "+"
    case Minus -> "-"
    case Star -> "*"
    case Slash -> "/"
    case Percent -> "%"
    case Eq -> "="
    case Bang -> "!"
    case Pipe -> "|"
    case Amp -> "&"
    case LParen -> "("
    case RParen -> ")"
    case LBracket -> "["
    case RBracket -> "]"
    case LBrace -> "{"
    case RBrace -> "}"
    case Comma -> ","
    case Semi -> ";"
    case Colon -> ":"
    case Dot -> "."
  }
}

func diagCount(lr: in LexResult): Int {
  lr.diagnostics.count
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
test "empty input" {
  val r = lex("")
  // Just an EOF.
  assertEqualInt(r.tokens.count, 1, "empty: token count")
  assertEqual(tokenKindAt(r, 0), "eof", "empty: only eof")
  assertEqualInt(diagCount(r), 0, "empty: no diagnostics")
}

test "ident and keyword" {
  val r = lex("foo bar package self")
  // foo, bar, package, self, EOF — no STMT_END (no newline).
  assertEqualInt(r.tokens.count, 5, "ident+kw: token count")
  assertEqual(tokenKindAt(r, 0), "ident", "ident+kw: foo is ident")
  assertEqual(identNameAt(r, 0), "foo", "ident+kw: foo name")
  assertEqual(tokenKindAt(r, 1), "ident", "ident+kw: bar is ident")
  assertEqual(identNameAt(r, 1), "bar", "ident+kw: bar name")
  assertEqual(tokenKindAt(r, 2), "keyword", "ident+kw: package is keyword")
  assertEqual(keywordSpellingAt(r, 2), "package", "ident+kw: package spelling")
  assertEqual(tokenKindAt(r, 3), "keyword", "ident+kw: self is keyword")
  assertEqual(keywordSpellingAt(r, 3), "self", "ident+kw: self spelling")
  assertEqual(tokenKindAt(r, 4), "eof", "ident+kw: trailing eof")
  assertEqualInt(diagCount(r), 0, "ident+kw: no diagnostics")
}

test "bool keyword" {
  val r = lex("true false")
  assertEqualInt(r.tokens.count, 3, "bool: token count")
  assertEqual(tokenKindAt(r, 0), "bool", "bool: true is bool token")
  assertTrue(boolValueAt(r, 0), "bool: true value")
  assertEqual(tokenKindAt(r, 1), "bool", "bool: false is bool token")
  assertTrue(not boolValueAt(r, 1), "bool: false value")
}

test "decimal ints" {
  val r = lex("0 42 1_000_000")
  assertEqualInt(r.tokens.count, 4, "decimal: token count (incl eof)")
  assertEqual(tokenKindAt(r, 0), "int", "decimal: 0 is int")
  assertTrue(intValueAt(r, 0) == 0i64, "decimal: 0 value")
  assertTrue(intValueAt(r, 1) == 42i64, "decimal: 42 value")
  assertTrue(intValueAt(r, 2) == 1000000i64, "decimal: underscore-separated")
}

test "hex oct bin ints" {
  val r = lex("0xFF 0o755 0b1010")
  assertEqualInt(r.tokens.count, 4, "based: token count")
  assertTrue(intValueAt(r, 0) == 255i64, "based: 0xFF")
  assertTrue(intValueAt(r, 1) == 493i64, "based: 0o755")
  assertTrue(intValueAt(r, 2) == 10i64, "based: 0b1010")
  assertEqualInt(diagCount(r), 0, "based: no diagnostics")
}

test "int suffix" {
  val r = lex("100u32 7i64")
  assertTrue(intValueAt(r, 0) == 100i64, "int-suffix: 100")
  assertTrue(intValueAt(r, 1) == 7i64, "int-suffix: 7")
  assertEqualInt(diagCount(r), 0, "int-suffix: no diagnostics")
}

test "leading zero decimal rejected" {
  val r = lex("0755")
  assertEqualInt(diagCount(r), 1, "leading-zero: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0012", "leading-zero: L0012")
}

test "float literals" {
  val r = lex("3.14 2.5e2 1.0f64")
  assertEqual(tokenKindAt(r, 0), "float", "float: 3.14 kind")
  assertTrue(floatValueAt(r, 0) > 3.13 and floatValueAt(r, 0) < 3.15, "float: 3.14 value")
  assertEqual(tokenKindAt(r, 1), "float", "float: 2.5e2 kind")
  assertTrue(floatValueAt(r, 1) > 249.9 and floatValueAt(r, 1) < 250.1, "float: 2.5e2 == 250")
  assertEqual(tokenKindAt(r, 2), "float", "float: 1.0f64 kind")
  assertTrue(floatValueAt(r, 2) > 0.99 and floatValueAt(r, 2) < 1.01, "float: 1.0f64 value")
  assertEqualInt(diagCount(r), 0, "float: no diagnostics")
}

test "float literal is correctly rounded" {
  // Pins the #5487/#5491 fix: parseDoubleLiteral delegates to the
  // correctly-rounded host parser (Double.Parse/InvariantCulture) instead
  // of the old left-to-right `value + digit*fracMul` accumulation, which
  // rounded `0.3` to 0.30000000000000004.  The nearest double to the
  // decimal 0.3 is strictly less than 0.1 + 0.2 (which rounds up), so the
  // two must NOT be bit-equal — that inequality is the correctness witness.
  val r = lex("0.3")
  assertEqual(tokenKindAt(r, 0), "float", "0.3 kind")
  assertFalse(floatValueAt(r, 0) == 0.1 + 0.2, "0.3 must be correctly rounded, not 0.1+0.2")
  assertTrue(floatValueAt(r, 0) > 0.29999999 and floatValueAt(r, 0) < 0.30000001, "0.3 within tight epsilon")
  assertEqualInt(diagCount(r), 0, "0.3: no diagnostics")
}

test "float literal with huge exponent is Infinity, not a hang" {
  // Pins the #5487/#5491 fix: an out-of-range exponent used to spin the
  // decimal-scaling loop ~10^9 times and hang the compiler.  The host
  // parser returns +Infinity instantly.  If this test returns at all, the
  // no-hang property holds; the value check confirms the Infinity result.
  val r = lex("1e999999999")
  assertEqual(tokenKindAt(r, 0), "float", "1e999999999 kind")
  assertTrue(floatValueAt(r, 0) > 1.0e308, "1e999999999 overflows to +Infinity")
  assertEqualInt(diagCount(r), 0, "1e999999999: no diagnostics")
}

test "string literal" {
  val r = lex("\"hello\"")
  assertEqual(tokenKindAt(r, 0), "string", "string: kind")
  assertEqual(stringValueAt(r, 0), "hello", "string: value")
  assertEqualInt(diagCount(r), 0, "string: no diagnostics")
}

test "string escapes" {
  val r = lex("\"a\\nb\\tc\\\\d\"")
  assertEqual(tokenKindAt(r, 0), "string", "string-esc: kind")
  assertEqual(stringValueAt(r, 0), "a\nb\tc\\d", "string-esc: value")
}

test "unterminated string" {
  val r = lex("\"oops")
  assertEqualInt(diagCount(r), 1, "unterm: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0025", "unterm: L0025")
}

// Unicode escapes in the full BMP must decode correctly.
// The surrogate range U+D800..U+DFFF must be rejected with L0023.
test "unicode escape bmp range" {
  // \u{80} — first non-ASCII BMP scalar.  Previously decoded to U+FFFD
  // under the 96-char ASCII lookup table.
  val r1 = lex("\"\\u{80}\"")
  assertEqualInt(diagCount(r1), 0, "u80: no diagnostics")
  assertEqual(stringValueAt(r1, 0), "", "u80: round-trips")

  // \u{00FF} — Latin-1 supplement boundary.
  val r2 = lex("\"\\u{00FF}\"")
  assertEqualInt(diagCount(r2), 0, "u00FF: no diagnostics")
  assertEqual(stringValueAt(r2, 0), "ÿ", "u00FF: round-trips")

  // \u{FFFF} — highest BMP scalar (last code point before surrogate
  // range, well above the surrogate range itself).
  val r3 = lex("\"\\u{FFFF}\"")
  assertEqualInt(diagCount(r3), 0, "uFFFF: no diagnostics")
  assertEqual(stringValueAt(r3, 0), "￿", "uFFFF: round-trips")
}

test "unicode escape surrogate rejected" {
  // U+D800 — first high (lead) surrogate.  Must produce L0023 (surrogate range)
  // and substitute U+FFFD without panicking.
  val r1 = lex("\"\\u{D800}\"")
  assertEqualInt(diagCount(r1), 1, "uD800: one diagnostic")
  assertEqual(r1.diagnostics[0].code, "L0023", "uD800: L0023")
  assertEqual(stringValueAt(r1, 0), "�", "uD800: U+FFFD substituted")

  // U+DFFF — last low (trail) surrogate.
  val r2 = lex("\"\\u{DFFF}\"")
  assertEqualInt(diagCount(r2), 1, "uDFFF: one diagnostic")
  assertEqual(r2.diagnostics[0].code, "L0023", "uDFFF: L0023")
  assertEqual(stringValueAt(r2, 0), "�", "uDFFF: U+FFFD substituted")
}

test "unicode escape non bmp in string accepted as surrogate pair" {
  // \u{1F600} — non-BMP scalar (😀).  String literals accept non-BMP via
  // UTF-16 surrogate-pair emission; no diagnostic should be recorded.
  val r = lex("\"\\u{1F600}\"")
  assertEqualInt(diagCount(r), 0, "u1F600-str: no diagnostics")
  assertEqual(stringValueAt(r, 0), "😀", "u1F600-str: emoji round-trips")
}

test "unicode escape non bmp in char literal rejected" {
  // '\u{1F600}' — non-BMP in a char literal.  Char is a single UTF-16
  // code unit so a non-BMP code point cannot be expressed; L0022.
  val r = lex("'\\u{1F600}'")
  assertEqualInt(diagCount(r), 1, "u1F600-char: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0022", "u1F600-char: L0022")
  assertEqualInt(charCodepointAt(r, 0), 0xFFFD, "u1F600-char: U+FFFD substituted")
}

test "unicode escape non bmp in interpolated string accepted" {
  // "\u{1F600}${x}" — non-BMP in a string literal that also has an
  // interpolation hole.  The escape is in the leading chunk (TStringPart)
  // and must emit a surrogate pair; the hole is unaffected.
  val r = lex("\"\\u{1F600}\${x}\"")
  assertEqualInt(diagCount(r), 0, "u1F600-interp: no diagnostics")
  assertEqual(tokenKindAt(r, 0), "string_start", "u1F600-interp: TStringStart")
  assertEqual(tokenKindAt(r, 1), "string_part", "u1F600-interp: TStringPart")
  assertEqual(stringPartAt(r, 1), "😀", "u1F600-interp: chunk has emoji")
  assertEqual(tokenKindAt(r, 2), "string_hole_start", "u1F600-interp: TStringHoleStart")
}

test "unicode escape non bmp in triple string accepted" {
  // """\u{1F600}""" — non-BMP in a triple-quoted string literal.
  // The escape must emit a surrogate pair; no diagnostic.
  val r = lex("\"\"\"\\u{1F600}\"\"\"")
  assertEqualInt(diagCount(r), 0, "u1F600-triple: no diagnostics")
  assertEqual(tokenKindAt(r, 0), "triple_string", "u1F600-triple: TTripleString")
  assertEqual(tripleStringAt(r, 0), "😀", "u1F600-triple: body has emoji")
}

// Phase 5 §M5.1 stage 3 — interpolated / triple / raw strings.
//
// Note on quoting: every time the body of a `lex(...)` call below
// contains a `${`, the bootstrap lexer (parsing this source file)
// would otherwise interpret it as its own interpolation hole.  The
// `\$` escape in the outer string keeps the bootstrap from doing
// that — the lexer-under-test still sees a literal `${` because
// `\$` decodes to `$`.
test "interpolated string" {
  // The string passed to `lex` is `"hello, ${name}"` — three logical
  // chunks: the literal `hello, `, the hole's expression token (an
  // ident), and the closing sequence.  Tokens: TStringStart,
  // TStringPart, TStringHoleStart, TIdent, TPunct(}), TStringEnd,
  // TEof.
  val r = lex("\"hello, \${name}\"")
  assertEqualInt(diagCount(r), 0, "interp: no diagnostics")
  assertEqual(tokenKindAt(r, 0), "string_start", "interp: TStringStart")
  assertEqual(tokenKindAt(r, 1), "string_part", "interp: TStringPart")
  assertEqual(stringPartAt(r, 1), "hello, ", "interp: chunk text")
  assertEqual(tokenKindAt(r, 2), "string_hole_start", "interp: TStringHoleStart")
  assertEqual(tokenKindAt(r, 3), "ident", "interp: hole ident")
  assertEqual(tokenKindAt(r, 4), "punct", "interp: closing }")
  assertEqual(tokenKindAt(r, 5), "string_end", "interp: TStringEnd")
}

test "interpolated string no holes" {
  // No `${`, so the simple `TString` path runs even though the
  // dispatcher consulted `hasInterpolation`.
  val r = lex("\"plain ascii\"")
  assertEqual(tokenKindAt(r, 0), "string", "interp-fallback: simple TString")
  assertEqual(stringValueAt(r, 0), "plain ascii", "interp-fallback: text")
}

test "triple string" {
  val r = lex("\"\"\"line1\nline2\"\"\"")
  assertEqualInt(diagCount(r), 0, "triple: no diagnostics")
  assertEqual(tokenKindAt(r, 0), "triple_string", "triple: TTripleString")
  assertEqual(tripleStringAt(r, 0), "line1\nline2", "triple: body preserved")
}

test "unterminated triple string" {
  val r = lex("\"\"\"missing close")
  assertEqualInt(diagCount(r), 1, "unterm-triple: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0026", "unterm-triple: L0026")
}

test "raw string no hashes" {
  val r = lex("r\"raw\\nbody\"")
  assertEqualInt(diagCount(r), 0, "raw: no diagnostics")
  assertEqual(tokenKindAt(r, 0), "raw_string", "raw: TRawString")
  // No escape processing — the literal `\n` survives as two chars.
  assertEqual(rawStringAt(r, 0), "raw\\nbody", "raw: body byte-for-byte")
}

test "raw string with hashes" {
  val r = lex("r#\"with \"quotes\"\"#")
  assertEqualInt(diagCount(r), 0, "raw#: no diagnostics")
  assertEqual(tokenKindAt(r, 0), "raw_string", "raw#: TRawString")
  assertEqual(rawStringAt(r, 0), "with \"quotes\"", "raw#: embedded quotes")
}

test "unterminated raw string" {
  val r = lex("r\"oops")
  assertEqualInt(diagCount(r), 1, "unterm-raw: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0028", "unterm-raw: L0028")
}

test "char literal" {
  val r = lex("'a' '\\n'")
  assertEqual(tokenKindAt(r, 0), "char", "char: 'a' kind")
  assertEqualInt(charCodepointAt(r, 0), 97, "char: 'a' codepoint")
  assertEqual(tokenKindAt(r, 1), "char", "char: '\\n' kind")
  assertEqualInt(charCodepointAt(r, 1), 10, "char: '\\n' codepoint")
}

test "punctuation" {
  val r = lex("-> => ..= < <= == != +=")
  assertEqual(punctNameAt(r, 0), "->", "punct: ->")
  assertEqual(punctNameAt(r, 1), "=>", "punct: =>")
  assertEqual(punctNameAt(r, 2), "..=", "punct: ..=")
  assertEqual(punctNameAt(r, 3), "<", "punct: <")
  assertEqual(punctNameAt(r, 4), "<=", "punct: <=")
  assertEqual(punctNameAt(r, 5), "==", "punct: ==")
  assertEqual(punctNameAt(r, 6), "!=", "punct: !=")
  assertEqual(punctNameAt(r, 7), "+=", "punct: +=")
}

test "stmt end insertion" {
  val r = lex("foo\nbar")
  assertEqualInt(r.tokens.count, 4, "stmt-end: foo STMT_END bar EOF")
  assertEqual(tokenKindAt(r, 0), "ident", "stmt-end: foo")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "stmt-end: synthesised")
  assertEqual(tokenKindAt(r, 2), "ident", "stmt-end: bar")
}

test "stmt end suppressed after operator" {
  val r = lex("a +\nb")
  assertEqualInt(r.tokens.count, 4, "stmt-end suppressed: token count")
  assertEqual(tokenKindAt(r, 0), "ident", "stmt-end suppressed: a")
  assertEqual(tokenKindAt(r, 1), "punct", "stmt-end suppressed: +")
  assertEqual(tokenKindAt(r, 2), "ident", "stmt-end suppressed: b — no STMT_END between + and b")
}

test "stmt end suppressed inside brackets" {
  val r = lex("(a\nb)")
  assertEqualInt(r.tokens.count, 5, "brackets: token count")
  assertEqual(tokenKindAt(r, 0), "punct", "brackets: (")
  assertEqual(tokenKindAt(r, 1), "ident", "brackets: a")
  assertEqual(tokenKindAt(r, 2), "ident", "brackets: b")
  assertEqual(tokenKindAt(r, 3), "punct", "brackets: )")
}

test "explicit semicolon" {
  val r = lex("a;b")
  assertEqualInt(r.tokens.count, 4, "semi: token count")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "semi: STMT_END from ;")
}

test "line comment" {
  val r = lex("foo // ignored\nbar")
  assertEqualInt(r.tokens.count, 4, "line comment: foo STMT_END bar EOF")
  assertEqual(tokenKindAt(r, 0), "ident", "line comment: foo")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "line comment: STMT_END after newline")
  assertEqual(tokenKindAt(r, 2), "ident", "line comment: bar")
}

test "block comment" {
  val r = lex("foo /* /* nested */ */ bar")
  assertEqualInt(r.tokens.count, 3, "block comment: token count")
  assertEqual(identNameAt(r, 0), "foo", "block comment: foo")
  assertEqual(identNameAt(r, 1), "bar", "block comment: bar")
  assertEqualInt(diagCount(r), 0, "block comment: no diagnostics")
}

test "unterminated block comment" {
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
test "bare min value abs literal fires l0010" {
  val r = lex("val x = 9223372036854775808")
  assertTrue(diagCount(r) >= 1, "9223372036854775808: L0010 fires")
  var sawL0010 = false
  var i = 0
  while i < r.diagnostics.count {
    if r.diagnostics[i].code == "L0010" {
      sawL0010 = true
    }
    i = i + 1
  }
  assertTrue(sawL0010, "9223372036854775808: L0010 present")
  // The bit pattern is preserved so `-9223372036854775808` downstream
  // can produce Long.MinValue — that's a separate parser test.
  // The literal itself is the third token (val, ident, =, int).
  assertEqual(tokenKindAt(r, 3), "int", "9223372036854775808: TInt emitted")
  assertTrue(intValueAt(r, 3) == -9223372036854775808i64, "9223372036854775808: bit pattern is Long.MinValue")
}

// Sanity check that other huge literals still hit the regular
// overflow path (not the MinValue special case).
test "truly overflowing literal still fires l0010" {
  val r = lex("val x = 9223372036854775809")  // one past Long.MaxValue+1
  var sawL0010 = false
  var i = 0
  while i < r.diagnostics.count {
    if r.diagnostics[i].code == "L0010" {
      sawL0010 = true
    }
    i = i + 1
  }
  assertTrue(sawL0010, "regular overflow: L0010 present")
  assertEqual(tokenKindAt(r, 3), "int", "regular overflow: TInt emitted (value 0)")
  assertTrue(intValueAt(r, 3) == 0i64, "regular overflow: value substituted with 0")
}

// #7839: a `u64` literal takes the full unsigned 64-bit range; a value
// from 2^63 to 2^64-1 is carried as its two's-complement pattern.
func sawDiag(r: in LexResult, code: in String): Bool {
  var i = 0
  while i < r.diagnostics.count {
    if r.diagnostics[i].code == code {
      return true
    }
    i = i + 1
  }
  false
}

func suffixAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TInt(_, sfx, _) -> match sfx {
      case U32 -> "u32"
      case U64 -> "u64"
      case I64 -> "i64"
      case NoIntSuffix -> ""
      case _ -> "other"
    }
    case _ -> "not-int"
  }
}

test "u64 literals span the full unsigned range" {
  val zero = lex("0u64")
  assertEqualInt(diagCount(zero), 0, "0u64: no diagnostics")
  assertTrue(intValueAt(zero, 0) == 0i64, "0u64: value 0")
  assertEqual(suffixAt(zero, 0), "u64", "0u64: suffix")

  val maxSigned = lex("9223372036854775807u64")
  assertEqualInt(diagCount(maxSigned), 0, "2^63-1 u64: no diagnostics")
  assertTrue(intValueAt(maxSigned, 0) == 9223372036854775807i64, "2^63-1 u64: value")

  val half = lex("9223372036854775808u64")
  assertEqualInt(diagCount(half), 0, "2^63 u64: no L0010")
  assertTrue(intValueAt(half, 0) == -9223372036854775808i64, "2^63 u64: pattern is Long.MinValue")

  val max = lex("18446744073709551615u64")
  assertEqualInt(diagCount(max), 0, "2^64-1 u64: no L0010")
  assertTrue(intValueAt(max, 0) == -1i64, "2^64-1 u64: pattern is -1")

  val underscored = lex("18_446_744_073_709_551_614u64")
  assertEqualInt(diagCount(underscored), 0, "2^64-2 u64 with underscores: no L0010")
  assertTrue(intValueAt(underscored, 0) == -2i64, "2^64-2 u64: pattern is -2")
}

test "u64 hex binary and octal literals span the full unsigned range" {
  val hex = lex("0xFFFF_FFFF_FFFF_FFFFu64")
  assertEqualInt(diagCount(hex), 0, "0xFFFFFFFFFFFFFFFFu64: no L0010")
  assertTrue(intValueAt(hex, 0) == -1i64, "0xFFFFFFFFFFFFFFFFu64: pattern is -1")
  assertEqual(suffixAt(hex, 0), "u64", "0xFFFFFFFFFFFFFFFFu64: suffix")

  val hexHalf = lex("0x8000000000000000u64")
  assertEqualInt(diagCount(hexHalf), 0, "0x8000000000000000u64: no L0010")
  assertTrue(intValueAt(hexHalf, 0) == -9223372036854775808i64, "0x8000000000000000u64: Long.MinValue pattern")

  val oct = lex("0o1777777777777777777777u64")
  assertEqualInt(diagCount(oct), 0, "octal 2^64-1 u64: no L0010")
  assertTrue(intValueAt(oct, 0) == -1i64, "octal 2^64-1 u64: pattern is -1")

  val bin = lex("0b1000000000000000000000000000000000000000000000000000000000000001u64")
  assertEqualInt(diagCount(bin), 0, "binary 2^63+1 u64: no L0010")
  assertTrue(intValueAt(bin, 0) == -9223372036854775807i64, "binary 2^63+1 u64: pattern")
}

test "u64 literals above 2^64-1 fire l0010" {
  val over = lex("18446744073709551616u64")
  assertTrue(sawDiag(over, "L0010"), "2^64 u64: L0010")
  assertTrue(intValueAt(over, 0) == 0i64, "2^64 u64: value substituted with 0")

  val hexOver = lex("0x1_0000_0000_0000_0000u64")
  assertTrue(sawDiag(hexOver, "L0010"), "0x10000000000000000u64: L0010")

  val far = lex("99999999999999999999999u64")
  assertTrue(sawDiag(far, "L0010"), "far past 2^64 u64: L0010")
}

test "signed and unsuffixed literals keep the signed 64-bit range" {
  val hex = lex("0xFFFFFFFFFFFFFFFF")
  assertTrue(sawDiag(hex, "L0010"), "unsuffixed 0xFFFFFFFFFFFFFFFF: L0010")
  val i64Over = lex("18446744073709551615i64")
  assertTrue(sawDiag(i64Over, "L0010"), "2^64-1 i64: L0010")
  val bareHalf = lex("9223372036854775808i64")
  assertTrue(sawDiag(bareHalf, "L0010"), "bare 2^63 i64: L0010")
}

// #7847: a signed suffix bounds its literal's magnitude by the signed
// maximum in every base.  One past the maximum is the minimum's magnitude:
// L0010 here, carried with its value so the parser can cancel the
// diagnostic under a unary minus (`-128i8`, parser_self_test.l).  Anything
// larger is L0010 with the value substituted by 0.
func checkSigned(src: in String, clean: in Bool, want: in Long, label: in String): Unit {
  val r = lex(src)
  if clean {
    assertEqualInt(diagCount(r), 0, label + ": no diagnostics")
  } else {
    assertTrue(sawDiag(r, "L0010"), label + ": L0010")
  }
  assertTrue(intValueAt(r, 0) == want, label + ": value")
}

test "i8 literals are bounded by the signed 8-bit range" {
  checkSigned("127i8", true, 127i64, "127i8")
  checkSigned("128i8", false, 128i64, "128i8 (minimum's magnitude)")
  checkSigned("129i8", false, 0i64, "129i8")
  checkSigned("300i8", false, 0i64, "300i8")
  checkSigned("0x7Fi8", true, 127i64, "0x7Fi8")
  checkSigned("0x80i8", false, 128i64, "0x80i8 (minimum's magnitude)")
  checkSigned("0x81i8", false, 0i64, "0x81i8")
  checkSigned("0xFFi8", false, 0i64, "0xFFi8 (a magnitude, not a bit pattern)")
  checkSigned("0b0111_1111i8", true, 127i64, "0b01111111i8")
  checkSigned("0b1000_0000i8", false, 128i64, "0b10000000i8 (minimum's magnitude)")
  checkSigned("0b1000_0001i8", false, 0i64, "0b10000001i8")
  checkSigned("0o177i8", true, 127i64, "0o177i8")
  checkSigned("0o201i8", false, 0i64, "0o201i8")
}

test "i16 literals are bounded by the signed 16-bit range" {
  checkSigned("32767i16", true, 32767i64, "32767i16")
  checkSigned("32768i16", false, 32768i64, "32768i16 (minimum's magnitude)")
  checkSigned("32769i16", false, 0i64, "32769i16")
  checkSigned("0x7FFFi16", true, 32767i64, "0x7FFFi16")
  checkSigned("0x8000i16", false, 32768i64, "0x8000i16 (minimum's magnitude)")
  checkSigned("0x8001i16", false, 0i64, "0x8001i16")
  checkSigned("0xFFFFi16", false, 0i64, "0xFFFFi16")
  checkSigned("0b0111_1111_1111_1111i16", true, 32767i64, "0b0111111111111111i16")
  checkSigned("0b1000_0000_0000_0000i16", false, 32768i64, "0b1000000000000000i16 (minimum's magnitude)")
  checkSigned("0b1000_0000_0000_0001i16", false, 0i64, "0b1000000000000001i16")
}

test "i32 literals are bounded by the signed 32-bit range" {
  checkSigned("2147483647i32", true, 2147483647i64, "2147483647i32")
  checkSigned("2147483648i32", false, 2147483648i64, "2147483648i32 (minimum's magnitude)")
  checkSigned("2147483649i32", false, 0i64, "2147483649i32")
  checkSigned("3000000000i32", false, 0i64, "3000000000i32")
  checkSigned("0x7FFF_FFFFi32", true, 2147483647i64, "0x7FFFFFFFi32")
  checkSigned("0x8000_0000i32", false, 2147483648i64, "0x80000000i32 (minimum's magnitude)")
  checkSigned("0x8000_0001i32", false, 0i64, "0x80000001i32")
  checkSigned("0xFFFF_FFFFi32", false, 0i64, "0xFFFFFFFFi32")
  checkSigned("0b0111_1111_1111_1111_1111_1111_1111_1111i32", true, 2147483647i64, "binary 2^31-1 i32")
  checkSigned(
    "0b1000_0000_0000_0000_0000_0000_0000_0000i32",
    false,
    2147483648i64,
    "binary 2^31 i32 (minimum's magnitude)"
  )
  checkSigned("0b1000_0000_0000_0000_0000_0000_0000_0001i32", false, 0i64, "binary 2^31+1 i32")
}

test "i64 and unsuffixed literals are bounded by the signed 64-bit range" {
  checkSigned("9223372036854775807i64", true, 9223372036854775807i64, "2^63-1 i64")
  checkSigned("9223372036854775808i64", false, -9223372036854775808i64, "2^63 i64 (minimum's magnitude)")
  checkSigned("9223372036854775809i64", false, 0i64, "2^63+1 i64")
  checkSigned("0x7FFF_FFFF_FFFF_FFFFi64", true, 9223372036854775807i64, "0x7FFFFFFFFFFFFFFFi64")
  checkSigned("0x8000_0000_0000_0000i64", false, -9223372036854775808i64, "0x8000000000000000i64 (minimum's magnitude)")
  checkSigned("0x8000_0000_0000_0001i64", false, 0i64, "0x8000000000000001i64")
  checkSigned(
    "0b1000000000000000000000000000000000000000000000000000000000000000i64",
    false,
    -9223372036854775808i64,
    "binary 2^63 i64 (minimum's magnitude)"
  )
  checkSigned("0b1000000000000000000000000000000000000000000000000000000000000001i64", false, 0i64, "binary 2^63+1 i64")
  checkSigned(
    "0x8000_0000_0000_0000",
    false,
    -9223372036854775808i64,
    "unsuffixed 0x8000000000000000 (minimum's magnitude)"
  )
  checkSigned("2147483648", true, 2147483648i64, "unsuffixed 2^31 is an ordinary Long")
}

test "signed literal l0010 names the suffix range" {
  val over = lex("300i8")
  assertTrue(over.diagnostics.count == 1, "300i8: one diagnostic")
  assertTrue(Str.contains(over.diagnostics[0].message, "`i8` (-128 ..= 127)"), "300i8: message names the i8 range")
  val minMag = lex("2147483648i32")
  assertTrue(
    Str.contains(minMag.diagnostics[0].message, "`-2147483648i32`"),
    "2147483648i32: message shows the minimum's spelling"
  )
  val longOver = lex("9223372036854775809")
  assertTrue(
    Str.contains(longOver.diagnostics[0].message, "`Long` (-9223372036854775808 ..= 9223372036854775807)"),
    "unsuffixed overflow: message names the Long range"
  )
}

test "narrow unsigned literals are bounded by their type" {
  val u32Max = lex("4294967295u32")
  assertEqualInt(diagCount(u32Max), 0, "4294967295u32: no diagnostics")
  assertTrue(intValueAt(u32Max, 0) == 4294967295i64, "4294967295u32: value")
  val u32Hex = lex("0xFFFF_FFFFu32")
  assertEqualInt(diagCount(u32Hex), 0, "0xFFFFFFFFu32: no diagnostics")
  assertTrue(intValueAt(u32Hex, 0) == 4294967295i64, "0xFFFFFFFFu32: value")
  val u32Over = lex("4294967296u32")
  assertTrue(sawDiag(u32Over, "L0010"), "4294967296u32: L0010")
  assertTrue(intValueAt(u32Over, 0) == 0i64, "4294967296u32: value substituted with 0")
  val u16Over = lex("65536u16")
  assertTrue(sawDiag(u16Over, "L0010"), "65536u16: L0010")
  val u16Max = lex("65535u16")
  assertEqualInt(diagCount(u16Max), 0, "65535u16: no diagnostics")
  val u8Over = lex("0x100u8")
  assertTrue(sawDiag(u8Over, "L0010"), "0x100u8: L0010")
  val u8Max = lex("255u8")
  assertEqualInt(diagCount(u8Max), 0, "255u8: no diagnostics")
}

// #425 item 2: a `// /*` sequence inside a line comment must NOT
// open a block comment.  The line-comment scanner is checked before
// the block-comment scanner (`skipTrivia` dispatch order), so a
// leading `//` claims the whole line — the `/*` is just comment text.
// Regression test: `foo // /*\nbar` must produce two real tokens
// (foo, bar) and no unterminated-comment diagnostic.
test "line comment swallows block open" {
  val r = lex("foo // /*\nbar")
  assertEqualInt(diagCount(r), 0, "line // /*: no unterminated-block diagnostic")
  assertEqual(tokenKindAt(r, 0), "ident", "line // /*: foo")
  assertEqual(identNameAt(r, 0), "foo", "line // /*: foo name")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "line // /*: STMT_END after newline")
  assertEqual(tokenKindAt(r, 2), "ident", "line // /*: bar")
  assertEqual(identNameAt(r, 2), "bar", "line // /*: bar name")
}

test "doc comment" {
  val r = lex("/// documentation\nfoo")
  assertEqualInt(r.tokens.count, 4, "doc: doc STMT_END foo EOF")
  assertEqual(tokenKindAt(r, 0), "doc", "doc: kind")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "doc: STMT_END after newline")
  assertEqual(identNameAt(r, 2), "foo", "doc: foo follows")
}

test "module doc comment" {
  val r = lex("//! module overview\n")
  assertEqualInt(r.tokens.count, 3, "module doc: token count")
  assertEqual(tokenKindAt(r, 0), "module_doc", "module doc: kind")
}

test "crlf normalisation" {
  val r = lex("foo\r\nbar")
  assertEqualInt(r.tokens.count, 4, "crlf: token count")
  assertEqual(tokenKindAt(r, 0), "ident", "crlf: foo")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "crlf: STMT_END")
  assertEqual(tokenKindAt(r, 2), "ident", "crlf: bar")
}

// Phase 5 §M5.1 stage 4 — L0040 reserved-name diagnostic for `_X`
// (underscore followed by an ASCII uppercase letter).  #425 item 1
// hardened the lexer so the rejected lexeme is rewritten to a
// `__error_<offset>` placeholder before TIdent emission; this prevents
// the original `_Foo` lexeme from clashing with compiler-generated
// names like `_Async` / `_StateMachine` further down the pipeline.
test "reserved underscore upper rejected" {
  val r = lex("_Hidden")
  assertEqual(tokenKindAt(r, 0), "ident", "L0040: still emitted as TIdent")
  assertEqual(identNameAt(r, 0), "__error_0", "L0040: lexeme rewritten to placeholder (offset 0)")
  assertEqualInt(diagCount(r), 1, "L0040: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0040", "L0040: code")
}

// #425 item 1: each `_UpperCase` occurrence gets a span-keyed
// placeholder, so two rejections in the same source produce distinct
// TIdent names that cannot clash with each other or with the
// `_StateMachine` / `_Async` family of compiler-generated names.
test "reserved underscore upper placeholders distinct" {
  val r = lex("_Foo  _Bar")
  assertEqualInt(diagCount(r), 2, "L0040: two diagnostics")
  assertEqual(identNameAt(r, 0), "__error_0", "L0040: first placeholder")
  // `_Bar` starts at byte offset 6 ("_Foo  " is six bytes).
  assertEqual(identNameAt(r, 1), "__error_6", "L0040: second placeholder")
}

test "reserved underscore lower ok" {
  // Underscore followed by a *lowercase* letter is fine — those
  // aren't compiler-generated.
  val r = lex("_hidden")
  assertEqualInt(diagCount(r), 0, "L0040: no diagnostic for _hidden")
}

test "reserved underscore digit ok" {
  // Underscore + digit is also fine (e.g. `_0` is a destructured
  // tuple slot in some style guides).
  val r = lex("_0name")
  assertEqualInt(diagCount(r), 0, "L0040: no diagnostic for _0…")
}

test "reserved underscore alone" {
  // Pure underscore is the wildcard pattern; no diagnostic.
  val r = lex("_")
  assertEqualInt(diagCount(r), 0, "L0040: no diagnostic for `_`")
}

// Phase 5 §M5.1 stage 4 — non-ASCII (UAX #31 XID_Start /
// XID_Continue) identifier acceptance via `Std.UnicodeHost`'s
// `System.Char.GetUnicodeCategory` extern.
test "non ascii identifier" {
  // Greek-letter identifier — `α` is `LowercaseLetter`,
  // `β` is `LowercaseLetter`.  No diagnostics; one TIdent token.
  val r = lex("αβ")
  assertEqualInt(diagCount(r), 0, "uax31: greek ident no diagnostics")
  assertEqual(tokenKindAt(r, 0), "ident", "uax31: TIdent kind")
  assertEqual(identNameAt(r, 0), "αβ", "uax31: lexeme preserved")
}

test "cyrillic identifier" {
  // Cyrillic capital letter `И` (U+0418) is `UppercaseLetter`;
  // followed by lowercase `и` (U+0438) which is `LowercaseLetter`.
  val r = lex("Ии")
  assertEqualInt(diagCount(r), 0, "uax31: cyrillic ident no diagnostics")
  assertEqual(tokenKindAt(r, 0), "ident", "uax31: TIdent kind")
}

test "ident digits continue only" {
  // `α0` — letter then ASCII digit.  Digits are XID_Continue but
  // not XID_Start, so the leading letter is required.  Should
  // produce one TIdent.
  val r = lex("α0")
  assertEqualInt(diagCount(r), 0, "uax31: letter+digit no diagnostics")
  assertEqual(tokenKindAt(r, 0), "ident", "uax31: starts as TIdent")
  assertEqual(identNameAt(r, 0), "α0", "uax31: digits trail")
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
    case TKWhitespace -> "ws"
    case TKNewline -> "nl"
    case TKLineComment -> "line"
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

test "trivia leading whitespace" {
  val r = lex("   foo")
  // Tokens: foo, EOF.  `foo` carries the leading "   " whitespace.
  assertEqual(tokenKindAt(r, 0), "ident", "trivia-ws: ident")
  assertEqualInt(leadingTriviaCount(r, 0), 1, "trivia-ws: one trivium")
  assertEqual(leadingTriviaKindAt(r, 0, 0), "ws", "trivia-ws: kind")
  assertEqual(leadingTriviaTextAt(r, 0, 0), "   ", "trivia-ws: text")
}

test "trivia line comment" {
  val r = lex("// hi\nfoo")
  // Tokens: foo, EOF.  Leading trivia on `foo`: line-comment then newline.
  assertEqual(tokenKindAt(r, 0), "ident", "trivia-line: ident")
  assertEqualInt(leadingTriviaCount(r, 0), 2, "trivia-line: two trivia")
  assertEqual(leadingTriviaKindAt(r, 0, 0), "line", "trivia-line: comment kind")
  assertEqual(leadingTriviaTextAt(r, 0, 0), "// hi", "trivia-line: comment text")
  assertEqual(leadingTriviaKindAt(r, 0, 1), "nl", "trivia-line: newline kind")
  assertEqual(leadingTriviaTextAt(r, 0, 1), "\n", "trivia-line: newline text")
}

test "trivia block comment" {
  val r = lex("/* hi */foo")
  // Tokens: foo, EOF.  Leading trivia on `foo`: block-comment.
  assertEqual(tokenKindAt(r, 0), "ident", "trivia-block: ident")
  assertEqualInt(leadingTriviaCount(r, 0), 1, "trivia-block: one trivium")
  assertEqual(leadingTriviaKindAt(r, 0, 0), "block", "trivia-block: kind")
  assertEqual(leadingTriviaTextAt(r, 0, 0), "/* hi */", "trivia-block: text")
}

test "trivia newline run" {
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

test "trivia doc comment not in trivia" {
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

test "trivia lossless" {
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

test "full package header" {
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

// D-progress-1006 — supplementary-plane characters typed directly into the
// source.  They are UTF-16 surrogate pairs, and a surrogate half is not a
// `Char`, so the lexer reads code units rather than indexing `source[i]`
// (which would fail on the first half).  These cases pin that literal
// emoji in every text-carrying position lex cleanly and round-trip intact.
func docTextAt(lr: in LexResult, i: in Int): String {
  match tokenAt(lr, i).token {
    case TDocComment(t) -> t
    case _ -> "<not doc>"
  }
}

test "literal emoji in a string literal round-trips" {
  val r = lex("\"a😀b\"")
  assertEqualInt(diagCount(r), 0, "emoji-str: no diagnostics")
  assertEqual(stringValueAt(r, 0), "a😀b", "emoji-str: text intact")
  assertEqualInt(stringValueAt(r, 0).length, 4, "emoji-str: surrogate pair kept (4 code units)")
}

test "literal emoji in interpolated, triple and raw strings round-trip" {
  val interp = lex("\"😀\${x}🎉\"")
  assertEqualInt(diagCount(interp), 0, "emoji-interp: no diagnostics")
  assertEqual(stringPartAt(interp, 1), "😀", "emoji-interp: leading chunk")
  val triple = lex("\"\"\"line 😀\nnext\"\"\"")
  assertEqualInt(diagCount(triple), 0, "emoji-triple: no diagnostics")
  assertEqual(tripleStringAt(triple, 0), "line 😀\nnext", "emoji-triple: body intact")
  val raw = lex("r#\"😀\"#")
  assertEqualInt(diagCount(raw), 0, "emoji-raw: no diagnostics")
  assertEqual(rawStringAt(raw, 0), "😀", "emoji-raw: body intact")
}

test "literal emoji in comments is skipped" {
  val r = lex("// 😀 line comment\n/* 🎉 block */ x")
  assertEqualInt(diagCount(r), 0, "emoji-comment: no diagnostics")
  assertEqual(identNameAt(r, 0), "x", "emoji-comment: ident after comments")
  val d = lex("/// doc 😀\nfunc f() {}")
  assertEqualInt(diagCount(d), 0, "emoji-doc: no diagnostics")
  assertEqual(docTextAt(d, 0), "doc 😀", "emoji-doc: doc text intact")
}

test "literal emoji in a char literal is L0022" {
  val r = lex("'😀'")
  assertEqualInt(diagCount(r), 1, "emoji-char: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0022", "emoji-char: L0022")
  assertEqualInt(charCodepointAt(r, 0), 0xFFFD, "emoji-char: U+FFFD substituted")
}

test "a stray emoji is one unexpected character" {
  val r = lex("x 😀 y")
  assertEqualInt(diagCount(r), 1, "emoji-stray: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0030", "emoji-stray: L0030")
  assertEqual(r.diagnostics[0].message, "unexpected character '😀'", "emoji-stray: whole character reported")
  assertEqual(identNameAt(r, 1), "y", "emoji-stray: lexing resumes")
}
