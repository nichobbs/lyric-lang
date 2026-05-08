/// Stage M3 end-to-end PE execution test.
///
/// Compiles compiler/lyric/msil/msil_self_test_m3.l via the Lyric emitter,
/// runs it (which writes a raw MSIL PE to /tmp via Std.File.writeBytes),
/// then executes the produced PE with `dotnet exec` and verifies the CLR
/// output contains "Hello, World!".
module Lyric.Emitter.Tests.MsilSelfTestM3

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "msil", "msil_self_test_m3.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

/// Write a runtimeconfig.json that matches the host runtime so that
/// `dotnet exec` can locate the correct framework for the raw PE.
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
    testList "Msil.SelfTest M3 (end-to-end PE execution)" [

        testCase "msil_self_test_m3" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/msil/msil_self_test_m3.l"

            let dllPath = "/tmp/lyric_msil_m3_hello.dll"
            let cfgPath = "/tmp/lyric_msil_m3_hello.runtimeconfig.json"

            // Stage runtimeconfig so dotnet exec can find the framework.
            writeRuntimeConfig cfgPath

            // Remove any leftover PE from a prior run.
            if File.Exists dllPath then File.Delete dllPath

            let result, stdout, stderr, exitCode = compileAndRun "msil_self_test_m3" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "wrote_pe=true"
                (sprintf "expected wrote_pe=true in stdout, got: '%s'" stdout)

            Expect.isTrue (File.Exists dllPath)
                (sprintf "expected PE to exist at %s" dllPath)

            // Execute the assembled PE under the CLR and verify output.
            let peStdout, peStderr, peExitCode = runDll dllPath

            Expect.equal peExitCode 0
                (sprintf "PE exit code expected 0 (stderr=%s stdout=%s)" peStderr peStdout)

            Expect.stringContains peStdout "Hello, World!"
                (sprintf "expected 'Hello, World!' in PE stdout, got: '%s'" peStdout)

            // Cleanup.
            try File.Delete dllPath with _ -> ()
            try File.Delete cfgPath with _ -> ()
    ]
