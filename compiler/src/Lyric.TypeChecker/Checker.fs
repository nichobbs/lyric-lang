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
    let add name (kind: TypeSymbolKind) =
        SymbolTable.addType st
            { Name      = [name]
              ShortName = name
              Generics  = ["A"]
              Kind      = kind
              DeclSpan  = syntheticSpan }
    add "Option"
        (TskUnion
            [ "Some", [None, Type.TyVar "A"]
              "None", [] ])
    add "Result"
        (TskUnion
            [ "Ok",  [None, Type.TyVar "A"]
              "Err", [None, Type.TyVar "B"] ])
    SymbolTable.addType st
        { Name      = ["Result"]
          ShortName = "Result"
          Generics  = ["A"; "B"]
          Kind      = TskUnion
            [ "Ok",  [None, Type.TyVar "A"]
              "Err", [None, Type.TyVar "B"] ]
          DeclSpan  = syntheticSpan }
    SymbolTable.addType st
        { Name      = ["Task"]
          ShortName = "Task"
          Generics  = ["A"]
          Kind      = TskOpaque
          DeclSpan  = syntheticSpan }
    // Prelude value symbols — `None`, `Some`, `Ok`, `Err` so they
    // resolve as bare identifiers in expression position.
    SymbolTable.addValue st
        { Name      = ["None"]
          ShortName = "None"
          Kind      = VskUnionCase (["Option"], [])
          DeclSpan  = syntheticSpan }
    SymbolTable.addValue st
        { Name      = ["Some"]
          ShortName = "Some"
          Kind      = VskUnionCase (["Option"], [None, Type.TyVar "A"])
          DeclSpan  = syntheticSpan }
    SymbolTable.addValue st
        { Name      = ["Ok"]
          ShortName = "Ok"
          Kind      = VskUnionCase (["Result"], [None, Type.TyVar "A"])
          DeclSpan  = syntheticSpan }
    SymbolTable.addValue st
        { Name      = ["Err"]
          ShortName = "Err"
          Kind      = VskUnionCase (["Result"], [None, Type.TyVar "B"])
          DeclSpan  = syntheticSpan }

/// Run the full type-checking pipeline against a parsed source file
/// and previously-collected parser diagnostics.
let check (parserDiags: Diagnostic list) (sf: SourceFile) : CheckResult =
    let st = SymbolTable.make ()
    let diagBuf = System.Collections.Generic.List<Diagnostic>(parserDiags)
    let env = CheckEnv.make st diagBuf

    installPrelude st
    registerImportAliases st sf

    let pkg = packagePath sf

    // Pass 1: type symbols (so they're available when resolving
    // function signatures).
    registerTypeSymbols st env pkg sf
    // Pass 2: function/value signatures (resolve types using the
    // type table). This is also where we discover errors in
    // signatures.
    registerValueSymbols st env pkg sf
    // Pass 3: bodies. Locals are added/removed from a scope stack
    // in `CheckEnv` via push/pop.
    checkBodies env sf

    { Diagnostics = List.ofSeq diagBuf }

/// Parse-and-check convenience for tests.
let checkSource (source: string) : CheckResult =
    let pr = parse source
    check pr.Diagnostics pr.File
