/// Stage M45 initblk + cpblk (memory block operations) test.
///
/// Compiles lyric/msil/msil_self_test_m45.l, runs it (PE uses
/// initblk to fill 1 byte with 42 and reads it back as u1, then uses
/// cpblk to copy 4 bytes from one local to another and reads back 42),
/// then executes the PE verifying two lines of "42".
module Lyric.Emitter.Tests.MsilSelfTestM45

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Msil.SelfTest M45 (initblk + cpblk)" [

        testCase "msil_self_test_m45" <| fun () ->
            let src =
                match findMsilSource "msil_self_test_m45.l" with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/msil/msil_self_test_m45.l"

            let dllPath = "/tmp/lyric_msil_m45_blk.dll"
            let cfgPath = "/tmp/lyric_msil_m45_blk.runtimeconfig.json"

            writeMsilRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m45" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            for check in [ "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                           "fat_hdr_ok"; "local_sig_ok"
                           "initblk_ok"; "cpblk_ok"; "bsjb_ok" ] do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            let lines = peStdout.Trim().Split('\n') |> Array.map (fun s -> s.Trim())
            Expect.equal lines.Length 2
                (sprintf "expected 2 lines of output, got: '%s'" peStdout)
            for line in lines do
                Expect.equal line "42"
                    (sprintf "expected '42' in each line, got: '%s'" line)

            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
