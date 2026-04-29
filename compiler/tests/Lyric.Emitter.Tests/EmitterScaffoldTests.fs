module Lyric.Emitter.Tests.EmitterScaffoldTests

open System.IO
open Expecto
open Lyric.Emitter.Emitter

/// E0 verifies only the scaffolding: the emit pipeline runs through
/// parser + type-checker + backend creation without exceptions, and
/// reports parser/type-checker diagnostics as before. Hello-World
/// codegen lands in E1.
let tests =
    testList "emitter scaffolding (E0)" [

        test "well-formed source produces no parser diagnostics" {
            let req =
                { Source       = "package Hello"
                  AssemblyName = "Hello"
                  OutputPath   = Path.Combine(Path.GetTempPath(), "lyric-e0-noop.dll") }
            let r = emit req
            // E0 doesn't yet save the assembly; the path stays None.
            Expect.isNone r.OutputPath "no output yet (E0 stub)"
            Expect.isEmpty r.Diagnostics "no diagnostics for clean source"
        }

        test "ill-formed source surfaces the parser's diagnostics" {
            let req =
                { Source       = ""
                  AssemblyName = "Empty"
                  OutputPath   = Path.Combine(Path.GetTempPath(), "lyric-e0-empty.dll") }
            let r = emit req
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0020" "missing-package surfaces"
            Expect.isNone r.OutputPath "no output when fatal diagnostics"
        }
    ]
