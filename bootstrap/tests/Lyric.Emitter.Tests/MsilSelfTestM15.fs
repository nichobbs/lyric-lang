/// Stage M15 ldc.i8 / conv.i4 test.
///
/// Compiles lyric/msil/msil_self_test_m15.l, runs it (producing a
/// PE that pushes 1000000000L and 2L, multiplies to 2000000000L, narrows via
/// conv.i4, and prints it), then executes the PE verifying "2000000000" in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM15

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M15 (ldc.i8 / conv.i4)" [

        testCase "msil_self_test_m15" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m15.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/msil/msil_self_test_m15.l"

            let dllPath = "/tmp/lyric_msil_m15_i64.dll"
            let cfgPath = "/tmp/lyric_msil_m15_i64.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m15" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            let checks = [
                "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                "tiny_hdr_ok"; "ldc_i8_ok"; "mul_ok"; "conv_i4_ok"
                "bsjb_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            // Execute the PE; Main computes 1000000000 * 2 = 2000000000 and prints it.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "2000000000"
                (sprintf "expected '2000000000' in PE stdout, got: '%s'" peStdout)

            // Cleanup
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
