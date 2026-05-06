/// Stage B102 smoke test — tableswitch and lookupswitch in LInsn.
module Lyric.Emitter.Tests.JvmLoweringB102Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b102.l")
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
    testList "Jvm.Lowering B102 (tableswitch + lookupswitch)" [

        testCase "b102_switch" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/jvm/self_test_b102.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b102" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b102/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar exit 0 expected, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 7
                (sprintf "expected 7 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "A=gradeStr(4)"   (sprintf "line 0: '%s'" lines.[0])
            Expect.equal lines.[1] "B=gradeStr(3)"   (sprintf "line 1: '%s'" lines.[1])
            Expect.equal lines.[2] "C=gradeStr(2)"   (sprintf "line 2: '%s'" lines.[2])
            Expect.equal lines.[3] "?=gradeStr(5)"   (sprintf "line 3: '%s'" lines.[3])
            Expect.equal lines.[4] "Mon=dayName(1)"  (sprintf "line 4: '%s'" lines.[4])
            Expect.equal lines.[5] "Wed=dayName(3)"  (sprintf "line 5: '%s'" lines.[5])
            Expect.equal lines.[6] "?=dayName(2)"    (sprintf "line 6: '%s'" lines.[6])
    ]
