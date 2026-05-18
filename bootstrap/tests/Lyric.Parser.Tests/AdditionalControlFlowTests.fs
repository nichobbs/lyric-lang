module Lyric.Parser.Tests.AdditionalControlFlowTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private prelude = "package P\n"

let private parseFnClean (body: string) =
    let src = prelude + sprintf "func f(): Int %s" body
    let r = parse src
    Expect.isEmpty r.Diagnostics
        (sprintf "diagnostics for body %A: %A" body r.Diagnostics)
    match r.File.Items.[0].Kind with
    | IFunc fn ->
        match fn.Body with
        | Some (FBBlock blk) -> blk
        | Some (FBExpr e) ->
            { Statements = [{ Kind = SExpr e; Span = e.Span }]; Span = e.Span }
        | None -> failtest "no body"
    | other -> failtestf "expected IFunc, got %A" other

let private firstStmt (blk: Block) : Statement =
    Expect.isGreaterThanOrEqual blk.Statements.Length 1 "at least one stmt"
    blk.Statements.[0]

let private parseExprClean (src: string) : Expr =
    let e, diags = parseExprFromString src
    Expect.isEmpty diags (sprintf "expected no diagnostics for %A" src)
    e

let tests =
    testList "control-flow expressions (additional)" [

        // ----- lambda parameter forms -----

        test "lambda with one typed parameter" {
            let blk = parseFnClean "{ val sq = { x: Int -> x * x } ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVal(_, _, { Kind = ELambda([p], _) })) ->
                Expect.equal p.Name "x" "param name"
                Expect.isSome p.Type "param type annotation present"
                match p.Type with
                | Some { Kind = TRef pa } ->
                    Expect.equal pa.Segments ["Int"] "Int annotation"
                | other -> failtestf "expected TRef Int, got %A" other
            | other -> failtestf "expected ELambda, got %A" other
        }

        test "lambda with multiple untyped parameters" {
            let blk = parseFnClean "{ val add = { x, y -> x + y } ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVal(_, _, { Kind = ELambda(ps, _) })) ->
                Expect.equal ps.Length 2 "two params"
                Expect.equal ps.[0].Name "x" "first param name"
                Expect.equal ps.[1].Name "y" "second param name"
                Expect.isNone ps.[0].Type "first param has no type"
                Expect.isNone ps.[1].Type "second param has no type"
            | other -> failtestf "expected ELambda, got %A" other
        }

        test "lambda with two typed parameters" {
            let blk =
                parseFnClean
                    "{ val add = { x: Int, y: Int -> x + y } ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVal(_, _, { Kind = ELambda(ps, _) })) ->
                Expect.equal ps.Length 2 "two params"
                Expect.isSome ps.[0].Type "x type present"
                Expect.isSome ps.[1].Type "y type present"
            | other -> failtestf "expected ELambda, got %A" other
        }

        test "body-only lambda has no params" {
            // `{ stmt }` with no `->` parses as a zero-param lambda.
            let blk = parseFnClean "{ val k = { 42 } ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVal(_, _, { Kind = ELambda([], body) })) ->
                Expect.equal body.Statements.Length 1 "one stmt"
            | other -> failtestf "expected zero-param ELambda, got %A" other
        }

        test "lambda with mixed typed and untyped params" {
            let blk =
                parseFnClean
                    "{ val f = { x: Int, y -> x } ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVal(_, _, { Kind = ELambda(ps, _) })) ->
                Expect.equal ps.Length 2 "two params"
                Expect.isSome ps.[0].Type "x typed"
                Expect.isNone ps.[1].Type "y untyped"
            | other -> failtestf "expected ELambda, got %A" other
        }

        // ----- try / catch clauses -----

        test "try with one catch" {
            let blk =
                parseFnClean
                    "{ try { val x = 1 } catch IOException { val y = 2 } ; return 0 }"
            match (firstStmt blk).Kind with
            | STry(_, [c]) ->
                Expect.equal c.Type "IOException" "catch type"
                Expect.isNone c.Bind "no bind"
            | other -> failtestf "expected STry one catch, got %A" other
        }

        test "try with catch as bound name" {
            let blk =
                parseFnClean
                    "{ try { val x = 1 } catch IOException as e { val y = 2 } ; return 0 }"
            match (firstStmt blk).Kind with
            | STry(_, [c]) ->
                Expect.equal c.Type "IOException" "catch type"
                Expect.equal c.Bind (Some "e") "bound to e"
            | other -> failtestf "expected STry catch-as, got %A" other
        }

        test "try with multiple catches" {
            let blk =
                parseFnClean
                    "{ try { } catch IOException { } catch RuntimeException { } ; return 0 }"
            match (firstStmt blk).Kind with
            | STry(_, cs) ->
                Expect.equal cs.Length 2 "two catch clauses"
                Expect.equal cs.[0].Type "IOException" "first type"
                Expect.equal cs.[1].Type "RuntimeException" "second type"
            | other -> failtestf "expected STry, got %A" other
        }

        test "try with catch missing identifier after 'as' is P0220" {
            let src = prelude + "func f(): Int { try { } catch IOException as { } }"
            let r = parse src
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0220" "P0220 emitted"
        }

        // ----- quantifier expressions (forall / exists) -----

        test "forall expression in contract requires-shape" {
            // forall over an Int with `implies` body — typical contract form.
            let e =
                parseExprClean "forall (n: Int) implies n + 0 == n"
            match e.Kind with
            | EForall(binders, w, _) ->
                Expect.equal binders.Length 1 "one binder"
                Expect.equal binders.[0].Name "n" "binder name"
                Expect.isNone w "no where clause"
            | other -> failtestf "expected EForall, got %A" other
        }

        test "exists expression with where clause" {
            let e =
                parseExprClean "exists (x: Int) where x > 0 implies x * x > 0"
            match e.Kind with
            | EExists(binders, w, _) ->
                Expect.equal binders.[0].Name "x" "binder name"
                Expect.isSome w "where clause present"
            | other -> failtestf "expected EExists, got %A" other
        }

        test "forall with multi-binder list" {
            let e =
                parseExprClean
                    "forall (a: Int, b: Int) implies a + b == b + a"
            match e.Kind with
            | EForall(binders, _, _) ->
                Expect.equal binders.Length 2 "two binders"
                Expect.equal binders.[0].Name "a" "a"
                Expect.equal binders.[1].Name "b" "b"
            | other -> failtestf "expected EForall, got %A" other
        }

        test "forall missing '(' is P0302" {
            let _, diags = parseExprFromString "forall x: Int implies true"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "P0302" "P0302 emitted"
        }

        test "forall missing ':' in binder is P0301" {
            let _, diags = parseExprFromString "forall (x Int) implies true"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "P0301" "P0301 emitted"
        }

        test "forall missing ')' is P0303" {
            let _, diags = parseExprFromString "forall (x: Int implies true"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "P0303" "P0303 emitted"
        }

        // ----- contract clauses on top-level functions -----

        test "function contract with 'when' clause" {
            let src =
                prelude
                + "func f(x: in Int): Int when: x > 0 = x"
            let r = parse src
            Expect.isEmpty r.Diagnostics "clean parse"
            match r.File.Items.[0].Kind with
            | IFunc fn ->
                Expect.equal fn.Contracts.Length 1 "one clause"
                match fn.Contracts.[0] with
                | CCWhen(_, _) -> ()
                | other -> failtestf "expected CCWhen, got %A" other
            | other -> failtestf "expected IFunc, got %A" other
        }

        test "missing ':' after 'requires' is P0170" {
            // contract clause without colon
            let r =
                parse
                    (prelude
                     + "func f(x: in Int): Int requires x > 0 = x")
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0170" "P0170 emitted"
        }

        test "function with 'ensures' clause referencing 'result'" {
            let src =
                prelude
                + "func dbl(x: in Int): Int ensures: result == x * 2 = x * 2"
            let r = parse src
            Expect.isEmpty r.Diagnostics "clean parse"
            match r.File.Items.[0].Kind with
            | IFunc fn ->
                Expect.equal fn.Contracts.Length 1 "one clause"
                match fn.Contracts.[0] with
                | CCEnsures(_, _) -> ()
                | other -> failtestf "expected CCEnsures, got %A" other
            | other -> failtestf "expected IFunc, got %A" other
        }

        test "missing protected-entry body is P0172" {
            // `parseFunctionBody` is called unconditionally for protected
            // entries; if the next token isn't '=' or '{', P0172 fires.
            let r =
                parse
                    (prelude
                     + "protected type T { entry e(): Int }")
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0172" "P0172 emitted"
        }
    ]
