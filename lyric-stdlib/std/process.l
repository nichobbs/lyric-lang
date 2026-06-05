//! std/process.l - spawn child processes.
//!
//! Wraps the BCL Process API (declared in _kernel/process_host.l) with
//! a Result-returning surface.  All failures surface as IOError so callers
//! can handle spawn errors the same way as file-IO errors.
//!
//! Argument handling: arguments that contain spaces, double-quotes, or
//! backslashes are wrapped in double-quotes.  Backslashes are doubled first
//! so that trailing backslashes before the closing quote do not escape it
//! (Windows CRT CommandLineToArgvW convention; safe on all platforms).
@runtime_checked
package Std.Process

import Std.Core
import Std.Collections
import Std.Errors
import Std.ProcessHost
import Std.ProcessCaptureHost

// Build an argument string for inherited-stdio spawning.
// Arguments that require quoting (contain spaces, quotes, or backslashes)
// are wrapped in double-quotes with backslash-escaping.
func buildArgString(args: in List[String]): String {
  var result = ""
  var i = 0
  val count = args.count
  while i < count {
    val arg = args[i]
    if i > 0 {
      result = result + " "
    }
    if arg.contains(" ") or arg.contains("\"") or arg.contains("\\") {
      result = result + "\"" + arg.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
    } else {
      result = result + arg
    }
    i += 1
  }
  result
}

// Build a safe argument string for piped-capture spawning.
// Every argument is always wrapped in double-quotes with full backslash
// escaping (matching Std.ProcessCapture.buildArgString) so the receiving
// process tokenises identically on POSIX and Windows.
func buildCaptureArgString(args: in List[String]): String {
  var result = ""
  var i = 0
  val count = args.count
  while i < count {
    if i > 0 {
      result = result + " "
    }
    val escaped = args[i].replace("\\", "\\\\").replace("\"", "\\\"")
    result = result + "\"" + escaped + "\""
    i += 1
  }
  result
}

/// Spawn a child process, inheriting the current process's stdio.
///
/// Returns `Ok(exitCode)` when the process exits normally.
/// Returns `Err(IoError)` if the executable cannot be started.
///
/// # Notes
/// - The child inherits stdin, stdout, and stderr.
/// - `executable` may be a bare name (resolved via `$PATH`) or a full path.
@stable(since = "1.0")
pub func run(executable: in String, args: in List[String]): Result[Int, IOError] {
  return try {
    val arguments = buildArgString(args)
    val proc = hostSpawn(executable, arguments)
    hostWait(proc)
    val code = hostExitCode(proc)
    hostDisposeProc(proc)
    Ok(value = code)
  } catch Bug as b {
    Err(error = IoError(path = executable, message = b.message))
  }
}

/// Spawn a child process and return its exit code directly.
///
/// Panics with a `Bug` if the process cannot be started; use `run` for
/// recoverable error handling.
@stable(since = "1.0")
pub func runChecked(executable: in String, args: in List[String]): Int {
  match run(executable, args) {
    case Ok(code) -> code
    case Err(e) -> panic(IOError.message(e))
  }
}

// ── Captured-output subprocess API ────────────────────────────────────────────
/// Result of a piped-capture subprocess invocation.
///
/// `stdout` and `stderr` are the complete captured text.  `exitCode` is the
/// process exit code (-1 on spawn failure; -2 when killed after timeout).
/// `timedOut` is true when `timeoutMs` elapsed before the process exited.
@stable(since = "1.0")
pub record ProcessResult {
  stdout: String
  stderr: String
  exitCode: Int
  timedOut: Bool
  // Project a raw `ProcessCaptureResult` opaque handle into the public
  // `ProcessResult` record.
}

func projectResult(raw: in ProcessCaptureResult): ProcessResult = ProcessResult(stdout = pcResultStdout(raw), stderr = pcResultStderr(raw), exitCode = pcResultExitCode(raw), timedOut = pcResultTimedOut(raw))

/// Spawn `executable` with `args`, capture its stdout and stderr, and return
/// a `ProcessResult` when the process exits (or is killed after `timeoutMs`).
///
/// Stdout and stderr are drained in parallel to avoid pipe-buffer deadlock.
/// Returns `Err` if the executable cannot be started.
@stable(since = "1.0")
pub func runCapture(executable: in String, args: in List[String], timeoutMs: in Int): Result[ProcessResult, String] {
  return try {
    val argStr = buildCaptureArgString(args)
    val raw = hostRunCaptureTimeout(executable, argStr, "", timeoutMs)
    Ok(value = projectResult(raw))
  } catch Bug as b {
    Err(error = b.message)
  }
}

/// Spawn `executable` with `args`, write `stdin` to the child's standard
/// input, capture stdout and stderr, and return a `ProcessResult`.
///
/// Returns `Err` if the executable cannot be started.
@stable(since = "1.0")
pub func runCaptureWithInput(
  executable: in String, args: in List[String], stdin: in String, timeoutMs: in Int
): Result[ProcessResult, String] {
  return try {
    val argStr = buildCaptureArgString(args)
    val raw = hostRunCaptureTimeout(executable, argStr, stdin, timeoutMs)
    Ok(value = projectResult(raw))
  } catch Bug as b {
    Err(error = b.message)
  }
}
