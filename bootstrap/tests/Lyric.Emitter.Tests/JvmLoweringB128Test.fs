/// Stage B128 smoke test — @externTarget static call with Result[T, JvmException] wrapping.
module Lyric.Emitter.Tests.JvmLoweringB128Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Emitter
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b128.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let private runJar (jarPath: string) : string * int =
    try
        let psi = System.Diagnostics.ProcessStartInfo("java", $"-jar {jarPath}")
        psi.RedirectStandardOutput <- true
        psi.RedirectStandardError  <- true
        psi.UseShellExecute        <- false
        match System.Diagnostics.Process.Start(psi) |> Option.ofObj with
        | None -> "", -1
        | Some proc ->
            let stdout = proc.StandardOutput.ReadToEnd()
            proc.WaitForExit()
            stdout, proc.ExitCode
    with _ -> "", -1

let tests =
    testList "Jvm.Lowering B128 (@externTarget static call with Result wrapping)" [

        testCase "b128_extern_target_parse_ok_and_err" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b128.l"

            // Use a per-run unique directory so parallel test runs don't collide
            // and the path works on non-Linux platforms (no hardcoded /tmp).
            let jarDir =
                Path.Combine(Path.GetTempPath(),
                             sprintf "lyric-jvm-b128-%s" (Guid.NewGuid().ToString("N")))
            try
                Directory.CreateDirectory jarDir |> ignore

                let outDir   = prepareOutputDir "jvm_driver_b128"
                try
                    let dll      = Path.Combine(outDir, "jvm_driver_b128.dll")
                    let req =
                        { Source             = src
                          AssemblyName       = "jvm_driver_b128"
                          OutputPath         = dll
                          RestoredPackages   = []
                          NugetAssemblyPaths = []
                          ExternShimRoot     = None
                          Target             = Lyric.Emitter.Emitter.Dotnet
                          ActiveFeatures     = Set.empty
                          DeclaredFeatures   = Set.empty }
                    let result = Lyric.Emitter.Emitter.emit req

                    let errors =
                        result.Diagnostics
                        |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
                    Expect.isEmpty errors
                        (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

                    let stdout, stderr, exitCode = runDllWithArgs dll [ jarDir ]

                    Expect.equal exitCode 0
                        (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

                    Expect.stringContains stdout "jar_written=true"
                        (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

                    let jarPath = Path.Combine(jarDir, "parse.jar")
                    Expect.isTrue (File.Exists jarPath)
                        (sprintf "expected %s to exist" jarPath)

                    let javaOut, javaExit = runJar jarPath
                    Expect.equal javaExit 0
                        (sprintf "java -jar exit 0 expected, got %d (stdout=%s)" javaExit javaOut)

                    let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
                    Expect.equal lines.Length 2
                        (sprintf "expected 2 output lines, got %d: '%s'" lines.Length javaOut)

                    Expect.equal lines.[0] "parse(42)=ok:42"
                        (sprintf "line 0 (ok path): '%s'" lines.[0])
                    Expect.equal lines.[1] "parse(abc)=err:NumberFormatException"
                        (sprintf "line 1 (err path): '%s'" lines.[1])
                finally
                    try Directory.Delete(outDir, recursive = true) with _ -> ()
            finally
                try Directory.Delete(jarDir, recursive = true) with _ -> ()
    ]
