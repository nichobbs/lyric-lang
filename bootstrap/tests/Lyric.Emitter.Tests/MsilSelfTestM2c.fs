/// Stage M2c smoke test for the MSIL metadata table model.
///
/// Compiles lyric-compiler/msil/msil_self_test_m2c.l via the Lyric emitter,
/// runs it, and verifies the structural invariants it prints.
module Lyric.Emitter.Tests.MsilSelfTestM2c

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric-compiler", "msil", "msil_self_test_m2c.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Msil.SelfTest M2c (metadata table model)" [

        testCase "msil_self_test_m2c" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/msil/msil_self_test_m2c.l"

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m2c" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            let checks = [
                "row_idx_ok"; "count_ok"; "coded_rs_ok"; "coded_tdr_ok"; "coded_mrp_ok"
                "stream_header_ok"; "stream_valid_ok"; "stream_rowcnt_ok"
                "stream_module_ok"; "stream_assembly_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)
    ]
