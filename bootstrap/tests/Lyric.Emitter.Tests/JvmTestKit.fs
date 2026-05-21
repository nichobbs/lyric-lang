/// Shared helpers for JVM lowering tests (Band 3).
///
/// `findJvmSource` walks up from the test binary's base directory looking
/// for a self-test source file under `lyric-compiler/jvm/`.
///
/// `runJar` invokes `java -jar <path>`, captures stdout, and returns
/// (stdout, exitCode) — `(""", -1)` on process-start failure.
///
/// Both functions are extracted to retire the verbatim duplication that
/// accumulated across the `JvmLoweringB128..B134Test.fs` family (#880,
/// #886, #898).
module Lyric.Emitter.Tests.JvmTestKit

open System
open System.IO

/// Walk up from the test binary's `AppContext.BaseDirectory` looking
/// for the named self-test source file under `lyric-compiler/jvm/`.
/// Returns `None` if not found in any ancestor directory.
let findJvmSource (filename: string) : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric-compiler", "jvm", filename)
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

/// Invoke `java -jar <jarPath>` and capture stdout.  Returns
/// `(stdout, exitCode)`; on process-start failure returns `("", -1)`.
let runJar (jarPath: string) : string * int =
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
