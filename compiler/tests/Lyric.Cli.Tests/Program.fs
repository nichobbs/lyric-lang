module Lyric.Cli.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Cli" [
            ManifestTests.tests
            PackTests.tests
            RestoredPackagesTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
