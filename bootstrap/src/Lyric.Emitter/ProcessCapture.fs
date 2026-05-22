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
///
/// **Stderr handling (#743):** stderr is redirected AND drained on a
/// background thread.  Without draining, a child that writes >4 KB
/// (Linux default) or >64 KB (Windows default) to stderr blocks on
/// the write once the pipe buffer fills — the F# parent never reads,
/// the child hangs, the 10-second WaitForExit timeout fires, the
/// child is killed, and stdout often ends up empty even though the
/// child had real output to deliver.  The drain prevents the deadlock.
/// Drained stderr is forwarded to the host process's own stderr so
/// it remains visible to whoever invoked the bridge / generator.  A
/// richer API that returns `(exitCode, stdout, stderr)` as a struct
/// is tracked in #743 as the follow-up; the immediate change here
/// is the deadlock fix + stderr visibility.
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
            // Start BOTH drains on background threads BEFORE waiting.
            // Running them concurrently lets the kill (if it fires) close
            // both pipes and unblock both drains.
            let stdoutTask =
                System.Threading.Tasks.Task.Run(fun () ->
                    proc.StandardOutput.ReadToEnd())
            // Drain stderr (#743): a non-empty stderr that we never read
            // can fill the pipe buffer and deadlock the child mid-write.
            let stderrTask =
                System.Threading.Tasks.Task.Run(fun () ->
                    proc.StandardError.ReadToEnd())
            // 10-second wall-clock cap: solvers already get a per-query
            // timeout flag (-T:5 for Z3, --tlimit=5000 for cvc5) but a
            // hung or misbehaving solver binary can still block indefinitely
            // if those flags are ignored.  Kill the process tree if it
            // hasn't exited within 2× the configured solver timeout.
            if not (proc.WaitForExit 10000) then
                try proc.Kill(entireProcessTree = true) with _ -> ()
            // Surface stderr so a generator / bridge failure remains
            // visible.  Skipped silently if the drain itself errored.
            try
                if stderrTask.Wait 5000 then
                    let errBytes = stderrTask.Result
                    if not (System.String.IsNullOrEmpty errBytes) then
                        System.Console.Error.Write errBytes
            with _ -> ()
            // Process has exited or been killed; the stdout pipe is now closed.
            // Give the background drain up to 5 s to flush any remaining bytes.
            try
                if stdoutTask.Wait 5000 then stdoutTask.Result else ""
            with _ -> ""
    with _ -> ""
