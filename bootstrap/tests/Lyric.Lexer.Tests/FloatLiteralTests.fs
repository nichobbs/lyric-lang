module Lyric.Lexer.Tests.FloatLiteralTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "float literals" [

        test "float literals" {
            let cases : (string * double) list =
                [ "3.14",    3.14
                  "0.5",     0.5
                  "1_000.5", 1000.5
                  "2.5e10",  2.5e10
                  "1.0e-3",  1.0e-3
                  "1e6",     1e6 ]
            for src, expected in cases do
                let toks = tokensClean src
                match toks with
                | [TFloat(v, _)] ->
                    Expect.floatClose Accuracy.high v expected src
                | _ ->
                    failtestf "expected one float token for %s, got %A" src toks
        }

        test "float suffixes" {
            let cases : (string * FloatSuffix) list =
                [ "3.14f32", F32
                  "3.14f64", F64 ]
            for src, expected in cases do
                let toks = tokensClean src
                match toks with
                | [TFloat(_, sfx)] -> Expect.equal sfx expected src
                | _ -> failtestf "expected one float token for %s, got %A" src toks
        }

        test "range syntax is not consumed by float lexer" {
            let expected =
                [TInt(1UL, NoIntSuffix); TPunct DotDot; TInt(5UL, NoIntSuffix)]
            Expect.equal (tokensClean "1..5") expected "1..5"
        }

        test "range-equal syntax with whitespace" {
            let actual =
                tokensClean "0 ..= 150" |> withoutStmtEnds
            let expected =
                [TInt(0UL, NoIntSuffix); TPunct DotDotEq; TInt(150UL, NoIntSuffix)]
            Expect.equal actual expected "0 ..= 150"
        }
    ]
