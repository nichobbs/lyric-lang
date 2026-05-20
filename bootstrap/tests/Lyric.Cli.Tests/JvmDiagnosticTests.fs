/// JVM-bridge diagnostic regressions (#638).
///
/// Cover the J001 reject path in `lyric-compiler/jvm/bridge.l`: a Lyric
/// program declaring `func main(): Long` (or Double) is rejected before
/// codegen because the JVM main wrapper only emits a category-1 POP and
/// would otherwise generate a class file that VerifyError-fails at load.
module Lyric.Cli.Tests.JvmDiagnosticTests

open System
open System.IO
open Expecto
open Lyric.Cli

let tests =
    testSequenced
    <| testList "JVM bridge diagnostics (J001)" [

        testCase "[J001 rejects func main(): Long]" <| fun () ->
            // Capture Console.error output via a redirected stderr stream so
            // we can assert the J001 message is present.  The Lyric bridge
            // writes the diagnostic to stderr via Std.Console.error.
            let dir =
                Path.Combine(
                    Path.GetTempPath(),
                    sprintf "lyric-j001-%s" (Guid.NewGuid().ToString "N"))
            Directory.CreateDirectory dir |> ignore
            try
                let jar = Path.Combine(dir, "j001_long_main.jar")
                let source =
                    "package J001LongMain\nfunc main(): Long {\n  return 1\n}\n"

                let stderrSb = System.Text.StringBuilder()
                let prevErr = Console.Error
                use capture = new StringWriter(stderrSb)
                Console.SetError capture

                let ok =
                    try SelfHostedJvm.compileToJar source jar "J001LongMain"
                    finally Console.SetError prevErr

                Expect.isFalse ok
                    "compileToJar must report failure for `func main(): Long`"
                let stderr = stderrSb.ToString()
                Expect.stringContains stderr "J001"
                    (sprintf "expected J001 in stderr, got: %s" stderr)
                Expect.stringContains stderr "Long"
                    (sprintf "expected the offending type in the J001 message, got: %s" stderr)
            finally
                try Directory.Delete(dir, recursive = true) with _ -> ()

        testCase "[J001 rejects func main(): Double]" <| fun () ->
            let dir =
                Path.Combine(
                    Path.GetTempPath(),
                    sprintf "lyric-j001-d-%s" (Guid.NewGuid().ToString "N"))
            Directory.CreateDirectory dir |> ignore
            try
                let jar = Path.Combine(dir, "j001_double_main.jar")
                let source =
                    "package J001DoubleMain\nfunc main(): Double {\n  return 1.0\n}\n"

                let stderrSb = System.Text.StringBuilder()
                let prevErr = Console.Error
                use capture = new StringWriter(stderrSb)
                Console.SetError capture

                let ok =
                    try SelfHostedJvm.compileToJar source jar "J001DoubleMain"
                    finally Console.SetError prevErr

                Expect.isFalse ok
                    "compileToJar must report failure for `func main(): Double`"
                let stderr = stderrSb.ToString()
                Expect.stringContains stderr "J001"
                    (sprintf "expected J001 in stderr, got: %s" stderr)
            finally
                try Directory.Delete(dir, recursive = true) with _ -> ()
    ]
