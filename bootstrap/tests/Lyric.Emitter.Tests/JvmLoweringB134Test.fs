/// Stage B134 smoke test — IImpl codegen pipeline integration.
/// Exercises codegenPackage → lowerPackage routing for Lyric `impl Y for X`
/// declarations (Band 3 of docs/41 §9) via Jvm.Bridge.
module Lyric.Emitter.Tests.JvmLoweringB134Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit
open Lyric.Emitter.Tests.JvmTestKit

let tests =
    testList "Jvm.Lowering B134 (IImpl codegen pipeline, Band 3)" [

        testCase "b134_impl_codegen_pipeline" <| fun () ->
            // Wipe any stale JAR from a prior run so File.Exists
            // can't pass on a leftover artifact.
            let jarPath = "/tmp/lyric-jvm-b134/impl.jar"
            try if File.Exists jarPath then File.Delete jarPath with _ -> ()

            let src =
                match findJvmSource "self_test_b134.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/jvm/self_test_b134.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b134" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar exit 0 expected, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 1
                (sprintf "expected 1 output line, got %d: '%s'" lines.Length javaOut)
            Expect.equal lines.[0] "impl_ok"
                (sprintf "line 0: '%s'" lines.[0])
    ]
