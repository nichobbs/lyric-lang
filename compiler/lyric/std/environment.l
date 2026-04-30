// std/environment.l - environment and process helpers.
//
// Reading process state is an effect, but missing environment variables
// are ordinary data errors. Process exit is intentionally explicit and
// does not hide behind app-host helpers.

@runtime_checked
package Std.Environment

import Std.Errors { IOError }
import Std.EnvironmentHost as HostEnvironment

/// Read one environment variable.
///
/// # Preconditions as data
/// - `key` must be non-empty; empty keys return `Err(InvalidPath)`.
///
/// # Errors
/// - `InvalidPath`: key is empty.
/// - `KeyNotFound`: no environment variable exists for `key`.
/// - `IoError`: host lookup failed.
pub func getVar(key: in String): Result[String, IOError] {
  if key.length == 0 {
    return Err(error = InvalidPath(path = key, reason = "environment key must not be empty"))
  }

  return try {
    match HostEnvironment.getEnvironmentVariable(key) {
      case null -> Err(error = KeyNotFound(key = key))
      case value -> Ok(value = value)
    }
  } catch Bug as b {
    Err(error = IoError(path = key, message = b.message))
  }
}

/// Read an environment variable or return a caller-provided default.
///
/// Empty keys also return the default because this is a convenience
/// lookup, not a validation boundary.
pub func getVarOrDefault(key: in String, default: in String): String {
  match getVar(key) {
    case Ok(value) -> value
    case Err(e) -> default
  }
}

/// Return command-line arguments for the current process.
///
/// The returned slice uses the host convention, including whether argv0
/// appears as the first entry.
pub func args(): slice[String] {
  return HostEnvironment.getCommandLineArgs()
}

/// Terminate the current process with an exit code.
///
/// This function does not return. Prefer returning an Int from
/// `App.run` in application code; use `exitCode` only at hard process
/// boundaries.
pub func exitCode(code: in Int): Never {
  HostEnvironment.exit(code)
}
