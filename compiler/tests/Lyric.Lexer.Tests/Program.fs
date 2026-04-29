module Lyric.Lexer.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Lexer" [
            KeywordTests.tests
            IdentifierTests.tests
            IntLiteralTests.tests
            FloatLiteralTests.tests
            StringLiteralTests.tests
            StringInterpolationTests.tests
            CommentTests.tests
            PunctuationTests.tests
            StmtEndTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
