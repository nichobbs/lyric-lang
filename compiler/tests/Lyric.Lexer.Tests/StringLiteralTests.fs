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

        test "triple-quoted string spans newlines" {
            let src = "\"\"\"\nline one\nline two\n\"\"\""
            let expected = "\nline one\nline two\n"
            Expect.equal (tokensClean src) [TTripleString expected] "triple"
        }

        test "triple-quoted string can contain a single \"" {
            let src = "\"\"\"a \"quoted\" word\"\"\""
            let expected = "a \"quoted\" word"
            Expect.equal (tokensClean src) [TTripleString expected] "embedded quote"
        }

        test "triple-quoted string honours escapes" {
            let src = "\"\"\"tab:\\there\"\"\""
            let expected = "tab:\there"
            Expect.equal (tokensClean src) [TTripleString expected] "triple escape"
        }

        test "unterminated triple string is a diagnostic" {
            let _, diags = lexBoth "\"\"\"oops"
            Expect.isNonEmpty diags "expected diagnostic"
            Expect.equal (List.head diags).Code "L0026" "diag code"
        }

        test "raw string preserves backslashes verbatim" {
            let src = "r\"C:\\path\\to\\file\""
            let expected = "C:\\path\\to\\file"
            Expect.equal (tokensClean src) [TRawString expected] "raw backslash"
        }

        test "raw string with hashes admits embedded quotes" {
            let src = "r#\"contains \"quotes\"\"#"
            let expected = "contains \"quotes\""
            Expect.equal (tokensClean src) [TRawString expected] "raw with hash"
        }

        test "raw string with no hashes does not interpret escapes" {
            // r"\n" should be a two-char raw string, not a newline.
            let src = "r\"\\n\""
            Expect.equal (tokensClean src) [TRawString "\\n"] "raw no escape"
        }

        test "raw string with mismatched-hash quote does not close early" {
            // Inside r##"..."##, a single '"#' is part of the body.
            let src = "r##\"part \"# more\"##"
            let expected = "part \"# more"
            Expect.equal (tokensClean src) [TRawString expected] "two hashes"
        }

        test "unterminated raw string is a diagnostic" {
            let _, diags = lexBoth "r\"never closed"
            Expect.isNonEmpty diags "expected diagnostic"
            Expect.equal (List.head diags).Code "L0028" "diag code"
        }

        test "the identifier 'r' is unaffected" {
            // Just 'r' on its own is still a valid identifier.
            Expect.equal (tokensClean "r") [TIdent "r"] "bare r"
            Expect.equal (tokensClean "rfoo") [TIdent "rfoo"] "rfoo"
        }
    ]
