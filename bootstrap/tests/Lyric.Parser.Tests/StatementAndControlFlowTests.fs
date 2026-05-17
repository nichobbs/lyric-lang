module Lyric.Parser.Tests.StatementAndControlFlowTests

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

let tests =
    testList "statements & control-flow expressions (P7)" [

        // ----- bindings -----

        test "val binding with type annotation" {
            let blk = parseFnClean "{ val x: Int = 1 ; return x }"
            match (firstStmt blk).Kind with
            | SLocal (LBVal _) -> ()
            | other -> failtestf "expected SLocal LBVal, got %A" other
        }

        test "var binding without initialiser" {
            let blk = parseFnClean "{ var n: Int ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVar(_, _, None)) -> ()
            | other -> failtestf "expected LBVar with no init, got %A" other
        }

        test "let lazy binding" {
            let blk = parseFnClean "{ let z: Int = 42 ; return z }"
            match (firstStmt blk).Kind with
            | SLocal (LBLet _) -> ()
            | other -> failtestf "expected LBLet, got %A" other
        }

        // ----- return / break / continue / throw -----

        test "return with no value" {
            let blk = parseFnClean "{ return }"
            match (firstStmt blk).Kind with
            | SReturn None -> ()
            | other -> failtestf "expected SReturn None, got %A" other
        }

        test "return with value" {
            let blk = parseFnClean "{ return 42 }"
            match (firstStmt blk).Kind with
            | SReturn (Some _) -> ()
            | other -> failtestf "expected SReturn Some, got %A" other
        }

        test "break with label" {
            let blk = parseFnClean "{ break outer }"
            match (firstStmt blk).Kind with
            | SBreak (Some "outer") -> ()
            | other -> failtestf "expected SBreak outer, got %A" other
        }

        test "continue (unlabelled)" {
            let blk = parseFnClean "{ continue }"
            match (firstStmt blk).Kind with
            | SContinue None -> ()
            | other -> failtestf "expected SContinue None, got %A" other
        }

        test "throw" {
            let blk = parseFnClean "{ throw err }"
            match (firstStmt blk).Kind with
            | SThrow _ -> ()
            | other -> failtestf "expected SThrow, got %A" other
        }

        // ----- if / match expressions -----

        test "ternary if-then-else expression body" {
            let blk = parseFnClean "{ return if x > 0 then 1 else 2 }"
            match (firstStmt blk).Kind with
            | SReturn (Some { Kind = EIf(_, _, Some _, true) }) -> ()
            | other -> failtestf "expected SReturn (EIf ternary), got %A" other
        }

        test "block-form if without else" {
            let blk = parseFnClean "{ if x > 0 { return 1 } ; return 0 }"
            match (firstStmt blk).Kind with
            | SExpr { Kind = EIf(_, EOBBlock _, None, false) } -> ()
            | other -> failtestf "expected SExpr block-form if, got %A" other
        }

        test "if/else if/else chain" {
            let blk = parseFnClean
                        "{ if a { return 1 } else if b { return 2 } else { return 3 } }"
            match (firstStmt blk).Kind with
            | SExpr { Kind = EIf(_, _, Some (EOBExpr { Kind = EIf _ }), false) } -> ()
            | other -> failtestf "expected nested else-if, got %A" other
        }

        test "match expression with two arms" {
            let blk = parseFnClean
                        "{ return match x { case 0 -> 0, case _ -> 1 } }"
            match (firstStmt blk).Kind with
            | SReturn (Some { Kind = EMatch(_, arms) }) ->
                Expect.equal arms.Length 2 "two arms"
            | other -> failtestf "expected SReturn EMatch, got %A" other
        }

        test "match arm body can be a return statement" {
            let blk = parseFnClean
                        "{ return match x { case Ok(v) -> v, case Err(_) -> return 0 } }"
            match (firstStmt blk).Kind with
            | SReturn (Some { Kind = EMatch(_, [_; arm2]) }) ->
                match arm2.Body with
                | EOBBlock { Statements = [stmt] } ->
                    match stmt.Kind with
                    | SReturn (Some _) -> ()
                    | other -> failtestf "expected SReturn in arm, got %A" other
                | other -> failtestf "expected EOBBlock arm, got %A" other
            | other -> failtestf "expected match with two arms, got %A" other
        }

        // ----- for / while / do -----

        test "for loop" {
            let blk = parseFnClean "{ for x in xs { } ; return 0 }"
            match (firstStmt blk).Kind with
            | SExpr _ -> failtest "for should be SFor not SExpr"
            | SFor _ -> ()
            | other -> failtestf "expected SFor, got %A" other
        }

        test "while loop" {
            let blk = parseFnClean "{ while x > 0 { } ; return 0 }"
            match (firstStmt blk).Kind with
            | SWhile _ -> ()
            | other -> failtestf "expected SWhile, got %A" other
        }

        test "do (infinite) loop" {
            let blk = parseFnClean "{ do { break } ; return 0 }"
            match (firstStmt blk).Kind with
            | SLoop _ -> ()
            | other -> failtestf "expected SLoop, got %A" other
        }

        // ----- await / spawn -----

        test "await expression in return" {
            let blk = parseFnClean "{ return await fetch() }"
            match (firstStmt blk).Kind with
            | SReturn (Some { Kind = EAwait _ }) -> ()
            | other -> failtestf "expected EAwait, got %A" other
        }

        test "spawn expression in val" {
            let blk = parseFnClean "{ val t = spawn worker() ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVal(_, _, { Kind = ESpawn _ })) -> ()
            | other -> failtestf "expected ESpawn, got %A" other
        }

        // ----- assignment -----

        test "simple assignment" {
            let blk = parseFnClean "{ var x: Int = 0 ; x = 1 ; return x }"
            match blk.Statements.[1].Kind with
            | SAssign(_, AssEq, _) -> ()
            | other -> failtestf "expected SAssign, got %A" other
        }

        test "compound assignment" {
            let blk = parseFnClean "{ var x: Int = 0 ; x += 1 ; return x }"
            match blk.Statements.[1].Kind with
            | SAssign(_, AssPlus, _) -> ()
            | other -> failtestf "expected SAssign +=, got %A" other
        }

        // ----- old / lambda -----

        test "old(...) inside ensures-shaped expression" {
            // `ensures: result == old(s.length) + 1` — appears in
            // the worked Stack example. Parsing as a plain Expr.
            let e, diags = parseExprFromString "result == old(s.length) + 1"
            Expect.isEmpty diags "clean parse"
            match e.Kind with
            | EBinop(BEq, _, { Kind = EBinop(BAdd, { Kind = EOld _ }, _) }) -> ()
            | other -> failtestf "expected expected shape, got %A" other
        }

        test "lambda with one parameter" {
            // Untyped lambda parameter form: typed param annotations
            // (`x: Int -> body`) require a type-without-arrow parser
            // that lands in P8.
            let blk = parseFnClean "{ val double = { x -> x * 2 } ; return 0 }"
            match (firstStmt blk).Kind with
            | SLocal (LBVal(_, _, { Kind = ELambda([p], _) })) ->
                Expect.equal p.Name "x" "param name"
            | other -> failtestf "expected lambda, got %A" other
        }

        // ----- nested control flow inside the worked-example shape -----

        test "the debit function from worked example 1" {
            let body = """{
                val v = amountValue(amount)
                if a.balance < v {
                    return Err(InsufficientFunds)
                }
                return Ok(a.copy(balance = a.balance - v))
            }"""
            let blk = parseFnClean body
            Expect.equal blk.Statements.Length 3 "val + if + return"
        }
    ]
