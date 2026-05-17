/// Stage B96 smoke test — Jvm.Reader round-trip (write class → parse → verify).
module Lyric.Emitter.Tests.JvmLoweringB96Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric-compiler", "jvm", "self_test_b96.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Jvm.Reader B96 (round-trip)" [

        testCase "b96_reader_round_trip" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/jvm/self_test_b96.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b96" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            let lines = stdout.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 3
                (sprintf "expected 3 output lines, got %d: '%s'" lines.Length stdout)

            Expect.equal lines.[0] "magic_valid=true"
                (sprintf "expected 'magic_valid=true', got '%s'" lines.[0])

            Expect.equal lines.[1] "major=65"
                (sprintf "expected 'major=65', got '%s'" lines.[1])

            Expect.equal lines.[2] "method_count=1"
                (sprintf "expected 'method_count=1', got '%s'" lines.[2])
    ]
