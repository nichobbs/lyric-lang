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
import Std.ProcessPipedHost

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
}

// Project a raw `ProcessCaptureResult` kernel record into the public
// `ProcessResult` record.
func projectResult(raw: in ProcessCaptureResult): ProcessResult = ProcessResult(stdout = pcResultStdout(raw), stderr = pcResultStderr(raw), exitCode = pcResultExitCode(raw), timedOut = pcResultTimedOut(raw))

/// Spawn `executable` with `args`, capture its stdout and stderr, and return
/// a `ProcessResult` when the process exits (or is killed after `timeoutMs`).
///
/// Stdout and stderr are drained in parallel to avoid pipe-buffer deadlock.
/// Returns `Err` if the executable cannot be started.
/// Native-backend coupling (D-N-023): calls to this function lowered
/// inside an `async func` body on `--target native` are redirected to
/// `Std.ProcessCaptureHost.hostRunCaptureListAsync` by arity-keyed
/// lookups in `lyric-compiler/lyric/llvm_codegen.l` (the intercept) and
/// `llvm_bridge.l` (the reachability walk).  Changing this signature's
/// arity silently disables that redirect — update both sites together.
@stable(since = "1.0")
pub func runCapture(executable: in String, args: in List[String], timeoutMs: in Int): Result[ProcessResult, String] {
  match hostRunCaptureList(executable, args, "", timeoutMs) {
    case Ok(raw) -> Ok(value = projectResult(raw))
    case Err(e) -> Err(error = e)
  }
}

/// Spawn `executable` with `args`, write `stdin` to the child's standard
/// input, capture stdout and stderr, and return a `ProcessResult`.
///
/// Returns `Err` if the executable cannot be started.
/// Native-backend coupling (D-N-023): like `runCapture` above, calls to
/// this function lowered inside an `async func` body on `--target native`
/// are redirected to `Std.ProcessCaptureHost.hostRunCaptureListAsync` by
/// arity-keyed lookups in `lyric-compiler/lyric/llvm_codegen.l` and
/// `llvm_bridge.l` — changing this signature's arity silently disables
/// that redirect; update both sites together.
@stable(since = "1.0")
pub func runCaptureWithInput(
  executable: in String, args: in List[String], stdin: in String, timeoutMs: in Int
): Result[ProcessResult, String] {
  match hostRunCaptureList(executable, args, stdin, timeoutMs) {
    case Ok(raw) -> Ok(value = projectResult(raw))
    case Err(e) -> Err(error = e)
  }
}

// ── Piped (long-lived bidirectional stdio) subprocess API ────────────────────
/// A running child process with piped stdin/stdout, for interactive or
/// streaming protocols (e.g. an MCP server's stdio transport) rather than a
/// single batch write-then-capture round trip. Stderr is inherited from
/// this process — see `_kernel/process_piped_host.l`'s module doc.
@stable(since = "1.0")
pub record PipedProcess {
  handle: PipedHandle
}

/// Spawn `executable` with `args`, redirecting stdin and stdout for
/// line-oriented bidirectional communication (e.g. NDJSON framing).
///
/// Returns `Err(IOError)` if the executable cannot be started.
@stable(since = "1.0")
pub func spawnPiped(executable: in String, args: in List[String]): Result[PipedProcess, IOError] {
  return try {
    val arguments = buildArgString(args)
    Ok(value = PipedProcess(handle = hostSpawnPiped(executable, arguments)))
  } catch Bug as b {
    Err(error = IoError(path = executable, message = b.message))
  }
}

/// Read one line from the child's stdout, excluding the trailing newline.
/// `Ok(None)` marks clean EOF (typically because the child exited or closed
/// its stdout).
@stable(since = "1.0")
pub func pipedReadLine(p: in PipedProcess): Result[Option[String], String] {
  return try {
    Ok(value = hostPipedReadLineOpt(p.handle))
  } catch Bug as b {
    Err(error = b.message)
  }
}

/// Write one line to the child's stdin. A trailing newline is appended and
/// the write is flushed immediately.
@stable(since = "1.0")
pub func pipedWriteLine(p: in PipedProcess, line: in String): Result[Unit, String] {
  return try {
    hostPipedWriteLine(p.handle, line)
    Ok(value = ())
  } catch Bug as b {
    Err(error = b.message)
  }
}

/// True while the child process has not yet exited.
@stable(since = "1.0")
pub func pipedIsAlive(p: in PipedProcess): Bool {
  hostPipedIsAlive(p.handle)
}

/// Forcibly terminate the child process (and, where supported, its process
/// tree). Safe to call on an already-exited process.
@stable(since = "1.0")
pub func pipedKill(p: in PipedProcess): Unit {
  hostPipedKill(p.handle)
}

/// Close only the child's stdin (signals EOF without affecting its
/// stdout) — for a batch-style child that reads until EOF, then writes its
/// complete output and exits, while `pipedReadLine` keeps working
/// afterward. Use `pipedClose` to release everything once done.
@stable(since = "1.0")
pub func pipedCloseStdin(p: in PipedProcess): Unit {
  hostPipedCloseStdin(p.handle)
}

/// Block up to `timeoutMs` milliseconds for the child to exit. Returns
/// `true` if it exited within the deadline.
@stable(since = "1.0")
pub func pipedWaitExit(p: in PipedProcess, timeoutMs: in Int): Bool {
  hostPipedWaitExit(p.handle, timeoutMs)
}

/// The child's OS exit code. Only meaningful once the child has exited
/// (`pipedIsAlive` is `false`, or `pipedWaitExit` returned `true`).
@stable(since = "1.0")
pub func pipedExitCode(p: in PipedProcess): Int {
  hostPipedExitCode(p.handle)
}

/// Close the child's stdin/stdout pipes and release the OS process handle.
/// Does not itself wait for or kill the child — call `pipedKill` first if
/// termination is required.
@stable(since = "1.0")
pub func pipedClose(p: in PipedProcess): Unit {
  hostPipedClose(p.handle)
}
