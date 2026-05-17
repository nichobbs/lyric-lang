/// Stage B62 smoke test — integer bitwise operations (iand, ior, ixor, ishl, ishr).
///
/// Compiles self_test_b62.l which generates Bits.class with band/bor/bxor/shl/shr.
/// Main prints: 15, 255, 90, 16, 32.
module Lyric.Emitter.Tests.JvmLoweringB62Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB62Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b62.l")
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
    testList "Jvm.Driver B62 (bitwise iand/ior/ixor/ishl/ishr)" [

        testCase "b62_bitwise_ops" <| fun () ->
            let src =
                match findSelfTestB62Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b62.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b62" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b62/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
            Expect.equal lines.Length 5
                (sprintf "expected 5 output lines, got %d: '%s'" lines.Length javaOut)

            Expect.equal lines.[0] "15"
                (sprintf "band(0xFF,0x0F) expected '15', got '%s'" lines.[0])
            Expect.equal lines.[1] "255"
                (sprintf "bor(0xF0,0x0F) expected '255', got '%s'" lines.[1])
            Expect.equal lines.[2] "90"
                (sprintf "bxor(0xFF,0xA5) expected '90', got '%s'" lines.[2])
            Expect.equal lines.[3] "16"
                (sprintf "shl(1,4) expected '16', got '%s'" lines.[3])
            Expect.equal lines.[4] "32"
                (sprintf "shr(256,3) expected '32', got '%s'" lines.[4])
    ]
