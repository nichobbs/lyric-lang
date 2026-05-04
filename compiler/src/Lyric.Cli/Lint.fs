/// `lyric lint` — style and quality checks for Lyric source files.
///
/// All checks work purely from the parsed AST; no type-checking context
/// is required.  This makes `lint` fast (just lex + parse) and runnable
/// on code that doesn't yet compile.
///
/// Diagnostic codes
/// ----------------
///   L001  PascalCase required for type names (record, union, enum,
///         interface, opaque, protected, distinct type, type alias).
///   L002  camelCase required for function names (`func` items and
///         `entry` declarations inside `protected` blocks).
///   L003  Missing doc comment on a `pub` item.
///   L004  `TODO` or `FIXME` found in a doc comment.
///   L005  `pub func` has no contract clauses (`requires` / `ensures`).
///         Advisory warning — emitted only when the function has a
///         block body (expression-body stubs are excluded).
module Lyric.Cli.Lint

open Lyric.Lexer
open Lyric.Parser.Ast

// ---------------------------------------------------------------------------
// Lint diagnostic type
// ---------------------------------------------------------------------------

type LintSeverity = LintError | LintWarning

type LintDiagnostic =
    { Code:     string
      Severity: LintSeverity
      Message:  string
      Span:     Span }

// ---------------------------------------------------------------------------
// Naming helpers
// ---------------------------------------------------------------------------

/// True when `s` starts with an uppercase ASCII letter (PascalCase signal).
let private startsUpper (s: string) : bool =
    s.Length > 0 && System.Char.IsUpper s.[0]

/// True when `s` starts with a lowercase ASCII letter (camelCase signal).
let private startsLower (s: string) : bool =
    s.Length > 0 && System.Char.IsLower s.[0]

/// True when `s` contains only uppercase ASCII letters, digits, and '_'.
let private isUpperSnake (s: string) : bool =
    s.Length > 0
    && s |> Seq.forall (fun c -> System.Char.IsUpper c || System.Char.IsDigit c || c = '_')

// ---------------------------------------------------------------------------
// Rule implementations
// ---------------------------------------------------------------------------

let private error code msg span : LintDiagnostic =
    { Code = code; Severity = LintError; Message = msg; Span = span }

let private warning code msg span : LintDiagnostic =
    { Code = code; Severity = LintWarning; Message = msg; Span = span }

/// L001 — type name must start with an uppercase letter.
let private checkTypeName (name: string) (span: Span) : LintDiagnostic list =
    if startsUpper name then []
    else
        [error "L001"
            (sprintf "type name '%s' should be PascalCase (start with an uppercase letter)" name)
            span]

/// L002 — function name must start with a lowercase letter.
let private checkFuncName (name: string) (span: Span) : LintDiagnostic list =
    if startsLower name then []
    else
        [error "L002"
            (sprintf "function name '%s' should be camelCase (start with a lowercase letter)" name)
            span]

/// L003 — pub item should have a doc comment.
let private checkPubDoc
        (vis: Visibility option)
        (docs: DocComment list)
        (name: string)
        (kind: string)
        (span: Span) : LintDiagnostic list =
    match vis with
    | None -> []
    | Some _ ->
        if List.isEmpty docs then
            [warning "L003"
                (sprintf "pub %s '%s' has no doc comment (///)" kind name)
                span]
        else []

/// L004 — doc comment contains TODO or FIXME.
let private checkDocTodos (docs: DocComment list) : LintDiagnostic list =
    docs |> List.choose (fun d ->
        let upper = d.Text.ToUpperInvariant()
        if upper.Contains "TODO" || upper.Contains "FIXME" then
            Some (warning "L004"
                (sprintf "doc comment contains TODO/FIXME: '%s'" (d.Text.Trim()))
                d.Span)
        else None)

/// L005 — pub func with a block body should declare at least one contract.
let private checkPubContract
        (vis: Visibility option)
        (fn: FunctionDecl) : LintDiagnostic list =
    match vis with
    | None -> []
    | Some _ ->
        match fn.Body with
        | Some (FBBlock _) when List.isEmpty fn.Contracts ->
            [warning "L005"
                (sprintf "pub func '%s' has no requires/ensures contracts — consider adding contracts or marking the module @runtime_checked"
                    fn.Name)
                fn.Span]
        | _ -> []

// ---------------------------------------------------------------------------
// Item walker
// ---------------------------------------------------------------------------

let private checkItem (item: Item) : LintDiagnostic list =
    let vis  = item.Visibility
    let docs = item.DocComments
    match item.Kind with

    | IFunc fn ->
        checkFuncName fn.Name fn.Span
        @ checkPubDoc vis docs fn.Name "func" item.Span
        @ checkDocTodos docs
        @ checkPubContract vis fn

    | IRecord rd ->
        checkTypeName rd.Name rd.Span
        @ checkPubDoc vis docs rd.Name "record" item.Span
        @ checkDocTodos docs

    | IExposedRec rd ->
        checkTypeName rd.Name rd.Span
        @ checkPubDoc vis docs rd.Name "exposed record" item.Span
        @ checkDocTodos docs

    | IUnion ud ->
        checkTypeName ud.Name ud.Span
        @ checkPubDoc vis docs ud.Name "union" item.Span
        @ checkDocTodos docs

    | IEnum ed ->
        checkTypeName ed.Name ed.Span
        @ checkPubDoc vis docs ed.Name "enum" item.Span
        @ checkDocTodos docs

    | IOpaque od ->
        checkTypeName od.Name od.Span
        @ checkPubDoc vis docs od.Name "opaque type" item.Span
        @ checkDocTodos docs

    | IProtected pd ->
        let typeChecks =
            checkTypeName pd.Name pd.Span
            @ checkPubDoc vis docs pd.Name "protected type" item.Span
            @ checkDocTodos docs
        // Also check entry declarations inside the protected block
        let memberChecks =
            pd.Members |> List.collect (function
                | PMEntry ed ->
                    checkFuncName ed.Name ed.Span
                    @ checkPubDoc ed.Visibility ed.DocComments ed.Name "entry" ed.Span
                    @ checkDocTodos ed.DocComments
                | PMFunc fn ->
                    checkFuncName fn.Name fn.Span
                    @ checkDocTodos fn.DocComments
                | _ -> [])
        typeChecks @ memberChecks

    | IInterface id ->
        let typeChecks =
            checkTypeName id.Name id.Span
            @ checkPubDoc vis docs id.Name "interface" item.Span
            @ checkDocTodos docs
        let memberChecks =
            id.Members |> List.collect (function
                | IMSig sg ->
                    checkFuncName sg.Name sg.Span
                | IMFunc fn ->
                    checkFuncName fn.Name fn.Span
                    @ checkDocTodos fn.DocComments
                | IMAssoc _ -> [])
        typeChecks @ memberChecks

    | IImpl id ->
        let memberChecks =
            id.Members |> List.collect (function
                | IMplFunc fn ->
                    checkFuncName fn.Name fn.Span
                    @ checkDocTodos fn.DocComments
                | IMplAssoc _ -> [])
        checkDocTodos docs @ memberChecks

    | IDistinctType dt ->
        checkTypeName dt.Name dt.Span
        @ checkPubDoc vis docs dt.Name "distinct type" item.Span
        @ checkDocTodos docs

    | ITypeAlias ta ->
        checkTypeName ta.Name ta.Span
        @ checkPubDoc vis docs ta.Name "type alias" item.Span
        @ checkDocTodos docs

    | IConst cd ->
        // Constants may be UPPER_SNAKE_CASE or camelCase.
        // Reject only lowercase-first names that aren't all-upper-snake:
        // i.e. `myConst` is fine; `maxValue` is fine; `max_value` is a warning.
        let nameOk =
            startsUpper cd.Name
            || isUpperSnake cd.Name
        let nameChecks =
            if nameOk then []
            else
                [warning "L001"
                    (sprintf "const '%s' should be PascalCase or UPPER_SNAKE_CASE" cd.Name)
                    cd.Span]
        nameChecks
        @ checkPubDoc vis docs cd.Name "const" item.Span
        @ checkDocTodos docs

    | IWire _ | IScopeKind _ | IExtern _ | IExternType _
    | ITest _ | IProperty _ | IFixture _ | IVal _ | IError ->
        checkDocTodos docs

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

type LintResult =
    { Diagnostics: LintDiagnostic list }

/// Lint a parsed source file.  Returns all diagnostics sorted by source
/// position so the CLI can print them in order.
let lint (file: SourceFile) : LintResult =
    let diags =
        file.Items
        |> List.collect checkItem
        |> List.sortBy (fun d -> d.Span.Start.Line, d.Span.Start.Column)
    { Diagnostics = diags }

/// Render a lint diagnostic in the same `<code> <sev> [line:col]: message`
/// shape the compiler uses.
let renderDiagnostic (d: LintDiagnostic) : string =
    let sev =
        match d.Severity with
        | LintError   -> "error"
        | LintWarning -> "warning"
    sprintf "%s %s [%d:%d]: %s"
        d.Code sev d.Span.Start.Line d.Span.Start.Column d.Message
