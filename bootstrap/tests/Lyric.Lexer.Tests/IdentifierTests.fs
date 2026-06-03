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

        test "non-ASCII BMP letters are valid identifier characters" {
            // Cyrillic, Greek, CJK, Latin-with-diacritic — written via
            // explicit \u escapes so byte-level identity does not depend
            // on the editor's Unicode handling.
            let cases =
                [ "имя"          // имя (Cyrillic)
                  "αβγ"          // αβγ  (Greek)
                  "名前"                // 名前 (CJK)
                  "café" ]                 // café (composed form)
            for s in cases do
                Expect.equal (tokensClean s) [TIdent s] s
        }

        test "NFC normalisation: composed and decomposed forms are equal" {
            // U+00E9          — composed 'é'
            // U+0065 U+0301   — 'e' + combining acute
            // After NFC normalisation, both lex to the same TIdent.
            let composedSrc   = "café"
            let decomposedSrc = "café"
            Expect.equal (tokensClean composedSrc) (tokensClean decomposedSrc)
                "NFC equality"
        }

        test "reserved name '_<Uppercase>' produces a diagnostic" {
            let _, diags = lexBoth "_Foo"
            Expect.isNonEmpty diags "expected diagnostic"
            Expect.equal (List.head diags).Code "L0040" "diag code"
        }

        test "identifier with leading underscore + lowercase is fine" {
            Expect.equal (tokensClean "_foo") [TIdent "_foo"] "_foo"
        }

        test "identifier with leading underscore + digit is fine" {
            Expect.equal (tokensClean "_1") [TIdent "_1"] "_1"
        }
    ]
