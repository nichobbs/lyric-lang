/// Stage B4 smoke test for Jvm.Lowering — union-type lowering.
///
/// Compiles lyric-compiler/jvm/self_test_b4.l, runs it (which writes
/// Option.class, Option$Some.class, Option$None.class, and OptionHelper.class
/// to /tmp/lyric-jvm-b4/), then verifies each class via `javap -c`.
module Lyric.Emitter.Tests.JvmLoweringB4Test

open System
open System.Diagnostics
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

let private findSelfTestB4Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric-compiler", "jvm", "self_test_b4.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

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
    testList "Jvm.Lowering B4 (union types)" [

        testCase "b4_lowering_emits_option_union" <| fun () ->
            let src =
                match findSelfTestB4Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/jvm/self_test_b4.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_lowering_b4" src

            // 1. Compilation must succeed.
            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            // 2. Program must exit cleanly.
            Expect.equal exitCode 0
                (sprintf "exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            // 3. All four class files must be mentioned.
            for name in ["Option"; "Option$Some"; "Option$None"; "OptionHelper"] do
                Expect.stringContains stdout name
                    (sprintf "expected '%s' in stdout, got: '%s'" name stdout)

            // 4. Each class file must exist and survive javap.
            let outDir = "/tmp/lyric-jvm-b4"
            for name in ["Option"; "Option$Some"; "Option$None"; "OptionHelper"] do
                let path = Path.Combine(outDir, name + ".class")
                Expect.isTrue (File.Exists path)
                    (sprintf "%s.class was not written to %s" name outDir)
                let javapOut = javap path
                Expect.stringContains javapOut "Code:"
                    (sprintf "javap output for %s.class should contain 'Code:':\n%s" name javapOut)

            // 5. OptionHelper must expose the unwrapOr method.
            let helperJavap = javap (Path.Combine(outDir, "OptionHelper.class"))
            Expect.stringContains helperJavap "unwrapOr"
                (sprintf "javap for OptionHelper.class should mention 'unwrapOr':\n%s" helperJavap)

            // 6. Option$Some must carry the `value` field.
            let someJavap = javap (Path.Combine(outDir, "Option$Some.class"))
            Expect.stringContains someJavap "value"
                (sprintf "javap for Option$Some.class should mention 'value':\n%s" someJavap)
    ]
