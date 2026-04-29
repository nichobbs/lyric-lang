module Lyric.Parser.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Parser" [
            SkeletonTests.tests
            FileHeadTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
