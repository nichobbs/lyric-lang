module Lyric.Lexer.Tests.StringLiteralTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "string literals" [

        test "string literals with simple escapes" {
            let cases : (string * string) list =
                [ "\"\"",            ""
                  "\"hello\"",       "hello"
                  "\"a b c\"",       "a b c"
                  "\"line\\nfeed\"", "line\nfeed"
                  "\"tab\\there\"",  "tab\there"
                  "\"quote\\\"in\"", "quote\"in"
                  "\"back\\\\slash\"", "back\\slash" ]
            for src, expected in cases do
                Expect.equal (tokensClean src) [TString expected] src
        }

        test "unicode-escape inside string" {
            Expect.equal
                (tokensClean "\"smile \\u{1F600} here\"")
                [TString "smile \U0001F600 here"]
                "smile escape"
        }

        test "unterminated string produces a diagnostic" {
            let _, diags = lexBoth "\"oops"
            Expect.isNonEmpty diags "expected diagnostic"
            Expect.equal (List.head diags).Code "L0025" "diag code"
        }

        test "newline inside a single-line string is rejected" {
            let _, diags = lexBoth "\"line\nbreak\""
            Expect.isNonEmpty diags "expected diagnostic"
        }

        test "two strings on a line" {
            let toks =
                tokensClean "\"a\" \"b\""
                |> withoutStmtEnds
            Expect.equal toks [TString "a"; TString "b"] "two strings"
        }
    ]
