module Lyric.Verifier.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Verifier" [
            ModeTests.tests
            ModeCheckTests.tests
            VcirTests.tests
            SmtTests.tests
            DriverTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
