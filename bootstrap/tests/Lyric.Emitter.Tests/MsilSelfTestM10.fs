/// Stage M10 virtual method dispatch test.
///
/// Compiles lyric/msil/msil_self_test_m10.l, runs it (producing a
/// PE with abstract Base, concrete Impl, and Hello classes), then executes
/// the PE with `dotnet exec` verifying that "77" appears in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM10

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M10 (callvirt virtual dispatch)" [

        testCase "msil_self_test_m10" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m10.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/msil/msil_self_test_m10.l"

            let dllPath = "/tmp/lyric_msil_m10_callvirt.dll"
            let cfgPath = "/tmp/lyric_msil_m10_callvirt.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m10" src

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

            // Execute the PE; Main creates Impl via newobj, calls callvirt Base.GetValue,
            // which dispatches to Impl.GetValue returning 77.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "77"
                (sprintf "expected '77' in PE stdout, got: '%s'" peStdout)

            // Cleanup
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
