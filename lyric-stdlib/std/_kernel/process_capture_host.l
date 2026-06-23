//! std/_kernel/process_capture_host.l — trusted host boundary for piped
//! process execution (stdout + stderr capture, exit code, timeout flag).
//!
//! Used by the self-hosted verifier (`Lyric.Verifier`) to invoke z3/cvc5
//! and by the source-generator runtime (`Lyric.Generator`) to invoke
//! generator DLLs.  Implemented entirely in Lyric via direct BCL externs
//! (#1489: F# `Lyric.Emitter.ProcessCapture` shim eliminated).
//!
//! Internal: only Std.ProcessCapture and Std.Process should import this.
@axiom("System.Diagnostics.Process piped stdout/stderr capture")
package Std.ProcessCaptureHost

import Std.Core

// ── BCL extern types ───────────────────────────────────────────────────────
extern type Psi = "System.Diagnostics.ProcessStartInfo"

extern type Proc = "System.Diagnostics.Process"

extern type ProcWriter = "System.IO.StreamWriter"

extern type ProcReader = "System.IO.StreamReader"

// Task<string> — used to start concurrent async pipe drains before waiting
// for the child process to exit, preventing the pipe-buffer-full deadlock
// that sequential synchronous reads would cause when the child writes more
// than the OS pipe buffer (typically 64 KB) to one stream.
extern type TaskStr = "System.Threading.Tasks.Task`1[System.String]"

// ── ProcessStartInfo setup ─────────────────────────────────────────────────
@externTarget("System.Diagnostics.ProcessStartInfo..ctor")
func newPsi(): Psi = ()

@externTarget("System.Diagnostics.ProcessStartInfo.set_FileName")
func psiFileName(psi: in Psi, v: in String): Unit = ()

@externTarget("System.Diagnostics.ProcessStartInfo.set_Arguments")
func psiArguments(psi: in Psi, v: in String): Unit = ()

@externTarget("System.Diagnostics.ProcessStartInfo.set_RedirectStandardInput")
func psiRedirectInput(psi: in Psi, v: in Bool): Unit = ()

@externTarget("System.Diagnostics.ProcessStartInfo.set_RedirectStandardOutput")
func psiRedirectOutput(psi: in Psi, v: in Bool): Unit = ()

@externTarget("System.Diagnostics.ProcessStartInfo.set_RedirectStandardError")
func psiRedirectError(psi: in Psi, v: in Bool): Unit = ()

@externTarget("System.Diagnostics.ProcessStartInfo.set_UseShellExecute")
func psiUseShell(psi: in Psi, v: in Bool): Unit = ()

@externTarget("System.Diagnostics.ProcessStartInfo.set_CreateNoWindow")
func psiNoWindow(psi: in Psi, v: in Bool): Unit = ()

// ── Process control ────────────────────────────────────────────────────────
// Process.Start(ProcessStartInfo) is a static method; the Psi parameter is
// not an instance receiver here — it is the sole argument.
@externStatic
@externTarget("System.Diagnostics.Process.Start")
func procStart(psi: in Psi): Proc = ()

@externInstance
@externTarget("System.Diagnostics.Process.StandardInput")
func procStdinWriter(p: in Proc): ProcWriter = ()

@externInstance
@externTarget("System.Diagnostics.Process.StandardOutput")
func procStdoutReader(p: in Proc): ProcReader = ()

@externInstance
@externTarget("System.Diagnostics.Process.StandardError")
func procStderrReader(p: in Proc): ProcReader = ()

// Returns true when the process exited within `ms` milliseconds, false on
// timeout.  .NET 5+ overload; we target .NET 10 so this is always available.
@externInstance
@externTarget("System.Diagnostics.Process.WaitForExit")
func procWaitMs(p: in Proc, ms: in Int): Bool = ()

@externInstance
@externTarget("System.Diagnostics.Process.Kill")
func procKillTree(p: in Proc, entireProcessTree: in Bool): Unit = ()

@externInstance
@externTarget("System.Diagnostics.Process.ExitCode")
func procExitCode(p: in Proc): Int = ()

// ── Stdin write ────────────────────────────────────────────────────────────
@externInstance
@externTarget("System.IO.StreamWriter.Write")
func writerWrite(w: in ProcWriter, s: in String): Unit = ()

@externInstance
@externTarget("System.IO.StreamWriter.Close")
func writerClose(w: in ProcWriter): Unit = ()

// ── Async pipe drain ───────────────────────────────────────────────────────
// Starts a background read to end-of-stream.  Calling this WITHOUT `await`
// returns the underlying Task<string> immediately; the read runs on the
// thread pool so both stdout and stderr can drain concurrently.
@externInstance
@externTarget("System.IO.TextReader.ReadToEndAsync")
func startReadAll(r: in ProcReader): TaskStr = ()

// Blocks the calling thread until the Task<string> completes and returns its
// result.  Only called after the child has exited (or been killed), so the
// task completes immediately in practice.
@externInstance
@externTarget("System.Threading.Tasks.Task`1[System.String].Result")
func taskStrResult(t: in TaskStr): String = ()

// Blocks the calling thread for up to `milliseconds`.  Returns true if the
// task completed within the timeout, false if the timeout elapsed first.
// Used to cap pipe-drain collection after a process kill so a slow kernel
// reap or a race between kill and child writes cannot hang the caller
// indefinitely (#3029).
@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWaitMs(t: in TaskStr, milliseconds: in Int): Bool = ()

// ── Public result record ───────────────────────────────────────────────────
// Replaces the former opaque `extern type ProcessCaptureResult =
// "Lyric.Emitter.ProcessCapture+CaptureResult"`.
pub record ProcessCaptureResult {
  stdout: String
  stderr: String
  exitCode: Int
  timedOut: Bool
}

// Field accessors — preserved for backward compatibility with Std.ProcessCapture
// and Std.Process which reference these names directly.
pub func pcResultStdout(r: in ProcessCaptureResult): String {
  r.stdout
}

pub func pcResultStderr(r: in ProcessCaptureResult): String {
  r.stderr
}

pub func pcResultExitCode(r: in ProcessCaptureResult): Int {
  r.exitCode
}

pub func pcResultTimedOut(r: in ProcessCaptureResult): Bool {
  r.timedOut
}

// ── Core subprocess implementation ────────────────────────────────────────
func runImpl(exe: in String, args: in String, stdinContent: in String, timeoutMs: in Int): ProcessCaptureResult {
  val psi = newPsi()
  psiFileName(psi, exe)
  psiArguments(psi, args)
  psiRedirectInput(psi, true)
  psiRedirectOutput(psi, true)
  psiRedirectError(psi, true)
  psiUseShell(psi, false)
  psiNoWindow(psi, true)

  val proc = procStart(psi)

  // Write all stdin then close it so the child's reader sees EOF.
  val w = procStdinWriter(proc)
  writerWrite(w, stdinContent)
  writerClose(w)

  // Launch concurrent async drains BEFORE blocking on WaitForExit.
  // Both tasks start immediately on the thread pool, preventing the
  // deadlock where a child that writes > 64 KB to one pipe blocks
  // waiting for the reader while the parent is blocked on WaitForExit.
  val stdoutTask = startReadAll(procStdoutReader(proc))
  val stderrTask = startReadAll(procStderrReader(proc))

  // Wait for the child to finish (or for the timeout to expire).
  val exited = procWaitMs(proc, timeoutMs)
  val timedOut = not exited
  if timedOut {
    try {
      procKillTree(proc, true)
    } catch Bug as _ {
      ()
    }
  }

  // Collect task results.  The child has either exited or been killed, so
  // both pipe write-ends are closed and the tasks normally complete immediately.
  // When the child was killed, apply a 5-second fallback timeout per task so
  // a slow kernel reap or a race between kill and child writes cannot block
  // the calling thread indefinitely (#3029 — mirrors the F# original's
  // `task.Wait(5000)` guard).
  val drainTimeoutMs = 5000
  val stdout = try {
    if timedOut {
      if taskWaitMs(stdoutTask, drainTimeoutMs) {
        taskStrResult(stdoutTask)
      } else {
        ""
      }
    } else {
      taskStrResult(stdoutTask)
    }
  } catch Bug as _ {
    ""
  }
  val stderr = try {
    if timedOut {
      if taskWaitMs(stderrTask, drainTimeoutMs) {
        taskStrResult(stderrTask)
      } else {
        ""
      }
    } else {
      taskStrResult(stderrTask)
    }
  } catch Bug as _ {
    ""
  }
  val code = try {
    procExitCode(proc)
  } catch Bug as _ {
    if timedOut {
      -2
    } else {
      -1
    }
  }

  ProcessCaptureResult(stdout = stdout, stderr = stderr, exitCode = code, timedOut = timedOut)
}

// ── Public entry points ────────────────────────────────────────────────────
// Spawn `executable` with a pre-formed `arguments` string, write
// `stdinContent` to the child's stdin, close stdin, and return a
// `ProcessCaptureResult`.  Spawn failures and I/O errors are silently
// absorbed (backward-compatible behaviour for `Std.ProcessCapture` callers).
pub func hostRunCapture(executable: in String, arguments: in String, stdinContent: in String): ProcessCaptureResult {
  try {
    runImpl(executable, arguments, stdinContent, 10000)
  } catch Bug as _ {
    ProcessCaptureResult(stdout = "", stderr = "", exitCode = -1, timedOut = false)
  }
}

// Variant of `hostRunCapture` with a caller-supplied `timeoutMs` wall-clock
// cap.  Spawn failures propagate as exceptions (Lyric `Bug`) so the `Err`
// return path in callers that wrap with `catch Bug` is reachable (#1062).
pub func hostRunCaptureTimeout(
  executable: in String, arguments: in String, stdinContent: in String, timeoutMs: in Int
): ProcessCaptureResult {
  runImpl(executable, arguments, stdinContent, timeoutMs)
}
