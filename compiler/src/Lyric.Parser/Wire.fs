/// AST-level synthesis for `wire { ... }` blocks (C6 / Tier 2.1).
///
/// The bootstrap-grade lowering covers `singleton` + `@provided` +
/// `expose` plus multi-wire support; scoped lifetimes and the
/// lifetime checker (rejecting singleton-depends-on-scoped) are
/// deferred per the C6 decision in `docs/12-todo-plan.md`.
///
/// For
///
///   wire ProductionWire {
///     @provided dbConn: String
///     singleton clock: Clock = SystemClock.make()
///     singleton svc: TransferService =
///       TransferService.make(dbConn, clock)
///     expose svc
///   }
///
/// the synthesiser appends two items to the source file:
///
///   pub record ProductionWire { pub svc: TransferService }
///   func ProductionWire.bootstrap(dbConn: in String): ProductionWire {
///     val clock = SystemClock.make()
///     val svc   = TransferService.make(dbConn, clock)
///     ProductionWire(svc = svc)
///   }
///
/// Singletons get topologically sorted by inspecting their `init`
/// expressions for references to other singleton / `@provided`
/// names; cycles surface as a P0260 wire-cycle diagnostic.  The
/// resulting program looks just like a hand-written record + factory,
/// so subsequent passes (type checker, emitter) need zero awareness
/// of the wire shape.
module Lyric.Parser.Wire

open System.Collections.Generic
open Lyric.Lexer
open Lyric.Parser.Ast

let private err (diags: ResizeArray<Diagnostic>) code msg span =
    diags.Add(Diagnostic.error code msg span)

/// Collect direct references to other names from an init expression.
/// Walks every `EPath { Segments = [name] }` it reaches; deeper paths
/// (`Foo.bar`, `Module.member`) reference an external symbol and don't
/// participate in wire ordering.
let private referencedNames (e: Expr) : Set<string> =
    let acc = HashSet<string>()
    let rec walk (e: Expr) =
        match e.Kind with
        | EPath p ->
            match p.Segments with
            | [name] -> acc.Add name |> ignore
            | _ -> ()
        | EParen inner -> walk inner
        | ETuple xs | EList xs -> for x in xs do walk x
        | EIf (c, t, el, _) ->
            walk c
            walkExprOrBlock t
            el |> Option.iter walkExprOrBlock
        | EMatch (sc, arms) ->
            walk sc
            for arm in arms do walkExprOrBlock arm.Body
        | EAwait inner | ESpawn inner | ETry inner | EOld inner -> walk inner
        | EForall (_, w, body) | EExists (_, w, body) ->
            w |> Option.iter walk
            walk body
        | ELambda (_, body) -> walkBlock body
        | ECall (fn, args) ->
            walk fn
            for a in args do
                match a with
                | CAPositional ex | CANamed (_, ex, _) -> walk ex
        | ETypeApp (fn, _) -> walk fn
        | EIndex (recv, idxs) ->
            walk recv
            for i in idxs do walk i
        | EMember (recv, _) -> walk recv
        | EPropagate inner -> walk inner
        | EPrefix (_, x) -> walk x
        | EBinop (_, l, r) -> walk l; walk r
        | EAssign (t, _, v) -> walk t; walk v
        | EBlock blk -> walkBlock blk
        | EInterpolated segs ->
            for s in segs do
                match s with
                | ISText _ -> ()
                | ISExpr ex -> walk ex
        | _ -> ()
    and walkExprOrBlock (eob: ExprOrBlock) =
        match eob with
        | EOBExpr e  -> walk e
        | EOBBlock b -> walkBlock b
    and walkBlock (b: Block) =
        for s in b.Statements do
            match s.Kind with
            | SExpr e -> walk e
            | SAssign (t, _, v) -> walk t; walk v
            | SLocal (LBVal (_, _, init))
            | SLocal (LBLet (_, _, init)) -> walk init
            | SLocal (LBVar (_, _, Some init)) -> walk init
            | SReturn (Some e) -> walk e
            | _ -> ()
    walk e
    Set.ofSeq acc

/// Topologically sort the singletons by their cross-references.
/// Returns the sorted name list.  Cycles emit P0260 and the singletons
/// are emitted in declaration order (the type checker / emitter will
/// surface a clearer error downstream).
let private topoSortSingletons
        (diags: ResizeArray<Diagnostic>)
        (wireName: string)
        (wireSpan: Span)
        (singletons: (string * Set<string>) list) : string list =
    let providedAndSingletonNames =
        singletons |> List.map fst |> Set.ofList
    let depMap =
        singletons
        |> List.map (fun (name, deps) ->
            // Only edges to other declared names matter; references to
            // out-of-wire symbols are external and don't constrain
            // ordering.
            name, Set.intersect deps providedAndSingletonNames |> Set.remove name)
        |> Map.ofList
    let result = ResizeArray<string>()
    let permanent = HashSet<string>()
    let temporary = HashSet<string>()
    let mutable cycleReported = false
    let rec visit (n: string) =
        if permanent.Contains n then ()
        elif temporary.Contains n then
            if not cycleReported then
                err diags "P0260"
                    (sprintf "wire '%s' has a singleton dependency cycle through '%s'"
                        wireName n)
                    wireSpan
                cycleReported <- true
        else
            temporary.Add n |> ignore
            match Map.tryFind n depMap with
            | Some deps -> for d in deps do visit d
            | None -> ()
            temporary.Remove n |> ignore
            permanent.Add n |> ignore
            result.Add n
    for (name, _) in singletons do visit name
    if cycleReported then singletons |> List.map fst
    else List.ofSeq result

let private mkPath (name: string) (span: Span) : ModulePath =
    { Segments = [name]; Span = span }

let private mkExpr (kind: ExprKind) (span: Span) : Expr =
    { Kind = kind; Span = span }

let private mkType (kind: TypeExprKind) (span: Span) : TypeExpr =
    { Kind = kind; Span = span }

let private synthesiseWireRecord (wd: WireDecl) : RecordDecl =
    let exposed =
        wd.Members
        |> List.choose (function
            | WMExpose (name, sp) -> Some (name, sp)
            | _ -> None)
    let typeOf (name: string) : TypeExpr option =
        wd.Members
        |> List.tryPick (function
            | WMSingleton (n, ty, _, _) when n = name -> Some ty
            | WMProvided (n, ty, _) when n = name -> Some ty
            | _ -> None)
    let fields =
        exposed
        |> List.map (fun (name, sp) ->
            let ty =
                match typeOf name with
                | Some t -> t
                | None   -> mkType TError sp
            RMField
                { DocComments = []
                  Annotations = []
                  Visibility  = Some (Pub sp)
                  Name        = name
                  Type        = ty
                  Default     = None
                  Span        = sp })
    { Name     = wd.Name
      Generics = None
      Where    = None
      Members  = fields
      Span     = wd.Span }

let private synthesiseBootstrap
        (diags: ResizeArray<Diagnostic>)
        (wd: WireDecl) : FunctionDecl =
    let providedParams =
        wd.Members
        |> List.choose (function
            | WMProvided (name, ty, sp) ->
                Some
                    { Mode    = PMIn
                      Name    = name
                      Type    = ty
                      Default = None
                      Span    = sp }
            | _ -> None)
    let singletons =
        wd.Members
        |> List.choose (function
            | WMSingleton (name, _, init, _) ->
                Some (name, referencedNames init)
            | _ -> None)
    let order = topoSortSingletons diags wd.Name wd.Span singletons
    let initOf (name: string) : Expr * Span =
        wd.Members
        |> List.pick (function
            | WMSingleton (n, _, init, sp) when n = name -> Some (init, sp)
            | _ -> None)
    let bindStmts =
        order
        |> List.map (fun name ->
            let init, sp = initOf name
            let pat : Pattern =
                { Kind = PBinding (name, None); Span = sp }
            { Kind = SLocal (LBVal (pat, None, init)); Span = sp })
    let exposed =
        wd.Members
        |> List.choose (function
            | WMExpose (name, sp) -> Some (name, sp)
            | _ -> None)
    let recordLitArgs =
        exposed
        |> List.map (fun (name, sp) ->
            let value = mkExpr (EPath (mkPath name sp)) sp
            CANamed (name, value, sp))
    let recordCallee =
        mkExpr (EPath (mkPath wd.Name wd.Span)) wd.Span
    let recordExpr =
        mkExpr (ECall (recordCallee, recordLitArgs)) wd.Span
    let bodyStmts =
        bindStmts @ [ { Kind = SExpr recordExpr; Span = wd.Span } ]
    let body =
        FBBlock { Statements = bodyStmts; Span = wd.Span }
    let returnTy =
        mkType (TRef (mkPath wd.Name wd.Span)) wd.Span
    { DocComments = []
      Annotations = []
      Visibility  = None
      IsAsync     = false
      Name        = wd.Name + ".bootstrap"
      Generics    = None
      Params      = providedParams
      Return      = Some returnTy
      Where       = None
      Contracts   = []
      Body        = Some body
      Span        = wd.Span }

/// Per-scoped-member factory function (D-progress-072).  A
/// `scoped[Request] db: Conn = makeConn()` member becomes a
/// `pub func <WireName>.scoped<Name>(): T` function that returns
/// a fresh instance on every call.  Callers in request-handler
/// code call this once per request to instantiate the scoped
/// dependency; the resulting value's lifetime matches the
/// request scope (the caller is responsible for cleanup, typically
/// via `defer`).
let private synthesiseScopedFactory
        (wd: WireDecl)
        (name: string)
        (ty: TypeExpr)
        (init: Expr)
        (sp: Span) : FunctionDecl =
    let body =
        FBBlock
            { Statements = [ { Kind = SExpr init; Span = sp } ]
              Span       = sp }
    { DocComments = []
      Annotations = []
      Visibility  = Some (Pub sp)
      IsAsync     = false
      Name        = wd.Name + ".scoped" + name
      Generics    = None
      Params      = []
      Return      = Some ty
      Where       = None
      Contracts   = []
      Body        = Some body
      Span        = sp }

/// Lifetime checker (D-progress-072).  Singletons are constructed
/// once at bootstrap time; their `init` expressions cannot
/// reference scoped names because a scoped value's lifetime is
/// per-request, not per-program.  Capturing one in a singleton
/// would smuggle a request-scoped resource into the global graph.
let private checkSingletonScopedRefs
        (diags: ResizeArray<Diagnostic>)
        (wd: WireDecl) : unit =
    let scopedNames =
        wd.Members
        |> List.choose (function
            | WMScoped (_, name, _, _, _) -> Some name
            | _ -> None)
        |> Set.ofList
    if not (Set.isEmpty scopedNames) then
        for m in wd.Members do
            match m with
            | WMSingleton (singletonName, _, init, sp) ->
                let refs = referencedNames init
                let badRefs = Set.intersect refs scopedNames
                if not (Set.isEmpty badRefs) then
                    let names = badRefs |> Set.toList |> String.concat ", "
                    err diags "P0261"
                        (sprintf "wire '%s': singleton '%s' references scoped name(s): %s — singletons cannot capture per-scope values"
                            wd.Name singletonName names)
                        sp
            | _ -> ()

let synthesizeItems
        (diags: ResizeArray<Diagnostic>)
        (items: Item list) : Item list =
    // For each `IWire` we emit a record + factory carrying the same
    // name, ordered as `[record, IWire (kept for parser tests),
    // bootstrap, scoped factories...]`.  The ordering matters:
    // SymbolTable returns the first symbol on `TryFindOne`, so
    // putting the synthesised record ahead of the original IWire
    // ensures `Resolver.resolveType` for `TRef [WireName]` lands on
    // `DKRecord` rather than `DKWire` (the latter isn't a type).
    // Keeping the IWire item in the list lets the parser's own
    // item-shape tests continue to assert on it.
    let result = ResizeArray<Item>()
    for it in items do
        match it.Kind with
        | IWire wd ->
            checkSingletonScopedRefs diags wd
            let recordDecl = synthesiseWireRecord wd
            let bootstrap  = synthesiseBootstrap diags wd
            result.Add
                { DocComments = []
                  Annotations = []
                  Visibility  = Some (Pub wd.Span)
                  Kind        = IRecord recordDecl
                  Span        = wd.Span }
            result.Add it
            result.Add
                { DocComments = []
                  Annotations = []
                  Visibility  = None
                  Kind        = IFunc bootstrap
                  Span        = wd.Span }
            // Scoped factories — one per `WMScoped` member.
            for m in wd.Members do
                match m with
                | WMScoped (_, name, ty, init, sp) ->
                    let factory = synthesiseScopedFactory wd name ty init sp
                    result.Add
                        { DocComments = []
                          Annotations = []
                          Visibility  = Some (Pub sp)
                          Kind        = IFunc factory
                          Span        = sp }
                | _ -> ()
        | _ -> result.Add it
    List.ofSeq result
