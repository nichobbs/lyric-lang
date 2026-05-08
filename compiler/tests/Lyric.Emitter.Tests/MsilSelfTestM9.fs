/// Stage M9 multiple TypeDefs test.
///
/// Compiles compiler/lyric/msil/msil_self_test_m9.l, runs it (producing a
/// PE with three classes Foo, Bar, Hello each owning one static method), then
/// executes the PE with `dotnet exec` verifying that "30" appears in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM9

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M9 (multiple TypeDefs)" [

        testCase "msil_self_test_m9" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m9.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/msil/msil_self_test_m9.l"

            let dllPath = "/tmp/lyric_msil_m9_multitypedef.dll"
            let cfgPath = "/tmp/lyric_msil_m9_multitypedef.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m9" src

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
                "foo_hdr_ok"; "foo_ldc_ok"
                "bar_hdr_ok"; "bar_ldc_ok"
                "main_hdr_ok"; "main_call1_ok"; "main_add_ok"
                "bsjb_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            // Execute the PE; Main calls GetFoo()+GetBar()=10+20 and prints 30.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "30"
                (sprintf "expected '30' in PE stdout, got: '%s'" peStdout)

            // Cleanup
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
