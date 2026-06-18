/// Stage M84: managed resource embedding.
///
/// Verifies the new `resourceData` path in `assemblePe`: CLR header
/// Resources directory entry, resource payload placement, metadata
/// table bit, and BSJB-after-resource alignment.
module Lyric.Emitter.Tests.MsilSelfTestM84

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M84 (managed resource embedding)" [

        testCase "msil_self_test_m84" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m84.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/msil/msil_self_test_m84.l"

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m84" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "clr_cb_ok"
                           "rsrc_rva_byte0_ok"; "rsrc_rva_byte1_ok"
                           "rsrc_rva_byte2_ok"; "rsrc_rva_byte3_ok"
                           "rsrc_size_byte0_ok"; "rsrc_size_byte1_ok"
                           "rsrc_size_byte2_ok"; "rsrc_size_byte3_ok"
                           "rsrc_len_prefix_ok"; "rsrc_payload_ok"
                           "bsjb_after_rsrc_ok" ] do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)
    ]
