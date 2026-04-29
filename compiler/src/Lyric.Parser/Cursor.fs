/// Token-stream cursor used by the parser. Wraps the lexer's
/// SpannedToken array, tracking the current index and providing the
/// peek / advance / expect primitives the recursive-descent parser
/// builds on top of.
///
/// `Cursor` is mutable for performance; the Parser module is the only
/// consumer and the cursor never escapes its activation.
module Lyric.Parser.Cursor

open Lyric.Lexer

/// Mutable cursor over a token sequence. Constructed via `make`; the
/// fields are exposed for direct read access but should be mutated only
/// via the helper functions below.
type Cursor =
    { Tokens:    SpannedToken[]
      mutable I: int }

let make (tokens: SpannedToken seq) : Cursor =
    { Tokens = Array.ofSeq tokens; I = 0 }

/// Number of tokens (including the trailing TEof).
let length (c: Cursor) : int = c.Tokens.Length

/// True when the cursor is positioned at TEof or beyond it.
let isAtEnd (c: Cursor) : bool =
    c.I >= c.Tokens.Length || c.Tokens.[c.I].Token = TEof

/// Look at the current token without consuming it. At EOF the helper
/// returns the synthetic TEof token from the stream so callers do not
/// need a special case.
let peek (c: Cursor) : SpannedToken =
    if c.I >= c.Tokens.Length then
        // The lexer always appends a TEof; this branch only fires on a
        // pathological empty input, where we still need a sane value.
        let p = Position.initial
        { Token = TEof; Span = Span.pointAt p }
    else
        c.Tokens.[c.I]

/// Look k tokens ahead (k = 0 is the current token).
let peekAt (c: Cursor) (k: int) : SpannedToken =
    let i = c.I + k
    if i < 0 || i >= c.Tokens.Length then
        let p = Position.initial
        { Token = TEof; Span = Span.pointAt p }
    else
        c.Tokens.[i]

/// Token-kind shortcut for the common peek-and-discriminate case.
let peekToken (c: Cursor) : Token = (peek c).Token

/// Span of the current token.
let peekSpan (c: Cursor) : Span = (peek c).Span

/// Consume and return the current token.
let advance (c: Cursor) : SpannedToken =
    let t = peek c
    if c.I < c.Tokens.Length then c.I <- c.I + 1
    t

/// Save / restore the cursor position. Used for backtracking limited
/// lookaheads (`tryParse` style helpers).
let mark (c: Cursor) : int = c.I
let reset (c: Cursor) (pos: int) = c.I <- pos

/// Skip any number of TStmtEnd tokens, returning how many were dropped.
/// Useful where the grammar permits arbitrarily many blank lines.
let skipStmtEnds (c: Cursor) : int =
    let mutable n = 0
    while peekToken c = TStmtEnd do
        c.I <- c.I + 1
        n <- n + 1
    n

/// Predicate-based one-token consumer. Returns Some t and advances on
/// match; returns None and leaves the cursor untouched on mismatch.
let tryEat (pred: Token -> bool) (c: Cursor) : SpannedToken option =
    let t = peek c
    if pred t.Token then
        c.I <- c.I + 1
        Some t
    else None

/// Match a specific keyword, advancing on success.
let tryEatKeyword (kw: Keyword) (c: Cursor) : SpannedToken option =
    tryEat (function TKeyword k when k = kw -> true | _ -> false) c

/// Match a specific Punct, advancing on success.
let tryEatPunct (p: Punct) (c: Cursor) : SpannedToken option =
    tryEat (function TPunct q when q = p -> true | _ -> false) c

/// Match an identifier, advancing on success and returning its name.
let tryEatIdent (c: Cursor) : (string * Span) option =
    match peekToken c with
    | TIdent name ->
        let span = peekSpan c
        c.I <- c.I + 1
        Some (name, span)
    | _ -> None
