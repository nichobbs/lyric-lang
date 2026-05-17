module Lyric.Lexer.Tests.EscapeTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "escape sequences" [

        test "every recognised single-char escape inside a string" {
            // \\0 is U+0000 (NUL); \\$ is a literal '$'; the rest are
            // the usual C-family meanings.
            let pairs : (string * string) list =
                [ "\"\\n\"",  "\n"
                  "\"\\r\"",  "\r"
                  "\"\\t\"",  "\t"
                  "\"\\0\"",  "\u0000"
                  "\"\\\\\"", "\\"
                  "\"\\\"\"", "\""
                  "\"\\'\"",  "'"
                  "\"\\$\"",  "$" ]
            for src, expected in pairs do
                Expect.equal (tokensClean src) [TString expected] src
        }

        test "unicode escape with one to six hex digits" {
            let cases : (string * string) list =
                [ "\"\\u{0}\"",      "\u0000"
                  "\"\\u{41}\"",     "A"
                  "\"\\u{1F600}\"",  "\U0001F600" ]
            for src, expected in cases do
                Expect.equal (tokensClean src) [TString expected] src
        }

        test "escaped dollar prevents interpolation" {
            // \\$ is a literal `$`. The next `{` does not open a hole.
            let actual = tokensClean "\"x = \\${value}\""
            Expect.equal actual [TString "x = ${value}"] "no hole"
        }

        test "unknown escape inside string is a diagnostic but lexing continues" {
            let toks, diags = lexBoth "\"a\\qb\""
            Expect.isNonEmpty diags "expected diagnostic"
            Expect.equal (List.head diags).Code "L0023" "diag code"
            // The unknown escape still produces a token.
            match toks with
            | [TString _] -> ()
            | other -> failtestf "expected one TString, got %A" other
        }

        test "unicode escape with too-large codepoint emits L0022" {
            // 0x110000 is just past the Unicode max of 0x10FFFF.
            let _, diags = lexBoth "\"\\u{110000}\""
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "L0022" "too-large codepoint"
        }

        test "unicode escape in surrogate range emits L0022 without crashing" {
            // Surrogate codepoints U+D800..U+DFFF are not valid scalar
            // values. Before the fix for #313 these escaped scalars were
            // accepted by the validator and then crashed
            // Char.ConvertFromUtf32 inside lexStringLiteral with an
            // unhandled ArgumentOutOfRangeException.
            let bounds : string list =
                [ "\"\\u{D800}\""    // high surrogate range start (U+D800..U+DBFF)
                  "\"\\u{DBFF}\""    // high surrogate range end
                  "\"\\u{DC00}\""    // low surrogate range start (U+DC00..U+DFFF)
                  "\"\\u{DFFF}\"" ]  // low surrogate range end
            for src in bounds do
                let toks, diags = lexBoth src
                let codes = diags |> List.map (fun d -> d.Code)
                Expect.contains codes "L0022" (sprintf "surrogate diag for %s" src)
                // Lexing continues; a TString is still produced (with the
                // U+FFFD replacement character substituted for the bad
                // escape). The point of this assertion is that we reach it
                // at all — i.e. no exception was raised.
                match toks with
                | [TString _] -> ()
                | other -> failtestf "expected one TString from %s, got %A" src other
        }

        test "unicode escape in surrogate range inside char literal emits L0022" {
            // lexEscape is shared with lexCharLiteral, so '\u{D800}'
            // would also have crashed before the fix. Char literals
            // don't go through Char.ConvertFromUtf32 (the codepoint is
            // stored raw in TChar), so the failure mode there was
            // different — but the guard at the validator covers both.
            let _, diags = lexBoth "'\\u{D800}'"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "L0022" "surrogate in char literal"
        }

        test "escape sequences inside triple-quoted string" {
            let src = "\"\"\"a\\nb\"\"\""
            Expect.equal (tokensClean src) [TTripleString "a\nb"]
                "newline escape in triple"
        }

        test "raw string does not process escapes" {
            // r"\n\t" is a four-character raw string.
            let src = "r\"\\n\\t\""
            Expect.equal (tokensClean src) [TRawString "\\n\\t"]
                "raw escapes are literal"
        }
    ]
