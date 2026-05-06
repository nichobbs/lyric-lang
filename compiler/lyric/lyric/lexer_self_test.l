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
// (underscore followed by an ASCII uppercase letter).  The lexeme
// still flows through as a TIdent so the parser can recover.
func testReservedUnderscoreUpperRejected(): Unit {
  val r = lex("_Hidden")
  assertEqual(tokenKindAt(r, 0), "ident", "L0040: still emitted as TIdent")
  assertEqual(identNameAt(r, 0), "_Hidden", "L0040: lexeme preserved")
  assertEqualInt(diagCount(r), 1, "L0040: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0040", "L0040: code")
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
  testDocComment()
  testModuleDocComment()
  testCrlfNormalisation()
  testReservedUnderscoreUpperRejected()
  testReservedUnderscoreLowerOK()
  testReservedUnderscoreDigitOK()
  testReservedUnderscoreAlone()
  testFullPackageHeader()
  println("lexer self-test: ok")
}
