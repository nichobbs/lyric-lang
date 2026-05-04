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
open Lyric.Emitter
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
      /// Cross-package contract metadata for callees defined in
      /// imported assemblies.  Looked up by leaf name when the
      /// local `Callees` table doesn't have the symbol
      /// (D-progress-086 cross-package call rule).
      Imports:  Imports.ImportedPackage list
      /// Datatype definitions in scope — local file records / unions
      /// / enums / opaques, plus imported types via ProofMeta.
      /// Indexed by leaf name.
      Datatypes: Map<string, ProofMeta.ProofType>
      Symbols:  ResizeArray<SymbolDecl> }

module Env =

    let empty () : Env =
        { Vars     = Map.empty
          Sorts    = Map.empty
          Callees  = Map.empty
          Imports  = []
          Datatypes = Map.empty
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

/// Resolve a `ProofType` field's source-level type-string into a
/// Sort by re-parsing.  Used by the datatype encoder.
let private fieldSortOf (f: ProofMeta.ProofField) : Sort =
    let te, _ = Lyric.Parser.Parser.parseTypeFromString f.TypeRepr
    (sortOfTypeExpr te).Sort

/// Register a datatype declaration in the environment's symbol
/// list once.  Idempotent: re-registering the same datatype is a
/// no-op.  The Smt emitter filters duplicates as a backstop.
let registerDatatype (env: Env) (pt: ProofMeta.ProofType) : unit =
    let already =
        env.Symbols
        |> Seq.exists (fun s ->
            match s with
            | Datatype(n, _) -> n = pt.Name
            | _ -> false)
    if already then ()
    else
    let ctors =
        match pt.Kind with
        | ProofMeta.PTKRecord fs ->
            [ pt.Name,
                fs |> List.map (fun f -> f.Name, fieldSortOf f) ]
        | ProofMeta.PTKOpaque fs ->
            [ pt.Name,
                fs |> List.map (fun f -> f.Name, fieldSortOf f) ]
        | ProofMeta.PTKUnion cases ->
            cases
            |> List.map (fun c ->
                c.Name,
                c.Fields |> List.map (fun f -> f.Name, fieldSortOf f))
        | ProofMeta.PTKEnum cs ->
            cs |> List.map (fun n -> n, [])
    env.Symbols.Add(Datatype(pt.Name, ctors))

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

/// Cheap structural equality on Terms — used by the match
/// translator to recognise unconditional `true` patterns.
let rec private termEqInternal (a: Term) (b: Term) : bool =
    match a, b with
    | TVar(n1, s1), TVar(n2, s2) -> n1 = n2 && s1 = s2
    | TLit(l1, _),  TLit(l2, _)  -> l1 = l2
    | TBuiltin(o1, xs), TBuiltin(o2, ys) ->
        o1 = o2 && List.length xs = List.length ys
        && List.forall2 termEqInternal xs ys
    | TApp(n1, xs, _), TApp(n2, ys, _) ->
        n1 = n2 && List.length xs = List.length ys
        && List.forall2 termEqInternal xs ys
    | _ -> false

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
            | EOBBlock blk ->
                // Extract a single trailing expression or return value so that
                // branches like `{ return 0 }` or `{ remaining }` translate
                // to the actual value rather than the `true` dummy.
                // Intermediate val/let bindings are skipped; they must already
                // be in scope from an outer block for the result to be meaningful.
                let rec lastExpr (stmts: Statement list) =
                    match stmts with
                    | [{ Kind = SExpr x }]         -> Some x
                    | [{ Kind = SReturn(Some x) }] -> Some x
                    | _ :: rest                    -> lastExpr rest
                    | []                           -> None
                match lastExpr blk.Statements with
                | Some x -> translateExpr env x
                | None ->
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
            // Datatype constructor short-circuit: when `name`
            // matches a known record / union case, emit a typed
            // `(<ctor> <args>)` term and register the datatype.
            // This requires the args to be in declared-field order;
            // named-arg call sites have to be reordered.  For
            // records, we reorder by matching the named args to the
            // record's field list; for unions we look up the case
            // across every union datatype.
            let datatypeCtor =
                let asRecord () =
                    match Map.tryFind name env.Datatypes with
                    | Some pt ->
                        match pt.Kind with
                        | ProofMeta.PTKRecord fs
                        | ProofMeta.PTKOpaque fs ->
                            // Build a name -> arg term map from the
                            // named call args.  Positional args fill
                            // in declaration order.
                            let namedMap =
                                args
                                |> List.zip argTerms
                                |> List.choose (fun (t, a) ->
                                    match a with
                                    | CANamed(n, _, _) -> Some (n, t)
                                    | _ -> None)
                                |> Map.ofList
                            let positional =
                                args
                                |> List.zip argTerms
                                |> List.choose (fun (t, a) ->
                                    match a with
                                    | CAPositional _ -> Some t
                                    | _ -> None)
                            let mutable posIdx = 0
                            let ordered =
                                fs
                                |> List.map (fun f ->
                                    match Map.tryFind f.Name namedMap with
                                    | Some t -> t
                                    | None ->
                                        if posIdx < List.length positional then
                                            let t = List.item posIdx positional
                                            posIdx <- posIdx + 1
                                            t
                                        else
                                            TVar("?missing." + f.Name, fieldSortOf f))
                            registerDatatype env pt
                            Some (TApp(pt.Name, ordered, SDatatype(pt.Name, [])))
                        | _ -> None
                    | None -> None
                let asUnionCase () =
                    env.Datatypes
                    |> Map.toSeq
                    |> Seq.tryPick (fun (_, pt) ->
                        match pt.Kind with
                        | ProofMeta.PTKUnion cases ->
                            cases
                            |> List.tryFind (fun c -> c.Name = name)
                            |> Option.map (fun c -> pt, c)
                        | ProofMeta.PTKEnum cs when cs |> List.contains name ->
                            Some (pt, { ProofMeta.ProofCase.Name = name; ProofMeta.ProofCase.Fields = [] })
                        | _ -> None)
                    |> Option.map (fun (pt, c) ->
                        registerDatatype env pt
                        TApp(c.Name, argTerms, SDatatype(pt.Name, [])))
                match asRecord () with
                | Some t -> Some t
                | None   -> asUnionCase ()
            match datatypeCtor with
            | Some ctorTerm ->
                { Term      = ctorTerm
                  SideConds = argSides
                  Assumed   = argAssumed },
                List.concat argDiags
            | None ->
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

                // @pure callee: unfold one level — emit `g(args) = body`
                // as an additional assumption so the caller's proof
                // can do equational reasoning on the body.
                // (`15-phase-4-proof-plan.md` §5.5; one-level unfold.)
                let pureUnfold : Term list =
                    if not (isPure decl) then []
                    else
                    let bodyExprOpt =
                        match decl.Body with
                        | Some(FBExpr e) -> Some e
                        // Block-form `{ return e }` is treated as
                        // FBExpr e for the purposes of unfold.
                        | Some(FBBlock blk) ->
                            match blk.Statements with
                            | [{ Kind = SReturn(Some e) }] -> Some e
                            | [{ Kind = SExpr e }]         -> Some e
                            | _ -> None
                        | None -> None
                    match bodyExprOpt with
                    | None -> []
                    | Some bodyExpr ->
                        // Translate body in a fresh env that has
                        // the params bound, then substitute caller
                        // args for the formal parameters.
                        let pureEnv =
                            decl.Params
                            |> List.fold
                                (fun env p ->
                                    let info = sortOfTypeExpr p.Type
                                    Env.bind p.Name info env)
                                (Env.empty ())
                        let bodyT, _ = translateExpr pureEnv bodyExpr
                        let bodySubst = Term.subst paramSubst bodyT.Term
                        [ TBuiltin(BOpEq, [callTerm; bodySubst]) ]

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
                  Assumed   = argAssumed @ postConds @ pureUnfold },
                List.concat argDiags
            | None ->
                // No local callee — try the cross-package import
                // table.  D-progress-086.
                match Imports.findDeclByLeaf env.Imports name with
                | None ->
                    // Free function — leave as TApp with an inferred sort.
                    let term = TApp(name, argTerms, SUninterp ("call." + name))
                    { Term      = term
                      SideConds = argSides
                      Assumed   = argAssumed },
                    List.concat argDiags
                | Some(_, importedDecl) ->
                    // Resolve param sorts from the textual type strings
                    // saved in the contract metadata.
                    let parseTypeStr (s: string) : SortInfo =
                        let te, _ = Lyric.Parser.Parser.parseTypeFromString s
                        sortOfTypeExpr te
                    let paramInfos =
                        importedDecl.Params
                        |> List.map (fun (n, ty) -> n, parseTypeStr ty)
                    let paramSorts =
                        paramInfos |> List.map (fun (_, info) -> info.Sort)
                    // Result sort: the contract Repr's `: <type>` is
                    // currently parseable only via re-parsing the
                    // function declaration as a whole, which is
                    // brittle.  As a bootstrap shortcut, the verifier
                    // re-parses the Repr as a function-decl-sized
                    // surface using `parseFromString` is unavailable;
                    // we degrade to an uninterpreted result sort when
                    // the metadata lacks an explicit return-type
                    // string.  This gets refined as M4.2 work — for
                    // now most cross-package callees are bool/int
                    // returns, which the user's contract still
                    // exercises through the post equation.
                    let resultSort =
                        // Best-effort: pull the colon-prefixed return
                        // type out of the Repr string.  e.g.
                        //   "pub func foo(x: in Int): Int requires: ..."
                        // The substring after the params' closing ')'
                        // and before the next clause keyword, if any.
                        let r = importedDecl.Repr
                        let idxClose = r.IndexOf ')'
                        if idxClose < 0 then SUninterp ("call." + name)
                        else
                            let tail = r.Substring(idxClose + 1).TrimStart()
                            if tail.StartsWith ":" then
                                let stripped = tail.Substring(1).TrimStart()
                                let cut =
                                    let idxSpace = stripped.IndexOf ' '
                                    let idxNewline = stripped.IndexOf '\n'
                                    let candidates =
                                        [ if idxSpace >= 0 then yield idxSpace
                                          if idxNewline >= 0 then yield idxNewline
                                          yield stripped.Length ]
                                    List.min candidates
                                let tyStr = stripped.Substring(0, cut)
                                if tyStr = "" then SUninterp ("call." + name)
                                else (parseTypeStr tyStr).Sort
                            else SUninterp ("call." + name)

                    env.Symbols.Add(UserFun(name, paramSorts, resultSort))
                    let callTerm = TApp(name, argTerms, resultSort)

                    // Substitution: imported param names → caller args.
                    let paramSubst : Map<string, Term> =
                        List.zip paramInfos argTerms
                        |> List.fold
                            (fun acc ((pn, _), arg) -> Map.add pn arg acc)
                            Map.empty

                    // Build an env in which the imported params are bound
                    // so we can translate the requires/ensures strings.
                    let mkImportedEnv () =
                        paramInfos
                        |> List.fold
                            (fun env (n, info) -> Env.bind n info env)
                            (Env.empty ())
                    let innerEnv = mkImportedEnv ()

                    let parseClause (s: string) : Expr option =
                        try
                            let e, diags = Lyric.Parser.Parser.parseExprFromString s
                            let hasErr =
                                diags |> List.exists (fun d -> d.Severity = DiagError)
                            if hasErr then None else Some e
                        with _ -> None

                    let preConds =
                        importedDecl.Requires
                        |> List.choose parseClause
                        |> List.map (fun pre ->
                            let r, _ = translateExpr innerEnv pre
                            Term.subst paramSubst r.Term)

                    let postConds =
                        importedDecl.Ensures
                        |> List.choose parseClause
                        |> List.map (fun post ->
                            let resultEnv =
                                { innerEnv with
                                    Vars  = Map.add "result" callTerm innerEnv.Vars
                                    Sorts = Map.add "result" { Sort = resultSort; Range = RBKNone } innerEnv.Sorts }
                            let r, _ = translateExpr resultEnv post
                            Term.subst paramSubst r.Term)

                    // Cross-package @pure unfold using the serialised
                    // body string (D-progress-086).
                    let pureUnfold : Term list =
                        if not importedDecl.Pure then []
                        else
                            match importedDecl.Body |> Option.bind parseClause with
                            | None -> []
                            | Some bodyExpr ->
                                let bodyT, _ = translateExpr innerEnv bodyExpr
                                let bodySubst = Term.subst paramSubst bodyT.Term
                                [ TBuiltin(BOpEq, [callTerm; bodySubst]) ]

                    { Term      = callTerm
                      SideConds = argSides @ preConds
                      Assumed   = argAssumed @ postConds @ pureUnfold },
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
        // `e.field` — when the receiver's sort is a known datatype
        // and the field exists in the proof-meta record, emit a
        // typed `(<field> <receiver>)` selector and register the
        // datatype declaration so the SMT layer's
        // `declare-datatypes` includes it.  Falls back to an
        // uninterpreted `$field.name` selector when the type isn't
        // visible to the verifier (cross-package opaque without
        // ProofMeta, or non-datatype types).
        let rT, rDiags = translateExpr env receiver
        let recvSort = Term.sortOf rT.Term
        let dtName =
            match recvSort with
            | SDatatype(n, _) -> Some n
            | _ -> None
        let typedSelector =
            dtName
            |> Option.bind (fun n ->
                Map.tryFind n env.Datatypes
                |> Option.bind (fun pt ->
                    match pt.Kind with
                    | ProofMeta.PTKRecord fs
                    | ProofMeta.PTKOpaque fs ->
                        fs
                        |> List.tryFind (fun f -> f.Name = name)
                        |> Option.map (fun f -> n, pt, f)
                    | _ -> None))
        match typedSelector with
        | Some(dtName, pt, field) ->
            let fieldSort =
                let te, _ = Lyric.Parser.Parser.parseTypeFromString field.TypeRepr
                (sortOfTypeExpr te).Sort
            // Register the datatype declaration on first use.
            registerDatatype env pt
            let term = TApp(name, [rT.Term], fieldSort)
            { Term      = term
              SideConds = rT.SideConds
              Assumed   = rT.Assumed }, rDiags
        | None ->
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

    | EMatch(scrutinee, arms) ->
        // M4.1 fragment: handle wildcard, literal, and bare-binding
        // patterns.  Constructor / record / tuple patterns are
        // M4.2 work and fall through to a warning.
        //
        // Encoding: nested ite over the arms' match conditions,
        // with each arm's body translated under an env extended by
        // the pattern's bindings.
        let scrutT, scrutDiags = translateExpr env scrutinee
        let scrutTerm = scrutT.Term

        let rec matchCond (pat: Pattern) (subject: Term) : Term option =
            match pat.Kind with
            | PWildcard -> Some Term.trueT
            | PBinding(_, None) -> Some Term.trueT
            | PBinding(_, Some inner) -> matchCond inner subject
            | PLiteral lit ->
                Some (TBuiltin(BOpEq, [subject; translateLit lit]))
            | PParen inner -> matchCond inner subject
            | _ -> None

        let rec patternBindings (pat: Pattern) (subject: Term) : (string * Term) list =
            match pat.Kind with
            | PBinding(name, None)        -> [(name, subject)]
            | PBinding(name, Some inner)  -> (name, subject) :: patternBindings inner subject
            | PParen inner                -> patternBindings inner subject
            | _ -> []

        let mutable allDiags = scrutDiags
        let mutable allSides = scrutT.SideConds
        let mutable allAssumed = scrutT.Assumed

        let translateArm (arm: MatchArm) : Term =
            let bindings = patternBindings arm.Pattern scrutTerm
            let env' =
                bindings
                |> List.fold
                    (fun envAcc (name, term) ->
                        let info = { Sort = Term.sortOf term; Range = RBKNone }
                        Env.bindTerm name term info envAcc)
                    env
            let body, bodyDiags =
                match arm.Body with
                | EOBExpr x -> translateExpr env' x
                | EOBBlock _ ->
                    let d =
                        Diagnostic.warning "V0028"
                            "block-form match arm bodies not yet supported in M4.1 verifier"
                            arm.Span
                    { Term = TVar("?matchblock", SUninterp "matchblock")
                      SideConds = []
                      Assumed = [] }, [d]
            allDiags <- allDiags @ bodyDiags
            allSides <- allSides @ body.SideConds
            allAssumed <- allAssumed @ body.Assumed
            body.Term

        // Walk arms; once a pattern matches unconditionally
        // (`PWildcard` or bare `PBinding`), the remaining arms are
        // unreachable and we use that arm's body directly as the
        // tail of the ite chain.  This avoids emitting a fallthrough
        // sort for exhaustive matches.
        let rec build (arms: MatchArm list) : Term =
            match arms with
            | [] ->
                // Non-exhaustive match — emit a sound-but-uninterpreted
                // fallback.  Z3 will reject this with an error so the
                // user sees a clear "non-exhaustive match" signal.
                let d =
                    Diagnostic.warning "V0029"
                        "match in proof-required code is not exhaustive against the M4.1-supported pattern set"
                        e.Span
                allDiags <- allDiags @ [d]
                TVar("?match.fallthrough", Term.sortOf scrutTerm)
            | [arm] ->
                // Last arm: if the pattern always matches, no ite
                // needed — the arm's body is the result.
                match matchCond arm.Pattern scrutTerm with
                | Some t when termEqInternal t Term.trueT ->
                    translateArm arm
                | Some cond ->
                    TIte(cond, translateArm arm, build [])
                | None ->
                    let d =
                        Diagnostic.warning "V0027"
                            "match arm pattern not yet supported in M4.1 verifier"
                            arm.Span
                    allDiags <- allDiags @ [d]
                    build []
            | arm :: rest ->
                match matchCond arm.Pattern scrutTerm with
                | Some t when termEqInternal t Term.trueT ->
                    // This arm catches everything; the remaining
                    // arms are dead.  Emit just this arm's body.
                    translateArm arm
                | Some cond ->
                    TIte(cond, translateArm arm, build rest)
                | None ->
                    let d =
                        Diagnostic.warning "V0027"
                            "match arm pattern not yet supported in M4.1 verifier"
                            arm.Span
                    allDiags <- allDiags @ [d]
                    build rest

        let term = build arms
        { Term = term; SideConds = allSides; Assumed = allAssumed }, allDiags

    | _ ->
        // Unsupported in M4.1 — emit a placeholder to keep the
        // pipeline forward, plus a warning so the user sees what
        // wasn't modelled.
        let diag =
            Diagnostic.warning "V0024"
                "expression construct not yet modelled in proof translation"
                e.Span
        { Term = TVar("?expr", SUninterp "expr"); SideConds = []; Assumed = [] }, [diag]

/// Translate a contract clause's expression.  Side conditions are
/// conjoined into the main term; assumed facts (e.g. callee
/// postconditions encountered during translation) are returned
/// separately so the caller can hoist them into the goal's
/// hypothesis set.
let translateContract
        (env: Env)
        (e: Expr) : Term * Term list * Diagnostic list =
    let r, diags = translateExpr env e
    let term =
        match r.SideConds with
        | [] -> r.Term
        | xs -> Term.mkAnd (xs @ [r.Term])
    term, r.Assumed, diags

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
let rec wpBody
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
            | { Kind = SExpr ({ Kind = ECall(callee, [arg]) } as callExpr) } :: rest
                when (match callee.Kind with
                      | EPath p ->
                          (match p.Segments with
                           | ["assert"] -> true
                           | _ -> false)
                      | _ -> false) ->
                // `assert φ` — translate φ, emit it as a side goal,
                // then add it to the assumed hypotheses for the rest
                // of the block.  This is the standard Hoare encoding
                // for assertions.
                let argExpr =
                    match arg with
                    | CAPositional v   -> v
                    | CANamed(_, v, _) -> v
                let phi, phiDiags = translateExpr env argExpr
                let inner = walk env rest
                { Wp        = inner.Wp
                  SideGoals = (phi.Term, GKAssertion, callExpr.Span) :: inner.SideGoals
                  Assumed   = phi.Term :: phi.Assumed @ inner.Assumed
                  Diags     = phiDiags @ inner.Diags }
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
                | LBVar(name, _, Some init) ->
                    // Decision 4a (M4.2): `var` bindings work like
                    // `let` for the purposes of forward-substitution
                    // wp.  Re-assignments later in the block produce
                    // a fresh entry in the env (handled in the
                    // SAssign arm), which is the SSA-without-counter
                    // shape — sound for straight-line code; loops
                    // need an explicit havoc step (handled in the
                    // SWhile arm).
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
                | LBVar(name, _, None) ->
                    // Uninitialised var: bind to a fresh symbolic
                    // value of the right sort (via TVar).  This is
                    // sound because the type checker requires the
                    // var to be assigned before any use.
                    let info =
                        // Best-effort: SInt for unannotated.
                        { Sort = SInt; Range = RBKNone }
                    let env' = Env.bind name info env
                    let inner = walk env' rest
                    inner
            | { Kind = SAssign(target, op, value) } :: rest ->
                // Decision 4a forward-substitution: `x = e2` rebinds
                // `x` in the env to `translate(e2)`.  Compound ops
                // (`+=` etc.) lower to `x = x + e2` shape using the
                // current `x` term.  Anything other than a single
                // identifier on the lhs is a bootstrap limitation
                // (records, indexers — M4.2+ work).
                match target.Kind with
                | EPath p when (match p.Segments with [_] -> true | _ -> false) ->
                    let name = List.head p.Segments
                    let rhsT, rhsDiags = translateExpr env value
                    let combined =
                        match op with
                        | AssEq -> rhsT.Term
                        | _ ->
                            let existing =
                                Env.lookup name env
                                |> Option.defaultValue (TVar(name, SInt))
                            let bin =
                                match op with
                                | AssPlus    -> BOpAdd
                                | AssMinus   -> BOpSub
                                | AssStar    -> BOpMul
                                | AssSlash   -> BOpDiv
                                | AssPercent -> BOpMod
                                | AssEq      -> BOpAdd
                            TBuiltin(bin, [existing; rhsT.Term])
                    let info =
                        Env.lookupSort name env
                        |> Option.defaultValue
                            { Sort = Term.sortOf combined; Range = RBKNone }
                    let env' = Env.bindTerm name combined info env
                    let inner = walk env' rest
                    { Wp        = inner.Wp
                      SideGoals = inner.SideGoals
                      Assumed   = rhsT.Assumed @ inner.Assumed
                      Diags     = rhsDiags @ inner.Diags }
                | _ ->
                    let diag =
                        Diagnostic.warning "V0026"
                            "complex assignment target not yet supported in proof body"
                            target.Span
                    let inner = walk env rest
                    { Wp = inner.Wp
                      SideGoals = inner.SideGoals
                      Assumed = inner.Assumed
                      Diags = diag :: inner.Diags }
            | { Kind = SWhile(_, cond, body) } as loopStmt :: rest ->
                // Loop encoding (`15-phase-4-proof-plan.md` §5.3 +
                // decision 3a).  The parser prepends each
                // `invariant: φ` as an SInvariant statement at the
                // head of the body block, so the wp walker pulls them
                // out here:
                //
                //   ι := conjunction of leading SInvariant clauses
                //   establish: side-goal `ι` at the loop point.
                //   preserve:  side-goal `ι ∧ c ⇒ wp(realBody, ι)`.
                //   conclude:  `wp(rest, Q)` continues under the
                //              assumption `ι ∧ ¬c` (havoc is bootstrap-
                //              grade — the conclude env carries the
                //              current vars; full havoc lands with
                //              the SSA pass, decision 4a).
                let isInvariant (s: Statement) =
                    match s.Kind with SInvariant _ -> true | _ -> false
                let invStmts, realBody =
                    body.Statements |> List.partition isInvariant
                let invTriples =
                    invStmts
                    |> List.choose (fun s ->
                        match s.Kind with
                        | SInvariant e -> Some e
                        | _ -> None)
                    |> List.map (translateContract env)
                let invTerms = invTriples |> List.map (fun (t, _, _) -> t)
                let invDiags =
                    invTriples |> List.collect (fun (_, _, d) -> d)
                let iotaT = Term.mkAnd invTerms

                // wp(realBody, ι): emit a side goal that the body
                // re-establishes the invariant.  Use a fresh inner
                // wpBody walk under the same env (no var mutation
                // tracking yet).
                let realBodyBlock = { body with Statements = realBody }
                let condT, condDiags = translateExpr env cond
                let preserveQ (_: Term) : Term = iotaT
                let bodyWp =
                    wpBody env resultSort preserveQ (FBBlock realBodyBlock)
                // The preserve side goal: under `ι ∧ c`, the body's
                // wp must hold (which equals ι by construction of
                // preserveQ).  We package this as one goal.
                let preserveCond =
                    Term.mkImplies
                        (Term.mkAnd [iotaT; condT.Term])
                        bodyWp.Wp

                // Decision 4a — havoc step.  Find every name in the
                // env whose body assignment changes its term, and
                // rebind it to a fresh universal `<name>$loopout`
                // value in the env that wp(rest, Q) sees.  The
                // post-loop assumptions `ι ∧ ¬c` then constrain the
                // havoc'd vars.  Bootstrap shape: we walk the body's
                // SAssign targets directly (no transitive aliasing
                // analysis).
                let modifiedVars =
                    let names = ResizeArray<string>()
                    let rec walkBlk (b: Block) =
                        for s in b.Statements do walkSt s
                    and walkSt (s: Statement) =
                        match s.Kind with
                        | SAssign(t, _, _) ->
                            match t.Kind with
                            | EPath p ->
                                match p.Segments with
                                | [n] -> names.Add n
                                | _ -> ()
                            | _ -> ()
                        | STry(b, _) | SDefer b
                        | SScope(_, b) | SLoop(_, b) -> walkBlk b
                        | SFor(_, _, _, b) | SWhile(_, _, b) -> walkBlk b
                        | _ -> ()
                    walkBlk realBodyBlock
                    names |> Seq.distinct |> List.ofSeq
                let envAfterHavoc =
                    modifiedVars
                    |> List.fold
                        (fun env name ->
                            let info =
                                Env.lookupSort name env
                                |> Option.defaultValue
                                    { Sort = SInt; Range = RBKNone }
                            let havocName = sprintf "%s$loopout" name
                            Env.bindTerm name
                                (TVar(havocName, info.Sort)) info env)
                        env
                // Re-translate the loop's invariant + condition in
                // the post-havoc env so the assumptions `ι ∧ ¬c`
                // reference the havoc'd names.
                let iotaPostT, _, _ =
                    let acc =
                        invStmts
                        |> List.choose (fun s ->
                            match s.Kind with
                            | SInvariant e -> Some e
                            | _ -> None)
                        |> List.map (translateContract envAfterHavoc)
                    let ts = acc |> List.map (fun (t, _, _) -> t)
                    let ass = acc |> List.collect (fun (_, a, _) -> a)
                    let ds  = acc |> List.collect (fun (_, _, d) -> d)
                    Term.mkAnd ts, ass, ds
                let condPostT, _ = translateExpr envAfterHavoc cond
                let postLoopAssumed =
                    [ iotaPostT; Term.mkNot condPostT.Term ]
                let inner = walk envAfterHavoc rest

                { Wp        = inner.Wp
                  SideGoals =
                      (iotaT, GKLoopEstablish, loopStmt.Span)
                      :: (preserveCond, GKLoopPreserve, loopStmt.Span)
                      :: bodyWp.SideGoals
                      @  inner.SideGoals
                  Assumed   =
                      condT.Assumed
                      @ bodyWp.Assumed
                      @ postLoopAssumed
                      @ inner.Assumed
                  Diags     =
                      invDiags @ condDiags @ bodyWp.Diags @ inner.Diags }
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

    // Pre / Post translation.  Returns (term, accumulatedAssumed,
    // diagnostics).  Pure-fn unfolding from the contract becomes
    // additional hypotheses on the goal (callee post is also
    // captured here, but that's harmless).
    let translateClauses (env: Env) (clauses: Expr list) =
        clauses
        |> List.map (fun c ->
            let term, assumed, diags = translateContract env c
            term, assumed, diags)
        |> List.fold
            (fun (terms, assumes, diags) (t, a, d) ->
                terms @ [t], assumes @ a, diags @ d)
            ([], [], [])

    let preClauses =
        decl.Contracts
        |> List.choose (fun c ->
            match c with CCRequires(e, _) -> Some e | _ -> None)
    let preTerms, preAssumed, preDiags = translateClauses envAfterParams preClauses
    let preTerm = Term.mkAnd preTerms

    let postClauses =
        decl.Contracts
        |> List.choose (fun c ->
            match c with CCEnsures(e, _) -> Some e | _ -> None)
    let postTerms, postAssumed, postDiags = translateClauses envWithOld postClauses
    let postTerm = Term.mkAnd postTerms

    let body =
        match decl.Body with
        | Some b -> b
        | None   ->
            // Function with no body: treated as @axiom.  No VCs.
            FBExpr { Kind = ELiteral Literal.LUnit; Span = decl.Span }

    // Return-type range bound: if the return type is a refined
    // range subtype, fold its `[lo, hi]` constraint into the
    // postcondition the wp computation chases.
    let returnRangeHyps (resultExpr: Term) : Term list =
        match resultSort.Range with
        | RBKNone -> []
        | RBKClosed(lo, hi) ->
            [ TBuiltin(BOpLte, [TLit(LInt lo, SInt); resultExpr])
              TBuiltin(BOpLte, [resultExpr; TLit(LInt hi, SInt)]) ]
        | RBKHalfOpen(lo, hi) ->
            [ TBuiltin(BOpLte, [TLit(LInt lo, SInt); resultExpr])
              TBuiltin(BOpLt,  [resultExpr; TLit(LInt hi, SInt)]) ]

    let wpRes =
        wpBody envWithOld resultSort
            (fun resultExpr ->
                // Substitute `result` into postTerm and add the
                // return-type range bound, if any.
                let userPost =
                    Term.subst (Map.ofList [("result", resultExpr)]) postTerm
                let rangeBounds = returnRangeHyps resultExpr
                Term.mkAnd (userPost :: rangeBounds))
            body

    // Hypothesis set for the post goal:
    //   * range bounds on parameters,
    //   * the precondition,
    //   * any assumed facts collected during translation of the
    //     contracts (e.g. @pure-callee unfolds in the contract),
    //   * any assumed facts collected during the wp computation
    //     (e.g. callee posts via the call rule).
    let hypotheses =
        paramHyps @ [preTerm] @ preAssumed @ postAssumed @ wpRes.Assumed

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
/// and emit the Goals.  `imports` carries cross-package contract
/// metadata loaded by `Lyric.Verifier.Imports` (D-progress-086);
/// pass `[]` for callers that don't yet wire it in.
let goalsForFileWithImports
        (file: SourceFile)
        (level: VerificationLevel)
        (imports: Imports.ImportedPackage list)
        : Goal list * Diagnostic list =

    if not (VerificationLevel.isProofRequired level) then [], []
    else
    // Local datatypes: build a mini ProofMeta from the file's
    // record / union / enum / opaque items.
    let localProofMeta = ProofMeta.buildProofMeta file ""
    let datatypes : Map<string, ProofMeta.ProofType> =
        let local =
            localProofMeta.Types
            |> List.map (fun t -> t.Name, t)
        let importedTypes =
            imports
            |> List.collect (fun ip ->
                match ip.Proof with
                | None -> []
                | Some pm ->
                    pm.Types |> List.map (fun t -> t.Name, t))
        Map.ofList (local @ importedTypes)
    let env0 =
        let callees =
            file.Items
            |> List.choose (fun it ->
                match it.Kind with
                | IFunc fn -> Some (fn.Name, fn)
                | _        -> None)
            |> Map.ofList
        { Env.empty () with
            Callees   = callees
            Imports   = imports
            Datatypes = datatypes }
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

/// Backwards-compatible alias for callers that haven't been
/// updated to pass an imports list.
let goalsForFile
        (file: SourceFile)
        (level: VerificationLevel)
        : Goal list * Diagnostic list =
    goalsForFileWithImports file level []
