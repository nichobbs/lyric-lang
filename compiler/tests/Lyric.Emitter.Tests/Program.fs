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
            GenericsTests.tests
            AsyncTests.tests
            BankingSmokeTests.tests
            StdlibSeedTests.tests
            DelegateTests.tests
            DistinctTypeTests.tests
            OpaqueTypeTests.tests
            MultiPackageTests.tests
            CrossAssemblyGenericTests.tests
            WhereClauseTests.tests
            NullaryInferenceTests.tests
            GenericUnionTests.tests
            SyntaxSimplificationTests.tests
            BclDispatchTests.tests
            ParseTests.tests
            DeferTests.tests
            StdlibImportTests.tests
            NegativePatternTests.tests
            InlineMethodTests.tests
            EndToEndSmokeTests.tests
            BuiltinTests.tests
            StdFileTests.tests
            CollectionTests.tests
            OutParamTests.tests
            IterTests.tests
            StubbableTests.tests
            AliasTests.tests
            AutoFfiTests.tests
            StdTimeTests.tests
            WireTests.tests
            GenericRecordTests.tests
            JsonDeriveTests.tests
        ]
    runTestsWithCLIArgs [] argv allTests
