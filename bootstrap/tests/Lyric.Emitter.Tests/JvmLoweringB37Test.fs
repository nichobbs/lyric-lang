/// Stage B37 smoke test — aconst_null, ifnull, ifnonnull.
///
/// Compiles self_test_b37.l which generates NullCheck.class (Java 5) with:
///   isNull(Object)Z   — ifnonnull branch
///   orDefault(String,String)String — ifnull branch
/// Main prints: 1, 0, "default", "hi".
module Lyric.Emitter.Tests.JvmLoweringB37Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB37Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b37.l")
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
    testList "Jvm.Driver B37 (aconst_null + ifnull + ifnonnull)" [

        testCase "b37_null_checks_and_default_value" <| fun () ->
            let src =
                match findSelfTestB37Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b37.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b37" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b37/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 4
                (sprintf "expected 4 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "1"       (sprintf "isNull(null)=1, got '%s'" lines.[0])
            Expect.equal lines.[1] "0"       (sprintf "isNull(\"hello\")=0, got '%s'" lines.[1])
            Expect.equal lines.[2] "default" (sprintf "orDefault(null,\"default\")=default, got '%s'" lines.[2])
            Expect.equal lines.[3] "hi"      (sprintf "orDefault(\"hi\",\"x\")=hi, got '%s'" lines.[3])
    ]
