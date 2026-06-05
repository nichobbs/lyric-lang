/// Stage B120 smoke test — lowerScopeBlock (scope-block codegen).
module Lyric.Emitter.Tests.JvmLoweringB120Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSource () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric-compiler", "jvm", "self_test_b120.l")
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

// Detect the JDK major version from `java -version` stderr output.
// Returns 21 on parse failure (safe fallback).
let private detectJavaMajorVersion () : int =
    try
        let psi = System.Diagnostics.ProcessStartInfo("java", "-version")
        psi.RedirectStandardOutput <- true
        psi.RedirectStandardError  <- true
        psi.UseShellExecute        <- false
        match System.Diagnostics.Process.Start(psi) |> Option.ofObj with
        | None -> 21
        | Some proc ->
            let stderr = proc.StandardError.ReadToEnd()
            proc.WaitForExit()
            let m = System.Text.RegularExpressions.Regex.Match(stderr, "version \"(\\d+)")
            if m.Success then (int m.Groups.[1].Value) else 21
    with _ -> 21

let tests =
    testList "Jvm.Lowering B120 (lowerScopeBlock)" [

        testCase "b120_scope_block" <| fun () ->
            // StructuredTaskScope.ShutdownOnFailure was removed in JDK 24 (JEP 499).
            // lowerScopeBlock panics on JDK 24+ by design; JDK 24+ support is tracked
            // in issue #2263.  Skip the full execution on JDK 24+ to avoid a spurious
            // failure; the compile step is still exercised on all JDK versions.
            let jdkVersion = detectJavaMajorVersion ()

            let src =
                match findSource () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/jvm/self_test_b120.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b120" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            if jdkVersion >= 24 then
                // lowerScopeBlock panics on JDK 24+ by design (tracked in #2263);
                // the Lyric program exits non-zero with the expected diagnostic.
                // Skip JAR-run assertions on this JDK version.
                ()
            else
                Expect.equal exitCode 0
                    (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

                Expect.stringContains stdout "jar_written=true"
                    (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

                let jarPath = "/tmp/lyric-jvm-b120/hello.jar"
                Expect.isTrue (File.Exists jarPath)
                    (sprintf "expected %s to exist" jarPath)

                let javaOut, javaExit = runJar jarPath
                Expect.equal javaExit 0
                    (sprintf "java -jar exit 0 expected, got %d (stdout=%s)" javaExit javaOut)

                let lines = javaOut.Split([| '\n'; '\r' |], StringSplitOptions.RemoveEmptyEntries)
                Expect.equal lines.Length 2
                    (sprintf "expected 2 output lines, got %d: '%s'" lines.Length javaOut)

                Expect.equal lines.[0] "a=hello"  (sprintf "line 0: '%s'" lines.[0])
                Expect.equal lines.[1] "b=world"  (sprintf "line 1: '%s'" lines.[1])
    ]
