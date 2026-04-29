module Lyric.TypeChecker.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.TypeChecker" [
            TypeRepTests.tests
            ResolverTests.tests
            SignatureTests.tests
            ExprCheckerTests.tests
            StmtCheckerTests.tests
            WorkedExampleSmokeTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
