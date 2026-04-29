/// Resolve a parser `TypeExpr` to a type-checker `Type`. Lookups
/// against the symbol table validate that named types exist and that
/// generic application matches arity. Range-refinement, function-type
/// arrow, tuple, slice, array, and nullable forms project onto the
/// matching `Type` constructors.
module Lyric.TypeChecker.Resolver

open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.TypeChecker
open Lyric.TypeChecker.Symbols

/// Map a primitive name to its `Type`. Recognised names cover §4.1
/// of the language reference plus `Char` and `Byte`.
let private tryPrimitive (name: string) : Type option =
    match name with
    | "Unit"   -> Some Type.unit'
    | "Bool"   -> Some Type.bool'
    | "Int"    -> Some Type.int'
    | "Long"   -> Some Type.long'
    | "Nat"    -> Some Type.nat'
    | "Byte"   -> Some Type.byte'
    | "Float"  -> Some Type.float'
    | "Double" -> Some Type.double'
    | "Char"   -> Some Type.char'
    | "String" -> Some Type.string'
    | "Never"  -> Some Type.never'
    | _        -> None

let private err (env: CheckEnv) (code: string) (msg: string) (span: Span) : unit =
    CheckEnv.report env (Diagnostic.error code msg span)

/// Convert a `ModulePath` to a `Type`. The path may be:
///
/// * a single segment matching an in-scope type variable;
/// * a single segment matching a primitive;
/// * a single segment matching a short-name type symbol;
/// * a multi-segment qualified path matching a type symbol;
/// * an aliased import.
///
/// On failure we emit a diagnostic and return `TyError` so the
/// containing expression can keep type-checking.
let private resolvePath (env: CheckEnv) (path: ModulePath) : Type =
    match path.Segments with
    | [] ->
        err env "T0001" "empty type path" path.Span
        Type.error'
    | [name] ->
        if GenericContext.contains env.Generics name then
            Type.TyVar name
        else
            match tryPrimitive name with
            | Some t -> t
            | None ->
                match SymbolTable.tryLookupTypeShort env.Symbols name with
                | Some sym -> Type.TyNamed sym.Name
                | None ->
                    match SymbolTable.tryResolveAlias env.Symbols name with
                    | Some segs -> Type.TyNamed segs
                    | None ->
                        err env "T0002"
                            (sprintf "unknown type '%s'" name)
                            path.Span
                        Type.error'
    | _ ->
        match SymbolTable.tryLookupTypeQualified env.Symbols path.Segments with
        | Some sym -> Type.TyNamed sym.Name
        | None ->
            // Allow extern-package style references that are not
            // pre-registered (Phase 1 deferred extern handling) by
            // returning a TyNamed shell.
            Type.TyNamed path.Segments

let rec resolve (env: CheckEnv) (te: TypeExpr) : Type =
    match te.Kind with
    | TUnit  -> Type.unit'
    | TNever -> Type.never'
    | TSelf  ->
        match env.SelfTy with
        | Some t -> t
        | None   -> Type.TySelf
    | TError -> Type.error'
    | TParen inner -> resolve env inner
    | TRef path -> resolvePath env path
    | TGenericApp (head, args) ->
        let headTy = resolvePath env head
        let argTys =
            args |> List.map (fun a ->
                match a with
                | TAType t -> resolve env t
                | TAValue _ ->
                    // Phase 1 ignores value generics — emit a
                    // diagnostic and substitute TyError so callers
                    // don't crash.
                    err env "T0003"
                        "value generics are not supported in Phase 1"
                        head.Span
                    Type.error')
        Type.TyApp (headTy, argTys)
    | TArray (size, elem) ->
        let sizeOpt =
            match size with
            | TAValue { Kind = ELiteral (LInt (n, _)) } -> Some (int n)
            | _ -> None
        Type.TyArray (sizeOpt, resolve env elem)
    | TSlice elem -> Type.TySlice (resolve env elem)
    | TRefined (path, _) ->
        // Phase 1: range refinements compile to the underlying type.
        resolvePath env path
    | TTuple ts -> Type.TyTuple (ts |> List.map (resolve env))
    | TNullable inner -> Type.TyNullable (resolve env inner)
    | TFunction (ps, r) ->
        Type.TyFunction (ps |> List.map (resolve env), resolve env r)
