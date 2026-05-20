module Lyric.Cli.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Cli" [
            ManifestTests.tests
            PackTests.tests
            NugetShimTests.tests
            MavenTests.tests
            RestoredPackagesTests.tests
            FmtTests.tests
            SelfHostedFmtBridgeTests.tests
            SelfHostedMsilBridgeTests.tests
            ParityTests.tests
            JvmDiagnosticTests.tests
            LintTests.tests
            ProjectBuildTests.tests
            ProveTests.tests
            TestRunnerTests.tests
            DocTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
