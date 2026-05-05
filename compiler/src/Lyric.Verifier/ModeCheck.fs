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
        | EUnsafe blk -> onUnsafe e.Span; visitBlock blk
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
            | SInvariant x       -> visitExpr x
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

    // True when a loop body's first statements include at least
    // one `SInvariant` clause — the parser inserts these at the
    // head of the body for `while ... invariant: φ { ... }` syntax
    // (D-progress-086).
    let bodyHasInvariant (body: Block) : bool =
        body.Statements
        |> List.exists (fun s ->
            match s.Kind with SInvariant _ -> true | _ -> false)

    let rec walkBlock (blk: Block) =
        for st in blk.Statements do
            match st.Kind with
            | SFor(_, _, _, body) | SWhile(_, _, body) | SLoop(_, body) ->
                if not (bodyHasInvariant body) then
                    diags.Add(
                        Diagnostic.error "V0005"
                            (sprintf "loop in proof-required function '%s' lacks an `invariant:` clause" fnName)
                            st.Span)
                walkBlock body
            | SItem _ | SBreak _ | SContinue _ -> ()
            | SLocal _ | SAssign _ | SReturn _ | SThrow _ | SExpr _ | SRule _ -> ()
            | SInvariant _ -> ()
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

/// V0006: in proof-required code, a `forall`/`exists` must quantify
/// over a *finitely enumerable* domain
/// (`08-contract-semantics.md` §6.3, `15-phase-4-proof-plan.md` §3.1).
///
/// M4.1 enforcement: reject quantifiers whose binder type is `Int`,
/// `Long`, `Nat`, `Float`, `Double`, or `String` without a refinement.
/// Bounded slices, sets, enums, range subtypes, and `Bool` are
/// admissible.
let private checkQuantifierDomains
        (diags: ResizeArray<Diagnostic>)
        (fileLevel: VerificationLevel)
        (file: SourceFile) : unit =

    let isUnboundedDomain (te: TypeExpr) : bool =
        match te.Kind with
        | TRef p ->
            match p.Segments with
            | [name] ->
                match name with
                | "Int" | "Long" | "Nat" | "Float" | "Double" | "String"
                | "UInt" | "ULong" -> true
                | _ -> false
            | _ -> false
        | TGenericApp _ | TArray _ | TSlice _ -> false
        | TRefined _ -> false  // a range subtype: bounded
        | _ -> false

    let rec walkExpr (e: Expr) : unit =
        match e.Kind with
        | EForall(binders, where, body) | EExists(binders, where, body) ->
            for b in binders do
                if isUnboundedDomain b.Type then
                    diags.Add(
                        Diagnostic.error "V0006"
                            (sprintf "quantifier binder '%s' has unbounded domain in proof-required code; constrain to a slice, set, range subtype, or finite enum"
                                b.Name)
                            b.Span)
            (match where with Some w -> walkExpr w | None -> ())
            walkExpr body
        | EParen inner | EOld inner | ETry inner | EAwait inner
        | ESpawn inner | EPropagate inner -> walkExpr inner
        | ETuple xs | EList xs -> xs |> List.iter walkExpr
        | EIf(c, t, eOpt, _) ->
            walkExpr c
            walkExprOrBlock t
            (match eOpt with Some x -> walkExprOrBlock x | None -> ())
        | EMatch(s, arms) ->
            walkExpr s
            for arm in arms do
                walkExprOrBlock arm.Body
                match arm.Guard with Some g -> walkExpr g | None -> ()
        | ECall(fn, args) ->
            walkExpr fn
            for a in args do
                match a with
                | CANamed(_, v, _) | CAPositional v -> walkExpr v
        | ETypeApp(fn, _) -> walkExpr fn
        | EIndex(r, ix) -> walkExpr r; ix |> List.iter walkExpr
        | EMember(r, _) -> walkExpr r
        | EPrefix(_, x) -> walkExpr x
        | EBinop(_, l, r) -> walkExpr l; walkExpr r
        | EAssign(t, _, v) -> walkExpr t; walkExpr v
        | EBlock blk | EUnsafe blk ->
            for st in blk.Statements do
                match st.Kind with
                | SExpr x | SAssign(_, _, x) | SReturn(Some x) | SThrow x -> walkExpr x
                | SLocal lb ->
                    match lb with
                    | LBVal(_, _, init) | LBLet(_, _, init) -> walkExpr init
                    | LBVar(_, _, Some init) -> walkExpr init
                    | LBVar(_, _, None) -> ()
                | _ -> ()
        | _ -> ()

    and walkExprOrBlock (eob: ExprOrBlock) =
        match eob with
        | EOBExpr x -> walkExpr x
        | EOBBlock b ->
            for st in b.Statements do
                match st.Kind with
                | SExpr x | SAssign(_, _, x) | SReturn(Some x) | SThrow x -> walkExpr x
                | _ -> ()

    let walkContractClauses (cs: ContractClause list) =
        for c in cs do
            match c with
            | CCRequires(e, _) | CCEnsures(e, _) | CCWhen(e, _) | CCDecreases(e, _) ->
                walkExpr e
            | CCRaises _ -> ()

    for it in file.Items do
        match it.Kind with
        | IFunc fn when fn |> levelOfFunction fileLevel |> VerificationLevel.isProofRequired ->
            walkContractClauses fn.Contracts
        | _ -> ()

/// V0009: `assume` used in proof-required code outside an `unsafe { }` block.
/// (`15-phase-4-proof-plan.md` §3.1.)
let private checkAssumeUsage
        (diags: ResizeArray<Diagnostic>)
        (fileLevel: VerificationLevel)
        (file: SourceFile) : unit =

    if not (VerificationLevel.isProofRequired fileLevel) then ()
    else

    let rec walkExpr (inUnsafe: bool) (e: Expr) : unit =
        match e.Kind with
        | ECall(callee, args) ->
            (match callee.Kind with
             | EPath p ->
                 match p.Segments with
                 | ["assume"] when not inUnsafe ->
                     diags.Add(
                         Diagnostic.error "V0009"
                             "`assume` may only appear inside an `unsafe { }` block in proof-required code; wrap in `unsafe { }` or remove"
                             e.Span)
                 | _ -> ()
             | _ -> ())
            walkExpr inUnsafe callee
            for a in args do
                match a with
                | CANamed(_, v, _) | CAPositional v -> walkExpr inUnsafe v
        | EUnsafe blk -> walkBlock true blk
        | EBlock blk -> walkBlock inUnsafe blk
        | EParen inner | EOld inner | ETry inner | EAwait inner
        | ESpawn inner | EPropagate inner -> walkExpr inUnsafe inner
        | ETuple xs | EList xs -> xs |> List.iter (walkExpr inUnsafe)
        | EIf(c, t, eOpt, _) ->
            walkExpr inUnsafe c
            walkExprOrBlock inUnsafe t
            (match eOpt with Some x -> walkExprOrBlock inUnsafe x | None -> ())
        | EMatch(s, arms) ->
            walkExpr inUnsafe s
            for arm in arms do
                walkExprOrBlock inUnsafe arm.Body
                match arm.Guard with Some g -> walkExpr inUnsafe g | None -> ()
        | EForall(_, w, body) | EExists(_, w, body) ->
            (match w with Some x -> walkExpr inUnsafe x | None -> ())
            walkExpr inUnsafe body
        | ETypeApp(fn, _) -> walkExpr inUnsafe fn
        | EIndex(r, ix) -> walkExpr inUnsafe r; ix |> List.iter (walkExpr inUnsafe)
        | EMember(r, _) -> walkExpr inUnsafe r
        | EPrefix(_, x) -> walkExpr inUnsafe x
        | EBinop(_, l, r) -> walkExpr inUnsafe l; walkExpr inUnsafe r
        | EAssign(t, _, v) -> walkExpr inUnsafe t; walkExpr inUnsafe v
        | ELambda(_, body) -> walkBlock inUnsafe body
        | EInterpolated segs ->
            for seg in segs do
                match seg with ISExpr x -> walkExpr inUnsafe x | ISText _ -> ()
        | ERange _ | ELiteral _ | EPath _ | ESelf | EResult | EError -> ()

    and walkExprOrBlock (inUnsafe: bool) (eob: ExprOrBlock) =
        match eob with
        | EOBExpr x -> walkExpr inUnsafe x
        | EOBBlock b -> walkBlock inUnsafe b

    and walkBlock (inUnsafe: bool) (blk: Block) =
        for st in blk.Statements do
            match st.Kind with
            | SExpr x | SAssign(_, _, x) | SReturn(Some x)
            | SThrow x | SInvariant x -> walkExpr inUnsafe x
            | SLocal lb ->
                match lb with
                | LBVal(_, _, init) | LBLet(_, _, init) -> walkExpr inUnsafe init
                | LBVar(_, _, Some init) -> walkExpr inUnsafe init
                | LBVar(_, _, None) -> ()
            | STry(body, catches) ->
                walkBlock inUnsafe body
                for c in catches do walkBlock inUnsafe c.Body
            | SDefer body | SScope(_, body) -> walkBlock inUnsafe body
            | SFor(_, _, iter, body) | SWhile(_, iter, body) ->
                walkExpr inUnsafe iter; walkBlock inUnsafe body
            | SLoop(_, body) -> walkBlock inUnsafe body
            | SRule(l, r) -> walkExpr inUnsafe l; walkExpr inUnsafe r
            | _ -> ()

    for it in file.Items do
        match it.Kind with
        | IFunc fn when fn |> levelOfFunction fileLevel |> VerificationLevel.isProofRequired ->
            match fn.Body with
            | None -> ()
            | Some(FBExpr e) -> walkExpr false e
            | Some(FBBlock blk) -> walkBlock false blk
        | _ -> ()

/// V0001: a `@proof_required` package may not directly import a
/// `@runtime_checked` package — the proof would be unsound because
/// the runtime-checked callee's contracts aren't VC-discharged.
/// (`08-contract-semantics.md` §3.1 partial order.)
///
/// `imports` carries every successfully loaded
/// `Lyric.Verifier.Imports.ImportedPackage`.  Imports the verifier
/// couldn't resolve (no DLL on disk, no contract resource) are
/// silently skipped — we conservatively assume opaque/legacy
/// imports are okay rather than spamming false positives.
let private checkImportLevels
        (diags: ResizeArray<Diagnostic>)
        (fileLevel: VerificationLevel)
        (file: SourceFile)
        (imports: Imports.ImportedPackage list) : unit =

    if not (VerificationLevel.isProofRequired fileLevel) then ()
    else
    for imp in file.Imports do
        let pkgPath =
            match imp.Path.Segments with
            | xs when not (List.isEmpty xs) -> String.concat "." xs
            | _ -> ""
        if pkgPath = "" then ()
        else
        match imports |> List.tryFind (fun ip -> ip.Name = pkgPath) with
        | None -> ()  // unresolved — silently pass
        | Some ip ->
            let calleeLevel = Imports.levelStringToMode ip.Contract.Level
            // RuntimeChecked callees are inadmissible from
            // proof-required code (per the partial order).  Axiom
            // is admissible.  Other proof-required levels are
            // admissible.
            match calleeLevel with
            | RuntimeChecked ->
                diags.Add(
                    Diagnostic.error "V0001"
                        (sprintf "proof-required package may not import @runtime_checked package '%s'; mark callees @axiom or shift to @runtime_checked"
                            pkgPath)
                        imp.Span)
            | _ -> ()

/// Top-level entry: returns mode-check diagnostics for `file` plus
/// the resolved file level.  Caller decides whether to proceed to
/// VC generation (the rule of thumb is: any V0001/V0002/V0004 error
/// stops the pipeline; V0005 is a warning shape today and will be
/// promoted to error once the loop-invariant syntax lands).
let checkFileWithImports
        (file: SourceFile)
        (imports: Imports.ImportedPackage list)
        : VerificationLevel * Diagnostic list =
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
        checkQuantifierDomains diags level file
        checkAssumeUsage diags level file
        checkImportLevels diags level file imports
        level, List.ofSeq diags

/// Backwards-compatible alias for the existing call sites that
/// don't yet pass imports.  Equivalent to `checkFileWithImports`
/// with an empty import list.
let checkFile (file: SourceFile) : VerificationLevel * Diagnostic list =
    checkFileWithImports file []
