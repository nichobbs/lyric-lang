/// Stage M6 method-arguments / non-void-return test.
///
/// Compiles compiler/lyric/msil/msil_self_test_m6.l, runs it (producing a
/// PE with Add(int,int):int and Main()), then executes the PE with `dotnet exec`
/// verifying that "7" appears in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM6

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "msil", "msil_self_test_m6.l")
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
    testList "Msil.SelfTest M6 (method arguments / non-void return)" [

        testCase "msil_self_test_m6" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/msil/msil_self_test_m6.l"

            let dllPath = "/tmp/lyric_msil_m6_add.dll"
            let cfgPath = "/tmp/lyric_msil_m6_add.runtimeconfig.json"

            writeRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m6" src

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
                "add_hdr_ok"; "add_ldarg0_ok"; "add_ldarg1_ok"; "add_add_ok"
                "main_hdr_ok"; "main_ldc3_ok"; "main_ldc4_ok"; "main_call_ok"
                "bsjb_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            // Execute the PE; Main calls Add(3,4) and prints the result.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "7"
                (sprintf "expected '7' in PE stdout, got: '%s'" peStdout)

            // Cleanup
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
