module Lyric.Parser.Tests.SkeletonTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Parser

let tests =
    testList "parser skeleton" [

        test "empty input parses with no diagnostics" {
            let r = parse ""
            Expect.isEmpty r.Diagnostics "no diagnostics for empty input"
        }

        test "whitespace-only input parses with no diagnostics" {
            let r = parse "\n\n   \n"
            Expect.isEmpty r.Diagnostics "no diagnostics for whitespace-only input"
        }

        test "non-empty input reports the unimplemented-parser diagnostic" {
            let r = parse "package Foo"
            // The lexer alone produces zero diagnostics for valid input;
            // the parser stub adds P0001 because tokens remain unconsumed.
            Expect.equal r.Diagnostics.Length 1 "exactly one diagnostic"
            Expect.equal (List.head r.Diagnostics).Code "P0001" "diag code"
        }

        test "lexer diagnostics propagate through parse()" {
            // An unterminated string at the lexer level shows up as a
            // lexer diagnostic in the parse result.
            let r = parse "\"oops"
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "L0025" "lexer diagnostic surfaces"
        }
    ]
