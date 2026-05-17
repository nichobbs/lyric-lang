/// Stage M14 newarr / array element access test.
///
/// Compiles lyric-compiler/msil/msil_self_test_m14.l, runs it (producing a
/// PE with Main() creating int32[3], storing 10/20/30, summing to 60), then
/// executes the PE with `dotnet exec` verifying that "60" appears in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM14

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M14 (newarr / array element access)" [

        testCase "msil_self_test_m14" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m14.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/msil/msil_self_test_m14.l"

            let dllPath = "/tmp/lyric_msil_m14_array.dll"
            let cfgPath = "/tmp/lyric_msil_m14_array.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m14" src

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
                "fat_hdr_ok"; "code_size_ok"; "local_sig_ok"
                "newarr_ok"; "stelem_ok"; "ldelem_ok"
                "bsjb_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            // Execute the PE; Main sums 10+20+30=60 and prints it.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "60"
                (sprintf "expected '60' in PE stdout, got: '%s'" peStdout)

            // Cleanup
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
