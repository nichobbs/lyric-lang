/// Stage B32 smoke test — shift ops (ishl, ishr, iushr) and long comparison (lcmp).
///
/// Compiles self_test_b32.l which generates ShiftOps.class with shl/shr/ushr/lcmp0.
/// Main prints:
///   16  (shl(1, 4)       = 1 << 4)
///   -4  (shr(-8, 1)      = -8 >> 1, arithmetic/sign-extending)
///   15  (ushr(-1, 28)    = 0xFFFFFFFF >>> 28 = 0xF)
///   1   (lcmp0(100L,50L) = 1, positive because 100 > 50)
module Lyric.Emitter.Tests.JvmLoweringB32Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB32Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b32.l")
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
    testList "Jvm.Driver B32 (shift ops: ishl + ishr + iushr + lcmp)" [

        testCase "b32_shift_ops_and_long_compare_correct" <| fun () ->
            let src =
                match findSelfTestB32Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b32.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b32" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b32/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 4
                (sprintf "expected 4 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "16" (sprintf "shl(1,4)=16, got '%s'" lines.[0])
            Expect.equal lines.[1] "-4" (sprintf "shr(-8,1)=-4, got '%s'" lines.[1])
            Expect.equal lines.[2] "15" (sprintf "ushr(-1,28)=15, got '%s'" lines.[2])
            Expect.equal lines.[3] "1"  (sprintf "lcmp0(100L,50L)=1, got '%s'" lines.[3])
    ]
