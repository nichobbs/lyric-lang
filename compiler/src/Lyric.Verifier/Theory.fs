/// Theory mapping: Lyric source types -> Lyric-VC sorts, Lyric
/// expression operators -> Vcir.Builtin (`15-phase-4-proof-plan.md`
/// §5.2).
module Lyric.Verifier.Theory

open Lyric.Parser.Ast
open Lyric.Verifier.Vcir

/// Range-subtype bound discovered during sort lookup.  Range subtypes
/// lift to `SInt` with a hypothesis that the value is in [lo, hi].
type RangeBoundKind =
    | RBKClosed   of lo: int64 * hi: int64
    | RBKHalfOpen of lo: int64 * hi: int64
    | RBKNone

/// Resolved sort plus optional range bound.  The VC generator
/// emits the bound as a hypothesis on every binder of this sort.
type SortInfo =
    { Sort:  Sort
      Range: RangeBoundKind }

let private sortInfoNoRange (s: Sort) : SortInfo =
    { Sort = s; Range = RBKNone }

/// Map a primitive type *name* (the leaf name of a `TRef`) to a sort.
let primitiveSort (name: string) : SortInfo option =
    match name with
    | "Bool"   -> Some (sortInfoNoRange SBool)
    | "Int"    -> Some (sortInfoNoRange SInt)
    | "Long"   -> Some (sortInfoNoRange SInt)
    | "Nat"    -> Some { Sort = SInt; Range = RBKClosed(0L, System.Int64.MaxValue) }
    | "UInt"   -> Some (sortInfoNoRange (SBitVec 32))
    | "ULong"  -> Some (sortInfoNoRange (SBitVec 64))
    | "Byte"   -> Some (sortInfoNoRange (SBitVec 8))
    | "Float"  -> Some (sortInfoNoRange SFloat32)
    | "Double" -> Some (sortInfoNoRange SFloat64)
    | "String" -> Some (sortInfoNoRange SString)
    | "Unit"   -> Some (sortInfoNoRange (SDatatype("Unit", [])))
    | _        -> None

/// Map a TypeExpr to a sort, falling back to an uninterpreted sort
/// for anything we don't yet model (M4.1 limitation).
let rec sortOfTypeExpr (t: TypeExpr) : SortInfo =
    match t.Kind with
    | TRef path ->
        match path.Segments with
        | [name] ->
            primitiveSort name
            |> Option.defaultValue { Sort = SDatatype(name, []); Range = RBKNone}
        | segs ->
            let leaf = List.last segs
            primitiveSort leaf
            |> Option.defaultValue { Sort = SDatatype(leaf, []); Range = RBKNone}
    | TGenericApp(head, args) ->
        let argSorts =
            args |> List.choose (fun ta ->
                match ta with
                | TAType te -> Some (sortOfTypeExpr te).Sort
                | TAValue _ -> None)
        let leaf =
            match head.Segments with
            | xs when not (List.isEmpty xs) -> List.last xs
            | _ -> "?"
        sortInfoNoRange (SDatatype(leaf, argSorts))
    | TArray(_, elt)
    | TSlice elt ->
        sortInfoNoRange (SSlice (sortOfTypeExpr elt).Sort)
    | TRefined(underlying, range) ->
        // `Int range a ..= b` lifts to SInt + a closed range hypothesis.
        let baseSort =
            match underlying.Segments with
            | [name] ->
                primitiveSort name
                |> Option.map (fun si -> si.Sort)
                |> Option.defaultValue SInt
            | _ -> SInt
        let rb =
            match constFoldRangeBound range with
            | Some bound -> bound
            | None       -> RBKNone
        { Sort = baseSort; Range = rb }
    | TTuple elts ->
        let sorts = elts |> List.map (sortOfTypeExpr >> fun si -> si.Sort)
        sortInfoNoRange (SDatatype("Tuple", sorts))
    | TNullable inner ->
        let inner' = (sortOfTypeExpr inner).Sort
        sortInfoNoRange (SDatatype("Option", [inner']))
    | TFunction(_, _) ->
        sortInfoNoRange (SUninterp "Function")
    | TUnit ->
        sortInfoNoRange (SDatatype("Unit", []))
    | TSelf ->
        sortInfoNoRange (SUninterp "Self")
    | TNever ->
        sortInfoNoRange (SUninterp "Never")
    | TParen inner ->
        sortOfTypeExpr inner
    | TError ->
        sortInfoNoRange (SUninterp "Error")

and private constFoldRangeBound (rb: RangeBound) : RangeBoundKind option =
    let foldExpr (e: Expr) : int64 option =
        match e.Kind with
        | ELiteral (Literal.LInt(v, _))                     -> Some (int64 v)
        | EPrefix(PreNeg, { Kind = ELiteral (Literal.LInt(v, _)) }) -> Some (- int64 v)
        | _ -> None
    match rb with
    | RBClosed(lo, hi) ->
        match foldExpr lo, foldExpr hi with
        | Some a, Some b -> Some (RBKClosed(a, b))
        | _              -> None
    | RBHalfOpen(lo, hi) ->
        match foldExpr lo, foldExpr hi with
        | Some a, Some b -> Some (RBKHalfOpen(a, b))
        | _              -> None
    | RBLowerOpen _ | RBUpperOpen _ -> None

/// Map a Lyric source binary operator to a Vcir.Builtin, where the
/// operator is part of the contract sub-language.  Returns `None`
/// for operators that have no proof-side meaning (e.g. `??`).
let builtinOfBinop (op: BinOp) : Builtin option =
    match op with
    | BAdd      -> Some BOpAdd
    | BSub      -> Some BOpSub
    | BMul      -> Some BOpMul
    | BDiv      -> Some BOpDiv
    | BMod      -> Some BOpMod
    | BAnd      -> Some BOpAnd
    | BOr       -> Some BOpOr
    | BXor      -> Some BOpXor
    | BEq       -> Some BOpEq
    | BNeq      -> Some BOpNeq
    | BLt       -> Some BOpLt
    | BLte      -> Some BOpLte
    | BGt       -> Some BOpGt
    | BGte      -> Some BOpGte
    | BImplies  -> Some BOpImplies
    | BCoalesce -> None

let builtinOfPrefix (op: PrefixOp) : Builtin option =
    match op with
    | PreNeg -> Some BOpNeg
    | PreNot -> Some BOpNot
    | PreRef -> None

/// Range-bound hypothesis for a binder of the given sort/range,
/// attached to a `TVar` of the given name.  Returns `[]` if no
/// bound is known.
let rangeHypotheses (binder: string) (info: SortInfo) : Term list =
    match info.Range with
    | RBKNone -> []
    | RBKClosed(lo, hi) ->
        let v = TVar(binder, info.Sort)
        [ TBuiltin(BOpLte, [ TLit(LInt lo, SInt); v ])
          TBuiltin(BOpLte, [ v; TLit(LInt hi, SInt) ]) ]
    | RBKHalfOpen(lo, hi) ->
        let v = TVar(binder, info.Sort)
        [ TBuiltin(BOpLte, [ TLit(LInt lo, SInt); v ])
          TBuiltin(BOpLt,  [ v; TLit(LInt hi, SInt) ]) ]
