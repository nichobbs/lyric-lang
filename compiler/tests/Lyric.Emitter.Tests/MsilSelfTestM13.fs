/// Stage M13 while-loop / backward-branch test.
///
/// Compiles compiler/lyric/msil/msil_self_test_m13.l, runs it (producing a
/// PE with Main() summing 1..5 via a while loop), then executes the PE with
/// `dotnet exec` verifying that "15" appears in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM13

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M13 (while loop / backward branch)" [

        testCase "msil_self_test_m13" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m13.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/msil/msil_self_test_m13.l"

            let dllPath = "/tmp/lyric_msil_m13_loop.dll"
            let cfgPath = "/tmp/lyric_msil_m13_loop.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m13" src

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
                "cgt_ok"; "brtrue_ok"; "br_back_ok"
                "bsjb_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            // Execute the PE; Main sums 1+2+3+4+5 = 15 and prints it.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "15"
                (sprintf "expected '15' in PE stdout, got: '%s'" peStdout)

            // Cleanup
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
