/// Stage B8 smoke test — differential fuzzing corpus.
///
/// Compiles lyric/jvm/self_test_b8.l, runs it (which writes
/// B8Corpus.class containing 13 corpus methods + main() to /tmp/lyric-jvm-b8/),
/// verifies the class file exists, then executes
/// `java -Xverify:all -cp /tmp/lyric-jvm-b8 B8Corpus` and checks exit 0.
///
/// `-Xverify:all` forces eager bytecode verification of every method in the
/// class, including those never called by main().  A bad StackMapTable,
/// wrong descriptor, or ill-typed instruction sequence causes a VerifyError
/// at class-load time (exit != 0).
module Lyric.Emitter.Tests.JvmLoweringB8Test

open System
open System.Diagnostics
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

let private findSelfTestB8Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b8.l")
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
    testList "Jvm.Fuzzer B8 (differential fuzzing corpus)" [

        testCase "b8_corpus_class_passes_jvm_verifier" <| fun () ->
            let src =
                match findSelfTestB8Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b8.l"

            // 1. Compile and run the Lyric program (writes B8Corpus.class).
            let result, stdout, stderr, exitCode = compileAndRun "jvm_fuzzer_b8" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "B8Corpus.class"
                (sprintf "expected 'B8Corpus.class' in stdout, got: '%s'" stdout)

            // 2. Verify B8Corpus.class exists.
            let classPath = "/tmp/lyric-jvm-b8/B8Corpus.class"
            Expect.isTrue (File.Exists classPath)
                "B8Corpus.class was not written to /tmp/lyric-jvm-b8/"

            // 3. Run `java -Xverify:all -cp /tmp/lyric-jvm-b8 B8Corpus`.
            //    -Xverify:all forces eager verification of all methods regardless
            //    of whether they are called.  A bad StackMapTable, wrong descriptor,
            //    or ill-typed instruction causes a VerifyError at class-load time.
            let jOut, jErr, jExit = runJava "-Xverify:all -cp /tmp/lyric-jvm-b8 B8Corpus"
            Expect.equal jExit 0
                (sprintf "java B8Corpus must exit 0 — a non-zero exit indicates a \
                          bad class file (VerifyError, ClassFormatError, etc.).\n\
                          java stdout: %s\njava stderr: %s" jOut jErr)
    ]
