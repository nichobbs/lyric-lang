/// Stage B130 smoke test — async generator full pipeline integration.
/// Exercises codegenPackage → lowerPackage routing for `async func` with `yield`
/// (Gap-4 / Gap-4a) by compiling a complete Lyric source string via Jvm.Bridge.
module Lyric.Emitter.Tests.JvmLoweringB130Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit
open Lyric.Emitter.Tests.JvmTestKit

let tests =
    testList "Jvm.Lowering B130 (async generator full pipeline, Gap-4/Gap-4a)" [

        testCase "b130_async_generator_pipeline" <| fun () ->
            let src =
                match findJvmSource "self_test_b130.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/jvm/self_test_b130.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b130" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b130/evens.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar exit 0 expected, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 4
                (sprintf "expected 4 output lines (0,2,4,6), got %d: '%s'" lines.Length javaOut)
            Expect.equal lines.[0] "0"  (sprintf "line 0: '%s'" lines.[0])
            Expect.equal lines.[1] "2"  (sprintf "line 1: '%s'" lines.[1])
            Expect.equal lines.[2] "4"  (sprintf "line 2: '%s'" lines.[2])
            Expect.equal lines.[3] "6"  (sprintf "line 3: '%s'" lines.[3])
    ]
