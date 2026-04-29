module Lyric.Parser.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Parser" [
            SkeletonTests.tests
            FileHeadTests.tests
            ItemHeadTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
