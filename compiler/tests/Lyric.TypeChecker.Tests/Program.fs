module Lyric.TypeChecker.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.TypeChecker" [
            SymbolTableTests.tests
            ResolverTests.tests
            SignatureTests.tests
            ExprCheckerTests.tests
            StmtCheckerTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
