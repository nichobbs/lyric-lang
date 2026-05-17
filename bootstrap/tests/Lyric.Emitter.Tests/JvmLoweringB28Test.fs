/// Stage B28 smoke test — primitive casts (i2l, i2d, d2i).
///
/// Compiles self_test_b28.l which generates Casts.class with:
///   intToLong(I)J  — i2l widening
///   intToDouble(I)D — i2d widening
///   doubleToInt(D)I — d2i narrowing (truncates toward zero)
/// Main prints:
///   42         (intToLong(42) as long)
///   3.14159    (intToDouble(314159) / 100000.0)
///   2          (doubleToInt(2.99) truncates to 2)
module Lyric.Emitter.Tests.JvmLoweringB28Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB28Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b28.l")
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
    testList "Jvm.Driver B28 (primitive casts: i2l, i2d, d2i)" [

        testCase "b28_primitive_casts_round_trip" <| fun () ->
            let src =
                match findSelfTestB28Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b28.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b28" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b28/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 3
                (sprintf "expected 3 output lines, got %d: '%s'" lines.Length javaOut)

            // intToLong(42) printed as long
            Expect.equal lines.[0] "42"
                (sprintf "expected intToLong(42)=42 on line 1, got: '%s'" lines.[0])

            // intToDouble(314159) / 100000.0 = 3.14159
            Expect.stringContains lines.[1] "3.14159"
                (sprintf "expected 3.14159 on line 2, got: '%s'" lines.[1])

            // doubleToInt(2.99) truncates to 2
            Expect.equal lines.[2] "2"
                (sprintf "expected doubleToInt(2.99)=2 on line 3, got: '%s'" lines.[2])
    ]
