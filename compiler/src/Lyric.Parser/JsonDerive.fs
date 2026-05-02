/// AST-level synthesis for `@derive(Json)` records (Tier 2.3 /
/// D-progress-030).
///
/// For each `pub record T` (or `pub exposed record T`) annotated with
/// `@derive(Json)`, the synthesiser appends a `T.toJson(self): String`
/// function that builds an RFC-8259-conformant JSON string by
/// concatenating field-by-field renderings.  Per-field renderings:
///
///   - `Bool`            → `"true"` / `"false"` via `toString`
///   - `Int`, `Long`,
///     `UInt`, `ULong`,
///     `Double`, `Float`  → `toString(value)`
///   - `String`           → `"\"" + value + "\""` (no escaping yet)
///   - Nested record with `@derive(Json)`  → `<TypeName>.toJson(value)`
///   - Anything else      → `toString(value)` as a best-effort fallback
///
/// Bootstrap-grade scope (D-progress-030 follow-ups):
///   - Real String escaping (today's bootstrap doesn't escape `"` or
///     `\` inside string fields).
///   - Slice / Array fields (`slice[T]` should emit `[...]`).
///   - Option / Result / other unions (need case-by-case dispatch).
///   - `fromJson` synthesis (the inverse direction).
///   - Generic records — the synthesised `toJson` is per-type and
///     doesn't yet handle `record Page[T]` in a polymorphic way.
module Lyric.Parser.JsonDerive

open Lyric.Lexer
open Lyric.Parser.Ast

let private isDeriveJson (a: Annotation) : bool =
    match a.Name.Segments with
    | ["derive"] ->
        a.Args
        |> List.exists (fun arg ->
            match arg with
            | ABare (n, _) -> n = "Json"
            | ALiteral (AVIdent (n, _), _) -> n = "Json"
            | _ -> false)
    | _ -> false

let private hasDeriveJson (it: Item) : bool =
    it.Annotations |> List.exists isDeriveJson

let private mkPath (name: string) (span: Span) : ModulePath =
    { Segments = [name]; Span = span }

let private mkExpr (kind: ExprKind) (span: Span) : Expr =
    { Kind = kind; Span = span }

let private mkType (kind: TypeExprKind) (span: Span) : TypeExpr =
    { Kind = kind; Span = span }

let private strLit (s: string) (span: Span) : Expr =
    mkExpr (ELiteral (LString s)) span

/// True if `te` mentions another user record with `@derive(Json)`.
/// Used to decide whether to dispatch to `<TypeName>.toJson(value)`
/// or fall back to a primitive / `toString` rendering.
let private nestedJsonTypeName
        (deriveJsonRecords: Set<string>)
        (te: TypeExpr) : string option =
    match te.Kind with
    | TRef p ->
        match p.Segments with
        | [name] when Set.contains name deriveJsonRecords -> Some name
        | _ -> None
    | _ -> None

let private isStringField (te: TypeExpr) : bool =
    match te.Kind with
    | TRef { Segments = ["String"] } -> true
    | _ -> false

/// Detect a `slice[T]` / `array[N, T]` field whose element type is
/// a primitive Lyric value: `Int`, `Long`, `Double`, `Bool`,
/// `String`.  Returns `Some helperName` (e.g. `"__lyricJsonRenderIntSlice"`)
/// when the synthesiser should route through the matching
/// `Lyric.Stdlib.JsonHost::Render…Slice` static.  `None` falls
/// through to the existing `toString` rendering, which doesn't
/// produce valid JSON for arrays but at least keeps the
/// synthesiser type-safe for non-primitive slices.
let private slicePrimitiveHelper (te: TypeExpr) : string option =
    let elemHelper (elem: TypeExpr) : string option =
        match elem.Kind with
        | TRef { Segments = ["Int"] }    -> Some "__lyricJsonRenderIntSlice"
        | TRef { Segments = ["Long"] }   -> Some "__lyricJsonRenderLongSlice"
        | TRef { Segments = ["Double"] } -> Some "__lyricJsonRenderDoubleSlice"
        | TRef { Segments = ["Bool"] }   -> Some "__lyricJsonRenderBoolSlice"
        | TRef { Segments = ["String"] } -> Some "__lyricJsonRenderStringSlice"
        | _ -> None
    match te.Kind with
    | TSlice elem -> elemHelper elem
    | TArray (_, elem) -> elemHelper elem
    | _ -> None

/// Build the body expression for one field's JSON rendering.
let private renderFieldExpr
        (deriveJsonRecords: Set<string>)
        (selfExpr: Expr)
        (field: FieldDecl) : Expr =
    let span = field.Span
    let access = mkExpr (EMember (selfExpr, field.Name)) span
    match nestedJsonTypeName deriveJsonRecords field.Type with
    | Some typeName ->
        // `<TypeName>.toJson(self.<field>)` — the nested record's
        // synthesised method is also a UFCS-style dotted function.
        let callee =
            mkExpr (EMember (mkExpr (EPath (mkPath typeName span)) span,
                             "toJson")) span
        mkExpr (ECall (callee, [CAPositional access])) span
    | None when isStringField field.Type ->
        // `__lyricJsonEscape(self.<field>)` — routes through the
        // BCL's `JsonEncodedText.Encode` via the stdlib's JsonHost
        // helper, surrounding-quotes-included.  The synthesised
        // extern target is appended once per source file by
        // `synthesizeItems`.
        let callee = mkExpr (EPath (mkPath "__lyricJsonEscape" span)) span
        mkExpr (ECall (callee, [CAPositional access])) span
    | None ->
        match slicePrimitiveHelper field.Type with
        | Some helperName ->
            // `__lyricJsonRender<T>Slice(self.<field>)` — routes
            // through `Lyric.Stdlib.JsonHost::Render<T>Slice`,
            // emitting a valid `[a, b, c]` JSON array literal
            // with proper quoting for String elements.
            let callee = mkExpr (EPath (mkPath helperName span)) span
            mkExpr (ECall (callee, [CAPositional access])) span
        | None ->
            // `toString(self.<field>)` — primitive fields, fallthrough.
            let callee = mkExpr (EPath (mkPath "toString" span)) span
            mkExpr (ECall (callee, [CAPositional access])) span

let private synthesiseToJson
        (deriveJsonRecords: Set<string>)
        (rd: RecordDecl) : FunctionDecl =
    let span = rd.Span
    let fields =
        rd.Members
        |> List.choose (function
            | RMField fd -> Some fd
            | _ -> None)
    let selfExpr = mkExpr ESelf span
    // Build the body expression as a left-associative chain of `+`s.
    let prefix = strLit "{" span
    let suffix = strLit "}" span
    let parts =
        fields
        |> List.mapi (fun i fd ->
            let fieldName = strLit ("\"" + fd.Name + "\":") span
            let value     = renderFieldExpr deriveJsonRecords selfExpr fd
            let comma     = if i = 0 then strLit "" span else strLit "," span
            // (comma + fieldName) + value
            let labelled  = mkExpr (EBinop (BAdd, comma, fieldName)) span
            mkExpr (EBinop (BAdd, labelled, value)) span)
    let body =
        let inner =
            parts
            |> List.fold
                (fun acc part -> mkExpr (EBinop (BAdd, acc, part)) span)
                prefix
        mkExpr (EBinop (BAdd, inner, suffix)) span
    let stringTy = mkType (TRef (mkPath "String" span)) span
    let selfParam : Param =
        { Mode    = PMIn
          Name    = "self"
          Type    = mkType (TRef (mkPath rd.Name span)) span
          Default = None
          Span    = span }
    { DocComments = []
      Annotations = []
      Visibility  = Some (Pub span)
      IsAsync     = false
      Name        = rd.Name + ".toJson"
      Generics    = None
      Params      = [selfParam]
      Return      = Some stringTy
      Where       = None
      Contracts   = []
      Body        = Some (FBExpr body)
      Span        = span }

let synthesizeItems (items: Item list) : Item list =
    // First pass: collect the names of every record with
    // `@derive(Json)` so the per-field renderer knows which fields
    // dispatch to a recursive `T.toJson(value)` call.
    let deriveJsonRecords =
        items
        |> List.choose (fun it ->
            if hasDeriveJson it then
                match it.Kind with
                | IRecord rd | IExposedRec rd -> Some rd.Name
                | _ -> None
            else None)
        |> Set.ofList
    if Set.isEmpty deriveJsonRecords then items
    else
        let result = ResizeArray<Item>(items)
        // Synthesise the JSON-string-escape helper once per source
        // file; the per-field renderer dispatches String fields to
        // `__lyricJsonEscape(value)` rather than wrapping in quotes
        // unsafely.  Pinning to the synthesised name avoids needing
        // the user to `import Std.Json`.
        let firstSpan =
            items
            |> List.tryPick (fun it ->
                if hasDeriveJson it then Some it.Span else None)
            |> Option.defaultWith (fun () -> Lyric.Lexer.Span.pointAt Lyric.Lexer.Position.initial)
        let stringTy = mkType (TRef (mkPath "String" firstSpan)) firstSpan
        let escAnn : Annotation =
            { Name = mkPath "externTarget" firstSpan
              Args =
                [ ALiteral
                    (AVString ("Lyric.Stdlib.JsonHost.EncodeString", firstSpan),
                     firstSpan) ]
              Span = firstSpan }
        let escFn : FunctionDecl =
            { DocComments = []
              Annotations = [ escAnn ]
              Visibility  = None
              IsAsync     = false
              Name        = "__lyricJsonEscape"
              Generics    = None
              Params      =
                [ { Mode    = PMIn
                    Name    = "s"
                    Type    = stringTy
                    Default = None
                    Span    = firstSpan } ]
              Return      = Some stringTy
              Where       = None
              Contracts   = []
              Body        = Some (FBExpr (mkExpr (ELiteral LUnit) firstSpan))
              Span        = firstSpan }
        result.Add
            { DocComments = []
              Annotations = []
              Visibility  = None
              Kind        = IFunc escFn
              Span        = firstSpan }
        // Synthesise per-primitive slice renderers.  Each one is
        // an extern target on `Lyric.Stdlib.JsonHost::Render<T>Slice`
        // accepting a `slice[T]` and returning a `[a, b, c]` JSON
        // array literal.  Defined unconditionally because the
        // synthesiser doesn't yet pre-scan field types — unused
        // helpers cost a few bytes of metadata but no IL.
        let mkSliceHelper
                (helperName: string)
                (clrName: string)
                (elemTy: TypeExpr) : Item =
            let sliceTy =
                mkType (TSlice elemTy) firstSpan
            let ann : Annotation =
                { Name = mkPath "externTarget" firstSpan
                  Args =
                    [ ALiteral
                        (AVString (clrName, firstSpan),
                         firstSpan) ]
                  Span = firstSpan }
            let fn : FunctionDecl =
                { DocComments = []
                  Annotations = [ ann ]
                  Visibility  = None
                  IsAsync     = false
                  Name        = helperName
                  Generics    = None
                  Params      =
                    [ { Mode    = PMIn
                        Name    = "s"
                        Type    = sliceTy
                        Default = None
                        Span    = firstSpan } ]
                  Return      = Some stringTy
                  Where       = None
                  Contracts   = []
                  Body        = Some (FBExpr (mkExpr (ELiteral LUnit) firstSpan))
                  Span        = firstSpan }
            { DocComments = []
              Annotations = []
              Visibility  = None
              Kind        = IFunc fn
              Span        = firstSpan }
        let mkRefTy (name: string) =
            mkType (TRef (mkPath name firstSpan)) firstSpan
        result.Add (mkSliceHelper
            "__lyricJsonRenderIntSlice"
            "Lyric.Stdlib.JsonHost.RenderIntSlice"
            (mkRefTy "Int"))
        result.Add (mkSliceHelper
            "__lyricJsonRenderLongSlice"
            "Lyric.Stdlib.JsonHost.RenderLongSlice"
            (mkRefTy "Long"))
        result.Add (mkSliceHelper
            "__lyricJsonRenderDoubleSlice"
            "Lyric.Stdlib.JsonHost.RenderDoubleSlice"
            (mkRefTy "Double"))
        result.Add (mkSliceHelper
            "__lyricJsonRenderBoolSlice"
            "Lyric.Stdlib.JsonHost.RenderBoolSlice"
            (mkRefTy "Bool"))
        result.Add (mkSliceHelper
            "__lyricJsonRenderStringSlice"
            "Lyric.Stdlib.JsonHost.RenderStringSlice"
            (mkRefTy "String"))
        for it in items do
            if hasDeriveJson it then
                match it.Kind with
                | IRecord rd | IExposedRec rd ->
                    let fn = synthesiseToJson deriveJsonRecords rd
                    result.Add
                        { DocComments = []
                          Annotations = []
                          Visibility  = Some (Pub rd.Span)
                          Kind        = IFunc fn
                          Span        = rd.Span }
                | _ -> ()
        List.ofSeq result
