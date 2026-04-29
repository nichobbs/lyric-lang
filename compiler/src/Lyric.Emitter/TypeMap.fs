/// Map a Lyric `Type` to a CLR `System.Type`. Used by every codegen
/// pass that needs to construct a method signature, a local-variable
/// slot, or a typed constant.
///
/// Phase 1 covers the §4.1 primitives plus tuples (→ `System.ValueTuple`),
/// slices (→ T[]), arrays (→ T[]), nullables (→ Nullable<T> for value
/// types, the underlying ref for reference types), and `Unit` (→ void
/// at the method-return level, or `System.ValueTuple` when used as a
/// value position). Generic instantiation (`TyUser`) lands in E5/E8.
module Lyric.Emitter.TypeMap

open Lyric.TypeChecker

/// Convenience alias — within this module, unqualified `Type` refers
/// to the Lyric DU; the CLR equivalent is `ClrType`.
type private ClrType = System.Type

/// CLR primitive types corresponding to each Lyric primitive. `Unit`
/// at value position has no CLR counterpart; we use `System.ValueTuple`
/// (the empty tuple type) when a slot type is required, and emit
/// `void` when a return-type is required.
let private primToClr : PrimType -> ClrType =
    function
    | PtBool   -> typeof<bool>
    | PtByte   -> typeof<byte>
    | PtInt    -> typeof<int32>
    | PtLong   -> typeof<int64>
    | PtUInt   -> typeof<uint32>
    | PtULong  -> typeof<uint64>
    | PtNat    -> typeof<uint64>          // Phase 1 simplification
    | PtFloat  -> typeof<single>
    | PtDouble -> typeof<double>
    | PtChar   -> typeof<char>
    | PtString -> typeof<string>
    | PtUnit   -> typeof<System.ValueTuple>
    | PtNever  -> typeof<System.ValueTuple>   // diverging — stack value never observed

/// Map a Lyric `Type` to a CLR `System.Type` using a lookup for
/// user-defined types. The lookup may return `None` for types whose
/// CLR shape isn't yet known (in which case we fall back to `obj`).
let rec toClrTypeWith (lookup: TypeId -> ClrType option) (t: Type) : ClrType =
    let recur = toClrTypeWith lookup
    match t with
    | TyPrim p -> primToClr p
    | TyTuple [] -> typeof<System.ValueTuple>
    | TyTuple [x] -> recur x
    | TyTuple xs ->
        // System.ValueTuple<...> for ≤ 7 elements; nested for more.
        let args = xs |> List.map recur |> List.toArray
        match args.Length with
        | 2 -> typedefof<System.ValueTuple<_, _>>.MakeGenericType args
        | 3 -> typedefof<System.ValueTuple<_, _, _>>.MakeGenericType args
        | 4 -> typedefof<System.ValueTuple<_, _, _, _>>.MakeGenericType args
        | 5 -> typedefof<System.ValueTuple<_, _, _, _, _>>.MakeGenericType args
        | 6 -> typedefof<System.ValueTuple<_, _, _, _, _, _>>.MakeGenericType args
        | 7 -> typedefof<System.ValueTuple<_, _, _, _, _, _, _>>.MakeGenericType args
        | _ -> typeof<obj>
    | TyNullable inner ->
        let cl = recur inner
        if cl.IsValueType then
            typedefof<System.Nullable<_>>.MakeGenericType([| cl |])
        else
            cl
    | TySlice elem | TyArray (_, elem) ->
        (recur elem).MakeArrayType()
    | TyFunction _    -> typeof<obj>     // E8 lifts to delegate types
    | TyUser (id, _)  ->
        match lookup id with
        | Some t -> t
        | None   -> typeof<obj>
    | TySelf          -> typeof<obj>
    | TyVar _         -> typeof<obj>
    | TyError         -> typeof<obj>

/// Convenience overload that knows nothing about user types — every
/// `TyUser` lowers to `obj`. Kept for tests / call sites that
/// haven't built a TypeId map yet.
let toClrType (t: Type) : ClrType =
    toClrTypeWith (fun _ -> None) t

/// CLR return-type for a Lyric type. Differs from `toClrType` only
/// for `Unit` and `Never`, which lower to `void` at the return slot.
let toClrReturnTypeWith (lookup: TypeId -> ClrType option) (t: Type) : ClrType =
    match t with
    | TyPrim PtUnit | TyPrim PtNever -> typeof<System.Void>
    | _ -> toClrTypeWith lookup t

let toClrReturnType (t: Type) : ClrType =
    toClrReturnTypeWith (fun _ -> None) t

/// Whether a Lyric type lowers to a CLR `void`-shaped value (no
/// stack value to push at function exit).
let isVoidLike (t: Type) : bool =
    match t with
    | TyPrim PtUnit | TyPrim PtNever -> true
    | _ -> false
