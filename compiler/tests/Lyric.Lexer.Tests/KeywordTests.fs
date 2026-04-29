module Lyric.Lexer.Tests.KeywordTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "keywords" [

        test "every keyword round-trips through the keyword table" {
            for kw in Keywords.all do
                let s = Keywords.spelling kw
                Expect.equal (Keywords.tryFromString s) (Some kw)
                    (sprintf "round-trip %s" s)
        }

        test "non-keyword identifiers are not in the table" {
            Expect.equal (Keywords.tryFromString "balance") None "balance"
            Expect.equal (Keywords.tryFromString "Foo") None "Foo"
            Expect.equal (Keywords.tryFromString "") None "empty string"
        }

        test "every keyword lexes as TKeyword (except true/false)" {
            for kw in Keywords.all do
                match kw with
                | KwTrue | KwFalse -> ()
                | _ ->
                    let s = Keywords.spelling kw
                    Expect.equal (tokensClean s) [TKeyword kw]
                        (sprintf "keyword %s lexes" s)
        }

        test "true and false lex as TBool" {
            Expect.equal (tokensClean "true")  [TBool true]  "true"
            Expect.equal (tokensClean "false") [TBool false] "false"
        }

        test "a sequence of keywords and identifiers lexes correctly" {
            let actual =
                tokensClean "pub func foo(): Int"
                |> withoutStmtEnds
            let expected =
                [ TKeyword KwPub; TKeyword KwFunc; TIdent "foo"
                  TPunct LParen; TPunct RParen; TPunct Colon; TIdent "Int" ]
            Expect.equal actual expected "sequence"
        }
    ]
