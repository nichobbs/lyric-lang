/// Resolved type representation, distinct from the parser's
/// `Lyric.Parser.Ast.TypeExpr`. A `Type` carries no surface-syntax
/// information — it is the canonical, post-resolution form used by
/// the rest of the type checker and downstream passes.
namespace Lyric.TypeChecker

open Lyric.Lexer

/// Stable identifier for a user-defined type (record / union / enum /
/// opaque / distinct / alias). Allocated at item-resolution time and
/// used to compare types by identity rather than structure.
type TypeId = TypeId of int

/// Lyric primitive types per docs/01-language-reference.md §2.1.
type PrimType =
    | TBool
    | TByte
    | TInt
    | TLong
    | TUInt
    | TULong
    | TNat
    | TFloat
    | TDouble
    | TChar
    | TString
    | TUnit
    | TNever

/// Resolved type. `Type` values are constructed by the resolver and
/// consumed by every downstream pass (mode checker, contract
/// elaborator, MSIL emitter). They carry no source position; the
/// surrounding AST node holds the span.
type Type =
    | TPrim     of PrimType

    /// `(A, B, …)` — a tuple. The empty tuple is `TPrim TUnit`.
    | TTuple    of Type list

    /// `T?` — nullable wrapper.
    | TNullable of Type

    /// `(A, B, …) -> C` — function type. `IsAsync` is true when the
    /// declaration was `async func`.
    | TFunction of parameters: Type list * result: Type * isAsync: bool

    /// `array[N, T]` — fixed-size array. Size is None when it is a
    /// value-generic parameter (e.g. `array[N, T]` inside a generic).
    | TArray    of size: int option * element: Type

    /// `slice[T]` — dynamic slice.
    | TSlice    of Type

    /// User-defined nominal type (record / union / opaque / distinct /
    /// alias) applied to its type arguments. The TypeId is the
    /// canonical identity of the declaration.
    | TUser     of TypeId * args: Type list

    /// `Self` — the implicit self-type inside an interface or impl.
    /// Resolved to a concrete TUser at instantiation.
    | TSelf

    /// A generic type variable bound by an enclosing `generic[…]`
    /// header. Identified by its source name.
    | TVar      of name: string

    /// Recovery placeholder when a type expression could not be
    /// resolved. Downstream passes treat TError as compatible with
    /// anything (poisoning prevents cascading errors).
    | TError

/// Compare types for structural equality. TError is considered equal
/// to any other type (so a recovered type does not provoke spurious
/// diagnostics in code that uses it).
module Type =

    let primName : PrimType -> string = function
        | TBool   -> "Bool"     | TByte   -> "Byte"
        | TInt    -> "Int"      | TLong   -> "Long"
        | TUInt   -> "UInt"     | TULong  -> "ULong"
        | TNat    -> "Nat"      | TFloat  -> "Float"
        | TDouble -> "Double"   | TChar   -> "Char"
        | TString -> "String"   | TUnit   -> "Unit"
        | TNever  -> "Never"

    let primFromString : string -> PrimType option = function
        | "Bool"   -> Some TBool    | "Byte"   -> Some TByte
        | "Int"    -> Some TInt     | "Long"   -> Some TLong
        | "UInt"   -> Some TUInt    | "ULong"  -> Some TULong
        | "Nat"    -> Some TNat     | "Float"  -> Some TFloat
        | "Double" -> Some TDouble  | "Char"   -> Some TChar
        | "String" -> Some TString  | "Unit"   -> Some TUnit
        | "Never"  -> Some TNever
        | _        -> None

    let rec equiv (a: Type) (b: Type) : bool =
        match a, b with
        | TError, _ | _, TError                 -> true
        | TPrim x, TPrim y                      -> x = y
        | TSelf, TSelf                          -> true
        | TVar x, TVar y                        -> x = y
        | TTuple xs, TTuple ys                  -> List.compareWith compareT xs ys = 0
        | TNullable x, TNullable y              -> equiv x y
        | TFunction(p1, r1, a1), TFunction(p2, r2, a2) ->
            a1 = a2
            && List.length p1 = List.length p2
            && List.forall2 equiv p1 p2
            && equiv r1 r2
        | TArray(s1, e1), TArray(s2, e2)        -> s1 = s2 && equiv e1 e2
        | TSlice x, TSlice y                    -> equiv x y
        | TUser(id1, a1), TUser(id2, a2) ->
            id1 = id2
            && List.length a1 = List.length a2
            && List.forall2 equiv a1 a2
        | _                                      -> false

    and private compareT (a: Type) (b: Type) : int =
        if equiv a b then 0 else 1

    let rec render : Type -> string = function
        | TPrim p          -> primName p
        | TTuple xs        ->
            "(" + (xs |> List.map render |> String.concat ", ") + ")"
        | TNullable x      -> render x + "?"
        | TFunction(ps, r, isAsync) ->
            let prefix = if isAsync then "async " else ""
            let pstr = "(" + (ps |> List.map render |> String.concat ", ") + ")"
            prefix + pstr + " -> " + render r
        | TArray(Some n, e) -> sprintf "array[%d, %s]" n (render e)
        | TArray(None, e)   -> sprintf "array[?, %s]" (render e)
        | TSlice x          -> sprintf "slice[%s]" (render x)
        | TUser(TypeId id, []) -> sprintf "<#%d>" id
        | TUser(TypeId id, args) ->
            sprintf "<#%d>[%s]" id (args |> List.map render |> String.concat ", ")
        | TSelf             -> "Self"
        | TVar n            -> n
        | TError            -> "<error>"
