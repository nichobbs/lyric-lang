/// Stage M50 sizeof (0xFE 0x1C — get value-type byte size) test.
///
/// Compiles compiler/lyric/msil/msil_self_test_m50.l, runs it (PE pushes
/// sizeof(System.Int32) = 4, adds 38, prints "42"), then executes the PE
/// verifying "42" output.
module Lyric.Emitter.Tests.MsilSelfTestM50

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M50 (sizeof)" [

        testCase "msil_self_test_m50" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m50.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/msil/msil_self_test_m50.l"

            let dllPath = "/tmp/lyric_msil_m50_sizeof.dll"
            let cfgPath = "/tmp/lyric_msil_m50_sizeof.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m50" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "tiny_hdr_ok"; "sizeof_prefix_ok"; "sizeof_ok"; "bsjb_ok" ] do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            let line = peStdout.Trim()
            Expect.equal line "42"
                (sprintf "expected '42', got: '%s'" peStdout)

            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
