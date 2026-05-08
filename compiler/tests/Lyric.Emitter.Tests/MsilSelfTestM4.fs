/// Stage M4 multi-method PE assembler test.
///
/// Compiles compiler/lyric/msil/msil_self_test_m4.l via the Lyric emitter,
/// runs it (which writes a two-method PE to /tmp), checks the structural
/// layout assertions, then executes the produced PE with `dotnet exec` and
/// verifies the CLR calls both Greet() invocations correctly.
module Lyric.Emitter.Tests.MsilSelfTestM4

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "msil", "msil_self_test_m4.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let private writeRuntimeConfig (path: string) : unit =
    let v   = Environment.Version
    let tfm = sprintf "net%d.0" v.Major
    let ver = sprintf "%d.%d.%d" v.Major v.Minor v.Build
    let config =
        "{\n"
        + "  \"runtimeOptions\": {\n"
        + "    \"tfm\": \"" + tfm + "\",\n"
        + "    \"framework\": {\n"
        + "      \"name\": \"Microsoft.NETCore.App\",\n"
        + "      \"version\": \"" + ver + "\"\n"
        + "    }\n"
        + "  }\n"
        + "}\n"
    File.WriteAllText(path, config)

let tests =
    testList "Msil.SelfTest M4 (multi-method PE assembler)" [

        testCase "msil_self_test_m4" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/msil/msil_self_test_m4.l"

            let dllPath = "/tmp/lyric_msil_m4_hello.dll"
            let cfgPath = "/tmp/lyric_msil_m4_hello.runtimeconfig.json"

            writeRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m4" src

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
                "greet_hdr_ok"; "greet_ldstr_ok"
                "main_hdr_ok"; "main_call_ok"
                "bsjb_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            // Execute the multi-method PE and verify both Greet calls fire.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            // Main calls Greet twice so "Hello from Greet!" appears twice.
            let lines =
                peStdout.Split([| '\n' |], StringSplitOptions.RemoveEmptyEntries)
                |> Array.filter (fun l -> l.Contains "Hello from Greet!")
            Expect.equal lines.Length 2
                (sprintf "expected 'Hello from Greet!' twice in PE stdout, got: '%s'" peStdout)

            // Cleanup.
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
