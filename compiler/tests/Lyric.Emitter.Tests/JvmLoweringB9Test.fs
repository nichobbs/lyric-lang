/// Stage B9 smoke test — class-file reader round-trip verification.
///
/// Compiles compiler/lyric/jvm/self_test_b9.l, runs it (which generates
/// Hello.class bytes in memory, reads them back with Jvm.Reader, and prints
/// the parsed header fields), then verifies the expected values:
///   magic_valid=true  (0xCAFEBABE confirmed)
///   major=65          (Java 21 class-file format)
///   method_count=1    (Hello has exactly one method: main)
module Lyric.Emitter.Tests.JvmLoweringB9Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB9Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b9.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Jvm.Reader B9 (class-file reader round-trip)" [

        testCase "b9_reader_parses_hello_class_correctly" <| fun () ->
            let src =
                match findSelfTestB9Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/jvm/self_test_b9.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_reader_b9" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "magic_valid=true"
                (sprintf "expected magic_valid=true in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "major=65"
                (sprintf "expected major=65 in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "method_count=1"
                (sprintf "expected method_count=1 in stdout, got: '%s'" stdout)
    ]
