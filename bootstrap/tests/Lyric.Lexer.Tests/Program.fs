module Lyric.Lexer.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Lexer" [
            KeywordTests.tests
            IdentifierTests.tests
            IntLiteralTests.tests
            NumericEdgeTests.tests
            FloatLiteralTests.tests
            StringLiteralTests.tests
            StringInterpolationTests.tests
            EscapeTests.tests
            CharLiteralTests.tests
            CommentTests.tests
            PunctuationTests.tests
            StmtEndTests.tests
            SuppressionRulesTests.tests
            SpanTests.tests
            SmokeTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
