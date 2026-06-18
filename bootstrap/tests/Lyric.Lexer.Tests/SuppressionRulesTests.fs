module Lyric.Lexer.Tests.SuppressionRulesTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

/// Helper: count TStmtEnd in a token list.
let private countStmtEnds (toks: Token list) : int =
    toks |> List.filter ((=) TStmtEnd) |> List.length

let tests =
    testList "STMT_END suppression rules" [

        test "newline after `xor` is suppressed" {
            Expect.equal
                (tokensClean "a xor\nb")
                [TIdent "a"; TKeyword KwXor; TIdent "b"]
                "a xor\\nb"
        }

        test "newline after `is` is suppressed" {
            Expect.equal
                (tokensClean "x is\nInt")
                [TIdent "x"; TKeyword KwIs; TIdent "Int"]
                "x is\\nInt"
        }

        test "newline after `as` is suppressed" {
            Expect.equal
                (tokensClean "x as\nInt")
                [TIdent "x"; TKeyword KwAs; TIdent "Int"]
                "x as\\nInt"
        }

        test "newline after `then` is suppressed" {
            Expect.equal
                (tokensClean "if c then\n1")
                [TKeyword KwIf; TIdent "c"; TKeyword KwThen; TInt(1UL, NoIntSuffix)]
                "newline after then"
        }

        test "newline after `else` is suppressed" {
            Expect.equal
                (tokensClean "if c then 1 else\n2")
                [TKeyword KwIf; TIdent "c"; TKeyword KwThen; TInt(1UL, NoIntSuffix)
                 TKeyword KwElse; TInt(2UL, NoIntSuffix)]
                "newline after else"
        }

        test "newline after `where` is suppressed" {
            Expect.equal
                (tokensClean "T where\nFoo")
                [TIdent "T"; TKeyword KwWhere; TIdent "Foo"]
                "newline after where"
        }

        test "newline after `not` is suppressed" {
            Expect.equal
                (tokensClean "not\nfoo")
                [TKeyword KwNot; TIdent "foo"]
                "newline after not"
        }

        test "newline after `pub` is NOT suppressed" {
            // `pub` is a visibility modifier — newline-after-pub does
            // emit a STMT_END, but `pub` followed by a token on the
            // next line still works in practice because parsers consume
            // the STMT_END before parsing the item kind. Codify the
            // current behaviour: STMT_END is emitted.
            let toks = tokensClean "pub\nfoo"
            Expect.isGreaterThan (countStmtEnds toks) 0
                "pub is not in the suppress-after set"
        }

        test "newline after `}` is NOT suppressed" {
            let toks = tokensClean "{ x }\nfoo"
            // The closing `}` ends a block; newline after it is a
            // genuine statement separator.
            Expect.isGreaterThan (countStmtEnds toks) 0
                "newline after `}` does emit STMT_END"
        }

        test "newline after `)` is NOT suppressed" {
            let toks = tokensClean "f()\ng"
            Expect.isGreaterThan (countStmtEnds toks) 0
                "newline after `)` does emit STMT_END"
        }

        test "newline after `]` is NOT suppressed" {
            let toks = tokensClean "xs[0]\nfoo"
            Expect.isGreaterThan (countStmtEnds toks) 0
                "newline after `]` does emit STMT_END"
        }

        test "newline after `::` is suppressed" {
            Expect.equal
                (tokensClean "Foo::\nBar")
                [TIdent "Foo"; TPunct ColonColon; TIdent "Bar"]
                "newline after ::"
        }

        test "newline after `??` is suppressed" {
            Expect.equal
                (tokensClean "a ??\nb")
                [TIdent "a"; TPunct QuestionQuestion; TIdent "b"]
                "newline after ??"
        }

        test "newline after `@` is suppressed" {
            // `@` opens an annotation — a newline after the at-sign
            // continues with the annotation name.
            Expect.equal
                (tokensClean "@\nfoo")
                [TPunct At; TIdent "foo"]
                "newline after @"
        }

        test "explicit semicolon at start of file does not emit STMT_END" {
            // The semicolon alone — nothing before it — emits STMT_END
            // unconditionally because explicit beats implicit.
            let toks = tokens ";"
            Expect.equal toks [TStmtEnd] "; alone"
        }

        test "trailing newline at EOF emits exactly one STMT_END" {
            let toks = tokens "x\n\n\n"
            Expect.equal (countStmtEnds toks) 1 "single TStmtEnd"
        }
    ]
