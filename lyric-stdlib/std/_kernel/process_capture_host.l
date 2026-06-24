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

// Non-generic Task (base class) — returned by Stream.CopyToAsync(Stream).
// Using the non-generic base avoids the Task<T> invariant-generic TypeSpec
// issue that arose with the retired Task<string> / ReadToEndAsync approach.
extern type Task = "System.Threading.Tasks.Task"

// System.IO.Stream — the type of StreamReader.BaseStream, and the target
// type for CopyToAsync.
extern type Stream = "System.IO.Stream"

// MemoryStream used as an in-memory accumulator for each pipe drain.
extern type MemStream = "System.IO.MemoryStream"

// ── ProcessStartInfo setup ─────────────────────────────────────────────────
@externTarget("System.Diagnostics.ProcessStartInfo..ctor")
func newPsi(): Psi = ()

@externInstance
@externTarget("System.Diagnostics.ProcessStartInfo.set_FileName")
func psiFileName(psi: in Psi, v: in String): Unit = ()

@externInstance
@externTarget("System.Diagnostics.ProcessStartInfo.set_Arguments")
func psiArguments(psi: in Psi, v: in String): Unit = ()

@externInstance
@externTarget("System.Diagnostics.ProcessStartInfo.set_RedirectStandardInput")
func psiRedirectInput(psi: in Psi, v: in Bool): Unit = ()

@externInstance
@externTarget("System.Diagnostics.ProcessStartInfo.set_RedirectStandardOutput")
func psiRedirectOutput(psi: in Psi, v: in Bool): Unit = ()

@externInstance
@externTarget("System.Diagnostics.ProcessStartInfo.set_RedirectStandardError")
func psiRedirectError(psi: in Psi, v: in Bool): Unit = ()

@externInstance
@externTarget("System.Diagnostics.ProcessStartInfo.set_UseShellExecute")
func psiUseShell(psi: in Psi, v: in Bool): Unit = ()

@externInstance
@externTarget("System.Diagnostics.ProcessStartInfo.set_CreateNoWindow")
func psiNoWindow(psi: in Psi, v: in Bool): Unit = ()

// ── Process control ────────────────────────────────────────────────────────
// Process.Start(ProcessStartInfo) is a static method; the Psi parameter is
// not an instance receiver here — it is the sole argument.
@externStatic
@externTarget("System.Diagnostics.Process.Start")
func procStart(psi: in Psi): Proc = ()

@externInstance
@externTarget("System.Diagnostics.Process.get_StandardInput")
func procStdinWriter(p: in Proc): ProcWriter = ()

@externInstance
@externTarget("System.Diagnostics.Process.get_StandardOutput")
func procStdoutReader(p: in Proc): ProcReader = ()

@externInstance
@externTarget("System.Diagnostics.Process.get_StandardError")
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
@externTarget("System.Diagnostics.Process.get_ExitCode")
func procExitCode(p: in Proc): Int = ()

// ── Stdin write ────────────────────────────────────────────────────────────
@externInstance
@externTarget("System.IO.StreamWriter.Write")
func writerWrite(w: in ProcWriter, s: in String): Unit = ()

@externInstance
@externTarget("System.IO.StreamWriter.Close")
func writerClose(w: in ProcWriter): Unit = ()

// ── Async pipe drain (MemoryStream-based) ─────────────────────────────────
// Instead of ReadToEndAsync() → Task<string> (which hits invariant-generic
// cast issues with the current TypeSpec builder), we drain each pipe's
// underlying Stream into a MemoryStream via CopyToAsync() → Task (non-
// generic base class).  Both drains start concurrently before WaitForExit,
// preventing the pipe-buffer-full deadlock (#3029).

// The underlying raw Stream from a StreamReader — the drain target for
// CopyToAsync so we bypass the generic Task<string> problem.
@externInstance
@externTarget("System.IO.StreamReader.get_BaseStream")
func readerBaseStream(r: in ProcReader): Stream = ()

// Create a fresh MemoryStream accumulator.
@externTarget("System.IO.MemoryStream..ctor")
func newMemStream(): MemStream = ()

// Drain `src` into `dst` asynchronously and return a non-generic Task.
// The dst MemStream widens to the Stream parameter via the metadata-direct
// resolver's lenient named-reference matching.
@externInstance
@externTarget("System.IO.Stream.CopyToAsync")
func streamCopyTo(src: in Stream, dst: in MemStream): Task = ()

// Block for up to `ms` milliseconds until the drain Task completes.
// Returns true on completion, false on timeout.
@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func drainWaitMs(t: in Task, ms: in Int): Bool = ()

// Seek the MemStream back to the start so the StreamReader sees the full
// content.  Position is Int64 (Long); pass 0i64.
@externInstance
@externTarget("System.IO.Stream.set_Position")
func memStreamResetPos(ms: in MemStream, pos: in Long): Unit = ()

// Wrap a MemStream in a new StreamReader for decoding.  Reuses the ProcReader
// extern type (same CLR type).  The MemStream argument widens to the Stream
// constructor parameter via lenient matching.
@externTarget("System.IO.StreamReader..ctor")
func newProcReaderFrom(s: in MemStream): ProcReader = ()

// Synchronously read all remaining content from a StreamReader.  Safe here
// because all content is already buffered in the MemStream.
@externInstance
@externTarget("System.IO.TextReader.ReadToEnd")
func readAllSync(r: in ProcReader): String = ()

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
  val stdoutBuf = newMemStream()
  val stderrBuf = newMemStream()
  val stdoutTask = streamCopyTo(readerBaseStream(procStdoutReader(proc)), stdoutBuf)
  val stderrTask = streamCopyTo(readerBaseStream(procStderrReader(proc)), stderrBuf)

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

  // Collect drain results with a 5-second fallback timeout per task so
  // a slow kernel reap or a race between kill and child writes cannot block
  // the calling thread indefinitely (#3029).  After the task completes,
  // reset the MemStream position and wrap in a StreamReader to decode.
  val drainTimeoutMs = 5000
  val stdout = try {
    if drainWaitMs(stdoutTask, drainTimeoutMs) {
      memStreamResetPos(stdoutBuf, 0i64)
      readAllSync(newProcReaderFrom(stdoutBuf))
    } else {
      ""
    }
  } catch Bug as _ {
    ""
  }
  val stderr = try {
    if drainWaitMs(stderrTask, drainTimeoutMs) {
      memStreamResetPos(stderrBuf, 0i64)
      readAllSync(newProcReaderFrom(stderrBuf))
    } else {
      ""
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
