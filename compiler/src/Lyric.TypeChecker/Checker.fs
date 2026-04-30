/// Public entry point of the type checker.
///
/// T1 milestone work-in-progress. The current state implements:
///
///   * Project scaffolding with Type / Symbol / Scope foundations.
///   * A `check` function that registers every top-level item in the
///     package's symbol table (assigning a fresh TypeId to each
///     type-shaped declaration) and reports duplicate-name errors.
///
/// Type-expression resolution, function-body checking, and generic
/// monomorphisation land in subsequent slices (T2 onwards) per the
/// project plan.
module Lyric.TypeChecker.Checker

open Lyric.Lexer
open Lyric.Parser.Ast

/// The checker's per-invocation result.
///
/// * Symbols     — package-level symbol table populated in T1.
/// * Signatures  — function-name → resolved signature, populated in
///                  T3 for every IFunc in the file.
/// * Diagnostics — accumulated across T1 + T2 + T3.
type CheckResult =
    { File:        SourceFile
      Symbols:     SymbolTable
      Signatures:  Map<string, ResolvedSignature>
      Diagnostics: Diagnostic list }

let private err
        (diags: ResizeArray<Diagnostic>)
        (code:  string)
        (msg:   string)
        (span:  Span) =
    diags.Add(Diagnostic.error code msg span)

/// Allocate fresh type identifiers monotonically. The numbering is
/// scoped to the package being checked; cross-package identity is a
/// problem for the future contract-metadata layer.
type private TypeIdSource() =
    let mutable next = 1
    member _.Fresh() : TypeId =
        let id = next
        next <- next + 1
        TypeId id

/// Register a single item in the symbol table. Returns the
/// constructed Symbol, or None if the item kind has no name to
/// register (e.g. an `impl` block or a recovered IError).
let private registerItem
        (table:  SymbolTable)
        (idSrc:  TypeIdSource)
        (diags:  ResizeArray<Diagnostic>)
        (it:     Item)
        : Symbol option =

    let mkSym (name: string) (kind: DeclKind) : Symbol =
        let sym =
            { Name        = name
              Kind        = kind
              DeclSpan    = it.Span
              Visibility  = it.Visibility }
        // Duplicate-name check: same name, same kind class.
        match table.TryFindOne(name) with
        | Some prior when Symbol.isType prior = Symbol.isType sym ->
            err diags "T0001"
                (sprintf "duplicate %s name '%s' (previously declared at line %d)"
                    (if Symbol.isType sym then "type" else "value")
                    name
                    prior.DeclSpan.Start.Line)
                it.Span
        | _ -> ()
        table.Add(sym)
        sym

    let mkType ctor (name: string) =
        let id = idSrc.Fresh()
        Some (mkSym name (ctor id))

    match it.Kind with
    | IRecord r        -> mkType (fun id -> DKRecord(id, r))         r.Name
    | IExposedRec r    -> mkType (fun id -> DKExposedRec(id, r))     r.Name
    | IUnion u         ->
        let id = idSrc.Fresh()
        let parent = Some (mkSym u.Name (DKUnion(id, u)))
        // Register each variant case as a separate symbol.
        for case in u.Cases do
            mkSym case.Name (DKUnionCase(id, case)) |> ignore
        parent
    | IEnum e          ->
        let id = idSrc.Fresh()
        let parent = Some (mkSym e.Name (DKEnum(id, e)))
        for case in e.Cases do
            mkSym case.Name (DKEnumCase(id, case)) |> ignore
        parent
    | IOpaque o        -> mkType (fun id -> DKOpaque(id, o))         o.Name
    | IProtected p     -> mkType (fun id -> DKProtected(id, p))      p.Name
    | IDistinctType d  -> mkType (fun id -> DKDistinctType(id, d))   d.Name
    | ITypeAlias a     -> Some (mkSym a.Name (DKTypeAlias a))
    | IInterface i     -> mkType (fun id -> DKInterface(id, i))      i.Name
    | IFunc f          -> Some (mkSym f.Name (DKFunc f))
    | IConst c         -> Some (mkSym c.Name (DKConst c))
    | IVal v           ->
        // Module-level val with a pattern: only single-ident
        // bindings are registered as named symbols; tuple/destructure
        // patterns are deferred to the body-checker pass.
        match v.Pattern.Kind with
        | PBinding(name, None) -> Some (mkSym name (DKVal v))
        | _ -> None
    | IWire w          -> Some (mkSym w.Name (DKWire w))
    | IExtern e        ->
        // The extern itself isn't a name; its members are registered
        // when the type checker visits the extern's body in T3.
        None
    | IScopeKind s     -> Some (mkSym s.Name (DKScopeKind s))
    | ITest t          -> Some (mkSym t.Title (DKTest t))
    | IProperty p      -> Some (mkSym p.Title (DKProperty p))
    | IFixture x       -> Some (mkSym x.Name (DKFixture x))
    | IImpl _          -> None       // impl blocks have no identifier
    | IError           -> None

/// The closed set of derive markers recognised in `where T: M` bounds.
/// Per D034: Add, Sub, Mul, Div, Mod, Compare, Hash, Equals, Default.
let private knownDeriveMarkers : Set<string> =
    Set.ofList [ "Add"; "Sub"; "Mul"; "Div"; "Mod"
                 "Compare"; "Hash"; "Equals"; "Default" ]

/// Well-formedness check for a `where` clause: each bound's left side
/// must be a generic parameter of the enclosing item, and each right-
/// side constraint must be a known derive marker or an interface in
/// scope.  Bound *enforcement* at call sites still waits on full
/// generic instantiation; this only catches typos at definition time.
let private checkWhereClause
        (table: SymbolTable)
        (diags: ResizeArray<Diagnostic>)
        (genericNames: string list)
        (where: WhereClause option) : unit =
    match where with
    | None -> ()
    | Some wc ->
        let known = Set.ofList genericNames
        for b in wc.Bounds do
            if not (Set.contains b.Name known) then
                diags.Add(Diagnostic.error "T0050"
                    (sprintf "'where' clause references unknown type parameter '%s'"
                        b.Name)
                    b.Span)
            for c in b.Constraints do
                match c.Head.Segments with
                | [name] ->
                    let isMarker = Set.contains name knownDeriveMarkers
                    let isInterface =
                        match table.TryFindOne name with
                        | Some s ->
                            match s.Kind with
                            | DKInterface _ -> true
                            | _ -> false
                        | None -> false
                    if not (isMarker || isInterface) then
                        diags.Add(Diagnostic.error "T0051"
                            (sprintf "unknown constraint '%s' in 'where' clause" name)
                            c.Span)
                | _ ->
                    diags.Add(Diagnostic.error "T0051"
                        (sprintf "qualified constraint paths not yet supported in 'where' clause")
                        c.Span)

/// Resolve a single FunctionDecl's signature. The function's generic
/// parameters are pushed onto the GenericContext so that bare `T`
/// references in parameter and return positions resolve to TyVar.
let private resolveFunctionSig
        (table: SymbolTable)
        (diags: ResizeArray<Diagnostic>)
        (fn:    FunctionDecl)
        : ResolvedSignature =

    let ctx = GenericContext()
    let genericNames =
        match fn.Generics with
        | Some gs ->
            gs.Params
            |> List.map (function
                | GPType(name, _)
                | GPValue(name, _, _) -> name)
        | None -> []
    if not genericNames.IsEmpty then
        ctx.Push(genericNames)

    checkWhereClause table diags genericNames fn.Where

    let bounds =
        match fn.Where with
        | Some wc ->
            wc.Bounds
            |> List.map (fun b ->
                let constraints =
                    b.Constraints
                    |> List.choose (fun c ->
                        match c.Head.Segments with
                        | [name] -> Some name
                        | _ -> None)
                { Name = b.Name; Constraints = constraints })
        | None -> []

    let resolveParam (p: Param) : ResolvedParam =
        { Name    = p.Name
          Type    = Resolver.resolveType table ctx diags p.Type
          Mode    = p.Mode
          Default = p.Default.IsSome
          Span    = p.Span }

    let parameters = fn.Params |> List.map resolveParam
    let returnType =
        match fn.Return with
        | Some t -> Resolver.resolveType table ctx diags t
        | None   -> TyPrim PtUnit

    { Generics = genericNames
      Bounds   = bounds
      Params   = parameters
      Return   = returnType
      IsAsync  = fn.IsAsync
      Span     = fn.Span }

/// Type-check a parser-produced source file with optional pre-
/// registered "imported" items (e.g. those pulled in via `import
/// Std.Core`).  Imported items are added to the symbol table and have
/// their function signatures resolved so the user's body checker can
/// resolve calls to them, but their bodies aren't re-checked here —
/// they were already validated when the imported assembly was
/// compiled.
let checkWithImports (file: SourceFile) (importedItems: Item list) : CheckResult =
    let diags = ResizeArray<Diagnostic>()
    let table = SymbolTable()
    let idSrc = TypeIdSource()

    // Register imported items first so user items can shadow / refer to them.
    for it in importedItems do
        registerItem table idSrc diags it |> ignore
    for it in file.Items do
        registerItem table idSrc diags it |> ignore

    // T3: resolve signatures for every IFunc — both imported and user.
    let signatures =
        Seq.append (List.toSeq importedItems) (List.toSeq file.Items)
        |> Seq.choose (fun it ->
            match it.Kind with
            | IFunc fn ->
                Some (fn.Name, resolveFunctionSig table diags fn)
            | _ -> None)
        |> Map.ofSeq

    // T5: check each function's body against its resolved signature —
    //     only for user-defined items.  Imported bodies were checked
    //     at the import target's compile time.
    for it in file.Items do
        match it.Kind with
        | IFunc fn ->
            match Map.tryFind fn.Name signatures with
            | Some s -> StmtChecker.checkFunctionBody table signatures diags fn s
            | None -> ()
        | _ -> ()

    { File        = file
      Symbols     = table
      Signatures  = signatures
      Diagnostics = List.ofSeq diags }

/// Back-compat wrapper for callers that don't pass imports.
let check (file: SourceFile) : CheckResult =
    checkWithImports file []
