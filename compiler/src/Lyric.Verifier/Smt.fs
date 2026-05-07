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
    // Float32/Float64 are mapped to SMT Real for proof purposes.
    // This treats Lyric doubles as mathematical reals (sound
    // approximation for invariant reasoning; avoids the full
    // IEEE-754 FP theory and its rounding-mode complexity).
    | SFloat32    -> "Real"
    | SFloat64    -> "Real"
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

/// Every name that a set of symbol declarations introduces into the
/// SMT namespace (constructor names, selector names, user-fun names).
/// A free variable whose name collides with one of these would cause
/// Z3 to report "ambiguous constant reference" even when arities
/// differ, so we rename such variables by appending "$p".
let private datatypeReservedNames (symbols: SymbolDecl list) : Set<string> =
    symbols
    |> List.collect (fun sym ->
        match sym with
        | Datatype(typeName, ctors) ->
            typeName
            :: (ctors |> List.collect (fun (ctorName, fields) ->
                    ctorName :: (fields |> List.map fst)))
        | UserFun(name, _, _) -> [name])
    |> Set.ofList

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
///
/// `sessionGlobalNames` is the accumulated set of constructor/
/// selector/user-fun names that have been declared OUTSIDE push/pop
/// in this session (i.e. they persist across goals in Z3's global
/// context).  Free variables whose names collide with any of these
/// names must also be renamed, not just those colliding with the
/// current goal's own symbols.  Returns the updated set that includes
/// names introduced by this goal's new declarations.
let renderGoalBlock
        (declaredSymbols: Set<string>)
        (sessionGlobalNames: Set<string>)
        (g: Goal) : string * Set<string> * Set<string> =
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
    let claim0 = Goal.asImplication g
    // Rename free variables that clash with datatype/selector names to
    // avoid Z3 "ambiguous constant reference" errors (Z3 treats a
    // declare-const with the same name as a selector as ambiguous even
    // though the arities differ).  Append "$p" to conflicting names.
    //
    // In a persistent session, datatypes declared by earlier goals
    // remain in Z3's global context (they are emitted outside push/pop).
    // We must check sessionGlobalNames (from prior goals) in addition to
    // the current goal's own symbols so cross-goal selector collisions
    // are also renamed.
    let reserved =
        Set.union sessionGlobalNames (datatypeReservedNames g.Symbols)
    let frees0 = freeVars claim0
    let renamingMap =
        frees0
        |> List.choose (fun (n, s) ->
            if Set.contains n reserved then Some (n, TVar(n + "$p", s))
            else None)
        |> Map.ofList
    let claim, frees =
        if Map.isEmpty renamingMap then claim0, frees0
        else
            let claim' = Term.subst renamingMap claim0
            let frees' =
                frees0
                |> List.map (fun (n, s) ->
                    match Map.tryFind n renamingMap with
                    | Some (TVar(n2, _)) -> n2, s
                    | _                  -> n, s)
            claim', frees'
    for (name, sort) in frees do
        appendln (sprintf "(declare-const %s %s)"
                    (sanitizeIdent name) (renderSort sort))
    appendln (sprintf "(assert (not %s))" (renderTerm claim))
    appendln "(check-sat)"
    appendln "(get-model)"
    appendln "(pop 1)"

    // Return accumulated session-global names including the new ones
    // declared outside push/pop by this goal.
    let sessionGlobalNames' =
        Set.union sessionGlobalNames (datatypeReservedNames g.Symbols)
    sb.ToString(), declared, sessionGlobalNames'

/// Render a single goal as a self-contained SMT-LIB v2.6 file.
/// Used by the `--proof-dir` writer (so each goal lives in its own
/// `.smt2` file) and by the per-goal subprocess fallback when no
/// persistent session is in use.
let renderGoal (g: Goal) : string =
    let preamble = renderPreamble ()
    let body, _, _ = renderGoalBlock Set.empty Set.empty g
    preamble + body
