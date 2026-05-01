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

/// Loop-progress guard. Each body-loop in the parser captures the
/// cursor's position at the start of an iteration and calls this at the
/// end. If no token was consumed (a recovery path failed to advance),
/// we force the cursor forward by one token to break the loop. Without
/// this, malformed input — e.g. an unterminated `union { ` — sends the
/// surrounding member-loop into an infinite cycle.
let private forceAdvanceIfStuck (cursor: Cursor) (before: int) : unit =
    if Cursor.mark cursor = before && not (Cursor.isAtEnd cursor) then
        Cursor.advance cursor |> ignore

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

/// `parseItem` and `parseItems` were originally defined here as
/// top-level `let private` functions. They have moved into the
/// mutual-recursion chain below so they can call the typed item-body
/// parsers introduced in P5b.

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

    | TPunct LParen
            when (match (Cursor.peekAt cursor 1).Token with
                  | TIdent _ -> true
                  | _ -> false)
                 && (Cursor.peekAt cursor 2).Token = TIdent "range" ->
        // Type-as-expression: `(Nat range 1 ..= 100).tryFrom(x)`. The
        // refined type is parsed but discarded — only the head segment
        // survives as an EPath, since the type checker handles the
        // refinement constraint at call resolution.
        Cursor.advance cursor |> ignore
        let ty = parseTypeExprNoArrow cursor diags
        let _ =
            match Cursor.tryEatPunct RParen cursor with
            | Some t -> t.Span
            | None ->
                err diags "P0051"
                    "expected ')' to close parenthesised type expression"
                    (Cursor.peekSpan cursor)
                ty.Span
        let head =
            match ty.Kind with
            | TRefined (mp, _) -> mp
            | TRef mp          -> mp
            | _ ->
                { Segments = []; Span = ty.Span }
        mkExpr (EPath head) (joinSpans tok.Span ty.Span)

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

    | TKeyword KwSelf ->
        Cursor.advance cursor |> ignore
        mkExpr ESelf tok.Span

    | TKeyword KwResult ->
        Cursor.advance cursor |> ignore
        mkExpr EResult tok.Span

    | TKeyword KwIf ->
        parseIfExpr cursor diags

    | TKeyword KwMatch ->
        parseMatchExpr cursor diags

    | TKeyword KwAwait ->
        let opTok = Cursor.advance cursor
        let inner = parsePostfixExpr cursor diags
        mkExpr (EAwait inner) (joinSpans opTok.Span inner.Span)

    | TKeyword KwSpawn ->
        let opTok = Cursor.advance cursor
        let inner = parsePostfixExpr cursor diags
        mkExpr (ESpawn inner) (joinSpans opTok.Span inner.Span)

    | TKeyword KwOld ->
        let opTok = Cursor.advance cursor
        match Cursor.tryEatPunct LParen cursor with
        | Some _ -> ()
        | None ->
            err diags "P0190"
                "expected '(' after 'old'"
                (Cursor.peekSpan cursor)
        let inner = parseExpr cursor diags
        let endSpan =
            match Cursor.tryEatPunct RParen cursor with
            | Some t -> t.Span
            | None ->
                err diags "P0191" "expected ')' to close 'old(...)'"
                    (Cursor.peekSpan cursor)
                inner.Span
        mkExpr (EOld inner) (joinSpans opTok.Span endSpan)

    | TIdent "forall" ->
        parseQuantifierExpr cursor diags true

    | TIdent "exists" ->
        parseQuantifierExpr cursor diags false

    // Diverging statements admitted in expression position. Their AST
    // representation wraps the synthesised statement in a single-stmt
    // EBlock so the outer expression machinery treats them as values
    // of type Never (subtyped into anything).
    | TKeyword KwReturn | TKeyword KwThrow
    | TIdent "break" | TIdent "continue" | TKeyword KwTry ->
        let stmt = parseStatement cursor diags
        let blk  = { Statements = [stmt]; Span = stmt.Span }
        mkExpr (EBlock blk) stmt.Span

    | TPunct LBrace ->
        // Lambda in expression position: `{ x: Int -> body }`. We don't
        // currently emit block-expressions outside match/if/etc.
        parseLambdaExpr cursor diags

    | TPunct LBracket ->
        // List literal: `[a, b, c]`.
        let startTok = Cursor.advance cursor
        let xs = ResizeArray<Expr>()
        if Cursor.peekToken cursor <> TPunct RBracket then
            xs.Add(parseExpr cursor diags)
            while Cursor.peekToken cursor = TPunct Comma do
                Cursor.advance cursor |> ignore
                if Cursor.peekToken cursor = TPunct RBracket then ()
                else xs.Add(parseExpr cursor diags)
        let endSpan =
            match Cursor.tryEatPunct RBracket cursor with
            | Some t -> t.Span
            | None ->
                err diags "P0192"
                    "expected ']' to close list literal"
                    (Cursor.peekSpan cursor)
                startTok.Span
        mkExpr (EList (List.ofSeq xs)) (joinSpans startTok.Span endSpan)

    | TIdent _ ->
        // Single-segment path. Multi-segment access (`Money.Amount`)
        // is built up by the postfix-`.IDENT` rule, since at the
        // expression level a dot is also member access.
        let nameTok = Cursor.advance cursor
        let name =
            match nameTok.Token with
            | TIdent n -> n
            | _ -> "<error>"
        let path =
            { Segments = [name]
              Span     = nameTok.Span }
        mkExpr (EPath path) nameTok.Span

    | _ ->
        err diags "P0050"
            "expected an expression"
            tok.Span
        Cursor.advance cursor |> ignore
        mkExpr EError tok.Span

and private parsePostfixExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    let mutable e = parsePrimaryExpr cursor diags
    let mutable keep = true
    while keep do
        match Cursor.peekToken cursor with
        | TPunct LParen ->
            // Function/method call: `e(arg1, arg2 = expr, …)`.
            Cursor.advance cursor |> ignore
            let args = ResizeArray<CallArg>()
            if Cursor.peekToken cursor <> TPunct RParen then
                args.Add(parseCallArg cursor diags)
                while Cursor.peekToken cursor = TPunct Comma do
                    Cursor.advance cursor |> ignore
                    if Cursor.peekToken cursor = TPunct RParen then ()
                    else args.Add(parseCallArg cursor diags)
            let endSpan =
                match Cursor.tryEatPunct RParen cursor with
                | Some t -> t.Span
                | None ->
                    err diags "P0080"
                        "expected ')' to close call argument list"
                        (Cursor.peekSpan cursor)
                    e.Span
            e <- mkExpr (ECall(e, List.ofSeq args)) (joinSpans e.Span endSpan)
        | TPunct Dot ->
            Cursor.advance cursor |> ignore
            match Cursor.tryEatIdent cursor with
            | Some (name, span) ->
                e <- mkExpr (EMember(e, name)) (joinSpans e.Span span)
            | None ->
                err diags "P0081"
                    "expected an identifier after '.'"
                    (Cursor.peekSpan cursor)
                keep <- false
        | TPunct Question ->
            let qTok = Cursor.advance cursor
            e <- mkExpr (EPropagate e) (joinSpans e.Span qTok.Span)
        | TPunct LBracket ->
            // Postfix indexing: `a[i]`, `a[i, j]`. Per grammar §7.
            // Note this collides with TypeArgs at call sites
            // (`f[T](x)`), but at expression-postfix level we always
            // treat `[` as indexing.
            Cursor.advance cursor |> ignore
            let xs = ResizeArray<Expr>()
            if Cursor.peekToken cursor <> TPunct RBracket then
                xs.Add(parseExpr cursor diags)
                while Cursor.peekToken cursor = TPunct Comma do
                    Cursor.advance cursor |> ignore
                    if Cursor.peekToken cursor = TPunct RBracket then ()
                    else xs.Add(parseExpr cursor diags)
            let endSpan =
                match Cursor.tryEatPunct RBracket cursor with
                | Some t -> t.Span
                | None ->
                    err diags "P0083"
                        "expected ']' to close index expression"
                        (Cursor.peekSpan cursor)
                    e.Span
            e <- mkExpr (EIndex(e, List.ofSeq xs)) (joinSpans e.Span endSpan)
        | _ -> keep <- false
    e

and private parseCallArg
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : CallArg =
    // Named (`x = expr`) vs positional. Use a save/restore for the
    // single-token lookahead.
    let saved = Cursor.mark cursor
    match Cursor.peekToken cursor with
    | TIdent _ ->
        let nameTok = Cursor.advance cursor
        if Cursor.peekToken cursor = TPunct Eq then
            Cursor.advance cursor |> ignore
            let value = parseExpr cursor diags
            let name =
                match nameTok.Token with
                | TIdent n -> n
                | _ -> "<error>"
            CANamed(name, value, joinSpans nameTok.Span value.Span)
        else
            Cursor.reset cursor saved
            CAPositional (parseExpr cursor diags)
    | _ ->
        CAPositional (parseExpr cursor diags)

// ---------------------------------------------------------------------------
// Control-flow expressions: if, match, lambda. These live at primary-expr
// level — they begin with a keyword that disambiguates them from binary
// operators.
// ---------------------------------------------------------------------------

and private parseIfExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    let startTok = Cursor.advance cursor   // 'if'
    let cond = parseExpr cursor diags
    if Cursor.peekToken cursor = TKeyword KwThen then
        // Ternary form: `if cond then a else b`.
        Cursor.advance cursor |> ignore
        let thenExpr = parseExpr cursor diags
        match Cursor.tryEatKeyword KwElse cursor with
        | Some _ -> ()
        | None ->
            err diags "P0200"
                "expected 'else' in `if … then … else …` expression"
                (Cursor.peekSpan cursor)
        let elseExpr = parseExpr cursor diags
        mkExpr
            (EIf(cond,
                 EOBExpr thenExpr,
                 Some (EOBExpr elseExpr),
                 true))
            (joinSpans startTok.Span elseExpr.Span)
    else
        // Block form: `if cond { … } [else { … } | else if …]`.
        let thenBlock = parseBlock cursor diags
        let elseBranch, endSpan =
            match Cursor.tryEatKeyword KwElse cursor with
            | Some _ ->
                if Cursor.peekToken cursor = TKeyword KwIf then
                    let elseIf = parseIfExpr cursor diags
                    Some (EOBExpr elseIf), elseIf.Span
                else
                    let blk = parseBlock cursor diags
                    Some (EOBBlock blk), blk.Span
            | None ->
                None, thenBlock.Span
        mkExpr
            (EIf(cond, EOBBlock thenBlock, elseBranch, false))
            (joinSpans startTok.Span endSpan)

and private parseMatchArmBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ExprOrBlock =
    match Cursor.peekToken cursor with
    | TPunct LBrace ->
        EOBBlock (parseBlock cursor diags)
    | TKeyword KwReturn | TKeyword KwThrow
    | TIdent "break" | TIdent "continue" ->
        // Diverging single-statement body — wrap in a synthetic Block
        // so the AST is uniform. ('break' and 'continue' are soft
        // keywords; the lexer emits them as TIdent.)
        let stmt = parseStatement cursor diags
        EOBBlock { Statements = [stmt]; Span = stmt.Span }
    | _ ->
        EOBExpr (parseExpr cursor diags)

and private parseMatchArm
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : MatchArm =
    let startSpan = Cursor.peekSpan cursor
    match Cursor.tryEatKeyword KwCase cursor with
    | Some _ -> ()
    | None ->
        err diags "P0201"
            "expected 'case' to start a match arm"
            (Cursor.peekSpan cursor)
    let pat = parsePattern cursor diags
    let guard =
        match Cursor.peekToken cursor with
        | TKeyword KwWhere | TKeyword KwIf ->
            Cursor.advance cursor |> ignore
            Some (parseExpr cursor diags)
        | _ -> None
    match Cursor.tryEatPunct Arrow cursor with
    | Some _ -> ()
    | None ->
        err diags "P0202"
            "expected '->' after match-arm pattern"
            (Cursor.peekSpan cursor)
    let body = parseMatchArmBody cursor diags
    let endSpan =
        match body with
        | EOBExpr e  -> e.Span
        | EOBBlock b -> b.Span
    { Pattern = pat
      Guard   = guard
      Body    = body
      Span    = joinSpans startSpan endSpan }

and private parseMatchExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    let startTok = Cursor.advance cursor   // 'match'
    let scrutinee = parseExpr cursor diags
    match Cursor.tryEatPunct LBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0203"
            "expected '{' to start match arms"
            (Cursor.peekSpan cursor)
    Cursor.skipStmtEnds cursor |> ignore
    let arms = ResizeArray<MatchArm>()
    while Cursor.peekToken cursor <> TPunct RBrace
          && not (Cursor.isAtEnd cursor) do
        let _before = Cursor.mark cursor
        arms.Add(parseMatchArm cursor diags)
        match Cursor.peekToken cursor with
        | TStmtEnd | TPunct Comma ->
            Cursor.advance cursor |> ignore
            Cursor.skipStmtEnds cursor |> ignore
        | _ -> ()
        forceAdvanceIfStuck cursor _before
    let endSpan =
        match Cursor.tryEatPunct RBrace cursor with
        | Some t -> t.Span
        | None ->
            err diags "P0204"
                "expected '}' to close match expression"
                (Cursor.peekSpan cursor)
            scrutinee.Span
    mkExpr (EMatch(scrutinee, List.ofSeq arms))
        (joinSpans startTok.Span endSpan)

and private parseQuantifierBinder
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : PropertyBinder =
    let nameTok = Cursor.peek cursor
    let name, nameSp =
        match Cursor.tryEatIdent cursor with
        | Some (n, s) -> n, s
        | None ->
            err diags "P0300" "expected an identifier in quantifier binder" nameTok.Span
            "<error>", nameTok.Span
    match Cursor.tryEatPunct Colon cursor with
    | Some _ -> ()
    | None ->
        err diags "P0301" "expected ':' in quantifier binder" (Cursor.peekSpan cursor)
    let ty = parseTypeExpr cursor diags
    { Name = name; Type = ty; Span = joinSpans nameSp ty.Span }

and private parseQuantifierExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (isForall: bool)
        : Expr =
    let startTok = Cursor.advance cursor   // 'forall' / 'exists'
    match Cursor.tryEatPunct LParen cursor with
    | Some _ -> ()
    | None ->
        err diags "P0302"
            (sprintf "expected '(' after '%s'"
                (if isForall then "forall" else "exists"))
            (Cursor.peekSpan cursor)
    let binders = ResizeArray<PropertyBinder>()
    if Cursor.peekToken cursor <> TPunct RParen then
        binders.Add(parseQuantifierBinder cursor diags)
        while Cursor.peekToken cursor = TPunct Comma do
            Cursor.advance cursor |> ignore
            if Cursor.peekToken cursor = TPunct RParen then ()
            else binders.Add(parseQuantifierBinder cursor diags)
    match Cursor.tryEatPunct RParen cursor with
    | Some _ -> ()
    | None ->
        err diags "P0303" "expected ')' to close quantifier binder list"
            (Cursor.peekSpan cursor)

    // Optional `where COND`. Use parseOrExpr2 (no `implies`) so the
    // trailing `implies BODY` is left for the body parser below.
    Cursor.skipStmtEnds cursor |> ignore
    let whereExpr =
        match Cursor.tryEatKeyword KwWhere cursor with
        | Some _ -> Some (parseOrExpr2 cursor diags)
        | None -> None
    // The `implies BODY` may be on its own line — see worked
    // example 11's stack ensures clauses.
    Cursor.skipStmtEnds cursor |> ignore

    // Body. Three permitted forms:
    //   `implies E`  — explicit implication body
    //   `{ … }`      — block body
    //   `E`          — bare expression body
    let body =
        match Cursor.peekToken cursor with
        | TIdent "implies" ->
            Cursor.advance cursor |> ignore
            parseExpr cursor diags
        | TPunct LBrace ->
            let blk = parseBlock cursor diags
            mkExpr (EBlock blk) blk.Span
        | _ ->
            parseExpr cursor diags

    let kind =
        if isForall then EForall(List.ofSeq binders, whereExpr, body)
        else EExists(List.ofSeq binders, whereExpr, body)
    mkExpr kind (joinSpans startTok.Span body.Span)

and private parseLambdaExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    // Already at '{'. Save position so we can backtrack if it turns out
    // to be a body-only lambda or a block-expression.
    let startTok = Cursor.advance cursor   // '{'
    let saved = Cursor.mark cursor
    Cursor.skipStmtEnds cursor |> ignore

    // Is there a parameter list followed by '->'?
    //   { x -> body }
    //   { x: Int -> body }
    //   { x, y -> body }
    //   { (x: Int, y: Int) -> body }
    //   { -> body }              (no params)
    let lambdaParams, hasArrow =
        let params' = ResizeArray<LambdaParam>()
        let mutable saw = false
        let savePos = Cursor.mark cursor
        let mutable headOk = true

        // Bare '->' = no params.
        if Cursor.peekToken cursor = TPunct Arrow then
            saw <- true
        elif Cursor.peekToken cursor = TPunct LParen then
            // Parenthesised parameter list — not consumed in this
            // first prototype; bail out and treat as a body-only block.
            headOk <- false
        else
            // Try a comma-separated identifier list followed by '->'.
            let mutable keep = true
            while keep do
                match Cursor.peekToken cursor with
                | TIdent name ->
                    let nameTok = Cursor.advance cursor
                    let ty =
                        match Cursor.tryEatPunct Colon cursor with
                        | Some _ -> Some (parseTypeExprNoArrow cursor diags)
                        | None -> None
                    let endSpan =
                        match ty with
                        | Some t -> t.Span
                        | None -> nameTok.Span
                    params'.Add(
                        { Name = name; Type = ty
                          Span = joinSpans nameTok.Span endSpan })
                    if Cursor.peekToken cursor = TPunct Comma then
                        Cursor.advance cursor |> ignore
                    else
                        keep <- false
                | _ ->
                    headOk <- false
                    keep <- false
            if headOk && Cursor.peekToken cursor = TPunct Arrow then
                saw <- true
            else
                headOk <- false

        if not headOk || not saw then
            Cursor.reset cursor savePos
            [], false
        else
            // Consume the '->'.
            Cursor.advance cursor |> ignore
            List.ofSeq params', true

    // Body: parse statements up to the closing '}'.
    let stmts = ResizeArray<Statement>()
    Cursor.skipStmtEnds cursor |> ignore
    while Cursor.peekToken cursor <> TPunct RBrace
          && not (Cursor.isAtEnd cursor) do
        let _before = Cursor.mark cursor
        stmts.Add(parseStatement cursor diags)
        match Cursor.peekToken cursor with
        | TStmtEnd | TPunct Semi ->
            Cursor.advance cursor |> ignore
            Cursor.skipStmtEnds cursor |> ignore
        | _ -> ()
        forceAdvanceIfStuck cursor _before
    let endSpan =
        match Cursor.tryEatPunct RBrace cursor with
        | Some t -> t.Span
        | None ->
            err diags "P0205"
                "expected '}' to close lambda / block"
                (Cursor.peekSpan cursor)
            startTok.Span

    if hasArrow then
        let body =
            { Statements = List.ofSeq stmts
              Span       = joinSpans startTok.Span endSpan }
        mkExpr (ELambda(lambdaParams, body))
            (joinSpans startTok.Span endSpan)
    else
        // Body-only: treat as a no-param lambda whose body is the
        // braced statement list. (Block-as-expression is an
        // alternative; we conflate them here.)
        let _ = saved
        let body =
            { Statements = List.ofSeq stmts
              Span       = joinSpans startTok.Span endSpan }
        mkExpr (ELambda([], body))
            (joinSpans startTok.Span endSpan)

// ---------------------------------------------------------------------------
// Blocks and statements (P7).
//
// A block is `{ Statement (NL Statement)* [NL] }`. Each statement may be
// a binding, a control-flow statement, an item declaration, an
// assignment, or a bare expression.
// ---------------------------------------------------------------------------

and private mkStmt (kind: StatementKind) (span: Span) : Statement =
    { Kind = kind; Span = span }

and private parseLocalBinding
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : LocalBinding =
    match Cursor.peekToken cursor with
    | TKeyword KwVal ->
        Cursor.advance cursor |> ignore
        let pat = parsePattern cursor diags
        let ty =
            match Cursor.tryEatPunct Colon cursor with
            | Some _ -> Some (parseTypeExpr cursor diags)
            | None -> None
        match Cursor.tryEatPunct Eq cursor with
        | Some _ -> ()
        | None ->
            err diags "P0210"
                "expected '=' in 'val' binding"
                (Cursor.peekSpan cursor)
        let init = parseExpr cursor diags
        LBVal(pat, ty, init)
    | TKeyword KwVar ->
        Cursor.advance cursor |> ignore
        let name, _ = readIdent cursor diags "var binding"
        let ty =
            match Cursor.tryEatPunct Colon cursor with
            | Some _ -> Some (parseTypeExpr cursor diags)
            | None -> None
        let init =
            match Cursor.tryEatPunct Eq cursor with
            | Some _ -> Some (parseExpr cursor diags)
            | None -> None
        LBVar(name, ty, init)
    | TKeyword KwLet ->
        Cursor.advance cursor |> ignore
        let name, _ = readIdent cursor diags "let binding"
        let ty =
            match Cursor.tryEatPunct Colon cursor with
            | Some _ -> Some (parseTypeExpr cursor diags)
            | None -> None
        match Cursor.tryEatPunct Eq cursor with
        | Some _ -> ()
        | None ->
            err diags "P0211"
                "expected '=' in 'let' binding"
                (Cursor.peekSpan cursor)
        let init = parseExpr cursor diags
        LBLet(name, ty, init)
    | _ ->
        err diags "P0212"
            "expected 'val', 'var', or 'let'"
            (Cursor.peekSpan cursor)
        LBVal(mkPat PError (Cursor.peekSpan cursor), None,
              mkExpr EError (Cursor.peekSpan cursor))

and private parseCatchClause
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : CatchClause =
    let startTok = Cursor.advance cursor   // 'catch'
    let typeName, _ = readIdent cursor diags "catch type"
    let bindAs =
        match Cursor.tryEatKeyword KwAs cursor with
        | Some _ ->
            match Cursor.tryEatIdent cursor with
            | Some (n, _) -> Some n
            | None ->
                err diags "P0220"
                    "expected identifier after 'as' in catch"
                    (Cursor.peekSpan cursor)
                None
        | None -> None
    let body = parseBlock cursor diags
    { Type = typeName
      Bind = bindAs
      Body = body
      Span = joinSpans startTok.Span body.Span }

and private parseStatement
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Statement =
    let startSpan = Cursor.peekSpan cursor
    match Cursor.peekToken cursor with

    | TKeyword KwVal | TKeyword KwVar | TKeyword KwLet ->
        let lb = parseLocalBinding cursor diags
        let endSpan = Cursor.peekSpan cursor
        mkStmt (SLocal lb) (joinSpans startSpan endSpan)

    | TKeyword KwReturn ->
        Cursor.advance cursor |> ignore
        // Optional return value: stop at STMT_END or block-closer.
        let value =
            match Cursor.peekToken cursor with
            | TStmtEnd | TPunct RBrace | TPunct Semi | TEof -> None
            | _ -> Some (parseExpr cursor diags)
        let endSpan =
            match value with
            | Some e -> e.Span
            | None -> startSpan
        mkStmt (SReturn value) (joinSpans startSpan endSpan)

    | TIdent "break" ->
        Cursor.advance cursor |> ignore
        let label =
            match Cursor.tryEatIdent cursor with
            | Some (n, _) -> Some n
            | None -> None
        mkStmt (SBreak label) (joinSpans startSpan (Cursor.peekSpan cursor))

    | TIdent "continue" ->
        Cursor.advance cursor |> ignore
        let label =
            match Cursor.tryEatIdent cursor with
            | Some (n, _) -> Some n
            | None -> None
        mkStmt (SContinue label) (joinSpans startSpan (Cursor.peekSpan cursor))

    | TKeyword KwThrow ->
        Cursor.advance cursor |> ignore
        let e = parseExpr cursor diags
        mkStmt (SThrow e) (joinSpans startSpan e.Span)

    | TKeyword KwTry ->
        Cursor.advance cursor |> ignore
        let body = parseBlock cursor diags
        let catches = ResizeArray<CatchClause>()
        while Cursor.peekToken cursor = TKeyword KwCase
              || (match Cursor.peekToken cursor with
                  | TIdent "catch" -> true
                  | _ -> false) do
            // 'catch' is not a reserved keyword in Lyric; it appears
            // as a bare identifier in catch clauses. Recognise it
            // contextually here.
            if Cursor.peekToken cursor = TIdent "catch" then
                catches.Add(parseCatchClause cursor diags)
            else
                ()
        // The grammar has 'catch' as part of the keyword set in
        // language reference §1.3 — but my lexer currently treats it
        // as an identifier. The lookup above tolerates either.
        // Real fix: add KwCatch to the lexer. Tracked as a follow-up.
        let endSpan =
            if catches.Count > 0 then
                (catches.[catches.Count - 1]).Span
            else body.Span
        mkStmt (STry(body, List.ofSeq catches))
            (joinSpans startSpan endSpan)

    | TKeyword KwDo ->
        // `do { ... }` — infinite loop.
        Cursor.advance cursor |> ignore
        let body = parseBlock cursor diags
        mkStmt (SLoop(None, body))
            (joinSpans startSpan body.Span)

    | TKeyword KwScope ->
        Cursor.advance cursor |> ignore
        // Optional `[scope-tag]` — not yet emitted.
        let body = parseBlock cursor diags
        mkStmt (SScope(None, body))
            (joinSpans startSpan body.Span)

    | TKeyword KwFor ->
        Cursor.advance cursor |> ignore
        let pat = parsePattern cursor diags
        match Cursor.tryEatKeyword KwIn cursor with
        | Some _ -> ()
        | None ->
            err diags "P0221"
                "expected 'in' in for-loop"
                (Cursor.peekSpan cursor)
        let iter = parseExpr cursor diags
        let body = parseBlock cursor diags
        mkStmt (SFor(None, pat, iter, body))
            (joinSpans startSpan body.Span)

    | TKeyword KwWhile ->
        Cursor.advance cursor |> ignore
        let cond = parseExpr cursor diags
        let body = parseBlock cursor diags
        mkStmt (SWhile(None, cond, body))
            (joinSpans startSpan body.Span)

    | TIdent "defer"
    | TKeyword KwSpawn  ->
        // Reserved: `defer` is in language reference §4.3 but not yet
        // a keyword in the lexer. Treat any TIdent "defer" followed by
        // `{` as a defer block.
        if Cursor.peekToken cursor = TIdent "defer" then
            Cursor.advance cursor |> ignore
            let body = parseBlock cursor diags
            mkStmt (SDefer body) (joinSpans startSpan body.Span)
        else
            // Plain expression statement (e.g. `spawn …`).
            let e = parseExpr cursor diags
            mkStmt (SExpr e) (joinSpans startSpan e.Span)

    | _ ->
        // Expression statement OR assignment OR stub-builder rule
        // (`lhs -> rhs`). Parse an expression; the trailing token
        // discriminates the form.
        let e = parseExpr cursor diags
        match Cursor.peekToken cursor with
        | TPunct Eq | TPunct PlusEq | TPunct MinusEq
        | TPunct StarEq | TPunct SlashEq | TPunct PercentEq ->
            let op =
                match Cursor.peekToken cursor with
                | TPunct Eq        -> AssEq
                | TPunct PlusEq    -> AssPlus
                | TPunct MinusEq   -> AssMinus
                | TPunct StarEq    -> AssStar
                | TPunct SlashEq   -> AssSlash
                | TPunct PercentEq -> AssPercent
                | _                -> AssEq
            Cursor.advance cursor |> ignore
            let value = parseExpr cursor diags
            mkStmt (SAssign(e, op, value))
                (joinSpans startSpan value.Span)
        | TPunct Arrow ->
            // Stub-builder rule entry inside a `{ … }` lambda, e.g.
            //   it.findById(x) -> Some(y)
            Cursor.advance cursor |> ignore
            let rhs = parseExpr cursor diags
            mkStmt (SRule(e, rhs))
                (joinSpans startSpan rhs.Span)
        | _ ->
            mkStmt (SExpr e) (joinSpans startSpan e.Span)

and private parseBlock
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Block =
    let startSpan = Cursor.peekSpan cursor
    match Cursor.tryEatPunct LBrace cursor with
    | None ->
        err diags "P0230"
            "expected '{' to start block"
            (Cursor.peekSpan cursor)
        { Statements = []; Span = startSpan }
    | Some _ ->
        Cursor.skipStmtEnds cursor |> ignore
        let stmts = ResizeArray<Statement>()
        while Cursor.peekToken cursor <> TPunct RBrace
              && not (Cursor.isAtEnd cursor) do
            let _before = Cursor.mark cursor
            stmts.Add(parseStatement cursor diags)
            // Tolerate STMT_END or ';' between statements.
            match Cursor.peekToken cursor with
            | TStmtEnd | TPunct Semi ->
                Cursor.advance cursor |> ignore
                Cursor.skipStmtEnds cursor |> ignore
            | _ -> ()
            forceAdvanceIfStuck cursor _before
        let endSpan =
            match Cursor.tryEatPunct RBrace cursor with
            | Some t -> t.Span
            | None ->
                err diags "P0231"
                    "expected '}' to close block"
                    (Cursor.peekSpan cursor)
                startSpan
        { Statements = List.ofSeq stmts
          Span       = joinSpans startSpan endSpan }

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
        parsePostfixExpr cursor diags

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

and private parseCoalesceExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    // Nil-coalescing `??` — right-associative, between additive and
    // comparison per language reference §4.1. We tolerate a STMT_END
    // between the LHS and the `??` because the worked examples chain
    // `??` onto the next line:
    //
    //   val from = await svc.accounts.findById(fromId)
    //       ?? return Err(AccountNotFound(fromId))
    let lhs = parseAddExpr cursor diags
    let savedPos = Cursor.mark cursor
    Cursor.skipStmtEnds cursor |> ignore
    if Cursor.peekToken cursor = TPunct QuestionQuestion then
        Cursor.advance cursor |> ignore
        let rhs = parseCoalesceExpr cursor diags
        mkExpr (EBinop(BCoalesce, lhs, rhs)) (joinSpans lhs.Span rhs.Span)
    else
        Cursor.reset cursor savedPos
        lhs

and private parseCompareExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    let lhs = parseCoalesceExpr cursor diags
    // At most one comparison operator at this level — chained
    // comparisons are a parse error per language reference §4.1.
    let pickOp () =
        match Cursor.peekToken cursor with
        | TPunct EqEq  -> Some BEq
        | TPunct NotEq -> Some BNeq
        | TPunct Lt    -> Some BLt
        | TPunct LtEq  -> Some BLte
        | TPunct Gt    -> Some BGt
        | TPunct GtEq  -> Some BGte
        | _ -> None
    match pickOp () with
    | None -> lhs
    | Some op ->
        Cursor.advance cursor |> ignore
        let rhs = parseCoalesceExpr cursor diags
        // Detect a chained comparison and emit a diagnostic.
        match pickOp () with
        | Some _ ->
            err diags "P0082"
                "comparison operators do not chain (use parentheses)"
                (Cursor.peekSpan cursor)
        | None -> ()
        mkExpr (EBinop(op, lhs, rhs)) (joinSpans lhs.Span rhs.Span)

and private parseAndExpr2
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    let mutable lhs = parseCompareExpr cursor diags
    while Cursor.peekToken cursor = TKeyword KwAnd do
        Cursor.advance cursor |> ignore
        let rhs = parseCompareExpr cursor diags
        lhs <- mkExpr (EBinop(BAnd, lhs, rhs)) (joinSpans lhs.Span rhs.Span)
    lhs

and private parseOrExpr2
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    // `or` and `xor` only — `implies` lives at the lower-precedence
    // wrapper parseImpliesExpr so the `where` clause inside a
    // quantifier can use parseOrExpr2 directly without absorbing the
    // trailing `implies BODY`.
    let mutable lhs = parseAndExpr2 cursor diags
    let mutable keep = true
    while keep do
        match Cursor.peekToken cursor with
        | TKeyword KwOr ->
            Cursor.advance cursor |> ignore
            let rhs = parseAndExpr2 cursor diags
            lhs <- mkExpr (EBinop(BOr, lhs, rhs)) (joinSpans lhs.Span rhs.Span)
        | TKeyword KwXor ->
            Cursor.advance cursor |> ignore
            let rhs = parseAndExpr2 cursor diags
            lhs <- mkExpr (EBinop(BXor, lhs, rhs)) (joinSpans lhs.Span rhs.Span)
        | _ -> keep <- false
    lhs

and private parseImpliesExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    // `implies` is the contract sub-language's logical implication.
    // Right-associative: `a implies b implies c` ≡ `a implies (b
    // implies c)`. The contract validator (a later pass) confirms
    // that `implies` only appears in admissible positions.
    let lhs = parseOrExpr2 cursor diags
    if Cursor.peekToken cursor = TIdent "implies" then
        Cursor.advance cursor |> ignore
        let rhs = parseImpliesExpr cursor diags
        mkExpr (EBinop(BImplies, lhs, rhs))
            (joinSpans lhs.Span rhs.Span)
    else
        lhs

and private parseExpr
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Expr =
    parseImpliesExpr cursor diags

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

/// Parse a type expression that does NOT consume a trailing `->`.
/// Used in contexts where `->` belongs to the surrounding syntax —
/// notably typed lambda parameters (`{ x: Int -> body }`) and the
/// `bind T -> provider` form inside a wire block.
and private parseTypeExprNoArrow
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : TypeExpr =
    let startSpan = Cursor.peekSpan cursor
    if Cursor.peekToken cursor = TPunct LParen then
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
        let span = joinSpans startSpan closeSpan
        let nodeKind =
            match inner with
            | []  -> TUnit
            | [t] -> TParen t
            | xs  -> TTuple xs
        applyNullableSuffix cursor (mkType nodeKind span)
    else
        let atom = parseAtomNonParenType cursor diags
        applyNullableSuffix cursor atom

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
                // `-N` literal — encode as the two's-complement
                // representation of `-v` in a uint64.  The codegen
                // path narrows the uint64 back to the suffix's CLR
                // width via wrapping casts, recovering the negative
                // signed value at IL-emit time.
                let negEncoded = 0UL - v
                mkPat (PLiteral (LInt(negEncoded, sfx))) firstExpr.Span
            | EPrefix(PreNeg, { Kind = ELiteral (LFloat(v, sfx)) }) ->
                mkPat (PLiteral (LFloat(-v, sfx))) firstExpr.Span
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

    // `result` is a contextual keyword — valid as a binding name in
    // patterns (e.g. `case Ok(result) ->`), even though it is also the
    // magic name for the return value inside `ensures:` clauses.
    | TKeyword KwResult ->
        let span = tok.Span
        Cursor.advance cursor |> ignore
        mkPat (PBinding("result", None)) span

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
// Generic parameters, where-clauses, invariant clauses (helpers reused
// by every item kind that admits generics or carries an invariant).
// ---------------------------------------------------------------------------

and private parseGenericParam
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : GenericParam =

    let nameTok = Cursor.peek cursor
    match Cursor.tryEatIdent cursor with
    | Some (name, nameSpan) ->
        // `T: SomeBound` is a value generic; bare `T` is a type generic.
        if Cursor.peekToken cursor = TPunct Colon then
            Cursor.advance cursor |> ignore
            let ty = parseTypeExpr cursor diags
            GPValue(name, ty, joinSpans nameSpan ty.Span)
        else
            GPType(name, nameSpan)
    | None ->
        err diags "P0090"
            "expected an identifier in generic parameter list"
            nameTok.Span
        if not (Cursor.isAtEnd cursor) then
            Cursor.advance cursor |> ignore
        GPType("<error>", nameTok.Span)

/// Parse a generic-parameter list immediately after a declaration's
/// identifier.  Two forms are accepted, both producing the same AST:
///
///   1. The bare-bracket form, `[T, U: Nat]` — preferred, mirrors the
///      type-application syntax users see at use sites (`Box[Int]`).
///   2. The legacy `generic[T, U: Nat]` form — still recognised for
///      back-compat; D-numbered decision will retire it.
///
/// Returns `None` if the cursor sits on neither form.
and private parseGenericParamsOpt
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : GenericParams option =
    let parseFromOpenBracket (startTok: Lyric.Lexer.SpannedToken) =
        // Cursor is positioned on the `[` token (not yet consumed).
        match Cursor.tryEatPunct LBracket cursor with
        | Some _ -> ()
        | None ->
            err diags "P0091"
                "expected '[' to open generic parameter list"
                (Cursor.peekSpan cursor)
        let xs = ResizeArray<GenericParam>()
        if Cursor.peekToken cursor <> TPunct RBracket then
            xs.Add(parseGenericParam cursor diags)
            while Cursor.peekToken cursor = TPunct Comma do
                Cursor.advance cursor |> ignore
                if Cursor.peekToken cursor = TPunct RBracket then ()
                else xs.Add(parseGenericParam cursor diags)
        let endSpan =
            match Cursor.tryEatPunct RBracket cursor with
            | Some t -> t.Span
            | None ->
                err diags "P0092"
                    "expected ']' to close generic parameter list"
                    (Cursor.peekSpan cursor)
                startTok.Span
        Some
            { Params = List.ofSeq xs
              Span   = joinSpans startTok.Span endSpan }
    match Cursor.peekToken cursor with
    | TKeyword KwGeneric ->
        let startTok = Cursor.advance cursor   // 'generic'
        parseFromOpenBracket startTok
    | TPunct LBracket ->
        let startTok = Cursor.peek cursor      // peek; bracket eaten below
        parseFromOpenBracket startTok
    | _ -> None

and private parseConstraintRef
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ConstraintRef =
    let head = parseModulePath cursor diags
    let args, endSpan =
        match Cursor.peekToken cursor with
        | TPunct LBracket ->
            let xs = parseTypeArgs cursor diags
            let last =
                match xs with
                | [] -> head.Span
                | _ ->
                    match List.last xs with
                    | TAType t  -> t.Span
                    | TAValue e -> e.Span
            xs, last
        | _ -> [], head.Span
    { Head = head; Args = args; Span = joinSpans head.Span endSpan }

and private parseWhereBound
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : WhereBound =
    let nameTok = Cursor.peek cursor
    let name, nameSpan =
        match Cursor.tryEatIdent cursor with
        | Some (n, s) -> n, s
        | None ->
            err diags "P0093"
                "expected an identifier in where-bound"
                nameTok.Span
            "<error>", nameTok.Span
    match Cursor.tryEatPunct Colon cursor with
    | Some _ -> ()
    | None ->
        err diags "P0094"
            "expected ':' after the bound's type variable"
            (Cursor.peekSpan cursor)
    let constraints = ResizeArray<ConstraintRef>()
    constraints.Add(parseConstraintRef cursor diags)
    while Cursor.peekToken cursor = TPunct Plus do
        Cursor.advance cursor |> ignore
        constraints.Add(parseConstraintRef cursor diags)
    let endSpan = (List.last (List.ofSeq constraints)).Span
    { Name        = name
      Constraints = List.ofSeq constraints
      Span        = joinSpans nameSpan endSpan }

/// Parse `where T: Compare + Hash, U: Default` if `where` is the next
/// token. Returns None if absent.
and private parseWhereClauseOpt
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : WhereClause option =
    if Cursor.peekToken cursor <> TKeyword KwWhere then None
    else
        let startTok = Cursor.advance cursor
        let xs = ResizeArray<WhereBound>()
        xs.Add(parseWhereBound cursor diags)
        while Cursor.peekToken cursor = TPunct Comma do
            Cursor.advance cursor |> ignore
            xs.Add(parseWhereBound cursor diags)
        let endSpan = (List.last (List.ofSeq xs)).Span
        Some
            { Bounds = List.ofSeq xs
              Span   = joinSpans startTok.Span endSpan }

/// Parse `invariant: <expr>`. Caller is expected to have peeked
/// `invariant` already.
and private parseInvariantClause
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : InvariantClause =
    let startTok = Cursor.advance cursor   // 'invariant'
    match Cursor.tryEatPunct Colon cursor with
    | Some _ -> ()
    | None ->
        err diags "P0095"
            "expected ':' after 'invariant'"
            (Cursor.peekSpan cursor)
    let expr = parseExpr cursor diags
    { Expr = expr
      Span = joinSpans startTok.Span expr.Span }

// ---------------------------------------------------------------------------
// P5b: type-shaped item bodies.
//
// Each item kind below shares the same prefix shape (name + generics +
// optional where-clause + body) with small variations. The two helpers
// `mergeGenericsInfo` and `readIdent` factor the common bits.
// ---------------------------------------------------------------------------

and private mergeGenericsInfo
        (diags:  ResizeArray<Diagnostic>)
        (prefix: GenericParams option)
        (suffix: GenericParams option)
        : GenericParams option =
    match prefix, suffix with
    | Some _, Some s ->
        err diags "P0102"
            "generic[...] may appear before or after the name, not both"
            s.Span
        prefix
    | Some _, None -> prefix
    | None, Some _ -> suffix
    | None, None   -> None

and private readIdent
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (whatFor: string)
        : string * Span =
    // Contextual keywords (currently `result`) are valid in binding
    // positions, so tryEatIdentOrContextual accepts them too.
    match Cursor.tryEatIdentOrContextual cursor with
    | Some (n, s) -> n, s
    | None ->
        let span = Cursor.peekSpan cursor
        err diags "P0103"
            (sprintf "expected an identifier for %s name" whatFor)
            span
        "<error>", span

/// Parse a single annotation that may follow a field or post-name on
/// an opaque type declaration.
and private parseTrailingAnnotations
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Annotation list =
    let xs = ResizeArray<Annotation>()
    let mutable keep = true
    while keep do
        match parseAnnotation cursor diags with
        | Some a -> xs.Add(a)
        | None -> keep <- false
    List.ofSeq xs

// ----- alias ---------------------------------------------------------------

and private parseTypeAliasBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (genericsPrefix: GenericParams option)
        : TypeAliasDecl =
    let startTok = Cursor.advance cursor   // 'alias'
    let name, nameSpan = readIdent cursor diags "alias"
    Cursor.skipStmtEnds cursor |> ignore
    let genericsSuffix = parseGenericParamsOpt cursor diags
    let generics = mergeGenericsInfo diags genericsPrefix genericsSuffix
    match Cursor.tryEatPunct Eq cursor with
    | Some _ -> ()
    | None ->
        err diags "P0110"
            "expected '=' in type alias"
            (Cursor.peekSpan cursor)
    let rhs = parseTypeExpr cursor diags
    { Name     = name
      Generics = generics
      RHS      = rhs
      Span     = joinSpans startTok.Span rhs.Span }

// ----- distinct type -------------------------------------------------------

and private parseDerivesClauseOpt
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : string list =
    match Cursor.peekToken cursor with
    | TIdent "derives" ->
        Cursor.advance cursor |> ignore
        let xs = ResizeArray<string>()
        let appendIdent () =
            match Cursor.tryEatIdent cursor with
            | Some (n, _) -> xs.Add(n)
            | None ->
                err diags "P0111"
                    "expected a marker name in 'derives' clause"
                    (Cursor.peekSpan cursor)
        appendIdent ()
        while Cursor.peekToken cursor = TPunct Comma do
            Cursor.advance cursor |> ignore
            appendIdent ()
        List.ofSeq xs
    | _ -> []

and private parseDistinctTypeBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (genericsPrefix: GenericParams option)
        : DistinctTypeDecl =
    let startTok = Cursor.advance cursor   // 'type'
    let name, nameSpan = readIdent cursor diags "type"
    Cursor.skipStmtEnds cursor |> ignore
    let genericsSuffix = parseGenericParamsOpt cursor diags
    let generics = mergeGenericsInfo diags genericsPrefix genericsSuffix
    match Cursor.tryEatPunct Eq cursor with
    | Some _ -> ()
    | None ->
        err diags "P0112"
            "expected '=' in distinct type declaration"
            (Cursor.peekSpan cursor)
    let initial = parseTypeExpr cursor diags
    // The type-expression grammar (§4) admits `Foo range a ..= b` as a
    // refined-type form. Distinct-type RHS context (§3.3) wants the
    // range as a separate RangeClause, so unwrap a TRefined back into
    // its head + bound.
    let underlying, rangeFromType =
        match initial.Kind with
        | TRefined(headPath, bound) ->
            let bareUnderlying =
                mkType (TRef headPath) headPath.Span
            bareUnderlying, Some bound
        | _ -> initial, None
    let range =
        match rangeFromType with
        | Some _ -> rangeFromType
        | None ->
            match Cursor.peekToken cursor with
            | TIdent "range" ->
                Cursor.advance cursor |> ignore
                Some (parseRangeBound cursor diags)
            | _ -> None
    let derives = parseDerivesClauseOpt cursor diags
    let endSpan = Cursor.peekSpan cursor
    { Name       = name
      Generics   = generics
      Underlying = underlying
      Range      = range
      Derives    = derives
      Span       = joinSpans startTok.Span endSpan }

// ----- record / exposed record ---------------------------------------------

and private parseFieldDecl
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : FieldDecl =
    let startSpan = Cursor.peekSpan cursor
    let docs = parseItemDocComments cursor
    let anns = parseItemAnnotations cursor diags
    let vis =
        match Cursor.tryEatKeyword KwPub cursor with
        | Some t -> Some (Pub t.Span)
        | None -> None
    let name, nameSpan = readIdent cursor diags "field"
    match Cursor.tryEatPunct Colon cursor with
    | Some _ -> ()
    | None ->
        err diags "P0120"
            "expected ':' after field name"
            (Cursor.peekSpan cursor)
    let ty = parseTypeExpr cursor diags
    let dflt =
        match Cursor.tryEatPunct Eq cursor with
        | Some _ -> Some (parseExpr cursor diags)
        | None -> None
    let trailingAnns = parseTrailingAnnotations cursor diags
    // Field-level trailing annotations attach to the field's annotation
    // list (after any item-level prefix annotations).
    let allAnns = List.append anns trailingAnns
    { DocComments = docs
      Annotations = allAnns
      Visibility  = vis
      Name        = name
      Type        = ty
      Default     = dflt
      Span        = joinSpans startSpan ty.Span }

and private parseRecordMembers
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : RecordMember list =
    match Cursor.tryEatPunct LBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0121"
            "expected '{' to start record body"
            (Cursor.peekSpan cursor)
    Cursor.skipStmtEnds cursor |> ignore
    let xs = ResizeArray<RecordMember>()
    while Cursor.peekToken cursor <> TPunct RBrace
          && not (Cursor.isAtEnd cursor) do
        let _before = Cursor.mark cursor
        match Cursor.peekToken cursor with
        | TKeyword KwInvariant ->
            xs.Add(RMInvariant (parseInvariantClause cursor diags))
        | TKeyword KwFunc ->
            // D037: methods in type body — `func name(self: …): R = …`.
            // Hoisted to a top-level `<RecordName>.<methodName>` after
            // the source file finishes parsing.
            xs.Add(RMFunc (parseFunctionDeclBody cursor diags None))
        | TKeyword KwAsync
            when (Cursor.peekAt cursor 1).Token = TKeyword KwFunc ->
            xs.Add(RMFunc (parseFunctionDeclBody cursor diags None))
        | _ ->
            xs.Add(RMField (parseFieldDecl cursor diags))
        // Tolerate STMT_END or comma between members.
        match Cursor.peekToken cursor with
        | TStmtEnd | TPunct Comma ->
            Cursor.advance cursor |> ignore
            Cursor.skipStmtEnds cursor |> ignore
        | _ -> ()
        forceAdvanceIfStuck cursor _before
    match Cursor.tryEatPunct RBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0122"
            "expected '}' to close record body"
            (Cursor.peekSpan cursor)
    List.ofSeq xs

and private parseRecordBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (genericsPrefix: GenericParams option)
        (isExposed: bool)
        : RecordDecl =
    let startSpan = Cursor.peekSpan cursor
    if isExposed then
        Cursor.advance cursor |> ignore   // 'exposed'
    Cursor.advance cursor |> ignore       // 'record'
    let name, nameSpan = readIdent cursor diags "record"
    Cursor.skipStmtEnds cursor |> ignore
    let genericsSuffix = parseGenericParamsOpt cursor diags
    let generics = mergeGenericsInfo diags genericsPrefix genericsSuffix
    Cursor.skipStmtEnds cursor |> ignore
    let where = parseWhereClauseOpt cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    parseTrailingAnnotations cursor diags |> ignore
    let members = parseRecordMembers cursor diags
    let endSpan = Cursor.peekSpan cursor
    { Name     = name
      Generics = generics
      Where    = where
      Members  = members
      Span     = joinSpans startSpan endSpan }

// ----- union ---------------------------------------------------------------

and private parseUnionField
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : UnionField =
    // Look-ahead: `IDENT ':' Type` is named; otherwise positional.
    let saved = Cursor.mark cursor
    match Cursor.peekToken cursor with
    | TIdent _ ->
        let nameTok = Cursor.advance cursor
        if Cursor.peekToken cursor = TPunct Colon then
            Cursor.advance cursor |> ignore
            let ty = parseTypeExpr cursor diags
            let name =
                match nameTok.Token with
                | TIdent n -> n
                | _ -> "<error>"
            UFNamed(name, ty, joinSpans nameTok.Span ty.Span)
        else
            Cursor.reset cursor saved
            let ty = parseTypeExpr cursor diags
            UFPos(ty, ty.Span)
    | _ ->
        let ty = parseTypeExpr cursor diags
        UFPos(ty, ty.Span)

and private parseUnionCase
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : UnionCase =
    let startSpan = Cursor.peekSpan cursor
    let docs = parseItemDocComments cursor
    let anns = parseItemAnnotations cursor diags
    match Cursor.tryEatKeyword KwCase cursor with
    | Some _ -> ()
    | None ->
        err diags "P0130"
            "expected 'case' to start a union case"
            (Cursor.peekSpan cursor)
    let name, nameSpan = readIdent cursor diags "case"
    let fields = ResizeArray<UnionField>()
    if Cursor.peekToken cursor = TPunct LParen then
        Cursor.advance cursor |> ignore
        if Cursor.peekToken cursor <> TPunct RParen then
            fields.Add(parseUnionField cursor diags)
            while Cursor.peekToken cursor = TPunct Comma do
                Cursor.advance cursor |> ignore
                if Cursor.peekToken cursor = TPunct RParen then ()
                else fields.Add(parseUnionField cursor diags)
        match Cursor.tryEatPunct RParen cursor with
        | Some _ -> ()
        | None ->
            err diags "P0131"
                "expected ')' to close union case payload"
                (Cursor.peekSpan cursor)
    let endSpan = Cursor.peekSpan cursor
    { DocComments = docs
      Annotations = anns
      Name        = name
      Fields      = List.ofSeq fields
      Span        = joinSpans startSpan endSpan }

and private parseUnionCases
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : UnionCase list =
    match Cursor.tryEatPunct LBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0132"
            "expected '{' to start union body"
            (Cursor.peekSpan cursor)
    Cursor.skipStmtEnds cursor |> ignore
    let xs = ResizeArray<UnionCase>()
    while Cursor.peekToken cursor <> TPunct RBrace
          && not (Cursor.isAtEnd cursor) do
        let _before = Cursor.mark cursor
        xs.Add(parseUnionCase cursor diags)
        match Cursor.peekToken cursor with
        | TStmtEnd | TPunct Comma ->
            Cursor.advance cursor |> ignore
            Cursor.skipStmtEnds cursor |> ignore
        | _ -> ()
        forceAdvanceIfStuck cursor _before
    match Cursor.tryEatPunct RBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0133"
            "expected '}' to close union body"
            (Cursor.peekSpan cursor)
    List.ofSeq xs

and private parseUnionBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (genericsPrefix: GenericParams option)
        : UnionDecl =
    let startTok = Cursor.advance cursor   // 'union'
    let name, nameSpan = readIdent cursor diags "union"
    Cursor.skipStmtEnds cursor |> ignore
    let genericsSuffix = parseGenericParamsOpt cursor diags
    let generics = mergeGenericsInfo diags genericsPrefix genericsSuffix
    Cursor.skipStmtEnds cursor |> ignore
    let where = parseWhereClauseOpt cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    parseTrailingAnnotations cursor diags |> ignore
    let cases = parseUnionCases cursor diags
    let endSpan = Cursor.peekSpan cursor
    { Name     = name
      Generics = generics
      Where    = where
      Cases    = cases
      Span     = joinSpans startTok.Span endSpan }

// ----- enum ----------------------------------------------------------------

and private parseEnumCase
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : EnumCase =
    let startSpan = Cursor.peekSpan cursor
    let docs = parseItemDocComments cursor
    let anns = parseItemAnnotations cursor diags
    match Cursor.tryEatKeyword KwCase cursor with
    | Some _ -> ()
    | None ->
        err diags "P0140"
            "expected 'case' to start an enum case"
            (Cursor.peekSpan cursor)
    let name, nameSpan = readIdent cursor diags "case"
    { DocComments = docs
      Annotations = anns
      Name        = name
      Span        = joinSpans startSpan nameSpan }

and private parseEnumCases
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : EnumCase list =
    match Cursor.tryEatPunct LBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0141"
            "expected '{' to start enum body"
            (Cursor.peekSpan cursor)
    Cursor.skipStmtEnds cursor |> ignore
    let xs = ResizeArray<EnumCase>()
    while Cursor.peekToken cursor <> TPunct RBrace
          && not (Cursor.isAtEnd cursor) do
        let _before = Cursor.mark cursor
        xs.Add(parseEnumCase cursor diags)
        match Cursor.peekToken cursor with
        | TStmtEnd | TPunct Comma ->
            Cursor.advance cursor |> ignore
            Cursor.skipStmtEnds cursor |> ignore
        | _ -> ()
        forceAdvanceIfStuck cursor _before
    match Cursor.tryEatPunct RBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0142"
            "expected '}' to close enum body"
            (Cursor.peekSpan cursor)
    List.ofSeq xs

and private parseEnumBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : EnumDecl =
    let startTok = Cursor.advance cursor   // 'enum'
    let name, _ = readIdent cursor diags "enum"
    let cases = parseEnumCases cursor diags
    let endSpan = Cursor.peekSpan cursor
    { Name = name
      Cases = cases
      Span = joinSpans startTok.Span endSpan }

// ----- opaque type ---------------------------------------------------------

and private parseOpaqueMembers
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : OpaqueMember list =
    match Cursor.tryEatPunct LBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0150"
            "expected '{' to start opaque type body"
            (Cursor.peekSpan cursor)
    Cursor.skipStmtEnds cursor |> ignore
    let xs = ResizeArray<OpaqueMember>()
    while Cursor.peekToken cursor <> TPunct RBrace
          && not (Cursor.isAtEnd cursor) do
        let _before = Cursor.mark cursor
        match Cursor.peekToken cursor with
        | TKeyword KwInvariant ->
            xs.Add(OMInvariant (parseInvariantClause cursor diags))
        | _ ->
            xs.Add(OMField (parseFieldDecl cursor diags))
        match Cursor.peekToken cursor with
        | TStmtEnd | TPunct Comma ->
            Cursor.advance cursor |> ignore
            Cursor.skipStmtEnds cursor |> ignore
        | _ -> ()
        forceAdvanceIfStuck cursor _before
    match Cursor.tryEatPunct RBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0151"
            "expected '}' to close opaque type body"
            (Cursor.peekSpan cursor)
    List.ofSeq xs

and private parseOpaqueTypeBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (genericsPrefix: GenericParams option)
        : OpaqueTypeDecl =
    // Caller positions the cursor at the leading keyword. We accept
    // either `opaque type X` (the canonical form) or just `type X`
    // (when the caller has already consumed a wrapping `exposed`).
    let startTok = Cursor.peek cursor
    if Cursor.peekToken cursor = TKeyword KwOpaque then
        Cursor.advance cursor |> ignore
    if Cursor.peekToken cursor = TKeyword KwType then
        Cursor.advance cursor |> ignore
    let name, _ = readIdent cursor diags "opaque type"
    Cursor.skipStmtEnds cursor |> ignore
    let genericsSuffix = parseGenericParamsOpt cursor diags
    let generics = mergeGenericsInfo diags genericsPrefix genericsSuffix
    Cursor.skipStmtEnds cursor |> ignore
    let where = parseWhereClauseOpt cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    // Post-name annotations (e.g. `@projectable`). Stored on
    // OpaqueTypeDecl directly — this parser does not drop them
    // like the record / union / etc. variants.
    let postAnns = parseTrailingAnnotations cursor diags
    // Body forms recognised:
    //   `opaque type X`              — header only (no body)
    //   `opaque type X { … }`        — inline body (record-shape)
    //   `opaque type X = record { … }` — `.lbody`-style body file
    //                                    (the `record` keyword is
    //                                    syntactic sugar — the
    //                                    representation is always
    //                                    record-shaped)
    let hasBody, members =
        match Cursor.peekToken cursor with
        | TPunct LBrace ->
            true, parseOpaqueMembers cursor diags
        | TPunct Eq ->
            Cursor.advance cursor |> ignore
            // Skip a leading `record` keyword if present.
            if Cursor.peekToken cursor = TKeyword KwRecord then
                Cursor.advance cursor |> ignore
            true, parseOpaqueMembers cursor diags
        | _ ->
            false, []
    let endSpan = Cursor.peekSpan cursor
    { Name        = name
      Generics    = generics
      Where       = where
      Annotations = postAnns
      Members     = members
      HasBody     = hasBody
      Span        = joinSpans startTok.Span endSpan }

// ---------------------------------------------------------------------------
// P6a: functions, parameter modes, contract clauses.
//
// `func`-shaped items have the head:
//   [async] func NAME [generic[…]] '(' params ')' [: TYPE]
//                                  [where …] { contract clauses }
//                                  ( '=' EXPR | block )
// FunctionSig (used inside interfaces and externs) is everything up to
// but not including the body.
// ---------------------------------------------------------------------------

and private parseParam
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Param =
    // The worked-example syntax is `name: mode type`, mirrored in the
    // language reference (§5.1: `func add(x: in Int, y: in Int)`).
    // The original grammar.ebnf put the mode first; this is a known
    // grammar/reference mismatch and we follow the reference + the
    // worked examples here.
    let startSpan = Cursor.peekSpan cursor
    // `self` is a hard keyword but is also the canonical name for the
    // implicit-receiver parameter inside `impl` method declarations
    // (worked example 6: `func add(self: in Vec3, other: in Vec3)`).
    // Accept it specifically as a parameter name in addition to
    // ordinary identifiers.
    let name, _ =
        match Cursor.peekToken cursor with
        | TKeyword KwSelf ->
            let t = Cursor.advance cursor
            "self", t.Span
        | _ ->
            readIdent cursor diags "parameter"
    match Cursor.tryEatPunct Colon cursor with
    | Some _ -> ()
    | None ->
        err diags "P0161"
            "expected ':' after parameter name"
            (Cursor.peekSpan cursor)
    let mode =
        match Cursor.peekToken cursor with
        | TKeyword KwIn    -> Cursor.advance cursor |> ignore; PMIn
        | TKeyword KwOut   -> Cursor.advance cursor |> ignore; PMOut
        | TKeyword KwInout -> Cursor.advance cursor |> ignore; PMInout
        | _                -> PMIn   // default mode is `in`
    let ty = parseTypeExpr cursor diags
    let dflt =
        match Cursor.tryEatPunct Eq cursor with
        | Some _ -> Some (parseExpr cursor diags)
        | None -> None
    let endSpan =
        match dflt with
        | Some e -> e.Span
        | None -> ty.Span
    { Mode    = mode
      Name    = name
      Type    = ty
      Default = dflt
      Span    = joinSpans startSpan endSpan }

/// Wait — Lyric's worked examples occasionally write parameters
/// without an explicit mode keyword. The grammar requires a mode (per
/// language reference D004, mandatory parameter modes), but inside
/// constructor-style helpers the convention may vary. The parser here
/// requires a mode and reports P0160 if missing.
and private parseParamList
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Param list =
    match Cursor.tryEatPunct LParen cursor with
    | Some _ -> ()
    | None ->
        err diags "P0162"
            "expected '(' to start parameter list"
            (Cursor.peekSpan cursor)
    let xs = ResizeArray<Param>()
    if Cursor.peekToken cursor <> TPunct RParen then
        xs.Add(parseParam cursor diags)
        while Cursor.peekToken cursor = TPunct Comma do
            Cursor.advance cursor |> ignore
            if Cursor.peekToken cursor = TPunct RParen then ()
            else xs.Add(parseParam cursor diags)
    match Cursor.tryEatPunct RParen cursor with
    | Some _ -> ()
    | None ->
        err diags "P0163"
            "expected ')' to close parameter list"
            (Cursor.peekSpan cursor)
    List.ofSeq xs

/// Parse a single contract clause. Returns None if the next token is
/// not a contract-clause keyword.
and private parseContractClauseOpt
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ContractClause option =
    let startSpan = Cursor.peekSpan cursor
    match Cursor.peekToken cursor with
    | TKeyword KwRequires ->
        Cursor.advance cursor |> ignore
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> ()
        | None ->
            err diags "P0170"
                "expected ':' after 'requires'"
                (Cursor.peekSpan cursor)
        let e = parseExpr cursor diags
        Some (CCRequires(e, joinSpans startSpan e.Span))
    | TKeyword KwEnsures ->
        Cursor.advance cursor |> ignore
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> ()
        | None ->
            err diags "P0170"
                "expected ':' after 'ensures'"
                (Cursor.peekSpan cursor)
        let e = parseExpr cursor diags
        Some (CCEnsures(e, joinSpans startSpan e.Span))
    | TKeyword KwWhen ->
        Cursor.advance cursor |> ignore
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> ()
        | None ->
            err diags "P0170"
                "expected ':' after 'when'"
                (Cursor.peekSpan cursor)
        let e = parseExpr cursor diags
        Some (CCWhen(e, joinSpans startSpan e.Span))
    | _ -> None

/// Parse zero or more contract clauses, tolerating STMT_ENDs between
/// them. Returns the collected list and stops at the first non-clause
/// token (typically `=` or `{` for a function body).
and private parseContractClauses
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ContractClause list =
    let xs = ResizeArray<ContractClause>()
    let mutable keepGoing = true
    while keepGoing do
        Cursor.skipStmtEnds cursor |> ignore
        match parseContractClauseOpt cursor diags with
        | Some c -> xs.Add(c)
        | None -> keepGoing <- false
    List.ofSeq xs

and private parseFunctionBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : FunctionBody =
    match Cursor.peekToken cursor with
    | TPunct Eq ->
        Cursor.advance cursor |> ignore
        FBExpr (parseExpr cursor diags)
    | TPunct LBrace ->
        FBBlock (parseBlock cursor diags)
    | _ ->
        err diags "P0172"
            "expected '=' or '{' to start function body"
            (Cursor.peekSpan cursor)
        FBBlock { Statements = []; Span = Cursor.peekSpan cursor }

and private parseFunctionDeclBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (genericsPrefix: GenericParams option)
        : FunctionDecl =
    let startSpan = Cursor.peekSpan cursor
    let isAsync =
        match Cursor.tryEatKeyword KwAsync cursor with
        | Some _ -> true
        | None -> false
    match Cursor.tryEatKeyword KwFunc cursor with
    | Some _ -> ()
    | None ->
        err diags "P0173"
            "expected 'func' keyword"
            (Cursor.peekSpan cursor)
    // Function names may be qualified — `func TypeName.method(…)`
    // is the method-style declaration form (worked example 9 shows
    // `pub func TeamView.tryInto(…)`). For now we collapse the
    // dotted segments into a single string with embedded dots; a
    // proper qualifier slot on FunctionDecl is a later AST change.
    let firstName, _ = readIdent cursor diags "function"
    let parts = ResizeArray<string>()
    parts.Add(firstName)
    while Cursor.peekToken cursor = TPunct Dot do
        Cursor.advance cursor |> ignore
        match Cursor.tryEatIdent cursor with
        | Some (n, _) -> parts.Add(n)
        | None -> ()
    let name = String.concat "." (List.ofSeq parts)
    Cursor.skipStmtEnds cursor |> ignore
    let genericsSuffix = parseGenericParamsOpt cursor diags
    let generics = mergeGenericsInfo diags genericsPrefix genericsSuffix
    Cursor.skipStmtEnds cursor |> ignore
    let parameters = parseParamList cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    let returnType =
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> Some (parseTypeExpr cursor diags)
        | None -> None
    Cursor.skipStmtEnds cursor |> ignore
    let where = parseWhereClauseOpt cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    parseTrailingAnnotations cursor diags |> ignore
    let contracts = parseContractClauses cursor diags
    // Body. If the next token is `=` or `{`, parse one. Otherwise
    // there is no body — used in interface signatures and extern
    // declarations.
    let body =
        match Cursor.peekToken cursor with
        | TPunct Eq | TPunct LBrace ->
            Some (parseFunctionBody cursor diags)
        | _ -> None
    let endSpan = Cursor.peekSpan cursor
    { DocComments = []
      Annotations = []
      Visibility  = None
      IsAsync     = isAsync
      Name        = name
      Generics    = generics
      Params      = parameters
      Return      = returnType
      Where       = where
      Contracts   = contracts
      Body        = body
      Span        = joinSpans startSpan endSpan }

// ---------------------------------------------------------------------------
// P6b: interface and impl declarations.
// ---------------------------------------------------------------------------

and private parseAssociatedTypeDecl
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : AssociatedTypeDecl =
    let startTok = Cursor.advance cursor   // 'type'
    let name, nameSpan = readIdent cursor diags "associated type"
    let default' =
        match Cursor.tryEatPunct Eq cursor with
        | Some _ -> Some (parseTypeExpr cursor diags)
        | None -> None
    let endSpan =
        match default' with
        | Some t -> t.Span
        | None -> nameSpan
    { Name    = name
      Default = default'
      Span    = joinSpans startTok.Span endSpan }

and private parseInterfaceMember
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : InterfaceMember option =
    let docs = parseItemDocComments cursor
    let anns = parseItemAnnotations cursor diags
    match Cursor.peekToken cursor with
    | TKeyword KwType ->
        Some (IMAssoc (parseAssociatedTypeDecl cursor diags))
    | TKeyword KwFunc | TKeyword KwAsync ->
        let fn = parseFunctionDeclBody cursor diags None
        let fn = { fn with DocComments = docs; Annotations = anns }
        match fn.Body with
        | None ->
            Some (IMSig
                { IsAsync   = fn.IsAsync
                  Name      = fn.Name
                  Generics  = fn.Generics
                  Params    = fn.Params
                  Return    = fn.Return
                  Where     = fn.Where
                  Contracts = fn.Contracts
                  Span      = fn.Span })
        | Some _ ->
            Some (IMFunc fn)
    | _ ->
        err diags "P0181"
            "expected 'func', 'async func', or 'type' inside interface body"
            (Cursor.peekSpan cursor)
        if not (Cursor.isAtEnd cursor) then
            Cursor.advance cursor |> ignore
        None

and private parseInterfaceMembers
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : InterfaceMember list =
    match Cursor.tryEatPunct LBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0182"
            "expected '{' to start interface body"
            (Cursor.peekSpan cursor)
    Cursor.skipStmtEnds cursor |> ignore
    let xs = ResizeArray<InterfaceMember>()
    while Cursor.peekToken cursor <> TPunct RBrace
          && not (Cursor.isAtEnd cursor) do
        let _before = Cursor.mark cursor
        match parseInterfaceMember cursor diags with
        | Some m -> xs.Add(m)
        | None -> ()
        match Cursor.peekToken cursor with
        | TStmtEnd | TPunct Comma ->
            Cursor.advance cursor |> ignore
            Cursor.skipStmtEnds cursor |> ignore
        | _ -> ()
        forceAdvanceIfStuck cursor _before
    match Cursor.tryEatPunct RBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0183"
            "expected '}' to close interface body"
            (Cursor.peekSpan cursor)
    List.ofSeq xs

and private parseInterfaceBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (genericsPrefix: GenericParams option)
        : InterfaceDecl =
    let startTok = Cursor.advance cursor   // 'interface'
    let name, _ = readIdent cursor diags "interface"
    Cursor.skipStmtEnds cursor |> ignore
    let genericsSuffix = parseGenericParamsOpt cursor diags
    let generics = mergeGenericsInfo diags genericsPrefix genericsSuffix
    Cursor.skipStmtEnds cursor |> ignore
    let where = parseWhereClauseOpt cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    parseTrailingAnnotations cursor diags |> ignore
    let members = parseInterfaceMembers cursor diags
    let endSpan = Cursor.peekSpan cursor
    { Name     = name
      Generics = generics
      Where    = where
      Members  = members
      Span     = joinSpans startTok.Span endSpan }

and private parseImplMember
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ImplMember option =
    let docs = parseItemDocComments cursor
    let anns = parseItemAnnotations cursor diags
    match Cursor.peekToken cursor with
    | TKeyword KwType ->
        Some (IMplAssoc (parseAssociatedTypeDecl cursor diags))
    | TKeyword KwFunc | TKeyword KwAsync ->
        let fn = parseFunctionDeclBody cursor diags None
        let fn = { fn with DocComments = docs; Annotations = anns }
        Some (IMplFunc fn)
    | _ ->
        err diags "P0184"
            "expected 'func', 'async func', or 'type' inside impl body"
            (Cursor.peekSpan cursor)
        if not (Cursor.isAtEnd cursor) then
            Cursor.advance cursor |> ignore
        None

and private parseImplMembers
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ImplMember list =
    match Cursor.tryEatPunct LBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0185"
            "expected '{' to start impl body"
            (Cursor.peekSpan cursor)
    Cursor.skipStmtEnds cursor |> ignore
    let xs = ResizeArray<ImplMember>()
    while Cursor.peekToken cursor <> TPunct RBrace
          && not (Cursor.isAtEnd cursor) do
        let _before = Cursor.mark cursor
        match parseImplMember cursor diags with
        | Some m -> xs.Add(m)
        | None -> ()
        match Cursor.peekToken cursor with
        | TStmtEnd | TPunct Comma ->
            Cursor.advance cursor |> ignore
            Cursor.skipStmtEnds cursor |> ignore
        | _ -> ()
        forceAdvanceIfStuck cursor _before
    match Cursor.tryEatPunct RBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0186"
            "expected '}' to close impl body"
            (Cursor.peekSpan cursor)
    List.ofSeq xs

and private parseImplBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (genericsPrefix: GenericParams option)
        : ImplDecl =
    let startTok = Cursor.advance cursor   // 'impl'
    let suffixGenerics = parseGenericParamsOpt cursor diags
    let generics = mergeGenericsInfo diags genericsPrefix suffixGenerics
    let interface' = parseConstraintRef cursor diags
    match Cursor.tryEatKeyword KwFor cursor with
    | Some _ -> ()
    | None ->
        err diags "P0180"
            "expected 'for' in impl declaration"
            (Cursor.peekSpan cursor)
    let target = parseTypeExpr cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    let where = parseWhereClauseOpt cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    parseTrailingAnnotations cursor diags |> ignore
    let members = parseImplMembers cursor diags
    let endSpan = Cursor.peekSpan cursor
    { Generics  = generics
      Interface = interface'
      Target    = target
      Where     = where
      Members   = members
      Span      = joinSpans startTok.Span endSpan }

// ---------------------------------------------------------------------------
// P8: remaining item kinds — protected, wire, extern, scope_kind, val,
// test, property, fixture.
// ---------------------------------------------------------------------------

// ----- protected type ------------------------------------------------------

and private parseEntryDecl
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : EntryDecl =
    let startSpan = Cursor.peekSpan cursor
    let docs = parseItemDocComments cursor
    let anns = parseItemAnnotations cursor diags
    let vis =
        match Cursor.tryEatKeyword KwPub cursor with
        | Some t -> Some (Pub t.Span)
        | None -> None
    let entryTok = Cursor.advance cursor   // 'entry'
    let name, _ = readIdent cursor diags "entry"
    let parameters = parseParamList cursor diags
    let returnType =
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> Some (parseTypeExpr cursor diags)
        | None -> None
    let contracts = parseContractClauses cursor diags
    let body = parseFunctionBody cursor diags
    let endSpan = Cursor.peekSpan cursor
    let _ = entryTok
    { DocComments = docs
      Annotations = anns
      Visibility  = vis
      Name        = name
      Params      = parameters
      Return      = returnType
      Contracts   = contracts
      Body        = body
      Span        = joinSpans startSpan endSpan }

and private parseProtectedField
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ProtectedField =
    let startSpan = Cursor.peekSpan cursor
    match Cursor.peekToken cursor with
    | TKeyword KwVar ->
        Cursor.advance cursor |> ignore
        let name, _ = readIdent cursor diags "field"
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> ()
        | None ->
            err diags "P0240" "expected ':' after field name" (Cursor.peekSpan cursor)
        let ty = parseTypeExpr cursor diags
        let init =
            match Cursor.tryEatPunct Eq cursor with
            | Some _ -> Some (parseExpr cursor diags)
            | None -> None
        let endSpan =
            match init with
            | Some e -> e.Span
            | None -> ty.Span
        PFVar(name, ty, init, joinSpans startSpan endSpan)
    | TKeyword KwLet ->
        Cursor.advance cursor |> ignore
        let name, _ = readIdent cursor diags "field"
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> ()
        | None ->
            err diags "P0240" "expected ':' after field name" (Cursor.peekSpan cursor)
        let ty = parseTypeExpr cursor diags
        let init =
            match Cursor.tryEatPunct Eq cursor with
            | Some _ -> Some (parseExpr cursor diags)
            | None -> None
        let endSpan =
            match init with
            | Some e -> e.Span
            | None -> ty.Span
        PFLet(name, ty, init, joinSpans startSpan endSpan)
    | _ ->
        // Plain immutable field: same shape as record FieldDecl.
        PFImmutable (parseFieldDecl cursor diags)

and private parseProtectedMember
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ProtectedMember =
    Cursor.skipStmtEnds cursor |> ignore
    match Cursor.peekToken cursor with
    | TKeyword KwInvariant ->
        PMInvariant (parseInvariantClause cursor diags)
    | TKeyword KwEntry ->
        PMEntry (parseEntryDecl cursor diags)
    // pub-prefixed entry is also legal — handled inside parseEntryDecl.
    | TKeyword KwPub
        when (Cursor.peekAt cursor 1).Token = TKeyword KwEntry ->
        PMEntry (parseEntryDecl cursor diags)
    | TKeyword KwPub
        when ((Cursor.peekAt cursor 1).Token = TKeyword KwFunc
              || (Cursor.peekAt cursor 1).Token = TKeyword KwAsync) ->
        // `pub func` / `pub async func` member.
        let docs = parseItemDocComments cursor
        let anns = parseItemAnnotations cursor diags
        let visTok = Cursor.advance cursor   // pub
        let fn = parseFunctionDeclBody cursor diags None
        PMFunc { fn with DocComments = docs
                         Annotations = anns
                         Visibility  = Some (Pub visTok.Span) }
    | TKeyword KwFunc | TKeyword KwAsync ->
        PMFunc (parseFunctionDeclBody cursor diags None)
    | TKeyword KwVar | TKeyword KwLet ->
        PMField (parseProtectedField cursor diags)
    | _ ->
        // Plain field declaration (var-less).
        PMField (parseProtectedField cursor diags)

and private parseProtectedTypeBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (genericsPrefix: GenericParams option)
        : ProtectedTypeDecl =
    let startTok = Cursor.advance cursor   // 'protected'
    Cursor.advance cursor |> ignore        // 'type'
    let name, _ = readIdent cursor diags "protected type"
    Cursor.skipStmtEnds cursor |> ignore
    let genericsSuffix = parseGenericParamsOpt cursor diags
    let generics = mergeGenericsInfo diags genericsPrefix genericsSuffix
    Cursor.skipStmtEnds cursor |> ignore
    let where = parseWhereClauseOpt cursor diags
    Cursor.skipStmtEnds cursor |> ignore
    parseTrailingAnnotations cursor diags |> ignore
    match Cursor.tryEatPunct LBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0241" "expected '{' to start protected type body"
            (Cursor.peekSpan cursor)
    Cursor.skipStmtEnds cursor |> ignore
    let xs = ResizeArray<ProtectedMember>()
    while Cursor.peekToken cursor <> TPunct RBrace
          && not (Cursor.isAtEnd cursor) do
        let _before = Cursor.mark cursor
        xs.Add(parseProtectedMember cursor diags)
        match Cursor.peekToken cursor with
        | TStmtEnd | TPunct Comma ->
            Cursor.advance cursor |> ignore
            Cursor.skipStmtEnds cursor |> ignore
        | _ -> ()
        forceAdvanceIfStuck cursor _before
    match Cursor.tryEatPunct RBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0242" "expected '}' to close protected type body"
            (Cursor.peekSpan cursor)
    let endSpan = Cursor.peekSpan cursor
    { Name     = name
      Generics = generics
      Where    = where
      Members  = List.ofSeq xs
      Span     = joinSpans startTok.Span endSpan }

// ----- wire ---------------------------------------------------------------

and private parseWireMember
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : WireMember =
    let startSpan = Cursor.peekSpan cursor
    match Cursor.peekToken cursor with
    | TPunct At
        when (Cursor.peekAt cursor 1).Token = TIdent "provided" ->
        Cursor.advance cursor |> ignore   // @
        Cursor.advance cursor |> ignore   // provided
        let name, _ = readIdent cursor diags "@provided"
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> ()
        | None ->
            err diags "P0250" "expected ':' after @provided name" (Cursor.peekSpan cursor)
        let ty = parseTypeExpr cursor diags
        WMProvided(name, ty, joinSpans startSpan ty.Span)
    | TKeyword KwSingleton ->
        Cursor.advance cursor |> ignore
        let name, _ = readIdent cursor diags "singleton"
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> ()
        | None ->
            err diags "P0251" "expected ':' after 'singleton' name" (Cursor.peekSpan cursor)
        let ty = parseTypeExpr cursor diags
        match Cursor.tryEatPunct Eq cursor with
        | Some _ -> ()
        | None ->
            err diags "P0252" "expected '=' in singleton declaration" (Cursor.peekSpan cursor)
        let init = parseExpr cursor diags
        WMSingleton(name, ty, init, joinSpans startSpan init.Span)
    | TKeyword KwScoped ->
        Cursor.advance cursor |> ignore
        match Cursor.tryEatPunct LBracket cursor with
        | Some _ -> ()
        | None ->
            err diags "P0253" "expected '[' after 'scoped'" (Cursor.peekSpan cursor)
        let scope, _ = readIdent cursor diags "scope tag"
        match Cursor.tryEatPunct RBracket cursor with
        | Some _ -> ()
        | None ->
            err diags "P0254" "expected ']' to close 'scoped[…]'" (Cursor.peekSpan cursor)
        let name, _ = readIdent cursor diags "scoped"
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> ()
        | None ->
            err diags "P0251" "expected ':' after 'scoped' name" (Cursor.peekSpan cursor)
        let ty = parseTypeExpr cursor diags
        match Cursor.tryEatPunct Eq cursor with
        | Some _ -> ()
        | None ->
            err diags "P0252" "expected '=' in scoped declaration" (Cursor.peekSpan cursor)
        let init = parseExpr cursor diags
        WMScoped(scope, name, ty, init, joinSpans startSpan init.Span)
    | TKeyword KwBind ->
        Cursor.advance cursor |> ignore
        // Parse the LHS type WITHOUT consuming the bind's `->`. We
        // build it by composing parseAtomNonParenType (which never
        // looks for arrows) with the nullable suffix and an optional
        // `[type-args]` for parameterised interfaces.
        let interface' =
            let atom = parseAtomNonParenType cursor diags
            applyNullableSuffix cursor atom
        match Cursor.tryEatPunct Arrow cursor with
        | Some _ -> ()
        | None ->
            err diags "P0255" "expected '->' in bind declaration" (Cursor.peekSpan cursor)
        let provider = parseExpr cursor diags
        WMBind(interface', provider, joinSpans startSpan provider.Span)
    | TKeyword KwUse ->
        // `expose` is the keyword in §7.1; `use` is its synonym only
        // in re-exports. We accept `expose` only here.
        err diags "P0256" "unexpected 'use' inside wire body (did you mean 'expose'?)"
            (Cursor.peekSpan cursor)
        Cursor.advance cursor |> ignore
        let name, sp = readIdent cursor diags "expose"
        WMExpose(name, joinSpans startSpan sp)
    | TIdent "expose" ->
        Cursor.advance cursor |> ignore
        let name, sp = readIdent cursor diags "expose"
        WMExpose(name, joinSpans startSpan sp)
    | TKeyword KwVal ->
        Cursor.advance cursor |> ignore
        let name, _ = readIdent cursor diags "wire-local val"
        let ty =
            match Cursor.tryEatPunct Colon cursor with
            | Some _ -> Some (parseTypeExpr cursor diags)
            | None -> None
        match Cursor.tryEatPunct Eq cursor with
        | Some _ -> ()
        | None ->
            err diags "P0257" "expected '=' in wire-local val" (Cursor.peekSpan cursor)
        let init = parseExpr cursor diags
        WMLocal(name, ty, init, joinSpans startSpan init.Span)
    | _ ->
        err diags "P0258" "expected wire member" (Cursor.peekSpan cursor)
        if not (Cursor.isAtEnd cursor) then
            Cursor.advance cursor |> ignore
        WMExpose("<error>", startSpan)

and private parseWireBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : WireDecl =
    let startTok = Cursor.advance cursor   // 'wire'
    let name, _ = readIdent cursor diags "wire"
    let parameters =
        if Cursor.peekToken cursor = TPunct LParen then
            parseParamList cursor diags
        else []
    match Cursor.tryEatPunct LBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0259" "expected '{' to start wire body" (Cursor.peekSpan cursor)
    Cursor.skipStmtEnds cursor |> ignore
    let xs = ResizeArray<WireMember>()
    while Cursor.peekToken cursor <> TPunct RBrace
          && not (Cursor.isAtEnd cursor) do
        let _before = Cursor.mark cursor
        xs.Add(parseWireMember cursor diags)
        match Cursor.peekToken cursor with
        | TStmtEnd | TPunct Comma ->
            Cursor.advance cursor |> ignore
            Cursor.skipStmtEnds cursor |> ignore
        | _ -> ()
        forceAdvanceIfStuck cursor _before
    match Cursor.tryEatPunct RBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0260" "expected '}' to close wire body" (Cursor.peekSpan cursor)
    let endSpan = Cursor.peekSpan cursor
    { Name    = name
      Params  = parameters
      Members = List.ofSeq xs
      Span    = joinSpans startTok.Span endSpan }

// ----- extern package ------------------------------------------------------

and private parseExternMember
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ExternMember option =
    let _docs = parseItemDocComments cursor
    let _anns = parseItemAnnotations cursor diags
    let _vis  =
        match Cursor.tryEatKeyword KwPub cursor with
        | Some _ -> true
        | None -> false
    match Cursor.peekToken cursor with
    | TKeyword KwExposed
        when (Cursor.peekAt cursor 1).Token = TKeyword KwRecord ->
        Some (EMExposedRec (parseRecordBody cursor diags None true))
    | TKeyword KwExposed
        when (Cursor.peekAt cursor 1).Token = TKeyword KwType ->
        // `exposed type X` is the FFI-only sugar (per worked example
        // §11.1) for an opaque-shaped extern. Treat as a header-only
        // OpaqueTypeDecl with `exposed` recorded as a synthetic
        // annotation. Skip the `exposed` keyword first so the body
        // parser sees `type X`.
        Cursor.advance cursor |> ignore  // 'exposed'
        let inlineDecl = parseOpaqueTypeBody cursor diags None
        // Tag with a synthetic `@exposed` annotation marker so the
        // resolver can distinguish from a regular opaque extern.
        let exposedTag : Annotation =
            { Name = { Segments = ["exposed"]; Span = inlineDecl.Span }
              Args = []
              Span = inlineDecl.Span }
        Some (EMOpaque
                { inlineDecl with
                    Annotations = exposedTag :: inlineDecl.Annotations })
    | TKeyword KwRecord ->
        Some (EMRecord (parseRecordBody cursor diags None false))
    | TKeyword KwUnion ->
        Some (EMUnion (parseUnionBody cursor diags None))
    | TKeyword KwEnum ->
        Some (EMEnum (parseEnumBody cursor diags))
    | TKeyword KwOpaque
        when (Cursor.peekAt cursor 1).Token = TKeyword KwType ->
        Some (EMOpaque (parseOpaqueTypeBody cursor diags None))
    | TKeyword KwAlias ->
        Some (EMTypeAlias (parseTypeAliasBody cursor diags None))
    | TKeyword KwType ->
        Some (EMDistinctType (parseDistinctTypeBody cursor diags None))
    | TKeyword KwFunc | TKeyword KwAsync ->
        let fn = parseFunctionDeclBody cursor diags None
        Some (EMSig
            { IsAsync = fn.IsAsync; Name = fn.Name
              Generics = fn.Generics; Params = fn.Params
              Return = fn.Return; Where = fn.Where
              Contracts = fn.Contracts; Span = fn.Span })
    | _ ->
        err diags "P0270"
            "expected an extern declaration"
            (Cursor.peekSpan cursor)
        if not (Cursor.isAtEnd cursor) then
            Cursor.advance cursor |> ignore
        None

and private parseExternPackageBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        (anns: Annotation list)
        : ExternPackageDecl =
    let startTok = Cursor.advance cursor   // 'extern'
    Cursor.advance cursor |> ignore        // 'package'
    let path = parseModulePath cursor diags
    match Cursor.tryEatPunct LBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0271" "expected '{' to start extern package body"
            (Cursor.peekSpan cursor)
    Cursor.skipStmtEnds cursor |> ignore
    let xs = ResizeArray<ExternMember>()
    while Cursor.peekToken cursor <> TPunct RBrace
          && not (Cursor.isAtEnd cursor) do
        let _before = Cursor.mark cursor
        match parseExternMember cursor diags with
        | Some m -> xs.Add(m)
        | None -> ()
        match Cursor.peekToken cursor with
        | TStmtEnd | TPunct Comma ->
            Cursor.advance cursor |> ignore
            Cursor.skipStmtEnds cursor |> ignore
        | _ -> ()
        forceAdvanceIfStuck cursor _before
    match Cursor.tryEatPunct RBrace cursor with
    | Some _ -> ()
    | None ->
        err diags "P0272" "expected '}' to close extern package body"
            (Cursor.peekSpan cursor)
    let endSpan = Cursor.peekSpan cursor
    { Path        = path
      Annotations = anns
      Members     = List.ofSeq xs
      Span        = joinSpans startTok.Span endSpan }

/// `extern type Foo = "System.Foo"` — declare a Lyric-side opaque
/// alias for a CLR type loaded into the AppDomain.  The string is
/// the CLR `FullName`; the type checker treats `Foo` as an
/// ordinary user type with no fields (opaque), and the emitter
/// looks the CLR type up at codegen via reflection.
and private parseExternTypeBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ExternTypeDecl =
    let startTok = Cursor.advance cursor   // 'extern'
    Cursor.advance cursor |> ignore        // 'type'
    let name, _ = readIdent cursor diags "extern type"
    let generics = parseGenericParamsOpt cursor diags
    match Cursor.tryEatPunct Eq cursor with
    | Some _ -> ()
    | None ->
        err diags "P0273" "expected '=' after extern type name"
            (Cursor.peekSpan cursor)
    let clrName, clrSpan =
        match Cursor.peekToken cursor with
        | TString s ->
            let tok = Cursor.advance cursor
            s, tok.Span
        | _ ->
            err diags "P0274"
                "expected a string literal naming the CLR type (e.g. \"System.DateTime\")"
                (Cursor.peekSpan cursor)
            "<error>", Cursor.peekSpan cursor
    { Name     = name
      Generics = generics
      ClrName  = clrName
      Span     = joinSpans startTok.Span clrSpan }

// ----- module-level val / scope_kind / test / property / fixture ----------

and private parseModuleValBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ValDecl =
    let startTok = Cursor.advance cursor   // 'val'
    let pat = parsePattern cursor diags
    let ty =
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> Some (parseTypeExpr cursor diags)
        | None -> None
    match Cursor.tryEatPunct Eq cursor with
    | Some _ -> ()
    | None ->
        err diags "P0280" "expected '=' in module-level val" (Cursor.peekSpan cursor)
    let init = parseExpr cursor diags
    { Pattern = pat
      Type    = ty
      Init    = init
      Span    = joinSpans startTok.Span init.Span }

and private parseScopeKindBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : ScopeKindDecl =
    let startTok = Cursor.advance cursor   // 'scope_kind' (TIdent)
    let name, sp = readIdent cursor diags "scope_kind"
    { Name = name
      Span = joinSpans startTok.Span sp }

and private parseTestBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : TestDecl =
    let startTok = Cursor.advance cursor   // 'test'
    let title =
        match Cursor.peek cursor with
        | { Token = TString s } ->
            Cursor.advance cursor |> ignore
            s
        | t ->
            err diags "P0290" "expected a string literal as test name" t.Span
            "<error>"
    Cursor.skipStmtEnds cursor |> ignore
    let body = parseBlock cursor diags
    { Title = title
      Body  = body
      Span  = joinSpans startTok.Span body.Span }

and private parsePropertyBinder
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : PropertyBinder =
    let name, nameSp = readIdent cursor diags "property binder"
    match Cursor.tryEatPunct Colon cursor with
    | Some _ -> ()
    | None ->
        err diags "P0291" "expected ':' in property binder"
            (Cursor.peekSpan cursor)
    let ty = parseTypeExpr cursor diags
    { Name = name
      Type = ty
      Span = joinSpans nameSp ty.Span }

and private parsePropertyBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : PropertyDecl =
    let startTok = Cursor.advance cursor   // 'property'
    let title =
        match Cursor.peek cursor with
        | { Token = TString s } ->
            Cursor.advance cursor |> ignore
            s
        | t ->
            err diags "P0292" "expected a string literal as property name" t.Span
            "<error>"
    let binders =
        match Cursor.peekToken cursor with
        | TIdent "forall" ->
            Cursor.advance cursor |> ignore
            match Cursor.tryEatPunct LParen cursor with
            | Some _ -> ()
            | None ->
                err diags "P0293" "expected '(' after 'forall' in property"
                    (Cursor.peekSpan cursor)
            let xs = ResizeArray<PropertyBinder>()
            if Cursor.peekToken cursor <> TPunct RParen then
                xs.Add(parsePropertyBinder cursor diags)
                while Cursor.peekToken cursor = TPunct Comma do
                    Cursor.advance cursor |> ignore
                    if Cursor.peekToken cursor = TPunct RParen then ()
                    else xs.Add(parsePropertyBinder cursor diags)
            match Cursor.tryEatPunct RParen cursor with
            | Some _ -> ()
            | None ->
                err diags "P0294" "expected ')' to close 'forall' binder list"
                    (Cursor.peekSpan cursor)
            List.ofSeq xs
        | _ -> []
    Cursor.skipStmtEnds cursor |> ignore
    let where' =
        match Cursor.tryEatKeyword KwWhere cursor with
        | Some _ -> Some (parseExpr cursor diags)
        | None -> None
    Cursor.skipStmtEnds cursor |> ignore
    let body = parseBlock cursor diags
    { Title  = title
      ForAll = binders
      Where  = where'
      Body   = body
      Span   = joinSpans startTok.Span body.Span }

and private parseFixtureBody
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : FixtureDecl =
    let startTok = Cursor.advance cursor   // 'fixture'
    let name, _ = readIdent cursor diags "fixture"
    let ty =
        match Cursor.tryEatPunct Colon cursor with
        | Some _ -> Some (parseTypeExpr cursor diags)
        | None -> None
    match Cursor.tryEatPunct Eq cursor with
    | Some _ -> ()
    | None ->
        err diags "P0295" "expected '=' in fixture declaration"
            (Cursor.peekSpan cursor)
    let init = parseExpr cursor diags
    { Name = name
      Type = ty
      Init = init
      Span = joinSpans startTok.Span init.Span }

// ---------------------------------------------------------------------------
// Top-level item loop. Lives at the end of the mutual-recursion chain
// so it can dispatch into every body parser above.
// ---------------------------------------------------------------------------

and private parseItem
        (cursor: Cursor)
        (diags:  ResizeArray<Diagnostic>)
        : Item option =

    Cursor.skipStmtEnds cursor |> ignore
    if Cursor.isAtEnd cursor then None
    else
        let prefixStart = Cursor.peekSpan cursor
        let docs = parseItemDocComments cursor
        // Worked-examples freely interleave annotations, `pub`, and
        // `generic[…]` before the item-kind keyword:
        //
        //   pub func foo …
        //   generic[T] pub func foo …
        //   @derive(Json) pub exposed record …
        //   generic[K] @pure pub func keys …
        //
        // Loop until none of the three prefix tokens matches.
        let collectedAnns = ResizeArray<Annotation>()
        let mutable vis            : Visibility option   = None
        let mutable genericsPrefix : GenericParams option = None
        let mutable progress = true
        while progress do
            // Tolerate STMT_END between prefix tokens (annotations on
            // their own line, blank line between the annotation and
            // `pub`, etc.).
            Cursor.skipStmtEnds cursor |> ignore
            match Cursor.peekToken cursor with
            | TKeyword KwPub when vis.IsNone ->
                let t = Cursor.advance cursor
                vis <- Some (Pub t.Span)
            | TKeyword KwGeneric when genericsPrefix.IsNone ->
                genericsPrefix <- parseGenericParamsOpt cursor diags
            | TPunct At ->
                match parseAnnotation cursor diags with
                | Some a -> collectedAnns.Add(a)
                | None -> progress <- false
            | _ -> progress <- false
        let anns = List.ofSeq collectedAnns

        let nextTok = Cursor.peek cursor
        let kind =
            match nextTok.Token with
            | TKeyword KwAlias ->
                ITypeAlias (parseTypeAliasBody cursor diags genericsPrefix)
            | TKeyword KwType ->
                IDistinctType (parseDistinctTypeBody cursor diags genericsPrefix)
            | TKeyword KwRecord ->
                IRecord (parseRecordBody cursor diags genericsPrefix false)
            | TKeyword KwExposed
                when (Cursor.peekAt cursor 1).Token = TKeyword KwRecord ->
                IExposedRec (parseRecordBody cursor diags genericsPrefix true)
            | TKeyword KwUnion ->
                IUnion (parseUnionBody cursor diags genericsPrefix)
            | TKeyword KwEnum ->
                match genericsPrefix with
                | Some g ->
                    err diags "P0100"
                        "enum does not accept generic parameters"
                        g.Span
                | None -> ()
                IEnum (parseEnumBody cursor diags)
            | TKeyword KwOpaque
                when (Cursor.peekAt cursor 1).Token = TKeyword KwType ->
                IOpaque (parseOpaqueTypeBody cursor diags genericsPrefix)
            | TKeyword KwFunc ->
                let fn = parseFunctionDeclBody cursor diags genericsPrefix
                IFunc { fn with
                          DocComments = docs
                          Annotations = anns
                          Visibility  = vis }
            | TKeyword KwAsync
                when (Cursor.peekAt cursor 1).Token = TKeyword KwFunc ->
                let fn = parseFunctionDeclBody cursor diags genericsPrefix
                IFunc { fn with
                          DocComments = docs
                          Annotations = anns
                          Visibility  = vis }
            | TKeyword KwInterface ->
                IInterface (parseInterfaceBody cursor diags genericsPrefix)
            | TKeyword KwImpl ->
                IImpl (parseImplBody cursor diags genericsPrefix)
            | TKeyword KwProtected
                when (Cursor.peekAt cursor 1).Token = TKeyword KwType ->
                IProtected (parseProtectedTypeBody cursor diags genericsPrefix)
            | TKeyword KwWire ->
                IWire (parseWireBody cursor diags)
            | TKeyword KwExtern
                when (Cursor.peekAt cursor 1).Token = TKeyword KwPackage ->
                IExtern (parseExternPackageBody cursor diags anns)
            | TKeyword KwExtern
                when (Cursor.peekAt cursor 1).Token = TKeyword KwType ->
                IExternType (parseExternTypeBody cursor diags)
            | TKeyword KwVal ->
                IVal (parseModuleValBody cursor diags)
            | TKeyword KwTest ->
                ITest (parseTestBody cursor diags)
            | TKeyword KwProperty ->
                IProperty (parsePropertyBody cursor diags)
            | TKeyword KwFixture ->
                IFixture (parseFixtureBody cursor diags)
            | TIdent "scope_kind" ->
                IScopeKind (parseScopeKindBody cursor diags)
            | tok when isItemStartToken tok ->
                // Recognised but not yet implemented; fall back to
                // the P3 skip-and-IError path.
                err diags "P0098"
                    "item-level parsing not yet implemented; body skipped"
                    nextTok.Span
                skipItemBody cursor |> ignore
                IError
            | _ ->
                err diags "P0040"
                    "expected an item declaration"
                    nextTok.Span
                if not (Cursor.isAtEnd cursor) then
                    Cursor.advance cursor |> ignore
                IError

        let endSpan = Cursor.peekSpan cursor
        Some
            { DocComments = docs
              Annotations = anns
              Visibility  = vis
              Kind        = kind
              Span        = joinSpans prefixStart endSpan }

and private parseItems
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

    // D037: hoist methods declared inside `record` / `exposed record`
    // bodies to top-level UFCS-style `<TypeName>.<methodName>`
    // functions.  The original record decl keeps only its fields and
    // invariants; the hoisted functions append to the file's items so
    // the existing UFCS dispatch handles the rest.
    let hoistInlineMethods (xs: Item list) : Item list =
        let result = ResizeArray<Item>()
        for it in xs do
            match it.Kind with
            | IRecord rd ->
                let nonFunc, funcs =
                    rd.Members
                    |> List.partition (function
                        | RMFunc _ -> false
                        | _ -> true)
                let strippedRecord =
                    { it with
                        Kind = IRecord { rd with Members = nonFunc } }
                result.Add(strippedRecord)
                for m in funcs do
                    match m with
                    | RMFunc fn ->
                        let renamed =
                            { fn with
                                Name = rd.Name + "." + fn.Name }
                        result.Add({ it with Kind = IFunc renamed })
                    | _ -> ()
            | IExposedRec rd ->
                let nonFunc, funcs =
                    rd.Members
                    |> List.partition (function
                        | RMFunc _ -> false
                        | _ -> true)
                let strippedRecord =
                    { it with
                        Kind = IExposedRec { rd with Members = nonFunc } }
                result.Add(strippedRecord)
                for m in funcs do
                    match m with
                    | RMFunc fn ->
                        let renamed =
                            { fn with
                                Name = rd.Name + "." + fn.Name }
                        result.Add({ it with Kind = IFunc renamed })
                    | _ -> ()
            | _ -> result.Add(it)
        List.ofSeq result

    let file =
        { ModuleDoc            = moduleDoc
          FileLevelAnnotations = fileAnnotations
          Package              = packageDecl
          Imports              = imports
          Items                = hoistInlineMethods items
          Span                 = joinSpans startSpan endSpan }

    { File        = file
      Diagnostics = List.ofSeq diags }
