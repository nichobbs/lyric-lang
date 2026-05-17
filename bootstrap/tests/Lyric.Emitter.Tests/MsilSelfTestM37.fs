/// Stage M37 ldelema test.
///
/// Compiles lyric/msil/msil_self_test_m37.l, runs it (PE allocates
/// int32[1], takes address of element[0] via ldelema, stores 42 via stind.i4,
/// reads it back via ldelem, and prints), then executes the PE verifying "42"
/// in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM37

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M37 (ldelema)" [

        testCase "msil_self_test_m37" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m37.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/msil/msil_self_test_m37.l"

            let dllPath = "/tmp/lyric_msil_m37_ldelema.dll"
            let cfgPath = "/tmp/lyric_msil_m37_ldelema.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m37" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "fat_hdr_ok"; "local_sig_ok"
                           "newarr_ok"; "ldelema_ok"; "ldelema_tok_ok"; "bsjb_ok" ] do
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
