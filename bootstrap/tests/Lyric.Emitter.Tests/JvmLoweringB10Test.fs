/// Stage B10 smoke test — manifest and lyric-contract metadata emission.
///
/// Compiles lyric/jvm/self_test_b10.l, runs it (which generates
/// a MANIFEST.MF string and a lyric-contract JSON stub and prints both),
/// then verifies the expected content in each output section.
module Lyric.Emitter.Tests.JvmLoweringB10Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB10Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b10.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Jvm.Manifest B10 (manifest and contract emission)" [

        testCase "b10_manifest_mf_contains_required_fields" <| fun () ->
            let src =
                match findSelfTestB10Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b10.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_manifest_b10" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "Manifest-Version: 1.0"
                (sprintf "expected Manifest-Version: 1.0 in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "Lyric-Package: Jvm.Classfile"
                (sprintf "expected Lyric-Package: Jvm.Classfile in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "\"package\": \"Jvm.Classfile\""
                (sprintf "expected contract package field in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "\"name\": \"parseClassSummary\""
                (sprintf "expected parseClassSummary export in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "\"name\": \"skipPool\""
                (sprintf "expected skipPool export in stdout, got: '%s'" stdout)
    ]
