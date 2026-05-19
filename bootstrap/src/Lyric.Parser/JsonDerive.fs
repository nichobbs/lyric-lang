/// AST-level synthesis for `@generate(Json)` records (Tier 2.3 /
/// D-progress-030).
///
/// For each `pub record T` (or `pub exposed record T`) annotated with
/// `@generate(Json)`, the synthesiser appends a `T.toJson(self): String`
/// function that builds an RFC-8259-conformant JSON string by
/// concatenating field-by-field renderings.  Per-field renderings:
///
///   - `Bool`            → `"true"` / `"false"` via `toString`
///   - `Int`, `Long`,
///     `UInt`, `ULong`,
///     `Double`, `Float`  → `toString(value)`
///   - `String`           → `"\"" + value + "\""` (no escaping yet)
///   - Nested record with `@generate(Json)` → `<TypeName>.toJson(value)`
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
    | ["generate"] ->
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

/// True if `te` mentions another user record with `@generate(Json)`.
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

/// Detect a `slice[Rec]` / `array[N, Rec]` field whose element
/// type is a user record with `@generate(Json)`.  Returns the
/// record name when matched; the synthesiser then routes through
/// a per-record `__lyricJsonRender<RecName>Slice` helper that
/// loops over the slice and calls `<RecName>.toJson` per element.
let private sliceRecordHelper
        (deriveJsonRecords: Set<string>)
        (te: TypeExpr) : string option =
    let elem (e: TypeExpr) : string option =
        match e.Kind with
        | TRef p ->
            match p.Segments with
            | [name] when Set.contains name deriveJsonRecords -> Some name
            | _ -> None
        | _ -> None
    match te.Kind with
    | TSlice e -> elem e
    | TArray (_, e) -> elem e
    | _ -> None

/// Detect `Option[T]` — a generic application whose head is the
/// `Option` union (single segment, no qualifier).  Returns the
/// inner T when matched.  Used by the field renderer to lower
/// `Option[T]` fields to a `match … { case None → "null" ; case
/// Some(v) → render(v) }` synthesis.
let private optionInnerType (te: TypeExpr) : TypeExpr option =
    match te.Kind with
    | TGenericApp (head, args) ->
        match head.Segments with
        | ["Option"] ->
            args
            |> List.tryHead
            |> Option.bind (function
                | TAType t -> Some t
                | TAValue _ -> None)
        | _ -> None
    | _ -> None

/// Render `access` (an expression of static type `te`) as a JSON
/// fragment.  Recursive — used both for top-level field
/// rendering and for the inner type of `Option[T]`.
let rec private renderAccessExpr
        (deriveJsonRecords: Set<string>)
        (access: Expr)
        (te: TypeExpr) : Expr =
    let span = access.Span
    match nestedJsonTypeName deriveJsonRecords te with
    | Some typeName ->
        let callee =
            mkExpr (EMember (mkExpr (EPath (mkPath typeName span)) span,
                             "toJson")) span
        mkExpr (ECall (callee, [CAPositional access])) span
    | None when isStringField te ->
        let callee = mkExpr (EPath (mkPath "__lyricJsonEscape" span)) span
        mkExpr (ECall (callee, [CAPositional access])) span
    | None ->
        match slicePrimitiveHelper te with
        | Some helperName ->
            let callee = mkExpr (EPath (mkPath helperName span)) span
            mkExpr (ECall (callee, [CAPositional access])) span
        | None ->
            match sliceRecordHelper deriveJsonRecords te with
            | Some recName ->
                let helperName =
                    "__lyricJsonRender" + recName + "Slice"
                let callee = mkExpr (EPath (mkPath helperName span)) span
                mkExpr (ECall (callee, [CAPositional access])) span
            | None ->
                match optionInnerType te with
                | Some innerTy ->
                    // D-progress-045: `Option[T]` field lowers to
                    //   match access {
                    //     case None     -> "null"
                    //     case Some(v)  -> renderAccessExpr v innerTy
                    //   }
                    // Recursive `renderAccessExpr` on `v` reuses
                    // every other case (primitive / String / nested
                    // record / slice).
                    let vBinding : Pattern =
                        { Kind = PBinding ("__lyric_json_v", None)
                          Span = span }
                    // Match the parser's shape for `case None ->` —
                    // a nullary constructor parses as `PBinding`,
                    // not `PConstructor`.  Otherwise the codegen
                    // routes match correctly but downstream
                    // handling diverges (only `PBinding` triggers
                    // the `alwaysMatches`-aware union-case test).
                    let nonePat : Pattern =
                        { Kind = PBinding ("None", None)
                          Span = span }
                    let somePat : Pattern =
                        { Kind = PConstructor (mkPath "Some" span, [vBinding])
                          Span = span }
                    let nullExpr = strLit "null" span
                    let vAccess =
                        mkExpr (EPath (mkPath "__lyric_json_v" span)) span
                    let innerExpr =
                        renderAccessExpr deriveJsonRecords vAccess innerTy
                    let arms : MatchArm list =
                        [ { Pattern = nonePat; Guard = None
                            Body = EOBExpr nullExpr; Span = span }
                          { Pattern = somePat; Guard = None
                            Body = EOBExpr innerExpr; Span = span } ]
                    mkExpr (EMatch (access, arms)) span
                | None ->
                    let callee = mkExpr (EPath (mkPath "toString" span)) span
                    mkExpr (ECall (callee, [CAPositional access])) span

/// Build the body expression for one field's JSON rendering.
let private renderFieldExpr
        (deriveJsonRecords: Set<string>)
        (selfExpr: Expr)
        (field: FieldDecl) : Expr =
    let span = field.Span
    let access = mkExpr (EMember (selfExpr, field.Name)) span
    renderAccessExpr deriveJsonRecords access field.Type

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

/// Map a primitive Lyric `TypeExpr` to the matching
/// `__lyricJsonGet<T>` shim name + the field's CLR type
/// expression for the synthesised `var <field>: T = default()`.
let private primitiveFromJsonHelper (te: TypeExpr) : (string * TypeExpr) option =
    match te.Kind with
    | TRef { Segments = ["Int"] }    -> Some ("__lyricJsonGetInt", te)
    | TRef { Segments = ["Long"] }   -> Some ("__lyricJsonGetLong", te)
    | TRef { Segments = ["Double"] } -> Some ("__lyricJsonGetDouble", te)
    | TRef { Segments = ["Bool"] }   -> Some ("__lyricJsonGetBool", te)
    | TRef { Segments = ["String"] } -> Some ("__lyricJsonGetString", te)
    | _ -> None

/// Map a `slice[Primitive]` field type to the matching
/// `__lyricJsonGet<T>Slice` shim.  Returns `None` for non-primitive
/// element types (those need a per-element decoder loop, handled
/// separately by the synthesiser via record-slice helpers).
let private primitiveSliceFromJsonHelper (te: TypeExpr) : (string * TypeExpr) option =
    match te.Kind with
    | TSlice inner ->
        match inner.Kind with
        | TRef { Segments = ["Int"] }    -> Some ("__lyricJsonGetIntSlice", te)
        | TRef { Segments = ["Long"] }   -> Some ("__lyricJsonGetLongSlice", te)
        | TRef { Segments = ["Double"] } -> Some ("__lyricJsonGetDoubleSlice", te)
        | TRef { Segments = ["Bool"] }   -> Some ("__lyricJsonGetBoolSlice", te)
        | TRef { Segments = ["String"] } -> Some ("__lyricJsonGetStringSlice", te)
        | _ -> None
    | _ -> None

/// Field-shape classification for `fromJson` synthesis.
type private FieldShape =
    | FsPrimitive of helperName: string
    | FsPrimitiveSlice of helperName: string
    | FsNestedRecord of recName: string

let private classifyField
        (deriveJsonRecords: Set<string>)
        (te: TypeExpr) : FieldShape option =
    match primitiveFromJsonHelper te with
    | Some (h, _) -> Some (FsPrimitive h)
    | None ->
    match primitiveSliceFromJsonHelper te with
    | Some (h, _) -> Some (FsPrimitiveSlice h)
    | None ->
    match te.Kind with
    | TRef { Segments = [name] } when deriveJsonRecords.Contains name ->
        Some (FsNestedRecord name)
    | _ -> None

/// Synthesise `<RecName>.fromJson(s: String): <RecName>` when
/// every field is a primitive Lyric type the
/// `__lyricJsonGet<T>` shims handle.  Records with non-primitive
/// fields (nested @generate(Json) records, slices, Option) skip
/// `fromJson` synthesis — Phase 2 (D-progress-046 follow-ups).
///
/// The synthesised body is straight-line:
///
///     pub func <RecName>.fromJson(s: in String): <RecName> {
///       var f1: T1 = default()
///       __lyricJsonGet<T1>(s, "f1", f1)   // ignore success/fail
///       var f2: T2 = default()
///       __lyricJsonGet<T2>(s, "f2", f2)
///       ...
///       <RecName>(f1 = f1, f2 = f2, ...)
///     }
///
/// Missing or wrongly-typed fields default-initialise (the
/// extern shim returns false but we ignore the return).  Future
/// revisions can return `Result` / `Option` instead.
let private synthesiseFromJsonOpt
        (deriveJsonRecords: Set<string>)
        (rd: RecordDecl) : FunctionDecl option =
    let span = rd.Span
    let fields =
        rd.Members
        |> List.choose (function
            | RMField fd -> Some fd
            | _ -> None)
    // Classify every field; skip fromJson synthesis if any field
    // has a shape we don't yet support (e.g. Option, slices of
    // records, generic types).
    let perField =
        fields
        |> List.map (fun f -> f, classifyField deriveJsonRecords f.Type)
    if perField |> List.exists (fun (_, h) -> h.IsNone) then None
    elif List.isEmpty fields then None
    else
        let stringTy = mkType (TRef (mkPath "String" span)) span
        let recordTy = mkType (TRef (mkPath rd.Name span)) span
        let stmts = ResizeArray<Statement>()
        let defaultCallExpr () =
            mkExpr (ECall (mkExpr (EPath (mkPath "default" span)) span, [])) span
        for (fd, shapeOpt) in perField do
            let shape =
                match shapeOpt with
                | Some s -> s
                | None -> failwith "unreachable"
            match shape with
            | FsPrimitive helperName ->
                // var <name>: T = default(); __lyricJsonGet<T>(s, "<name>", <name>)
                stmts.Add
                    { Kind =
                        SLocal (LBVar (fd.Name, Some fd.Type, Some (defaultCallExpr ())))
                      Span = span }
                let helperCall =
                    let callee = mkExpr (EPath (mkPath helperName span)) span
                    let args =
                        [ CAPositional (mkExpr (EPath (mkPath "s" span)) span)
                          CAPositional (strLit fd.Name span)
                          CAPositional (mkExpr (EPath (mkPath fd.Name span)) span) ]
                    mkExpr (ECall (callee, args)) span
                stmts.Add { Kind = SExpr helperCall; Span = span }
            | FsPrimitiveSlice helperName ->
                // Same shape as primitive; the helper's out-param
                // type is `slice[T]` (mapped to `T[]` on the CLR
                // side).  `default()` produces a null `T[]` ref;
                // the host shim overwrites it with an array on hit
                // OR an empty array on miss.
                stmts.Add
                    { Kind =
                        SLocal (LBVar (fd.Name, Some fd.Type, Some (defaultCallExpr ())))
                      Span = span }
                let helperCall =
                    let callee = mkExpr (EPath (mkPath helperName span)) span
                    let args =
                        [ CAPositional (mkExpr (EPath (mkPath "s" span)) span)
                          CAPositional (strLit fd.Name span)
                          CAPositional (mkExpr (EPath (mkPath fd.Name span)) span) ]
                    mkExpr (ECall (callee, args)) span
                stmts.Add { Kind = SExpr helperCall; Span = span }
            | FsNestedRecord recName ->
                // var <name>__sub: String = "{}"
                // __lyricJsonGetSubObject(s, "<name>", <name>__sub)
                // val <name>: Inner = Inner.fromJson(<name>__sub)
                let subName = fd.Name + "__sub"
                stmts.Add
                    { Kind =
                        SLocal (LBVar
                            (subName,
                             Some stringTy,
                             Some (strLit "{}" span)))
                      Span = span }
                let getSubCall =
                    let callee =
                        mkExpr (EPath (mkPath "__lyricJsonGetSubObject" span)) span
                    let args =
                        [ CAPositional (mkExpr (EPath (mkPath "s" span)) span)
                          CAPositional (strLit fd.Name span)
                          CAPositional (mkExpr (EPath (mkPath subName span)) span) ]
                    mkExpr (ECall (callee, args)) span
                stmts.Add { Kind = SExpr getSubCall; Span = span }
                let recurseCall =
                    let callee =
                        mkExpr
                            (EMember
                                (mkExpr (EPath (mkPath recName span)) span,
                                 "fromJson"))
                            span
                    let args =
                        [ CAPositional (mkExpr (EPath (mkPath subName span)) span) ]
                    mkExpr (ECall (callee, args)) span
                stmts.Add
                    { Kind =
                        SLocal (LBLet (fd.Name, Some fd.Type, recurseCall))
                      Span = span }
        // Construct: <RecName>(f1 = f1, f2 = f2, ...)
        let ctorArgs =
            fields
            |> List.map (fun fd ->
                CANamed
                    (fd.Name,
                     mkExpr (EPath (mkPath fd.Name span)) span,
                     span))
        let ctorCall =
            mkExpr
                (ECall
                    (mkExpr (EPath (mkPath rd.Name span)) span,
                     ctorArgs))
                span
        stmts.Add
            { Kind = SExpr ctorCall; Span = span }
        let body : Block =
            { Statements = List.ofSeq stmts; Span = span }
        let selfParam : Param =
            { Mode    = PMIn
              Name    = "s"
              Type    = stringTy
              Default = None
              Span    = span }
        Some
            { DocComments = []
              Annotations = []
              Visibility  = Some (Pub span)
              IsAsync     = false
              Name        = rd.Name + ".fromJson"
              Generics    = None
              Params      = [selfParam]
              Return      = Some recordTy
              Where       = None
              Contracts   = []
              Body        = Some (FBBlock body)
              Span        = span }

/// Synthetic imports required by `@generate(Json)` synthesis.
///
/// Returns `[import Std.Json]` if any `@generate(Json)` record exists
/// in the item list; returns `[]` otherwise.  The emitter's
/// `resolveStdlibImports` deduplicates via `HashSet`, so injecting a
/// duplicate when the user already has `import Std.Json` is harmless.
let synthesizeImports (items: Item list) : ImportDecl list =
    let hasDerive =
        items |> List.exists (fun it ->
            hasDeriveJson it &&
            match it.Kind with
            | IRecord _ | IExposedRec _ -> true
            | _ -> false)
    if not hasDerive then []
    else
        let span =
            items
            |> List.tryPick (fun it ->
                if hasDeriveJson it then Some it.Span else None)
            |> Option.defaultWith (fun () ->
                Lyric.Lexer.Span.pointAt Lyric.Lexer.Position.initial)
        [ { Path     = { Segments = ["Std"; "Json"]; Span = span }
            Selector = None
            Alias    = None
            IsPubUse = false
            Span     = span } ]

let synthesizeItems (items: Item list) : Item list =
    // First pass: collect the names of every record with
    // `@generate(Json)` so the per-field renderer knows which fields
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
        // `__lyricJsonEscape` now calls the Lyric-kernel
        // `hostEncodeString` from `Std.JsonHost` instead of routing
        // through an `@externTarget` to the F# shim.  The
        // `synthesizeImports` pass adds `Std.Json`, which transitively
        // pulls `Std.JsonHost` and brings `hostEncodeString` into scope.
        let escBody : Expr =
            let callee = mkExpr (EPath (mkPath "hostEncodeString" firstSpan)) firstSpan
            let arg = mkExpr (EPath (mkPath "s" firstSpan)) firstSpan
            mkExpr (ECall (callee, [ CAPositional arg ])) firstSpan
        let escFn : FunctionDecl =
            { DocComments = []
              Annotations = []
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
              Body        = Some (FBExpr escBody)
              Span        = firstSpan }
        result.Add
            { DocComments = []
              Annotations = []
              Visibility  = None
              Kind        = IFunc escFn
              Span        = firstSpan }
        // Synthesise per-primitive slice renderers.  P3-3 of the
        // native-stdlib plan replaces the legacy
        // `Lyric.Stdlib.JsonHost::Render<T>Slice` extern wrappers
        // with inline `while` loops over `slice[T]` — same shape as
        // `mkRecordSliceHelper` below but with a primitive-specific
        // per-element render expression.  `Double` keeps a tiny
        // host extern for round-trip-faithful formatting
        // (`ToString("R", InvariantCulture)`) which Lyric's
        // `toString` doesn't yet guarantee.  Defined unconditionally
        // because the synthesiser doesn't yet pre-scan field types —
        // unused helpers cost a few bytes of metadata but no IL.
        let mkRefTy (name: string) =
            mkType (TRef (mkPath name firstSpan)) firstSpan
        let strLitInline (s: string) = strLit s firstSpan
        let pathExpr name = mkExpr (EPath (mkPath name firstSpan)) firstSpan
        /// Build an inline `while`-loop slice renderer.  `renderElem`
        /// receives the indexed-element expression `items[i]` and
        /// must produce a `String`-typed expression for that element.
        let mkSliceHelperInline
                (helperName: string)
                (elemTy: TypeExpr)
                (renderElem: Expr -> Expr) : Item =
            let sliceTy = mkType (TSlice elemTy) firstSpan
            let intTy = mkType (TRef (mkPath "Int" firstSpan)) firstSpan
            // var result: String = "["
            let resultDecl =
                { Kind =
                    SLocal (LBVar
                        ("result",
                         Some stringTy,
                         Some (strLitInline "[")))
                  Span = firstSpan }
            // var i: Int = 0
            let iDecl =
                { Kind =
                    SLocal (LBVar
                        ("i",
                         Some intTy,
                         Some (mkExpr (ELiteral (LInt (0UL, NoIntSuffix))) firstSpan)))
                  Span = firstSpan }
            // while i < items.length { … }
            let lengthAccess =
                mkExpr (EMember (pathExpr "items", "length")) firstSpan
            let cond =
                mkExpr (EBinop (BLt, pathExpr "i", lengthAccess)) firstSpan
            // if i > 0 { result = result + "," }
            let zeroLit = mkExpr (ELiteral (LInt (0UL, NoIntSuffix))) firstSpan
            let iGtZero =
                mkExpr (EBinop (BGt, pathExpr "i", zeroLit)) firstSpan
            let appendComma =
                { Kind =
                    SAssign
                        (pathExpr "result", AssEq,
                         mkExpr
                             (EBinop (BAdd, pathExpr "result",
                                       strLitInline ","))
                             firstSpan)
                  Span = firstSpan }
            let ifCommaThenBlock : Block =
                { Statements = [ appendComma ]; Span = firstSpan }
            let ifComma : Statement =
                { Kind =
                    SExpr
                        (mkExpr
                            (EIf (iGtZero,
                                  EOBBlock ifCommaThenBlock,
                                  None,
                                  false))
                            firstSpan)
                  Span = firstSpan }
            // result = result + <renderElem items[i]>
            let elemAccess =
                mkExpr
                    (EIndex (pathExpr "items", [ pathExpr "i" ]))
                    firstSpan
            let appendElem =
                { Kind =
                    SAssign
                        (pathExpr "result", AssEq,
                         mkExpr
                             (EBinop (BAdd, pathExpr "result", renderElem elemAccess))
                             firstSpan)
                  Span = firstSpan }
            // i = i + 1
            let oneLit = mkExpr (ELiteral (LInt (1UL, NoIntSuffix))) firstSpan
            let bumpI =
                { Kind =
                    SAssign
                        (pathExpr "i", AssEq,
                         mkExpr
                             (EBinop (BAdd, pathExpr "i", oneLit))
                             firstSpan)
                  Span = firstSpan }
            let whileBody : Block =
                { Statements = [ ifComma; appendElem; bumpI ]
                  Span       = firstSpan }
            let whileStmt =
                { Kind = SWhile (None, cond, whileBody)
                  Span = firstSpan }
            // result + "]"
            let bodyExpr =
                mkExpr
                    (EBinop (BAdd, pathExpr "result", strLitInline "]"))
                    firstSpan
            let bodyExprStmt =
                { Kind = SExpr bodyExpr; Span = firstSpan }
            let bodyBlock : Block =
                { Statements = [ resultDecl; iDecl; whileStmt; bodyExprStmt ]
                  Span       = firstSpan }
            let fn : FunctionDecl =
                { DocComments = []
                  Annotations = []
                  Visibility  = None
                  IsAsync     = false
                  Name        = helperName
                  Generics    = None
                  Params      =
                    [ { Mode    = PMIn
                        Name    = "items"
                        Type    = sliceTy
                        Default = None
                        Span    = firstSpan } ]
                  Return      = Some stringTy
                  Where       = None
                  Contracts   = []
                  Body        = Some (FBBlock bodyBlock)
                  Span        = firstSpan }
            { DocComments = []
              Annotations = []
              Visibility  = None
              Kind        = IFunc fn
              Span        = firstSpan }
        // Int / Long / Double render via `toString(items[i])`.  The
        // codegen's `toString` builtin emits culture-invariant
        // formatting for `Double` / `Float` (round-trip-safe under
        // `Double.ToString(InvariantCulture)`), so JSON output is
        // locale-stable.
        let toStringCall (e: Expr) =
            mkExpr (ECall (pathExpr "toString", [ CAPositional e ])) firstSpan
        result.Add (mkSliceHelperInline
            "__lyricJsonRenderIntSlice"
            (mkRefTy "Int")
            toStringCall)
        result.Add (mkSliceHelperInline
            "__lyricJsonRenderLongSlice"
            (mkRefTy "Long")
            toStringCall)
        result.Add (mkSliceHelperInline
            "__lyricJsonRenderDoubleSlice"
            (mkRefTy "Double")
            toStringCall)
        // Bool renders via inline `if items[i] { "true" } else { "false" }`.
        let boolRender (e: Expr) =
            mkExpr
                (EIf (e,
                      EOBExpr (strLitInline "true"),
                      Some (EOBExpr (strLitInline "false")),
                      true))
                firstSpan
        result.Add (mkSliceHelperInline
            "__lyricJsonRenderBoolSlice"
            (mkRefTy "Bool")
            boolRender)
        // String routes through the per-source `__lyricJsonEscape`
        // synthesised above (which itself is a host extern wrapping
        // `Lyric.Stdlib.JsonHost.EncodeString`).
        let strRender (e: Expr) =
            mkExpr
                (ECall (pathExpr "__lyricJsonEscape", [ CAPositional e ]))
                firstSpan
        result.Add (mkSliceHelperInline
            "__lyricJsonRenderStringSlice"
            (mkRefTy "String")
            strRender)
        // Per-record slice helpers — one `__lyricJsonRender<Rec>Slice`
        // function per `@generate(Json)` record so fields of type
        // `slice[Rec]` can lower to `__lyricJsonRender<Rec>Slice
        // (self.<field>)`.  The body is a hand-rolled `while` loop
        // that calls `<Rec>.toJson(items[i])` on each element.
        let mkRecordSliceHelper (recName: string) (recSpan: Span) : Item =
            let elemTy = mkType (TRef (mkPath recName recSpan)) recSpan
            let sliceTy = mkType (TSlice elemTy) recSpan
            let intTy = mkType (TRef (mkPath "Int" recSpan)) recSpan
            let strLitInline (s: string) = strLit s recSpan
            let pathExpr name = mkExpr (EPath (mkPath name recSpan)) recSpan
            // var result: String = "["
            let resultDecl =
                { Kind =
                    SLocal (LBVar
                        ("result",
                         Some stringTy,
                         Some (strLitInline "[")))
                  Span = recSpan }
            // var i: Int = 0
            let iDecl =
                { Kind =
                    SLocal (LBVar
                        ("i",
                         Some intTy,
                         Some (mkExpr (ELiteral (LInt (0UL, NoIntSuffix))) recSpan)))
                  Span = recSpan }
            // while i < items.length { ... }
            let lengthAccess =
                mkExpr (EMember (pathExpr "items", "length")) recSpan
            let cond =
                mkExpr (EBinop (BLt, pathExpr "i", lengthAccess)) recSpan
            // if i > 0 { result = result + "," }
            let zeroLit = mkExpr (ELiteral (LInt (0UL, NoIntSuffix))) recSpan
            let iGtZero =
                mkExpr (EBinop (BGt, pathExpr "i", zeroLit)) recSpan
            let appendComma =
                { Kind =
                    SAssign
                        (pathExpr "result", AssEq,
                         mkExpr
                             (EBinop (BAdd, pathExpr "result",
                                       strLitInline ","))
                             recSpan)
                  Span = recSpan }
            let ifCommaThenBlock : Block =
                { Statements = [ appendComma ]; Span = recSpan }
            let ifComma : Statement =
                { Kind =
                    SExpr
                        (mkExpr
                            (EIf (iGtZero,
                                  EOBBlock ifCommaThenBlock,
                                  None,
                                  false))
                            recSpan)
                  Span = recSpan }
            // result = result + <Rec>.toJson(items[i])
            let toJsonCall =
                let callee =
                    mkExpr
                        (EMember (pathExpr recName, "toJson"))
                        recSpan
                let arg =
                    mkExpr
                        (EIndex (pathExpr "items", [ pathExpr "i" ]))
                        recSpan
                mkExpr (ECall (callee, [ CAPositional arg ])) recSpan
            let appendJson =
                { Kind =
                    SAssign
                        (pathExpr "result", AssEq,
                         mkExpr
                             (EBinop (BAdd, pathExpr "result", toJsonCall))
                             recSpan)
                  Span = recSpan }
            // i = i + 1
            let oneLit = mkExpr (ELiteral (LInt (1UL, NoIntSuffix))) recSpan
            let bumpI =
                { Kind =
                    SAssign
                        (pathExpr "i", AssEq,
                         mkExpr
                             (EBinop (BAdd, pathExpr "i", oneLit))
                             recSpan)
                  Span = recSpan }
            let whileBody : Block =
                { Statements = [ ifComma; appendJson; bumpI ]
                  Span       = recSpan }
            let whileStmt =
                { Kind = SWhile (None, cond, whileBody)
                  Span = recSpan }
            // result + "]"
            let bodyExpr =
                mkExpr
                    (EBinop (BAdd, pathExpr "result", strLitInline "]"))
                    recSpan
            let bodyExprStmt =
                { Kind = SExpr bodyExpr; Span = recSpan }
            let bodyBlock : Block =
                { Statements = [ resultDecl; iDecl; whileStmt; bodyExprStmt ]
                  Span       = recSpan }
            let fn : FunctionDecl =
                { DocComments = []
                  Annotations = []
                  Visibility  = None
                  IsAsync     = false
                  Name        = "__lyricJsonRender" + recName + "Slice"
                  Generics    = None
                  Params      =
                    [ { Mode    = PMIn
                        Name    = "items"
                        Type    = sliceTy
                        Default = None
                        Span    = recSpan } ]
                  Return      = Some stringTy
                  Where       = None
                  Contracts   = []
                  Body        = Some (FBBlock bodyBlock)
                  Span        = recSpan }
            { DocComments = []
              Annotations = []
              Visibility  = None
              Kind        = IFunc fn
              Span        = recSpan }
        // fromJson primitive shims — added unconditionally per
        // D-progress-046.  See `synthesiseFromJsonOpt` for the
        // per-record `fromJson` synthesis itself.
        // Emit a shim whose body calls a Lyric stdlib function.
        // Both scalar and slice readers are now implemented in pure
        // Lyric in `_kernel/json_host.l` (the slice readers iterate
        // `JsonElement.ArrayEnumerator` via direct externs).
        let mkGetShimBody
                (helperName: string)
                (lyricCallee: string)
                (valueTy: TypeExpr) : Item =
            let boolTy = mkType (TRef (mkPath "Bool" firstSpan)) firstSpan
            let callBody =
                let callee = mkExpr (EPath (mkPath lyricCallee firstSpan)) firstSpan
                let args =
                    [ CAPositional (mkExpr (EPath (mkPath "s"     firstSpan)) firstSpan)
                      CAPositional (mkExpr (EPath (mkPath "name"  firstSpan)) firstSpan)
                      CAPositional (mkExpr (EPath (mkPath "value" firstSpan)) firstSpan) ]
                mkExpr (ECall (callee, args)) firstSpan
            let fn : FunctionDecl =
                { DocComments = []
                  Annotations = []
                  Visibility  = None
                  IsAsync     = false
                  Name        = helperName
                  Generics    = None
                  Params      =
                    [ { Mode    = PMIn
                        Name    = "s"
                        Type    = stringTy
                        Default = None
                        Span    = firstSpan }
                      { Mode    = PMIn
                        Name    = "name"
                        Type    = stringTy
                        Default = None
                        Span    = firstSpan }
                      { Mode    = PMOut
                        Name    = "value"
                        Type    = valueTy
                        Default = None
                        Span    = firstSpan } ]
                  Return      = Some boolTy
                  Where       = None
                  Contracts   = []
                  Body        = Some (FBExpr callBody)
                  Span        = firstSpan }
            { DocComments = []
              Annotations = []
              Visibility  = None
              Kind        = IFunc fn
              Span        = firstSpan }
        // Scalar readers — implemented in pure Lyric in _kernel/json_host.l
        result.Add (mkGetShimBody "__lyricJsonGetInt"    "lyricJsonGetInt"    (mkRefTy "Int"))
        result.Add (mkGetShimBody "__lyricJsonGetLong"   "lyricJsonGetLong"   (mkRefTy "Long"))
        result.Add (mkGetShimBody "__lyricJsonGetDouble" "lyricJsonGetDouble" (mkRefTy "Double"))
        result.Add (mkGetShimBody "__lyricJsonGetBool"   "lyricJsonGetBool"   (mkRefTy "Bool"))
        result.Add (mkGetShimBody "__lyricJsonGetString" "lyricJsonGetString" (mkRefTy "String"))
        // Slice readers — implemented in pure Lyric in _kernel/json_host.l
        // (`lyricJsonGet*Slice`) on top of direct `JsonElement+ArrayEnumerator`
        // externs.  The `__lyricJsonGet*Slice` helpers are thin Lyric
        // wrappers that call into the kernel implementations, matching
        // the shape of the scalar readers above.
        let mkSliceTy elemRefName =
            mkType (TSlice (mkRefTy elemRefName)) firstSpan
        result.Add (mkGetShimBody "__lyricJsonGetIntSlice"
                                  "lyricJsonGetIntSlice"
                                  (mkSliceTy "Int"))
        result.Add (mkGetShimBody "__lyricJsonGetLongSlice"
                                  "lyricJsonGetLongSlice"
                                  (mkSliceTy "Long"))
        result.Add (mkGetShimBody "__lyricJsonGetDoubleSlice"
                                  "lyricJsonGetDoubleSlice"
                                  (mkSliceTy "Double"))
        result.Add (mkGetShimBody "__lyricJsonGetBoolSlice"
                                  "lyricJsonGetBoolSlice"
                                  (mkSliceTy "Bool"))
        result.Add (mkGetShimBody "__lyricJsonGetStringSlice"
                                  "lyricJsonGetStringSlice"
                                  (mkSliceTy "String"))
        // Sub-object reader — implemented in pure Lyric in _kernel/json_host.l
        result.Add (mkGetShimBody "__lyricJsonGetSubObject" "lyricJsonGetSubObject" (mkRefTy "String"))
        for it in items do
            if hasDeriveJson it then
                match it.Kind with
                | IRecord rd | IExposedRec rd ->
                    result.Add (mkRecordSliceHelper rd.Name rd.Span)
                    let fn = synthesiseToJson deriveJsonRecords rd
                    result.Add
                        { DocComments = []
                          Annotations = []
                          Visibility  = Some (Pub rd.Span)
                          Kind        = IFunc fn
                          Span        = rd.Span }
                    match synthesiseFromJsonOpt deriveJsonRecords rd with
                    | Some fnFrom ->
                        result.Add
                            { DocComments = []
                              Annotations = []
                              Visibility  = Some (Pub rd.Span)
                              Kind        = IFunc fnFrom
                              Span        = rd.Span }
                    | None -> ()
                | _ -> ()
        List.ofSeq result
