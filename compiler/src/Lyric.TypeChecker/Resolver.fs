/// Resolve a parser-produced TypeExpr into a checker Type.
module Lyric.TypeChecker.Resolver

open Lyric.Lexer
open Lyric.Parser.Ast

let private err
        (diags: ResizeArray<Diagnostic>)
        (code:  string)
        (msg:   string)
        (span:  Span) =
    diags.Add(Diagnostic.error code msg span)

let rec resolveType
        (table: SymbolTable)
        (ctx:   GenericContext)
        (diags: ResizeArray<Diagnostic>)
        (te:    TypeExpr)
        : Type =
    match te.Kind with
    | TUnit  -> TyPrim PtUnit
    | TSelf  -> TySelf
    | TNever -> TyPrim PtNever
    | TError -> TyError

    | TParen inner ->
        resolveType table ctx diags inner

    | TTuple xs ->
        TyTuple (xs |> List.map (resolveType table ctx diags))

    | TNullable inner ->
        TyNullable (resolveType table ctx diags inner)

    | TFunction(parameters, result) ->
        let ps = parameters |> List.map (resolveType table ctx diags)
        let r  = resolveType table ctx diags result
        TyFunction(ps, r, false)

    | TArray(size, elem) ->
        let elemT = resolveType table ctx diags elem
        let sizeT =
            match size with
            | TAValue { Kind = ELiteral (LInt(n, _)) } -> Some (int n)
            | _ -> None        // value-generic or recovery
        TyArray(sizeT, elemT)

    | TSlice elem ->
        TySlice (resolveType table ctx diags elem)

    | TRef path ->
        resolvePath table ctx diags path te.Span []

    | TGenericApp(head, args) ->
        let resolvedArgs =
            args |> List.map (fun a ->
                match a with
                | TAType t -> resolveType table ctx diags t
                | TAValue _ ->
                    // Value-generic arg — full handling lands in T6.
                    TyError)
        resolvePath table ctx diags head te.Span resolvedArgs

    | TRefined(under, _bound) ->
        // The range bound is not captured in the resolved Type yet
        // (its enforcement lives in the contract elaborator). For
        // type-checking purposes the refined type is equivalent to
        // its underlying numeric primitive / distinct type.
        resolvePath table ctx diags under te.Span []

and private resolvePath
        (table: SymbolTable)
        (ctx:   GenericContext)
        (diags: ResizeArray<Diagnostic>)
        (path:  ModulePath)
        (span:  Span)
        (args:  Type list)
        : Type =
    match path.Segments with
    | [] ->
        err diags "T0010" "empty module path in type position" span
        TyError

    | [name] ->
        // 1. Primitive?
        match Type.primFromString name with
        | Some prim ->
            if not args.IsEmpty then
                err diags "T0012"
                    (sprintf "primitive type '%s' does not take type arguments" name)
                    span
            TyPrim prim
        | None ->
            // 2. In-scope generic type parameter?
            if ctx.IsTypeParam name && args.IsEmpty then
                TyVar name
            else
                // 3. User-declared type in this package's symbol table?
                match table.TryFindOne name with
                | Some sym ->
                    match Symbol.typeIdOpt sym with
                    | Some id -> TyUser(id, args)
                    | None ->
                        err diags "T0013"
                            (sprintf "'%s' is not a type" name)
                            span
                        TyError
                | None ->
                    err diags "T0010"
                        (sprintf "unknown type name '%s'" name)
                        span
                    TyError

    | _ ->
        // Multi-segment path. Today we only recognise a primitive in
        // the trailing segment (e.g. `std.core.Int`). Cross-package
        // resolution lands in T7+ when contract-metadata import data
        // is wired in.
        let last = List.last path.Segments
        match Type.primFromString last with
        | Some prim ->
            if not args.IsEmpty then
                err diags "T0012"
                    (sprintf "primitive type '%s' does not take type arguments" last)
                    span
            TyPrim prim
        | None ->
            err diags "T0014"
                (sprintf "qualified type names not yet resolved (saw '%s')"
                    (String.concat "." path.Segments))
                span
            TyError
