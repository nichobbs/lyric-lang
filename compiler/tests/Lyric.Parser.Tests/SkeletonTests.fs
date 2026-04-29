module Lyric.Parser.Tests.SkeletonTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Parser

let tests =
    testList "parser skeleton" [

        test "empty input reports a missing-package diagnostic" {
            // Every Lyric file must start with `package …`. An empty
            // file violates that, so the parser surfaces P0020.
            let r = parse ""
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0020" "missing package on empty input"
        }

        test "whitespace-only input reports the same missing-package diagnostic" {
            let r = parse "\n\n   \n"
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0020" "missing package on whitespace input"
        }

        test "well-formed file head parses with no diagnostics" {
            let r = parse "package Foo"
            Expect.isEmpty r.Diagnostics "no diagnostics for `package Foo`"
        }

        test "lexer diagnostics propagate through parse()" {
            // An unterminated string at the lexer level shows up as a
            // lexer diagnostic in the parse result.
            let r = parse "\"oops"
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "L0025" "lexer diagnostic surfaces"
        }
    ]
