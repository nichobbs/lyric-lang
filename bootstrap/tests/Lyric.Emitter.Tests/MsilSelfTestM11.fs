/// Stage M11 InterfaceImpl table test.
///
/// Compiles lyric/msil/msil_self_test_m11.l, runs it (producing a
/// PE with an interface IGetter, implementing class Impl, and Hello), then
/// executes the PE with `dotnet exec` verifying that "42" appears in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM11

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M11 (InterfaceImpl table)" [

        testCase "msil_self_test_m11" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m11.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/msil/msil_self_test_m11.l"

            let dllPath = "/tmp/lyric_msil_m11_ifaceimpl.dll"
            let cfgPath = "/tmp/lyric_msil_m11_ifaceimpl.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m11" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            // Structural layout checks
            let checks = [
                "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                "ctor_hdr_ok"
                "getv_hdr_ok"; "getv_ldc_ok"
                "main_hdr_ok"; "newobj_ok"; "callvirt_ok"
                "bsjb_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            // Execute the PE; Main creates Impl via newobj, calls callvirt IGetter.GetValue,
            // which dispatches to Impl.GetValue returning 42.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "42"
                (sprintf "expected '42' in PE stdout, got: '%s'" peStdout)

            // Cleanup
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
