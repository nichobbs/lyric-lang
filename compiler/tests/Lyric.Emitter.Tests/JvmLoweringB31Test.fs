/// Stage B31 smoke test — bitwise integer ops (iand, ior, ixor, irem).
///
/// Compiles self_test_b31.l which generates BitOps.class with andMask/orFlags/
/// xorBits/rem methods.  Main prints:
///   15  (0xFF & 0x0F)
///   171 (0xA0 | 0x0B = 0xAB)
///   6   (10 ^ 12 = 0b0110)
///   2   (17 % 5)
module Lyric.Emitter.Tests.JvmLoweringB31Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB31Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b31.l")
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
    testList "Jvm.Driver B31 (bitwise ops: iand + ior + ixor + irem)" [

        testCase "b31_bitwise_ops_and_remainder_correct" <| fun () ->
            let src =
                match findSelfTestB31Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/jvm/self_test_b31.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b31" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b31/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 4
                (sprintf "expected 4 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "15"  (sprintf "andMask(0xFF,0x0F)=15, got '%s'" lines.[0])
            Expect.equal lines.[1] "171" (sprintf "orFlags(0xA0,0x0B)=171, got '%s'" lines.[1])
            Expect.equal lines.[2] "6"   (sprintf "xorBits(10,12)=6, got '%s'" lines.[2])
            Expect.equal lines.[3] "2"   (sprintf "rem(17,5)=2, got '%s'" lines.[3])
    ]
