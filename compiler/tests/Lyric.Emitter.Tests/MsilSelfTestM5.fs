/// Stage M5 local-variable / fat-method-header test.
///
/// Compiles compiler/lyric/msil/msil_self_test_m5.l, runs it (producing a
/// PE whose Main() uses a fat method header and a StandAloneSig local-var
/// signature), then executes the PE with `dotnet exec` verifying that
/// "Hello from locals!" appears twice in stdout.
module Lyric.Emitter.Tests.MsilSelfTestM5

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "msil", "msil_self_test_m5.l")
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
    testList "Msil.SelfTest M5 (local variables / fat method header)" [

        testCase "msil_self_test_m5" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/msil/msil_self_test_m5.l"

            let dllPath = "/tmp/lyric_msil_m5_hello.dll"
            let cfgPath = "/tmp/lyric_msil_m5_hello.runtimeconfig.json"

            writeRuntimeConfig cfgPath
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m5" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            // Layout checks
            let checks = [
                "dos_ok"; "pe_sig_ok"; "clr_cb_ok"; "entry_tok_ok"
                "fat_hdr_ok"; "code_size_ok"; "local_sig_ok"
                "ldstr_ok"; "bsjb_ok"
            ]
            for check in checks do
                Expect.stringContains stdout (check + "=true")
                    (sprintf "expected %s=true in stdout, got: '%s'" check stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            // Execute the PE; Main stores string in local[0] and calls
            // Console.WriteLine(local[0]) twice.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            let lines =
                peStdout.Split([| '\n' |], StringSplitOptions.RemoveEmptyEntries)
                |> Array.filter (fun l -> l.Contains "Hello from locals!")
            Expect.equal lines.Length 2
                (sprintf "expected 'Hello from locals!' twice in PE stdout, got: '%s'" peStdout)

            // Cleanup
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
