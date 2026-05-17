/// Stage B5 smoke test for Jvm.Lowering — stack-map frame computation.
///
/// Compiles lyric/jvm/self_test_b5.l, runs it (which writes
/// B5Test.class to /tmp/lyric-jvm-b5/), then verifies the class is
/// accepted by the JVM verifier by executing `java -cp /tmp/lyric-jvm-b5 B5Test`.
/// A missing or incorrect StackMapTable causes a VerifyError at class-load
/// time, which makes java exit non-zero.
module Lyric.Emitter.Tests.JvmLoweringB5Test

open System
open System.Diagnostics
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

let private findSelfTestB5Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b5.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let private runJava (args: string) : string * string * int =
    let psi = ProcessStartInfo("java", args)
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.UseShellExecute        <- false
    psi.CreateNoWindow         <- true
    let proc =
        match Option.ofObj (Process.Start psi) with
        | Some p -> p
        | None   -> failwith "failed to start java"
    use _ = proc
    let stdout = proc.StandardOutput.ReadToEnd()
    let stderr = proc.StandardError.ReadToEnd()
    proc.WaitForExit()
    stdout, stderr, proc.ExitCode

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

let tests =
    testList "Jvm.Lowering B5 (stack-map frames)" [

        testCase "b5_stackmap_makes_branching_class_jvm_loadable" <| fun () ->
            let src =
                match findSelfTestB5Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b5.l"

            // 1. Compile and run the Lyric program (writes B5Test.class).
            let result, stdout, stderr, exitCode = compileAndRun "jvm_lowering_b5" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "B5Test.class"
                (sprintf "expected 'B5Test.class' in stdout, got: '%s'" stdout)

            // 2. Verify B5Test.class exists.
            let classPath = "/tmp/lyric-jvm-b5/B5Test.class"
            Expect.isTrue (File.Exists classPath)
                (sprintf "B5Test.class was not written to /tmp/lyric-jvm-b5/")

            // 3. Run `java -cp /tmp/lyric-jvm-b5 B5Test`.
            //    If the StackMapTable is absent or malformed the JVM verifier
            //    rejects the class with a VerifyError at load time (exit ≠ 0).
            let jOut, jErr, jExit = runJava "-cp /tmp/lyric-jvm-b5 B5Test"
            Expect.equal jExit 0
                (sprintf "java B5Test must exit 0 — a non-zero exit indicates \
                          a bad StackMapTable (VerifyError or ClassFormatError).\n\
                          java stdout: %s\njava stderr: %s" jOut jErr)
    ]
