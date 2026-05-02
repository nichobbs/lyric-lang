module Lyric.Parser.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Parser" [
            SkeletonTests.tests
            FileHeadTests.tests
            ItemHeadTests.tests
            TypeExprTests.tests
            AdditionalTypeExprTests.tests
            PatternTests.tests
            AdditionalPatternTests.tests
            ExprTests.tests
            AdditionalExprTests.tests
            ItemBodyTests.tests
            FunctionDeclTests.tests
            InterfaceImplTests.tests
            StatementAndControlFlowTests.tests
            AdditionalStatementTests.tests
            RemainingItemTests.tests
            DiagnosticTests.tests
            SynthesizerTests.tests
            WorkedExampleSmokeTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
