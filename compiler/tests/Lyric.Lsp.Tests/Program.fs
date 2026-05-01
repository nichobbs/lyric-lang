module Lyric.Lsp.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests = testList "Lyric.Lsp" [ ProtocolTests.tests ]
    runTestsWithCLIArgs [] argv allTests
