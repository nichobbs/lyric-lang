module Lyric.Emitter.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Emitter" [
            StdlibSmokeTests.tests
            EmitterScaffoldTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
