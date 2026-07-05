//! std/_kernel_native/process_capture_host.l — native-target piped
//! process execution.
//!
//! The `--target native` twin of `_kernel/process_capture_host.l`,
//! selected by the native source loader by basename.  Implements the
//! list-argv Result seam (issue #4752) that `Std.Process` delegates to,
//! over lyric-rt's `lyric_process_run` (fork + execvp, never a shell —
//! the argv list is passed through verbatim with no quoting or word
//! splitting).
//!
//! Both seams honor the full managed contract (issue #4752, runCapture
//! half): `stdinContent` is written to an always-piped child stdin
//! (interleaved with output reads, so large content cannot deadlock),
//! and `timeoutMs >= 0` SIGKILLs the child on expiry with `timedOut`
//! true and exit code -2 — unless the reap shows the child had already
//! exited normally (#5107).
@axiom("fork/execvp piped process capture via lyric-rt conforms to its documented contract")
package Std.ProcessCaptureHost

import Std.Core
import Std.Collections
import Std.Time

// ── Public result record ───────────────────────────────────────────────────
pub record ProcessCaptureResult {
  stdout: String
  stderr: String
  exitCode: Int
  timedOut: Bool
}

// Field accessors — the same surface the managed twin exports for
// Std.ProcessCapture and Std.Process.
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

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

// `args` is the raw kernel handle of a Std.Collections `List[String]`
// (LyricList*): collection values ride extern `NativePtr[Byte]`
// parameters as their kernel pointers (N4.5 argument adaptation).
extern func rtProcessRun(path: NativePtr[Byte], args: NativePtr[Byte], stdinContent: String, timeoutMs: Int, outCode: NativePtr[Int], outStdout: NativePtr[String], outStderr: NativePtr[String], outTimedOut: NativePtr[Int]): Int = "lyric_process_run"

@unsafe_ffi
pub func hostRunCaptureList(
  executable: in String, args: in List[String], stdinContent: in String, timeoutMs: in Int
): Result[ProcessCaptureResult, String] {
  var code: Int = 0
  var outText: String = ""
  var errText: String = ""
  var timedOutFlag: Int = 0
  val c = toC(executable)
  val rc = rtProcessRun(
    c,
    args,
    stdinContent,
    timeoutMs,
    nativeAddrOf(code),
    nativeAddrOf(outText),
    nativeAddrOf(errText),
    nativeAddrOf(timedOutFlag)
  )
  freeC(c)
  if rc == 0 {
    // Managed contract: a timed-out capture reports exit code -2, not
    // the raw 128+SIGKILL status the reap produced.
    val timedOut = timedOutFlag != 0
    val exitCode = if timedOut { 0 - 2 } else { code }
    Ok(value = ProcessCaptureResult(stdout = outText, stderr = errText, exitCode = exitCode, timedOut = timedOut))
  } else {
    Err(error = "failed to spawn process: " + executable)
  }
}

// ── Async seam (the async process leaf, D-N-023) ─────────────────────────────
// Nonblocking capture op over lyric-rt (see lyric_process.c): start ->
// pump until done -> accessors -> free.
extern func rtProcessStart(path: NativePtr[Byte], args: NativePtr[Byte], stdinContent: String): NativePtr[Byte] = "lyric_process_start"

extern func rtProcessSpawnFailed(op: NativePtr[Byte]): Int = "lyric_process_spawn_failed"

extern func rtProcessPump(op: NativePtr[Byte]): Int = "lyric_process_pump"

// Returns 1 when the kill terminated the child, 0 when the child had
// already exited (real exit status preserved) — see #5107.
extern func rtProcessKill(op: NativePtr[Byte]): Int = "lyric_process_kill"

extern func rtProcessExitCode(op: NativePtr[Byte]): Int = "lyric_process_exit_code"

extern func rtProcessStdout(op: NativePtr[Byte]): String = "lyric_process_stdout"

extern func rtProcessStderr(op: NativePtr[Byte]): String = "lyric_process_stderr"

extern func rtProcessFree(op: NativePtr[Byte]): Unit = "lyric_process_free"

extern func rtMonoNanos(): Long = "lyric_monotonic_nanos"

/// The coroutine-context twin of `hostRunCaptureList`: `Std.Process.runCapture`
/// and `Std.Process.runCaptureWithInput` calls lowered inside an `async func`
/// body are redirected here by the native backend (D-N-023), so the capture
/// parks only the calling task instead of blocking the scheduler thread.  The
/// pump cadence is the 1 ms poll the JVM kernel twin documents for its drain
/// loop — each iteration suspends through the `Std.Time.sleepMillis` async
/// leaf.  `stdinContent` is copied into the op at start and pumped out through
/// the nonblocking stdin pipe alongside the output reads.  `timeoutMs` follows
/// the managed twin: on expiry the child is SIGKILLed, `timedOut` is true, and
/// the exit code reports -2; a negative `timeoutMs` means no timeout.
@unsafe_ffi
pub async func hostRunCaptureListAsync(
  executable: in String,
  args: in List[String],
  stdinContent: in String,
  timeoutMs: in Int,
): Result[ProcessCaptureResult, String] {
  val c = toC(executable)
  val op = rtProcessStart(c, args, stdinContent)
  freeC(c)
  if rtProcessSpawnFailed(op) != 0 {
    rtProcessFree(op)
    return Err(error = "failed to spawn process: " + executable)
  }
  val deadline: Long = rtMonoNanos() + timeoutMs.toLong() * 1000000i64
  var timedOut = false
  while rtProcessPump(op) == 0 {
    if timeoutMs >= 0 and rtMonoNanos() >= deadline {
      // A child that exited inside the last pump-to-deadline window is
      // NOT a timeout: the kill reaps its real status and reports 0.
      timedOut = rtProcessKill(op) != 0
    } else {
      sleepMillis(1)
    }
  }
  val code = if timedOut { 0 - 2 } else { rtProcessExitCode(op) }
  val outText = rtProcessStdout(op)
  val errText = rtProcessStderr(op)
  rtProcessFree(op)
  Ok(value = ProcessCaptureResult(stdout = outText, stderr = errText, exitCode = code, timedOut = timedOut))
}
