namespace Lyric.Lexer

/// Type suffix on an integer literal (per docs/grammar.ebnf §1.8).
type IntSuffix =
    | I8 | I16 | I32 | I64
    | U8 | U16 | U32 | U64
    | NoIntSuffix

/// Type suffix on a float literal.
type FloatSuffix =
    | F32 | F64
    | NoFloatSuffix

/// A reserved keyword (per docs/grammar.ebnf §1.5).
/// The constructor name has 'Kw' prefix to avoid colliding with the F#
/// keywords (e.g. 'KwOf' vs F# 'of'). Each constructor has a single
/// canonical lowercase spelling, recovered via Keywords.spelling.
type Keyword =
    | KwAlias | KwAnd | KwAs | KwAsync | KwAwait
    | KwBind | KwCase | KwDo | KwElse | KwEnd
    | KwEnsures | KwEntry | KwEnum | KwExposed | KwExtern
    | KwFalse | KwFixture | KwFor | KwFunc | KwGeneric
    | KwIf | KwImpl | KwImport | KwIn | KwInout
    | KwInterface | KwInvariant | KwIs | KwLet | KwMatch
    | KwMut | KwNot | KwOld | KwOpaque | KwOr
    | KwOut | KwPackage | KwProperty | KwProtected | KwPub
    | KwRecord | KwRequires | KwResult | KwReturn | KwScope
    | KwScoped | KwSelf | KwSingleton | KwSpawn | KwTest
    | KwThen | KwThrow | KwTrue | KwTry | KwType
    | KwUnion | KwUse | KwVal | KwVar | KwWhen
    | KwWhere | KwWhile | KwWire | KwWith | KwXor

/// A multi-char punctuation/operator token (per docs/grammar.ebnf §1.9).
type Punct =
    // Range and arrow tokens.
    | DotDotEq                  // ..=
    | DotDotLt                  // ..<
    | DotDot                    // ..
    | Arrow                     // ->
    | FatArrow                  // =>
    | ColonColon                // ::
    // Single- and double-char question/at.
    | Question                  // ?
    | QuestionQuestion          // ??
    | At                        // @
    // Comparison.
    | EqEq | NotEq | LtEq | GtEq | Lt | Gt
    // Compound assignment.
    | PlusEq | MinusEq | StarEq | SlashEq | PercentEq
    // Arithmetic.
    | Plus | Minus | Star | Slash | Percent
    // Plain.
    | Eq | Bang
    // Brackets.
    | LParen | RParen | LBracket | RBracket | LBrace | RBrace
    // Separators.
    | Comma | Semi | Colon | Dot

/// A token produced by the lexer.
///
/// String-literal tokenisation (per docs/grammar.ebnf §1.8) emits a
/// non-interpolated string as a single TString. Interpolation support
/// (TStringStart / TStringPart / TStringHoleStart / TStringEnd) lands
/// in a follow-up commit.
type Token =
    | TKeyword of Keyword
    | TIdent   of string

    /// Integer-literal magnitude (the parser handles unary minus). The
    /// suffix narrows the inferred type per the grammar; without a
    /// suffix the type is decided in semantic analysis.
    | TInt     of value: uint64 * suffix: IntSuffix

    | TFloat   of value: double * suffix: FloatSuffix

    /// A character literal — a single Unicode scalar value, stored as
    /// an Int32 codepoint.
    | TChar    of int

    /// A complete plain string literal (no interpolation). Emitted by
    /// the lexer when a "..." literal contains no '${' holes — the
    /// common case. Strings with interpolation are emitted as the
    /// multi-token sequence below.
    | TString  of string

    /// Beginning of an interpolated string literal — the opening '"'.
    /// Followed by zero or more (TStringPart, TStringHoleStart,
    /// ...expr-tokens..., RBrace) tuples, then a final TStringPart
    /// (possibly empty) and TStringEnd.
    | TStringStart

    /// A run of literal characters inside an interpolated string,
    /// between holes (or between '"' and the first hole, or between
    /// the last hole and the closing '"').
    | TStringPart of string

    /// The '${' that opens an interpolation hole. The expression
    /// inside is lexed as ordinary tokens; the matching '}' is a
    /// regular RBrace, the lexer pops back into string mode after it.
    | TStringHoleStart

    /// The closing '"' of an interpolated string.
    | TStringEnd

    /// Triple-quoted multiline string ('"""..."""').
    | TTripleString of string

    /// Raw string (`r"..."` / `r#"..."#`).
    | TRawString of string

    | TBool    of bool
    | TPunct   of Punct
    | TStmtEnd

    /// '///' doc comment for the following item; payload is the comment
    /// text without the leading '///' (one comment per line).
    | TDocComment of string

    /// '//!' doc comment for the enclosing module.
    | TModuleDocComment of string

    | TEof

/// A token together with its source span.
type SpannedToken =
    { Token: Token
      Span:  Span }
