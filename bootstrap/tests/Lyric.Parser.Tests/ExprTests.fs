module Lyric.Parser.Tests.ExprTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private parseClean (src: string) =
    let e, diags = parseExprFromString src
    Expect.isEmpty diags (sprintf "expected no diagnostics for %A" src)
    e

let tests =
    testList "expressions (extended)" [

        // ----- arithmetic precedence (existing, sanity) -----

        test "addition" {
            let e = parseClean "1 + 2"
            match e.Kind with
            | EBinop(BAdd, _, _) -> ()
            | other -> failtestf "expected BAdd, got %A" other
        }

        test "multiplication binds tighter than addition" {
            let e = parseClean "1 + 2 * 3"
            match e.Kind with
            | EBinop(BAdd, _, { Kind = EBinop(BMul, _, _) }) -> ()
            | other -> failtestf "expected (1 + (2*3)), got %A" other
        }

        test "unary minus" {
            let e = parseClean "-5"
            match e.Kind with
            | EPrefix(PreNeg, { Kind = ELiteral (LInt(5UL, _)) }) -> ()
            | other -> failtestf "expected -5, got %A" other
        }

        // ----- comparisons -----

        test "equality" {
            let e = parseClean "a == b"
            match e.Kind with
            | EBinop(BEq, _, _) -> ()
            | other -> failtestf "expected BEq, got %A" other
        }

        test "less-than" {
            let e = parseClean "a < b"
            match e.Kind with
            | EBinop(BLt, _, _) -> ()
            | other -> failtestf "expected BLt, got %A" other
        }

        test "comparison does not chain" {
            let _, diags = parseExprFromString "a < b < c"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "P0082" "chained-comparison rejected"
        }

        // ----- logical and / or / xor / implies -----

        test "logical and" {
            let e = parseClean "x and y"
            match e.Kind with
            | EBinop(BAnd, _, _) -> ()
            | other -> failtestf "expected BAnd, got %A" other
        }

        test "logical or" {
            let e = parseClean "x or y"
            match e.Kind with
            | EBinop(BOr, _, _) -> ()
            | other -> failtestf "expected BOr, got %A" other
        }

        test "and binds tighter than or" {
            let e = parseClean "a or b and c"
            match e.Kind with
            | EBinop(BOr, _, { Kind = EBinop(BAnd, _, _) }) -> ()
            | other -> failtestf "expected (a or (b and c)), got %A" other
        }

        test "comparison binds tighter than logical and" {
            let e = parseClean "x > 0 and y > 0"
            match e.Kind with
            | EBinop(BAnd, { Kind = EBinop(BGt, _, _) }, { Kind = EBinop(BGt, _, _) }) -> ()
            | other -> failtestf "expected (gt and gt), got %A" other
        }

        test "implies as soft-keyword binary operator" {
            let e = parseClean "p implies q"
            match e.Kind with
            | EBinop(BImplies, _, _) -> ()
            | other -> failtestf "expected BImplies, got %A" other
        }

        test "not is a prefix operator" {
            let e = parseClean "not x"
            match e.Kind with
            | EPrefix(PreNot, _) -> ()
            | other -> failtestf "expected PreNot, got %A" other
        }

        // ----- postfix: call, member, propagate -----

        test "function call with positional args" {
            let e = parseClean "f(x, y)"
            match e.Kind with
            | ECall({ Kind = EPath _ }, args) ->
                Expect.equal args.Length 2 "two args"
            | other -> failtestf "expected ECall, got %A" other
        }

        test "function call with named args" {
            let e = parseClean "f(x = 1, y = 2)"
            match e.Kind with
            | ECall(_, [CANamed("x", _, _); CANamed("y", _, _)]) -> ()
            | other -> failtestf "expected named args, got %A" other
        }

        test "member access" {
            let e = parseClean "account.balance"
            match e.Kind with
            | EMember({ Kind = EPath _ }, "balance") -> ()
            | other -> failtestf "expected member access, got %A" other
        }

        test "chained member access" {
            let e = parseClean "account.balance.amount"
            match e.Kind with
            | EMember({ Kind = EMember({ Kind = EPath _ }, "balance") }, "amount") -> ()
            | other -> failtestf "expected chained member, got %A" other
        }

        test "chained member access starting from `result` keyword" {
            let e = parseClean "result.value.value"
            match e.Kind with
            | EMember({ Kind = EMember({ Kind = EResult }, "value") }, "value") -> ()
            | other -> failtestf "expected EResult.value.value, got %A" other
        }

        test "postfix error propagation" {
            let e = parseClean "tryFoo()?"
            match e.Kind with
            | EPropagate { Kind = ECall _ } -> ()
            | other -> failtestf "expected propagate over call, got %A" other
        }

        test "method-call shape via member + call" {
            let e = parseClean "xs.append(x)"
            match e.Kind with
            | ECall({ Kind = EMember(_, "append") }, [CAPositional _]) -> ()
            | other -> failtestf "expected method-call shape, got %A" other
        }

        // ----- combined contract-style expression -----

        test "contract-style: result.isOk implies condition" {
            let e = parseClean "result.isOk implies result.value.value == c"
            match e.Kind with
            | EBinop(BImplies, lhs, rhs) ->
                match lhs.Kind with
                | EMember({ Kind = EResult }, "isOk") -> ()
                | other -> failtestf "lhs: %A" other
                match rhs.Kind with
                | EBinop(BEq, _, _) -> ()
                | other -> failtestf "rhs: %A" other
            | other -> failtestf "shape: %A" other
        }

        test "contract-style: balance >= 0 and balance <= 1_000_000_000" {
            let e = parseClean "balance >= 0 and balance <= 1_000_000_000"
            match e.Kind with
            | EBinop(BAnd, { Kind = EBinop(BGte, _, _) }, { Kind = EBinop(BLte, _, _) }) -> ()
            | other -> failtestf "shape: %A" other
        }

        // ----- self / result -----

        test "self keyword" {
            let e = parseClean "self"
            match e.Kind with
            | ESelf -> ()
            | other -> failtestf "expected ESelf, got %A" other
        }

        test "result keyword" {
            let e = parseClean "result"
            match e.Kind with
            | EResult -> ()
            | other -> failtestf "expected EResult, got %A" other
        }
    ]
