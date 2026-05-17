/// Stage M17 bitwise operations test.
///
/// Compiles lyric/msil/msil_self_test_m17.l, runs it (producing a
/// PE that computes (60 & 13) + (60 | 13) = 12 + 61 = 73), then executes
/// the PE verifying "73" in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM17

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M17 (bitwise ops)" [

        testCase "msil_self_test_m17" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m17.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/msil/msil_self_test_m17.l"

            let dllPath = "/tmp/lyric_msil_m17_bitwise.dll"
            let cfgPath = "/tmp/lyric_msil_m17_bitwise.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m17" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            let checks = [
                "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                "tiny_hdr_ok"; "and_ok"; "or_ok"; "add_ok"; "bsjb_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            // Execute the PE; (60 & 13) + (60 | 13) = 12 + 61 = 73.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "73"
                (sprintf "expected '73' in PE stdout, got: '%s'" peStdout)

            // Cleanup
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
