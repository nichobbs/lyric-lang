/// SMT-LIB v2.6 emitter for the Lyric-VC IR.
///
/// (`15-phase-4-proof-plan.md` §7.2)  Targets Z3 by default; CVC5 is
/// expected to consume the same output without modification (modulo
/// the AOT-mode caveat documented in §7.1).
module Lyric.Verifier.Smt

open System.Text
open Lyric.Verifier.Vcir

let rec private renderSort (s: Sort) : string =
    match s with
    | SBool       -> "Bool"
    | SInt        -> "Int"
    | SBitVec n   -> sprintf "(_ BitVec %d)" n
    | SFloat32    -> "Float32"
    | SFloat64    -> "Float64"
    | SString     -> "String"
    | SDatatype("Unit", []) -> "Unit"
    | SDatatype(name, []) -> name
    | SDatatype(name, args) ->
        sprintf "(%s %s)" name
            (args |> List.map renderSort |> String.concat " ")
    | SSlice e    -> sprintf "(Array Int %s)" (renderSort e)
    | SUninterp n -> sanitizeIdent n

and private sanitizeIdent (s: string) : string =
    let sb = StringBuilder()
    for c in s do
        if System.Char.IsLetterOrDigit c || c = '_' || c = '.' then
            sb.Append c |> ignore
        else
            sb.Append '_' |> ignore
    sb.ToString()

let private renderLit (lit: Lit) : string =
    match lit with
    | LBool true   -> "true"
    | LBool false  -> "false"
    | LInt n when n < 0L -> sprintf "(- %d)" (- n)
    | LInt n       -> string n
    | LFloat f     -> sprintf "%s" (string f)
    | LString s    -> sprintf "\"%s\"" (s.Replace("\"", "\"\""))
    | LUnit        -> "unit"

let rec private renderTerm (t: Term) : string =
    match t with
    | TVar(name, _) -> sanitizeIdent name
    | TLit(lit, _)  -> renderLit lit
    | TBuiltin(op, [x]) when op = BOpNot ->
        sprintf "(not %s)" (renderTerm x)
    | TBuiltin(op, [x]) when op = BOpNeg ->
        sprintf "(- %s)" (renderTerm x)
    | TBuiltin(BOpSliceLength, [x]) ->
        sprintf "(slice.length %s)" (renderTerm x)
    | TBuiltin(BOpSliceIndex, [arr; idx]) ->
        sprintf "(select %s %s)" (renderTerm arr) (renderTerm idx)
    | TBuiltin(op, args) ->
        sprintf "(%s %s)"
            (Builtin.display op)
            (args |> List.map renderTerm |> String.concat " ")
    | TApp(name, [], _)   -> sanitizeIdent name
    | TApp(name, args, _) ->
        sprintf "(%s %s)"
            (sanitizeIdent name)
            (args |> List.map renderTerm |> String.concat " ")
    | TLet(bs, body) ->
        let binds =
            bs
            |> List.map (fun (n, e) ->
                sprintf "(%s %s)" (sanitizeIdent n) (renderTerm e))
            |> String.concat " "
        sprintf "(let (%s) %s)" binds (renderTerm body)
    | TIte(c, a, b) ->
        sprintf "(ite %s %s %s)" (renderTerm c) (renderTerm a) (renderTerm b)
    | TForall(binders, _, body) ->
        let bs =
            binders
            |> List.map (fun (n, s) ->
                sprintf "(%s %s)" (sanitizeIdent n) (renderSort s))
            |> String.concat " "
        sprintf "(forall (%s) %s)" bs (renderTerm body)
    | TExists(binders, body) ->
        let bs =
            binders
            |> List.map (fun (n, s) ->
                sprintf "(%s %s)" (sanitizeIdent n) (renderSort s))
            |> String.concat " "
        sprintf "(exists (%s) %s)" bs (renderTerm body)

/// Free variables of a term: every `TVar` not introduced by a binder.
let private freeVars (t: Term) : (string * Sort) list =
    let mutable bound : Set<string> = Set.empty
    let result = ResizeArray<string * Sort>()
    let seen = System.Collections.Generic.HashSet<string>()
    let rec go (t: Term) =
        match t with
        | TVar(name, sort) ->
            if not (Set.contains name bound) && seen.Add name then
                result.Add(name, sort)
        | TLit _ -> ()
        | TBuiltin(_, args) | TApp(_, args, _) ->
            args |> List.iter go
        | TLet(bs, body) ->
            for (_, e) in bs do go e
            let prevBound = bound
            for (n, _) in bs do bound <- Set.add n bound
            go body
            bound <- prevBound
        | TIte(c, a, b) -> go c; go a; go b
        | TForall(binders, _, body) | TExists(binders, body) ->
            let prevBound = bound
            for (n, _) in binders do bound <- Set.add n bound
            go body
            bound <- prevBound
    go t
    List.ofSeq result

/// Render a SMT-LIB session preamble: the logic + option +
/// `Unit` datatype.  Sent once per persistent z3 session
/// (decision 5c) and shared across goals.
let renderPreamble () : string =
    let sb = StringBuilder()
    sb.Append "(set-logic ALL)\n" |> ignore
    sb.Append "(set-option :produce-models true)\n" |> ignore
    sb.Append "(declare-datatypes ((Unit 0)) (((unit))))\n" |> ignore
    sb.ToString()

/// Render the goal-scoped block: shared symbol declarations,
/// per-goal `declare-const` for free variables, and the negated-
/// implication assert.  Wrapped in `(push)` / `(pop)` by the
/// caller so the persistent z3 context can discharge the next
/// goal cleanly.
///
/// `declaredSymbols` is the set of symbol names already emitted
/// in this session — datatypes / declare-fun lines for symbols in
/// that set are skipped.  Returns the new set after this goal's
/// declarations are added.
let renderGoalBlock
        (declaredSymbols: Set<string>)
        (g: Goal) : string * Set<string> =
    let sb = StringBuilder()
    let appendln (s: string) = sb.Append(s).Append('\n') |> ignore

    appendln (sprintf "; goal: %s" g.Label)
    appendln (sprintf "; kind: %s" (GoalKind.display g.Kind))

    let mutable declared = declaredSymbols
    // Declarations that are stable across goals (datatypes,
    // declare-fun for user symbols) live *outside* the push so
    // they remain in scope after pop.  Idempotency by name.
    for sym in g.Symbols do
        match sym with
        | UserFun(name, paramSorts, resultSort) ->
            let key = "fun:" + name
            if not (Set.contains key declared) then
                declared <- Set.add key declared
                let paramText =
                    paramSorts |> List.map renderSort |> String.concat " "
                appendln (sprintf "(declare-fun %s (%s) %s)"
                            (sanitizeIdent name) paramText (renderSort resultSort))
        | Datatype(name, ctors) ->
            let key = "dt:" + name
            if not (Set.contains key declared) then
                declared <- Set.add key declared
                let ctorText =
                    ctors
                    |> List.map (fun (cname, fields) ->
                        let fieldText =
                            fields
                            |> List.map (fun (fname, fsort) ->
                                sprintf "(%s %s)"
                                    (sanitizeIdent fname)
                                    (renderSort fsort))
                            |> String.concat " "
                        sprintf "(%s %s)" (sanitizeIdent cname) fieldText)
                    |> String.concat " "
                appendln (sprintf "(declare-datatypes ((%s 0)) ((%s)))"
                            (sanitizeIdent name) ctorText)

    // Per-goal section: push, declare-const free variables, assert,
    // check-sat + get-model, pop.
    appendln "(push 1)"
    let claim = Goal.asImplication g
    let frees = freeVars claim
    for (name, sort) in frees do
        appendln (sprintf "(declare-const %s %s)"
                    (sanitizeIdent name) (renderSort sort))
    appendln (sprintf "(assert (not %s))" (renderTerm claim))
    appendln "(check-sat)"
    appendln "(get-model)"
    appendln "(pop 1)"

    sb.ToString(), declared

/// Render a single goal as a self-contained SMT-LIB v2.6 file.
/// Used by the `--proof-dir` writer (so each goal lives in its own
/// `.smt2` file) and by the per-goal subprocess fallback when no
/// persistent session is in use.
let renderGoal (g: Goal) : string =
    let preamble = renderPreamble ()
    let body, _ = renderGoalBlock Set.empty g
    preamble + body
