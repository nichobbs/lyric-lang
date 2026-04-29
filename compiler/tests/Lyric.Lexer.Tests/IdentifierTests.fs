module Lyric.Lexer.Tests.IdentifierTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "identifiers" [

        test "valid identifiers lex as TIdent" {
            let cases =
                [ "x"; "foo"; "camelCase"; "PascalCase"; "SCREAMING_SNAKE"
                  "a1"; "a_b_c"; "_leading"; "trailing_"; "x123y" ]
            for s in cases do
                Expect.equal (tokensClean s) [TIdent s] s
        }

        test "identifier followed by digits stays one token" {
            Expect.equal (tokensClean "foo123") [TIdent "foo123"] "foo123"
        }

        test "two identifiers separated by space are two tokens" {
            Expect.equal (tokensClean "foo bar")
                [TIdent "foo"; TIdent "bar"] "foo bar"
        }

        test "leading digit triggers number lex, not identifier" {
            let toks = tokens "123"
            match List.head toks with
            | TIdent _ -> failtest "identifier may not start with a digit"
            | _ -> ()
        }
    ]
