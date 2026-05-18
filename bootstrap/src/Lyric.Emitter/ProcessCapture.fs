/// Helper for the self-hosted verifier kernel: run a subprocess with
/// piped stdin/stdout and return the captured stdout text.
///
/// Exposed as `Lyric.Emitter.ProcessCapture.runCapture` so the stdlib
/// kernel can target it via `@externTarget`.  Always loaded in the
/// AppDomain when emitting or running self-hosted Lyric code.
module Lyric.Emitter.ProcessCapture

open System.Diagnostics

/// Spawn `executable` with a pre-formed `arguments` string, write
/// `stdinContent` to the child's stdin, close stdin, read all stdout,
/// and return it.  Returns `""` on spawn failure or I/O error so
/// callers (the trivial discharger path) degrade gracefully.
let runCapture (executable: string) (arguments: string) (stdinContent: string) : string =
    let psi = ProcessStartInfo()
    psi.FileName  <- executable
    psi.Arguments <- arguments
    psi.RedirectStandardInput  <- true
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.UseShellExecute <- false
    psi.CreateNoWindow  <- true
    try
        match Option.ofObj (Process.Start psi) with
        | None -> ""
        | Some proc ->
            use _ = proc
            proc.StandardInput.Write stdinContent
            proc.StandardInput.Close()
            let stdout = proc.StandardOutput.ReadToEnd()
            proc.WaitForExit()
            stdout
    with _ -> ""
