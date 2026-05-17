/// Stage B43 smoke test — Math.max and Math.min (static JDK utility).
///
/// Compiles self_test_b43.l which generates MathUtils.class with:
///   clamp(I,I,I)I — clamps a value to [lo, hi] using Math.max and Math.min
/// Main prints: 5, 1, 10.
module Lyric.Emitter.Tests.JvmLoweringB43Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB43Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b43.l")
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
    testList "Jvm.Driver B43 (Math.max + Math.min — value clamping)" [

        testCase "b43_clamp_uses_math_max_and_min" <| fun () ->
            let src =
                match findSelfTestB43Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b43.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b43" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b43/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 3
                (sprintf "expected 3 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "5"  (sprintf "clamp(5,1,10)=5, got '%s'" lines.[0])
            Expect.equal lines.[1] "1"  (sprintf "clamp(0,1,10)=1, got '%s'" lines.[1])
            Expect.equal lines.[2] "10" (sprintf "clamp(15,1,10)=10, got '%s'" lines.[2])
    ]
