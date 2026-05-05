// lyric/lexer.l — first slice of a self-hosted Lyric lexer.
//
// Mirrors the F# bootstrap lexer at compiler/src/Lyric.Lexer/Lexer.fs:
// produces the same token stream over a UTF-8 source string, applies the
// same statement-terminator-insertion rules, records the same diagnostic
// codes for malformed input.  Phase 5 §M5.1 calls for the lexer to be
// the first compiler component to leave F# behind; this file is the
// opening down-payment on that work.
//
// Scope deferred to a follow-up pass (so the v0.1 self-host stays
// readable):
//   * String interpolation (`"…${expr}…"` → multi-token sequence).
//   * Triple-quoted (`"""…"""`) and raw (`r"…"` / `r#"…"#`) strings.
//   * Non-BMP `\u{…}` escapes (would need a wider TChar payload).
//   * Non-ASCII identifiers and NFC normalisation.
//   * The `_X` reserved-name diagnostic (L0040).
//
// Everything else from the F# lexer's grammar §1 implementation lives
// here: identifiers, the full keyword table, decimal/hex/octal/binary
// integer literals (with underscore separators and type suffixes), float
// literals (with optional exponent and `f32`/`f64` suffix), single-quoted
// string literals with the common escape set, character literals, the
// full punctuation table, line + nested block comments, doc/module-doc
// comments, and statement-end insertion with the same suppression set
// used by the bootstrap.
//
// Stage 1 of M5.1 deliberately avoided several patterns the
// bootstrap couldn't yet handle (or-patterns, nested constructor
// patterns, tuple destructuring, bare non-Unit-returning calls in
// statement position, `Option[T]` over a TypeBuilder type-arg, and
// cross-package field reads on imported records).  The bootstrap
// has since gained all of these; the lexer continues to live in a
// single package alongside its self-test until M5.1 stage 2b
// finishes the library split — see `docs/19-multi-file-packages.md`.
package Lyric.LexerSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Position and Span — mirror compiler/src/Lyric.Lexer/Span.fs.
// ─────────────────────────────────────────────────────────────────────────────

/// A position in source.  `offset` is a 0-based UTF-16 code-unit offset
/// into the (already CR/LF-normalised) source string; `line` and
/// `column` are 1-based.
@stable(since="0.1")
pub record Position {
  offset: Int
  line:   Int
  column: Int
}

@stable(since="0.1")
pub func initialPosition(): Position {
  Position(offset = 0, line = 1, column = 1)
}

/// A half-open span `[startPos, endPos)` over the source.
@stable(since="0.1")
pub record Span {
  startPos: Position
  endPos:   Position
}

@stable(since="0.1")
pub func makeSpan(startP: in Position, endP: in Position): Span {
  Span(startPos = startP, endPos = endP)
}

/// Zero-length span used for synthetic tokens (STMT_END, EOF).
@stable(since="0.1")
pub func pointSpan(p: in Position): Span {
  Span(startPos = p, endPos = p)
}

@pure
@stable(since="0.1")
pub func spanLength(s: in Span): Int {
  s.endPos.offset - s.startPos.offset
}

// ─────────────────────────────────────────────────────────────────────────────
// Diagnostics — mirror compiler/src/Lyric.Lexer/Diagnostics.fs.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub union DiagnosticSeverity {
  case DiagError
  case DiagWarning
}

@stable(since="0.1")
pub record Diagnostic {
  severity: DiagnosticSeverity
  code:     String
  message:  String
  span:     Span
}

@stable(since="0.1")
pub func errorDiagnostic(code: in String, msg: in String, sp: in Span): Diagnostic {
  Diagnostic(severity = DiagError, code = code, message = msg, span = sp)
}

@stable(since="0.1")
pub func warningDiagnostic(code: in String, msg: in String, sp: in Span): Diagnostic {
  Diagnostic(severity = DiagWarning, code = code, message = msg, span = sp)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tokens — mirror compiler/src/Lyric.Lexer/Token.fs.  String-interpolation
// variants (TStringStart / TStringPart / TStringHoleStart / TStringEnd),
// triple-quoted, and raw strings are deferred (see file header).
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub union IntSuffix {
  case I8
  case I16
  case I32
  case I64
  case U8
  case U16
  case U32
  case U64
  case NoIntSuffix
}

@stable(since="0.1")
pub union FloatSuffix {
  case F32
  case F64
  case NoFloatSuffix
}

/// The reserved keyword set (grammar §1.5).  Constructor names carry a
/// `Kw` prefix to keep them spelling-distinct from Lyric keywords.
@stable(since="0.1")
pub union Keyword {
  case KwAlias
  case KwAnd
  case KwAs
  case KwAsync
  case KwAwait
  case KwBind
  case KwCase
  case KwDo
  case KwElse
  case KwEnd
  case KwEnsures
  case KwEntry
  case KwEnum
  case KwExposed
  case KwExtern
  case KwFalse
  case KwFixture
  case KwFor
  case KwFunc
  case KwGeneric
  case KwIf
  case KwImpl
  case KwImport
  case KwIn
  case KwInout
  case KwInterface
  case KwInvariant
  case KwIs
  case KwLet
  case KwMatch
  case KwMut
  case KwNot
  case KwOld
  case KwOpaque
  case KwOr
  case KwOut
  case KwPackage
  case KwProperty
  case KwProtected
  case KwPub
  case KwRecord
  case KwRequires
  case KwResult
  case KwReturn
  case KwScope
  case KwScoped
  case KwSelf
  case KwSingleton
  case KwSpawn
  case KwTest
  case KwThen
  case KwThrow
  case KwTrue
  case KwTry
  case KwType
  case KwUnion
  case KwUse
  case KwVal
  case KwVar
  case KwWhen
  case KwWhere
  case KwWhile
  case KwWire
  case KwWith
  case KwXor
}

/// Multi- and single-character punctuation/operator tokens (§1.9).
@stable(since="0.1")
pub union Punct {
  case DotDotEq
  case DotDotLt
  case DotDot
  case Arrow
  case FatArrow
  case ColonColon
  case Question
  case QuestionQuestion
  case At
  case EqEq
  case NotEq
  case LtEq
  case GtEq
  case Lt
  case Gt
  case PlusEq
  case MinusEq
  case StarEq
  case SlashEq
  case PercentEq
  case Plus
  case Minus
  case Star
  case Slash
  case Percent
  case Eq
  case Bang
  case Pipe
  case Amp
  case LParen
  case RParen
  case LBracket
  case RBracket
  case LBrace
  case RBrace
  case Comma
  case Semi
  case Colon
  case Dot
}

/// A token produced by the lexer.  `intValue` is unsigned in spirit
/// (the parser reattaches a leading `-`), but we represent it as `Long`
/// because Lyric does not yet have a `ULong` literal form in this
/// module's surface area; values that overflow `Long.MaxValue` are
/// reported via L0010 and replaced with 0.
@stable(since="0.1")
pub union Token {
  case TKeyword(kw: Keyword)
  case TIdent(name: String)
  case TInt(value: Long, suffix: IntSuffix)
  case TFloat(value: Double, suffix: FloatSuffix)
  case TChar(codepoint: Int)
  case TString(text: String)
  case TBool(value: Bool)
  case TPunct(p: Punct)
  case TStmtEnd
  case TDocComment(text: String)
  case TModuleDocComment(text: String)
  case TEof
}

@stable(since="0.1")
pub record SpannedToken {
  token: Token
  span:  Span
}

// ─────────────────────────────────────────────────────────────────────────────
// Keyword spelling tables.  Mirrors compiler/src/Lyric.Lexer/Keywords.fs.
// ─────────────────────────────────────────────────────────────────────────────

/// Canonical source spelling for a keyword.
@pure
@stable(since="0.1")
pub func keywordSpelling(kw: in Keyword): String {
  match kw {
    case KwAlias     -> "alias"
    case KwAnd       -> "and"
    case KwAs        -> "as"
    case KwAsync     -> "async"
    case KwAwait     -> "await"
    case KwBind      -> "bind"
    case KwCase      -> "case"
    case KwDo        -> "do"
    case KwElse      -> "else"
    case KwEnd       -> "end"
    case KwEnsures   -> "ensures"
    case KwEntry     -> "entry"
    case KwEnum      -> "enum"
    case KwExposed   -> "exposed"
    case KwExtern    -> "extern"
    case KwFalse     -> "false"
    case KwFixture   -> "fixture"
    case KwFor       -> "for"
    case KwFunc      -> "func"
    case KwGeneric   -> "generic"
    case KwIf        -> "if"
    case KwImpl      -> "impl"
    case KwImport    -> "import"
    case KwIn        -> "in"
    case KwInout     -> "inout"
    case KwInterface -> "interface"
    case KwInvariant -> "invariant"
    case KwIs        -> "is"
    case KwLet       -> "let"
    case KwMatch     -> "match"
    case KwMut       -> "mut"
    case KwNot       -> "not"
    case KwOld       -> "old"
    case KwOpaque    -> "opaque"
    case KwOr        -> "or"
    case KwOut       -> "out"
    case KwPackage   -> "package"
    case KwProperty  -> "property"
    case KwProtected -> "protected"
    case KwPub       -> "pub"
    case KwRecord    -> "record"
    case KwRequires  -> "requires"
    case KwResult    -> "result"
    case KwReturn    -> "return"
    case KwScope     -> "scope"
    case KwScoped    -> "scoped"
    case KwSelf      -> "self"
    case KwSingleton -> "singleton"
    case KwSpawn     -> "spawn"
    case KwTest      -> "test"
    case KwThen      -> "then"
    case KwThrow     -> "throw"
    case KwTrue      -> "true"
    case KwTry       -> "try"
    case KwType      -> "type"
    case KwUnion     -> "union"
    case KwUse       -> "use"
    case KwVal       -> "val"
    case KwVar       -> "var"
    case KwWhen      -> "when"
    case KwWhere     -> "where"
    case KwWhile     -> "while"
    case KwWire      -> "wire"
    case KwWith      -> "with"
    case KwXor       -> "xor"
  }
}

/// Result of looking an identifier up in the keyword table.  This is
/// a local non-generic union (rather than `Option[Keyword]`) because
/// the bootstrap codegen does not yet handle `None[Keyword]` when
/// `Keyword` is a TypeBuilder under construction (the imported nullary
/// case branch at `Codegen.fs:2137` calls `GetConstructors()` on a
/// `TypeBuilderInstantiation`, which throws).  A self-hosted compiler
/// rebuild will collapse this back into `Option[Keyword]`.
@stable(since="0.1")
pub union KeywordLookup {
  case FoundKw(kw: Keyword)
  case NoKw
}

/// Match an identifier-shaped string against the keyword table.
/// Soft keywords (`range`, `derives`, `forall`, `exists`, `implies`,
/// `scope_kind`) are NOT recognised here — the parser resolves them
/// contextually.
@pure
@stable(since="0.1")
pub func tryKeywordFromString(s: in String): KeywordLookup {
  // The keyword table is closed and small; an explicit cascade keeps
  // the lookup allocation-free and its branches obvious.  Once the
  // self-hosted compiler grows a `Std.Map` with first-class hash
  // tables this can collapse to a hashed lookup.
  if s == "alias"     { FoundKw(kw = KwAlias) }
  else if s == "and"       { FoundKw(kw = KwAnd) }
  else if s == "as"        { FoundKw(kw = KwAs) }
  else if s == "async"     { FoundKw(kw = KwAsync) }
  else if s == "await"     { FoundKw(kw = KwAwait) }
  else if s == "bind"      { FoundKw(kw = KwBind) }
  else if s == "case"      { FoundKw(kw = KwCase) }
  else if s == "do"        { FoundKw(kw = KwDo) }
  else if s == "else"      { FoundKw(kw = KwElse) }
  else if s == "end"       { FoundKw(kw = KwEnd) }
  else if s == "ensures"   { FoundKw(kw = KwEnsures) }
  else if s == "entry"     { FoundKw(kw = KwEntry) }
  else if s == "enum"      { FoundKw(kw = KwEnum) }
  else if s == "exposed"   { FoundKw(kw = KwExposed) }
  else if s == "extern"    { FoundKw(kw = KwExtern) }
  else if s == "false"     { FoundKw(kw = KwFalse) }
  else if s == "fixture"   { FoundKw(kw = KwFixture) }
  else if s == "for"       { FoundKw(kw = KwFor) }
  else if s == "func"      { FoundKw(kw = KwFunc) }
  else if s == "generic"   { FoundKw(kw = KwGeneric) }
  else if s == "if"        { FoundKw(kw = KwIf) }
  else if s == "impl"      { FoundKw(kw = KwImpl) }
  else if s == "import"    { FoundKw(kw = KwImport) }
  else if s == "in"        { FoundKw(kw = KwIn) }
  else if s == "inout"     { FoundKw(kw = KwInout) }
  else if s == "interface" { FoundKw(kw = KwInterface) }
  else if s == "invariant" { FoundKw(kw = KwInvariant) }
  else if s == "is"        { FoundKw(kw = KwIs) }
  else if s == "let"       { FoundKw(kw = KwLet) }
  else if s == "match"     { FoundKw(kw = KwMatch) }
  else if s == "mut"       { FoundKw(kw = KwMut) }
  else if s == "not"       { FoundKw(kw = KwNot) }
  else if s == "old"       { FoundKw(kw = KwOld) }
  else if s == "opaque"    { FoundKw(kw = KwOpaque) }
  else if s == "or"        { FoundKw(kw = KwOr) }
  else if s == "out"       { FoundKw(kw = KwOut) }
  else if s == "package"   { FoundKw(kw = KwPackage) }
  else if s == "property"  { FoundKw(kw = KwProperty) }
  else if s == "protected" { FoundKw(kw = KwProtected) }
  else if s == "pub"       { FoundKw(kw = KwPub) }
  else if s == "record"    { FoundKw(kw = KwRecord) }
  else if s == "requires"  { FoundKw(kw = KwRequires) }
  else if s == "result"    { FoundKw(kw = KwResult) }
  else if s == "return"    { FoundKw(kw = KwReturn) }
  else if s == "scope"     { FoundKw(kw = KwScope) }
  else if s == "scoped"    { FoundKw(kw = KwScoped) }
  else if s == "self"      { FoundKw(kw = KwSelf) }
  else if s == "singleton" { FoundKw(kw = KwSingleton) }
  else if s == "spawn"     { FoundKw(kw = KwSpawn) }
  else if s == "test"      { FoundKw(kw = KwTest) }
  else if s == "then"      { FoundKw(kw = KwThen) }
  else if s == "throw"     { FoundKw(kw = KwThrow) }
  else if s == "true"      { FoundKw(kw = KwTrue) }
  else if s == "try"       { FoundKw(kw = KwTry) }
  else if s == "type"      { FoundKw(kw = KwType) }
  else if s == "union"     { FoundKw(kw = KwUnion) }
  else if s == "use"       { FoundKw(kw = KwUse) }
  else if s == "val"       { FoundKw(kw = KwVal) }
  else if s == "var"       { FoundKw(kw = KwVar) }
  else if s == "when"      { FoundKw(kw = KwWhen) }
  else if s == "where"     { FoundKw(kw = KwWhere) }
  else if s == "while"     { FoundKw(kw = KwWhile) }
  else if s == "wire"      { FoundKw(kw = KwWire) }
  else if s == "with"      { FoundKw(kw = KwWith) }
  else if s == "xor"       { FoundKw(kw = KwXor) }
  else                     { NoKw }
}

// ─────────────────────────────────────────────────────────────────────────────
// LexResult and LexerState.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record LexResult {
  tokens:      List[SpannedToken]
  diagnostics: List[Diagnostic]
}

/// Internal state carried through every helper as `inout`.  Records in
/// Lyric have assignable fields once a binding is in scope, so each
/// helper can step the cursor and accumulate tokens / diagnostics
/// without reconstructing the record.
record LexerState {
  source: String
  pos:    Int
  line:   Int
  column: Int
  // Bracket-nesting depth (parens / square / brace) gates STMT_END
  // emission: a newline inside an unclosed bracket pair is a
  // continuation, never a terminator.
  bracketDepth: Int
  // A newline has been seen since the previous emit; the next emit
  // must consider STMT_END insertion.
  newlinePending: Bool
  // The last non-STMT_END emit cannot terminate a statement (a binary
  // operator, opening bracket, comma/dot/at/etc.).  Tracked as a
  // single Bool — the F# lexer carries the full token but only ever
  // queries `suppressesNewlineAfter`.
  prevSuppresses: Bool
  // The previous emit was a STMT_END (explicit `;` or synthesised);
  // a second one in a row collapses to one.
  prevWasStmtEnd: Bool
  // True once the file has emitted at least one real token; used to
  // suppress STMT_END at start-of-file.
  haveAnyToken: Bool
  tokens:      List[SpannedToken]
  diagnostics: List[Diagnostic]
}

func newState(source: in String): LexerState {
  LexerState(
    source         = source,
    pos            = 0,
    line           = 1,
    column         = 1,
    bracketDepth   = 0,
    newlinePending = false,
    prevSuppresses = false,
    prevWasStmtEnd = false,
    haveAnyToken   = false,
    tokens         = newList(),
    diagnostics    = newList()
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Cursor primitives.
// ─────────────────────────────────────────────────────────────────────────────

@pure
func isAtEnd(state: in LexerState): Bool {
  state.pos >= state.source.length
}

/// Peek the current character.  Returns `' '` (space) at end-of-input
/// to keep predicate code branchless — the caller already gates on
/// `isAtEnd` before consuming.
@pure
func peek(state: in LexerState): Char {
  if state.pos < state.source.length {
    state.source[state.pos]
  } else {
    ' '
  }
}

@pure
func peekAt(state: in LexerState, offset: in Int): Char {
  val i = state.pos + offset
  if i >= 0 and i < state.source.length {
    state.source[i]
  } else {
    ' '
  }
}

/// Read one character and advance the cursor.  Updates line/column.
func advance(state: inout LexerState): Char {
  val c = state.source[state.pos]
  state.pos = state.pos + 1
  if c == '\n' {
    state.line = state.line + 1
    state.column = 1
  } else {
    state.column = state.column + 1
  }
  return c
}

@pure
func currentPosition(state: in LexerState): Position {
  Position(offset = state.pos, line = state.line, column = state.column)
}

// ─────────────────────────────────────────────────────────────────────────────
// Character predicates (ASCII fast path; non-ASCII identifier handling
// is deferred per the file header).
// ─────────────────────────────────────────────────────────────────────────────

@pure
func isDigitChar(c: in Char): Bool {
  c >= '0' and c <= '9'
}

@pure
func isHexDigitChar(c: in Char): Bool {
  isDigitChar(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')
}

@pure
func isOctalDigitChar(c: in Char): Bool {
  c >= '0' and c <= '7'
}

@pure
func isBinaryDigitChar(c: in Char): Bool {
  c == '0' or c == '1'
}

@pure
func isAsciiAlpha(c: in Char): Bool {
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')
}

@pure
func isIdStart(c: in Char): Bool {
  isAsciiAlpha(c) or c == '_'
}

@pure
func isIdContinue(c: in Char): Bool {
  isAsciiAlpha(c) or isDigitChar(c) or c == '_'
}

/// Map an ASCII digit char to its numeric value 0..15, returning -1
/// for non-digits.  Lyric does not yet expose `Char` ↔ `Int`
/// arithmetic in the surface language, so the conversion is an
/// explicit table.
@pure
func digitValue(c: in Char): Int {
  match c {
    case '0' -> 0
    case '1' -> 1
    case '2' -> 2
    case '3' -> 3
    case '4' -> 4
    case '5' -> 5
    case '6' -> 6
    case '7' -> 7
    case '8' -> 8
    case '9' -> 9
    case 'a' -> 10
    case 'A' -> 10
    case 'b' -> 11
    case 'B' -> 11
    case 'c' -> 12
    case 'C' -> 12
    case 'd' -> 13
    case 'D' -> 13
    case 'e' -> 14
    case 'E' -> 14
    case 'f' -> 15
    case 'F' -> 15
    case _   -> -1
  }
}

@pure
func charToString(c: in Char): String {
  // Lyric does not yet expose a `Char` → `String` builtin; concatenating
  // an empty string with the char drives the codegen to box and lift
  // through `System.String.Concat`, which is the same path used by
  // string-interpolation fragments.
  "" + c
}

@pure
func maxInt(a: in Int, b: in Int): Int {
  if a > b { a } else { b }
}

// ─────────────────────────────────────────────────────────────────────────────
// Statement-terminator insertion (grammar §1.7).
// ─────────────────────────────────────────────────────────────────────────────

@pure
func punctSuppressesNewline(p: in Punct): Bool {
  match p {
    case Plus       -> true
    case Minus      -> true
    case Star       -> true
    case Slash      -> true
    case Percent    -> true
    case Eq         -> true
    case EqEq       -> true
    case NotEq      -> true
    case Lt         -> true
    case LtEq       -> true
    case Gt         -> true
    case GtEq       -> true
    case PlusEq     -> true
    case MinusEq    -> true
    case StarEq     -> true
    case SlashEq    -> true
    case PercentEq  -> true
    case Arrow      -> true
    case FatArrow   -> true
    case DotDot     -> true
    case DotDotEq   -> true
    case DotDotLt   -> true
    case Comma      -> true
    case Dot        -> true
    case At         -> true
    case ColonColon -> true
    case Colon      -> true
    case LParen     -> true
    case LBracket   -> true
    case LBrace     -> true
    case QuestionQuestion -> true
    case _          -> false
  }
}

@pure
func keywordSuppressesNewline(kw: in Keyword): Bool {
  // Connectives and binary keywords that cannot terminate an
  // expression: a newline after them is a continuation.  Mirrors
  // `suppressesNewlineAfter` in the F# lexer.
  match kw {
    case KwAnd   -> true
    case KwOr    -> true
    case KwXor   -> true
    case KwNot   -> true
    case KwIs    -> true
    case KwAs    -> true
    case KwElse  -> true
    case KwThen  -> true
    case KwIn    -> true
    case KwWhere -> true
    case _       -> false
  }
}

@pure
func tokenSuppressesNewline(tok: in Token): Bool {
  match tok {
    case TPunct(p)   -> punctSuppressesNewline(p)
    case TKeyword(k) -> keywordSuppressesNewline(k)
    case _           -> false
  }
}

@pure
func bracketDelta(currentDepth: in Int, p: in Punct): Int {
  if punctIsOpenBracket(p) {
    currentDepth + 1
  } else if punctIsCloseBracket(p) {
    maxInt(0, currentDepth - 1)
  } else {
    currentDepth
  }
}

/// Update `state.bracketDepth` based on `tok` if `tok` is a punct.
/// Lifted out of `emit` because the bootstrap codegen mishandles
/// field stores through an `inout` parameter inside a `match` arm
/// whose scrutinee is a discriminated-union value (the IL emission
/// produces an unverifiable program).  Calling out to a helper with
/// no `match` keeps the inout-mutation IL on a known-good path.
func trackBracketDepthFor(state: inout LexerState, tok: in Token): Unit {
  val p = punctOfToken(tok)
  if isSomePunct(p) {
    state.bracketDepth = bracketDelta(state.bracketDepth, unwrapPunct(p))
  }
}

/// `Option[Punct]`-shaped lookup, but realised as a small local union
/// to keep generic-over-local-type out of the picture (per the same
/// imported-nullary-case codegen issue tracked in `KeywordLookup`).
union PunctLookup {
  case GotPunct(p: Punct)
  case NoPunct
}

@pure
func punctOfToken(tok: in Token): PunctLookup {
  match tok {
    case TPunct(p) -> GotPunct(p = p)
    case _         -> NoPunct
  }
}

@pure
func isSomePunct(pl: in PunctLookup): Bool {
  match pl {
    case GotPunct(_) -> true
    case NoPunct     -> false
  }
}

@pure
func unwrapPunct(pl: in PunctLookup): Punct {
  match pl {
    case GotPunct(p) -> p
    case NoPunct     -> Comma  // unreachable when guarded by isSomePunct
  }
}

@pure
func punctIsOpenBracket(p: in Punct): Bool {
  match p {
    case LParen   -> true
    case LBracket -> true
    case LBrace   -> true
    case _        -> false
  }
}

@pure
func punctIsCloseBracket(p: in Punct): Bool {
  match p {
    case RParen   -> true
    case RBracket -> true
    case RBrace   -> true
    case _        -> false
  }
}

/// Maybe insert a synthesised STMT_END before emitting the next token.
/// Mirrors `maybeEmitStmtEnd` in the F# lexer.
func maybeEmitStmtEnd(state: inout LexerState): Unit {
  if state.newlinePending and state.bracketDepth == 0 {
    val suppress =
      state.prevWasStmtEnd or state.prevSuppresses or (not state.haveAnyToken)
    if not suppress {
      val sp = pointSpan(currentPosition(state))
      state.tokens.add(SpannedToken(token = TStmtEnd, span = sp))
      state.prevWasStmtEnd = true
      state.prevSuppresses = false
      state.haveAnyToken = true
    }
  }
  state.newlinePending = false
}

/// Emit a token, threading STMT_END insertion and bracket-depth
/// bookkeeping.  All non-STMT_END token writes go through here.
func emit(state: inout LexerState, tok: in Token, startP: in Position): Unit {
  maybeEmitStmtEnd(state)
  val sp = makeSpan(startP, currentPosition(state))
  state.tokens.add(SpannedToken(token = tok, span = sp))
  // Removed match — bracket-tracking is moved to a separate helper to
  // sidestep a bootstrap codegen bug with field assignment inside a
  // match arm whose scrutinee is a discriminated-union value.  See the
  // file header for the work-around scope.
  trackBracketDepthFor(state, tok)
  state.prevSuppresses = tokenSuppressesNewline(tok)
  state.prevWasStmtEnd = false
  state.haveAnyToken = true
}

func recordError(state: inout LexerState, code: in String, msg: in String, sp: in Span): Unit {
  state.diagnostics.add(errorDiagnostic(code, msg, sp))
}

// ─────────────────────────────────────────────────────────────────────────────
// Trivia: whitespace and comments.
// ─────────────────────────────────────────────────────────────────────────────

func skipBlockComment(state: inout LexerState, startP: in Position): Unit {
  // Already past the opening `/*`.
  var depth = 1
  while depth > 0 and not isAtEnd(state) {
    if peek(state) == '/' and peekAt(state, 1) == '*' {
      advance(state)
      advance(state)
      depth = depth + 1
    } else if peek(state) == '*' and peekAt(state, 1) == '/' {
      advance(state)
      advance(state)
      depth = depth - 1
    } else {
      advance(state)
    }
  }
  if depth > 0 {
    recordError(state, "L0001", "unterminated block comment",
                makeSpan(startP, currentPosition(state)))
  }
}

func consumeLineToString(state: inout LexerState): String {
  // Read up to (but not including) the next `\n`.  Caller is responsible
  // for the trailing newline (it becomes a normal newline-trivia event).
  var buf = ""
  while not isAtEnd(state) and peek(state) != '\n' {
    val c = advance(state)
    buf = buf + charToString(c)
  }
  buf
}

func emitDocComment(state: inout LexerState, startP: in Position): Unit {
  // Consume the leading `///`.
  advance(state)
  advance(state)
  advance(state)
  val raw = consumeLineToString(state)
  // The bootstrap lexer trims a single leading space; replicate it.
  val text = if raw.length > 0 and raw[0] == ' ' {
    Str.substring(raw, 1, raw.length - 1)
  } else {
    raw
  }
  emit(state, TDocComment(text = text), startP)
}

func emitModuleDocComment(state: inout LexerState, startP: in Position): Unit {
  advance(state)
  advance(state)
  advance(state)
  val raw = consumeLineToString(state)
  val text = if raw.length > 0 and raw[0] == ' ' {
    Str.substring(raw, 1, raw.length - 1)
  } else {
    raw
  }
  emit(state, TModuleDocComment(text = text), startP)
}

/// Skip whitespace, line/block comments, and newlines.  Doc comments
/// (`///` and `//!`) are emitted as their own tokens; ordinary
/// `//` and `/* … */` are dropped.
func skipTrivia(state: inout LexerState): Unit {
  while not isAtEnd(state) {
    val c = peek(state)
    if isAsciiWhitespace(c) {
      // `newlinePending` carries forward across multiple newlines:
      // OR-in the new flag so a `\n` followed by `\t` keeps the
      // pending state set until the next non-trivia emit.
      state.newlinePending = state.newlinePending or (c == '\n')
      advance(state)
    } else if isLineCommentStart(state) {
      consumeLineCommentOrDocComment(state)
    } else if isBlockCommentStart(state) {
      consumeBlockComment(state)
    } else {
      return
    }
  }
}

@pure
func isAsciiWhitespace(c: in Char): Bool {
  c == ' ' or c == '\t' or c == '\n'
}

@pure
func isLineCommentStart(state: in LexerState): Bool {
  peek(state) == '/' and peekAt(state, 1) == '/'
}

@pure
func isBlockCommentStart(state: in LexerState): Bool {
  peek(state) == '/' and peekAt(state, 1) == '*'
}

func consumeLineCommentOrDocComment(state: inout LexerState): Unit {
  val third = peekAt(state, 2)
  if third == '/' {
    val startP = currentPosition(state)
    emitDocComment(state, startP)
  } else if third == '!' {
    val startP = currentPosition(state)
    emitModuleDocComment(state, startP)
  } else {
    // Plain line comment — drop everything up to but not including
    // the newline (which the next skipTrivia iteration handles as a
    // normal newline-trivia event).
    while not isAtEnd(state) and peek(state) != '\n' {
      advance(state)
    }
  }
}

func consumeBlockComment(state: inout LexerState): Unit {
  val startP = currentPosition(state)
  advance(state)   // '/'
  advance(state)   // '*'
  skipBlockComment(state, startP)
}

// ─────────────────────────────────────────────────────────────────────────────
// Identifiers and keywords.
// ─────────────────────────────────────────────────────────────────────────────

func lexIdentOrKeyword(state: inout LexerState): Unit {
  val startP = currentPosition(state)
  var buf = ""
  while not isAtEnd(state) and isIdContinue(peek(state)) {
    val c = advance(state)
    buf = buf + charToString(c)
  }
  emitIdentOrKeywordToken(state, buf, startP)
}

/// Decide between `TBool`, `TKeyword`, and `TIdent` for a freshly
/// scanned identifier-shaped lexeme.  Hoisted out of `lexIdentOrKeyword`
/// because the bootstrap codegen mishandles a `match` whose arms
/// dispatch through three different `emit(...)` calls; keeping the
/// branch in a top-level helper lets each `emit` call own a
/// straight-line IL frame.
func emitIdentOrKeywordToken(state: inout LexerState, lexeme: in String, startP: in Position): Unit {
  match tryKeywordFromString(lexeme) {
    case FoundKw(kw) -> emitKeywordToken(state, kw, startP)
    case NoKw        -> emit(state, TIdent(name = lexeme), startP)
  }
}

func emitKeywordToken(state: inout LexerState, kw: in Keyword, startP: in Position): Unit {
  match kw {
    case KwTrue  -> emit(state, TBool(value = true),  startP)
    case KwFalse -> emit(state, TBool(value = false), startP)
    case _       -> emit(state, TKeyword(kw = kw),    startP)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Numeric literals.
// ─────────────────────────────────────────────────────────────────────────────

@pure
func stripUnderscores(s: in String): String {
  // `var sb` not `var out` — `out` is a reserved keyword (parameter
  // mode), so it cannot bind a local in this dialect.
  var sb = ""
  var i = 0
  while i < s.length {
    val c = s[i]
    if c != '_' {
      sb = sb + charToString(c)
    }
    i = i + 1
  }
  sb
}

/// Result of peeling an integer-type suffix off a numeric body.
record IntSuffixSplit {
  body:   String
  suffix: IntSuffix
}

/// Result of peeling a float-type suffix off a numeric body.
record FloatSuffixSplit {
  body:   String
  suffix: FloatSuffix
}

@pure
func splitIntSuffix(raw: in String): IntSuffixSplit {
  if raw.length >= 3 and Str.substring(raw, raw.length - 3, 3) == "i32" {
    IntSuffixSplit(body = Str.substring(raw, 0, raw.length - 3), suffix = I32)
  } else if raw.length >= 3 and Str.substring(raw, raw.length - 3, 3) == "i64" {
    IntSuffixSplit(body = Str.substring(raw, 0, raw.length - 3), suffix = I64)
  } else if raw.length >= 3 and Str.substring(raw, raw.length - 3, 3) == "i16" {
    IntSuffixSplit(body = Str.substring(raw, 0, raw.length - 3), suffix = I16)
  } else if raw.length >= 3 and Str.substring(raw, raw.length - 3, 3) == "u32" {
    IntSuffixSplit(body = Str.substring(raw, 0, raw.length - 3), suffix = U32)
  } else if raw.length >= 3 and Str.substring(raw, raw.length - 3, 3) == "u64" {
    IntSuffixSplit(body = Str.substring(raw, 0, raw.length - 3), suffix = U64)
  } else if raw.length >= 3 and Str.substring(raw, raw.length - 3, 3) == "u16" {
    IntSuffixSplit(body = Str.substring(raw, 0, raw.length - 3), suffix = U16)
  } else if raw.length >= 2 and Str.substring(raw, raw.length - 2, 2) == "i8" {
    IntSuffixSplit(body = Str.substring(raw, 0, raw.length - 2), suffix = I8)
  } else if raw.length >= 2 and Str.substring(raw, raw.length - 2, 2) == "u8" {
    IntSuffixSplit(body = Str.substring(raw, 0, raw.length - 2), suffix = U8)
  } else {
    IntSuffixSplit(body = raw, suffix = NoIntSuffix)
  }
}

@pure
func splitFloatSuffix(raw: in String): FloatSuffixSplit {
  if raw.length >= 3 and Str.substring(raw, raw.length - 3, 3) == "f32" {
    FloatSuffixSplit(body = Str.substring(raw, 0, raw.length - 3), suffix = F32)
  } else if raw.length >= 3 and Str.substring(raw, raw.length - 3, 3) == "f64" {
    FloatSuffixSplit(body = Str.substring(raw, 0, raw.length - 3), suffix = F64)
  } else {
    FloatSuffixSplit(body = raw, suffix = NoFloatSuffix)
  }
}

@pure
func intToLong(n: in Int): Long {
  // Tiny widening shim — Lyric's surface language requires explicit
  // promotion here.  Inputs are bounded to small magnitudes (digit
  // values 0..15, base ∈ {2, 8, 10, 16}) so the loop is constant time.
  var acc: Long = 0i64
  if n >= 0 {
    var i = 0
    while i < n {
      acc = acc + 1i64
      i = i + 1
    }
  } else {
    var i = 0
    while i > n {
      acc = acc - 1i64
      i = i - 1
    }
  }
  acc
}

@pure
func intToDouble(n: in Int): Double {
  // Same shape as `intToLong`; only ever called with single-digit
  // values from `digitValue` so the iteration count is at most 9.
  var acc: Double = 0.0
  if n >= 0 {
    var i = 0
    while i < n {
      acc = acc + 1.0
      i = i + 1
    }
  } else {
    var i = 0
    while i > n {
      acc = acc - 1.0
      i = i - 1
    }
  }
  acc
}

/// Parse a digit string in the given base into a `Long`.  Returns
/// `None` on overflow, on empty input, or when a character outside
/// the base's digit set appears (matches the F# lexer's behaviour of
/// surfacing L0010 in those cases).
@pure
func parseDigits(body: in String, base: in Int): Option[Long] {
  if body.length == 0 { return None }
  val baseL = intToLong(base)
  var value: Long = 0i64
  var overflowed = false
  var i = 0
  // The largest value that, when multiplied by `base`, still fits in
  // a positive Long.  Used as an early-exit overflow guard so the
  // intermediate `value * base` cannot trap.
  val limit: Long = 9223372036854775807i64
  while i < body.length and not overflowed {
    val d = digitValue(body[i])
    if d < 0 or d >= base {
      overflowed = true
    } else {
      val dL = intToLong(d)
      val maxBefore = (limit - dL) / baseL
      if value > maxBefore {
        overflowed = true
      } else {
        value = value * baseL + dL
      }
    }
    i = i + 1
  }
  if overflowed { None } else { Some(value = value) }
}

func lexBasedInt(state: inout LexerState, startP: in Position, base: in Int): Unit {
  // Already at the leading `0`; consume it plus the base char.
  advance(state)        // '0'
  advance(state)        // 'x' / 'o' / 'b'
  var raw = ""
  var keepReading = true
  while keepReading and not isAtEnd(state) {
    val c = peek(state)
    val ok =
      if base == 16 { isHexDigitChar(c) }
      else if base == 8  { isOctalDigitChar(c) }
      else               { isBinaryDigitChar(c) }
    if ok or c == '_' {
      advance(state)
      raw = raw + charToString(c)
    } else {
      keepReading = false
    }
  }
  // Optional integer suffix tail.
  var tail = ""
  while not isAtEnd(state) and (isAsciiAlpha(peek(state)) or isDigitChar(peek(state))) {
    val c = advance(state)
    tail = tail + charToString(c)
  }
  val split = splitIntSuffix(tail)
  if split.body.length > 0 {
    // Unrecognised characters in the suffix tail.  Re-glue them onto
    // the body so they participate in the digit-overflow diagnostic
    // and surface a clean L0010.
    raw = raw + split.body
  }
  val body = stripUnderscores(raw)
  match parseDigits(body, base) {
    case Some(v) -> emit(state, TInt(value = v, suffix = split.suffix), startP)
    case None    -> {
      recordError(state, "L0010", "integer literal out of range",
                  makeSpan(startP, currentPosition(state)))
      emit(state, TInt(value = 0i64, suffix = split.suffix), startP)
    }
  }
}

@pure
func parseDoubleLiteral(body: in String): Option[Double] {
  // Hand-roll a permissive decimal-float parser:
  //   `[0-9]+ ('.' [0-9]+)? ([eE][+-]?[0-9]+)?`
  // The bootstrap lexer delegates to `Double.TryParse(InvariantCulture)`;
  // mirror the same accepted shape so the two lexers stay aligned.
  if body.length == 0 { return None }
  var i = 0
  var sawDigit = false
  // Integer part.
  while i < body.length and isDigitChar(body[i]) {
    sawDigit = true
    i = i + 1
  }
  // Fractional part.
  var hasFrac = false
  if i < body.length and body[i] == '.' {
    hasFrac = true
    i = i + 1
    var fracDigits = false
    while i < body.length and isDigitChar(body[i]) {
      fracDigits = true
      sawDigit = true
      i = i + 1
    }
    if not fracDigits { return None }
  }
  // Exponent.
  var hasExp = false
  if i < body.length and (body[i] == 'e' or body[i] == 'E') {
    hasExp = true
    i = i + 1
    if i < body.length and (body[i] == '+' or body[i] == '-') {
      i = i + 1
    }
    var expDigits = false
    while i < body.length and isDigitChar(body[i]) {
      expDigits = true
      i = i + 1
    }
    if not expDigits { return None }
  }
  if not sawDigit { return None }
  if i != body.length { return None }
  // Build value left-to-right.
  var idx = 0
  var intPart: Double = 0.0
  while idx < body.length and isDigitChar(body[idx]) {
    intPart = intPart * 10.0 + intToDouble(digitValue(body[idx]))
    idx = idx + 1
  }
  var value: Double = intPart
  if hasFrac {
    idx = idx + 1   // skip '.'
    var fracMul: Double = 0.1
    while idx < body.length and isDigitChar(body[idx]) {
      value = value + intToDouble(digitValue(body[idx])) * fracMul
      fracMul = fracMul / 10.0
      idx = idx + 1
    }
  }
  if hasExp {
    idx = idx + 1   // skip 'e'/'E'
    var expSign = 1
    if idx < body.length and (body[idx] == '+' or body[idx] == '-') {
      if body[idx] == '-' { expSign = -1 }
      idx = idx + 1
    }
    var expVal = 0
    while idx < body.length and isDigitChar(body[idx]) {
      expVal = expVal * 10 + digitValue(body[idx])
      idx = idx + 1
    }
    var k = 0
    while k < expVal {
      if expSign > 0 {
        value = value * 10.0
      } else {
        value = value / 10.0
      }
      k = k + 1
    }
  }
  Some(value = value)
}

func lexDecimalNumber(state: inout LexerState): Unit {
  val startP = currentPosition(state)
  // Detect an illegal C-style leading-zero decimal (e.g. `0755`).  A
  // bare `0`, `0.5`, `0e1`, `0_` are fine.
  val leadingZero = peek(state) == '0' and isDigitChar(peekAt(state, 1))
  var raw = ""
  while not isAtEnd(state) and (isDigitChar(peek(state)) or peek(state) == '_') {
    raw = raw + charToString(advance(state))
  }
  var isFloat = false
  // Fractional part — only if a digit follows the `.` (so `1..5` parses
  // as 1, .., 5, matching the bootstrap lexer).
  if peek(state) == '.' and isDigitChar(peekAt(state, 1)) {
    isFloat = true
    raw = raw + charToString(advance(state))
    while not isAtEnd(state) and (isDigitChar(peek(state)) or peek(state) == '_') {
      raw = raw + charToString(advance(state))
    }
  }
  if peek(state) == 'e' or peek(state) == 'E' {
    isFloat = true
    raw = raw + charToString(advance(state))
    if peek(state) == '+' or peek(state) == '-' {
      raw = raw + charToString(advance(state))
    }
    while not isAtEnd(state) and (isDigitChar(peek(state)) or peek(state) == '_') {
      raw = raw + charToString(advance(state))
    }
  }
  // Optional suffix tail (letters + digits — broad enough to catch
  // `f32`, `i64`, and to swallow malformed tails into the parse error).
  var tail = ""
  while not isAtEnd(state) and (isAsciiAlpha(peek(state)) or isDigitChar(peek(state))) {
    tail = tail + charToString(advance(state))
  }
  val combined = raw + tail
  val endsInF = combined.length >= 3 and (Str.substring(combined, combined.length - 3, 3) == "f32"
                                          or Str.substring(combined, combined.length - 3, 3) == "f64")
  if isFloat or endsInF {
    val fsplit = splitFloatSuffix(combined)
    val stripped = stripUnderscores(fsplit.body)
    match parseDoubleLiteral(stripped) {
      case Some(v) -> emit(state, TFloat(value = v, suffix = fsplit.suffix), startP)
      case None    -> {
        recordError(state, "L0011", "invalid float literal",
                    makeSpan(startP, currentPosition(state)))
        emit(state, TFloat(value = 0.0, suffix = fsplit.suffix), startP)
      }
    }
  } else {
    val isplit = splitIntSuffix(combined)
    val stripped = stripUnderscores(isplit.body)
    if leadingZero {
      recordError(state, "L0012",
                  "leading-zero decimal integers are not permitted; use 0o for octal",
                  makeSpan(startP, currentPosition(state)))
    }
    match parseDigits(stripped, 10) {
      case Some(v) -> emit(state, TInt(value = v, suffix = isplit.suffix), startP)
      case None    -> {
        recordError(state, "L0010", "integer literal out of range",
                    makeSpan(startP, currentPosition(state)))
        emit(state, TInt(value = 0i64, suffix = isplit.suffix), startP)
      }
    }
  }
}

func lexNumber(state: inout LexerState): Unit {
  val startP = currentPosition(state)
  if peek(state) == '0' {
    val n1 = peekAt(state, 1)
    if n1 == 'x' or n1 == 'X' {
      lexBasedInt(state, startP, 16)
      return
    } else if n1 == 'o' or n1 == 'O' {
      lexBasedInt(state, startP, 8)
      return
    } else if n1 == 'b' or n1 == 'B' {
      lexBasedInt(state, startP, 2)
      return
    }
  }
  lexDecimalNumber(state)
}

// ─────────────────────────────────────────────────────────────────────────────
// Character and string literals.
//
// Interpolation, triple-quoted, and raw strings are deferred (see the
// file header).  Within plain `"…"` and `'…'` literals the v0.1 lexer
// recognises the common ASCII escapes; non-BMP `\u{…}` escapes are
// reserved for the follow-up that introduces a wider TChar payload.
// ─────────────────────────────────────────────────────────────────────────────

@pure
func decodeEscape(c: in Char): Option[Char] {
  match c {
    case 'n'  -> Some(value = '\n')
    case 'r'  -> Some(value = '\r')
    case 't'  -> Some(value = '\t')
    case '\\' -> Some(value = '\\')
    case '\'' -> Some(value = '\'')
    case '"'  -> Some(value = '"')
    case '0'  -> Some(value = '\0')
    case '$'  -> Some(value = '$')
    case _    -> None
  }
}

@pure
func longToChar(v: in Long): Char {
  // Walk a small lookup table for ASCII; non-ASCII BMP scalars can be
  // re-introduced once a `Char.fromCodepoint` builtin lands.
  if v < 0i64 or v > 127i64 {
    '\u{FFFD}'
  } else {
    val ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
    val i = longToInt(v)
    if i < 32 {
      if i == 9 { '\t' }
      else if i == 10 { '\n' }
      else if i == 13 { '\r' }
      else if i == 0 { '\0' }
      else { '\u{FFFD}' }
    } else if i == 127 {
      '\u{FFFD}'
    } else {
      ascii[i - 32]
    }
  }
}

@pure
func longToInt(v: in Long): Int {
  // Saturating downcast for the small-positive range we need above.
  // A real `conv.i4` builtin would replace this once exposed.
  var acc = 0
  var rem = v
  while rem > 0i64 {
    acc = acc + 1
    rem = rem - 1i64
  }
  acc
}

@pure
func charCodepoint(c: in Char): Int {
  // Tiny ASCII inverse of `longToChar`; suffices for the v0.1 escape
  // set + ASCII source.  A real builtin will replace this when the
  // Char→Int promotion is exposed in the surface language.
  if c == '\0' { 0 }
  else if c == '\t' { 9 }
  else if c == '\n' { 10 }
  else if c == '\r' { 13 }
  else if c == '\u{FFFD}' { 0xFFFD }
  else {
    var i = 32
    val ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
    var found = -1
    while i < 127 and found < 0 {
      if ascii[i - 32] == c { found = i }
      i = i + 1
    }
    if found < 0 { 0xFFFD } else { found }
  }
}

/// Consume one escape-sequence body just past the opening backslash.
/// Returns the decoded char (or U+FFFD on error) and records a
/// diagnostic if the sequence was malformed / unknown.
func lexEscape(state: inout LexerState, startP: in Position): Char {
  if isAtEnd(state) {
    return '\u{FFFD}'
  }
  val c = advance(state)
  if c == 'u' {
    return lexUnicodeEscape(state, startP)
  }
  match decodeEscape(c) {
    case Some(d) -> d
    case None    -> c
  }
}

/// Lex a `\u{...}` Unicode escape.  v0.1 decodes only BMP scalars
/// (≤ 0xFFFF) so the result fits in a `Char`; higher codepoints land
/// with the wider-TChar follow-up.  The leading `\u` has already been
/// consumed by the caller.
func lexUnicodeEscape(state: inout LexerState, startP: in Position): Char {
  if peek(state) != '{' {
    recordError(state, "L0021", "expected '{' after \\u",
                makeSpan(startP, currentPosition(state)))
    return '\u{FFFD}'
  }
  advance(state)   // '{'
  var hexBody = ""
  var n = 0
  while not isAtEnd(state) and peek(state) != '}' and n < 6 {
    hexBody = hexBody + charToString(advance(state))
    n = n + 1
  }
  if peek(state) != '}' {
    recordError(state, "L0021", "unterminated unicode escape",
                makeSpan(startP, currentPosition(state)))
    return '\u{FFFD}'
  }
  advance(state)   // '}'
  match parseDigits(hexBody, 16) {
    case Some(v) -> {
      if v < 0i64 or v > 65535i64 {
        recordError(state, "L0022",
                    "non-BMP unicode escape (deferred to follow-up)",
                    makeSpan(startP, currentPosition(state)))
        '\u{FFFD}'
      } else {
        longToChar(v)
      }
    }
    case None -> {
      recordError(state, "L0022",
                  "invalid unicode escape (must be 1-6 hex digits)",
                  makeSpan(startP, currentPosition(state)))
      '\u{FFFD}'
    }
  }
}

func lexCharLiteral(state: inout LexerState): Unit {
  val startP = currentPosition(state)
  advance(state)   // opening '
  if isAtEnd(state) {
    recordError(state, "L0024", "unterminated character literal",
                makeSpan(startP, currentPosition(state)))
    emit(state, TChar(codepoint = 0xFFFD), startP)
    return
  }
  val ch = readCharLiteralBody(state, startP)
  if peek(state) == '\'' {
    advance(state)
  } else {
    recordError(state, "L0024", "unterminated character literal",
                makeSpan(startP, currentPosition(state)))
  }
  emit(state, TChar(codepoint = charCodepoint(ch)), startP)
}

/// Read the single-char body of a `'…'` literal — either an escape
/// sequence beginning with `\` or one literal char.  Lifted out of
/// `lexCharLiteral` so the conditional `val ch = if … { … } else { … }`
/// shape doesn't sit alongside other state-mutating statements (the
/// bootstrap codegen mishandles that combination on inout-record
/// receivers).
func readCharLiteralBody(state: inout LexerState, startP: in Position): Char {
  if peek(state) == '\\' {
    advance(state)    // consume the backslash
    lexEscape(state, startP)
  } else {
    advance(state)
  }
}

func lexStringLiteral(state: inout LexerState): Unit {
  val startP = currentPosition(state)
  advance(state)   // opening "
  var buf = ""
  var terminated = false
  while not terminated and not isAtEnd(state) {
    val c = peek(state)
    if c == '"' {
      advance(state)
      terminated = true
    } else if c == '\\' {
      advance(state)
      val d = lexEscape(state, startP)
      buf = buf + charToString(d)
    } else if c == '\n' {
      recordError(state, "L0025",
                  "unterminated string literal (newline before closing \")",
                  makeSpan(startP, currentPosition(state)))
      terminated = true
    } else {
      buf = buf + charToString(advance(state))
    }
  }
  if not terminated {
    recordError(state, "L0025", "unterminated string literal",
                makeSpan(startP, currentPosition(state)))
  }
  emit(state, TString(text = buf), startP)
}

// ─────────────────────────────────────────────────────────────────────────────
// Punctuation and operators.
// ─────────────────────────────────────────────────────────────────────────────

/// Result of a punctuation-table lookup.  Local non-generic union for
/// the same reason `KeywordLookup` is — `None[Record]` trips the
/// bootstrap codegen's imported-nullary-case path with a TypeBuilder
/// argument.  Fields are flattened into the case (rather than nested
/// in a `OperatorMatch` record) because the bootstrap codegen does
/// not yet handle record-typed payloads on union cases — every
/// existing union in the stdlib uses primitive payloads only.
union OperatorLookup {
  case FoundOp(p: Punct, consumed: Int)
  case NoOp
}

/// Try to match a multi-/single-char operator at the cursor.  Returns
/// the matched `FoundOp(p, n)` (the Punct plus how many source chars
/// to advance) or `NoOp` if no token is available.
@pure
func tryMatchOperator(c0: in Char, c1: in Char, c2: in Char): OperatorLookup {
  if c0 == '.' and c1 == '.' and c2 == '=' { FoundOp(p = DotDotEq, consumed = 3) }
  else if c0 == '.' and c1 == '.' and c2 == '<' { FoundOp(p = DotDotLt, consumed = 3) }
  else if c0 == '.' and c1 == '.'               { FoundOp(p = DotDot, consumed = 2) }
  else if c0 == '-' and c1 == '>'               { FoundOp(p = Arrow, consumed = 2) }
  else if c0 == '=' and c1 == '>'               { FoundOp(p = FatArrow, consumed = 2) }
  else if c0 == ':' and c1 == ':'               { FoundOp(p = ColonColon, consumed = 2) }
  else if c0 == '?' and c1 == '?'               { FoundOp(p = QuestionQuestion, consumed = 2) }
  else if c0 == '=' and c1 == '='               { FoundOp(p = EqEq, consumed = 2) }
  else if c0 == '!' and c1 == '='               { FoundOp(p = NotEq, consumed = 2) }
  else if c0 == '<' and c1 == '='               { FoundOp(p = LtEq, consumed = 2) }
  else if c0 == '>' and c1 == '='               { FoundOp(p = GtEq, consumed = 2) }
  else if c0 == '+' and c1 == '='               { FoundOp(p = PlusEq, consumed = 2) }
  else if c0 == '-' and c1 == '='               { FoundOp(p = MinusEq, consumed = 2) }
  else if c0 == '*' and c1 == '='               { FoundOp(p = StarEq, consumed = 2) }
  else if c0 == '/' and c1 == '='               { FoundOp(p = SlashEq, consumed = 2) }
  else if c0 == '%' and c1 == '='               { FoundOp(p = PercentEq, consumed = 2) }
  else if c0 == '?'                             { FoundOp(p = Question, consumed = 1) }
  else if c0 == '@'                             { FoundOp(p = At, consumed = 1) }
  else if c0 == '+'                             { FoundOp(p = Plus, consumed = 1) }
  else if c0 == '-'                             { FoundOp(p = Minus, consumed = 1) }
  else if c0 == '*'                             { FoundOp(p = Star, consumed = 1) }
  else if c0 == '/'                             { FoundOp(p = Slash, consumed = 1) }
  else if c0 == '%'                             { FoundOp(p = Percent, consumed = 1) }
  else if c0 == '<'                             { FoundOp(p = Lt, consumed = 1) }
  else if c0 == '>'                             { FoundOp(p = Gt, consumed = 1) }
  else if c0 == '='                             { FoundOp(p = Eq, consumed = 1) }
  else if c0 == '!'                             { FoundOp(p = Bang, consumed = 1) }
  else if c0 == '|'                             { FoundOp(p = Pipe, consumed = 1) }
  else if c0 == '&'                             { FoundOp(p = Amp, consumed = 1) }
  else if c0 == '('                             { FoundOp(p = LParen, consumed = 1) }
  else if c0 == ')'                             { FoundOp(p = RParen, consumed = 1) }
  else if c0 == '['                             { FoundOp(p = LBracket, consumed = 1) }
  else if c0 == ']'                             { FoundOp(p = RBracket, consumed = 1) }
  else if c0 == '{'                             { FoundOp(p = LBrace, consumed = 1) }
  else if c0 == '}'                             { FoundOp(p = RBrace, consumed = 1) }
  else if c0 == ','                             { FoundOp(p = Comma, consumed = 1) }
  else if c0 == ';'                             { FoundOp(p = Semi, consumed = 1) }
  else if c0 == ':'                             { FoundOp(p = Colon, consumed = 1) }
  else if c0 == '.'                             { FoundOp(p = Dot, consumed = 1) }
  else                                          { NoOp }
}

@pure
func punctIsSemi(p: in Punct): Bool {
  match p {
    case Semi -> true
    case _    -> false
  }
}

func lexPunct(state: inout LexerState): Unit {
  val startP = currentPosition(state)
  val c0 = peek(state)
  val c1 = peekAt(state, 1)
  val c2 = peekAt(state, 2)
  match tryMatchOperator(c0, c1, c2) {
    case FoundOp(p, n) -> {
      var i = 0
      while i < n {
        advance(state)
        i = i + 1
      }
      if punctIsSemi(p) {
        // Explicit `;` always wins over the suppression rules and
        // emits STMT_END.
        maybeEmitStmtEnd(state)
        val sp = makeSpan(startP, currentPosition(state))
        state.tokens.add(SpannedToken(token = TStmtEnd, span = sp))
        state.prevWasStmtEnd = true
        state.prevSuppresses = false
        state.haveAnyToken = true
      } else {
        emit(state, TPunct(p = p), startP)
      }
    }
    case NoOp -> {
      val c = advance(state)
      recordError(state, "L0030",
                  "unexpected character '" + charToString(c) + "'",
                  makeSpan(startP, currentPosition(state)))
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level lexer loop.
// ─────────────────────────────────────────────────────────────────────────────

func lexOne(state: inout LexerState): Unit {
  skipTrivia(state)
  if isAtEnd(state) { return }
  val c = peek(state)
  if isDigitChar(c) {
    lexNumber(state)
  } else if isIdStart(c) {
    lexIdentOrKeyword(state)
  } else if c == '"' {
    lexStringLiteral(state)
  } else if c == '\'' {
    lexCharLiteral(state)
  } else {
    lexPunct(state)
  }
}

@pure
func normaliseLineEndings(s: in String): String {
  // CRLF → LF, then bare CR → LF.  Sources that already use LF
  // round-trip through unchanged buffers.
  s.replace("\r\n", "\n").replace("\r", "\n")
}

/// Lex `source` into a `LexResult`.  The result always contains a
/// trailing `TEof`; diagnostics include all the recoverable lexer
/// errors with their `L00xx` codes, matching the bootstrap.
@stable(since="0.1")
pub func lex(source: in String): LexResult {
  val normalised = normaliseLineEndings(source)
  val state = newState(normalised)
  while not isAtEnd(state) {
    lexOne(state)
  }
  // Final STMT_END if the file ended on a real statement.
  skipTrivia(state)
  if state.newlinePending and state.bracketDepth == 0
     and state.haveAnyToken
     and not state.prevSuppresses
     and not state.prevWasStmtEnd {
    val sp = pointSpan(currentPosition(state))
    state.tokens.add(SpannedToken(token = TStmtEnd, span = sp))
    state.prevWasStmtEnd = true
  }
  state.newlinePending = false
  // EOF marker.
  val eofSp = pointSpan(currentPosition(state))
  state.tokens.add(SpannedToken(token = TEof, span = eofSp))
  LexResult(tokens = state.tokens, diagnostics = state.diagnostics)
}
// ─────────────────────────────────────────────────────────────────────────────
// Token-shape predicates.
//
// The bootstrap codegen does not yet support nested constructor patterns
// (`case TPunct(LParen)`), so tests inspect tokens through small
// `is*` / `*Value` helpers that nest one `match` per layer.
// ─────────────────────────────────────────────────────────────────────────────

func tokenName(t: in Token): String {
  match t {
    case TKeyword(_)          -> "keyword"
    case TIdent(_)            -> "ident"
    case TInt(_, _)           -> "int"
    case TFloat(_, _)         -> "float"
    case TChar(_)             -> "char"
    case TString(_)           -> "string"
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
  // intValueAt returns Long; assertEqualInt expects Int.  Cast via
  // explicit comparison to keep the assertion path on the Int helper.
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
  // Floating-point comparisons on the hand-rolled parser tolerate a
  // small epsilon; values are simple enough that exact equality holds.
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
  // Expected payload: a, newline, b, tab, c, backslash, d.
  assertEqual(stringValueAt(r, 0), "a\nb\tc\\d", "string-esc: value")
}

func testUnterminatedString(): Unit {
  val r = lex("\"oops")
  assertEqualInt(diagCount(r), 1, "unterm: one diagnostic")
  assertEqual(r.diagnostics[0].code, "L0025", "unterm: L0025")
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
  // A newline between two ident tokens must produce a STMT_END.
  val r = lex("foo\nbar")
  assertEqualInt(r.tokens.count, 4, "stmt-end: foo STMT_END bar EOF")
  assertEqual(tokenKindAt(r, 0), "ident",    "stmt-end: foo")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "stmt-end: synthesised")
  assertEqual(tokenKindAt(r, 2), "ident",    "stmt-end: bar")
}

func testStmtEndSuppressedAfterOperator(): Unit {
  // `+` is in the suppression set.  No STMT_END after it.
  val r = lex("a +\nb")
  assertEqualInt(r.tokens.count, 4, "stmt-end suppressed: token count")
  assertEqual(tokenKindAt(r, 0), "ident", "stmt-end suppressed: a")
  assertEqual(tokenKindAt(r, 1), "punct", "stmt-end suppressed: +")
  assertEqual(tokenKindAt(r, 2), "ident", "stmt-end suppressed: b — no STMT_END between + and b")
}

func testStmtEndSuppressedInsideBrackets(): Unit {
  // A newline inside `(…)` is a continuation, never a statement
  // terminator, regardless of the previous token.
  val r = lex("(a\nb)")
  // `(`, a, b, `)`, EOF — no STMT_END.
  assertEqualInt(r.tokens.count, 5, "brackets: token count")
  assertEqual(tokenKindAt(r, 0), "punct", "brackets: (")
  assertEqual(tokenKindAt(r, 1), "ident", "brackets: a")
  assertEqual(tokenKindAt(r, 2), "ident", "brackets: b")
  assertEqual(tokenKindAt(r, 3), "punct", "brackets: )")
}

func testExplicitSemicolon(): Unit {
  val r = lex("a;b")
  // a, STMT_END (from ;), b, EOF.
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
  // Block comment is dropped; foo + bar + EOF.
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
  // Trailing newline triggers STMT_END before next ident.
  assertEqual(tokenKindAt(r, 1), "stmt_end", "doc: STMT_END after newline")
  assertEqual(identNameAt(r, 2), "foo", "doc: foo follows")
}

func testModuleDocComment(): Unit {
  val r = lex("//! module overview\n")
  // module_doc + STMT_END + EOF.  Doc-comment tokens are ordinary
  // statement-terminators (not in the suppression set).
  assertEqualInt(r.tokens.count, 3, "module doc: token count")
  assertEqual(tokenKindAt(r, 0), "module_doc", "module doc: kind")
}

func testCrlfNormalisation(): Unit {
  // CRLF must normalise to LF; the resulting STMT_END appears between
  // foo and bar, not as two separate events.
  val r = lex("foo\r\nbar")
  assertEqualInt(r.tokens.count, 4, "crlf: token count")
  assertEqual(tokenKindAt(r, 0), "ident",    "crlf: foo")
  assertEqual(tokenKindAt(r, 1), "stmt_end", "crlf: STMT_END")
  assertEqual(tokenKindAt(r, 2), "ident",    "crlf: bar")
}

func testFullPackageHeader(): Unit {
  // A small but realistic Lyric source — package + import + a func.
  val r = lex("package Foo.Bar\n\nimport Std.Core\n\nfunc add(x: in Int, y: in Int): Int {\n  x + y\n}\n")
  // Drive a scan of every token; assert no diagnostics surfaced and
  // the trailing token is EOF.
  assertEqualInt(diagCount(r), 0, "full: no diagnostics")
  val last = r.tokens.count - 1
  assertEqual(tokenKindAt(r, last), "eof", "full: ends in eof")
  // First three tokens: `package`, `Foo`, `.`.
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
  testFullPackageHeader()
  println("lexer self-test: ok")
}
