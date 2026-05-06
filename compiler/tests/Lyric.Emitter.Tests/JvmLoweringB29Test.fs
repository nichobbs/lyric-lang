/// Stage B29 smoke test — instanceof + checkcast.
///
/// Compiles self_test_b29.l which generates TypeCheck.class with:
///   isString(Object)Z  — instanceof check (returns 1 for String args)
///   castToString(Object)String — checkcast to String + areturn
/// Main: isString("hello")→1, castToString("world")→"world".
module Lyric.Emitter.Tests.JvmLoweringB29Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB29Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b29.l")
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
    testList "Jvm.Driver B29 (instanceof + checkcast)" [

        testCase "b29_instanceof_and_checkcast_work" <| fun () ->
            let src =
                match findSelfTestB29Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/jvm/self_test_b29.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b29" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b29/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 2
                (sprintf "expected 2 output lines, got %d: '%s'" lines.Length javaOut)

            // isString("hello") = 1
            Expect.equal lines.[0] "1"
                (sprintf "expected isString(\"hello\")=1 on line 1, got: '%s'" lines.[0])

            // castToString("world") = "world"
            Expect.equal lines.[1] "world"
                (sprintf "expected castToString(\"world\")=world on line 2, got: '%s'" lines.[1])
    ]
