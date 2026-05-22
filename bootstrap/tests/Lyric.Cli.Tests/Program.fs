module Lyric.Cli.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Cli" [
            SelfHostedMsilBridgeTests.tests
            SelfHostedJvmBridgeTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
