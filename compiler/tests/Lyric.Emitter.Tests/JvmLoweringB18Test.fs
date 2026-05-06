/// Stage B18 smoke test — StackMapTable generation for manually-assembled bytecode.
///
/// Repeats the abs(I)I branch test from B17 but uses assembleCodeWithFrames
/// (which generates a StackMapTable) so the class file targets Java 21 (major=65)
/// and passes the verifier without -noverify.
/// First test validating StackMapTable generation in the manual assembly path.
module Lyric.Emitter.Tests.JvmLoweringB18Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB18Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b18.l")
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
    testList "Jvm.Driver B18 (StackMapTable for manual assembly)" [

        testCase "b18_stackmaptable_enables_branching_in_java21_class" <| fun () ->
            let src =
                match findSelfTestB18Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/jvm/self_test_b18.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b18" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b18/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0 (verifier accepts StackMapTable), got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], System.StringSplitOptions.RemoveEmptyEntries)
            Expect.equal (lines.Length) 2
                (sprintf "expected 2 output lines, got %d: '%s'" lines.Length javaOut)
            Expect.equal lines.[0] "7"
                (sprintf "expected abs(-7)=7 on line 1, got: '%s'" lines.[0])
            Expect.equal lines.[1] "3"
                (sprintf "expected abs(3)=3 on line 2, got: '%s'" lines.[1])
    ]
