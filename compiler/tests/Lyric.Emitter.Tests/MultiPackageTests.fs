/// Smoke test for stdlib precompilation: trigger the standalone build
/// of `Lyric.Stdlib.Core.dll` and verify the DLL loads with the expected
/// types.  This is the foundation for cross-assembly multi-package
/// compilation: once the user-emit path consults imported tables, the
/// same artifact will be referenced from user code.
module Lyric.Emitter.Tests.MultiPackageTests

open System
open System.IO
open System.Reflection
open Expecto
open Lyric.Emitter.Emitter

let tests =
    testSequenced
    <| testList "multi-package compilation" [

        testCase "[stdlib precompiles to a loadable assembly]" <| fun () ->
            // Reach into the cached artifact via the published accessor.
            // The stdlib hasn't been triggered yet by any prior test so
            // we drive compilation manually by invoking the cache from
            // a no-op user emit that imports Std.Core.
            let outDir =
                Path.Combine(Path.GetTempPath(), "lyric-mp-" + Guid.NewGuid().ToString("N"))
            Directory.CreateDirectory outDir |> ignore
            let dll = Path.Combine(outDir, "Trigger.dll")
            let req =
                { Source       = "package Trigger\nimport Std.Core\nfunc main(): Unit { println(unwrapOr(Some(value = 1), 0)) }"
                  AssemblyName = "Trigger"
                  OutputPath   = dll }
            let _ = emit req
            match stdlibAssemblyPath () with
            | None ->
                failtest "stdlib was not compiled — accessor returned None"
            | Some path ->
                Expect.isTrue (File.Exists path)
                    (sprintf "compiled stdlib DLL exists at %s" path)
                let asm = Assembly.LoadFrom path
                let types =
                    asm.GetTypes()
                    |> Array.map (fun t -> t.Name)
                Expect.contains types "Option" "Option type present"
                Expect.contains types "Result" "Result type present"
    ]
