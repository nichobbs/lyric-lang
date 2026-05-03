module Lyric.Emitter.Tests.EmitterScaffoldTests

open System.IO
open Expecto
open Lyric.Emitter.Emitter

/// Scaffolding-level checks: the emit pipeline runs through parser +
/// type-checker + backend without exceptions, reports upstream
/// diagnostics, and refuses to emit when a `func main` is missing.
let tests =
    testList "emitter scaffolding" [

        test "source without a main function reports E0001" {
            let req =
                { Source           = "package Hello"
                  AssemblyName     = "Hello"
                  OutputPath       = Path.Combine(Path.GetTempPath(), "lyric-noop.dll")
                  RestoredPackages = [] }
            let r = emit req
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "E0001" "missing-main surfaces E0001"
            Expect.isNone r.OutputPath "no output when fatal emitter diagnostics"
        }

        test "ill-formed source surfaces the parser's diagnostics" {
            let req =
                { Source           = ""
                  AssemblyName     = "Empty"
                  OutputPath       = Path.Combine(Path.GetTempPath(), "lyric-empty.dll")
                  RestoredPackages = [] }
            let r = emit req
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0020" "missing-package surfaces"
            Expect.isNone r.OutputPath "no output when fatal upstream"
        }
    ]
