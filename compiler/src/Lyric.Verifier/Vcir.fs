/// Lyric-VC IR (`15-phase-4-proof-plan.md` §6).
///
/// A typed first-order logic close to SMT-LIB v2.6.  The IR is
/// solver-agnostic: the SMT-LIB emitter (`Smt.fs`) is one back-end,
/// any future CVC5 back-end is another.
module Lyric.Verifier.Vcir

open Lyric.Lexer

/// Sorts (Lyric-VC types).
///
/// Maps from Lyric source types via `Theory.fs`.
type Sort =
    | SBool
    | SInt
    | SBitVec   of width: int
    | SFloat32
    | SFloat64
    | SString
    /// Algebraic datatypes — records, unions, enums, opaque types.
    /// The string is the datatype name as declared in source.
    | SDatatype of name: string * args: Sort list
    /// `slice[T]` — a finite array with a separate length.
    | SSlice    of element: Sort
    /// Uninterpreted sort, used for opaque protected-type refs and
    /// unmodelled resources.
    | SUninterp of name: string

module Sort =

    let rec display (s: Sort) : string =
        match s with
        | SBool                  -> "Bool"
        | SInt                   -> "Int"
        | SBitVec n              -> sprintf "BitVec[%d]" n
        | SFloat32               -> "Float32"
        | SFloat64               -> "Float64"
        | SString                -> "String"
        | SDatatype(name, [])    -> name
        | SDatatype(name, args)  ->
            sprintf "%s[%s]" name (args |> List.map display |> String.concat ", ")
        | SSlice e               -> sprintf "Slice[%s]" (display e)
        | SUninterp name         -> name

/// Built-in operators that the SMT emitter knows how to render.
type Builtin =
    /// Boolean
    | BOpAnd | BOpOr | BOpNot | BOpXor | BOpImplies | BOpIff
    /// Polymorphic equality
    | BOpEq  | BOpNeq
    /// Integer / bitvector
    | BOpAdd | BOpSub | BOpMul | BOpDiv | BOpMod | BOpNeg
    | BOpLt  | BOpLte | BOpGt  | BOpGte
    /// Slice (`length` is total over the slice sort)
    | BOpSliceLength
    | BOpSliceIndex
    /// If-then-else (carried as a builtin so the IR has uniform shape).
    | BOpIte

module Builtin =

    let display (b: Builtin) : string =
        match b with
        | BOpAnd -> "and" | BOpOr -> "or" | BOpNot -> "not"
        | BOpXor -> "xor" | BOpImplies -> "=>" | BOpIff -> "="
        | BOpEq  -> "="   | BOpNeq -> "distinct"
        | BOpAdd -> "+"   | BOpSub -> "-" | BOpMul -> "*"
        | BOpDiv -> "div" | BOpMod -> "mod" | BOpNeg -> "-"
        | BOpLt  -> "<"   | BOpLte -> "<=" | BOpGt -> ">" | BOpGte -> ">="
        | BOpSliceLength -> "slice.length"
        | BOpSliceIndex  -> "slice.select"
        | BOpIte         -> "ite"

/// Literal in IR position.  Distinguished from Lyric source literals
/// (which carry suffix metadata the IR doesn't need).
type Lit =
    | LBool   of bool
    | LInt    of int64
    | LFloat  of double
    | LString of string
    | LUnit

/// Terms.  Variables, literals, applications, let, ite, quantifiers.
///
/// Variables carry their sort so substitutions and pretty-printing
/// don't need a separate environment lookup.
type Term =
    | TVar     of name: string * sort: Sort
    | TLit     of value: Lit * sort: Sort
    | TBuiltin of op: Builtin * args: Term list
    /// Application of a user-defined function symbol (free or
    /// declared in the package contract surface).  The `result`
    /// sort is the declared return sort.
    | TApp     of name: string * args: Term list * result: Sort
    | TLet     of bindings: (string * Term) list * body: Term
    | TIte     of cond: Term * thenT: Term * elseT: Term
    | TForall  of binders: (string * Sort) list * triggers: Term list list * body: Term
    | TExists  of binders: (string * Sort) list * body: Term

module Term =

    let mkAnd (xs: Term list) : Term =
        match xs with
        | []  -> TLit(LBool true,  SBool)
        | [x] -> x
        | _   -> TBuiltin(BOpAnd, xs)

    let mkOr (xs: Term list) : Term =
        match xs with
        | []  -> TLit(LBool false, SBool)
        | [x] -> x
        | _   -> TBuiltin(BOpOr, xs)

    let mkImplies (p: Term) (q: Term) : Term =
        TBuiltin(BOpImplies, [p; q])

    let mkNot (p: Term) : Term =
        TBuiltin(BOpNot, [p])

    let trueT : Term  = TLit(LBool true,  SBool)
    let falseT : Term = TLit(LBool false, SBool)

    /// True when the term has no `TVar` references — useful for the
    /// trivial discharger.
    let rec isClosed (t: Term) : bool =
        match t with
        | TVar _ -> false
        | TLit _ -> true
        | TBuiltin(_, xs) -> xs |> List.forall isClosed
        | TApp(_, xs, _)  -> xs |> List.forall isClosed
        | TLet(bs, b)     -> (bs |> List.forall (snd >> isClosed)) && isClosed b
        | TIte(c, a, b)   -> isClosed c && isClosed a && isClosed b
        | TForall(_, _, b) | TExists(_, b) -> isClosed b

    /// Sort-of (best-effort).  Variables and literals carry their
    /// sort directly; applications are uniform on builtins.  Used by
    /// the pretty-printer.
    let rec sortOf (t: Term) : Sort =
        match t with
        | TVar(_, s)
        | TLit(_, s) -> s
        | TBuiltin(b, args) ->
            match b with
            | BOpAnd | BOpOr | BOpNot | BOpXor | BOpImplies | BOpIff
            | BOpEq  | BOpNeq | BOpLt  | BOpLte | BOpGt  | BOpGte -> SBool
            | BOpAdd | BOpSub | BOpMul | BOpDiv | BOpMod | BOpNeg ->
                match args with x :: _ -> sortOf x | [] -> SInt
            | BOpSliceLength -> SInt
            | BOpSliceIndex  ->
                match args with x :: _ ->
                                  match sortOf x with
                                  | SSlice e -> e
                                  | _        -> SInt
                                | _ -> SInt
            | BOpIte ->
                match args with _ :: a :: _ -> sortOf a | _ -> SBool
        | TApp(_, _, s) -> s
        | TLet(_, b)    -> sortOf b
        | TIte(_, a, _) -> sortOf a
        | TForall _ | TExists _ -> SBool

    /// Capture-avoiding substitution.  Variable renaming on capture
    /// uses a numeric suffix.
    let rec subst (env: Map<string, Term>) (t: Term) : Term =
        match t with
        | TVar(name, _) ->
            match Map.tryFind name env with
            | Some replacement -> replacement
            | None             -> t
        | TLit _ -> t
        | TBuiltin(op, args)  -> TBuiltin(op, args |> List.map (subst env))
        | TApp(name, args, s) -> TApp(name, args |> List.map (subst env), s)
        | TLet(bs, body) ->
            let bs' = bs |> List.map (fun (n, e) -> n, subst env e)
            let env' = bs |> List.fold (fun acc (n, _) -> Map.remove n acc) env
            TLet(bs', subst env' body)
        | TIte(c, a, b) -> TIte(subst env c, subst env a, subst env b)
        | TForall(binders, triggers, body) ->
            let env' = binders |> List.fold (fun acc (n, _) -> Map.remove n acc) env
            TForall(binders, triggers |> List.map (List.map (subst env')), subst env' body)
        | TExists(binders, body) ->
            let env' = binders |> List.fold (fun acc (n, _) -> Map.remove n acc) env
            TExists(binders, subst env' body)

/// Origin of a verification condition — the source-level tag that
/// produced it.  `15-phase-4-proof-plan.md` §6 lists these.
type GoalKind =
    | GKPrecondition       of fnName: string
    | GKPostcondition      of fnName: string
    | GKReturnInvariant    of typeName: string
    | GKConstructionInv    of typeName: string
    | GKLoopEstablish
    | GKLoopPreserve
    | GKLoopConclude
    | GKAssertion
    | GKRangeBound

module GoalKind =

    let display (k: GoalKind) : string =
        match k with
        | GKPrecondition  fn        -> sprintf "precondition of %s" fn
        | GKPostcondition fn        -> sprintf "postcondition of %s" fn
        | GKReturnInvariant   tn    -> sprintf "return-invariant of %s" tn
        | GKConstructionInv   tn    -> sprintf "construction invariant of %s" tn
        | GKLoopEstablish           -> "loop invariant (establish)"
        | GKLoopPreserve            -> "loop invariant (preserve)"
        | GKLoopConclude            -> "loop invariant (conclude)"
        | GKAssertion               -> "user assertion"
        | GKRangeBound              -> "range-subtype bound"

/// A free symbol the goal references — declared at the top of the
/// SMT-LIB file as `(declare-fun ...)`.
type SymbolDecl =
    | UserFun  of name: string * paramSorts: Sort list * resultSort: Sort
    | Datatype of name: string * constructors: (string * (string * Sort) list) list

/// A discharged proof obligation.
type Goal =
    { Hypotheses: Term list
      Conclusion: Term
      Symbols:    SymbolDecl list
      Origin:     Span
      Kind:       GoalKind
      Label:      string }

module Goal =

    /// The goal's *raw* claim: hypotheses imply conclusion.  This is
    /// what the SMT solver receives (negated for `unsat` query).
    let asImplication (g: Goal) : Term =
        Term.mkImplies (Term.mkAnd g.Hypotheses) g.Conclusion
