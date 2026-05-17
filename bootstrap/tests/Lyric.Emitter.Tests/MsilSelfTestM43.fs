/// Stage M43 localloc (stack allocation) test.
///
/// Compiles lyric/msil/msil_self_test_m43.l, runs it (PE uses
/// localloc to allocate 4 bytes of stack memory, writes 42, reads it back,
/// and prints "42"), then executes the PE verifying one line of "42".
module Lyric.Emitter.Tests.MsilSelfTestM43

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M43 (localloc)" [

        testCase "msil_self_test_m43" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m43.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/msil/msil_self_test_m43.l"

            let dllPath = "/tmp/lyric_msil_m43_localloc.dll"
            let cfgPath = "/tmp/lyric_msil_m43_localloc.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m43" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "fat_hdr_ok"; "local_sig_ok"
                           "localloc_ok"; "stind_ok"; "ldind_ok"; "bsjb_ok" ] do
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
