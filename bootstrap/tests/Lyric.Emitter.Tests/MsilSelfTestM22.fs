/// Stage M22 ldstr + #US heap test.
///
/// Compiles lyric-compiler/msil/msil_self_test_m22.l, runs it (PE loads
/// "Hello, World!" via ldstr and calls Console.WriteLine(string)), then
/// executes the PE verifying "Hello, World!" in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM22

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M22 (ldstr / #US heap)" [

        testCase "msil_self_test_m22" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m22.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/msil/msil_self_test_m22.l"

            let dllPath = "/tmp/lyric_msil_m22_ldstr.dll"
            let cfgPath = "/tmp/lyric_msil_m22_ldstr.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m22" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "tiny_hdr_ok"; "ldstr_ok"; "ldstr_tok_ok"
                           "bsjb_ok"; "us_off_ok" ] do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "Hello, World!"
                (sprintf "expected 'Hello, World!' in PE stdout, got: '%s'" peStdout)

            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
