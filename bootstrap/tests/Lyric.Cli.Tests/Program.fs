module Lyric.Cli.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Cli" [
            ManifestTests.tests
            SelfHostedMsilBridgeTests.tests
            SelfHostedJvmBridgeTests.tests
            SelfHostedRestoredPackageE2ETests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
