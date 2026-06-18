/// Stage B66 smoke test — String.valueOf for int, long, boolean.
///
/// Compiles self_test_b66.l which generates Stringifier.class with intToStr/longToStr/boolToStr.
/// Main prints: "42", "-100", "999999999", "true", "false".
module Lyric.Emitter.Tests.JvmLoweringB66Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB66Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric-compiler", "jvm", "self_test_b66.l")
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
    testList "Jvm.Driver B66 (String.valueOf int/long/boolean)" [

        testCase "b66_string_valueof" <| fun () ->
            let src =
                match findSelfTestB66Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/jvm/self_test_b66.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b66" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b66/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 5
                (sprintf "expected 5 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "42"
                (sprintf "intToStr(42) expected '42', got '%s'" lines.[0])
            Expect.equal lines.[1] "-100"
                (sprintf "intToStr(-100) expected '-100', got '%s'" lines.[1])
            Expect.equal lines.[2] "999999999"
                (sprintf "longToStr(999999999) expected '999999999', got '%s'" lines.[2])
            Expect.equal lines.[3] "true"
                (sprintf "boolToStr(1) expected 'true', got '%s'" lines.[3])
            Expect.equal lines.[4] "false"
                (sprintf "boolToStr(0) expected 'false', got '%s'" lines.[4])
    ]
