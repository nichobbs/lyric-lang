module Lyric.Lexer.Tests.StmtEndTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "statement terminators" [

        test "newline between idents inserts TStmtEnd" {
            Expect.equal
                (tokensClean "a\nb")
                [TIdent "a"; TStmtEnd; TIdent "b"]
                "a\\nb"
        }

        test "newline at end of file inserts TStmtEnd" {
            Expect.equal
                (tokensClean "a\n")
                [TIdent "a"; TStmtEnd]
                "trailing newline"
        }

        test "consecutive newlines do not produce duplicate TStmtEnd" {
            Expect.equal
                (tokensClean "a\n\n\nb")
                [TIdent "a"; TStmtEnd; TIdent "b"]
                "multiple newlines"
        }

        test "newline after a binary operator is suppressed" {
            Expect.equal
                (tokensClean "a +\n  b")
                [TIdent "a"; TPunct Plus; TIdent "b"]
                "a +\\n  b"
        }

        test "newline after a comma is suppressed" {
            Expect.equal
                (tokensClean "f(a,\n  b)")
                [TIdent "f"; TPunct LParen; TIdent "a"; TPunct Comma
                 TIdent "b"; TPunct RParen]
                "trailing comma continuation"
        }

        test "newline after dot is suppressed" {
            Expect.equal
                (tokensClean "obj.\n  field")
                [TIdent "obj"; TPunct Dot; TIdent "field"]
                "obj.\\n  field"
        }

        test "newline inside brackets is ignored" {
            Expect.equal
                (tokensClean "[1,\n 2]")
                [TPunct LBracket; TInt(1UL, NoIntSuffix); TPunct Comma
                 TInt(2UL, NoIntSuffix); TPunct RBracket]
                "list literal across newline"
        }

        test "semicolon and newline collapse into one TStmtEnd" {
            let toks = tokensClean "a;\nb"
            let count = toks |> List.filter ((=) TStmtEnd) |> List.length
            Expect.equal count 1 "exactly one TStmtEnd"
        }
    ]
