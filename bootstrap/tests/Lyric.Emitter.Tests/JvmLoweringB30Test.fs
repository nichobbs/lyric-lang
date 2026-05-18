/// Stage B30 smoke test — multianewarray (multi-dimensional arrays).
///
/// Compiles self_test_b30.l which generates Grid.class with makeGrid(I,I)[[I
/// (creates int[rows][cols] via multianewarray).  Main calls makeGrid(2,3),
/// prints outer length (2) and inner length (3).
/// First test exercising emitMultiANewArray and 2D array access.
module Lyric.Emitter.Tests.JvmLoweringB30Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB30Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric-compiler", "jvm", "self_test_b30.l")
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
    testList "Jvm.Driver B30 (multianewarray — 2D array creation and access)" [

        testCase "b30_multianewarray_2x3_grid_dimensions" <| fun () ->
            let src =
                match findSelfTestB30Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/jvm/self_test_b30.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b30" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b30/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 2
                (sprintf "expected 2 output lines, got %d: '%s'" lines.Length javaOut)

            // outer dimension = 2
            Expect.equal lines.[0] "2"
                (sprintf "expected outer length=2 on line 1, got: '%s'" lines.[0])

            // inner dimension = 3
            Expect.equal lines.[1] "3"
                (sprintf "expected inner length=3 on line 2, got: '%s'" lines.[1])
    ]
