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
            PatternTests.tests
            ExprTests.tests
            ItemBodyTests.tests
            FunctionDeclTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
