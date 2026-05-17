/// Stage M69 checked from-unsigned unsigned conversions — conv.ovf.u1.un (0x86), conv.ovf.u2.un (0x87), conv.ovf.u4.un (0x88), conv.ovf.u8.un (0x89).
module Lyric.Emitter.Tests.MsilSelfTestM69

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M69 (conv.ovf.u1.un/u2.un/u4.un/u8.un)" [

        testCase "msil_self_test_m69" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m69.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/msil/msil_self_test_m69.l"

            let dllPath = "/tmp/lyric_msil_m69_conv_ovf_uun.dll"
            let cfgPath = "/tmp/lyric_msil_m69_conv_ovf_uun.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m69" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "tiny_hdr_ok"; "conv_ovf_u1_un_ok"; "conv_ovf_u2_un_ok"
                           "conv_ovf_u4_un_ok"; "conv_ovf_u8_un_ok"; "bsjb_ok" ] do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.equal (peStdout.Trim()) "42"
                (sprintf "expected '42', got: '%s'" peStdout)

            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
