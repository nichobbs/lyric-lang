/// Stage B110 smoke test — lowerOpaqueType (opaque-type wrapper codegen).
module Lyric.Emitter.Tests.JvmLoweringB110Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b110.l")
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
    testList "Jvm.Lowering B110 (lowerOpaqueType)" [

        testCase "b110_opaque_type_fields" <| fun () ->
            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b110.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b110" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b110/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar exit 0 expected, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 4
                (sprintf "expected 4 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "point.$x=3"   (sprintf "line 0: '%s'" lines.[0])
            Expect.equal lines.[1] "point.$y=4"   (sprintf "line 1: '%s'" lines.[1])
            Expect.equal lines.[2] "origin.$x=0"  (sprintf "line 2: '%s'" lines.[2])
            Expect.equal lines.[3] "origin.$y=0"  (sprintf "line 3: '%s'" lines.[3])
    ]
