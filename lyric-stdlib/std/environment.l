//! std/environment.l - environment and process helpers.
//!
//! Reading process state is an effect, but missing environment variables
//! are ordinary data errors. Process exit is intentionally explicit and
//! does not hide behind app-host helpers.
@runtime_checked
package Std.Environment

import Std.Errors
import Std.EnvironmentHost

/// Read one environment variable.
///
/// # Preconditions as data
/// - `key` must be non-empty; empty keys return `Err(InvalidPath)`.
///
/// # Errors
/// - `InvalidPath`: key is empty.
/// - `KeyNotFound`: no environment variable exists for `key` (host
///   lookup failures also report as `KeyNotFound` — the kernel seam
///   folds them into the absent case).
@stable(since = "1.0")
pub func getVar(key: in String): Result[String, IOError] {
  if key.length == 0 {
    return Err(error = InvalidPath(path = key, reason = "environment key must not be empty"))
  }

  match hostGetVarOpt(key) {
    case Some(value) -> Ok(value = value)
    case None -> Err(error = KeyNotFound(key = key))
  }
}

/// Read an environment variable or return a caller-provided default.
///
/// Empty keys also return the default because this is a convenience
/// lookup, not a validation boundary.
@stable(since = "1.0")
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
@stable(since = "1.0")
pub func args(): slice[String] {
  return hostGetCommandLineArgs()
}

/// Terminate the current process with an exit code.
///
/// This function does not return. Prefer returning an Int from
/// `App.run` in application code; use `exitCode` only at hard process
/// boundaries.
@stable(since = "1.0")
pub func exitCode(code: in Int): Never {
  hostExit(code)
}

/// Directory containing the currently-executing assembly.
///
/// On .NET this is `System.AppContext.BaseDirectory`, which is the
/// directory containing the entry assembly.  Useful for resolving
/// resources packaged alongside the binary.
@stable(since = "0.1")
pub func appBaseDirectory(): String {
  hostAppBaseDirectory()
}

/// Current working directory of the process.  Equivalent to `pwd` on
/// POSIX.
@stable(since = "0.1")
pub func currentDirectory(): String {
  hostCurrentDirectory()
}

/// Directory of the active .NET runtime shared framework
/// (e.g. `/usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.x/`).
/// Used by the self-hosted compiler to discover reference assemblies on
/// installations where `DOTNET_ROOT` is unset.  May return an empty string
/// in native-AOT scenarios.
@stable(since = "1.0")
pub func runtimeDirectory(): String {
  hostRuntimeDirectory()
}

/// The .NET runtime identifier of the running process — e.g. `"linux-x64"`,
/// `"win-x64"`, `"osx-arm64"`.
///
/// On .NET, delegates to
/// `System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier` and is
/// always non-empty.  On JVM (where the .NET RID has no equivalent) this
/// returns an empty string; callers should treat empty as "unknown" and fall
/// back to a host-independent choice.
@stable(since = "1.0")
pub func runtimeIdentifier(): String {
  hostRuntimeIdentifier()
}

/// Set (or replace) a process-level environment variable.
///
/// The new value is visible to subsequent `getVar` / `getVarOrDefault` calls
/// in the same process and is inherited by any child processes spawned after
/// this call.
///
/// On .NET, delegates to `System.Environment.SetEnvironmentVariable`.
/// On JVM this is a no-op (the JVM exposes no portable `setenv` equivalent
/// without unsafe reflection); the Lyric CLI — the primary caller of this
/// function — always runs on .NET, so the JVM no-op is never exercised in
/// practice.
@stable(since = "1.0")
pub func setVar(key: in String, value: in String): Unit {
  hostSetEnvironmentVariable(key, value)
}
