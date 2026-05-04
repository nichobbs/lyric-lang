module Lyric.Verifier.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Verifier" [
            ModeTests.tests
            ModeCheckTests.tests
            StabilityCheckTests.tests
            VcirTests.tests
            SmtTests.tests
            SolverTests.tests
            ImportsTests.tests
            DriverTests.tests
            RegressionTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
