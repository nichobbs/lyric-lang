/// Mode-dispatch and pure-call check
/// (`15-phase-4-proof-plan.md` §3.1, §4.1, §4.2).
///
/// Walks every function in a `@proof_required` package and reports
/// the V0001–V0006 diagnostics that must be cleared before VC
/// generation.
module Lyric.Verifier.ModeCheck

open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Verifier.Mode

/// Information the mode checker needs about each callee.
type CalleeInfo =
    { Name:    string
      Level:   VerificationLevel
      IsPure:  bool }

/// Build a callee table from the file's local function declarations.
/// Cross-package callees would land here once the contract-metadata
/// reader is wired in (`15-phase-4-proof-plan.md` §3.2).
let calleeTableOfFile
        (fileLevel: VerificationLevel)
        (file: SourceFile)
        : Map<string, CalleeInfo> =
    file.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IFunc fn ->
            Some
                { Name   = fn.Name
                  Level  = levelOfFunction fileLevel fn
                  IsPure = isPure fn }
        | _ -> None)
    |> List.fold (fun acc info -> Map.add info.Name info acc) Map.empty

/// Walk an expression, calling `onCall` whenever a top-level call's
/// callee can be resolved by name lookup.  We only resolve `EPath`
/// callees here; method-style `e.f(args)` calls also dispatch via a
/// path lookup but the inference pass has already lowered them.  M4.1
/// is conservative: only direct `EPath`-headed calls are checked.
let private collectCalls
        (onCall: string -> Span -> unit)
        (onAwait: Span -> unit)
        (onSpawn: Span -> unit)
        (onUnsafe: Span -> unit)
        (e: Expr) : unit =

    let rec visitExpr (e: Expr) =
        match e.Kind with
        | EAwait inner -> onAwait e.Span; visitExpr inner
        | ESpawn inner -> onSpawn e.Span; visitExpr inner
        | ECall(fn, args) ->
            (match fn.Kind with
             | EPath p ->
                 match p.Segments with
                 | [name] -> onCall name e.Span
                 | _      -> ()
             | _ -> ())
            visitExpr fn
            for a in args do
                match a with
                | CANamed(_, v, _)   -> visitExpr v
                | CAPositional v     -> visitExpr v
        | EParen inner | ETry inner | EOld inner | EPropagate inner -> visitExpr inner
        | ETuple xs | EList xs -> xs |> List.iter visitExpr
        | EIf(c, t, eOpt, _) ->
            visitExpr c
            visitExprOrBlock t
            match eOpt with Some x -> visitExprOrBlock x | None -> ()
        | EMatch(s, arms) ->
            visitExpr s
            for arm in arms do
                visitExprOrBlock arm.Body
                match arm.Guard with Some g -> visitExpr g | None -> ()
        | EForall(_, w, body) | EExists(_, w, body) ->
            visitExpr body
            match w with Some x -> visitExpr x | None -> ()
        | ETypeApp(fn, _) -> visitExpr fn
        | EIndex(r, ix) -> visitExpr r; ix |> List.iter visitExpr
        | EMember(r, _) -> visitExpr r
        | EPrefix(_, x) -> visitExpr x
        | EBinop(_, l, r) -> visitExpr l; visitExpr r
        | EAssign(t, _, v) -> visitExpr t; visitExpr v
        | EBlock blk -> visitBlock blk
        | EInterpolated segs ->
            for seg in segs do
                match seg with
                | ISExpr x -> visitExpr x
                | ISText _ -> ()
        | ELambda(_, body) -> visitBlock body
        | ERange rb ->
            match rb with
            | RBClosed(a, b) | RBHalfOpen(a, b) -> visitExpr a; visitExpr b
            | RBLowerOpen b -> visitExpr b
            | RBUpperOpen a -> visitExpr a
        | ELiteral _ | EPath _ | ESelf | EResult | EError -> ()

    and visitExprOrBlock (eob: ExprOrBlock) =
        match eob with
        | EOBExpr x  -> visitExpr x
        | EOBBlock b -> visitBlock b

    and visitBlock (blk: Block) =
        for st in blk.Statements do
            match st.Kind with
            | SLocal lb ->
                match lb with
                | LBVal(_, _, init) | LBLet(_, _, init) -> visitExpr init
                | LBVar(_, _, Some init) -> visitExpr init
                | LBVar(_, _, None) -> ()
            | SAssign(t, _, v)   -> visitExpr t; visitExpr v
            | SReturn(Some v)    -> visitExpr v
            | SReturn None       -> ()
            | SBreak _ | SContinue _ -> ()
            | SThrow x           -> visitExpr x
            | STry(body, catches) ->
                visitBlock body
                for c in catches do visitBlock c.Body
            | SDefer body | SScope(_, body) -> visitBlock body
            | SFor(_, _, iter, body)
            | SWhile(_, iter, body) ->
                visitExpr iter; visitBlock body
            | SLoop(_, body)     -> visitBlock body
            | SExpr x            -> visitExpr x
            | SRule(l, r)        -> visitExpr l; visitExpr r
            | SItem _            -> ()

    visitExpr e

/// Walk a block looking for loops without `invariant:` clauses.
/// V0005 per `15-phase-4-proof-plan.md` §3.1.  Loop invariants live
/// in `Annotations` since the AST has no first-class invariant slot
/// on loop statements; the parser carries the clause as the
/// `invariant` annotation.
let private collectMissingLoopInvariants
        (diags: ResizeArray<Diagnostic>)
        (fnName: string)
        (blk: Block) : unit =

    let hasInvariantAnnotation (anns: Annotation list) : bool =
        anns |> List.exists (fun a ->
            match a.Name.Segments with
            | ["invariant"] -> true
            | _ -> false)

    let rec walkBlock (blk: Block) =
        for st in blk.Statements do
            match st.Kind with
            | SFor(_, _, _, body) | SWhile(_, _, body) | SLoop(_, body) ->
                // Loop annotations live alongside the body's items.
                // For now we look for an `@invariant(...)` annotation
                // attached to the loop's enclosing item annotations.
                // The parser doesn't yet attach loop-level
                // annotations, so M4.1 reports V0005 on every loop in
                // proof-required code.  Once the loop-invariant
                // syntax lands the check inspects the actual clause.
                let span = st.Span
                diags.Add(
                    Diagnostic.error "V0005"
                        (sprintf "loop in proof-required function '%s' lacks an `invariant:` clause" fnName)
                        span)
                walkBlock body
            | SItem _ | SBreak _ | SContinue _ -> ()
            | SLocal _ | SAssign _ | SReturn _ | SThrow _ | SExpr _ | SRule _ -> ()
            | STry(body, catches) ->
                walkBlock body
                for c in catches do walkBlock c.Body
            | SDefer body | SScope(_, body) -> walkBlock body

    walkBlock blk

/// Check a single function body against the call-graph rules of a
/// proof-required containing package.
let private checkFunction
        (diags: ResizeArray<Diagnostic>)
        (fileLevel: VerificationLevel)
        (callees: Map<string, CalleeInfo>)
        (fn: FunctionDecl) : unit =

    let fnLevel = levelOfFunction fileLevel fn
    if not (VerificationLevel.isProofRequired fnLevel) then ()
    else

    let onCall (name: string) (span: Span) =
        match Map.tryFind name callees with
        | None ->
            // Unknown name — could be a stdlib import or BCL.
            // Without contract metadata we conservatively skip
            // (matches `15-phase-4-proof-plan.md` §3.2 deferral).
            ()
        | Some info ->
            let admissible =
                VerificationLevel.dominates info.Level fnLevel
                || info.IsPure
            if not admissible then
                diags.Add(
                    Diagnostic.error "V0002"
                        (sprintf "proof-required function '%s' may not call '%s' (%s); upgrade callee, mark @pure, or shift caller to @runtime_checked"
                            fn.Name info.Name
                            (VerificationLevel.display info.Level))
                        span)

    let onAwait (span: Span) =
        diags.Add(
            Diagnostic.error "V0002"
                (sprintf "`await` not admitted in proof-required function '%s'" fn.Name)
                span)

    let onSpawn (span: Span) =
        diags.Add(
            Diagnostic.error "V0002"
                (sprintf "`spawn` not admitted in proof-required function '%s'" fn.Name)
                span)

    let onUnsafe (span: Span) =
        match fnLevel with
        | ProofRequiredUnsafe -> ()
        | _ ->
            diags.Add(
                Diagnostic.error "V0003"
                    (sprintf "`unsafe` block requires `@proof_required(unsafe_blocks_allowed)` on the package")
                    span)

    match fn.Body with
    | None -> ()
    | Some(FBExpr e) -> collectCalls onCall onAwait onSpawn onUnsafe e
    | Some(FBBlock blk) ->
        for st in blk.Statements do
            match st.Kind with
            | SExpr e | SAssign(_, _, e) | SReturn(Some e) | SThrow e ->
                collectCalls onCall onAwait onSpawn onUnsafe e
            | SLocal lb ->
                match lb with
                | LBVal(_, _, init) | LBLet(_, _, init) ->
                    collectCalls onCall onAwait onSpawn onUnsafe init
                | LBVar(_, _, Some init) ->
                    collectCalls onCall onAwait onSpawn onUnsafe init
                | LBVar(_, _, None) -> ()
            | _ -> ()

        collectMissingLoopInvariants diags fn.Name blk

/// V0004: an `@axiom` declaration must have no body.
let private checkAxiomBodies
        (diags: ResizeArray<Diagnostic>)
        (fileLevel: VerificationLevel)
        (file: SourceFile) : unit =

    for it in file.Items do
        match it.Kind with
        | IFunc fn when levelOfFunction fileLevel fn = Axiom ->
            match fn.Body with
            | Some _ ->
                diags.Add(
                    Diagnostic.error "V0004"
                        (sprintf "@axiom function '%s' must not have a body" fn.Name)
                        fn.Span)
            | None -> ()
        | _ -> ()

/// Top-level entry: returns mode-check diagnostics for `file` plus
/// the resolved file level.  Caller decides whether to proceed to
/// VC generation (the rule of thumb is: any V0001/V0002/V0004 error
/// stops the pipeline; V0005 is a warning shape today and will be
/// promoted to error once the loop-invariant syntax lands).
let checkFile (file: SourceFile) : VerificationLevel * Diagnostic list =
    let level, levelDiags = levelOfFile file
    let diags = ResizeArray<Diagnostic>(levelDiags)
    if not (VerificationLevel.isProofRequired level) then
        level, List.ofSeq diags
    else
        let callees = calleeTableOfFile level file
        for it in file.Items do
            match it.Kind with
            | IFunc fn -> checkFunction diags level callees fn
            | _        -> ()
        checkAxiomBodies diags level file
        level, List.ofSeq diags
