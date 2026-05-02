/// Contract metadata format + embed/extract for cross-package
/// consumption (Tier 3 / D-progress-031).
///
/// Per the C8 decision (D-progress-030 in `docs/12-todo-plan.md`),
/// every emitted Lyric assembly carries a managed resource named
/// `Lyric.Contract` describing its `pub` surface.  Downstream
/// tooling — `lyric build`'s cross-package import resolution,
/// `lyric public-api-diff`, `lyric search` — reads the resource to
/// learn what a `.dll` exports without having to re-parse the
/// source.
///
/// Bootstrap-grade format: JSON-as-UTF-8.  The eventual hand-rolled
/// binary layout (modeled on F#'s `FSharpSignatureData`) drops in
/// later when (a) we have downstream consumers actually reading the
/// resource and (b) JSON parsing latency becomes a real concern.
/// JSON keeps the format human-readable and trivially debugged.
module Lyric.Emitter.ContractMeta

open System
open System.IO
open System.Text
open Lyric.Parser.Ast

/// One serialised public declaration.  Kept structural — no
/// `Lyric.TypeChecker.Type` references — so the metadata is
/// self-contained and the consumer doesn't need to re-resolve.
type ContractDecl =
    { Kind:     string         // "func" | "record" | "union" | "enum" | …
      Name:     string
      Repr:     string }       // canonical signature / shape, free-form

/// Serialised contract for one emitted assembly.
type Contract =
    { PackageName: string
      Version:     string
      Decls:       ContractDecl list }

let private renderTypeExpr (te: TypeExpr) : string =
    let rec go (te: TypeExpr) =
        match te.Kind with
        | TRef p          -> String.concat "." p.Segments
        | TGenericApp (h, args) ->
            let head = String.concat "." h.Segments
            let argStrs =
                args
                |> List.map (function
                    | TAType t  -> go t
                    | TAValue _ -> "<expr>")
            head + "[" + String.concat ", " argStrs + "]"
        | TArray (_, elem) -> sprintf "array[..., %s]" (go elem)
        | TSlice elem      -> sprintf "slice[%s]" (go elem)
        | TRefined (h, _)  -> String.concat "." h.Segments + " range ..."
        | TTuple ts        ->
            "(" + (ts |> List.map go |> String.concat ", ") + ")"
        | TNullable t      -> go t + "?"
        | TFunction (ps, r) ->
            sprintf "(%s) -> %s"
                (ps |> List.map go |> String.concat ", ") (go r)
        | TUnit  -> "Unit"
        | TSelf  -> "Self"
        | TNever -> "Never"
        | TParen t -> "(" + go t + ")"
        | TError -> "<?>"
    go te

let private isPub (vis: Visibility option) =
    match vis with Some _ -> true | None -> false

let private genericsRepr (g: GenericParams option) : string =
    match g with
    | None -> ""
    | Some gp ->
        gp.Params
        |> List.map (function GPType (n, _) | GPValue (n, _, _) -> n)
        |> String.concat ", "
        |> fun s -> "[" + s + "]"

let private modeStr (m: ParamMode) : string =
    match m with PMIn -> "in" | PMOut -> "out" | PMInout -> "inout"

let private declOf (it: Item) : ContractDecl option =
    if not (isPub it.Visibility) then None
    else
        match it.Kind with
        | IFunc fn ->
            let ps =
                fn.Params
                |> List.map (fun p ->
                    sprintf "%s: %s %s" p.Name (modeStr p.Mode) (renderTypeExpr p.Type))
                |> String.concat ", "
            let ret =
                match fn.Return with
                | Some te -> ": " + renderTypeExpr te
                | None    -> ""
            let asyncTok = if fn.IsAsync then "async " else ""
            let repr =
                sprintf "%spub func %s%s(%s)%s"
                    asyncTok fn.Name (genericsRepr fn.Generics) ps ret
            Some { Kind = "func"; Name = fn.Name; Repr = repr }
        | IRecord rd | IExposedRec rd ->
            let fs =
                rd.Members
                |> List.choose (function
                    | RMField fd ->
                        let pubTok = if isPub fd.Visibility then "pub " else ""
                        Some (sprintf "%s%s: %s" pubTok fd.Name (renderTypeExpr fd.Type))
                    | _ -> None)
                |> String.concat ", "
            let repr =
                sprintf "pub record %s%s { %s }"
                    rd.Name (genericsRepr rd.Generics) fs
            Some { Kind = "record"; Name = rd.Name; Repr = repr }
        | IUnion ud ->
            let cs =
                ud.Cases
                |> List.map (fun c ->
                    let fs =
                        c.Fields
                        |> List.map (function
                            | UFNamed (n, te, _) -> sprintf "%s: %s" n (renderTypeExpr te)
                            | UFPos   (te, _)    -> renderTypeExpr te)
                        |> String.concat ", "
                    if fs = "" then "case " + c.Name
                    else sprintf "case %s(%s)" c.Name fs)
                |> String.concat "; "
            let repr =
                sprintf "pub union %s%s { %s }"
                    ud.Name (genericsRepr ud.Generics) cs
            Some { Kind = "union"; Name = ud.Name; Repr = repr }
        | IEnum ed ->
            let cs =
                ed.Cases
                |> List.map (fun c -> "case " + c.Name)
                |> String.concat "; "
            let repr = sprintf "pub enum %s { %s }" ed.Name cs
            Some { Kind = "enum"; Name = ed.Name; Repr = repr }
        | IOpaque od ->
            Some { Kind = "opaque"; Name = od.Name
                   Repr = sprintf "pub opaque type %s%s" od.Name (genericsRepr od.Generics) }
        | IInterface id ->
            Some { Kind = "interface"; Name = id.Name
                   Repr = sprintf "pub interface %s%s" id.Name (genericsRepr id.Generics) }
        | IDistinctType d ->
            Some { Kind = "distinct"; Name = d.Name
                   Repr = sprintf "pub distinct type %s = %s"
                            d.Name (renderTypeExpr d.Underlying) }
        | ITypeAlias ta ->
            Some { Kind = "alias"; Name = ta.Name
                   Repr = sprintf "pub type %s = %s"
                            ta.Name (renderTypeExpr ta.RHS) }
        | IConst c ->
            Some { Kind = "const"; Name = c.Name
                   Repr = sprintf "pub const %s: %s = ..."
                            c.Name (renderTypeExpr c.Type) }
        | _ -> None

/// Walk a `SourceFile` and produce the contract metadata for it.
let buildContract (sf: SourceFile) (version: string) : Contract =
    let pkg = String.concat "." sf.Package.Path.Segments
    let decls = sf.Items |> List.choose declOf
    { PackageName = pkg
      Version     = version
      Decls       = decls }

let private escape (s: string) : string =
    let sb = StringBuilder(s.Length + 2)
    for ch in s do
        match ch with
        | '"'  -> sb.Append "\\\"" |> ignore
        | '\\' -> sb.Append "\\\\" |> ignore
        | '\n' -> sb.Append "\\n" |> ignore
        | '\r' -> sb.Append "\\r" |> ignore
        | '\t' -> sb.Append "\\t" |> ignore
        | c when int c < 0x20 ->
            sb.Append(sprintf "\\u%04x" (int c)) |> ignore
        | c -> sb.Append c |> ignore
    sb.ToString()

/// Render a `Contract` as JSON.  Hand-rolled to avoid pulling in
/// System.Text.Json on every emit (it's already loaded via the
/// stdlib but the explicit serializer wiring is cleaner here).
let toJson (c: Contract) : string =
    let sb = StringBuilder(1024)
    sb.Append "{\n" |> ignore
    sb.Append (sprintf "  \"packageName\": \"%s\",\n" (escape c.PackageName)) |> ignore
    sb.Append (sprintf "  \"version\": \"%s\",\n" (escape c.Version)) |> ignore
    sb.Append "  \"decls\": [\n" |> ignore
    c.Decls
    |> List.iteri (fun i d ->
        let comma = if i = 0 then "" else ",\n"
        sb.Append comma |> ignore
        sb.Append (sprintf "    {\"kind\":\"%s\",\"name\":\"%s\",\"repr\":\"%s\"}"
                    (escape d.Kind) (escape d.Name) (escape d.Repr)) |> ignore)
    sb.Append "\n  ]\n}\n" |> ignore
    sb.ToString()

/// Embed `Lyric.Contract` as a managed resource on the assembly at
/// `dllPath`.  Uses Mono.Cecil to manipulate the resource table —
/// `PersistedAssemblyBuilder` doesn't expose
/// `DefineManifestResource` so post-processing is the simplest path.
/// Idempotent: re-embedding overwrites any prior `Lyric.Contract`
/// resource.
let embedIntoAssembly (dllPath: string) (json: string) : unit =
    let assembly =
        Mono.Cecil.AssemblyDefinition.ReadAssembly(
            dllPath,
            Mono.Cecil.ReaderParameters(InMemory = true))
    let mainModule = assembly.MainModule
    // Drop any pre-existing Lyric.Contract resource so re-embeds are
    // idempotent.
    let toDelete =
        mainModule.Resources
        |> Seq.filter (fun r -> r.Name = "Lyric.Contract")
        |> Seq.toList
    for r in toDelete do
        mainModule.Resources.Remove r |> ignore
    let bytes = Encoding.UTF8.GetBytes json
    let resource =
        Mono.Cecil.EmbeddedResource(
            "Lyric.Contract",
            Mono.Cecil.ManifestResourceAttributes.Public,
            bytes)
    mainModule.Resources.Add(resource)
    let tmp = dllPath + ".tmp"
    assembly.Write(tmp)
    File.Move(tmp, dllPath, overwrite = true)

/// Read the embedded `Lyric.Contract` resource from a .dll and
/// return its JSON payload.  Returns `None` when the resource isn't
/// present (e.g. a non-Lyric assembly, or an older Lyric build).
let readFromAssembly (dllPath: string) : string option =
    let assembly =
        Mono.Cecil.AssemblyDefinition.ReadAssembly(
            dllPath,
            Mono.Cecil.ReaderParameters(InMemory = true))
    let resource =
        assembly.MainModule.Resources
        |> Seq.tryFind (fun r -> r.Name = "Lyric.Contract")
    match resource with
    | Some r ->
        match r with
        | :? Mono.Cecil.EmbeddedResource as er ->
            Some (Encoding.UTF8.GetString(er.GetResourceData()))
        | _ -> None
    | None -> None

/// Parse the JSON payload back to a `Contract` value.  Uses
/// `System.Text.Json` (already loaded via the stdlib) for
/// robustness against future format additions; the schema mirrors
/// `toJson` above.  Returns `None` on parse failure.
let parseFromJson (json: string) : Contract option =
    try
        use doc = System.Text.Json.JsonDocument.Parse(json)
        let root = doc.RootElement
        let pkg =
            match root.TryGetProperty("packageName") with
            | true, e -> e.GetString()
            | _ -> ""
        let ver =
            match root.TryGetProperty("version") with
            | true, e -> e.GetString()
            | _ -> "0.0.0"
        let safeStr (s: string | null) (fallback: string) : string =
            match Option.ofObj s with
            | Some v -> v
            | None   -> fallback
        let decls =
            match root.TryGetProperty("decls") with
            | true, arr when arr.ValueKind = System.Text.Json.JsonValueKind.Array ->
                [ for el in arr.EnumerateArray() do
                    let kind =
                        match el.TryGetProperty("kind") with
                        | true, e -> safeStr (e.GetString()) ""
                        | _ -> ""
                    let name =
                        match el.TryGetProperty("name") with
                        | true, e -> safeStr (e.GetString()) ""
                        | _ -> ""
                    let repr =
                        match el.TryGetProperty("repr") with
                        | true, e -> safeStr (e.GetString()) ""
                        | _ -> ""
                    yield { Kind = kind; Name = name; Repr = repr } ]
            | _ -> []
        let pkgStr = safeStr pkg ""
        let verStr = safeStr ver "0.0.0"
        Some { PackageName = pkgStr; Version = verStr; Decls = decls }
    with _ -> None

/// Diff result for `lyric public-api-diff`.  Each variant carries
/// enough info to render a human-readable line.  Removed/changed
/// entries are SemVer-major-bump-worthy; Added entries are minor-
/// bump-worthy.
type ContractDiffEntry =
    | DiffAdded   of ContractDecl
    | DiffRemoved of ContractDecl
    | DiffChanged of oldDecl: ContractDecl * newDecl: ContractDecl

let private declKey (d: ContractDecl) = (d.Kind, d.Name)

/// Compute a structural diff between two contracts.  Decls keyed
/// by (Kind, Name) — adding a record and removing a same-named
/// function counts as both an Added and a Removed.
let diffContracts
        (oldC: Contract) (newC: Contract) : ContractDiffEntry list =
    let oldByKey =
        oldC.Decls
        |> List.map (fun d -> declKey d, d)
        |> Map.ofList
    let newByKey =
        newC.Decls
        |> List.map (fun d -> declKey d, d)
        |> Map.ofList
    let allKeys =
        Set.union (oldByKey |> Map.toList |> List.map fst |> Set.ofList)
                  (newByKey |> Map.toList |> List.map fst |> Set.ofList)
    [ for key in allKeys do
        match Map.tryFind key oldByKey, Map.tryFind key newByKey with
        | Some o, Some n when o.Repr <> n.Repr -> yield DiffChanged (o, n)
        | Some _, Some _ -> ()  // unchanged
        | None, Some n -> yield DiffAdded n
        | Some o, None -> yield DiffRemoved o
        | None, None -> () ]
    |> List.sortBy (fun entry ->
        let kind, name =
            match entry with
            | DiffAdded d -> 0, declKey d
            | DiffRemoved d -> 1, declKey d
            | DiffChanged (o, _) -> 2, declKey o
        (kind, name))

/// Returns true when the diff contains breaking changes
/// (Removed or Changed).  Added-only diffs are a SemVer minor bump.
let hasBreakingChanges (entries: ContractDiffEntry list) : bool =
    entries
    |> List.exists (function
        | DiffRemoved _ | DiffChanged _ -> true
        | DiffAdded _ -> false)

/// Render a single diff entry as a human-readable line.
let renderDiffEntry (entry: ContractDiffEntry) : string =
    match entry with
    | DiffAdded d ->
        sprintf "  + %s %s : %s" d.Kind d.Name d.Repr
    | DiffRemoved d ->
        sprintf "  - %s %s : %s" d.Kind d.Name d.Repr
    | DiffChanged (o, n) ->
        sprintf "  ~ %s %s\n      old: %s\n      new: %s"
            o.Kind o.Name o.Repr n.Repr
