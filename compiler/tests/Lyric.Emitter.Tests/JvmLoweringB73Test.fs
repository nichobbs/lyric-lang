/// Stage B73 smoke test — ifnull / ifnonnull / aconst_null.
///
/// Compiles self_test_b73.l which generates NullCheck.class.
/// Main prints: 1, 0, "x", "y", 1.
module Lyric.Emitter.Tests.JvmLoweringB73Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB73Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b73.l")
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
    testList "Jvm.Driver B73 (ifnull/ifnonnull/aconst_null)" [

        testCase "b73_null_checks" <| fun () ->
            let src =
                match findSelfTestB73Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/jvm/self_test_b73.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b73" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b73/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 5
                (sprintf "expected 5 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "1"
                (sprintf "isNull(null) expected '1', got '%s'" lines.[0])
            Expect.equal lines.[1] "0"
                (sprintf "isNull('hi') expected '0', got '%s'" lines.[1])
            Expect.equal lines.[2] "x"
                (sprintf "orDefault(null,'x') expected 'x', got '%s'" lines.[2])
            Expect.equal lines.[3] "y"
                (sprintf "orDefault('y','x') expected 'y', got '%s'" lines.[3])
            Expect.equal lines.[4] "1"
                (sprintf "isNull(makeNull()) expected '1', got '%s'" lines.[4])
    ]
