/// Stage M2b smoke test for the self-hosted MSIL typed instruction IR.
///
/// Compiles compiler/lyric/msil/msil_self_test_m2b.l via the Lyric emitter,
/// runs it, and verifies the structural invariants it prints.
module Lyric.Emitter.Tests.MsilSelfTestM2b

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "msil", "msil_self_test_m2b.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Msil.SelfTest M2b (typed CIL instruction IR)" [

        testCase "msil_self_test_m2b" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/msil/msil_self_test_m2b.l"

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m2b" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            let checks = [
                "body_size_ok"; "header_ok"; "ldstr_opcode_ok"; "ldstr_token_ok"
                "call_opcode_ok"; "call_token_ok"; "ret_ok"
                "branch_size_ok"; "branch_header_ok"; "branch_opcode_ok"; "branch_offset_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)
    ]
