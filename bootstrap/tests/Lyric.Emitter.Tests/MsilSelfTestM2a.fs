/// Stage M2a smoke test for the self-hosted MSIL heap builders.
///
/// Compiles lyric-compiler/msil/msil_self_test_m2a.l via the Lyric emitter,
/// runs it, and verifies the structural invariants it prints.
module Lyric.Emitter.Tests.MsilSelfTestM2a

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric-compiler", "msil", "msil_self_test_m2a.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Msil.SelfTest M2a (heap builder structural checks)" [

        testCase "msil_self_test_m2a" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/msil/msil_self_test_m2a.l"

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m2a" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            let checks = [
                "strings_start_ok"; "string_intern_ok"; "string_size_ok"; "string_bytes_ok"
                "blob_start_ok"; "blob_intern_ok"; "blob_size_ok"
                "us_start_ok"; "us_intern_ok"; "us_size_ok"; "us_bytes_ok"
                "guid_start_ok"; "guid_intern_ok"; "guid_size_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)
    ]
