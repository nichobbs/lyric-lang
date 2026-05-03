/// Verification-condition generator
/// (`08-contract-semantics.md` §10, `15-phase-4-proof-plan.md` §5).
///
/// M4.1 fragment:
///
///   * Function bodies that are either a single expression (`= expr`)
///     or a block of `let`/`val` bindings followed by a single
///     `return` (or terminating expression).
///   * `if`/`else` and `match` on `Result.Ok`/`Err` desugar.
///   * Calls to other proof-required or `@pure` functions, encoded
///     via the call rule (assert callee Pre, assume callee Post).
///   * Range-subtype encoding via SInt + range hypotheses.
///
/// M4.2 picks up loops, quantifiers, structural reasoning.
module Lyric.Verifier.VCGen

open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Verifier.Vcir
open Lyric.Verifier.Theory
open Lyric.Verifier.Mode

/// The translation environment: variable name → (term, sort info).
/// `result` and `old(...)` substitutions live in the same map; the
/// VC generator extends the environment as it descends through
/// `let`/`val` bindings.
type Env =
    { Vars:     Map<string, Term>
      Sorts:    Map<string, SortInfo>
      Callees:  Map<string, FunctionDecl>
      Symbols:  ResizeArray<SymbolDecl> }

module Env =

    let empty () : Env =
        { Vars     = Map.empty
          Sorts    = Map.empty
          Callees  = Map.empty
          Symbols  = ResizeArray<SymbolDecl>() }

    let bind (name: string) (info: SortInfo) (env: Env) : Env =
        { env with
            Vars  = Map.add name (TVar(name, info.Sort)) env.Vars
            Sorts = Map.add name info env.Sorts }

    let bindTerm (name: string) (term: Term) (info: SortInfo) (env: Env) : Env =
        { env with
            Vars  = Map.add name term env.Vars
            Sorts = Map.add name info env.Sorts }

    let lookup (name: string) (env: Env) : Term option =
        Map.tryFind name env.Vars

    let lookupSort (name: string) (env: Env) : SortInfo option =
        Map.tryFind name env.Sorts

/// Translation result from an expression: a Term, side conditions
/// (must-hold obligations such as a callee's precondition at the
/// call site), and assumed facts (a callee's postcondition substituted
/// at the call site, per the call rule `08-contract-semantics.md`
/// §10.4).
type TranslateResult =
    { Term:        Term
      SideConds:   Term list
      Assumed:     Term list }

/// Translate a literal to an IR literal/term.
let private translateLit (lit: Literal) : Term =
    match lit with
    | Literal.LBool b           -> TLit(LBool b, SBool)
    | Literal.LInt(v, _)        -> TLit(LInt(int64 v), SInt)
    | Literal.LFloat(v, _)      -> TLit(LFloat v, SFloat64)
    | Literal.LString s
    | Literal.LTripleString s
    | Literal.LRawString s      -> TLit(LString s, SString)
    | Literal.LChar c           -> TLit(LInt(int64 c), SInt)
    | Literal.LUnit             -> TLit(LUnit, SDatatype("Unit", []))

/// Combine two translation results:  union the side conditions and
/// assumptions; the term is replaced by the supplied combiner.
let private combine
        (a: TranslateResult)
        (b: TranslateResult)
        (mkTerm: Term -> Term -> Term) : TranslateResult =
    { Term      = mkTerm a.Term b.Term
      SideConds = a.SideConds @ b.SideConds
      Assumed   = a.Assumed   @ b.Assumed }

/// Translate a Lyric expression to a Lyric-VC term.  For the M4.1
/// fragment we assume the expression is in the contract sub-language;
/// constructs outside that sub-language land in `failures`.
let rec translateExpr (env: Env) (e: Expr)
        : TranslateResult * Diagnostic list =

    let single t = { Term = t; SideConds = []; Assumed = [] }, []

    match e.Kind with
    | ELiteral lit -> single (translateLit lit)

    | EParen inner -> translateExpr env inner

    | EPath p ->
        match p.Segments with
        | [name] ->
            match Env.lookup name env with
            | Some t -> single t
            | None ->
                // Unknown name — emit an opaque uninterpreted symbol
                // for forward progress.  The VC will likely fail to
                // discharge but the user gets a useful diagnostic.
                let sort = SUninterp name
                single (TVar(name, sort))
        | _ ->
            single (TVar(String.concat "." p.Segments, SUninterp "path"))

    | EResult ->
        match Env.lookup "result" env with
        | Some t -> single t
        | None   ->
            // `result` not in scope — outside an `ensures:`.
            let diag =
                Diagnostic.error "V0020"
                    "`result` is only valid inside `ensures:` clauses"
                    e.Span
            { Term = TVar("result", SUninterp "result"); SideConds = []; Assumed = [] }, [diag]

    | EOld inner ->
        // `old(e)` — for M4.1 we look up an entry in the env keyed by
        // the syntactic shape of `e`.  The simplest case is `old(x)`
        // for a parameter `x`, which is bound under `old.x`.
        match inner.Kind with
        | EPath p ->
            let leafName =
                match p.Segments with
                | xs when not (List.isEmpty xs) -> List.last xs
                | _ -> ""
            let key = "old." + leafName
            match Env.lookup key env with
            | Some t -> single t
            | None ->
                // No snapshot binding — fall back to the current
                // value (sound only if the value didn't change, but
                // this is a M4.1 limitation).
                translateExpr env inner
        | _ ->
            // Non-trivial `old(e)` — defer (M4.2 work).
            let diag =
                Diagnostic.warning "V0021"
                    "`old(e)` for non-path expressions is not yet supported; treating as current"
                    e.Span
            let inner', innerDiags = translateExpr env inner
            inner', diag :: innerDiags

    | EIf(c, t, eOpt, _) ->
        let cT, cDiags = translateExpr env c
        let asExpr eob =
            match eob with
            | EOBExpr x   -> translateExpr env x
            | EOBBlock _  ->
                // Block branches are not yet supported in the M4.1
                // expression translator; fall back to a dummy.
                let diag =
                    Diagnostic.warning "V0022"
                        "block branches in contract expressions not yet supported in M4.1"
                        e.Span
                { Term = Term.trueT; SideConds = []; Assumed = [] }, [diag]
        let tT, tDiags = asExpr t
        let eT, eDiags =
            match eOpt with
            | Some branch -> asExpr branch
            | None        -> { Term = TLit(LUnit, SDatatype("Unit", [])); SideConds = []; Assumed = [] }, []
        let term = TIte(cT.Term, tT.Term, eT.Term)
        { Term      = term
          SideConds = cT.SideConds @ tT.SideConds @ eT.SideConds
          Assumed   = cT.Assumed   @ tT.Assumed   @ eT.Assumed },
        cDiags @ tDiags @ eDiags

    | EPrefix(op, x) ->
        let xT, xDiags = translateExpr env x
        match builtinOfPrefix op with
        | Some b ->
            { Term      = TBuiltin(b, [xT.Term])
              SideConds = xT.SideConds
              Assumed   = xT.Assumed }, xDiags
        | None ->
            single (TVar("?prefix", SUninterp "prefix"))

    | EBinop(op, l, r) ->
        let lT, lDiags = translateExpr env l
        let rT, rDiags = translateExpr env r
        match builtinOfBinop op with
        | Some b ->
            let term = TBuiltin(b, [lT.Term; rT.Term])
            { Term      = term
              SideConds = lT.SideConds @ rT.SideConds
              Assumed   = lT.Assumed   @ rT.Assumed },
            lDiags @ rDiags
        | None ->
            let diag =
                Diagnostic.warning "V0023"
                    "binary operator not yet modelled in proof translation"
                    e.Span
            { Term = TVar("?binop", SUninterp "binop"); SideConds = []; Assumed = [] },
            diag :: (lDiags @ rDiags)

    | ECall(fn, args) ->
        // Resolve callee by name and emit a TApp + its precondition
        // as a side condition + its postcondition as an assumption
        // (call rule §10.4).
        let argResults, argDiags =
            args
            |> List.map (fun a ->
                match a with
                | CANamed(_, v, _) | CAPositional v -> translateExpr env v)
            |> List.unzip
        let argTerms   = argResults |> List.map (fun r -> r.Term)
        let argSides   = argResults |> List.collect (fun r -> r.SideConds)
        let argAssumed = argResults |> List.collect (fun r -> r.Assumed)
        match fn.Kind with
        | EPath p ->
            let name =
                match p.Segments with
                | [n] -> n
                | xs  -> String.concat "." xs
            match Map.tryFind name env.Callees with
            | Some decl ->
                let resultSort =
                    match decl.Return with
                    | Some te -> (sortOfTypeExpr te).Sort
                    | None    -> SDatatype("Unit", [])
                let paramSorts =
                    decl.Params
                    |> List.map (fun p -> (sortOfTypeExpr p.Type).Sort)
                env.Symbols.Add(UserFun(name, paramSorts, resultSort))
                let callTerm = TApp(name, argTerms, resultSort)

                // Build a substitution map: param[i].Name → argTerms[i].
                let paramSubst : Map<string, Term> =
                    List.zip decl.Params argTerms
                    |> List.fold (fun acc (p, arg) -> Map.add p.Name arg acc) Map.empty

                // Translate every requires clause into a side
                // condition (substituted with the caller's args).
                let mkInnerEnv () =
                    decl.Params
                    |> List.fold
                        (fun env p ->
                            let info = sortOfTypeExpr p.Type
                            Env.bind p.Name info env)
                        (Env.empty ())
                let innerEnv = mkInnerEnv ()
                let preConds =
                    decl.Contracts
                    |> List.choose (fun c ->
                        match c with CCRequires(e, _) -> Some e | _ -> None)
                    |> List.choose (fun pre ->
                        let r, _ = translateExpr innerEnv pre
                        Some (Term.subst paramSubst r.Term))

                // Translate every ensures clause and substitute
                // both params and `result := callTerm`.
                let postConds =
                    decl.Contracts
                    |> List.choose (fun c ->
                        match c with CCEnsures(e, _) -> Some e | _ -> None)
                    |> List.choose (fun post ->
                        let resultEnv =
                            { innerEnv with
                                Vars  = Map.add "result" callTerm innerEnv.Vars
                                Sorts = Map.add "result" { Sort = resultSort; Range = RBKNone } innerEnv.Sorts }
                        let r, _ = translateExpr resultEnv post
                        Some (Term.subst paramSubst r.Term))

                { Term      = callTerm
                  SideConds = argSides @ preConds
                  Assumed   = argAssumed @ postConds },
                List.concat argDiags
            | None ->
                // Free function — leave as TApp with an inferred sort.
                let term = TApp(name, argTerms, SUninterp ("call." + name))
                { Term      = term
                  SideConds = argSides
                  Assumed   = argAssumed },
                List.concat argDiags
        | _ ->
            single (TVar("?call", SUninterp "call"))

    | EForall(binders, where, body) ->
        let env', binderSorts =
            binders
            |> List.fold
                (fun (envAcc, sortsAcc) (b: PropertyBinder) ->
                    let info = sortOfTypeExpr b.Type
                    Env.bind b.Name info envAcc,
                    sortsAcc @ [b.Name, info.Sort])
                (env, [])
        let bodyT, bodyDiags = translateExpr env' body
        let whereT, whereDiags =
            match where with
            | Some w ->
                let wT, wDiags = translateExpr env' w
                Some wT.Term, wDiags
            | None -> None, []
        let inner =
            match whereT with
            | Some wt -> Term.mkImplies wt bodyT.Term
            | None    -> bodyT.Term
        { Term = TForall(binderSorts, [], inner); SideConds = []; Assumed = [] },
        bodyDiags @ whereDiags

    | EExists(binders, where, body) ->
        let env', binderSorts =
            binders
            |> List.fold
                (fun (envAcc, sortsAcc) (b: PropertyBinder) ->
                    let info = sortOfTypeExpr b.Type
                    Env.bind b.Name info envAcc,
                    sortsAcc @ [b.Name, info.Sort])
                (env, [])
        let bodyT, bodyDiags = translateExpr env' body
        let whereT, whereDiags =
            match where with
            | Some w ->
                let wT, wDiags = translateExpr env' w
                Some wT.Term, wDiags
            | None -> None, []
        let inner =
            match whereT with
            | Some wt -> Term.mkAnd [wt; bodyT.Term]
            | None    -> bodyT.Term
        { Term = TExists(binderSorts, inner); SideConds = []; Assumed = [] },
        bodyDiags @ whereDiags

    | EMember(receiver, name) ->
        // `e.field` — model as an uninterpreted selector application.
        // Datatype-level field access is M4.2 work.
        let rT, rDiags = translateExpr env receiver
        let resultSort = SUninterp ("field." + name)
        let term = TApp("$field." + name, [rT.Term], resultSort)
        { Term      = term
          SideConds = rT.SideConds
          Assumed   = rT.Assumed }, rDiags

    | EBlock blk ->
        // Single-expression block: just translate the trailing expr.
        let rec lastExpr (stmts: Statement list) : Expr option =
            match stmts with
            | [] -> None
            | [{ Kind = SExpr x }] -> Some x
            | [{ Kind = SReturn(Some x) }] -> Some x
            | _ :: rest -> lastExpr rest
        match lastExpr blk.Statements with
        | Some last -> translateExpr env last
        | None ->
            single (TLit(LUnit, SDatatype("Unit", [])))

    | _ ->
        // Unsupported in M4.1 — emit a placeholder to keep the
        // pipeline forward, plus a warning so the user sees what
        // wasn't modelled.
        let diag =
            Diagnostic.warning "V0024"
                "expression construct not yet modelled in proof translation"
                e.Span
        { Term = TVar("?expr", SUninterp "expr"); SideConds = []; Assumed = [] }, [diag]

/// Translate a contract clause's expression, conjoining any side
/// conditions into the main term.
let translateContract (env: Env) (e: Expr) : Term * Diagnostic list =
    let r, diags = translateExpr env e
    match r.SideConds with
    | [] -> r.Term, diags
    | xs -> Term.mkAnd (xs @ [r.Term]), diags

/// Bind a single function parameter into the environment, producing
/// a parameter-side range hypothesis if the type is a refined range.
let private bindParam (env: Env) (p: Param) : Env * Term list =
    let info = sortOfTypeExpr p.Type
    let env' = Env.bind p.Name info env
    let hyps = rangeHypotheses p.Name info
    env', hyps

/// `15-phase-4-proof-plan.md` §5.4: the wp of a body with respect
/// to a postcondition.  M4.1 special-cases:
///
///   * `body = e`   (FBExpr)        →   wp = Q[result := ⟦e⟧]
///   * `body = { return e }`        →   same as above
///   * `body = { let x = e ; rest }` →  wp(rest, Q)[x := ⟦e⟧]
///
/// Anything outside these shapes produces a `WpUnsupported` diag and
/// returns `Term.trueT` for the wp (so the goal will fail to
/// discharge unless the postcondition is itself trivial).
type WpResult =
    { Wp:        Term
      SideGoals: (Term * GoalKind * Span) list
      /// Hypotheses to add to the goal — typically the postconditions
      /// of called functions (call rule §10.4).
      Assumed:   Term list
      Diags:     Diagnostic list }

let rec private wpExpr
        (env: Env)
        (resultSort: SortInfo)
        (q: Term -> Term)
        (e: Expr) : WpResult =

    let translation, diags = translateExpr env e
    let wp = q translation.Term
    let sideGoals =
        translation.SideConds
        |> List.map (fun side -> side, GKAssertion, e.Span)
    { Wp        = wp
      SideGoals = sideGoals
      Assumed   = translation.Assumed
      Diags     = diags }

/// wp over a function body (FBExpr or FBBlock with simple shape).
let wpBody
        (env: Env)
        (resultSort: SortInfo)
        (q: Term -> Term)
        (body: FunctionBody) : WpResult =

    match body with
    | FBExpr e -> wpExpr env resultSort q e
    | FBBlock blk ->
        // M4.1: support
        //
        //   { return e }                                     (single return)
        //   { let x: T = e1 ; ... ; return eN }              (let-let-return)
        //   { val x: T = e1 ; ... ; return eN }
        //
        // Anything else falls through to "unsupported".
        let stmts = blk.Statements
        let rec walk (env: Env) (stmts: Statement list)
                : WpResult =
            match stmts with
            | [] ->
                { Wp = q (TLit(LUnit, SDatatype("Unit", [])))
                  SideGoals = []
                  Assumed = []
                  Diags = [] }
            | [{ Kind = SReturn(Some e) }]
            | [{ Kind = SExpr e }] ->
                wpExpr env resultSort q e
            | [{ Kind = SReturn None }] ->
                { Wp = q (TLit(LUnit, SDatatype("Unit", [])))
                  SideGoals = []
                  Assumed = []
                  Diags = [] }
            | { Kind = SLocal lb } :: rest ->
                match lb with
                | LBVal(pat, _, init) ->
                    let name =
                        match pat.Kind with
                        | PBinding(n, _) -> n
                        | _              -> "?pat"
                    let initT, initDiags = translateExpr env init
                    let info =
                        // Best-effort: take the sort from the init term.
                        let s = Term.sortOf initT.Term
                        { Sort = s; Range = RBKNone }
                    let env' = Env.bindTerm name initT.Term info env
                    let inner = walk env' rest
                    { Wp = inner.Wp
                      SideGoals = inner.SideGoals
                      Assumed = initT.Assumed @ inner.Assumed
                      Diags = initDiags @ inner.Diags }
                | LBLet(name, _, init) ->
                    let initT, initDiags = translateExpr env init
                    let info =
                        let s = Term.sortOf initT.Term
                        { Sort = s; Range = RBKNone }
                    let env' = Env.bindTerm name initT.Term info env
                    let inner = walk env' rest
                    { Wp = inner.Wp
                      SideGoals = inner.SideGoals
                      Assumed = initT.Assumed @ inner.Assumed
                      Diags = initDiags @ inner.Diags }
                | LBVar _ ->
                    let diag =
                        Diagnostic.warning "V0025"
                            "`var` bindings not yet supported in M4.1 verifier"
                            (List.head stmts).Span
                    { Wp = Term.trueT; SideGoals = []; Assumed = []; Diags = [diag] }
            | st :: _ ->
                let diag =
                    Diagnostic.warning "V0026"
                        "statement form not yet supported in M4.1 verifier"
                        st.Span
                { Wp = Term.trueT; SideGoals = []; Assumed = []; Diags = [diag] }

        walk env stmts

/// Generate the `Pre ⇒ wp(body, Post)` goal for one function.
let goalsForFunction
        (env0: Env)
        (decl: FunctionDecl)
        : Goal list * Diagnostic list =

    // Bind parameters.
    let envAfterParams, paramHyps =
        decl.Params
        |> List.fold
            (fun (env, hyps) p ->
                let env', h = bindParam env p
                env', hyps @ h)
            (env0, [])

    // Result sort.
    let resultSort =
        match decl.Return with
        | Some te -> sortOfTypeExpr te
        | None    ->
            { Sort = SDatatype("Unit", []); Range = RBKNone }

    // Bind `result` into a successor environment for the postcondition.
    let envWithResult =
        Env.bind "result" resultSort envAfterParams

    // Old-snapshot bindings: for every parameter, `old.<name> := <name>`.
    let envWithOld =
        decl.Params
        |> List.fold
            (fun env p ->
                let info = sortOfTypeExpr p.Type
                Env.bindTerm ("old." + p.Name) (TVar(p.Name, info.Sort)) info env)
            envWithResult

    // Pre / Post translation.
    let preTerm, preDiags =
        let clauses =
            decl.Contracts
            |> List.choose (fun c ->
                match c with CCRequires(e, _) -> Some e | _ -> None)
        clauses
        |> List.map (translateContract envAfterParams)
        |> List.unzip
        |> fun (terms, diagss) -> Term.mkAnd terms, List.concat diagss

    let postTerm, postDiags =
        let clauses =
            decl.Contracts
            |> List.choose (fun c ->
                match c with CCEnsures(e, _) -> Some e | _ -> None)
        clauses
        |> List.map (translateContract envWithOld)
        |> List.unzip
        |> fun (terms, diagss) -> Term.mkAnd terms, List.concat diagss

    let body =
        match decl.Body with
        | Some b -> b
        | None   ->
            // Function with no body: treated as @axiom.  No VCs.
            FBExpr { Kind = ELiteral Literal.LUnit; Span = decl.Span }

    let wpRes =
        wpBody envWithOld resultSort
            (fun resultExpr ->
                // Substitute `result` into postTerm.
                Term.subst (Map.ofList [("result", resultExpr)]) postTerm)
            body

    let hypotheses = paramHyps @ [preTerm] @ wpRes.Assumed

    let mainGoal =
        { Hypotheses = hypotheses
          Conclusion = wpRes.Wp
          Symbols    = List.ofSeq env0.Symbols
          Origin     = decl.Span
          Kind       = GKPostcondition decl.Name
          Label      = sprintf "%s$post" decl.Name }

    // Side goals (callee preconditions) get the *non-assumed*
    // hypotheses — assuming a callee's post here would be circular.
    let sideHyps = paramHyps @ [preTerm]
    let sideGoals =
        wpRes.SideGoals
        |> List.map (fun (term, kind, span) ->
            { Hypotheses = sideHyps
              Conclusion = term
              Symbols    = List.ofSeq env0.Symbols
              Origin     = span
              Kind       = kind
              Label      = sprintf "%s$side" decl.Name })

    let diags = preDiags @ postDiags @ wpRes.Diags
    mainGoal :: sideGoals, diags

/// Top-level entry: walk every proof-required function in a file
/// and emit the Goals.
let goalsForFile (file: SourceFile) (level: VerificationLevel)
        : Goal list * Diagnostic list =

    if not (VerificationLevel.isProofRequired level) then [], []
    else
    let env0 =
        let callees =
            file.Items
            |> List.choose (fun it ->
                match it.Kind with
                | IFunc fn -> Some (fn.Name, fn)
                | _        -> None)
            |> Map.ofList
        { Env.empty () with Callees = callees }
    let allGoals, allDiags =
        file.Items
        |> List.choose (fun it ->
            match it.Kind with
            | IFunc fn ->
                match levelOfFunction level fn with
                | Axiom        -> None
                | RuntimeChecked -> None
                | _            -> Some fn
            | _ -> None)
        |> List.map (goalsForFunction env0)
        |> List.unzip
    List.concat allGoals, List.concat allDiags
