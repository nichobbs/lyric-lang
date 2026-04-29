/// Symbol tables. The type checker keeps two complementary tables:
///
/// * **Type symbols** — record / union / enum / opaque / distinct /
///   alias / extern declarations indexed by qualified name.
/// * **Value symbols** — top-level functions, vals, consts, plus the
///   stack of lexical scopes for in-scope locals during body checking.
///
/// Generic context tracks the type variables introduced by the
/// nearest enclosing `[T, U, …]` clause so the resolver can map
/// `TypeExprKind.TRef ["T"]` back to `Type.TyVar "T"`.
module Lyric.TypeChecker.Symbols

open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.TypeChecker

/// What a type symbol *is* — used by the resolver to validate generic
/// arity and by the expression checker to look up record fields and
/// union cases.
type TypeSymbolKind =
    | TskRecord     of fields: (string * Type) list
    | TskExposedRec of fields: (string * Type) list
    | TskUnion      of cases: (string * (string option * Type) list) list
    | TskEnum       of cases: string list
    | TskOpaque
    | TskDistinct   of underlying: Type
    | TskAlias      of underlying: Type
    | TskExtern                                    // extern record / opaque
    | TskInterface  of methods: (string * ResolvedSig) list

and ResolvedSig =
    { Generics:  string list
      Params:    Type list
      Return:    Type }

type TypeSymbol =
    { Name:      string list             // fully qualified
      ShortName: string                  // last segment
      Generics:  string list             // unbound type-parameter names
      Kind:      TypeSymbolKind
      DeclSpan:  Span }

/// What a value symbol carries. A function symbol is fully resolved at
/// the signature level; a value/const carries its declared type; a
/// local is just a name + type (no generics).
type ValueSymbolKind =
    | VskFunc   of ResolvedSig
    | VskVal    of Type
    | VskConst  of Type
    | VskLocal  of Type
    | VskParam  of Type
    | VskUnionCase of typeName: string list * caseFields: (string option * Type) list
    | VskEnumCase  of typeName: string list

type ValueSymbol =
    { Name:      string list
      ShortName: string
      Kind:      ValueSymbolKind
      DeclSpan:  Span }

/// Top-level symbol table built up during the file pre-pass. Maps
/// qualified-name lists to declarations. We also keep a flat
/// short-name index for unqualified lookup of items declared in the
/// current package.
type SymbolTable =
    { Types:        System.Collections.Generic.Dictionary<string, TypeSymbol>
      Values:       System.Collections.Generic.Dictionary<string, ValueSymbol>
      ShortTypes:   System.Collections.Generic.Dictionary<string, TypeSymbol list>
      ShortValues:  System.Collections.Generic.Dictionary<string, ValueSymbol list>
      ImportedAliases: System.Collections.Generic.Dictionary<string, string list> }

module SymbolTable =

    let make () : SymbolTable =
        { Types       = System.Collections.Generic.Dictionary<_, _>()
          Values      = System.Collections.Generic.Dictionary<_, _>()
          ShortTypes  = System.Collections.Generic.Dictionary<_, _>()
          ShortValues = System.Collections.Generic.Dictionary<_, _>()
          ImportedAliases = System.Collections.Generic.Dictionary<_, _>() }

    let private key (segs: string list) : string = String.concat "." segs

    let private addShort
            (idx: System.Collections.Generic.Dictionary<string, 'a list>)
            (name: string)
            (sym: 'a) =
        match idx.TryGetValue name with
        | true, xs -> idx.[name] <- sym :: xs
        | false, _ -> idx.[name] <- [sym]

    let addType (st: SymbolTable) (sym: TypeSymbol) : unit =
        st.Types.[key sym.Name] <- sym
        addShort st.ShortTypes sym.ShortName sym

    let addValue (st: SymbolTable) (sym: ValueSymbol) : unit =
        st.Values.[key sym.Name] <- sym
        addShort st.ShortValues sym.ShortName sym

    let tryLookupTypeQualified (st: SymbolTable) (segs: string list) : TypeSymbol option =
        match st.Types.TryGetValue(key segs) with
        | true, s -> Some s
        | false, _ -> None

    let tryLookupValueQualified (st: SymbolTable) (segs: string list) : ValueSymbol option =
        match st.Values.TryGetValue(key segs) with
        | true, s -> Some s
        | false, _ -> None

    let tryLookupTypeShort (st: SymbolTable) (name: string) : TypeSymbol option =
        match st.ShortTypes.TryGetValue name with
        | true, (s :: _) -> Some s
        | _              -> None

    let tryLookupValueShort (st: SymbolTable) (name: string) : ValueSymbol option =
        match st.ShortValues.TryGetValue name with
        | true, (s :: _) -> Some s
        | _              -> None

    let tryResolveAlias (st: SymbolTable) (name: string) : string list option =
        match st.ImportedAliases.TryGetValue name with
        | true, segs -> Some segs
        | false, _   -> None

    let addAlias (st: SymbolTable) (alias: string) (segs: string list) : unit =
        st.ImportedAliases.[alias] <- segs

/// A nested scope frame for function-body locals. Walked top-down for
/// shadowing-aware lookups.
type Scope =
    { Locals: System.Collections.Generic.Dictionary<string, Type> }

module Scope =

    let make () : Scope =
        { Locals = System.Collections.Generic.Dictionary<_, _>() }

    let addLocal (sc: Scope) (name: string) (ty: Type) : unit =
        sc.Locals.[name] <- ty

    let tryLookup (sc: Scope) (name: string) : Type option =
        match sc.Locals.TryGetValue name with
        | true, t  -> Some t
        | false, _ -> None

/// Generic context: the current set of in-scope type-parameter names
/// (e.g. introduced by a function header `func map[A, B](f: A -> B): …`).
type GenericContext =
    { Params: Set<string> }

module GenericContext =
    let empty : GenericContext = { Params = Set.empty }
    let make (xs: string list) : GenericContext = { Params = Set.ofList xs }
    let union (a: GenericContext) (b: GenericContext) : GenericContext =
        { Params = Set.union a.Params b.Params }
    let contains (g: GenericContext) (name: string) : bool =
        Set.contains name g.Params

/// Body-check environment. Carries the symbol table, the current
/// generic context, the lexical scope stack, and metadata for
/// statements like `return` / `result`.
type CheckEnv =
    { Symbols:        SymbolTable
      Generics:       GenericContext
      ScopeStack:     System.Collections.Generic.Stack<Scope>
      mutable Return: Type
      mutable SelfTy: Type option
      Diagnostics:    System.Collections.Generic.List<Diagnostic> }

module CheckEnv =

    let make (st: SymbolTable) (diags: System.Collections.Generic.List<Diagnostic>) : CheckEnv =
        let stack = System.Collections.Generic.Stack<Scope>()
        stack.Push(Scope.make ())
        { Symbols     = st
          Generics    = GenericContext.empty
          ScopeStack  = stack
          Return      = Type.TyError
          SelfTy      = None
          Diagnostics = diags }

    let pushScope (env: CheckEnv) : unit =
        env.ScopeStack.Push(Scope.make ())

    let popScope (env: CheckEnv) : unit =
        env.ScopeStack.Pop() |> ignore

    let addLocal (env: CheckEnv) (name: string) (ty: Type) : unit =
        Scope.addLocal (env.ScopeStack.Peek()) name ty

    let tryLookupLocal (env: CheckEnv) (name: string) : Type option =
        let mutable found : Type option = None
        let arr = env.ScopeStack.ToArray()  // top-down
        let mutable i = 0
        while found.IsNone && i < arr.Length do
            match Scope.tryLookup arr.[i] name with
            | Some t -> found <- Some t
            | None   -> ()
            i <- i + 1
        found

    let report (env: CheckEnv) (d: Diagnostic) : unit =
        env.Diagnostics.Add d
