module Lyric.TypeChecker.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.TypeChecker" [
            SymbolTableTests.tests
            ResolverTests.tests
            AdditionalResolverTests.tests
            SignatureTests.tests
            ExprCheckerTests.tests
            AdditionalExprCheckerTests.tests
            StmtCheckerTests.tests
            AdditionalStmtCheckerTests.tests
            ConstFoldTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
