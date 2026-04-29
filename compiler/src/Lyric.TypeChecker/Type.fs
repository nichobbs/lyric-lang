/// Resolved type representation, distinct from the parser's
/// `Lyric.Parser.Ast.TypeExpr`. A `Type` carries no surface-syntax
/// information — it is the canonical, post-resolution form used by
/// the rest of the type checker and downstream passes.
///
/// Variant constructors are prefixed (`Ty…` for `Type`, `Pt…` for
/// `PrimType`) to disambiguate from the parser AST's TypeExprKind
/// constructors when both are in scope.
namespace Lyric.TypeChecker

open Lyric.Lexer

/// Stable identifier for a user-defined type (record / union / enum /
/// opaque / distinct / alias). Allocated at item-resolution time and
/// used to compare types by identity rather than structure.
type TypeId = TypeId of int

/// Lyric primitive types per docs/01-language-reference.md §2.1.
type PrimType =
    | PtBool
    | PtByte
    | PtInt
    | PtLong
    | PtUInt
    | PtULong
    | PtNat
    | PtFloat
    | PtDouble
    | PtChar
    | PtString
    | PtUnit
    | PtNever

/// Resolved type. `Type` values are constructed by the resolver and
/// consumed by every downstream pass.
type Type =
    | TyPrim     of PrimType
    | TyTuple    of Type list
    | TyNullable of Type
    | TyFunction of parameters: Type list * result: Type * isAsync: bool
    | TyArray    of size: int option * element: Type
    | TySlice    of Type
    | TyUser     of TypeId * args: Type list
    | TySelf
    | TyVar      of name: string
    | TyError

module Type =

    let primName : PrimType -> string = function
        | PtBool   -> "Bool"     | PtByte   -> "Byte"
        | PtInt    -> "Int"      | PtLong   -> "Long"
        | PtUInt   -> "UInt"     | PtULong  -> "ULong"
        | PtNat    -> "Nat"      | PtFloat  -> "Float"
        | PtDouble -> "Double"   | PtChar   -> "Char"
        | PtString -> "String"   | PtUnit   -> "Unit"
        | PtNever  -> "Never"

    let primFromString : string -> PrimType option = function
        | "Bool"   -> Some PtBool    | "Byte"   -> Some PtByte
        | "Int"    -> Some PtInt     | "Long"   -> Some PtLong
        | "UInt"   -> Some PtUInt    | "ULong"  -> Some PtULong
        | "Nat"    -> Some PtNat     | "Float"  -> Some PtFloat
        | "Double" -> Some PtDouble  | "Char"   -> Some PtChar
        | "String" -> Some PtString  | "Unit"   -> Some PtUnit
        | "Never"  -> Some PtNever
        | _        -> None

    let rec equiv (a: Type) (b: Type) : bool =
        match a, b with
        | TyError, _ | _, TyError                       -> true
        | TyPrim x, TyPrim y                            -> x = y
        | TySelf, TySelf                                -> true
        | TyVar x, TyVar y                              -> x = y
        | TyTuple xs, TyTuple ys                        ->
            List.length xs = List.length ys
            && List.forall2 equiv xs ys
        | TyNullable x, TyNullable y                    -> equiv x y
        | TyFunction(p1, r1, a1), TyFunction(p2, r2, a2) ->
            a1 = a2
            && List.length p1 = List.length p2
            && List.forall2 equiv p1 p2
            && equiv r1 r2
        | TyArray(s1, e1), TyArray(s2, e2)              -> s1 = s2 && equiv e1 e2
        | TySlice x, TySlice y                          -> equiv x y
        | TyUser(id1, a1), TyUser(id2, a2) ->
            id1 = id2
            && List.length a1 = List.length a2
            && List.forall2 equiv a1 a2
        | _                                              -> false

    let rec render : Type -> string = function
        | TyPrim p          -> primName p
        | TyTuple xs        ->
            "(" + (xs |> List.map render |> String.concat ", ") + ")"
        | TyNullable x      -> render x + "?"
        | TyFunction(ps, r, isAsync) ->
            let prefix = if isAsync then "async " else ""
            let pstr = "(" + (ps |> List.map render |> String.concat ", ") + ")"
            prefix + pstr + " -> " + render r
        | TyArray(Some n, e) -> sprintf "array[%d, %s]" n (render e)
        | TyArray(None, e)   -> sprintf "array[?, %s]" (render e)
        | TySlice x          -> sprintf "slice[%s]" (render x)
        | TyUser(TypeId id, []) -> sprintf "<#%d>" id
        | TyUser(TypeId id, args) ->
            sprintf "<#%d>[%s]" id (args |> List.map render |> String.concat ", ")
        | TySelf             -> "Self"
        | TyVar n            -> n
        | TyError            -> "<error>"
