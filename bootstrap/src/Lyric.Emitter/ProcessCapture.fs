/// Helper for the self-hosted verifier kernel: run a subprocess with
/// piped stdin/stdout/stderr and return a structured result.
///
/// Exposed as `Lyric.Emitter.ProcessCapture.runCapture` so the stdlib
/// kernel can target it via `@externTarget`.  Always loaded in the
/// AppDomain when emitting or running self-hosted Lyric code.
module Lyric.Emitter.ProcessCapture

open System.Diagnostics

/// Structured result of a subprocess invocation (#743 / #1025).
/// Callers that only need stdout can use the `Stdout` field directly;
/// callers that need diagnostics (generator failures, solver errors)
/// use `Stderr`, `ExitCode`, and `TimedOut`.
type CaptureResult =
    { Stdout:   string
      Stderr:   string
      ExitCode: int
      TimedOut: bool }

/// The empty-output sentinel returned on spawn failure.
let private captureFailure : CaptureResult =
    { Stdout = ""; Stderr = ""; ExitCode = -1; TimedOut = false }

/// Shared subprocess implementation: spawn `executable`, write `stdinContent`,
/// drain stdout+stderr in parallel, wait up to `timeoutMs`, and return a
/// `CaptureResult`.
let private runCaptureImpl (executable: string) (arguments: string) (stdinContent: string) (timeoutMs: int) : CaptureResult =
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
        | None -> captureFailure
        | Some proc ->
            use _ = proc
            proc.StandardInput.Write stdinContent
            proc.StandardInput.Close()
            // Drain both pipes on background threads BEFORE WaitForExit.
            // Running them concurrently lets the kill (if it fires) close
            // both pipes and unblock both drains.
            let stdoutTask =
                System.Threading.Tasks.Task.Run(fun () ->
                    proc.StandardOutput.ReadToEnd())
            let stderrTask =
                System.Threading.Tasks.Task.Run(fun () ->
                    proc.StandardError.ReadToEnd())
            let timedOut = not (proc.WaitForExit timeoutMs)
            if timedOut then
                try proc.Kill(entireProcessTree = true) with _ -> ()
            let stdout = try if stdoutTask.Wait 5000 then stdoutTask.Result else "" with _ -> ""
            let stderr = try if stderrTask.Wait 5000 then stderrTask.Result else "" with _ -> ""
            let exitCode = try proc.ExitCode with _ -> if timedOut then -2 else -1
            { Stdout = stdout; Stderr = stderr; ExitCode = exitCode; TimedOut = timedOut }
    with _ -> captureFailure

/// Spawn `executable` with a pre-formed `arguments` string, write
/// `stdinContent` to the child's stdin, close stdin, and return a
/// `CaptureResult` with the captured stdout, stderr, exit code, and
/// whether the process was killed for exceeding the 10-second wall-clock cap.
///
/// Both stdout and stderr are drained on background threads before
/// `WaitForExit` so that a child that writes more than the pipe-buffer
/// limit (4 KB on Linux, 64 KB on Windows) to either stream cannot
/// deadlock against the parent.
let runCapture (executable: string) (arguments: string) (stdinContent: string) : CaptureResult =
    runCaptureImpl executable arguments stdinContent 10000

/// Variant of `runCapture` with a caller-supplied `timeoutMs` wall-clock cap
/// instead of the hardcoded 10-second default.  Used by `Std.Process.runCapture`
/// and `Std.Process.runCaptureWithInput` (#1023 / #743).
let runCaptureWithTimeout (executable: string) (arguments: string) (stdinContent: string) (timeoutMs: int) : CaptureResult =
    runCaptureImpl executable arguments stdinContent timeoutMs
