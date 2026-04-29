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

/// The checker's per-invocation result. `Symbols` is the package's
/// symbol table after resolving every top-level declaration; the
/// AST is unchanged at this stage but later slices will return a
/// type-annotated copy.
type CheckResult =
    { File:        SourceFile
      Symbols:     SymbolTable
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

/// Type-check a parser-produced source file. Currently registers
/// declarations only — see module doc-comment for what's implemented.
let check (file: SourceFile) : CheckResult =
    let diags = ResizeArray<Diagnostic>()
    let table = SymbolTable()
    let idSrc = TypeIdSource()

    for it in file.Items do
        registerItem table idSrc diags it |> ignore

    { File        = file
      Symbols     = table
      Diagnostics = List.ofSeq diags }
