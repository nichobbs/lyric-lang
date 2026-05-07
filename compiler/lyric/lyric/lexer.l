// lyric/lexer.l — self-hosted Lyric lexer (Phase 5 §M5.1 stage 2b).
//
// Mirrors the F# bootstrap lexer at compiler/src/Lyric.Lexer/Lexer.fs:
// produces the same token stream over a UTF-8 source string, applies
// the same statement-terminator-insertion rules, and records the same
// diagnostic codes for malformed input.  This file is the reusable
// `Lyric.Lexer` library; the in-process self-test that exercises it
// lives at `compiler/lyric/lyric/lexer_self_test.l`.
//
// Phase 5 §M5.1 stage 3 (this file): string interpolation, triple-
// quoted and raw strings landed; the new tokens (TStringStart,
// TStringPart, TStringHoleStart, TStringEnd, TTripleString,
// TRawString) plus the InString / InHole mode stack mirror
// `compiler/src/Lyric.Lexer/Lexer.fs` 1:1.
//
// Phase 5 §M5.1 stage 4 (this file): full UAX #31 identifier
// support — NFC normalisation of lexemes via
// `System.String.Normalize` (BCL instance method), the L0040
// reserved-name diagnostic for `_X` identifiers, and non-ASCII
// XID_Start / XID_Continue acceptance via `Std.UnicodeHost`'s
// `System.Char.GetUnicodeCategory` extern.  The category integers
// match `System.Globalization.UnicodeCategory`'s enum ordering;
// see `compiler/lyric/std/_kernel/unicode_host.l` for the constants.
//
// Scope still deferred:
//   * Non-BMP `\u{…}` escapes (would need a wider TChar payload).
//
// Everything else from the F# lexer's grammar §1 implementation lives
// here: identifiers, the full keyword table, decimal/hex/octal/binary
// integer literals (with underscore separators and type suffixes), float
// literals (with optional exponent and `f32`/`f64` suffix), single-quoted
// string literals with the common escape set, character literals, the
// full punctuation table, line + nested block comments, doc/module-doc
// comments, and statement-end insertion with the same suppression set
// used by the bootstrap.
package Lyric.Lexer

import Std.Core
import Std.Collections
import Std.String as Str
import Std.UnicodeHost


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
// Trivia — the lossless `red/green` foundation.  Every `SpannedToken`
// carries the run of whitespace, newlines, and (non-doc) comments that
// preceded it in source order, so a downstream consumer (a formatter,
// LSP, or refactoring tool) can reconstruct the source byte-for-byte.
// Doc and module-doc comments remain real tokens (`TDocComment` /
// `TModuleDocComment`) because the parser binds them into the AST.
// Trailing-trivia attachment (Roslyn-style split at end-of-line) is not
// performed; the entire run between two real tokens is recorded as the
// second token's `leadingTrivia`.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub union TriviaKind {
  case TKWhitespace
  case TKNewline
  case TKLineComment
  case TKBlockComment
}

@stable(since="0.1")
pub record Trivia {
  kind: TriviaKind
  text: String
  span: Span
}

// ─────────────────────────────────────────────────────────────────────────────
// Tokens — mirror compiler/src/Lyric.Lexer/Token.fs.
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
  case KwInternal
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
  /// A complete plain string literal (no interpolation).  Emitted by
  /// `lexStringLiteral` for the common case.
  case TString(text: String)
  /// Beginning of an interpolated string literal — the opening `"`.
  /// Followed by a sequence of `TStringPart` (literal chunks) and
  /// `TStringHoleStart` … `}` … (interpolation expressions), and
  /// terminated by `TStringEnd` on the closing `"`.
  case TStringStart
  /// A run of literal characters inside an interpolated string.
  /// The text has all the same escape processing as `TString`.
  case TStringPart(text: String)
  /// The `${` that opens an interpolation hole.  The expression
  /// inside is lexed by the regular dispatcher; the hole closes
  /// when bracket depth returns to its pre-hole value.
  case TStringHoleStart
  /// The closing `"` of an interpolated string.
  case TStringEnd
  /// Triple-quoted multiline string (`"""…"""`).
  case TTripleString(text: String)
  /// Raw string (`r"…"` / `r#"…"#`).  Body is captured byte-for-byte;
  /// no escape processing happens.
  case TRawString(text: String)
  case TBool(value: Bool)
  case TPunct(p: Punct)
  case TStmtEnd
  case TDocComment(text: String)
  case TModuleDocComment(text: String)
  case TEof
}

@stable(since="0.1")
pub record SpannedToken {
  token:         Token
  span:          Span
  /// Whitespace, newlines, and non-doc comments that appeared in the
  /// source between the previous token's end and this token's start.
  /// Always non-null; empty for the very first token in a file (and for
  /// synthetic tokens manufactured by the parser at out-of-bounds peek
  /// positions).  See the `Trivia` union for the recognised kinds.
  leadingTrivia: List[Trivia]
}

/// Construct a `SpannedToken` with no leading trivia.  Used by helpers
/// that synthesise tokens (sentinels for out-of-bounds peeks, and
/// constructors prior to trivia capture wiring).
@stable(since="0.1")
pub func makeSpannedToken(tok: in Token, sp: in Span): SpannedToken {
  val empty: List[Trivia] = newList()
  SpannedToken(token = tok, span = sp, leadingTrivia = empty)
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
    case KwInternal  -> "internal"
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

/// Match an identifier-shaped string against the keyword table.
/// Soft keywords (`range`, `derives`, `forall`, `exists`, `implies`,
/// `scope_kind`) are NOT recognised here — the parser resolves them
/// contextually.
@pure
@stable(since="0.1")
pub func tryKeywordFromString(s: in String): Option[Keyword] {
  // The keyword table is closed and small; an explicit cascade keeps
  // the lookup allocation-free and its branches obvious.  Once the
  // self-hosted compiler grows a `Std.Map` with first-class hash
  // tables this can collapse to a hashed lookup.
  if s == "alias"     { Some(value = KwAlias) }
  else if s == "and"       { Some(value = KwAnd) }
  else if s == "as"        { Some(value = KwAs) }
  else if s == "async"     { Some(value = KwAsync) }
  else if s == "await"     { Some(value = KwAwait) }
  else if s == "bind"      { Some(value = KwBind) }
  else if s == "case"      { Some(value = KwCase) }
  else if s == "do"        { Some(value = KwDo) }
  else if s == "else"      { Some(value = KwElse) }
  else if s == "end"       { Some(value = KwEnd) }
  else if s == "ensures"   { Some(value = KwEnsures) }
  else if s == "entry"     { Some(value = KwEntry) }
  else if s == "enum"      { Some(value = KwEnum) }
  else if s == "exposed"   { Some(value = KwExposed) }
  else if s == "extern"    { Some(value = KwExtern) }
  else if s == "false"     { Some(value = KwFalse) }
  else if s == "fixture"   { Some(value = KwFixture) }
  else if s == "for"       { Some(value = KwFor) }
  else if s == "func"      { Some(value = KwFunc) }
  else if s == "generic"   { Some(value = KwGeneric) }
  else if s == "if"        { Some(value = KwIf) }
  else if s == "impl"      { Some(value = KwImpl) }
  else if s == "import"    { Some(value = KwImport) }
  else if s == "in"        { Some(value = KwIn) }
  else if s == "inout"     { Some(value = KwInout) }
  else if s == "interface" { Some(value = KwInterface) }
  else if s == "internal"  { Some(value = KwInternal) }
  else if s == "invariant" { Some(value = KwInvariant) }
  else if s == "is"        { Some(value = KwIs) }
  else if s == "let"       { Some(value = KwLet) }
  else if s == "match"     { Some(value = KwMatch) }
  else if s == "mut"       { Some(value = KwMut) }
  else if s == "not"       { Some(value = KwNot) }
  else if s == "old"       { Some(value = KwOld) }
  else if s == "opaque"    { Some(value = KwOpaque) }
  else if s == "or"        { Some(value = KwOr) }
  else if s == "out"       { Some(value = KwOut) }
  else if s == "package"   { Some(value = KwPackage) }
  else if s == "property"  { Some(value = KwProperty) }
  else if s == "protected" { Some(value = KwProtected) }
  else if s == "pub"       { Some(value = KwPub) }
  else if s == "record"    { Some(value = KwRecord) }
  else if s == "requires"  { Some(value = KwRequires) }
  else if s == "result"    { Some(value = KwResult) }
  else if s == "return"    { Some(value = KwReturn) }
  else if s == "scope"     { Some(value = KwScope) }
  else if s == "scoped"    { Some(value = KwScoped) }
  else if s == "self"      { Some(value = KwSelf) }
  else if s == "singleton" { Some(value = KwSingleton) }
  else if s == "spawn"     { Some(value = KwSpawn) }
  else if s == "test"      { Some(value = KwTest) }
  else if s == "then"      { Some(value = KwThen) }
  else if s == "throw"     { Some(value = KwThrow) }
  else if s == "true"      { Some(value = KwTrue) }
  else if s == "try"       { Some(value = KwTry) }
  else if s == "type"      { Some(value = KwType) }
  else if s == "union"     { Some(value = KwUnion) }
  else if s == "use"       { Some(value = KwUse) }
  else if s == "val"       { Some(value = KwVal) }
  else if s == "var"       { Some(value = KwVar) }
  else if s == "when"      { Some(value = KwWhen) }
  else if s == "where"     { Some(value = KwWhere) }
  else if s == "while"     { Some(value = KwWhile) }
  else if s == "wire"      { Some(value = KwWire) }
  else if s == "with"      { Some(value = KwWith) }
  else if s == "xor"       { Some(value = KwXor) }
  else                     { None }
}

// ─────────────────────────────────────────────────────────────────────────────
// LexResult and LexerState.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record LexResult {
  tokens:      List[SpannedToken]
  diagnostics: List[Diagnostic]
}

/// A lexer mode pushed onto an internal stack to track string-
/// interpolation context.  The stack is empty during normal top-
/// level lexing; the `InString` frame is pushed when a `"` opens an
/// interpolated literal, and an `InHole` frame is pushed when a
/// `${` opens an interpolation hole inside it.  Mirrors the F#
/// bootstrap's `Mode` union.
union Mode {
  /// Inside a `"…"` string.  `start` is the position of the
  /// opening `"`, used for span construction on `TStringPart` and
  /// for the unterminated-string diagnostic.
  case InString(start: Position)
  /// Inside an interpolation hole `${ … }`.  `depthBefore` is the
  /// `bracketDepth` recorded just before the hole's implicit `{`
  /// counted; when bracket depth returns to that value the hole
  /// has closed.
  case InHole(depthBefore: Int)
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
  // String / interpolation mode stack.  Empty during plain top-
  // level lexing; see the `Mode` union.
  modes:       List[Mode]
  // Trivia accumulated since the previous emit; flushed onto the next
  // emitted token's `leadingTrivia` (the synthesised STMT_END if one
  // is inserted first, otherwise the real token).  Always non-null.
  pendingTrivia: List[Trivia]
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
    diagnostics    = newList(),
    modes          = newList(),
    pendingTrivia  = newList()
  )
}

/// Drain `state.pendingTrivia` into a fresh list, leaving the buffer
/// empty.  Used by every token-emission site (real and synthetic) to
/// hand off the accumulated leading trivia atomically.
/// (`out` is a reserved parameter-mode keyword in this dialect, so the
/// local binding is named `drained`.)
func takePendingTrivia(state: inout LexerState): List[Trivia] {
  val drained = state.pendingTrivia
  state.pendingTrivia = newList()
  drained
}

/// Substring of the source covered by `[startOffset, endOffset)`.
@pure
func sourceSlice(state: in LexerState, startOffset: in Int, endOffset: in Int): String {
  Str.substring(state.source, startOffset, endOffset - startOffset)
}

/// Append a captured trivia run.  `startP` was recorded before the run
/// began; the current position bounds the end.
func recordTrivia(state: inout LexerState, kind: in TriviaKind, startP: in Position): Unit {
  val sp = makeSpan(startP, currentPosition(state))
  val text = sourceSlice(state, sp.startPos.offset, sp.endPos.offset)
  state.pendingTrivia.add(Trivia(kind = kind, text = text, span = sp))
}

/// `topMode`: peek the most recently pushed mode, if any.
func topMode(state: in LexerState): Option[Mode] {
  val n = state.modes.count
  if n == 0 {
    None
  } else {
    Some(value = state.modes[n - 1])
  }
}

func pushMode(state: inout LexerState, m: in Mode): Unit {
  state.modes.add(m)
}

func popMode(state: inout LexerState): Unit {
  val n = state.modes.count
  if n > 0 {
    state.modes.removeAt(n - 1)
  }
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
func isAscii(c: in Char): Bool {
  c <= '\u{007F}'
}

/// UAX #31 XID_Start (approximated through .NET's `UnicodeCategory`):
/// the ASCII fast path covers `[A-Za-z_]`; the non-ASCII path admits
/// any character whose category is `UppercaseLetter`,
/// `LowercaseLetter`, `TitlecaseLetter`, `ModifierLetter`,
/// `OtherLetter`, or `LetterNumber`.  Mirrors the F# bootstrap's
/// `isIdStart` (compiler/src/Lyric.Lexer/Lexer.fs lines 92-101).
@pure
func isIdStart(c: in Char): Bool {
  if isAscii(c) {
    isAsciiAlpha(c) or c == '_'
  } else {
    val cat = hostUnicodeCategory(c)
    cat == ucUppercaseLetter()
      or cat == ucLowercaseLetter()
      or cat == ucTitlecaseLetter()
      or cat == ucModifierLetter()
      or cat == ucOtherLetter()
      or cat == ucLetterNumber()
  }
}

/// UAX #31 XID_Continue: XID_Start plus combining marks
/// (`NonSpacingMark`, `SpacingCombiningMark`), decimal digits
/// (`DecimalDigitNumber`), and connector punctuation
/// (`ConnectorPunctuation` — i.e. `_` and friends).  Mirrors the F#
/// bootstrap's `isIdContinue` (lines 104-119).
@pure
func isIdContinue(c: in Char): Bool {
  if isAscii(c) {
    isAsciiAlpha(c) or isDigitChar(c) or c == '_'
  } else {
    val cat = hostUnicodeCategory(c)
    cat == ucUppercaseLetter()
      or cat == ucLowercaseLetter()
      or cat == ucTitlecaseLetter()
      or cat == ucModifierLetter()
      or cat == ucOtherLetter()
      or cat == ucLetterNumber()
      or cat == ucNonSpacingMark()
      or cat == ucSpacingCombiningMark()
      or cat == ucDecimalDigitNumber()
      or cat == ucConnectorPunctuation()
  }
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
func trackBracketDepthFor(state: inout LexerState, tok: in Token): Unit {
  match tok {
    case TPunct(p) -> {
      state.bracketDepth = bracketDelta(state.bracketDepth, p)
    }
    case _ -> ()
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
/// Mirrors `maybeEmitStmtEnd` in the F# lexer.  When inserted, the
/// pending trivia (the whitespace/newline/comment run that triggered
/// the boundary) attaches to the STMT_END as its leading trivia, so
/// the next real token starts with an empty trivia list.
func maybeEmitStmtEnd(state: inout LexerState): Unit {
  if state.newlinePending and state.bracketDepth == 0 {
    val suppress =
      state.prevWasStmtEnd or state.prevSuppresses or (not state.haveAnyToken)
    if not suppress {
      val sp = pointSpan(currentPosition(state))
      val triv = takePendingTrivia(state)
      state.tokens.add(SpannedToken(token = TStmtEnd, span = sp, leadingTrivia = triv))
      state.prevWasStmtEnd = true
      state.prevSuppresses = false
      state.haveAnyToken = true
    }
  }
  state.newlinePending = false
}

/// Emit a token, threading STMT_END insertion and bracket-depth
/// bookkeeping.  All non-STMT_END token writes go through here.  Any
/// pending trivia not consumed by an inserted STMT_END is attached to
/// `tok` as its leading trivia.
func emit(state: inout LexerState, tok: in Token, startP: in Position): Unit {
  maybeEmitStmtEnd(state)
  val sp = makeSpan(startP, currentPosition(state))
  val triv = takePendingTrivia(state)
  state.tokens.add(SpannedToken(token = tok, span = sp, leadingTrivia = triv))
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

/// Skip whitespace, line/block comments, and newlines, capturing each
/// run as a `Trivia` event into `state.pendingTrivia`.  Doc comments
/// (`///` and `//!`) remain real tokens emitted via `emitDocComment` /
/// `emitModuleDocComment` (which themselves flush the pending trivia
/// onto the doc-comment token's `leadingTrivia`).  Captured trivia is
/// attached to the next emitted token; see `emit` and
/// `maybeEmitStmtEnd`.
func skipTrivia(state: inout LexerState): Unit {
  while not isAtEnd(state) {
    val c = peek(state)
    if c == ' ' or c == '\t' {
      val startP = currentPosition(state)
      while not isAtEnd(state) and (peek(state) == ' ' or peek(state) == '\t') {
        val _ = advance(state)
      }
      recordTrivia(state, TKWhitespace, startP)
    } else if c == '\n' {
      val startP = currentPosition(state)
      val _ = advance(state)
      // Each '\n' is its own trivium so a formatter can preserve
      // intentional blank lines.  The STMT_END insertion logic still
      // gates on `newlinePending`, which is set per-newline below.
      state.newlinePending = true
      recordTrivia(state, TKNewline, startP)
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
    // Plain line comment — capture the run (excluding the trailing
    // newline, which the next `skipTrivia` iteration records on its
    // own as a TKNewline trivium).
    val startP = currentPosition(state)
    while not isAtEnd(state) and peek(state) != '\n' {
      val _ = advance(state)
    }
    recordTrivia(state, TKLineComment, startP)
  }
}

func consumeBlockComment(state: inout LexerState): Unit {
  val startP = currentPosition(state)
  advance(state)   // '/'
  advance(state)   // '*'
  skipBlockComment(state, startP)
  recordTrivia(state, TKBlockComment, startP)
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
  // Phase 5 §M5.1 stage 4: NFC-normalise the lexed identifier so
  // downstream stages compare canonical-equivalent spellings as
  // equal (per grammar.ebnf §1.4).  For pure ASCII identifiers
  // `Normalize` is a no-op; the cost is paid only on strings that
  // actually differ.
  val text = if buf.isNormalized() { buf } else { buf.normalize() }
  // Phase 5 §M5.1 stage 4: reject identifiers of the form `_`
  // followed by an ASCII uppercase letter — reserved for compiler-
  // generated names (grammar.ebnf §1.4).  The lexeme still flows
  // through as a TIdent so the parser keeps making progress on
  // recovery; only the diagnostic surfaces the policy.
  if isReservedUnderscoreUpper(text) {
    recordError(state, "L0040",
                reservedUnderscoreUpperMessage(text),
                makeSpan(startP, currentPosition(state)))
  }
  emitIdentOrKeywordToken(state, text, startP)
}

@pure
func isAsciiUpper(c: in Char): Bool {
  c >= 'A' and c <= 'Z'
}

@pure
func isReservedUnderscoreUpper(text: in String): Bool {
  text.length >= 2 and text[0] == '_' and isAsciiUpper(text[1])
}

@pure
func reservedUnderscoreUpperMessage(text: in String): String {
  "identifier '" + text
    + "' is reserved (leading '_' followed by an uppercase letter)"
}

/// Decide between `TBool`, `TKeyword`, and `TIdent` for a freshly
/// scanned identifier-shaped lexeme.  Hoisted out of `lexIdentOrKeyword`
/// because the bootstrap codegen mishandles a `match` whose arms
/// dispatch through three different `emit(...)` calls; keeping the
/// branch in a top-level helper lets each `emit` call own a
/// straight-line IL frame.
func emitIdentOrKeywordToken(state: inout LexerState, lexeme: in String, startP: in Position): Unit {
  match tryKeywordFromString(lexeme) {
    case Some(kw) -> emitKeywordToken(state, kw, startP)
    case None     -> emit(state, TIdent(name = lexeme), startP)
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
// String interpolation, triple-quoted, and raw strings (Phase 5 §M5.1
// stage 3).  Mirrors `compiler/src/Lyric.Lexer/Lexer.fs` 1:1 — see the
// docstrings on each helper for the per-shape rules.
// ─────────────────────────────────────────────────────────────────────────────

/// Lookahead from just past an opening `"`: scan for the first
/// occurrence of an unescaped `${`, closing `"`, newline, or EOF.
/// Returns true iff `${` is encountered first — that's the signal
/// to take the multi-token interpolation path instead of the simple
/// `TString` path.
@pure
func hasInterpolation(state: in LexerState): Bool {
  var i = state.pos + 1   // skip the `"` we're sitting on
  var result = false
  var stopped = false
  while not stopped {
    if i >= state.source.length {
      stopped = true
    } else {
      val c = state.source[i]
      if c == '"' {
        stopped = true
      } else if c == '\n' {
        stopped = true
      } else if c == '\\' {
        // Skip the backslash and the next char (the escape body).
        i = i + 2
      } else if c == '$' and i + 1 < state.source.length
                and state.source[i + 1] == '{' {
        result = true
        stopped = true
      } else {
        i = i + 1
      }
    }
  }
  return result
}

/// Open an interpolated string: emit `TStringStart`, push `InString`
/// mode.  The actual content + holes are consumed by the dispatcher
/// via `lexStringChunk` on subsequent steps.
func lexInterpolatedStringOpen(state: inout LexerState): Unit {
  val startP = currentPosition(state)
  advance(state)   // opening `"`
  emit(state, TStringStart, startP)
  pushMode(state, InString(start = startP))
}

/// Inside an `InString` frame: consume one chunk of string content.
/// Emits at most one `TStringPart` for the literal run, followed by
/// either `TStringEnd` (closing quote), `TStringHoleStart` + push
/// `InHole` (a `${`), or a diagnostic + `TStringEnd` on EOF / stray
/// newline.
func lexStringChunk(state: inout LexerState, stringStart: in Position): Unit {
  val chunkStart = currentPosition(state)
  var buf = ""
  var stopped = false
  // closeReason: 0 closed, 1 hole, 2 newline, 3 eof.
  var closeReason = 0
  while not stopped {
    if isAtEnd(state) {
      stopped = true
      closeReason = 3
    } else {
      val c = peek(state)
      if c == '"' {
        stopped = true
        closeReason = 0
      } else if c == '$' and peekAt(state, 1) == '{' {
        stopped = true
        closeReason = 1
      } else if c == '\n' {
        stopped = true
        closeReason = 2
      } else if c == '\\' {
        advance(state)    // consume the backslash
        val d = lexEscape(state, chunkStart)
        buf = buf + charToString(d)
      } else {
        buf = buf + charToString(advance(state))
      }
    }
  }
  if buf.length > 0 {
    emit(state, TStringPart(text = buf), chunkStart)
  }
  if closeReason == 0 {
    val endStart = currentPosition(state)
    advance(state)   // closing `"`
    emit(state, TStringEnd, endStart)
    popMode(state)
  } else if closeReason == 1 {
    val holeStart = currentPosition(state)
    advance(state)   // `$`
    advance(state)   // `{`
    emit(state, TStringHoleStart, holeStart)
    // The hole's implicit `{` counts toward bracketDepth so a
    // matching `}` decrements back to the saved depth, signalling
    // hole-close to the dispatcher.
    val depthBeforeHole = state.bracketDepth
    state.bracketDepth = state.bracketDepth + 1
    pushMode(state, InHole(depthBefore = depthBeforeHole))
  } else {
    recordError(state, "L0025",
                "unterminated string literal",
                makeSpan(stringStart, currentPosition(state)))
    emit(state, TStringEnd, currentPosition(state))
    popMode(state)
  }
}

/// Triple-quoted string.  Spans newlines; escapes processed
/// identically to a single-quoted string.  Closes on the first
/// occurrence of `"""` in the body.  Interpolation in the triple
/// form is reserved (the spec keeps it for a future slice).
func lexTripleString(state: inout LexerState): Unit {
  val startP = currentPosition(state)
  advance(state)   // first `"`
  advance(state)   // second `"`
  advance(state)   // third `"`
  var buf = ""
  var terminated = false
  while not terminated and not isAtEnd(state) {
    if peek(state) == '"' and peekAt(state, 1) == '"'
       and peekAt(state, 2) == '"' {
      advance(state)
      advance(state)
      advance(state)
      terminated = true
    } else if peek(state) == '\\' {
      advance(state)
      val d = lexEscape(state, startP)
      buf = buf + charToString(d)
    } else {
      buf = buf + charToString(advance(state))
    }
  }
  if not terminated {
    recordError(state, "L0026",
                "unterminated triple-quoted string literal",
                makeSpan(startP, currentPosition(state)))
  }
  emit(state, TTripleString(text = buf), startP)
}

/// Raw string: `r"…"` (no hashes) or `r#"…"#`, `r##"…"##`, etc.
/// Inside the body no escape processing happens — the body is
/// captured byte-for-byte.  Newlines are permitted.  The closing
/// delimiter is a `"` followed by the same number of `#`s used at
/// the opening.
func lexRawString(state: inout LexerState): Unit {
  val startP = currentPosition(state)
  advance(state)   // `r`
  var hashes = 0
  while peek(state) == '#' {
    advance(state)
    hashes = hashes + 1
  }
  if peek(state) != '"' {
    recordError(state, "L0027",
                "expected '\"' after 'r' (raw-string opener)",
                makeSpan(startP, currentPosition(state)))
    emit(state, TRawString(text = ""), startP)
    return
  }
  advance(state)   // opening `"`
  var buf = ""
  var terminated = false
  while not terminated and not isAtEnd(state) {
    if peek(state) == '"' {
      // Tentative close: peek ahead `hashes` hash characters.
      var i = 1
      var matched = true
      while matched and i <= hashes {
        if peekAt(state, i) != '#' { matched = false }
        i = i + 1
      }
      if matched {
        // Consume `"` plus `hashes` `#`s.
        advance(state)
        var k = 0
        while k < hashes {
          advance(state)
          k = k + 1
        }
        terminated = true
      } else {
        buf = buf + charToString(advance(state))
      }
    } else {
      buf = buf + charToString(advance(state))
    }
  }
  if not terminated {
    recordError(state, "L0028",
                "unterminated raw string literal",
                makeSpan(startP, currentPosition(state)))
  }
  emit(state, TRawString(text = buf), startP)
}

// ─────────────────────────────────────────────────────────────────────────────
// Punctuation and operators.
// ─────────────────────────────────────────────────────────────────────────────

/// Try to match a multi-/single-char operator at the cursor.  Returns
/// `Some((p, n))` with the matched `Punct` plus how many source chars
/// to advance, or `None` if no token is available.
@pure
func tryMatchOperator(c0: in Char, c1: in Char, c2: in Char): Option[(Punct, Int)] {
  if c0 == '.' and c1 == '.' and c2 == '=' { Some(value = (DotDotEq, 3)) }
  else if c0 == '.' and c1 == '.' and c2 == '<' { Some(value = (DotDotLt, 3)) }
  else if c0 == '.' and c1 == '.'               { Some(value = (DotDot, 2)) }
  else if c0 == '-' and c1 == '>'               { Some(value = (Arrow, 2)) }
  else if c0 == '=' and c1 == '>'               { Some(value = (FatArrow, 2)) }
  else if c0 == ':' and c1 == ':'               { Some(value = (ColonColon, 2)) }
  else if c0 == '?' and c1 == '?'               { Some(value = (QuestionQuestion, 2)) }
  else if c0 == '=' and c1 == '='               { Some(value = (EqEq, 2)) }
  else if c0 == '!' and c1 == '='               { Some(value = (NotEq, 2)) }
  else if c0 == '<' and c1 == '='               { Some(value = (LtEq, 2)) }
  else if c0 == '>' and c1 == '='               { Some(value = (GtEq, 2)) }
  else if c0 == '+' and c1 == '='               { Some(value = (PlusEq, 2)) }
  else if c0 == '-' and c1 == '='               { Some(value = (MinusEq, 2)) }
  else if c0 == '*' and c1 == '='               { Some(value = (StarEq, 2)) }
  else if c0 == '/' and c1 == '='               { Some(value = (SlashEq, 2)) }
  else if c0 == '%' and c1 == '='               { Some(value = (PercentEq, 2)) }
  else if c0 == '?'                             { Some(value = (Question, 1)) }
  else if c0 == '@'                             { Some(value = (At, 1)) }
  else if c0 == '+'                             { Some(value = (Plus, 1)) }
  else if c0 == '-'                             { Some(value = (Minus, 1)) }
  else if c0 == '*'                             { Some(value = (Star, 1)) }
  else if c0 == '/'                             { Some(value = (Slash, 1)) }
  else if c0 == '%'                             { Some(value = (Percent, 1)) }
  else if c0 == '<'                             { Some(value = (Lt, 1)) }
  else if c0 == '>'                             { Some(value = (Gt, 1)) }
  else if c0 == '='                             { Some(value = (Eq, 1)) }
  else if c0 == '!'                             { Some(value = (Bang, 1)) }
  else if c0 == '|'                             { Some(value = (Pipe, 1)) }
  else if c0 == '&'                             { Some(value = (Amp, 1)) }
  else if c0 == '('                             { Some(value = (LParen, 1)) }
  else if c0 == ')'                             { Some(value = (RParen, 1)) }
  else if c0 == '['                             { Some(value = (LBracket, 1)) }
  else if c0 == ']'                             { Some(value = (RBracket, 1)) }
  else if c0 == '{'                             { Some(value = (LBrace, 1)) }
  else if c0 == '}'                             { Some(value = (RBrace, 1)) }
  else if c0 == ','                             { Some(value = (Comma, 1)) }
  else if c0 == ';'                             { Some(value = (Semi, 1)) }
  else if c0 == ':'                             { Some(value = (Colon, 1)) }
  else if c0 == '.'                             { Some(value = (Dot, 1)) }
  else                                          { None }
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
    case Some((p, n)) -> {
      var i = 0
      while i < n {
        advance(state)
        i = i + 1
      }
      if punctIsSemi(p) {
        // Explicit `;` always wins over the suppression rules and
        // emits STMT_END.  Any trivia not consumed by an inserted
        // synthetic STMT_END attaches to the explicit `;` here.
        maybeEmitStmtEnd(state)
        val sp = makeSpan(startP, currentPosition(state))
        val triv = takePendingTrivia(state)
        state.tokens.add(SpannedToken(token = TStmtEnd, span = sp, leadingTrivia = triv))
        state.prevWasStmtEnd = true
        state.prevSuppresses = false
        state.haveAnyToken = true
      } else {
        emit(state, TPunct(p = p), startP)
      }
    }
    case None -> {
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
  // Raw-string prefix wins over the `r` identifier path.
  if c == 'r' and (peekAt(state, 1) == '"' or peekAt(state, 1) == '#') {
    lexRawString(state)
  // Triple-quoted string wins over the single-quoted form.
  } else if c == '"' and peekAt(state, 1) == '"' and peekAt(state, 2) == '"' {
    lexTripleString(state)
  } else if isDigitChar(c) {
    lexNumber(state)
  } else if isIdStart(c) {
    lexIdentOrKeyword(state)
  } else if c == '"' {
    // Decide between the simple `TString` path (no interpolation)
    // and the multi-token interpolated path.
    if hasInterpolation(state) {
      lexInterpolatedStringOpen(state)
    } else {
      lexStringLiteral(state)
    }
  } else if c == '\'' {
    lexCharLiteral(state)
  } else {
    lexPunct(state)
  }
}

/// One step of the top-level lexer.  Dispatches to either `lexOne`
/// (for normal / `InHole` frames) or `lexStringChunk` (for
/// `InString` frames).  After emitting a token in `InHole` context,
/// checks whether the matching `}` just closed the hole and pops
/// the `InHole` frame if so.
func lexNext(state: inout LexerState): Unit {
  match topMode(state) {
    case Some(InString(start)) -> lexStringChunk(state, start)
    case _ -> {
      lexOne(state)
      // Hole-close detection: emit() decremented bracketDepth on a
      // matching `}`.  If we're now back at the depth recorded at
      // hole entry, the hole has closed; pop and resume string
      // mode.
      match topMode(state) {
        case Some(InHole(saved)) -> {
          if state.bracketDepth == saved { popMode(state) }
        }
        case _ -> {}
      }
    }
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
    lexNext(state)
  }
  // Drain any open string / hole frames at EOF so the diagnostics
  // arrive in a well-defined order and the tokens stream stays
  // balanced (every TStringStart / TStringHoleStart eventually
  // pairs with a TStringEnd).
  while state.modes.count > 0 {
    match topMode(state) {
      case Some(InString(start)) -> lexStringChunk(state, start)
      case Some(InHole(_))       -> popMode(state)
      case None                  -> {}
    }
  }
  // Final STMT_END if the file ended on a real statement.
  skipTrivia(state)
  if state.newlinePending and state.bracketDepth == 0
     and state.haveAnyToken
     and not state.prevSuppresses
     and not state.prevWasStmtEnd {
    val sp = pointSpan(currentPosition(state))
    val stmtTriv = takePendingTrivia(state)
    state.tokens.add(SpannedToken(token = TStmtEnd, span = sp, leadingTrivia = stmtTriv))
    state.prevWasStmtEnd = true
  }
  state.newlinePending = false
  // EOF marker.  Any trailing trivia (final whitespace, a dangling
  // line comment without a newline, etc.) attaches here so
  // round-trip-formatting reproduces the original source byte-for-byte.
  val eofSp = pointSpan(currentPosition(state))
  val eofTriv = takePendingTrivia(state)
  state.tokens.add(SpannedToken(token = TEof, span = eofSp, leadingTrivia = eofTriv))
  LexResult(tokens = state.tokens, diagnostics = state.diagnostics)
}
