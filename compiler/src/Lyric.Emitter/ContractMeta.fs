/// Contract metadata format + embed/extract for cross-package
/// consumption (Tier 3 / D-progress-031, format-2 in D-progress-086).
///
/// Per the C8 decision (D-progress-030 in `docs/12-todo-plan.md`),
/// every emitted Lyric assembly carries a managed resource named
/// `Lyric.Contract` describing its `pub` surface.  Downstream
/// tooling — `lyric build`'s cross-package import resolution,
/// `lyric public-api-diff`, `lyric search`, and the Phase 4
/// verifier — reads the resource to learn what a `.dll` exports
/// without having to re-parse the source.
///
/// Format-2 (D-progress-086) extends the schema with:
///
/// * `formatVersion: 2` at the top level.
/// * `level` per package: `runtime_checked` | `proof_required[(modifier)]` | `axiom`.
/// * `pure: true` on per-decl entries that carry the `@pure` annotation.
/// * `requires` / `ensures`: source-level strings of the contract clauses.
/// * `body`: source-level string of `@pure` function bodies (so
///   cross-package callers can unfold one level).
/// * `params`: structured parameter list (name + type-string + mode)
///   so consumers can rebind for substitution.
///
/// Format-1 payloads continue to round-trip; missing fields default
/// to `runtime_checked` / `pure: false` / no clauses / no body.
module Lyric.Emitter.ContractMeta

open System
open System.IO
open System.Text
open Lyric.Parser.Ast

let private FORMAT_VERSION = 2

/// One serialised public declaration.
///
/// `Repr` is the canonical signature, free-form, used for diff
/// rendering.  The structured fields below are what the verifier
/// (and future consumers) read for actual reasoning.
type ContractDecl =
    { Kind:     string         // "func" | "record" | "union" | "enum" | …
      Name:     string
      Repr:     string         // canonical signature / shape, free-form
      /// `@pure` annotation present on this declaration.
      Pure:     bool
      /// Stability level (D040 / Q011).
      ///   ""                — unannotated (treated as stable for enforcement).
      ///   "stable:X.Y"      — `@stable(since="X.Y")`.
      ///   "experimental"    — `@experimental`.
      Stability: string
      /// Source-level strings of the function's `requires:` clauses.
      /// Empty for non-functions.
      Requires: string list
      /// Source-level strings of the function's `ensures:` clauses.
      Ensures:  string list
      /// Source-level string of the function's body (only populated
      /// when `Pure = true` and the body is an expression form
      /// suitable for one-level unfolding).
      Body:     string option
      /// Structured parameters: (name, type-string).  Lets a consumer
      /// rebind locals without re-parsing `Repr`.
      Params:   (string * string) list }

/// Serialised contract for one emitted assembly.
type Contract =
    { PackageName:   string
      Version:       string
      /// Verification level: `runtime_checked` (default) /
      /// `proof_required` / `proof_required(unsafe_blocks_allowed)` /
      /// `proof_required(checked_arithmetic)` / `axiom`.
      Level:         string
      FormatVersion: int
      Decls:         ContractDecl list }

module ContractDecl =

    /// A `ContractDecl` value with no proof-related metadata —
    /// equivalent to a format-1 entry.  Useful for legacy test
    /// fixtures and decls of kinds that never carry contracts
    /// (records, enums, …).
    let basic (kind: string) (name: string) (repr: string) : ContractDecl =
        { Kind      = kind
          Name      = name
          Repr      = repr
          Pure      = false
          Stability = ""
          Requires  = []
          Ensures   = []
          Body      = None
          Params    = [] }

module Contract =

    /// A `Contract` value with no level / proof-related metadata —
    /// equivalent to a format-1 payload.  Useful for legacy
    /// fixtures.
    let legacy (pkg: string) (ver: string) (decls: ContractDecl list) : Contract =
        { PackageName   = pkg
          Version       = ver
          Level         = "runtime_checked"
          FormatVersion = 1
          Decls         = decls }

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

/// True iff a symbol is part of the *external* contract surface.
/// `pub` is in; `internal` and package-private are both out — internals
/// are visible inside the project but invisible to cross-project
/// consumers reading the contract resource (per
/// `docs/20-project-as-dll.md` §2).
let private isPub (vis: Visibility option) =
    match vis with
    | Some (Pub _)      -> true
    | Some (Internal _) -> false
    | None              -> false

/// Encode the stability annotations on an `Item` as the canonical
/// stability string stored in `ContractDecl.Stability`.
///   `@stable(since="X.Y")` → `"stable:X.Y"`
///   `@experimental`        → `"experimental"`
///   (unannotated)          → `""`
let private stabilityStringOfItem (item: Item) : string =
    let findAnn name =
        item.Annotations |> List.tryFind (fun a ->
            match a.Name.Segments with
            | [seg] -> seg = name
            | _     -> false)
    match findAnn "experimental" with
    | Some _ -> "experimental"
    | None ->
        match findAnn "stable" with
        | Some a ->
            let since =
                a.Args |> List.tryPick (fun arg ->
                    match arg with
                    | AAName("since", AVString(s, _), _) -> Some s
                    | _                                  -> None)
                |> Option.defaultValue ""
            "stable:" + since
        | None -> ""

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

/// Return the source-text of an annotation if its head matches one
/// of the proof-related names (`pure`, `axiom`, `runtime_checked`,
/// `proof_required`).
let private hasAnnotation (name: string) (anns: Annotation list) : bool =
    anns |> List.exists (fun a ->
        match a.Name.Segments with
        | [seg] -> seg = name
        | _     -> false)

/// Best-effort: re-render a Lyric expression (contract clause body
/// or @pure function body) as a single-line source string.  Mirrors
/// the parser's expression grammar at low fidelity but is round-
/// trippable through `parseExprFromString` for the common shapes
/// proof-required code uses (literals, identifiers, binops, calls,
/// member access, `result`, `old(_)`, and `if`/`match` exprs).
let renderExpr (e: Expr) : string =
    let rec lit l =
        match l with
        | Literal.LBool true     -> "true"
        | Literal.LBool false    -> "false"
        | Literal.LInt(v, _)     -> string v
        | Literal.LFloat(v, _)   -> string v
        | Literal.LString s
        | Literal.LTripleString s
        | Literal.LRawString s   -> sprintf "\"%s\"" (s.Replace("\"", "\\\""))
        | Literal.LChar c        -> sprintf "'\\u{%04x}'" c
        | Literal.LUnit          -> "()"
    let binopStr op =
        match op with
        | BAdd -> "+" | BSub -> "-" | BMul -> "*" | BDiv -> "/" | BMod -> "%"
        | BAnd -> "and" | BOr -> "or" | BXor -> "xor"
        | BEq -> "==" | BNeq -> "!=" | BLt -> "<" | BLte -> "<="
        | BGt -> ">"  | BGte -> ">=" | BCoalesce -> "??" | BImplies -> "implies"
    let prefixStr op =
        match op with PreNeg -> "-" | PreNot -> "not " | PreRef -> "&"
    let rec go (e: Expr) =
        match e.Kind with
        | ELiteral l            -> lit l
        | EPath p               -> String.concat "." p.Segments
        | EParen inner          -> "(" + go inner + ")"
        | EResult               -> "result"
        | ESelf                 -> "self"
        | EOld inner            -> "old(" + go inner + ")"
        | EBinop(op, l, r)      -> sprintf "(%s %s %s)" (go l) (binopStr op) (go r)
        | EPrefix(op, x)        -> prefixStr op + go x
        | EMember(r, n)         -> go r + "." + n
        | ECall(fn, args)       ->
            let argStr =
                args
                |> List.map (function
                    | CANamed(_, v, _) -> go v
                    | CAPositional v   -> go v)
                |> String.concat ", "
            go fn + "(" + argStr + ")"
        | EIf(c, t, eOpt, _) ->
            let tBranch =
                match t with EOBExpr x -> go x | EOBBlock _ -> "{ ... }"
            let eBranch =
                match eOpt with
                | Some(EOBExpr x) -> " else " + go x
                | _ -> ""
            sprintf "if %s then %s%s" (go c) tBranch eBranch
        | EMatch(scrut, arms) ->
            let armStr =
                arms
                |> List.map (fun arm ->
                    let body =
                        match arm.Body with
                        | EOBExpr x -> go x
                        | EOBBlock _ -> "{ ... }"
                    let pat = goPat arm.Pattern
                    sprintf "case %s -> %s" pat body)
                |> String.concat " | "
            sprintf "match %s { %s }" (go scrut) armStr
        | _ -> "<unsupported>"
    and goPat (p: Pattern) =
        match p.Kind with
        | PWildcard       -> "_"
        | PLiteral l      -> lit l
        | PBinding(n, _)  -> n
        | PParen inner    -> "(" + goPat inner + ")"
        | _ -> "<pat>"
    go e

/// Whether a function declaration's body can be unfolded as part of
/// a contract metadata payload — only expression-form or
/// single-return-statement bodies are eligible (the verifier's
/// pure-unfold rule covers exactly these shapes).
let private bodyForUnfold (fn: FunctionDecl) : string option =
    match fn.Body with
    | Some(FBExpr e) -> Some (renderExpr e)
    | Some(FBBlock blk) ->
        match blk.Statements with
        | [{ Kind = SReturn(Some e) }]
        | [{ Kind = SExpr e }] -> Some (renderExpr e)
        | _ -> None
    | None -> None

let private contractClauseStrings (cs: ContractClause list)
        : string list * string list =
    let req =
        cs |> List.choose (function
            | CCRequires(e, _) -> Some (renderExpr e)
            | _ -> None)
    let ens =
        cs |> List.choose (function
            | CCEnsures(e, _) -> Some (renderExpr e)
            | _ -> None)
    req, ens

let private declOf (it: Item) : ContractDecl option =
    let stab = stabilityStringOfItem it
    let mkDefault kind name repr =
        { Kind      = kind
          Name      = name
          Repr      = repr
          Pure      = false
          Stability = stab
          Requires  = []
          Ensures   = []
          Body      = None
          Params    = [] }
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
            let pureTok =
                if hasAnnotation "pure" fn.Annotations then "@pure " else ""
            let req, ens = contractClauseStrings fn.Contracts
            let contractsStr =
                let pieces =
                    (req |> List.map (fun s -> "requires: " + s))
                    @ (ens |> List.map (fun s -> "ensures: " + s))
                if List.isEmpty pieces then "" else " " + String.concat "; " pieces
            let repr =
                sprintf "%s%spub func %s%s(%s)%s%s"
                    pureTok asyncTok fn.Name (genericsRepr fn.Generics)
                    ps ret contractsStr
            let isPure = hasAnnotation "pure" fn.Annotations
            let body = if isPure then bodyForUnfold fn else None
            let paramsStruct =
                fn.Params
                |> List.map (fun p -> p.Name, renderTypeExpr p.Type)
            Some
                { Kind      = "func"
                  Name      = fn.Name
                  Repr      = repr
                  Pure      = isPure
                  Stability = stab
                  Requires  = req
                  Ensures   = ens
                  Body      = body
                  Params    = paramsStruct }
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
            Some (mkDefault "record" rd.Name repr)
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
            Some (mkDefault "union" ud.Name repr)
        | IEnum ed ->
            let cs =
                ed.Cases
                |> List.map (fun c -> "case " + c.Name)
                |> String.concat "; "
            let repr = sprintf "pub enum %s { %s }" ed.Name cs
            Some (mkDefault "enum" ed.Name repr)
        | IOpaque od ->
            Some (mkDefault "opaque" od.Name
                    (sprintf "pub opaque type %s%s" od.Name (genericsRepr od.Generics)))
        | IInterface id ->
            Some (mkDefault "interface" id.Name
                    (sprintf "pub interface %s%s" id.Name (genericsRepr id.Generics)))
        | IDistinctType d ->
            let derives =
                if List.isEmpty d.Derives then ""
                else " derives " + String.concat ", " d.Derives
            Some (mkDefault "distinct" d.Name
                    (sprintf "pub type %s = %s%s"
                        d.Name (renderTypeExpr d.Underlying) derives))
        | ITypeAlias ta ->
            Some (mkDefault "alias" ta.Name
                    (sprintf "pub type %s = %s"
                        ta.Name (renderTypeExpr ta.RHS)))
        | IConst c ->
            Some (mkDefault "const" c.Name
                    (sprintf "pub const %s: %s = ..." c.Name (renderTypeExpr c.Type)))
        | _ -> None

/// Resolve a source file's verification level into the canonical
/// string that goes into the contract's `level` field.
let private levelOfFile (sf: SourceFile) : string =
    let anns = sf.FileLevelAnnotations
    let findOne name =
        anns |> List.tryFind (fun a ->
            match a.Name.Segments with
            | [seg] -> seg = name
            | _     -> false)
    match findOne "axiom" with
    | Some _ -> "axiom"
    | None ->
        match findOne "proof_required" with
        | Some ann ->
            let modifier =
                ann.Args |> List.tryPick (fun arg ->
                    match arg with
                    | ABare(name, _) -> Some name
                    | _              -> None)
            match modifier with
            | Some "unsafe_blocks_allowed" ->
                "proof_required(unsafe_blocks_allowed)"
            | Some "checked_arithmetic" ->
                "proof_required(checked_arithmetic)"
            | _ -> "proof_required"
        | None ->
            match findOne "runtime_checked" with
            | Some _ -> "runtime_checked"
            | None   -> "runtime_checked"

/// Produce ContractDecls for any `pub use` imports in `sf`.
/// Each `pub use Pkg.{foo}` cherry-picks only the named pub items
/// from the matching imported source file; a bare `pub use Pkg`
/// re-exports all pub items from `Pkg`.
let private pubUseDecls
        (sf: SourceFile)
        (importedSources: Map<string, SourceFile>) : ContractDecl list =
    sf.Imports
    |> List.filter (fun imp -> imp.IsPubUse)
    |> List.collect (fun imp ->
        let pkgKey = String.concat "." imp.Path.Segments
        match Map.tryFind pkgKey importedSources with
        | None -> []
        | Some src ->
            let allowedNames : Set<string> option =
                match imp.Selector with
                | None -> None
                | Some (ISSingle item) -> Some (Set.singleton item.Name)
                | Some (ISGroup items) ->
                    Some (items |> List.map (fun i -> i.Name) |> Set.ofList)
            src.Items
            |> List.choose (fun it ->
                match declOf it with
                | None -> None
                | Some decl ->
                    match allowedNames with
                    | None -> Some decl
                    | Some names when Set.contains decl.Name names -> Some decl
                    | _ -> None))

/// Walk a `SourceFile` and produce the contract metadata for it.
/// `importedSources` maps package-name keys (e.g. `"Std.Core"`) to their
/// parsed source files; it is used to resolve `pub use` re-exports.
let buildContract
        (sf: SourceFile)
        (importedSources: Map<string, SourceFile>)
        (version: string) : Contract =
    let pkg = String.concat "." sf.Package.Path.Segments
    let ownDecls = sf.Items |> List.choose declOf
    let reexportDecls = pubUseDecls sf importedSources
    { PackageName   = pkg
      Version       = version
      Level         = levelOfFile sf
      FormatVersion = FORMAT_VERSION
      Decls         = ownDecls @ reexportDecls }

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

/// Render a string list as a JSON array of strings.
let private renderStringArray (xs: string list) : string =
    let sb = StringBuilder()
    sb.Append "[" |> ignore
    xs |> List.iteri (fun i s ->
        if i > 0 then sb.Append "," |> ignore
        sb.Append "\"" |> ignore
        sb.Append (escape s) |> ignore
        sb.Append "\"" |> ignore)
    sb.Append "]" |> ignore
    sb.ToString()

let private renderParams (ps: (string * string) list) : string =
    let sb = StringBuilder()
    sb.Append "[" |> ignore
    ps |> List.iteri (fun i (n, ty) ->
        if i > 0 then sb.Append "," |> ignore
        sb.Append (sprintf "{\"name\":\"%s\",\"type\":\"%s\"}"
                    (escape n) (escape ty)) |> ignore)
    sb.Append "]" |> ignore
    sb.ToString()

let private renderDecl (d: ContractDecl) : string =
    let sb = StringBuilder()
    sb.Append (sprintf "{\"kind\":\"%s\",\"name\":\"%s\",\"repr\":\"%s\""
                (escape d.Kind) (escape d.Name) (escape d.Repr))
        |> ignore
    if d.Stability <> "" then
        sb.Append (sprintf ",\"stability\":\"%s\"" (escape d.Stability)) |> ignore
    if d.Pure then
        sb.Append ",\"pure\":true" |> ignore
    if not (List.isEmpty d.Requires) then
        sb.Append (sprintf ",\"requires\":%s" (renderStringArray d.Requires))
            |> ignore
    if not (List.isEmpty d.Ensures) then
        sb.Append (sprintf ",\"ensures\":%s" (renderStringArray d.Ensures))
            |> ignore
    match d.Body with
    | Some body ->
        sb.Append (sprintf ",\"body\":\"%s\"" (escape body)) |> ignore
    | None -> ()
    if not (List.isEmpty d.Params) then
        sb.Append (sprintf ",\"params\":%s" (renderParams d.Params))
            |> ignore
    sb.Append "}" |> ignore
    sb.ToString()

/// Render a `Contract` as JSON.  Hand-rolled to avoid pulling in
/// System.Text.Json on every emit.  Format-2 (D-progress-086).
let toJson (c: Contract) : string =
    let sb = StringBuilder(1024)
    sb.Append "{\n" |> ignore
    sb.Append (sprintf "  \"formatVersion\": %d,\n" c.FormatVersion) |> ignore
    sb.Append (sprintf "  \"packageName\": \"%s\",\n" (escape c.PackageName)) |> ignore
    sb.Append (sprintf "  \"version\": \"%s\",\n" (escape c.Version)) |> ignore
    sb.Append (sprintf "  \"level\": \"%s\",\n" (escape c.Level)) |> ignore
    sb.Append "  \"decls\": [\n" |> ignore
    c.Decls
    |> List.iteri (fun i d ->
        let comma = if i = 0 then "" else ",\n"
        sb.Append comma |> ignore
        sb.Append "    " |> ignore
        sb.Append (renderDecl d) |> ignore)
    sb.Append "\n  ]\n}\n" |> ignore
    sb.ToString()

/// Embed a contract JSON as a managed resource named `resourceName`
/// on the assembly at `dllPath`.  Project-as-DLL uses
/// `Lyric.Contract.<Pkg>` (one per packaged); the legacy single-
/// package shape uses `Lyric.Contract` (no suffix) via
/// `embedIntoAssembly`.
let embedIntoAssemblyAs
        (dllPath: string)
        (resourceName: string)
        (json: string) : unit =
    let assembly =
        Mono.Cecil.AssemblyDefinition.ReadAssembly(
            dllPath,
            Mono.Cecil.ReaderParameters(InMemory = true))
    let mainModule = assembly.MainModule
    // Drop any pre-existing same-name resource so re-embeds are
    // idempotent.
    let toDelete =
        mainModule.Resources
        |> Seq.filter (fun r -> r.Name = resourceName)
        |> Seq.toList
    for r in toDelete do
        mainModule.Resources.Remove r |> ignore
    let bytes = Encoding.UTF8.GetBytes json
    let resource =
        Mono.Cecil.EmbeddedResource(
            resourceName,
            Mono.Cecil.ManifestResourceAttributes.Public,
            bytes)
    mainModule.Resources.Add(resource)
    let tmp = dllPath + ".tmp"
    assembly.Write(tmp)
    File.Move(tmp, dllPath, overwrite = true)

/// Embed `Lyric.Contract` as a managed resource on the assembly at
/// `dllPath`.  Uses Mono.Cecil to manipulate the resource table —
/// `PersistedAssemblyBuilder` doesn't expose
/// `DefineManifestResource` so post-processing is the simplest path.
/// Idempotent: re-embedding overwrites any prior `Lyric.Contract`
/// resource.  Single-package shape; multi-package projects (`output =
/// "single"`) use `embedIntoAssemblyAs` with a per-package resource
/// name.
let embedIntoAssembly (dllPath: string) (json: string) : unit =
    embedIntoAssemblyAs dllPath "Lyric.Contract" json

/// Read the embedded `Lyric.Contract` resource (or any
/// `Lyric.Contract.<Pkg>` per-package variant in project-as-DLL
/// bundled assemblies) from a `.dll` and return its JSON payload.
let readFromAssemblyNamed
        (dllPath: string) (resourceName: string) : string option =
    let assembly =
        Mono.Cecil.AssemblyDefinition.ReadAssembly(
            dllPath,
            Mono.Cecil.ReaderParameters(InMemory = true))
    let resource =
        assembly.MainModule.Resources
        |> Seq.tryFind (fun r -> r.Name = resourceName)
    match resource with
    | Some r ->
        match r with
        | :? Mono.Cecil.EmbeddedResource as er ->
            Some (Encoding.UTF8.GetString(er.GetResourceData()))
        | _ -> None
    | None -> None

/// Read the embedded `Lyric.Contract` resource from a .dll and
/// return its JSON payload.  Returns `None` when the resource isn't
/// present (e.g. a non-Lyric assembly, or an older Lyric build).
/// For project-as-DLL bundled assemblies (`output = "single"`),
/// `readAllContractsFromAssembly` returns every `Lyric.Contract.<Pkg>`
/// resource keyed by package name.
let readFromAssembly (dllPath: string) : string option =
    readFromAssemblyNamed dllPath "Lyric.Contract"

/// Walk every `Lyric.Contract` / `Lyric.Contract.<Pkg>` resource in
/// the bundled DLL and return them keyed by package name.  Single-
/// package assemblies surface as `[("", json)]`; project-as-DLL
/// bundles surface as one entry per package
/// (`[("MyApp.Core", core-json); ("MyApp.Db", db-json); …]`).
let readAllContractsFromAssembly
        (dllPath: string) : (string * string) list =
    let assembly =
        Mono.Cecil.AssemblyDefinition.ReadAssembly(
            dllPath,
            Mono.Cecil.ReaderParameters(InMemory = true))
    let prefix = "Lyric.Contract"
    assembly.MainModule.Resources
    |> Seq.choose (fun r ->
        if r.Name = prefix then
            match r with
            | :? Mono.Cecil.EmbeddedResource as er ->
                Some ("", Encoding.UTF8.GetString(er.GetResourceData()))
            | _ -> None
        elif r.Name.StartsWith(prefix + ".") then
            match r with
            | :? Mono.Cecil.EmbeddedResource as er ->
                let pkg = r.Name.Substring(prefix.Length + 1)
                Some (pkg, Encoding.UTF8.GetString(er.GetResourceData()))
            | _ -> None
        else None)
    |> List.ofSeq

/// Parse the JSON payload back to a `Contract` value.  Uses
/// `System.Text.Json` for robustness against future format
/// additions.  Format-1 payloads (no `formatVersion`, no `level`,
/// no per-decl `pure`/`requires`/`ensures`/`body`/`params`) parse
/// with safe defaults: `runtime_checked` level, all decls non-pure,
/// no clauses, no body, no params.
let parseFromJson (json: string) : Contract option =
    try
        use doc = System.Text.Json.JsonDocument.Parse(json)
        let root = doc.RootElement
        let safeStr (s: string | null) (fallback: string) : string =
            match Option.ofObj s with
            | Some v -> v
            | None   -> fallback
        let getStr name fallback =
            match root.TryGetProperty(name: string) with
            | true, e -> safeStr (e.GetString()) fallback
            | _ -> fallback
        let getStrInElem (el: System.Text.Json.JsonElement) name fallback =
            match el.TryGetProperty(name: string) with
            | true, e -> safeStr (e.GetString()) fallback
            | _ -> fallback
        let getStrArrayInElem (el: System.Text.Json.JsonElement) name : string list =
            match el.TryGetProperty(name: string) with
            | true, arr when arr.ValueKind = System.Text.Json.JsonValueKind.Array ->
                [ for inner in arr.EnumerateArray() do
                    yield safeStr (inner.GetString()) "" ]
            | _ -> []
        let getOptStrInElem (el: System.Text.Json.JsonElement) name : string option =
            match el.TryGetProperty(name: string) with
            | true, e -> Option.ofObj (e.GetString())
            | _ -> None
        let getBoolInElem (el: System.Text.Json.JsonElement) name : bool =
            match el.TryGetProperty(name: string) with
            | true, e -> e.ValueKind = System.Text.Json.JsonValueKind.True
            | _ -> false
        let getParamsInElem (el: System.Text.Json.JsonElement) : (string * string) list =
            match el.TryGetProperty("params") with
            | true, arr when arr.ValueKind = System.Text.Json.JsonValueKind.Array ->
                [ for inner in arr.EnumerateArray() do
                    let n = getStrInElem inner "name" ""
                    let t = getStrInElem inner "type" ""
                    yield n, t ]
            | _ -> []
        let formatVersion =
            match root.TryGetProperty("formatVersion") with
            | true, e ->
                match e.ValueKind with
                | System.Text.Json.JsonValueKind.Number ->
                    e.GetInt32()
                | _ -> 1
            | _ -> 1
        let pkgStr = getStr "packageName" ""
        let verStr = getStr "version" "0.0.0"
        let level  = getStr "level" "runtime_checked"
        let decls =
            match root.TryGetProperty("decls") with
            | true, arr when arr.ValueKind = System.Text.Json.JsonValueKind.Array ->
                [ for el in arr.EnumerateArray() do
                    let kind     = getStrInElem el "kind" ""
                    let name     = getStrInElem el "name" ""
                    let repr     = getStrInElem el "repr" ""
                    let pure'    = getBoolInElem el "pure"
                    let stab     = getStrInElem el "stability" ""
                    let reqs     = getStrArrayInElem el "requires"
                    let ens      = getStrArrayInElem el "ensures"
                    let body     = getOptStrInElem el "body"
                    let parms    = getParamsInElem el
                    yield
                        { Kind      = kind
                          Name      = name
                          Repr      = repr
                          Pure      = pure'
                          Stability = stab
                          Requires  = reqs
                          Ensures   = ens
                          Body      = body
                          Params    = parms } ]
            | _ -> []
        Some
            { PackageName   = pkgStr
              Version       = verStr
              Level         = level
              FormatVersion = formatVersion
              Decls         = decls }
    with _ -> None

/// Diff result for `lyric public-api-diff`.  Each variant carries
/// enough info to render a human-readable line.  Removed/changed
/// entries are SemVer-major-bump-worthy; Added entries are minor-
/// bump-worthy.
///
/// `DiffContractChanged` fires when the signature is unchanged but the
/// requires/ensures clauses differ in a semantically breaking way:
///   * StrengthenedRequires — new adds preconditions callers must satisfy.
///   * WeakenedEnsures      — new removes postconditions callees relied on.
type ContractBreakKind =
    | StrengthenedRequires of added: string list
    | WeakenedEnsures      of removed: string list

type ContractDiffEntry =
    | DiffAdded           of ContractDecl
    | DiffRemoved         of ContractDecl
    | DiffChanged         of oldDecl: ContractDecl * newDecl: ContractDecl
    | DiffContractChanged of decl: ContractDecl * breaks: ContractBreakKind list

let private declKey (d: ContractDecl) = (d.Kind, d.Name)

/// Detect contract-clause breaking changes between two same-named function
/// declarations.  Returns `Some` with the list of break kinds when at
/// least one breaking change is detected; `None` when contracts are
/// compatible.
let private contractBreaks (o: ContractDecl) (n: ContractDecl) : ContractBreakKind list =
    let oldReqs = Set.ofList o.Requires
    let newReqs = Set.ofList n.Requires
    let oldEns  = Set.ofList o.Ensures
    let newEns  = Set.ofList n.Ensures
    let addedReqs   = Set.difference newReqs oldReqs |> Set.toList
    let removedEns  = Set.difference oldEns  newEns  |> Set.toList
    [ if not (List.isEmpty addedReqs)  then yield StrengthenedRequires addedReqs
      if not (List.isEmpty removedEns) then yield WeakenedEnsures removedEns ]

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
        | Some o, Some n ->
            // Same signature — check contract clauses.
            let breaks = contractBreaks o n
            if not (List.isEmpty breaks) then
                yield DiffContractChanged (n, breaks)
        | None, Some n -> yield DiffAdded n
        | Some o, None -> yield DiffRemoved o
        | None, None -> () ]
    |> List.sortBy (fun entry ->
        let kind, name =
            match entry with
            | DiffAdded d -> 0, declKey d
            | DiffRemoved d -> 1, declKey d
            | DiffChanged (o, _) -> 2, declKey o
            | DiffContractChanged (d, _) -> 3, declKey d
        (kind, name))

/// Returns true when the diff contains breaking changes to *stable*
/// surface (Removed or Changed on a non-experimental item).
///
/// Removing or changing an `@experimental` item is a no-op SemVer-
/// wise — experimental surface carries no stability guarantee.
/// Added-only diffs (any stability) are a SemVer minor bump.
let hasBreakingChanges (entries: ContractDiffEntry list) : bool =
    entries
    |> List.exists (function
        | DiffAdded _ -> false
        | DiffRemoved d -> d.Stability <> "experimental"
        | DiffChanged(o, _) -> o.Stability <> "experimental"
        | DiffContractChanged(d, _) -> d.Stability <> "experimental")

/// Render a single diff entry as a human-readable line.
let renderDiffEntry (entry: ContractDiffEntry) : string =
    let stabTag (d: ContractDecl) =
        match d.Stability with
        | "experimental" -> " [experimental]"
        | s when s.StartsWith("stable:") ->
            sprintf " [stable since %s]" (s.Substring(7))
        | _ -> ""
    match entry with
    | DiffAdded d ->
        sprintf "  + %s %s%s : %s" d.Kind d.Name (stabTag d) d.Repr
    | DiffRemoved d ->
        sprintf "  - %s %s%s : %s" d.Kind d.Name (stabTag d) d.Repr
    | DiffChanged (o, n) ->
        sprintf "  ~ %s %s%s\n      old: %s\n      new: %s"
            o.Kind o.Name (stabTag o) o.Repr n.Repr
    | DiffContractChanged (d, breaks) ->
        let breakLines =
            breaks |> List.map (function
                | StrengthenedRequires added ->
                    sprintf "      [breaking] strengthened requires: %s"
                        (added |> List.map (sprintf "\"%s\"") |> String.concat ", ")
                | WeakenedEnsures removed ->
                    sprintf "      [breaking] weakened ensures: %s"
                        (removed |> List.map (sprintf "\"%s\"") |> String.concat ", "))
            |> String.concat "\n"
        sprintf "  ! %s %s%s (contract change)\n%s"
            d.Kind d.Name (stabTag d) breakLines
