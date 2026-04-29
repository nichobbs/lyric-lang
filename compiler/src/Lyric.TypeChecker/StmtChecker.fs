/// Type-check statements and function bodies. Locals enter the
/// current scope; `return` is checked against the enclosing function's
/// return type; control-flow statements descend into nested scopes.
module Lyric.TypeChecker.StmtChecker

open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.TypeChecker
open Lyric.TypeChecker.Symbols
open Lyric.TypeChecker.ExprChecker

let private err (env: CheckEnv) (code: string) (msg: string) (span: Span) : unit =
    CheckEnv.report env (Diagnostic.error code msg span)

/// Bind every name introduced by a value-pattern. The narrowest
/// binding wins; we don't enforce exhaustivity here.
let rec private bindPattern (env: CheckEnv) (pat: Pattern) (ty: Type) : unit =
    match pat.Kind with
    | PBinding (name, innerOpt) ->
        CheckEnv.addLocal env name ty
        match innerOpt with
        | Some inner -> bindPattern env inner ty
        | None       -> ()
    | PWildcard | PLiteral _ -> ()
    | PTuple subs ->
        match ty with
        | Type.TyTuple ts when List.length ts = List.length subs ->
            List.iter2 (bindPattern env) subs ts
        | _ ->
            for s in subs do bindPattern env s Type.error'
    | PRecord (_, fields, _) ->
        for f in fields do
            match f with
            | RPFNamed (_, p, _) -> bindPattern env p Type.error'
            | RPFShort (n, _)    -> CheckEnv.addLocal env n Type.error'
    | PConstructor (_, subs) ->
        for s in subs do bindPattern env s Type.error'
    | PParen inner | PTypeTest (inner, _) ->
        bindPattern env inner ty
    | PRange _ | POr _ -> ()
    | PError -> ()

let private resolveLocalType (env: CheckEnv) (annot: TypeExpr option) (init: Type) : Type =
    match annot with
    | Some t ->
        let declared = Resolver.resolve env t
        if not (Type.compatible declared init) then
            err env "T0060"
                (sprintf "initializer type %s incompatible with declared type %s"
                    (Type.render init) (Type.render declared))
                t.Span
        declared
    | None -> init

let rec checkStatement (env: CheckEnv) (stmt: Statement) : unit =
    match stmt.Kind with
    | SLocal (LBVal (pat, annot, init)) ->
        let initTy = inferExpr env init
        let ty     = resolveLocalType env annot initTy
        bindPattern env pat ty
    | SLocal (LBVar (name, annot, initOpt)) ->
        let ty =
            match initOpt with
            | Some init ->
                let it = inferExpr env init
                resolveLocalType env annot it
            | None ->
                match annot with
                | Some t -> Resolver.resolve env t
                | None ->
                    err env "T0061"
                        (sprintf "'var %s' needs either a type annotation or an initializer" name)
                        stmt.Span
                    Type.error'
        CheckEnv.addLocal env name ty
    | SLocal (LBLet (name, annot, init)) ->
        let initTy = inferExpr env init
        let ty     = resolveLocalType env annot initTy
        CheckEnv.addLocal env name ty
    | SAssign (target, _, value) ->
        let lt = inferExpr env target
        let rt = inferExpr env value
        if not (Type.compatible lt rt) then
            err env "T0062"
                (sprintf "assignment value type %s incompatible with target type %s"
                    (Type.render rt) (Type.render lt))
                stmt.Span
    | SReturn None ->
        if not (Type.compatible env.Return Type.unit') then
            err env "T0063"
                (sprintf "'return' without value in function returning %s"
                    (Type.render env.Return))
                stmt.Span
    | SReturn (Some e) ->
        let t = inferExpr env e
        if not (Type.compatible env.Return t) then
            err env "T0064"
                (sprintf "'return' value of type %s incompatible with declared %s"
                    (Type.render t) (Type.render env.Return))
                stmt.Span
    | SBreak _ | SContinue _ -> ()
    | SThrow e ->
        let _ = inferExpr env e
        ()
    | STry (body, catches) ->
        checkBlock env body
        for c in catches do
            CheckEnv.pushScope env
            (match c.Bind with
             | Some n -> CheckEnv.addLocal env n Type.error'
             | None   -> ())
            checkBlock env c.Body
            CheckEnv.popScope env
    | SDefer body | SScope (_, body) ->
        CheckEnv.pushScope env
        checkBlock env body
        CheckEnv.popScope env
    | SFor (_, pat, iter, body) ->
        let iterTy = inferExpr env iter
        let elemTy =
            match iterTy with
            | Type.TyArray (_, e) | Type.TySlice e -> e
            | _ -> Type.error'
        CheckEnv.pushScope env
        bindPattern env pat elemTy
        checkBlock env body
        CheckEnv.popScope env
    | SWhile (_, cond, body) ->
        let ct = inferExpr env cond
        if not (Type.compatible Type.bool' ct) then
            err env "T0065"
                (sprintf "'while' condition has type %s, expected Bool" (Type.render ct))
                cond.Span
        CheckEnv.pushScope env
        checkBlock env body
        CheckEnv.popScope env
    | SLoop (_, body) ->
        CheckEnv.pushScope env
        checkBlock env body
        CheckEnv.popScope env
    | SExpr e ->
        let _ = inferExpr env e
        ()
    | SRule (_, _) ->
        // Stub-builder DSL entries are accepted but not type-checked
        // in Phase 1; the stub-builder type machinery isn't online yet.
        ()
    | SItem _ ->
        // Nested item declarations are recorded by the pre-pass; the
        // body checker doesn't recurse into them.
        ()

and checkBlock (env: CheckEnv) (blk: Block) : unit =
    CheckEnv.pushScope env
    for stmt in blk.Statements do
        checkStatement env stmt
    CheckEnv.popScope env

/// Type-check a function body against its resolved signature.
let checkFunctionBody (env: CheckEnv) (fd: FunctionDecl) (sig': ResolvedSig) : unit =
    let savedReturn = env.Return
    env.Return <- sig'.Return
    CheckEnv.pushScope env
    // Bind parameters into the body scope.
    List.iter2
        (fun (p: Param) (t: Type) -> CheckEnv.addLocal env p.Name t)
        fd.Params sig'.Params
    match fd.Body with
    | None -> ()
    | Some (FBExpr ({ Kind = ELambda ([], blk) } as _)) ->
        // `func foo(): T = { ... }` — parser sees the `=` and parses
        // `{...}` as a zero-argument lambda. Treat it as the block
        // body it morally is.
        for stmt in blk.Statements do
            checkStatement env stmt
        let last =
            match List.tryLast blk.Statements with
            | Some { Kind = SExpr e } -> ExprChecker.inferExpr env e
            | _ -> Type.unit'
        if not (Type.compatible sig'.Return last) then
            err env "T0070"
                (sprintf "block-bodied function returns %s but signature is %s"
                    (Type.render last) (Type.render sig'.Return))
                blk.Span
    | Some (FBExpr e) ->
        let t = inferExpr env e
        if not (Type.compatible sig'.Return t) then
            err env "T0070"
                (sprintf "expression-bodied function returns %s but signature is %s"
                    (Type.render t) (Type.render sig'.Return))
                e.Span
    | Some (FBBlock blk) ->
        for stmt in blk.Statements do
            checkStatement env stmt
    CheckEnv.popScope env
    env.Return <- savedReturn
