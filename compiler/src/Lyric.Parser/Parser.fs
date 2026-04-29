/// Lyric parser entry point.
///
/// Phase 1 milestone M1.1 work-in-progress. The current state covers
/// the file head — module doc comments, file-level annotations,
/// `package` declaration, and imports — per docs/grammar.ebnf §2.
/// Item-level parsing (records, functions, etc.) lands in subsequent
/// slices (P3 through P9 per the project plan). Anything past the
/// imports therefore still produces a `P0099` diagnostic flagging
/// unparsed tokens.
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

    // Anything left over is an item; item parsing lands in P3+.
    Cursor.skipStmtEnds cursor |> ignore
    if not (Cursor.isAtEnd cursor) then
        err diags "P0099"
            "item-level parsing not yet implemented; tokens remain unconsumed"
            (Cursor.peekSpan cursor)

    let endSpan = Cursor.peekSpan cursor
    let file =
        { ModuleDoc            = moduleDoc
          FileLevelAnnotations = fileAnnotations
          Package              = packageDecl
          Imports              = imports
          Items                = []
          Span                 = joinSpans startSpan endSpan }

    { File        = file
      Diagnostics = List.ofSeq diags }
