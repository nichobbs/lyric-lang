/// Stage B2 smoke test for the JVM classfile + bytecode packages.
///
/// Compiles compiler/lyric/jvm/self_test.l via the Lyric emitter, runs it
/// (which writes Hello.class to a temp dir), then hands the class file to
/// `javap -c` to verify it is a structurally valid JVM class file.
module Lyric.Emitter.Tests.JvmSelfTest

open System
open System.Diagnostics
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Walk up from `start` looking for `lyric/jvm/self_test.l`.
let private findSelfTestSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test.l")
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
    testList "Jvm.SelfTest (stage B2)" [

        testCase "[hello_class_bytes_are_jvm_loadable]" <| fun () ->
            let src =
                match findSelfTestSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate compiler/lyric/jvm/self_test.l — run from the source tree"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_self_test" src

            // 1. Compilation must succeed (no error-code diagnostics).
            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            // 2. Program must exit cleanly.
            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            // 3. Program must report writing bytes.
            Expect.stringContains stdout "wrote"
                (sprintf "expected 'wrote' in stdout, got: '%s'" stdout)

            // 4. Hello.class must exist and be JVM-verifiable via javap.
            let classFile = "/tmp/lyric-jvm-selftest/Hello.class"
            Expect.isTrue (File.Exists classFile)
                (sprintf "Hello.class was not written to %s" classFile)

            let javapOut = javap classFile
            Expect.stringContains javapOut "main"
                (sprintf "javap output should mention 'main':\n%s" javapOut)
            Expect.stringContains javapOut "Code:"
                (sprintf "javap output should contain 'Code:' section:\n%s" javapOut)
    ]
