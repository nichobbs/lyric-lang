/// Stage M8 newobj + instance fields test.
///
/// Compiles compiler/lyric/msil/msil_self_test_m8.l, runs it (producing a
/// PE with an instance constructor and ldfld/stfld), then executes the PE
/// with `dotnet exec` verifying that "99" appears in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM8

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M8 (newobj + instance fields)" [

        testCase "msil_self_test_m8" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m8.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/msil/msil_self_test_m8.l"

            let dllPath = "/tmp/lyric_msil_m8_newobj.dll"
            let cfgPath = "/tmp/lyric_msil_m8_newobj.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m8" src

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
                "ctor_hdr_ok"; "ctor_stfld_ok"
                "main_hdr_ok"; "newobj_ok"; "ldfld_ok"
                "bsjb_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            // Execute the PE; Main creates Hello(99) and prints x_val.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "99"
                (sprintf "expected '99' in PE stdout, got: '%s'" peStdout)

            // Cleanup
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
