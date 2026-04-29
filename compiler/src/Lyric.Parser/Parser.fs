/// Lyric parser entry point.
///
/// Phase 1 milestone M1.1 work-in-progress. The current state covers
/// the file head — module doc comments, file-level annotations,
/// `package` declaration, and imports — plus item-head recognition:
/// every recognised top-level item keyword is consumed (with its body
/// skipped via balanced-brace scan) and produces an `IError`-tagged
/// AST node together with a `P0098` diagnostic. Typed item bodies
/// land in subsequent slices (P4 through P9).
module Lyric.Parser.Parser

open Lyric.Lexer
open Lyric.Lexer.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Cursor

/// A parsed source file together with the diagnostics produced during
/// parsing. The lexer's diagnostics are merged into the same list so
/// callers see a unified error report.
type ParseResult =
    { File:        SourceFile
      Diagnostics: Diagnostic list }

// ---------------------------------------------------------------------------
// Span helpers.
// ---------------------------------------------------------------------------

let private syntheticSpan = Span.pointAt Position.initial

/// Build a span covering [start, end) given two endpoint Positions.
let private spanFromTo (s: Position) (e: Position) : Span =
    Span.make s e

/// Span join: the smallest span covering both arguments. Caller is
/// responsible for ordering.
let private joinSpans (a: Span) (b: Span) : Span =
    Span.make a.Start b.End

// ---------------------------------------------------------------------------
// Diagnostics.
//
// Parser diagnostic codes start at P0001. The numbering is purely an
// internal cross-reference — the message is what users read.
// ---------------------------------------------------------------------------

let private err (diags: ResizeArray<Diagnostic>) code msg span =
    diags.Add(Diagnostic.error code msg span)

// ---------------------------------------------------------------------------
// Module-doc and ordinary-doc comment harvesting.
// ---------------------------------------------------------------------------

/// Consume any number of `//!` module doc comments at the cursor's
/// current position, separated by STMT_ENDs. Stops at the first
/// non-module-doc token.
let private parseModuleDocComments (cursor: Cursor) : DocComment list =
    let xs = ResizeArray<DocComment>()
    let mutable keepGoing = true
    while keepGoing do
        Cursor.skipStmtEnds cursor |> ignore
        match Cursor.peekToken cursor with
        | TModuleDocComment text ->
            let span = Cursor.peekSpan cursor
            Cursor.advance cursor |> ignore
            xs.Add({ IsModule = true; Text = text; Span = span })
        | _ ->
            keepGoing <- false
    List.ofSeq xs

/// Consume any number of `///` doc comments. Used at item-attachment
/// points; not consumed at the file head where module-doc takes over.
let private parseItemDocComments (cursor: Cursor) : DocComment list =
    let xs = ResizeArray<DocComment>()
    let mutable keepGoing = true
    while keepGoing do
        match Cursor.peekToken cursor with
        | TDocComment text ->
            let span = Cursor.peekSpan cursor
            Cursor.advance cursor |> ignore
            // Inline doc-comment runs are separated by STMT_ENDs. We
            // tolerate exactly one between each comment so that
            // /// line one
            // /// line two
            // groups together.
            Cursor.skipStmtEnds cursor |> ignore
            xs.Add({ IsModule = false; Text = text; Span = span })
        | _ -> keepGoing <- false
    List.ofSeq xs

// ---------------------------------------------------------------------------
// ModulePath: IDENT { '.' IDENT } .
// ---------------------------------------------------------------------------

let private parseModulePath
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ModulePath =

    let segments = ResizeArray<string>()
    let initialSpan = Cursor.peekSpan cursor
    let mutable startPos = initialSpan.Start
    let mutable endPos   = initialSpan.End
    let mutable haveStart = false

    let tryAppendIdent () =
        match Cursor.tryEatIdent cursor with
        | Some (name, span) ->
            if not haveStart then
                startPos  <- span.Start
                haveStart <- true
            endPos <- span.End
            segments.Add(name)
            true
        | None -> false

    if not (tryAppendIdent ()) then
        err diags "P0010" "expected an identifier in module path"
            (Cursor.peekSpan cursor)

    // Only continue past '.' when the token after it is itself an
    // identifier — that way an `import Foo.{...}` selector group does
    // not get misclassified as a malformed continuation of the path.
    let isDotIdent () =
        Cursor.peekToken cursor = TPunct Dot
        && (match (Cursor.peekAt cursor 1).Token with
            | TIdent _ -> true
            | _ -> false)
    while isDotIdent () do
        Cursor.advance cursor |> ignore
        tryAppendIdent () |> ignore

    { Segments = List.ofSeq segments
      Span     = spanFromTo startPos endPos }

// ---------------------------------------------------------------------------
// Annotations: '@' AnnotationName [ AnnotationArgs ] .
// ---------------------------------------------------------------------------

/// Parse a single argument inside `@name(...)`. Accepts:
///   * `name = value`     — keyword form
///   * `name`             — bare identifier (interpreted by post-parse passes)
///   * a literal value
let private parseAnnotationArg
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : AnnotationArg =

    // Snapshot for `name = value` lookahead.
    let savedPos = Cursor.mark cursor
    let starting = Cursor.peekSpan cursor

    // Try to match `IDENT '=' value`.
    match Cursor.peekToken cursor with
    | TIdent name ->
        Cursor.advance cursor |> ignore
        if Cursor.peekToken cursor = TPunct Eq then
            Cursor.advance cursor |> ignore
            // Keyword arg: `name = literal`.
            let valueSpan = Cursor.peekSpan cursor
            let value =
                match Cursor.advance cursor with
                | { Token = TInt(v, _); Span = s }    -> AVInt(v, s)
                | { Token = TString s';   Span = s }   -> AVString(s', s)
                | { Token = TBool b;      Span = s }   -> AVBool(b, s)
                | { Token = TIdent id;    Span = s }   -> AVIdent(id, s)
                | t ->
                    err diags "P0011"
                        "expected a literal or identifier as annotation value"
                        t.Span
                    AVIdent("<error>", t.Span)
            let total = joinSpans starting (
                match value with
                | AVInt(_, s) | AVString(_, s)
                | AVBool(_, s) | AVIdent(_, s) -> s)
            AAName(name, value, total)
        else
            // Bare identifier — `name`.
            ABare(name, starting)

    | TInt _ | TString _ | TBool _ ->
        Cursor.reset cursor savedPos
        let tok = Cursor.advance cursor
        let value =
            match tok.Token with
            | TInt(v, _) -> AVInt(v, tok.Span)
            | TString s -> AVString(s, tok.Span)
            | TBool b   -> AVBool(b, tok.Span)
            | _ ->
                AVIdent("<error>", tok.Span)
        ALiteral(value, tok.Span)

    | _ ->
        err diags "P0011" "expected an annotation argument" starting
        // Consume one token to make progress.
        Cursor.advance cursor |> ignore
        ALiteral(AVIdent("<error>", starting), starting)

let private parseAnnotation
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Annotation option =

    match Cursor.peekToken cursor with
    | TPunct At ->
        let atSpan = Cursor.peekSpan cursor
        Cursor.advance cursor |> ignore
        let name = parseModulePath cursor diags
        let args = ResizeArray<AnnotationArg>()
        let mutable endSpan = name.Span
        // Optional '(' arg-list ')'.
        if Cursor.peekToken cursor = TPunct LParen then
            Cursor.advance cursor |> ignore
            // Empty arg list?
            if Cursor.peekToken cursor <> TPunct RParen then
                args.Add(parseAnnotationArg cursor diags)
                while Cursor.peekToken cursor = TPunct Comma do
                    Cursor.advance cursor |> ignore
                    if Cursor.peekToken cursor = TPunct RParen then () // trailing comma
                    else args.Add(parseAnnotationArg cursor diags)
            match Cursor.tryEatPunct RParen cursor with
            | Some t -> endSpan <- t.Span
            | None ->
                err diags "P0012" "expected ')' to close annotation argument list"
                    (Cursor.peekSpan cursor)
        Some
            { Name = name
              Args = List.ofSeq args
              Span = joinSpans atSpan endSpan }
    | _ -> None

let private parseFileLevelAnnotations
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Annotation list =

    let xs = ResizeArray<Annotation>()
    let mutable keepGoing = true
    while keepGoing do
        Cursor.skipStmtEnds cursor |> ignore
        match parseAnnotation cursor diags with
        | Some a -> xs.Add(a)
        | None   -> keepGoing <- false
    List.ofSeq xs

// ---------------------------------------------------------------------------
// Package declaration: 'package' ModulePath .
// ---------------------------------------------------------------------------

let private parsePackageDecl
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : PackageDecl =

    Cursor.skipStmtEnds cursor |> ignore
    match Cursor.tryEatKeyword KwPackage cursor with
    | Some packageTok ->
        let path = parseModulePath cursor diags
        { Path = path
          Span = joinSpans packageTok.Span path.Span }
    | None ->
        err diags "P0020"
            "expected 'package' declaration at the head of the file"
            (Cursor.peekSpan cursor)
        { Path =
              { Segments = []
                Span     = Cursor.peekSpan cursor }
          Span = Cursor.peekSpan cursor }

// ---------------------------------------------------------------------------
// Imports.
//
// 'import' ModulePath [ '.' '{' ImportItem (',' ImportItem)* [','] '}' ]
//                     [ 'as' IDENT ]
// 'pub' 'use' ModulePath [ '.' '{' … '}' ] [ 'as' IDENT ]
//
// `import Foo.Bar` is parsed greedily as path=Foo.Bar, no group.
// `import Foo.{A, B}` is path=Foo with selectors=[A, B].
// `import Foo as F` aliases the whole import.
// ---------------------------------------------------------------------------

let private parseImportItem
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ImportItem =

    let nameTok = Cursor.peek cursor
    let name, nameSpan =
        match Cursor.tryEatIdent cursor with
        | Some (n, s) -> n, s
        | None ->
            err diags "P0030"
                "expected identifier in import group"
                nameTok.Span
            "<error>", nameTok.Span

    let alias, endSpan =
        match Cursor.tryEatKeyword KwAs cursor with
        | Some _ ->
            match Cursor.tryEatIdent cursor with
            | Some (a, sp) -> Some a, sp
            | None ->
                err diags "P0031"
                    "expected identifier after 'as' in import group"
                    (Cursor.peekSpan cursor)
                None, nameSpan
        | None -> None, nameSpan

    { Name = name
      Alias = alias
      Span = joinSpans nameSpan endSpan }

let private parseImportSelectorIfPresent
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ImportSelector option =

    // The `.{...}` group is the only selector form we recognise; the
    // bare `IDENT` form was already absorbed into the greedy ModulePath.
    if Cursor.peekToken cursor = TPunct Dot
       && (Cursor.peekAt cursor 1).Token = TPunct LBrace then
        Cursor.advance cursor |> ignore   // .
        Cursor.advance cursor |> ignore   // {
        let items = ResizeArray<ImportItem>()
        if Cursor.peekToken cursor <> TPunct RBrace then
            items.Add(parseImportItem cursor diags)
            while Cursor.peekToken cursor = TPunct Comma do
                Cursor.advance cursor |> ignore
                if Cursor.peekToken cursor = TPunct RBrace then () // trailing comma
                else items.Add(parseImportItem cursor diags)
        match Cursor.tryEatPunct RBrace cursor with
        | Some _ -> ()
        | None ->
            err diags "P0032"
                "expected '}' to close import group"
                (Cursor.peekSpan cursor)
        Some (ISGroup (List.ofSeq items))
    else
        None

/// Try to parse a single import declaration. Returns None if the
/// next token is not an import-starting keyword.
let private parseImportDecl
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ImportDecl option =

    let isPubUse =
        Cursor.peekToken cursor = TKeyword KwPub
        && (Cursor.peekAt cursor 1).Token = TKeyword KwUse
    let isImport =
        Cursor.peekToken cursor = TKeyword KwImport

    if not (isImport || isPubUse) then None
    else
        let startSpan = Cursor.peekSpan cursor
        if isPubUse then
            Cursor.advance cursor |> ignore   // pub
            Cursor.advance cursor |> ignore   // use
        else
            Cursor.advance cursor |> ignore   // import

        let path = parseModulePath cursor diags
        let selector = parseImportSelectorIfPresent cursor diags

        let alias, endSpan =
            match Cursor.tryEatKeyword KwAs cursor with
            | Some _ ->
                match Cursor.tryEatIdent cursor with
                | Some (a, sp) -> Some a, sp
                | None ->
                    err diags "P0033"
                        "expected identifier after 'as' in import"
                        (Cursor.peekSpan cursor)
                    None, path.Span
            | None ->
                None, path.Span

        Some
            { Path     = path
              Selector = selector
              Alias    = alias
              IsPubUse = isPubUse
              Span     = joinSpans startSpan endSpan }

let private parseImports
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ImportDecl list =

    let xs = ResizeArray<ImportDecl>()
    let mutable keepGoing = true
    while keepGoing do
        Cursor.skipStmtEnds cursor |> ignore
        match parseImportDecl cursor diags with
        | Some d -> xs.Add(d)
        | None   -> keepGoing <- false
    List.ofSeq xs

// ---------------------------------------------------------------------------
// Item recognition (P3 — bodies are skipped via balanced-brace scan;
// the typed body parsing lives in subsequent slices P4 through P8).
// ---------------------------------------------------------------------------

/// Item-level annotations (e.g. `@projectable`, `@derive(Json)`,
/// `@stubbable`) directly precede the item's keyword. Unlike the file-
/// level loop, this helper does not skip leading STMT_ENDs — we want to
/// stay attached to the next item.
let private parseItemAnnotations
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Annotation list =

    let xs = ResizeArray<Annotation>()
    let mutable keepGoing = true
    while keepGoing do
        match parseAnnotation cursor diags with
        | Some a ->
            xs.Add(a)
            // Tolerate one STMT_END between annotations and before
            // the item keyword: `@runtime_checked\n@axiom\nfunc foo`.
            Cursor.skipStmtEnds cursor |> ignore
        | None -> keepGoing <- false
    List.ofSeq xs

/// True when the next token can begin a top-level item.
let private isItemStartToken (tok: Token) : bool =
    match tok with
    | TKeyword kw ->
        match kw with
        | KwAlias | KwType | KwRecord | KwUnion | KwEnum
        | KwOpaque | KwProtected | KwExposed | KwInterface
        | KwImpl | KwWire | KwExtern | KwAsync | KwFunc
        | KwVal | KwGeneric | KwTest | KwProperty | KwFixture -> true
        | _ -> false
    // `scope_kind` is a soft keyword; lexed as a regular identifier.
    | TIdent "scope_kind" -> true
    | _ -> false

/// Skip past the current item: consume tokens until we either close the
/// outermost brace-delimited body or hit a top-level STMT_END (for
/// items with no body, e.g. `type X = Long range 0 ..= 99`). Returns the
/// span covering the skipped region.
let private skipItemBody (cursor: Cursor) : Span =
    let startSpan = Cursor.peekSpan cursor
    let mutable depth = 0
    let mutable seenBrace = false
    let mutable keepGoing = true
    let mutable lastSpan = startSpan
    while keepGoing && not (Cursor.isAtEnd cursor) do
        let tok = Cursor.peek cursor
        lastSpan <- tok.Span
        match tok.Token with
        | TPunct LBrace ->
            seenBrace <- true
            depth <- depth + 1
            Cursor.advance cursor |> ignore
        | TPunct LParen | TPunct LBracket ->
            depth <- depth + 1
            Cursor.advance cursor |> ignore
        | TPunct RBrace ->
            depth <- max 0 (depth - 1)
            Cursor.advance cursor |> ignore
            if seenBrace && depth = 0 then keepGoing <- false
        | TPunct RParen | TPunct RBracket ->
            depth <- max 0 (depth - 1)
            Cursor.advance cursor |> ignore
        | TStmtEnd when depth = 0 ->
            // `type X = Long`, `extern func ...` and similar one-line
            // items end here; do not consume the terminator itself.
            keepGoing <- false
        | _ ->
            Cursor.advance cursor |> ignore
    joinSpans startSpan lastSpan

/// Try to parse one top-level item. Returns None at EOF; otherwise
/// always returns Some, populating an IError-tagged Item on
/// unrecognised input so the parser keeps making progress.
let private parseItem
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Item option =

    Cursor.skipStmtEnds cursor |> ignore
    if Cursor.isAtEnd cursor then None
    else
        let prefixStart = Cursor.peekSpan cursor
        let docs = parseItemDocComments cursor
        let anns = parseItemAnnotations cursor diags
        let vis =
            match Cursor.tryEatKeyword KwPub cursor with
            | Some t -> Some (Pub t.Span)
            | None -> None

        let nextTok = Cursor.peek cursor
        if isItemStartToken nextTok.Token then
            err diags "P0098"
                "item-level parsing not yet implemented; body skipped"
                nextTok.Span
            let bodySpan = skipItemBody cursor
            let totalSpan = joinSpans prefixStart bodySpan
            Some
                { DocComments = docs
                  Annotations = anns
                  Visibility  = vis
                  Kind        = IError
                  Span        = totalSpan }
        else
            err diags "P0040"
                "expected an item declaration"
                nextTok.Span
            // Advance one token to guarantee progress.
            if not (Cursor.isAtEnd cursor) then
                Cursor.advance cursor |> ignore
            Some
                { DocComments = docs
                  Annotations = anns
                  Visibility  = vis
                  Kind        = IError
                  Span        = joinSpans prefixStart nextTok.Span }

let private parseItems
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Item list =

    let xs = ResizeArray<Item>()
    let mutable keepGoing = true
    while keepGoing do
        match parseItem cursor diags with
        | Some it -> xs.Add(it)
        | None    -> keepGoing <- false
    List.ofSeq xs

// ===========================================================================
//  P4: Expressions (minimal subset), type expressions, range bounds.
//
//  These productions form a small mutually-recursive group. The
//  expression parser here is intentionally minimal — just enough to
//  handle range bounds (`0 ..= 100`), array sizes (`array[16, T]`),
//  and value-generic arguments. The full precedence cascade lands in
//  P7 by replacing parsePrimaryExpr / parseAddExpr below.
// ===========================================================================

let private mkExpr (kind: ExprKind) (span: Span) : Expr =
    { Kind = kind; Span = span }

let private mkType (kind: TypeExprKind) (span: Span) : TypeExpr =
    { Kind = kind; Span = span }

let private literalFromToken (tok: Token) : Literal option =
    match tok with
    | TInt(v, sfx)        -> Some (LInt(v, sfx))
    | TFloat(v, sfx)      -> Some (LFloat(v, sfx))
    | TChar c             -> Some (LChar c)
    | TString s           -> Some (LString s)
    | TTripleString s     -> Some (LTripleString s)
    | TRawString s        -> Some (LRawString s)
    | TBool b             -> Some (LBool b)
    | _                   -> None

let rec private parsePrimaryExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    let tok = Cursor.peek cursor
    match tok.Token with
    | TInt _ | TFloat _ | TChar _ | TString _
    | TTripleString _ | TRawString _ | TBool _ ->
        Cursor.advance cursor |> ignore
        match literalFromToken tok.Token with
        | Some lit -> mkExpr (ELiteral lit) tok.Span
        | None     -> mkExpr EError tok.Span

    | TPunct LParen ->
        Cursor.advance cursor |> ignore
        // Empty parens: '()' — the unit value.
        if Cursor.peekToken cursor = TPunct RParen then
            let endTok = Cursor.advance cursor
            mkExpr (ELiteral LUnit) (joinSpans tok.Span endTok.Span)
        else
            let inner = parseExpr cursor diags
            // Tuple literal? `(a, b, c)`.
            if Cursor.peekToken cursor = TPunct Comma then
                let items = ResizeArray<Expr>()
                items.Add(inner)
                while Cursor.peekToken cursor = TPunct Comma do
                    Cursor.advance cursor |> ignore
                    if Cursor.peekToken cursor = TPunct RParen then ()
                    else items.Add(parseExpr cursor diags)
                let endSpan =
                    match Cursor.tryEatPunct RParen cursor with
                    | Some t -> t.Span
                    | None ->
                        err diags "P0051"
                            "expected ')' to close tuple expression"
                            (Cursor.peekSpan cursor)
                        (List.last (List.ofSeq items)).Span
                mkExpr (ETuple (List.ofSeq items))
                    (joinSpans tok.Span endSpan)
            else
                let endSpan =
                    match Cursor.tryEatPunct RParen cursor with
                    | Some t -> t.Span
                    | None ->
                        err diags "P0051"
                            "expected ')' to close parenthesised expression"
                            (Cursor.peekSpan cursor)
                        inner.Span
                mkExpr (EParen inner) (joinSpans tok.Span endSpan)

    | TIdent _ ->
        let path = parseModulePath cursor diags
        mkExpr (EPath path) path.Span

    | _ ->
        err diags "P0050"
            "expected an expression"
            tok.Span
        Cursor.advance cursor |> ignore
        mkExpr EError tok.Span

and private parsePrefixExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    match Cursor.peekToken cursor with
    | TPunct Minus ->
        let opTok = Cursor.advance cursor
        let inner = parsePrefixExpr cursor diags
        mkExpr (EPrefix(PreNeg, inner))
            (joinSpans opTok.Span inner.Span)
    | TKeyword KwNot ->
        let opTok = Cursor.advance cursor
        let inner = parsePrefixExpr cursor diags
        mkExpr (EPrefix(PreNot, inner))
            (joinSpans opTok.Span inner.Span)
    | TPunct Amp ->
        let opTok = Cursor.advance cursor
        let inner = parsePrefixExpr cursor diags
        mkExpr (EPrefix(PreRef, inner))
            (joinSpans opTok.Span inner.Span)
    | _ ->
        parsePrimaryExpr cursor diags

and private parseMulExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    let mutable lhs = parsePrefixExpr cursor diags
    let mutable keep = true
    while keep do
        match Cursor.peekToken cursor with
        | TPunct Star ->
            Cursor.advance cursor |> ignore
            let rhs = parsePrefixExpr cursor diags
            lhs <- mkExpr (EBinop(BMul, lhs, rhs)) (joinSpans lhs.Span rhs.Span)
        | TPunct Slash ->
            Cursor.advance cursor |> ignore
            let rhs = parsePrefixExpr cursor diags
            lhs <- mkExpr (EBinop(BDiv, lhs, rhs)) (joinSpans lhs.Span rhs.Span)
        | TPunct Percent ->
            Cursor.advance cursor |> ignore
            let rhs = parsePrefixExpr cursor diags
            lhs <- mkExpr (EBinop(BMod, lhs, rhs)) (joinSpans lhs.Span rhs.Span)
        | _ -> keep <- false
    lhs

and private parseAddExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    let mutable lhs = parseMulExpr cursor diags
    let mutable keep = true
    while keep do
        match Cursor.peekToken cursor with
        | TPunct Plus ->
            Cursor.advance cursor |> ignore
            let rhs = parseMulExpr cursor diags
            lhs <- mkExpr (EBinop(BAdd, lhs, rhs)) (joinSpans lhs.Span rhs.Span)
        | TPunct Minus ->
            Cursor.advance cursor |> ignore
            let rhs = parseMulExpr cursor diags
            lhs <- mkExpr (EBinop(BSub, lhs, rhs)) (joinSpans lhs.Span rhs.Span)
        | _ -> keep <- false
    lhs

and private parseExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    parseAddExpr cursor diags

// ---------------------------------------------------------------------------
// Range bounds: `lo ..= hi`, `lo ..< hi`, `lo .. hi`, `..= hi`, `lo ..`.
// ---------------------------------------------------------------------------

and private parseRangeBound
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : RangeBound =
    // Lower-open form: `..= hi` (no `lo` to its left).
    match Cursor.peekToken cursor with
    | TPunct DotDotEq ->
        Cursor.advance cursor |> ignore
        let hi = parseExpr cursor diags
        RBLowerOpen hi
    | TPunct DotDot | TPunct DotDotLt ->
        let opTok = Cursor.advance cursor
        let hi = parseExpr cursor diags
        // `..` and `..<` both produce a half-open lower bound here. We
        // synthesise an LInt 0 placeholder for the missing low bound.
        let lo = mkExpr (ELiteral (LInt(0UL, NoIntSuffix))) opTok.Span
        RBHalfOpen(lo, hi)
    | _ ->
        let lo = parseExpr cursor diags
        match Cursor.peekToken cursor with
        | TPunct DotDotEq ->
            Cursor.advance cursor |> ignore
            // Upper-open form `lo ..` is rare and ambiguous with end of
            // expression; require `lo ..= hi` to provide hi.
            let hi = parseExpr cursor diags
            RBClosed(lo, hi)
        | TPunct DotDotLt ->
            Cursor.advance cursor |> ignore
            let hi = parseExpr cursor diags
            RBHalfOpen(lo, hi)
        | TPunct DotDot ->
            Cursor.advance cursor |> ignore
            // `lo .. hi` (treat as half-open) or `lo ..` (open upper).
            // We pick by checking whether an expression follows.
            match Cursor.peekToken cursor with
            | TStmtEnd | TPunct Comma | TPunct RParen
            | TPunct RBracket | TPunct RBrace | TEof ->
                RBUpperOpen lo
            | _ ->
                let hi = parseExpr cursor diags
                RBHalfOpen(lo, hi)
        | _ ->
            err diags "P0060"
                "expected '..', '..<', or '..=' in range bound"
                (Cursor.peekSpan cursor)
            // Fall back to `lo ..= lo` so downstream code has something.
            RBClosed(lo, lo)

// ---------------------------------------------------------------------------
// Type arguments: types or const expressions inside `[...]`.
// ---------------------------------------------------------------------------

and private parseTypeArg
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : TypeArg =
    // Heuristic: integer / float / char / string / bool / unary-minus /
    // parenthesised — definitely a value. Otherwise try the type path
    // and let the resolver upgrade if needed.
    match Cursor.peekToken cursor with
    | TInt _ | TFloat _ | TChar _ | TString _
    | TTripleString _ | TRawString _ | TBool _
    | TPunct Minus ->
        TAValue (parseExpr cursor diags)
    | _ ->
        TAType (parseTypeExpr cursor diags)

and private parseTypeArgs
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : TypeArg list =
    Cursor.advance cursor |> ignore // eat '['
    let xs = ResizeArray<TypeArg>()
    if Cursor.peekToken cursor <> TPunct RBracket then
        xs.Add(parseTypeArg cursor diags)
        while Cursor.peekToken cursor = TPunct Comma do
            Cursor.advance cursor |> ignore
            if Cursor.peekToken cursor = TPunct RBracket then ()
            else xs.Add(parseTypeArg cursor diags)
    match Cursor.tryEatPunct RBracket cursor with
    | Some _ -> ()
    | None ->
        err diags "P0061"
            "expected ']' to close type-argument list"
            (Cursor.peekSpan cursor)
    List.ofSeq xs

// ---------------------------------------------------------------------------
// Type expressions (full grammar).
// ---------------------------------------------------------------------------

and private applyNullableSuffix
        (cursor: Cursor)
        (t: TypeExpr)
        : TypeExpr =
    if Cursor.peekToken cursor = TPunct Question then
        let qTok = Cursor.advance cursor
        mkType (TNullable t) (joinSpans t.Span qTok.Span)
    else t

and private parseAtomNonParenType
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : TypeExpr =

    let tok = Cursor.peek cursor
    match tok.Token with

    | TIdent "Self" ->
        Cursor.advance cursor |> ignore
        mkType TSelf tok.Span

    | TIdent "Never" ->
        Cursor.advance cursor |> ignore
        mkType TNever tok.Span

    | TIdent "array"
        when (Cursor.peekAt cursor 1).Token = TPunct LBracket ->
        Cursor.advance cursor |> ignore  // 'array'
        Cursor.advance cursor |> ignore  // '['
        let size = parseTypeArg cursor diags
        match Cursor.tryEatPunct Comma cursor with
        | Some _ -> ()
        | None ->
            err diags "P0062"
                "expected ',' between size and element type in array[...]"
                (Cursor.peekSpan cursor)
        let elem = parseTypeExpr cursor diags
        let endSpan =
            match Cursor.tryEatPunct RBracket cursor with
            | Some t -> t.Span
            | None ->
                err diags "P0061"
                    "expected ']' to close array[...]"
                    (Cursor.peekSpan cursor)
                elem.Span
        mkType (TArray(size, elem)) (joinSpans tok.Span endSpan)

    | TIdent "slice"
        when (Cursor.peekAt cursor 1).Token = TPunct LBracket ->
        Cursor.advance cursor |> ignore  // 'slice'
        Cursor.advance cursor |> ignore  // '['
        let elem = parseTypeExpr cursor diags
        let endSpan =
            match Cursor.tryEatPunct RBracket cursor with
            | Some t -> t.Span
            | None ->
                err diags "P0061"
                    "expected ']' to close slice[...]"
                    (Cursor.peekSpan cursor)
                elem.Span
        mkType (TSlice elem) (joinSpans tok.Span endSpan)

    | TIdent _ ->
        // ModulePath; then optionally a generic application or a
        // `range` refinement.
        let path = parseModulePath cursor diags
        match Cursor.peekToken cursor with
        | TPunct LBracket ->
            let args = parseTypeArgs cursor diags
            let endSpan =
                match args with
                | [] -> path.Span
                | _ ->
                    match List.last args with
                    | TAType t  -> t.Span
                    | TAValue e -> e.Span
            mkType (TGenericApp(path, args)) (joinSpans path.Span endSpan)
        | TIdent "range" ->
            Cursor.advance cursor |> ignore
            let bound = parseRangeBound cursor diags
            let endSpan =
                match bound with
                | RBClosed(_, hi) | RBHalfOpen(_, hi) | RBLowerOpen hi -> hi.Span
                | RBUpperOpen lo -> lo.Span
            mkType (TRefined(path, bound)) (joinSpans path.Span endSpan)
        | _ ->
            mkType (TRef path) path.Span

    | _ ->
        err diags "P0050"
            "expected a type"
            tok.Span
        if not (Cursor.isAtEnd cursor) then
            Cursor.advance cursor |> ignore
        mkType TError tok.Span

and private parseTypeListUntilRParen
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : TypeExpr list =
    let xs = ResizeArray<TypeExpr>()
    if Cursor.peekToken cursor <> TPunct RParen then
        xs.Add(parseTypeExpr cursor diags)
        while Cursor.peekToken cursor = TPunct Comma do
            Cursor.advance cursor |> ignore
            if Cursor.peekToken cursor = TPunct RParen then ()
            else xs.Add(parseTypeExpr cursor diags)
    List.ofSeq xs

and private parseTypeExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : TypeExpr =

    let startSpan = Cursor.peekSpan cursor

    if Cursor.peekToken cursor = TPunct LParen then
        // Could be: `()`, `(T)`, `(A, B)`, `() -> T`, `(A, B) -> T`,
        // `(T) -> U`.
        Cursor.advance cursor |> ignore
        let inner = parseTypeListUntilRParen cursor diags
        let closeSpan =
            match Cursor.tryEatPunct RParen cursor with
            | Some t -> t.Span
            | None ->
                err diags "P0063"
                    "expected ')' to close parenthesised type"
                    (Cursor.peekSpan cursor)
                startSpan
        if Cursor.peekToken cursor = TPunct Arrow then
            Cursor.advance cursor |> ignore
            let result = parseTypeExpr cursor diags
            mkType (TFunction(inner, result))
                (joinSpans startSpan result.Span)
        else
            let span = joinSpans startSpan closeSpan
            let nodeKind =
                match inner with
                | []  -> TUnit
                | [t] -> TParen t
                | xs  -> TTuple xs
            applyNullableSuffix cursor (mkType nodeKind span)
    else
        let atom = parseAtomNonParenType cursor diags
        let withSuffix = applyNullableSuffix cursor atom
        if Cursor.peekToken cursor = TPunct Arrow then
            Cursor.advance cursor |> ignore
            let result = parseTypeExpr cursor diags
            mkType (TFunction([withSuffix], result))
                (joinSpans withSuffix.Span result.Span)
        else
            withSuffix

// ---------------------------------------------------------------------------
// Patterns (full grammar §8). OrPattern wraps a TypeTestPattern, which
// wraps a PrimaryPattern. TypeTest is `pat is Type`; or-pattern is
// `pat | pat | ...`. Range patterns (`0 ..= 9`) and literal patterns
// share the lookahead-on-literal entry point.
// ---------------------------------------------------------------------------

and private mkPat (kind: PatternKind) (span: Span) : Pattern =
    { Kind = kind; Span = span }

and private parseRecordPatternFields
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : RecordPatternField list * bool =

    Cursor.advance cursor |> ignore   // {
    let fields = ResizeArray<RecordPatternField>()
    let mutable ignoreRest = false
    let mutable keepGoing = true
    while keepGoing do
        match Cursor.peekToken cursor with
        | TPunct RBrace ->
            keepGoing <- false
        | TPunct DotDot ->
            Cursor.advance cursor |> ignore
            ignoreRest <- true
            keepGoing <- false   // '..' must be last
        | TIdent _ ->
            let nameTok = Cursor.advance cursor
            let name =
                match nameTok.Token with
                | TIdent n -> n
                | _ -> "<error>"
            if Cursor.peekToken cursor = TPunct Eq then
                Cursor.advance cursor |> ignore
                let pat = parsePattern cursor diags
                fields.Add(
                    RPFNamed(name, pat, joinSpans nameTok.Span pat.Span))
            else
                fields.Add(RPFShort(name, nameTok.Span))
            // Trailing comma optional; loop back regardless.
            if Cursor.peekToken cursor = TPunct Comma then
                Cursor.advance cursor |> ignore
        | _ ->
            err diags "P0070"
                "expected a field name or '..' in record pattern"
                (Cursor.peekSpan cursor)
            keepGoing <- false
    match Cursor.tryEatPunct RBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0071"
            "expected '}' to close record pattern"
            (Cursor.peekSpan cursor)
    List.ofSeq fields, ignoreRest

and private parsePatternArgs
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Pattern list =

    Cursor.advance cursor |> ignore   // (
    let xs = ResizeArray<Pattern>()
    if Cursor.peekToken cursor <> TPunct RParen then
        xs.Add(parsePattern cursor diags)
        while Cursor.peekToken cursor = TPunct Comma do
            Cursor.advance cursor |> ignore
            if Cursor.peekToken cursor = TPunct RParen then ()
            else xs.Add(parsePattern cursor diags)
    match Cursor.tryEatPunct RParen cursor with
    | Some _ -> ()
    | None ->
        err diags "P0072"
            "expected ')' to close constructor-pattern arguments"
            (Cursor.peekSpan cursor)
    List.ofSeq xs

and private parsePrimaryPattern
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Pattern =

    let tok = Cursor.peek cursor
    match tok.Token with

    // The wildcard `_`. Lyric's lexer produces TIdent "_" for a bare
    // underscore (per §1.4 of the grammar — `_` alone is a legal
    // identifier).
    | TIdent "_" ->
        Cursor.advance cursor |> ignore
        mkPat PWildcard tok.Span

    // Literal-led patterns: a literal alone is PLiteral; a literal
    // followed by `..=` / `..<` / `..` is a range. Unary minus also
    // qualifies — `-5 ..= 5` is permitted.
    | TInt _ | TFloat _ | TChar _ | TString _ | TBool _
    | TTripleString _ | TRawString _ | TPunct Minus ->
        let firstExpr = parseExpr cursor diags
        match Cursor.peekToken cursor with
        | TPunct DotDotEq ->
            Cursor.advance cursor |> ignore
            let hi = parseExpr cursor diags
            mkPat (PRange(firstExpr, true, hi))
                (joinSpans firstExpr.Span hi.Span)
        | TPunct DotDot | TPunct DotDotLt ->
            Cursor.advance cursor |> ignore
            let hi = parseExpr cursor diags
            mkPat (PRange(firstExpr, false, hi))
                (joinSpans firstExpr.Span hi.Span)
        | _ ->
            // Plain literal pattern. Convert the parsed expression
            // back into the AST literal form.
            match firstExpr.Kind with
            | ELiteral lit -> mkPat (PLiteral lit) firstExpr.Span
            | EPrefix(PreNeg, { Kind = ELiteral (LInt(v, sfx)) }) ->
                // `-N` literal — represent as a negated int literal
                // pattern using a synthesised Expr-based range. For
                // now we fall through to a binding pattern named
                // "<error>"; full negative-literal support arrives
                // when LInt grows a sign field.
                let _ = (v, sfx)
                err diags "P0073"
                    "negative literal patterns not yet supported"
                    firstExpr.Span
                mkPat PError firstExpr.Span
            | _ ->
                err diags "P0073"
                    "expected a literal pattern"
                    firstExpr.Span
                mkPat PError firstExpr.Span

    | TPunct LParen ->
        Cursor.advance cursor |> ignore
        // `()` — unit pattern (treated as a 0-tuple).
        if Cursor.peekToken cursor = TPunct RParen then
            let endTok = Cursor.advance cursor
            mkPat (PTuple [])
                (joinSpans tok.Span endTok.Span)
        else
            let first = parsePattern cursor diags
            if Cursor.peekToken cursor = TPunct Comma then
                let items = ResizeArray<Pattern>()
                items.Add(first)
                while Cursor.peekToken cursor = TPunct Comma do
                    Cursor.advance cursor |> ignore
                    if Cursor.peekToken cursor = TPunct RParen then ()
                    else items.Add(parsePattern cursor diags)
                let endSpan =
                    match Cursor.tryEatPunct RParen cursor with
                    | Some t -> t.Span
                    | None ->
                        err diags "P0074"
                            "expected ')' to close tuple pattern"
                            (Cursor.peekSpan cursor)
                        first.Span
                mkPat (PTuple (List.ofSeq items))
                    (joinSpans tok.Span endSpan)
            else
                let endSpan =
                    match Cursor.tryEatPunct RParen cursor with
                    | Some t -> t.Span
                    | None ->
                        err diags "P0074"
                            "expected ')' to close paren pattern"
                            (Cursor.peekSpan cursor)
                        first.Span
                mkPat (PParen first) (joinSpans tok.Span endSpan)

    | TIdent _ ->
        let path = parseModulePath cursor diags
        match Cursor.peekToken cursor with
        | TPunct LParen ->
            let args = parsePatternArgs cursor diags
            let lastSpan =
                match args with
                | [] -> path.Span
                | _  -> (List.last args).Span
            mkPat (PConstructor(path, args))
                (joinSpans path.Span lastSpan)
        | TPunct LBrace ->
            let fields, ignoreRest = parseRecordPatternFields cursor diags
            let lastSpan = Cursor.peekSpan cursor
            mkPat (PRecord(path, fields, ignoreRest))
                (joinSpans path.Span lastSpan)
        | TPunct At when path.Segments.Length = 1 ->
            Cursor.advance cursor |> ignore
            let inner = parsePrimaryPattern cursor diags
            mkPat (PBinding(List.head path.Segments, Some inner))
                (joinSpans path.Span inner.Span)
        | _ when path.Segments.Length = 1 ->
            mkPat (PBinding(List.head path.Segments, None)) path.Span
        | _ ->
            // Multi-segment path with no payload — payload-less
            // constructor (e.g. `case Color.Red ->`).
            mkPat (PConstructor(path, [])) path.Span

    | _ ->
        err diags "P0075"
            "expected a pattern"
            tok.Span
        if not (Cursor.isAtEnd cursor) then
            Cursor.advance cursor |> ignore
        mkPat PError tok.Span

and private parseTypeTestPattern
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Pattern =

    let primary = parsePrimaryPattern cursor diags
    if Cursor.peekToken cursor = TKeyword KwIs then
        Cursor.advance cursor |> ignore
        let ty = parseTypeExpr cursor diags
        mkPat (PTypeTest(primary, ty))
            (joinSpans primary.Span ty.Span)
    else
        primary

and private parsePattern
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Pattern =

    let first = parseTypeTestPattern cursor diags
    if Cursor.peekToken cursor = TPunct Pipe then
        let alts = ResizeArray<Pattern>()
        alts.Add(first)
        while Cursor.peekToken cursor = TPunct Pipe do
            Cursor.advance cursor |> ignore
            alts.Add(parseTypeTestPattern cursor diags)
        let lastSpan = (List.last (List.ofSeq alts)).Span
        mkPat (POr (List.ofSeq alts)) (joinSpans first.Span lastSpan)
    else
        first

// ---------------------------------------------------------------------------
// Public testing entry points (exposed but documented as low-level).
// ---------------------------------------------------------------------------

/// Parse a single TypeExpr from a string, returning the type and any
/// diagnostics. Convenience wrapper for tests; not part of the
/// stable parser surface.
let parseTypeFromString (source: string) : TypeExpr * Diagnostic list =
    let lexed = lex source
    let cursor = Cursor.make lexed.Tokens
    let diags = ResizeArray<Diagnostic>(lexed.Diagnostics)
    Cursor.skipStmtEnds cursor |> ignore
    let t = parseTypeExpr cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    if not (Cursor.isAtEnd cursor) then
        err diags "P0064"
            "unexpected tokens after type"
            (Cursor.peekSpan cursor)
    t, List.ofSeq diags

/// Parse a single Expr from a string. Currently parses only the
/// minimal-expression subset implemented in P4.
let parseExprFromString (source: string) : Expr * Diagnostic list =
    let lexed = lex source
    let cursor = Cursor.make lexed.Tokens
    let diags = ResizeArray<Diagnostic>(lexed.Diagnostics)
    Cursor.skipStmtEnds cursor |> ignore
    let e = parseExpr cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    if not (Cursor.isAtEnd cursor) then
        err diags "P0065"
            "unexpected tokens after expression"
            (Cursor.peekSpan cursor)
    e, List.ofSeq diags

/// Parse a single Pattern from a string. Tests entry point only.
let parsePatternFromString (source: string) : Pattern * Diagnostic list =
    let lexed = lex source
    let cursor = Cursor.make lexed.Tokens
    let diags = ResizeArray<Diagnostic>(lexed.Diagnostics)
    Cursor.skipStmtEnds cursor |> ignore
    let p = parsePattern cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    if not (Cursor.isAtEnd cursor) then
        err diags "P0066"
            "unexpected tokens after pattern"
            (Cursor.peekSpan cursor)
    p, List.ofSeq diags

// ---------------------------------------------------------------------------
// Top-level entry.
// ---------------------------------------------------------------------------

/// Parse a Lyric source string into a SourceFile plus diagnostics.
let parse (source: string) : ParseResult =
    let lexed  = lex source
    let cursor = Cursor.make lexed.Tokens

    let diags = ResizeArray<Diagnostic>(lexed.Diagnostics)

    let startSpan = Cursor.peekSpan cursor

    let moduleDoc = parseModuleDocComments cursor
    let fileAnnotations = parseFileLevelAnnotations cursor diags
    let packageDecl = parsePackageDecl cursor diags
    let imports = parseImports cursor diags
    let items = parseItems cursor diags

    let endSpan = Cursor.peekSpan cursor
    let file =
        { ModuleDoc            = moduleDoc
          FileLevelAnnotations = fileAnnotations
          Package              = packageDecl
          Imports              = imports
          Items                = items
          Span                 = joinSpans startSpan endSpan }

    { File        = file
      Diagnostics = List.ofSeq diags }
