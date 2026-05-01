module Lyric.Lexer.Tests.CharLiteralTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "character literals" [

        test "single ASCII letter" {
            Expect.equal (tokensClean "'a'") [TChar (int 'a')] "'a'"
            Expect.equal (tokensClean "'Z'") [TChar (int 'Z')] "'Z'"
            Expect.equal (tokensClean "'0'") [TChar (int '0')] "'0'"
        }

        test "ASCII punctuation" {
            Expect.equal (tokensClean "' '")  [TChar (int ' ')]  "' '"
            Expect.equal (tokensClean "'+'")  [TChar (int '+')]  "'+'"
            Expect.equal (tokensClean "'.'")  [TChar (int '.')]  "'.'"
        }

        test "common escape sequences" {
            Expect.equal (tokensClean "'\\n'")  [TChar (int '\n')] "newline"
            Expect.equal (tokensClean "'\\r'")  [TChar (int '\r')] "carriage return"
            Expect.equal (tokensClean "'\\t'")  [TChar (int '\t')] "tab"
            Expect.equal (tokensClean "'\\\\'") [TChar (int '\\')] "backslash"
            Expect.equal (tokensClean "'\\''")  [TChar (int '\'')] "single quote"
            Expect.equal (tokensClean "'\\\"'") [TChar (int '"')]  "double quote"
            Expect.equal (tokensClean "'\\0'")  [TChar 0]           "null"
        }

        test "unicode escape" {
            Expect.equal (tokensClean "'\\u{41}'")     [TChar 0x41] "\\u{41} = A"
            Expect.equal (tokensClean "'\\u{1F600}'")  [TChar 0x1F600] "\\u{1F600}"
        }

        test "unterminated character literal is a diagnostic" {
            // 'x with no closing quote — at end of input.
            let _, diags = lexBoth "'x"
            Expect.isNonEmpty diags "expected diagnostic"
            Expect.equal (List.head diags).Code "L0024" "diag code"
        }

        test "unknown escape sequence is a diagnostic" {
            let _, diags = lexBoth "'\\q'"
            Expect.isNonEmpty diags "expected diagnostic"
            Expect.equal (List.head diags).Code "L0023" "diag code"
        }

        test "non-ASCII (BMP) char literal" {
            // U+00E9 ('é') is one .NET char, so the codepoint comes
            // through directly.
            Expect.equal (tokensClean "'é'") [TChar (int 'é')] "é"
        }

        test "char literal followed by another token" {
            let actual = tokensClean "'a' 'b'" |> withoutStmtEnds
            Expect.equal actual [TChar (int 'a'); TChar (int 'b')] "two chars"
        }

        test "invalid unicode escape — too many hex digits — is a diagnostic" {
            // Seven hex digits exceeds the 6-digit cap. The lexer reads
            // up to 6 chars, then expects a closing `}`. With seven hex
            // chars in a row inside the braces, the closing `}` is not
            // where expected, producing L0021.
            let _, diags = lexBoth "'\\u{1234567}'"
            Expect.isNonEmpty diags "expected diagnostic"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "L0021" "L0021 unterminated unicode escape"
        }
    ]
