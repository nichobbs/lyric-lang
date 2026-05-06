/// Stage B68 smoke test — tableswitch for contiguous range dispatch.
///
/// Compiles self_test_b68.l which generates Grades.class with letterGrade(I)String
/// using tableswitch over score/10 in [7..10].
/// Main prints: "A", "A", "B", "C", "F".
module Lyric.Emitter.Tests.JvmLoweringB68Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB68Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b68.l")
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
    testList "Jvm.Driver B68 (tableswitch)" [

        testCase "b68_tableswitch_grade" <| fun () ->
            let src =
                match findSelfTestB68Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/jvm/self_test_b68.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b68" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b68/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 5
                (sprintf "expected 5 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "A"
                (sprintf "letterGrade(95) expected 'A', got '%s'" lines.[0])
            Expect.equal lines.[1] "A"
                (sprintf "letterGrade(100) expected 'A', got '%s'" lines.[1])
            Expect.equal lines.[2] "B"
                (sprintf "letterGrade(83) expected 'B', got '%s'" lines.[2])
            Expect.equal lines.[3] "C"
                (sprintf "letterGrade(72) expected 'C', got '%s'" lines.[3])
            Expect.equal lines.[4] "F"
                (sprintf "letterGrade(60) expected 'F', got '%s'" lines.[4])
    ]
