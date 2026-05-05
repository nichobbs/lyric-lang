/// Stage B6 smoke test for Jvm.Lowering — protected types and wire blocks.
///
/// Compiles compiler/lyric/jvm/self_test_b6.l, runs it (which writes
/// B6Counter.class, B6Services.class, and B6Driver.class to /tmp/lyric-jvm-b6/),
/// then verifies all three classes are accepted by the JVM verifier by
/// executing `java -cp /tmp/lyric-jvm-b6 B6Driver`.
/// A missing or malformed method/field causes a VerifyError or
/// NoSuchMethodError at class-load time, making java exit non-zero.
module Lyric.Emitter.Tests.JvmLoweringB6Test

open System
open System.Diagnostics
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

let private findSelfTestB6Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b6.l")
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
    testList "Jvm.Lowering B6 (protected types + wires)" [

        testCase "b6_protected_type_and_wire_classes_are_jvm_loadable" <| fun () ->
            let src =
                match findSelfTestB6Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/jvm/self_test_b6.l"

            // 1. Compile and run the Lyric program (writes three .class files).
            let result, stdout, stderr, exitCode = compileAndRun "jvm_lowering_b6" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "B6Counter.class"
                (sprintf "expected 'B6Counter.class' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "B6Services.class"
                (sprintf "expected 'B6Services.class' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "B6Driver.class"
                (sprintf "expected 'B6Driver.class' in stdout, got: '%s'" stdout)

            // 2. Verify all three class files exist.
            Expect.isTrue (File.Exists "/tmp/lyric-jvm-b6/B6Counter.class")
                "B6Counter.class was not written to /tmp/lyric-jvm-b6/"
            Expect.isTrue (File.Exists "/tmp/lyric-jvm-b6/B6Services.class")
                "B6Services.class was not written to /tmp/lyric-jvm-b6/"
            Expect.isTrue (File.Exists "/tmp/lyric-jvm-b6/B6Driver.class")
                "B6Driver.class was not written to /tmp/lyric-jvm-b6/"

            // 3. Run `java -cp /tmp/lyric-jvm-b6 B6Driver`.
            //    Loading B6Driver causes the JVM to load and verify B6Counter and
            //    B6Services.  A bad StackMapTable, wrong descriptor, or missing
            //    method raises VerifyError / NoSuchMethodError at class-load time.
            let jOut, jErr, jExit = runJava "-cp /tmp/lyric-jvm-b6 B6Driver"
            Expect.equal jExit 0
                (sprintf "java B6Driver must exit 0 — a non-zero exit indicates a \
                          bad class file (VerifyError, NoSuchMethodError, etc.).\n\
                          java stdout: %s\njava stderr: %s" jOut jErr)
    ]
