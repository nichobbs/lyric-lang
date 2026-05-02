module Lyric.Parser.Tests.AdditionalStatementTests

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

let private firstStmt (blk: Block) : Statement = blk.Statements.[0]

let tests =
    testList "additional statement / control-flow forms" [

        // ----- val with pattern binding -----

        test "val with tuple pattern" {
            let blk = parseFnClean "{ val (a, b) = (1, 2) ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVal({ Kind = PTuple [_; _] }, _, _)) -> ()
            | other -> failtestf "expected LBVal tuple, got %A" other
        }

        test "val with constructor pattern" {
            let blk = parseFnClean "{ val Some(x) = maybe ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVal({ Kind = PConstructor _ }, _, _)) -> ()
            | other -> failtestf "expected LBVal ctor, got %A" other
        }

        test "var with type annotation but no init" {
            let blk = parseFnClean "{ var n: Int ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVar(_, Some _, None)) -> ()
            | other -> failtestf "expected LBVar with type, no init, got %A" other
        }

        test "var with type and init" {
            let blk = parseFnClean "{ var x: Int = 0 ; return x }"
            match (firstStmt blk).Kind with
            | SLocal (LBVar(_, Some _, Some _)) -> ()
            | other -> failtestf "expected LBVar with type and init, got %A" other
        }

        // ----- break with value  -----

        test "break without label" {
            let blk = parseFnClean "{ do { break } ; return 0 }"
            match (firstStmt blk).Kind with
            | SLoop(None, body) ->
                match body.Statements.[0].Kind with
                | SBreak None -> ()
                | other -> failtestf "expected SBreak None, got %A" other
            | other -> failtestf "expected SLoop, got %A" other
        }

        test "continue with label" {
            let blk = parseFnClean "{ do { continue outer } ; return 0 }"
            match (firstStmt blk).Kind with
            | SLoop(_, body) ->
                match body.Statements.[0].Kind with
                | SContinue (Some "outer") -> ()
                | other -> failtestf "expected SContinue outer, got %A" other
            | other -> failtestf "expected SLoop, got %A" other
        }

        // ----- compound assignment forms -----

        test "all five compound assignment ops" {
            let cases : (string * AssignOp) list =
                [ "+=", AssPlus
                  "-=", AssMinus
                  "*=", AssStar
                  "/=", AssSlash
                  "%=", AssPercent ]
            for op, expected in cases do
                let body = sprintf "{ var x: Int = 0 ; x %s 1 ; return x }" op
                let blk = parseFnClean body
                match blk.Statements.[1].Kind with
                | SAssign(_, actual, _) when actual = expected -> ()
                | other -> failtestf "%s: %A" op other
        }

        // ----- if/match -----

        test "block-form if with else block" {
            let blk = parseFnClean "{ if c { return 1 } else { return 2 } }"
            match (firstStmt blk).Kind with
            | SExpr { Kind = EIf(_, EOBBlock _, Some (EOBBlock _), false) } -> ()
            | other -> failtestf "shape: %A" other
        }

        test "match with three arms" {
            let blk = parseFnClean
                        "{ return match x { case 0 -> 0, case 1 -> 1, case _ -> 2 } }"
            match (firstStmt blk).Kind with
            | SReturn (Some { Kind = EMatch(_, arms) }) ->
                Expect.equal arms.Length 3 "three arms"
            | other -> failtestf "shape: %A" other
        }

        test "match arm with where-guard" {
            let blk = parseFnClean
                        "{ return match x { case n where n > 0 -> n, case _ -> 0 } }"
            match (firstStmt blk).Kind with
            | SReturn (Some { Kind = EMatch(_, [arm; _]) }) ->
                Expect.isSome arm.Guard "where-guard present"
            | other -> failtestf "shape: %A" other
        }

        // ----- for / while -----

        test "for loop with destructuring pattern" {
            let blk = parseFnClean "{ for (k, v) in pairs { } ; return 0 }"
            match (firstStmt blk).Kind with
            | SFor(_, { Kind = PTuple [_; _] }, _, _) -> ()
            | other -> failtestf "shape: %A" other
        }

        test "while-let style — `while c` only, no let-binding" {
            let blk = parseFnClean "{ while x > 0 { x = x - 1 } ; return 0 }"
            match (firstStmt blk).Kind with
            | SWhile(_, _, body) ->
                Expect.equal body.Statements.Length 1 "one body stmt"
            | other -> failtestf "shape: %A" other
        }

        // ----- try / catch -----

        test "try with no catches" {
            let blk = parseFnClean "{ try { } ; return 0 }"
            match (firstStmt blk).Kind with
            | STry(_, []) -> ()
            | other -> failtestf "expected STry no catches, got %A" other
        }

        // ----- defer -----

        test "defer block" {
            let blk = parseFnClean "{ defer { } ; return 0 }"
            match (firstStmt blk).Kind with
            | SDefer _ -> ()
            | other -> failtestf "expected SDefer, got %A" other
        }

        // ----- scope -----

        test "scope block" {
            let blk = parseFnClean "{ scope { } ; return 0 }"
            match (firstStmt blk).Kind with
            | SScope _ -> ()
            | other -> failtestf "expected SScope, got %A" other
        }

        // ----- expression statements -----

        test "function call as expression statement" {
            let blk = parseFnClean "{ doIt() ; return 0 }"
            match (firstStmt blk).Kind with
            | SExpr { Kind = ECall _ } -> ()
            | other -> failtestf "expected SExpr ECall, got %A" other
        }

        test "interpolated string in val init" {
            let blk =
                parseFnClean "{ val s = \"hi ${name}\" ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVal(_, _, { Kind = EInterpolated _ })) -> ()
            | other -> failtestf "expected interpolated, got %A" other
        }

        // ----- semicolons separate statements -----

        test "multiple statements via semicolons" {
            let blk = parseFnClean "{ val a = 1 ; val b = 2 ; return a + b }"
            Expect.equal blk.Statements.Length 3 "three statements"
        }

        test "multiple statements via newlines" {
            let body = """{
                val a = 1
                val b = 2
                return a + b
            }"""
            let blk = parseFnClean body
            Expect.equal blk.Statements.Length 3 "three statements"
        }

        // ----- assignments to compound targets -----

        test "assignment to a member" {
            let blk = parseFnClean "{ self.count = 0 ; return 0 }"
            match (firstStmt blk).Kind with
            | SAssign({ Kind = EMember _ }, AssEq, _) -> ()
            | other -> failtestf "shape: %A" other
        }

        test "assignment to an indexed expression" {
            let blk = parseFnClean "{ xs[0] = 1 ; return 0 }"
            match (firstStmt blk).Kind with
            | SAssign({ Kind = EIndex _ }, AssEq, _) -> ()
            | other -> failtestf "shape: %A" other
        }
    ]
