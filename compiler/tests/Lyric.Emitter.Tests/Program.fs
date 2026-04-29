module Lyric.Emitter.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    let allTests =
        testList "Lyric.Emitter" [
            StdlibSmokeTests.tests
            EmitterScaffoldTests.tests
            HelloWorldTests.tests
            ArithmeticTests.tests
            ControlFlowTests.tests
            FunctionCallTests.tests
            RecordTests.tests
            SliceTests.tests
            EnumMatchTests.tests
            UnionTests.tests
            InterfaceTests.tests
            ContractTests.tests
            EndToEndSmokeTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
