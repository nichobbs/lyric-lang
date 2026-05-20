/// Negative-path tests for the self-hosted JVM bridge (`Lyric.Cli.SelfHostedJvm`).
///
/// Mirrors the Band 1 middle-end gating tests in
/// `SelfHostedMsilBridgeTests.fs` for the JVM side (#828).  Confirms that
/// mode-checker errors abort the bridge before codegen, parse errors
/// abort, and JVM-specific J001 (Long/Double main return) rejects pre-
/// codegen rather than panicking during class-file emission.
module Lyric.Cli.Tests.SelfHostedJvmBridgeTests

open System
open System.IO
open Expecto
open Lyric.Cli

/// Compile `source` via `SelfHostedJvm.compileToJar` and assert it
/// FAILS.  Probes the bridge's static surface first; skips the
/// assertion when the JVM kernel can't initialise in this environment
/// (matching the #839 pattern from JvmDiagnosticTests).
let private mkBridgeFails (label: string) (pkgName: string) (source: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let dir =
            Path.Combine(
                Path.GetTempPath(),
                sprintf "lyric-jvm-bridge-test-%s-%s" label (Guid.NewGuid().ToString "N"))
        Directory.CreateDirectory dir |> ignore
        try
            let jar = Path.Combine(dir, label + ".jar")
            // Suppress stderr from the bridge so the test log is clean —
            // the bridge prints diagnostics to stderr and we don't want
            // a wall of noise per test.
            let prevErr = Console.Error
            Console.SetError TextWriter.Null
            let ok =
                try SelfHostedJvm.compileToJar source jar pkgName
                finally Console.SetError prevErr
            Expect.isFalse ok
                (sprintf "self-hosted JVM compile should fail for '%s' (Band 1 gating)" label)
        finally
            try Directory.Delete(dir, recursive = true) with _ -> ()

let tests =
    testSequenced
    <| testList "SelfHostedJvm bridge (Band 1 gating)" [

        // V0004: @axiom function with a body.  Without Band 1 wiring the
        // bridge silently emitted a JAR anyway.
        mkBridgeFails "shj_mode_check_v0004" "ShJVerify"
            """@proof_required
package ShJVerify

@axiom
func aboveSafe(x: in Int): Bool {
  x > 0
}

func main(): Unit { }
"""

        // Parse errors must abort the bridge before codegen.
        mkBridgeFails "shj_parse_error" "ShJParse"
            """package ShJParse

func main(): Unit {
  val x = 1 +
}
"""

        // J001: func main(): Long/Double is rejected pre-codegen because
        // the JVM main wrapper only emits a category-1 POP.  Also covered
        // by JvmDiagnosticTests but mirroring it here keeps the bridge's
        // negative-path matrix complete.
        mkBridgeFails "shj_main_long_return" "ShJLongMain"
            """package ShJLongMain
func main(): Long {
  return 1
}
"""
    ]
