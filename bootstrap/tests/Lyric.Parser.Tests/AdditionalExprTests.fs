module Lyric.Parser.Tests.AdditionalExprTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private parseClean (src: string) =
    let e, diags = parseExprFromString src
    Expect.isEmpty diags (sprintf "expected no diagnostics for %A" src)
    e

let tests =
    testList "additional expression forms" [

        // ----- arithmetic completeness -----

        test "subtraction" {
            let e = parseClean "a - b"
            match e.Kind with
            | EBinop(BSub, _, _) -> ()
            | other -> failtestf "expected BSub, got %A" other
        }

        test "division" {
            let e = parseClean "a / b"
            match e.Kind with
            | EBinop(BDiv, _, _) -> ()
            | other -> failtestf "expected BDiv, got %A" other
        }

        test "modulus" {
            let e = parseClean "a % b"
            match e.Kind with
            | EBinop(BMod, _, _) -> ()
            | other -> failtestf "expected BMod, got %A" other
        }

        test "left-associative subtraction" {
            // (a - b) - c, not a - (b - c).
            let e = parseClean "a - b - c"
            match e.Kind with
            | EBinop(BSub, { Kind = EBinop(BSub, _, _) }, _) -> ()
            | other -> failtestf "expected left-assoc, got %A" other
        }

        test "unary minus binds tighter than binary subtract" {
            let e = parseClean "-a - b"
            match e.Kind with
            | EBinop(BSub, { Kind = EPrefix(PreNeg, _) }, _) -> ()
            | other -> failtestf "shape: %A" other
        }

        test "double negation" {
            let e = parseClean "- - x"
            match e.Kind with
            | EPrefix(PreNeg, { Kind = EPrefix(PreNeg, _) }) -> ()
            | other -> failtestf "shape: %A" other
        }

        // ----- comparisons completeness -----

        test "every comparison operator" {
            let cases : (string * BinOp) list =
                [ "a == b", BEq
                  "a != b", BNeq
                  "a < b",  BLt
                  "a <= b", BLte
                  "a > b",  BGt
                  "a >= b", BGte ]
            for src, op in cases do
                let e = parseClean src
                match e.Kind with
                | EBinop(actualOp, _, _) when actualOp = op -> ()
                | other -> failtestf "%s: %A" src other
        }

        // ----- xor / coalesce -----

        test "xor as an or-level operator" {
            let e = parseClean "a xor b"
            match e.Kind with
            | EBinop(BXor, _, _) -> ()
            | other -> failtestf "expected BXor, got %A" other
        }

        test "coalesce ?? right-associates" {
            // a ?? b ?? c parses as a ?? (b ?? c).
            let e = parseClean "a ?? b ?? c"
            match e.Kind with
            | EBinop(BCoalesce, _, { Kind = EBinop(BCoalesce, _, _) }) -> ()
            | other -> failtestf "expected right-assoc, got %A" other
        }

        test "coalesce binds looser than addition" {
            // a + b ?? c parses as (a + b) ?? c.
            let e = parseClean "a + b ?? c"
            match e.Kind with
            | EBinop(BCoalesce, { Kind = EBinop(BAdd, _, _) }, _) -> ()
            | other -> failtestf "expected (add) ?? c, got %A" other
        }

        // ----- prefix forms -----

        test "ampersand reference prefix" {
            let e = parseClean "&x"
            match e.Kind with
            | EPrefix(PreRef, _) -> ()
            | other -> failtestf "expected PreRef, got %A" other
        }

        // ----- postfix indexing -----

        test "indexing with a single index" {
            let e = parseClean "xs[0]"
            match e.Kind with
            | EIndex(_, [_]) -> ()
            | other -> failtestf "expected EIndex of 1, got %A" other
        }

        test "indexing with multiple indices" {
            let e = parseClean "matrix[i, j]"
            match e.Kind with
            | EIndex(_, idxs) -> Expect.equal idxs.Length 2 "two indices"
            | other -> failtestf "expected EIndex, got %A" other
        }

        test "indexing chains with member access" {
            let e = parseClean "obj.field[0]"
            match e.Kind with
            | EIndex({ Kind = EMember _ }, _) -> ()
            | other -> failtestf "shape: %A" other
        }

        // ----- list and tuple literals -----

        test "empty list literal" {
            let e = parseClean "[]"
            match e.Kind with
            | EList [] -> ()
            | other -> failtestf "expected EList [], got %A" other
        }

        test "list literal with three elements" {
            let e = parseClean "[1, 2, 3]"
            match e.Kind with
            | EList xs -> Expect.equal xs.Length 3 "three"
            | other -> failtestf "expected EList, got %A" other
        }

        test "list literal with trailing comma" {
            let e = parseClean "[1, 2,]"
            match e.Kind with
            | EList xs -> Expect.equal xs.Length 2 "two (trailing comma OK)"
            | other -> failtestf "expected EList, got %A" other
        }

        test "tuple expression" {
            let e = parseClean "(1, 2)"
            match e.Kind with
            | ETuple [_; _] -> ()
            | other -> failtestf "expected ETuple of 2, got %A" other
        }

        test "three-tuple expression" {
            let e = parseClean "(1, 2, 3)"
            match e.Kind with
            | ETuple xs -> Expect.equal xs.Length 3 "three"
            | other -> failtestf "expected ETuple, got %A" other
        }

        test "unit value" {
            let e = parseClean "()"
            match e.Kind with
            | ELiteral LUnit -> ()
            | other -> failtestf "expected LUnit, got %A" other
        }

        test "parenthesised expression preserves EParen" {
            let e = parseClean "(x)"
            match e.Kind with
            | EParen _ -> ()
            | other -> failtestf "expected EParen, got %A" other
        }

        // ----- if forms -----

        test "block-form if without else" {
            let e = parseClean "if c { 1 }"
            match e.Kind with
            | EIf(_, EOBBlock _, None, false) -> ()
            | other -> failtestf "shape: %A" other
        }

        test "ternary if-then-else inside expression" {
            let e = parseClean "1 + if c then 2 else 3"
            match e.Kind with
            | EBinop(BAdd, _, { Kind = EIf(_, _, Some _, true) }) -> ()
            | other -> failtestf "shape: %A" other
        }

        // ----- match completeness -----

        test "match arm with guard" {
            let e = parseClean "match x { case n if n > 0 -> n }"
            match e.Kind with
            | EMatch(_, [arm]) ->
                Expect.isSome arm.Guard "guard present"
            | other -> failtestf "expected one-arm match, got %A" other
        }

        test "match arm with block body" {
            let e = parseClean "match x { case 0 -> { 1 } }"
            match e.Kind with
            | EMatch(_, [arm]) ->
                match arm.Body with
                | EOBBlock _ -> ()
                | other -> failtestf "body: %A" other
            | other -> failtestf "expected one-arm match, got %A" other
        }

        // ----- await / spawn / try -----

        test "spawn expression" {
            let e = parseClean "spawn worker()"
            match e.Kind with
            | ESpawn _ -> ()
            | other -> failtestf "expected ESpawn, got %A" other
        }

        test "await on member access" {
            let e = parseClean "await svc.fetch()"
            match e.Kind with
            | EAwait { Kind = ECall({ Kind = EMember _ }, _) } -> ()
            | other -> failtestf "shape: %A" other
        }

        // ----- string literals as expressions -----

        test "plain string literal in expression position" {
            let e = parseClean "\"hello\""
            match e.Kind with
            | ELiteral (LString "hello") -> ()
            | other -> failtestf "expected LString, got %A" other
        }

        test "raw string literal in expression position" {
            let e = parseClean "r\"path\\to\\file\""
            match e.Kind with
            | ELiteral (LRawString "path\\to\\file") -> ()
            | other -> failtestf "expected LRawString, got %A" other
        }

        test "interpolated string yields EInterpolated" {
            let e = parseClean "\"hi ${name}!\""
            match e.Kind with
            | EInterpolated segs ->
                let texts =
                    segs |> List.choose (function
                        | ISText(s, _) -> Some s
                        | _ -> None)
                Expect.contains texts "hi " "leading text"
            | other -> failtestf "expected EInterpolated, got %A" other
        }

        // ----- propagate -----

        test "propagate over a member access" {
            let e = parseClean "obj.field?"
            match e.Kind with
            | EPropagate { Kind = EMember _ } -> ()
            | other -> failtestf "shape: %A" other
        }

        // ----- error recovery -----

        test "incomplete binary expression reports a diagnostic" {
            // `a +` with nothing on the RHS should produce a P0050.
            let _, diags = parseExprFromString "a +"
            Expect.isNonEmpty diags "expected diagnostic"
        }

        test "chained comparison emits one P0082" {
            let _, diags = parseExprFromString "a < b < c"
            let p82 = diags |> List.filter (fun d -> d.Code = "P0082")
            Expect.equal p82.Length 1 "exactly one P0082"
        }
    ]
