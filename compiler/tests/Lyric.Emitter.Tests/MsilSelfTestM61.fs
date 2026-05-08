/// Stage M61 overflow arithmetic — add.ovf/sub.ovf/mul.ovf + .un variants.
module Lyric.Emitter.Tests.MsilSelfTestM61

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M61 (overflow arithmetic)" [

        testCase "msil_self_test_m61" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m61.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/msil/msil_self_test_m61.l"

            let dllPath = "/tmp/lyric_msil_m61_ovf.dll"
            let cfgPath = "/tmp/lyric_msil_m61_ovf.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m61" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "tiny_hdr_ok"; "add_ovf_ok"; "sub_ovf_ok"; "mul_ovf_ok"
                           "add_ovf_un_ok"; "sub_ovf_un_ok"; "mul_ovf_un_ok"; "bsjb_ok" ] do
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
