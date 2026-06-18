/// Stage M36 ldind.i4 + stind.i4 test.
///
/// Compiles lyric-compiler/msil/msil_self_test_m36.l, runs it (PE stores 42
/// into a local via ldloca_S + stind.i4, then reads it back via ldind.i4 and
/// prints), then executes the PE verifying "42" in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM36

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M36 (ldind.i4 + stind.i4)" [

        testCase "msil_self_test_m36" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m36.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/msil/msil_self_test_m36.l"

            let dllPath = "/tmp/lyric_msil_m36_ldind.dll"
            let cfgPath = "/tmp/lyric_msil_m36_ldind.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m36" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "fat_hdr_ok"; "local_sig_ok"
                           "ldloca_ok"; "stind_ok"; "ldind_ok"; "bsjb_ok" ] do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "42"
                (sprintf "expected '42' in PE stdout, got: '%s'" peStdout)

            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
