module Lyric.Lexer.Tests.CommentTests

open Expecto
open Lyric.Lexer
open Lyric.Lexer.Tests.TestHelpers

let tests =
    testList "comments" [

        test "line comments are dropped" {
            let actual =
                tokensClean "// hello\nx"
                |> withoutStmtEnds
            Expect.equal actual [TIdent "x"] "line comment"
        }

        test "block comments are dropped" {
            Expect.equal
                (tokensClean "x /* a comment */ y")
                [TIdent "x"; TIdent "y"]
                "block comment"
        }

        test "block comments nest" {
            Expect.equal
                (tokensClean "x /* outer /* inner */ outer */ y")
                [TIdent "x"; TIdent "y"]
                "nested block comment"
        }

        test "unterminated block comment is a diagnostic" {
            let _, diags = lexBoth "/* never closed"
            Expect.isNonEmpty diags "expected diagnostic"
            Expect.equal (List.head diags).Code "L0001" "diag code"
        }

        test "triple-slash is a doc comment" {
            let actual =
                tokensClean "/// the answer\nx"
                |> withoutStmtEnds
            Expect.equal actual [TDocComment "the answer"; TIdent "x"] "doc comment"
        }

        test "slash-bang is a module doc comment" {
            let actual =
                tokensClean "//! module-level\nx"
                |> withoutStmtEnds
            Expect.equal actual
                [TModuleDocComment "module-level"; TIdent "x"]
                "module doc comment"
        }
    ]
