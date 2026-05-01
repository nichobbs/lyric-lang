/// `lyric doc` — generate a Markdown reference from a Lyric source
/// file's public surface.
///
/// The bootstrap-grade scope is intentionally narrow: walk the AST
/// once, emit one Markdown document per source file, and surface every
/// `pub` declaration plus its leading `///` doc comments.  Cross-file
/// linking, dependency graphs, "examples extracted from doctests", and
/// the eventual HTML output land in Phase 3 once the package manager
/// can identify whole projects.
///
/// What ships:
///   - File header: `# <Package.Path>` + module-level `//!` doc body
///   - Per-`pub`-item section: `### <kind> <name>` + signature in a
///     code fence + the `///` body verbatim
///   - Items emitted: `pub func`, `pub record`, `pub union`, `pub
///     enum`, `pub opaque type`, `pub interface`, `pub type` /
///     `pub distinct type`, `pub const`
///   - Package-private items are omitted.
///
/// Out of scope (tracked in `docs/12-todo-plan.md` C9 follow-ups):
///   - Cross-file references and per-package roll-ups
///   - Stable item anchors / Markdown TOCs
///   - Method tables for impl blocks (the impl declarations get a
///     section but per-method docs are deferred)
module Lyric.Cli.Doc

open System.Text
open Lyric.Lexer
open Lyric.Parser
open Lyric.Parser.Ast

let private hasPubMarker (vis: Visibility option) : bool =
    match vis with
    | Some _ -> true
    | None   -> false

/// Strip the `/// ` prefix from a doc-comment payload.  The lexer
/// stores the text without the leading slashes already, but we
/// trim a single leading space if present.
let private docText (d: DocComment) : string =
    let s = d.Text
    if s.Length > 0 && s.[0] = ' ' then s.Substring 1 else s

let private renderDocComments (sb: StringBuilder) (docs: DocComment list) : unit =
    if not (List.isEmpty docs) then
        for d in docs do
            sb.AppendLine(docText d) |> ignore
        sb.AppendLine() |> ignore

let private renderModuleDocs (sb: StringBuilder) (docs: DocComment list) : unit =
    let moduleDocs = docs |> List.filter (fun d -> d.IsModule)
    renderDocComments sb moduleDocs

// --- type-expression printing --------------------------------------------

let rec private typeStr (te: TypeExpr) : string =
    match te.Kind with
    | TRef p          -> String.concat "." p.Segments
    | TGenericApp (h, args) ->
        let head = String.concat "." h.Segments
        let argStrs =
            args
            |> List.map (function
                | TAType t  -> typeStr t
                | TAValue _ -> "<expr>")
        head + "[" + String.concat ", " argStrs + "]"
    | TArray (_, elem) -> sprintf "array[..., %s]" (typeStr elem)
    | TSlice elem      -> sprintf "slice[%s]" (typeStr elem)
    | TRefined (h, _)  ->
        // `Int range a ..= b` — a use-site refinement.  Render as the
        // underlying name; the bounds are runtime-only.
        String.concat "." h.Segments + " range ..."
    | TTuple ts        ->
        "(" + (ts |> List.map typeStr |> String.concat ", ") + ")"
    | TNullable t      -> typeStr t + "?"
    | TFunction (ps, r) ->
        let ps' = ps |> List.map typeStr |> String.concat ", "
        sprintf "(%s) -> %s" ps' (typeStr r)
    | TUnit            -> "Unit"
    | TSelf            -> "Self"
    | TNever           -> "Never"
    | TParen t         -> "(" + typeStr t + ")"
    | TError           -> "<?>"

let private modeStr (m: ParamMode) : string =
    match m with PMIn -> "in" | PMOut -> "out" | PMInout -> "inout"

let private paramStr (p: Param) : string =
    sprintf "%s: %s %s" p.Name (modeStr p.Mode) (typeStr p.Type)

let private genericsStr (g: GenericParams option) : string =
    match g with
    | None    -> ""
    | Some gp ->
        let names =
            gp.Params
            |> List.map (function
                | GPType (n, _) | GPValue (n, _, _) -> n)
        "[" + String.concat ", " names + "]"

let private functionSignature (fn: FunctionDecl) : string =
    let params' = fn.Params |> List.map paramStr |> String.concat ", "
    let ret =
        match fn.Return with
        | Some te -> ": " + typeStr te
        | None    -> ""
    let asyncTok = if fn.IsAsync then "async " else ""
    sprintf "%spub func %s%s(%s)%s" asyncTok fn.Name (genericsStr fn.Generics) params' ret

let private fieldStr (f: FieldDecl) : string =
    let vis = if hasPubMarker f.Visibility then "pub " else ""
    sprintf "  %s%s: %s" vis f.Name (typeStr f.Type)

let private recordSignature (kind: string) (rd: RecordDecl) : string =
    let fields =
        rd.Members
        |> List.choose (function
            | RMField fd -> Some (fieldStr fd)
            | _          -> None)
    let header = sprintf "pub %s %s%s {" kind rd.Name (genericsStr rd.Generics)
    if List.isEmpty fields then header + " }"
    else header + "\n" + String.concat "\n" fields + "\n}"

let private unionSignature (ud: UnionDecl) : string =
    let caseStr (c: UnionCase) =
        let fields =
            c.Fields
            |> List.map (function
                | UFNamed (n, te, _) -> sprintf "%s: %s" n (typeStr te)
                | UFPos   (te, _)    -> typeStr te)
        if List.isEmpty fields then "  case " + c.Name
        else sprintf "  case %s(%s)" c.Name (String.concat ", " fields)
    let header = sprintf "pub union %s%s {" ud.Name (genericsStr ud.Generics)
    let body =
        ud.Cases
        |> List.map caseStr
        |> String.concat "\n"
    header + "\n" + body + "\n}"

let private enumSignature (ed: EnumDecl) : string =
    let cases = ed.Cases |> List.map (fun c -> "  case " + c.Name) |> String.concat "\n"
    sprintf "pub enum %s {\n%s\n}" ed.Name cases

let private opaqueSignature (od: OpaqueTypeDecl) : string =
    let anns =
        od.Annotations
        |> List.map (fun a -> "@" + (String.concat "." a.Name.Segments))
        |> String.concat " "
    let prefix = if anns = "" then "" else anns + "\n"
    sprintf "%spub opaque type %s%s" prefix od.Name (genericsStr od.Generics)

let private interfaceSignature (id: InterfaceDecl) : string =
    let methodStr (m: InterfaceMember) =
        match m with
        | IMSig sg ->
            let ps = sg.Params |> List.map paramStr |> String.concat ", "
            let ret =
                match sg.Return with
                | Some te -> ": " + typeStr te
                | None    -> ""
            let asyncTok = if sg.IsAsync then "async " else ""
            sprintf "  %sfunc %s%s(%s)%s" asyncTok sg.Name (genericsStr sg.Generics) ps ret
        | IMFunc fn -> "  // default: " + fn.Name
        | IMAssoc a -> sprintf "  type %s" a.Name
    let body =
        id.Members
        |> List.map methodStr
        |> String.concat "\n"
    sprintf "pub interface %s%s {\n%s\n}" id.Name (genericsStr id.Generics) body

let private distinctSignature (dt: DistinctTypeDecl) : string =
    let derives =
        if List.isEmpty dt.Derives then ""
        else " derives " + String.concat ", " dt.Derives
    sprintf "pub distinct type %s%s = %s%s"
        dt.Name (genericsStr dt.Generics)
        (typeStr dt.Underlying) derives

let private typeAliasSignature (ta: TypeAliasDecl) : string =
    sprintf "pub type %s%s = %s"
        ta.Name (genericsStr ta.Generics) (typeStr ta.RHS)

let private constSignature (c: ConstDecl) : string =
    sprintf "pub const %s: %s = ..." c.Name (typeStr c.Type)

// --- per-item rendering ---------------------------------------------------

let private renderItem (sb: StringBuilder) (it: Item) : unit =
    if not (hasPubMarker it.Visibility) then ()
    else
        let render (kind: string) (name: string) (body: string) =
            sb.AppendLine(sprintf "### %s `%s`" kind name) |> ignore
            sb.AppendLine() |> ignore
            sb.AppendLine("```lyric") |> ignore
            sb.AppendLine(body) |> ignore
            sb.AppendLine("```") |> ignore
            sb.AppendLine() |> ignore
            renderDocComments sb it.DocComments
        match it.Kind with
        | IFunc fn        -> render "func" fn.Name (functionSignature fn)
        | IRecord rd      -> render "record" rd.Name (recordSignature "record" rd)
        | IExposedRec rd  -> render "exposed record" rd.Name (recordSignature "exposed record" rd)
        | IUnion ud       -> render "union" ud.Name (unionSignature ud)
        | IEnum ed        -> render "enum" ed.Name (enumSignature ed)
        | IOpaque od      -> render "opaque type" od.Name (opaqueSignature od)
        | IInterface idl  -> render "interface" idl.Name (interfaceSignature idl)
        | IDistinctType d -> render "distinct type" d.Name (distinctSignature d)
        | ITypeAlias ta   -> render "type alias" ta.Name (typeAliasSignature ta)
        | IConst c        -> render "const" c.Name (constSignature c)
        | _ -> ()

// --- top-level entry ------------------------------------------------------

let generate (file: SourceFile) : string =
    let sb = StringBuilder()
    let pkgName = String.concat "." file.Package.Path.Segments
    sb.AppendLine(sprintf "# Package `%s`" pkgName) |> ignore
    sb.AppendLine() |> ignore
    renderModuleDocs sb file.ModuleDoc
    let pubItems =
        file.Items
        |> List.filter (fun it -> hasPubMarker it.Visibility)
    if List.isEmpty pubItems then
        sb.AppendLine("_No public surface._") |> ignore
        sb.AppendLine() |> ignore
    else
        for it in pubItems do
            renderItem sb it
    sb.ToString()
