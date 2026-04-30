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
///
/// `genericSubst` substitutes Lyric `TyVar name` references for the
/// caller-supplied CLR `Type` (typically a `GenericTypeParameterBuilder`
/// when emitting a generic method, or a concrete CLR type when
/// monomorphising a call site).  An empty map preserves the previous
/// erasure-to-`obj` behaviour for unbound type variables.
let rec toClrTypeWithGenerics
        (lookup: TypeId -> ClrType option)
        (genericSubst: Map<string, ClrType>)
        (t: Type) : ClrType =
    let recur = toClrTypeWithGenerics lookup genericSubst
    match t with
    | TyPrim p -> primToClr p
    | TyTuple [] -> typeof<System.ValueTuple>
    | TyTuple [x] -> recur x
    | TyTuple xs ->
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
    | TyFunction (ps, r, _isAsync) ->
        let paramTys = ps |> List.map recur |> List.toArray
        let isUnit =
            match r with TyPrim PtUnit | TyPrim PtNever -> true | _ -> false
        if isUnit then
            match paramTys.Length with
            | 0 -> typeof<System.Action>
            | 1 -> typedefof<System.Action<_>>.MakeGenericType(paramTys)
            | 2 -> typedefof<System.Action<_,_>>.MakeGenericType(paramTys)
            | 3 -> typedefof<System.Action<_,_,_>>.MakeGenericType(paramTys)
            | 4 -> typedefof<System.Action<_,_,_,_>>.MakeGenericType(paramTys)
            | n -> failwithf "TypeMap: Action<%d> not supported" n
        else
            let retTy = recur r
            let allTys = Array.append paramTys [| retTy |]
            match allTys.Length with
            | 1 -> typedefof<System.Func<_>>.MakeGenericType(allTys)
            | 2 -> typedefof<System.Func<_,_>>.MakeGenericType(allTys)
            | 3 -> typedefof<System.Func<_,_,_>>.MakeGenericType(allTys)
            | 4 -> typedefof<System.Func<_,_,_,_>>.MakeGenericType(allTys)
            | 5 -> typedefof<System.Func<_,_,_,_,_>>.MakeGenericType(allTys)
            | n -> failwithf "TypeMap: Func<%d> not supported" n
    | TyUser (id, args)  ->
        match lookup id with
        | Some t ->
            // Reified generic types: when the user mentions
            // `Option[Int]`, `t` is the open generic definition; the
            // real CLR type is `t.MakeGenericType(int32)`.
            if List.isEmpty args || not t.IsGenericTypeDefinition
            then t
            else
                let argTys = args |> List.map recur |> List.toArray
                t.MakeGenericType argTys
        | None   -> typeof<obj>
    | TySelf          -> typeof<obj>
    | TyVar name      ->
        match Map.tryFind name genericSubst with
        | Some t -> t
        | None   -> typeof<obj>      // erasure fallback for unbound vars
    | TyError         -> typeof<obj>

/// Back-compat overload that erases every `TyVar` to `obj`.
let toClrTypeWith (lookup: TypeId -> ClrType option) (t: Type) : ClrType =
    toClrTypeWithGenerics lookup Map.empty t

/// Convenience overload that knows nothing about user types — every
/// `TyUser` lowers to `obj`. Kept for tests / call sites that
/// haven't built a TypeId map yet.
let toClrType (t: Type) : ClrType =
    toClrTypeWith (fun _ -> None) t

/// CLR return-type for a Lyric type. Differs from `toClrType` only
/// for `Unit` and `Never`, which lower to `void` at the return slot.
let toClrReturnTypeWithGenerics
        (lookup: TypeId -> ClrType option)
        (genericSubst: Map<string, ClrType>)
        (t: Type) : ClrType =
    match t with
    | TyPrim PtUnit | TyPrim PtNever -> typeof<System.Void>
    | _ -> toClrTypeWithGenerics lookup genericSubst t

let toClrReturnTypeWith (lookup: TypeId -> ClrType option) (t: Type) : ClrType =
    toClrReturnTypeWithGenerics lookup Map.empty t

let toClrReturnType (t: Type) : ClrType =
    toClrReturnTypeWith (fun _ -> None) t

/// Whether a Lyric type lowers to a CLR `void`-shaped value (no
/// stack value to push at function exit).
let isVoidLike (t: Type) : bool =
    match t with
    | TyPrim PtUnit | TyPrim PtNever -> true
    | _ -> false
