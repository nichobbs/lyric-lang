/// Internal type representation used by the type checker.
///
/// Constructors carry `Ty…` / `Pt…` prefixes to avoid collisions with
/// the parser's `TypeExprKind` (`TUnit`, `TRef`, `TSelf`, …) when both
/// modules are opened in the same file.
namespace Lyric.TypeChecker

open Lyric.Lexer
open Lyric.Parser.Ast

/// Built-in primitive types. Phase 1 covers the §4.1 primitives plus
/// `Char` and `Byte` since the lexer already recognises their literal
/// forms. `Nat` is treated as a distinct primitive (rather than a
/// refinement of `Int`) for now — refinements are deferred per
/// `docs/05-implementation-plan.md` Phase 1 "Deferred" list.
type PrimType =
    | PtUnit
    | PtBool
    | PtInt
    | PtLong
    | PtNat
    | PtByte
    | PtFloat
    | PtDouble
    | PtChar
    | PtString
    | PtNever          // uninhabited

/// The internal kind of a Lyric type. Equality is structural via
/// derived `=` — two types are equal iff their representations match.
/// Generic application is shallow (head + args); `TyVar` carries a
/// bind name for substitution.
[<RequireQualifiedAccess; StructuralEquality; StructuralComparison>]
type Type =
    | TyPrim of PrimType
    /// A named user-declared type (record / union / enum / opaque /
    /// distinct / extern), referenced by its fully-qualified path.
    /// Generic instantiations live under `TyApp`.
    | TyNamed of segments: string list
    /// `head[args…]` — generic instantiation. `head` is normally a
    /// `TyNamed`; the args are parallel positional bindings.
    | TyApp of head: Type * args: Type list
    | TyFunction of parameters: Type list * result: Type
    | TyTuple of Type list
    | TyArray of size: int option * element: Type   // None when size is unresolved
    | TySlice of element: Type
    | TyNullable of element: Type
    | TyVar of name: string
    | TySelf
    /// Recovery placeholder. Equal to itself only — never to a real
    /// type — and silently subsumes any unification attempt so that
    /// downstream errors don't cascade.
    | TyError

module Type =

    let unit'    = Type.TyPrim PtUnit
    let bool'    = Type.TyPrim PtBool
    let int'     = Type.TyPrim PtInt
    let long'    = Type.TyPrim PtLong
    let nat'     = Type.TyPrim PtNat
    let byte'    = Type.TyPrim PtByte
    let float'   = Type.TyPrim PtFloat
    let double'  = Type.TyPrim PtDouble
    let char'    = Type.TyPrim PtChar
    let string'  = Type.TyPrim PtString
    let never'   = Type.TyPrim PtNever
    let error'   = Type.TyError

    /// Pretty-print a type for diagnostics. Stable; not pretty-pretty.
    let rec render (t: Type) : string =
        match t with
        | Type.TyPrim p ->
            match p with
            | PtUnit   -> "Unit"
            | PtBool   -> "Bool"
            | PtInt    -> "Int"
            | PtLong   -> "Long"
            | PtNat    -> "Nat"
            | PtByte   -> "Byte"
            | PtFloat  -> "Float"
            | PtDouble -> "Double"
            | PtChar   -> "Char"
            | PtString -> "String"
            | PtNever  -> "Never"
        | Type.TyNamed segs    -> String.concat "." segs
        | Type.TyApp (h, args) ->
            let argStr =
                args |> List.map render |> String.concat ", "
            sprintf "%s[%s]" (render h) argStr
        | Type.TyFunction (ps, r) ->
            let psStr = ps |> List.map render |> String.concat ", "
            sprintf "(%s) -> %s" psStr (render r)
        | Type.TyTuple ts ->
            let inner = ts |> List.map render |> String.concat ", "
            sprintf "(%s)" inner
        | Type.TyArray (size, e) ->
            match size with
            | Some n -> sprintf "array[%d, %s]" n (render e)
            | None   -> sprintf "array[?, %s]" (render e)
        | Type.TySlice e    -> sprintf "slice[%s]" (render e)
        | Type.TyNullable e -> sprintf "%s?" (render e)
        | Type.TyVar n      -> n
        | Type.TySelf       -> "Self"
        | Type.TyError      -> "<error>"

    /// Substitute every `TyVar n` with `subst.[n]` if present.
    /// Untouched variables remain as `TyVar`.
    let rec subst (s: Map<string, Type>) (t: Type) : Type =
        match t with
        | Type.TyVar n ->
            match Map.tryFind n s with
            | Some t' -> t'
            | None    -> t
        | Type.TyApp (h, args) ->
            Type.TyApp (subst s h, args |> List.map (subst s))
        | Type.TyFunction (ps, r) ->
            Type.TyFunction (ps |> List.map (subst s), subst s r)
        | Type.TyTuple ts ->
            Type.TyTuple (ts |> List.map (subst s))
        | Type.TyArray (n, e) ->
            Type.TyArray (n, subst s e)
        | Type.TySlice e ->
            Type.TySlice (subst s e)
        | Type.TyNullable e ->
            Type.TyNullable (subst s e)
        | Type.TyPrim _ | Type.TyNamed _ | Type.TySelf | Type.TyError ->
            t

    /// Check whether `actual` is assignable to `expected`. Phase 1
    /// rules: structural equality, nullable subsumes inner, `TyError`
    /// is universally compatible (recovery), `TyVar` matches anything
    /// (placeholder for the inference pass), and an applied generic
    /// type is compatible with its bare head when args are absent
    /// (the type checker doesn't yet track instantiation through
    /// constructor calls — `Some(x): Option` flows into `Option[A]`).
    let rec compatible (expected: Type) (actual: Type) : bool =
        if expected = actual then true
        else
            match expected, actual with
            | Type.TyError, _ | _, Type.TyError -> true
            | Type.TyVar _, _ | _, Type.TyVar _ -> true
            | Type.TyNullable e, a              -> compatible e a
            | a, Type.TyNullable inner          -> compatible a inner
            | Type.TyPrim PtNever, _            -> true   // Never can flow anywhere
            | _, Type.TyPrim PtNever            -> true
            | Type.TyApp (h, _), other when compatible h other -> true
            | other, Type.TyApp (h, _) when compatible other h -> true
            // Distinct/range-refined types compile down to a
            // primitive in Phase 1. Without the symbol table here
            // we can't chase the underlying, so we assume any
            // TyNamed could be a numeric/string distinct of a
            // primitive and let it slide.
            | Type.TyNamed _, Type.TyPrim _ -> true
            | Type.TyPrim _, Type.TyNamed _ -> true
            | Type.TyApp (h1, a1), Type.TyApp (h2, a2)
                when List.length a1 = List.length a2 ->
                compatible h1 h2
                && List.forall2 compatible a1 a2
            | Type.TyFunction (p1, r1), Type.TyFunction (p2, r2)
                when List.length p1 = List.length p2 ->
                List.forall2 compatible p1 p2 && compatible r1 r2
            | Type.TyTuple t1, Type.TyTuple t2
                when List.length t1 = List.length t2 ->
                List.forall2 compatible t1 t2
            | Type.TySlice e1, Type.TySlice e2 -> compatible e1 e2
            | _ -> false
