module Lyric.Lexer.Tests.PunctuationTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "punctuation" [

        test "multi-char operators" {
            let cases : (string * Punct) list =
                [ "..=", DotDotEq
                  "..<", DotDotLt
                  "..",  DotDot
                  "->",  Arrow
                  "=>",  FatArrow
                  "::",  ColonColon
                  "??",  QuestionQuestion
                  "==",  EqEq
                  "!=",  NotEq
                  "<=",  LtEq
                  ">=",  GtEq
                  "+=",  PlusEq
                  "-=",  MinusEq
                  "*=",  StarEq
                  "/=",  SlashEq
                  "%=",  PercentEq ]
            for src, expected in cases do
                Expect.equal (tokensClean src) [TPunct expected] src
        }

        test "single-char operators" {
            let cases : (string * Punct) list =
                [ "+", Plus;  "-", Minus; "*", Star;  "/", Slash;  "%", Percent
                  "=", Eq;    "<", Lt;    ">", Gt;    "?", Question; "@", At
                  "(", LParen; ")", RParen
                  "[", LBracket; "]", RBracket
                  "{", LBrace; "}", RBrace
                  ",", Comma; ":", Colon; ".", Dot ]
            for src, expected in cases do
                Expect.equal (tokensClean src) [TPunct expected] src
        }

        test "semicolon emits a TStmtEnd" {
            Expect.equal
                (tokensClean "x; y")
                [TIdent "x"; TStmtEnd; TIdent "y"]
                "x; y"
        }

        test "operators are matched greedily" {
            // '..=' takes precedence over '..' + '='.
            Expect.equal
                (tokensClean "1..=5")
                [TInt(1UL, NoIntSuffix); TPunct DotDotEq; TInt(5UL, NoIntSuffix)]
                "1..=5"
        }

        test "bracket depth suppresses statement-end inside parens" {
            let actual = tokensClean "(a\nb)"
            // No TStmtEnd between a and b — they are inside parens.
            Expect.equal actual
                [TPunct LParen; TIdent "a"; TIdent "b"; TPunct RParen]
                "(a\\nb)"
        }
    ]
