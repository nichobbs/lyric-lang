/// Stage B60 smoke test — java.lang.Math static methods (abs, min, max).
///
/// Compiles self_test_b60.l which generates MathHelper.class with absInt/minInt/maxInt
/// wrapping java.lang.Math builtins.
/// Main prints: absInt(-7)=7, minInt(3,8)=3, maxInt(3,8)=8.
module Lyric.Emitter.Tests.JvmLoweringB60Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB60Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b60.l")
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
    testList "Jvm.Driver B60 (Math.abs/min/max)" [

        testCase "b60_math_abs_min_max" <| fun () ->
            let src =
                match findSelfTestB60Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b60.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b60" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b60/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 3
                (sprintf "expected 3 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "7"
                (sprintf "absInt(-7) expected '7', got '%s'" lines.[0])
            Expect.equal lines.[1] "3"
                (sprintf "minInt(3,8) expected '3', got '%s'" lines.[1])
            Expect.equal lines.[2] "8"
                (sprintf "maxInt(3,8) expected '8', got '%s'" lines.[2])
    ]
