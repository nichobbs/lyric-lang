/// Stage B59 smoke test — Integer.toBinaryString / toHexString / toOctalString.
///
/// Compiles self_test_b59.l which generates Converter.class with toBin/toHex/toOct
/// static methods wrapping java.lang.Integer string-conversion builtins.
/// Main prints: toBin(10)="1010", toHex(255)="ff", toOct(8)="10".
module Lyric.Emitter.Tests.JvmLoweringB59Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB59Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b59.l")
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
    testList "Jvm.Driver B59 (Integer.toBinaryString/toHexString/toOctalString)" [

        testCase "b59_integer_string_conversions" <| fun () ->
            let src =
                match findSelfTestB59Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b59.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b59" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b59/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 3
                (sprintf "expected 3 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "1010"
                (sprintf "toBin(10) expected '1010', got '%s'" lines.[0])
            Expect.equal lines.[1] "ff"
                (sprintf "toHex(255) expected 'ff', got '%s'" lines.[1])
            Expect.equal lines.[2] "10"
                (sprintf "toOct(8) expected '10', got '%s'" lines.[2])
    ]
