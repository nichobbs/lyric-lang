/// Stage B132 smoke test — IDistinctType codegen pipeline integration.
/// Exercises codegenPackage → lowerPackage routing for Lyric `type X = Y`
/// distinct type declarations (Band 3 of docs/41 §9) via Jvm.Bridge.
module Lyric.Emitter.Tests.JvmLoweringB132Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit
open Lyric.Emitter.Tests.JvmTestKit

let tests =
    testList "Jvm.Lowering B132 (IDistinctType codegen pipeline, Band 3)" [

        testCase "b132_distinct_type_codegen_pipeline" <| fun () ->
            let src =
                match findJvmSource "self_test_b132.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/jvm/self_test_b132.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b132" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b132/distinct.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar exit 0 expected, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 1
                (sprintf "expected 1 output line, got %d: '%s'" lines.Length javaOut)
            Expect.equal lines.[0] "distinct_ok"
                (sprintf "line 0: '%s'" lines.[0])
    ]
