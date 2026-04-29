module Lyric.TypeChecker.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.TypeChecker" [
            SymbolTableTests.tests
            ResolverTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
