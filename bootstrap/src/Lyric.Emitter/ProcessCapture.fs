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
            // Start the stdout drain on a background thread BEFORE waiting.
            // If ReadToEnd() ran first and the solver hung without closing its
            // stdout pipe, it would block indefinitely — the WaitForExit timeout
            // would never be reached.  Running them concurrently lets the kill
            // fire after 10 s, which closes the pipe and unblocks the drain.
            let stdoutTask =
                System.Threading.Tasks.Task.Run(fun () ->
                    proc.StandardOutput.ReadToEnd())
            // 10-second wall-clock cap: solvers already get a per-query
            // timeout flag (-T:5 for Z3, --tlimit=5000 for cvc5) but a
            // hung or misbehaving solver binary can still block indefinitely
            // if those flags are ignored.  Kill the process tree if it
            // hasn't exited within 2× the configured solver timeout.
            if not (proc.WaitForExit 10000) then
                try proc.Kill(entireProcessTree = true) with _ -> ()
            // Process has exited or been killed; the stdout pipe is now closed.
            // Give the background drain up to 5 s to flush any remaining bytes.
            try
                if stdoutTask.Wait 5000 then stdoutTask.Result else ""
            with _ -> ""
    with _ -> ""
