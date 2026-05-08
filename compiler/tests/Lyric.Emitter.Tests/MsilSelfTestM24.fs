/// Stage M24 instance methods + instance fields test.
///
/// Compiles compiler/lyric/msil/msil_self_test_m24.l, runs it (PE builds a
/// Counter class with a _value field, .ctor, Increment, GetValue; Main calls
/// Increment 3 times via dup+call and prints GetValue result), then executes
/// the PE verifying "3" in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM24

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M24 (instance methods / fields)" [

        testCase "msil_self_test_m24" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m24.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/msil/msil_self_test_m24.l"

            let dllPath = "/tmp/lyric_msil_m24_instance.dll"
            let cfgPath = "/tmp/lyric_msil_m24_instance.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m24" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "ctor_hdr_ok"; "ctor_stfld_ok"
                           "incr_hdr_ok"; "ldfld_ok"; "stfld_ok"
                           "get_hdr_ok"; "get_ldfld_ok"
                           "main_hdr_ok"; "newobj_ok"; "dup_ok"; "call_incr_ok"
                           "bsjb_ok" ] do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "3"
                (sprintf "expected '3' in PE stdout, got: '%s'" peStdout)

            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
