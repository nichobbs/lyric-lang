/// Stage B3 smoke test for Jvm.Lowering (LInsn / LRecord API).
///
/// Compiles lyric-compiler/jvm/self_test_b3.l via the Lyric emitter,
/// runs it (which writes Adder.class and Point.class to a temp dir),
/// then hands each class file to `javap -c` to verify structural validity.
module Lyric.Emitter.Tests.JvmLoweringTest

open System
open System.Diagnostics
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Walk up from `start` looking for `lyric-compiler/jvm/self_test_b3.l`.
let private findSelfTestB3Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric-compiler", "jvm", "self_test_b3.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

/// Run `javap -c <classFile>` and return stdout.
let private javap (classFile: string) : string =
    let psi = ProcessStartInfo("javap", sprintf "-c %s" classFile)
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.UseShellExecute        <- false
    psi.CreateNoWindow         <- true
    let proc =
        match Option.ofObj (Process.Start psi) with
        | Some p -> p
        | None   -> failwith "failed to start javap"
    use _ = proc
    let stdout = proc.StandardOutput.ReadToEnd()
    proc.WaitForExit()
    stdout

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

let tests =
    testList "Jvm.Lowering (stage B3)" [

        testCase "b3_lowering_emits_adder_and_point" <| fun () ->
            let src =
                match findSelfTestB3Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/jvm/self_test_b3.l — run from the source tree"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_lowering_b3" src

            // 1. Compilation must succeed.
            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            // 2. Program must exit cleanly.
            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            // 3. Program must report writing both class files.
            Expect.stringContains stdout "Adder.class"
                (sprintf "expected 'Adder.class' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "Point.class"
                (sprintf "expected 'Point.class' in stdout, got: '%s'" stdout)

            // 4. Adder.class must exist and be JVM-verifiable.
            let adderFile = "/tmp/lyric-jvm-b3/Adder.class"
            Expect.isTrue (File.Exists adderFile)
                (sprintf "Adder.class was not written to %s" adderFile)
            let adderJavap = javap adderFile
            Expect.stringContains adderJavap "add"
                (sprintf "javap output for Adder.class should mention 'add':\n%s" adderJavap)
            Expect.stringContains adderJavap "Code:"
                (sprintf "javap output for Adder.class should contain 'Code:':\n%s" adderJavap)

            // 5. Point.class must exist and be JVM-verifiable.
            let pointFile = "/tmp/lyric-jvm-b3/Point.class"
            Expect.isTrue (File.Exists pointFile)
                (sprintf "Point.class was not written to %s" pointFile)
            let pointJavap = javap pointFile
            Expect.stringContains pointJavap "Code:"
                (sprintf "javap output for Point.class should contain 'Code:':\n%s" pointJavap)
    ]
