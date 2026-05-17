/// Stage M2d smoke test for the parameterized PE assembler.
///
/// Compiles lyric/msil/msil_self_test_m2d.l via the Lyric emitter,
/// runs it, and verifies the structural layout invariants it prints.
module Lyric.Emitter.Tests.MsilSelfTestM2d

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "msil", "msil_self_test_m2d.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Msil.SelfTest M2d (parameterized PE assembler)" [

        testCase "msil_self_test_m2d" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/msil/msil_self_test_m2d.l"

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m2d" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            let checks = [
                "size_ok"; "dos_ok"; "pe_sig_ok"; "clr_cb_ok"
                "md_rva_ok"; "md_size_ok"; "entry_tok_ok"
                "method_hdr_ok"; "method_ldstr_ok"; "bsjb_ok"; "nstreams_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)
    ]
