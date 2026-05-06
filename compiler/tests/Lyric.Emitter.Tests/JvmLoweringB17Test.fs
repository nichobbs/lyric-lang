/// Stage B17 smoke test — conditional branching with ifge + goto + labels.
///
/// Compiles self_test_b17.l which generates MathB17.class (with a static
/// abs(I)I method using ifge + goto) and Main.class that calls abs(-7) and
/// abs(3), printing 7 and 3.  First test exercising label-based conditional
/// branching in Lyric-emitted JVM bytecode.
module Lyric.Emitter.Tests.JvmLoweringB17Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB17Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b17.l")
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
    testList "Jvm.Driver B17 (conditional branching with ifge + goto)" [

        testCase "b17_label_based_conditional_branching_works" <| fun () ->
            let src =
                match findSelfTestB17Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/jvm/self_test_b17.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b17" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b17/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            // abs(-7) = 7, abs(3) = 3 — both on separate lines.
            let lines = javaOut.Split([| '\n'; '\r' |], System.StringSplitOptions.RemoveEmptyEntries)
            Expect.equal (lines.Length) 2
                (sprintf "expected 2 output lines, got %d: '%s'" lines.Length javaOut)
            Expect.equal lines.[0] "7"
                (sprintf "expected abs(-7)=7 on line 1, got: '%s'" lines.[0])
            Expect.equal lines.[1] "3"
                (sprintf "expected abs(3)=3 on line 2, got: '%s'" lines.[1])
    ]
