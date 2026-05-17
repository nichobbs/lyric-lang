/// Stage M82: ldelem.i1/u1/i2 (0x90/0x91/0x92) + stelem.i1/i2 (0x9C/0x9D) + ldelem.u4 (0x95) + stelem/ldelem tok (0xA4/0xA3).
module Lyric.Emitter.Tests.MsilSelfTestM82

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M82 (typed stelem/ldelem: i1/u1/i2/u4 + tok)" [

        testCase "msil_self_test_m82" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m82.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/msil/msil_self_test_m82.l"

            let dllPath = "/tmp/lyric_msil_m82_stelem_ldelem_b.dll"
            let cfgPath = "/tmp/lyric_msil_m82_stelem_ldelem_b.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m82" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "fat_hdr_ok"
                           "stelem_i1_ok"; "ldelem_u1_ok"; "ldelem_i1_ok"
                           "stelem_i2_ok"; "ldelem_i2_ok"
                           "ldelem_u4_ok"
                           "stelem_tok_ok"; "ldelem_tok_ok"; "bsjb_ok" ] do
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
