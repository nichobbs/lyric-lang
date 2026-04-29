/// Type-check (more accurately, type-infer) expressions. Inference is
/// shallow — there's no Hindley-Milner unification yet — but it's
/// enough to surface argument-arity, primitive-mismatch, and
/// unknown-name errors against the worked examples.
module Lyric.TypeChecker.ExprChecker

open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.TypeChecker
open Lyric.TypeChecker.Symbols

let private err (env: CheckEnv) (code: string) (msg: string) (span: Span) : unit =
    CheckEnv.report env (Diagnostic.error code msg span)

let private inferLiteral (lit: Literal) : Type =
    match lit with
    | LUnit         -> Type.unit'
    | LBool _       -> Type.bool'
    | LInt _        -> Type.int'
    | LFloat _      -> Type.double'
    | LChar _       -> Type.char'
    | LString _     -> Type.string'
    | LTripleString _ -> Type.string'
    | LRawString _    -> Type.string'

/// Look up a single-segment path. Order: locals → values (top-level) →
/// union/enum cases (treated as values) → fall through to a TyError
/// with diagnostic.
let private lookupShortPath (env: CheckEnv) (name: string) (span: Span) : Type =
    match CheckEnv.tryLookupLocal env name with
    | Some t -> t
    | None ->
        match SymbolTable.tryLookupValueShort env.Symbols name with
        | Some sym ->
            match sym.Kind with
            | VskFunc rs ->
                Type.TyFunction (rs.Params, rs.Return)
            | VskVal t | VskConst t | VskLocal t | VskParam t -> t
            | VskEnumCase tn -> Type.TyNamed tn
            | VskUnionCase (tn, []) -> Type.TyNamed tn
            | VskUnionCase (tn, fields) ->
                let pTys = fields |> List.map snd
                Type.TyFunction (pTys, Type.TyNamed tn)
        | None ->
            match SymbolTable.tryLookupTypeShort env.Symbols name with
            | Some sym ->
                // A bare type name is OK when it's used as a static
                // receiver for a method call (e.g. `Cents.tryFrom(x)`).
                // Carrying it as `TyNamed` lets the postfix `.IDENT`
                // case decide.
                Type.TyNamed sym.Name
            | None ->
                err env "T0010" (sprintf "unknown name '%s'" name) span
                Type.error'

let private lookupQualifiedPath (env: CheckEnv) (segs: string list) (span: Span) : Type =
    match SymbolTable.tryLookupValueQualified env.Symbols segs with
    | Some sym ->
        match sym.Kind with
        | VskFunc rs ->
            Type.TyFunction (rs.Params, rs.Return)
        | VskVal t | VskConst t | VskLocal t | VskParam t -> t
        | VskEnumCase tn -> Type.TyNamed tn
        | VskUnionCase (tn, []) -> Type.TyNamed tn
        | VskUnionCase (tn, fields) ->
            let pTys = fields |> List.map snd
            Type.TyFunction (pTys, Type.TyNamed tn)
    | None ->
        match SymbolTable.tryLookupTypeQualified env.Symbols segs with
        | Some sym -> Type.TyNamed sym.Name
        | None     -> Type.TyNamed segs   // tolerated; extern/imported

let rec inferExpr (env: CheckEnv) (e: Expr) : Type =
    match e.Kind with
    | ELiteral lit  -> inferLiteral lit
    | EInterpolated _ -> Type.string'
    | EPath path ->
        match path.Segments with
        | [name] -> lookupShortPath env name path.Span
        | segs   -> lookupQualifiedPath env segs path.Span
    | EParen inner -> inferExpr env inner
    | ETuple es    -> Type.TyTuple (es |> List.map (inferExpr env))
    | EList es ->
        // Element type = type of first element; all others must be
        // compatible. Empty list defaults to slice[Error] under
        // Phase 1's no-inference rules.
        match es with
        | [] -> Type.TySlice Type.error'
        | first :: rest ->
            let firstTy = inferExpr env first
            for r in rest do
                let rt = inferExpr env r
                if not (Type.compatible firstTy rt) then
                    err env "T0020"
                        (sprintf "list element type %s mismatches first element %s"
                            (Type.render rt) (Type.render firstTy))
                        r.Span
            Type.TySlice firstTy
    | EIf (cond, thenB, elseB, _) ->
        let cTy = inferExpr env cond
        if not (Type.compatible Type.bool' cTy) then
            err env "T0021"
                (sprintf "'if' condition has type %s, expected Bool" (Type.render cTy))
                cond.Span
        let thenTy = inferBranch env thenB
        match elseB with
        | Some eb ->
            let elseTy = inferBranch env eb
            if Type.compatible thenTy elseTy then thenTy
            elif Type.compatible elseTy thenTy then elseTy
            else
                err env "T0022"
                    (sprintf "'if' branches differ: %s vs %s"
                        (Type.render thenTy) (Type.render elseTy))
                    e.Span
                Type.error'
        | None -> Type.unit'
    | EMatch (scr, arms) ->
        let _ = inferExpr env scr
        match arms with
        | [] -> Type.error'
        | first :: rest ->
            let firstTy = inferBranch env first.Body
            for arm in rest do
                let _ = inferBranch env arm.Body
                ()
            firstTy
    | EAwait inner ->
        let t = inferExpr env inner
        match t with
        | Type.TyApp (Type.TyNamed ["Task"], [a]) -> a
        | _ -> t
    | ESpawn inner ->
        let t = inferExpr env inner
        Type.TyApp (Type.TyNamed ["Task"], [t])
    | ETry inner ->
        let _ = inferExpr env inner
        Type.error'
    | EOld inner -> inferExpr env inner
    | EForall _ | EExists _ -> Type.bool'
    | ESelf ->
        match env.SelfTy with
        | Some t -> t
        | None ->
            err env "T0030" "'self' used outside of a method" e.Span
            Type.error'
    | EResult -> env.Return
    | ELambda (lambdaParams, body) ->
        // Resolve the parameter types we have annotations for.
        let pTys =
            lambdaParams |> List.map (fun lp ->
                match lp.Type with
                | Some t -> Resolver.resolve env t
                | None   -> Type.error')
        // Stub-builder DSL bodies (`{ it.foo() -> bar; … }`) parse
        // as a block of `SRule` statements with no parameters and no
        // return value. Treat the lambda as `Unit` in that case.
        Type.TyFunction (pTys, Type.unit')
    | ECall (fn, args) ->
        let fnTy = inferExpr env fn
        let argTys =
            args |> List.map (fun a ->
                match a with
                | CAPositional e | CANamed (_, e, _) -> inferExpr env e)
        match fnTy with
        | Type.TyFunction (paramTys, retTy) ->
            if List.length paramTys <> List.length argTys then
                err env "T0040"
                    (sprintf "expected %d argument(s), got %d"
                        (List.length paramTys) (List.length argTys))
                    e.Span
                retTy
            else
                List.iter2
                    (fun expected actual ->
                        if not (Type.compatible expected actual) then
                            err env "T0041"
                                (sprintf "argument type %s incompatible with parameter %s"
                                    (Type.render actual) (Type.render expected))
                                e.Span)
                    paramTys argTys
                retTy
        | Type.TyError -> Type.error'
        | Type.TyNamed _ ->
            // Treat as a constructor call — we don't track type
            // shapes well enough to verify. Return the named type.
            fnTy
        | _ ->
            err env "T0042"
                (sprintf "call target has non-function type %s" (Type.render fnTy))
                e.Span
            Type.error'
    | ETypeApp (fn, _) -> inferExpr env fn
    | EIndex (recv, _) ->
        let rt = inferExpr env recv
        match rt with
        | Type.TyArray (_, e) | Type.TySlice e -> e
        | _ -> Type.error'
    | EMember (recv, name) ->
        let rt = inferExpr env recv
        memberType env rt name e.Span
    | EPropagate inner ->
        let t = inferExpr env inner
        match t with
        | Type.TyApp (Type.TyNamed ["Result"], [ok; _]) -> ok
        | Type.TyApp (Type.TyNamed ["Option"], [a])     -> a
        | _ -> t
    | EPrefix (op, operand) ->
        let t = inferExpr env operand
        match op with
        | PreNeg -> t
        | PreNot ->
            if not (Type.compatible Type.bool' t) then
                err env "T0050"
                    (sprintf "operator 'not' requires Bool, got %s" (Type.render t))
                    operand.Span
            Type.bool'
        | PreRef -> t
    | EBinop (op, lhs, rhs) ->
        let lt = inferExpr env lhs
        let rt = inferExpr env rhs
        inferBinop env op lt rt e.Span
    | ERange _ ->
        // A range expression in value position is a slice — the
        // backing iterator's element type matches the bounds. We
        // don't track that yet; fall back to TyError.
        Type.error'
    | EAssign _ -> Type.unit'
    | EBlock blk ->
        // The diverging-statement wrapper. Type it as Never.
        ignore blk
        Type.never'
    | EError -> Type.error'

and private inferBranch (env: CheckEnv) (b: ExprOrBlock) : Type =
    match b with
    | EOBExpr e -> inferExpr env e
    | EOBBlock blk ->
        // Phase 1: a block's value is the type of its trailing
        // expression statement. Without one, the block is `Unit`.
        match List.tryLast blk.Statements with
        | Some { Kind = SExpr e } -> inferExpr env e
        | _ -> Type.unit'

and private inferBinop (env: CheckEnv) (op: BinOp) (lt: Type) (rt: Type) (span: Span) : Type =
    let arith () =
        if Type.compatible lt rt then lt
        elif Type.compatible rt lt then rt
        else
            err env "T0051"
                (sprintf "operands of arithmetic operator differ: %s and %s"
                    (Type.render lt) (Type.render rt))
                span
            Type.error'
    let cmp () =
        if not (Type.compatible lt rt) && not (Type.compatible rt lt) then
            err env "T0052"
                (sprintf "operands of comparison differ: %s and %s"
                    (Type.render lt) (Type.render rt))
                span
        Type.bool'
    let logical () =
        if not (Type.compatible Type.bool' lt) then
            err env "T0053"
                (sprintf "logical operator requires Bool on the left, got %s" (Type.render lt))
                span
        if not (Type.compatible Type.bool' rt) then
            err env "T0053"
                (sprintf "logical operator requires Bool on the right, got %s" (Type.render rt))
                span
        Type.bool'
    match op with
    | BAdd | BSub | BMul | BDiv | BMod -> arith ()
    | BAnd | BOr | BXor                -> logical ()
    | BEq | BNeq | BLt | BLte | BGt | BGte -> cmp ()
    | BCoalesce ->
        match lt with
        | Type.TyNullable inner -> if Type.compatible inner rt then inner else rt
        | _ -> if Type.compatible lt rt then lt else rt
    | BImplies -> logical ()

and private memberType (env: CheckEnv) (rt: Type) (name: string) (span: Span) : Type =
    match rt with
    | Type.TyError -> Type.error'
    | Type.TyNamed segs ->
        // Type-as-receiver static method call. The shape of the type's
        // associated functions isn't tracked yet, so we fall back to
        // TyError (no diagnostic — the call site will adapt).
        match SymbolTable.tryLookupTypeQualified env.Symbols segs with
        | Some sym ->
            match sym.Kind with
            | TskRecord fields | TskExposedRec fields ->
                match List.tryFind (fun (n, _) -> n = name) fields with
                | Some (_, t) -> t
                | None        -> Type.error'
            | TskInterface methods ->
                match List.tryFind (fun (n, _) -> n = name) methods with
                | Some (_, rs) -> Type.TyFunction (rs.Params, rs.Return)
                | None         -> Type.error'
            | TskUnion cases ->
                match List.tryFind (fun (n, _) -> n = name) cases with
                | Some (_, []) -> Type.TyNamed sym.Name
                | Some (_, fields) ->
                    let pTys = fields |> List.map snd
                    Type.TyFunction (pTys, Type.TyNamed sym.Name)
                | None -> Type.error'
            | TskEnum cases ->
                if List.contains name cases then Type.TyNamed sym.Name
                else Type.error'
            | _ -> Type.error'
        | None -> Type.error'
    | Type.TyApp (Type.TyNamed segs, _) ->
        // Generic instantiation: defer to the head's members for now.
        memberType env (Type.TyNamed segs) name span
    | Type.TyTuple ts ->
        // `t.0`, `t.1`, …
        match System.Int32.TryParse name with
        | true, i when i >= 0 && i < List.length ts -> ts.[i]
        | _ -> Type.error'
    | _ -> Type.error'
