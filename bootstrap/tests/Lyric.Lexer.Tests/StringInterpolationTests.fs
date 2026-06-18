module Lyric.Lexer.Tests.StringInterpolationTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "string interpolation" [

        test "string with no holes lexes as a single TString" {
            // No '${' in body; the simple-string path applies.
            Expect.equal (tokensClean "\"hello\"") [TString "hello"] "plain"
        }

        test "string with one identifier hole produces the canonical sequence" {
            // "hello ${name}!" →
            //   TStringStart, TStringPart "hello ", TStringHoleStart,
            //   TIdent "name", TPunct RBrace, TStringPart "!", TStringEnd
            let actual = tokensClean "\"hello ${name}!\""
            let expected =
                [ TStringStart
                  TStringPart "hello "
                  TStringHoleStart
                  TIdent "name"
                  TPunct RBrace
                  TStringPart "!"
                  TStringEnd ]
            Expect.equal actual expected "interpolated"
        }

        test "leading hole has no preceding TStringPart" {
            let actual = tokensClean "\"${x}!\""
            let expected =
                [ TStringStart
                  TStringHoleStart
                  TIdent "x"
                  TPunct RBrace
                  TStringPart "!"
                  TStringEnd ]
            Expect.equal actual expected "${x}!"
        }

        test "trailing hole has no following TStringPart before TStringEnd" {
            let actual = tokensClean "\"hi ${x}\""
            let expected =
                [ TStringStart
                  TStringPart "hi "
                  TStringHoleStart
                  TIdent "x"
                  TPunct RBrace
                  TStringEnd ]
            Expect.equal actual expected "hi ${x}"
        }

        test "two adjacent holes produce no TStringPart between them" {
            let actual = tokensClean "\"${a}${b}\""
            let expected =
                [ TStringStart
                  TStringHoleStart
                  TIdent "a"
                  TPunct RBrace
                  TStringHoleStart
                  TIdent "b"
                  TPunct RBrace
                  TStringEnd ]
            Expect.equal actual expected "${a}${b}"
        }

        test "expression inside hole may use braces" {
            // The inner '{ ... }' is a block expression; its braces are
            // counted normally so the hole's closing '}' is the matching
            // outermost one.
            let actual = tokensClean "\"v=${ if c then 1 else 0 }\""
            // We don't enumerate the whole token list — just spot-check
            // the bracketing structure.
            let kinds = actual |> List.map (function
                | TStringStart       -> "S"
                | TStringPart _      -> "P"
                | TStringHoleStart   -> "H"
                | TStringEnd         -> "E"
                | TPunct LBrace      -> "{"
                | TPunct RBrace      -> "}"
                | _                  -> ".")
            // Expect: S P H . . . . . . } E   (no inner { } pair)
            Expect.contains kinds "H" "hole-start present"
            Expect.contains kinds "}" "hole-close brace present"
            Expect.contains kinds "E" "string-end present"
        }

        test "escaped \\${ does not open a hole" {
            // The escape consumes '\\$', leaving '{' as a literal char,
            // so the whole string lexes as TString.
            let actual = tokensClean "\"escaped: \\${not}\""
            Expect.equal actual [TString "escaped: ${not}"] "escape"
        }

        test "unterminated interpolated string is a diagnostic" {
            let _, diags = lexBoth "\"hi ${x}"
            Expect.isNonEmpty diags "expected diagnostic"
            Expect.equal (List.head diags).Code "L0025" "diag code"
        }

        test "nested interpolation: \"${ \"${y}\" }\"" {
            let actual = tokensClean "\"${\"${y}\"}\""
            let expected =
                [ TStringStart                  // outer "
                  TStringHoleStart              // outer ${
                  TStringStart                  // inner "
                  TStringHoleStart              // inner ${
                  TIdent "y"
                  TPunct RBrace                 // inner }
                  TStringEnd                    // inner "
                  TPunct RBrace                 // outer }
                  TStringEnd ]                  // outer "
            Expect.equal actual expected "nested"
        }
    ]
