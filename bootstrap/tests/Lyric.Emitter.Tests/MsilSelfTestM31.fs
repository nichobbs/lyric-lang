/// Stage M31 ldftn + delegate test.
///
/// Compiles lyric-compiler/msil/msil_self_test_m31.l, runs it (PE loads a
/// function pointer for PrintFortyTwo via ldftn, wraps it in System.Action,
/// then invokes it via callvirt Action::Invoke, which prints 42), then
/// executes the PE verifying "42" in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM31

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M31 (ldftn + delegate)" [

        testCase "msil_self_test_m31" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m31.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/msil/msil_self_test_m31.l"

            let dllPath = "/tmp/lyric_msil_m31_ldftn.dll"
            let cfgPath = "/tmp/lyric_msil_m31_ldftn.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m31" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "main_hdr_ok"; "ldnull_ok"; "ldftn_ok"; "ldftn_tok_ok"
                           "newobj_ok"; "print_hdr_ok"; "bsjb_ok" ] do
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
