/// Stage M1 smoke test for the self-hosted MSIL PE emitter.
///
/// Compiles lyric/msil/msil_self_test_m1.l via the Lyric emitter,
/// runs it, and verifies the structural invariants it prints:
///   pe_size_ok=true   — image is exactly 1024 bytes
///   mz_ok=true        — DOS MZ signature correct
///   pe_sig_ok=true    — "PE\0\0" signature at 0x80
///   clr_header_ok=true — CLR header cb=72 at 0x200
///   bsjb_ok=true      — BSJB metadata magic at 0x254
module Lyric.Emitter.Tests.MsilSelfTestM1

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "msil", "msil_self_test_m1.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let tests =
    testList "Msil.SelfTest M1 (PE image structural checks)" [

        testCase "msil_self_test_m1" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/msil/msil_self_test_m1.l"

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m1" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "pe_size_ok=true"
                (sprintf "expected pe_size_ok=true in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "mz_ok=true"
                (sprintf "expected mz_ok=true in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "pe_sig_ok=true"
                (sprintf "expected pe_sig_ok=true in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "clr_header_ok=true"
                (sprintf "expected clr_header_ok=true in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "bsjb_ok=true"
                (sprintf "expected bsjb_ok=true in stdout, got: '%s'" stdout)
    ]
