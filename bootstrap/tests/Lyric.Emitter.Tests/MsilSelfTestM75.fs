/// Stage M75: ldloc.2/3 (0x08/0x09), stloc.2/3 (0x0C/0x0D), ldloc.s/stloc.s (0x11/0x13), ldloc/stloc wide (0xFE 0x0C/0x0E).
module Lyric.Emitter.Tests.MsilSelfTestM75

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M75 (ldloc.2/3/s/wide + stloc.2/3/s/wide)" [

        testCase "msil_self_test_m75" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m75.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/msil/msil_self_test_m75.l"

            let dllPath = "/tmp/lyric_msil_m75_ldloc_stloc.dll"
            let cfgPath = "/tmp/lyric_msil_m75_ldloc_stloc.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m75" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "fat_hdr_ok"; "stloc_2_ok"; "ldloc_2_ok"; "stloc_3_ok"; "ldloc_3_ok"
                           "stloc_s_ok"; "ldloc_s_ok"; "stloc_ok"; "ldloc_ok"; "bsjb_ok" ] do
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
