/// Public entry point: `check` a parsed `SourceFile` against an
/// optional set of pre-populated symbols (used by the smoke test to
/// register `Option`, `Result`, `slice`, etc. without having a stdlib
/// available yet) and return the diagnostics produced.
module Lyric.TypeChecker.Checker

open Lyric.Lexer
open Lyric.Parser.Parser
open Lyric.Parser.Ast
open Lyric.TypeChecker
open Lyric.TypeChecker.Symbols

type CheckResult =
    { Diagnostics: Diagnostic list }

let private syntheticSpan = Span.pointAt Position.initial

let private packagePath (sf: SourceFile) : string list =
    sf.Package.Path.Segments

/// Pre-register type names with empty bodies so Resolver lookups inside
/// recursive declarations (e.g. `union Tree { case Node(l: Tree[K], …) }`)
/// can resolve self-references to a fully-qualified `TyNamed`. The
/// real bodies are filled in by `registerTypeSymbols`.
let private preRegisterTypeNames
        (st: SymbolTable)
        (pkg: string list)
        (sf: SourceFile) : unit =
    let qualify (name: string) = pkg @ [name]
    let placeholder name span generics =
        SymbolTable.addType st
            { Name      = qualify name
              ShortName = name
              Generics  = generics
              Kind      = TskOpaque
              DeclSpan  = span }
    let genNames (gp: GenericParams option) =
        match gp with
        | None -> []
        | Some gps ->
            gps.Params
            |> List.choose (fun p ->
                match p with
                | GPType (n, _) -> Some n
                | _             -> None)
    for item in sf.Items do
        match item.Kind with
        | IRecord r | IExposedRec r -> placeholder r.Name r.Span (genNames r.Generics)
        | IUnion u                  -> placeholder u.Name u.Span (genNames u.Generics)
        | IEnum e                   -> placeholder e.Name e.Span []
        | IOpaque o                 -> placeholder o.Name o.Span (genNames o.Generics)
        | ITypeAlias a              -> placeholder a.Name a.Span (genNames a.Generics)
        | IDistinctType d           -> placeholder d.Name d.Span (genNames d.Generics)
        | IInterface i              -> placeholder i.Name i.Span (genNames i.Generics)
        | IExtern ep ->
            for m in ep.Members do
                match m with
                | EMRecord r | EMExposedRec r ->
                    SymbolTable.addType st
                        { Name      = ep.Path.Segments @ [r.Name]
                          ShortName = r.Name
                          Generics  = []
                          Kind      = TskOpaque
                          DeclSpan  = r.Span }
                | EMOpaque o ->
                    SymbolTable.addType st
                        { Name      = ep.Path.Segments @ [o.Name]
                          ShortName = o.Name
                          Generics  = []
                          Kind      = TskOpaque
                          DeclSpan  = o.Span }
                | EMUnion u ->
                    SymbolTable.addType st
                        { Name      = ep.Path.Segments @ [u.Name]
                          ShortName = u.Name
                          Generics  = []
                          Kind      = TskOpaque
                          DeclSpan  = u.Span }
                | EMEnum e ->
                    SymbolTable.addType st
                        { Name      = ep.Path.Segments @ [e.Name]
                          ShortName = e.Name
                          Generics  = []
                          Kind      = TskOpaque
                          DeclSpan  = e.Span }
                | _ -> ()
        | _ -> ()

/// Walk the source file and add every top-level type declaration to
/// the symbol table. Bodies are added as best-effort shapes (record
/// fields, union cases, enum cases) so the resolver can answer
/// member-access questions.
let private registerTypeSymbols
        (st: SymbolTable)
        (env: CheckEnv)
        (pkg: string list)
        (sf: SourceFile) : unit =
    let qualify (name: string) = pkg @ [name]
    for item in sf.Items do
        match item.Kind with
        | IRecord r | IExposedRec r ->
            let fields =
                r.Members
                |> List.choose (fun m ->
                    match m with
                    | RMField f -> Some (f.Name, Resolver.resolve env f.Type)
                    | RMInvariant _ -> None)
            let kind =
                match item.Kind with
                | IExposedRec _ -> TskExposedRec fields
                | _             -> TskRecord fields
            let qn = qualify r.Name
            SymbolTable.addType st
                { Name      = qn
                  ShortName = r.Name
                  Generics  =
                    match r.Generics with
                    | None -> []
                    | Some gp ->
                        gp.Params
                        |> List.choose (fun p ->
                            match p with
                            | GPType (n, _) -> Some n
                            | _             -> None)
                  Kind     = kind
                  DeclSpan = r.Span }
        | IUnion u ->
            let cases =
                u.Cases
                |> List.map (fun c ->
                    let fields =
                        c.Fields
                        |> List.map (fun f ->
                            match f with
                            | UFNamed (n, t, _) -> (Some n, Resolver.resolve env t)
                            | UFPos   (t, _)    -> (None,   Resolver.resolve env t))
                    (c.Name, fields))
            let qn = qualify u.Name
            SymbolTable.addType st
                { Name      = qn
                  ShortName = u.Name
                  Generics  =
                    match u.Generics with
                    | None -> []
                    | Some gp ->
                        gp.Params
                        |> List.choose (fun p ->
                            match p with
                            | GPType (n, _) -> Some n
                            | _             -> None)
                  Kind     = TskUnion cases
                  DeclSpan = u.Span }
            // Each union case becomes a value (constructor or
            // nullary constant).
            for (caseName, fields) in cases do
                SymbolTable.addValue st
                    { Name      = qualify caseName
                      ShortName = caseName
                      Kind      = VskUnionCase (qn, fields)
                      DeclSpan  = u.Span }
        | IEnum e ->
            let qn = qualify e.Name
            let names = e.Cases |> List.map (fun c -> c.Name)
            SymbolTable.addType st
                { Name      = qn
                  ShortName = e.Name
                  Generics  = []
                  Kind      = TskEnum names
                  DeclSpan  = e.Span }
            for c in e.Cases do
                SymbolTable.addValue st
                    { Name      = qualify c.Name
                      ShortName = c.Name
                      Kind      = VskEnumCase qn
                      DeclSpan  = c.Span }
        | IOpaque o ->
            let qn = qualify o.Name
            SymbolTable.addType st
                { Name      = qn
                  ShortName = o.Name
                  Generics  =
                    match o.Generics with
                    | None -> []
                    | Some gp ->
                        gp.Params
                        |> List.choose (fun p ->
                            match p with
                            | GPType (n, _) -> Some n
                            | _             -> None)
                  Kind     = TskOpaque
                  DeclSpan = o.Span }
        | ITypeAlias a ->
            let qn = qualify a.Name
            // Resolve underlying lazily; keep TyError if it depends
            // on a not-yet-registered symbol.
            let underlying = Resolver.resolve env a.RHS
            SymbolTable.addType st
                { Name      = qn
                  ShortName = a.Name
                  Generics  =
                    match a.Generics with
                    | None -> []
                    | Some gp ->
                        gp.Params
                        |> List.choose (fun p ->
                            match p with
                            | GPType (n, _) -> Some n
                            | _             -> None)
                  Kind     = TskAlias underlying
                  DeclSpan = a.Span }
        | IDistinctType d ->
            let qn = qualify d.Name
            let underlying = Resolver.resolve env d.Underlying
            SymbolTable.addType st
                { Name      = qn
                  ShortName = d.Name
                  Generics  =
                    match d.Generics with
                    | None -> []
                    | Some gp ->
                        gp.Params
                        |> List.choose (fun p ->
                            match p with
                            | GPType (n, _) -> Some n
                            | _             -> None)
                  Kind     = TskDistinct underlying
                  DeclSpan = d.Span }
        | IInterface i ->
            // Methods get registered as a flat (name, sig) list.
            // Default-method bodies are still type-checked in the
            // body pass; here we just register the signature.
            let methods =
                i.Members
                |> List.choose (fun m ->
                    match m with
                    | IMSig fs ->
                        let rs = Signature.resolveFunctionSig env fs
                        Some (fs.Name, rs)
                    | IMFunc fd ->
                        let rs = Signature.resolveFunction env fd
                        Some (fd.Name, rs)
                    | IMAssoc _ -> None)
            let qn = qualify i.Name
            SymbolTable.addType st
                { Name      = qn
                  ShortName = i.Name
                  Generics  =
                    match i.Generics with
                    | None -> []
                    | Some gp ->
                        gp.Params
                        |> List.choose (fun p ->
                            match p with
                            | GPType (n, _) -> Some n
                            | _             -> None)
                  Kind     = TskInterface methods
                  DeclSpan = i.Span }
        | IExtern ep ->
            for m in ep.Members do
                match m with
                | EMRecord r | EMExposedRec r ->
                    let qn = ep.Path.Segments @ [r.Name]
                    SymbolTable.addType st
                        { Name      = qn
                          ShortName = r.Name
                          Generics  = []
                          Kind      = TskExtern
                          DeclSpan  = r.Span }
                | EMOpaque o ->
                    let qn = ep.Path.Segments @ [o.Name]
                    SymbolTable.addType st
                        { Name      = qn
                          ShortName = o.Name
                          Generics  = []
                          Kind      = TskOpaque
                          DeclSpan  = o.Span }
                | EMUnion u ->
                    let qn = ep.Path.Segments @ [u.Name]
                    SymbolTable.addType st
                        { Name      = qn
                          ShortName = u.Name
                          Generics  = []
                          Kind      = TskUnion []
                          DeclSpan  = u.Span }
                | EMEnum e ->
                    let qn = ep.Path.Segments @ [e.Name]
                    SymbolTable.addType st
                        { Name      = qn
                          ShortName = e.Name
                          Generics  = []
                          Kind      = TskEnum (e.Cases |> List.map (fun c -> c.Name))
                          DeclSpan  = e.Span }
                | _ -> ()
        | _ -> ()

let private registerValueSymbols
        (st: SymbolTable)
        (env: CheckEnv)
        (pkg: string list)
        (sf: SourceFile) : unit =
    let qualify (name: string) = pkg @ [name]
    for item in sf.Items do
        match item.Kind with
        | IFunc fd ->
            let rs = Signature.resolveFunction env fd
            SymbolTable.addValue st
                { Name      = qualify fd.Name
                  ShortName = fd.Name
                  Kind      = VskFunc rs
                  DeclSpan  = fd.Span }
        | IConst c ->
            let t = Resolver.resolve env c.Type
            SymbolTable.addValue st
                { Name      = qualify c.Name
                  ShortName = c.Name
                  Kind      = VskConst t
                  DeclSpan  = c.Span }
        | IVal v ->
            let t =
                match v.Type with
                | Some t -> Resolver.resolve env t
                | None   -> ExprChecker.inferExpr env v.Init
            // Bind each name in the pattern.
            let rec bind p =
                match (p: Pattern).Kind with
                | PBinding (n, innerOpt) ->
                    SymbolTable.addValue st
                        { Name      = qualify n
                          ShortName = n
                          Kind      = VskVal t
                          DeclSpan  = p.Span }
                    match innerOpt with
                    | Some inner -> bind inner
                    | None -> ()
                | _ -> ()
            bind v.Pattern
        | IExtern ep ->
            for m in ep.Members do
                match m with
                | EMSig fs ->
                    let rs = Signature.resolveFunctionSig env fs
                    let qn = ep.Path.Segments @ [fs.Name]
                    SymbolTable.addValue st
                        { Name      = qn
                          ShortName = fs.Name
                          Kind      = VskFunc rs
                          DeclSpan  = fs.Span }
                | _ -> ()
        | _ -> ()

let private registerImportAliases (st: SymbolTable) (sf: SourceFile) : unit =
    for imp in sf.Imports do
        match imp.Selector, imp.Alias with
        | None, Some a ->
            SymbolTable.addAlias st a imp.Path.Segments
        | None, None ->
            let last = List.last imp.Path.Segments
            SymbolTable.addAlias st last imp.Path.Segments
        | Some (ISSingle item), _ ->
            let alias = defaultArg item.Alias item.Name
            SymbolTable.addAlias st alias (imp.Path.Segments @ [item.Name])
        | Some (ISGroup items), _ ->
            for item in items do
                let alias = defaultArg item.Alias item.Name
                SymbolTable.addAlias st alias (imp.Path.Segments @ [item.Name])

let private checkBodies (env: CheckEnv) (sf: SourceFile) : unit =
    for item in sf.Items do
        match item.Kind with
        | IFunc fd ->
            let rs = Signature.resolveFunction env fd
            let saved = env.Generics
            let env' =
                { env with Generics = GenericContext.union saved (GenericContext.make rs.Generics) }
            // Mutate-friendly shim: copy the in-place fields back so
            // Return / SelfTy stay consistent across the call.
            env'.Return <- env.Return
            env'.SelfTy <- env.SelfTy
            StmtChecker.checkFunctionBody env' fd rs
        | IImpl impl ->
            // Validate impl-method bodies against the interface
            // sig, with `self` bound to the impl target.
            let targetTy = Resolver.resolve env impl.Target
            let savedSelf = env.SelfTy
            env.SelfTy <- Some targetTy
            for m in impl.Members do
                match m with
                | IMplFunc fd ->
                    let rs = Signature.resolveFunction env fd
                    StmtChecker.checkFunctionBody env fd rs
                | IMplAssoc _ -> ()
            env.SelfTy <- savedSelf
        | ITest t ->
            CheckEnv.pushScope env
            for stmt in t.Body.Statements do
                StmtChecker.checkStatement env stmt
            CheckEnv.popScope env
        | _ -> ()

/// Pre-register a handful of stdlib-shaped symbols so the worked
/// examples that mention `Option`, `Result`, `Task`, `slice`, etc.
/// don't drown in `unknown name` errors. This is a stop-gap until
/// `std.core` lands in Lyric.
let private installPrelude (st: SymbolTable) : unit =
    let addType name generics kind =
        SymbolTable.addType st
            { Name      = [name]
              ShortName = name
              Generics  = generics
              Kind      = kind
              DeclSpan  = syntheticSpan }
    let addValue name kind =
        SymbolTable.addValue st
            { Name      = [name]
              ShortName = name
              Kind      = kind
              DeclSpan  = syntheticSpan }

    // Sum/option types.
    addType "Option" ["A"]
        (TskUnion
            [ "Some", [None, Type.TyVar "A"]
              "None", [] ])
    addType "Result" ["A"; "B"]
        (TskUnion
            [ "Ok",  [None, Type.TyVar "A"]
              "Err", [None, Type.TyVar "B"] ])

    // Container shells; Phase 1 won't validate methods, but the
    // names need to resolve.
    addType "Task"   ["A"] TskOpaque
    addType "List"   ["A"] TskOpaque
    addType "Map"    ["K"; "V"] TskOpaque
    addType "Set"    ["A"] TskOpaque
    addType "Iter"   ["A"] TskOpaque
    addType "Seq"    ["A"] TskOpaque

    // Prelude value symbols — case constructors.
    addValue "None" (VskUnionCase (["Option"], []))
    addValue "Some" (VskUnionCase (["Option"], [None, Type.TyVar "A"]))
    addValue "Ok"   (VskUnionCase (["Result"], [None, Type.TyVar "A"]))
    addValue "Err"  (VskUnionCase (["Result"], [None, Type.TyVar "B"]))

    // Free-standing helper functions used pervasively across the
    // worked examples. Phase 1 ignores their actual signatures —
    // every parameter is `TyError` (which `Type.compatible` accepts
    // against anything) so call-sites still pass argument-arity
    // checks.
    let polymorphicSig (n: int) =
        { Generics = []
          Params   = List.replicate n Type.TyError
          Return   = Type.TyError }
    for name, arity in
        [ "println", 1
          "print",   1
          "expect",  1
          "assert",  1
          "fail",    1
          "todo",    0
          "ignore",  1
          "debug",   1
          "log",     1
          "panic",   1 ] do
        addValue name (VskFunc (polymorphicSig arity))

/// Run the full type-checking pipeline against a parsed source file
/// and previously-collected parser diagnostics.
let check (parserDiags: Diagnostic list) (sf: SourceFile) : CheckResult =
    let st = SymbolTable.make ()
    let diagBuf = System.Collections.Generic.List<Diagnostic>(parserDiags)
    let env = CheckEnv.make st diagBuf

    installPrelude st
    registerImportAliases st sf

    let pkg = packagePath sf

    // Pass 0: pre-register type names so recursive declarations can
    // resolve self-references (`union Tree { case Node(l: Tree[K]) }`).
    preRegisterTypeNames st pkg sf
    // Pass 1: type symbols — fields, cases, methods now resolve
    // against the pre-registered names.
    registerTypeSymbols st env pkg sf
    // Pass 2: function/value signatures. `func id[T](x: T): T` and
    // top-level `val`/`const` declarations.
    registerValueSymbols st env pkg sf
    // Pass 3: bodies. Locals are added/removed from a scope stack
    // in `CheckEnv` via push/pop.
    checkBodies env sf

    { Diagnostics = List.ofSeq diagBuf }

/// Parse-and-check convenience for tests.
let checkSource (source: string) : CheckResult =
    let pr = parse source
    check pr.Diagnostics pr.File
