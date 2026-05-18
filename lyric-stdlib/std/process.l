// std/process.l - spawn child processes.
//
// Wraps the BCL Process API (declared in _kernel/process_host.l) with
// a Result-returning surface.  All failures surface as IOError so callers
// can handle spawn errors the same way as file-IO errors.
//
// Argument handling: individual arguments that contain spaces or
// double-quotes are wrapped in double-quotes with internal double-quotes
// escaped as \".  This matches the Windows CreateProcess / .NET runtime
// argument-splitting convention used on all platforms.

@runtime_checked
package Std.Process

import Std.Core
import Std.Collections
import Std.Errors
import Std.ProcessHost

// Build a single pre-formed argument string from a list.
// Each argument is quoted if it contains a space or double-quote.
func buildArgString(args: in List[String]): String {
  var result = ""
  var i = 0
  val count = args.count
  while i < count {
    val arg = args[i]
    if i > 0 { result = result + " " }
    if arg.contains(" ") or arg.contains("\"") {
      result = result + "\"" + arg.replace("\"", "\\\"") + "\""
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
@stable(since="1.0")
pub func run(executable: in String, args: in List[String]): Result[Int, IOError] {
  return try {
    val arguments = buildArgString(args)
    val proc = hostSpawn(executable, arguments)
    hostWait(proc)
    Ok(value = hostExitCode(proc))
  } catch Bug as b {
    Err(error = IoError(path = executable, message = b.message))
  }
}

/// Spawn a child process and return its exit code directly.
///
/// Panics with a `Bug` if the process cannot be started; use `run` for
/// recoverable error handling.
@stable(since="1.0")
pub func runChecked(executable: in String, args: in List[String]): Int {
  match run(executable, args) {
    case Ok(code) -> code
    case Err(e)   -> panic(IOError.message(e))
  }
}
