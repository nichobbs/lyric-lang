module Lyric.Cli.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Cli" [
            ManifestTests.tests
            SelfHostedMsilBridgeTests.tests
            SelfHostedMsilProjectBridgeTests.tests
            SelfHostedJvmBridgeTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
