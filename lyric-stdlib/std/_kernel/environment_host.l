//! std/_kernel/environment_host.l - trusted host boundary for process state.
//!
//! Environment variables, command-line arguments, and process exit are
//! host-global effects. Public wrappers in Std.Environment keep the
//! recoverable parts Result-based and make process termination explicit.
@axiom("System.Environment operations conform to their documented .NET contracts")
package Std.EnvironmentHost

import Std.Core

@externTarget("System.Environment.GetEnvironmentVariable")
pub func hostGetEnvironmentVariable(key: in String): String? = ()

@externTarget("System.Environment.GetCommandLineArgs")
pub func hostGetCommandLineArgs(): slice[String] = ()

// Base directory of the host process — `System.AppContext.BaseDirectory`
// resolves to the entry-point assembly's directory, not the currently-
// executing assembly's directory (the two differ when a DLL is loaded
// from a different path than the apphost stub).  Native callers (the
// self-hosted MSIL bridge) walk up from here to find the
// `lyric-stdlib/std/` source tree at runtime — same convention the F#
// bootstrap `Lyric.Cli.SelfHostedBridge.findStdlibSources` uses.
@externTarget("System.AppContext.get_BaseDirectory")
pub func hostAppBaseDirectory(): String = ()

// Current working directory of the process.  Used by the self-hosted
// compiler bridges as a fallback when `hostAppBaseDirectory()` doesn't
// resolve to a location with the stdlib in a known relative position
// (e.g. when running a compiled DLL from a temp directory under a
// development tree).
@externTarget("System.IO.Directory.GetCurrentDirectory")
pub func hostCurrentDirectory(): String = ()

// Directory of the active .NET runtime shared framework, e.g.
// `/usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.x/`.  Used by
// the self-hosted metadata reader to discover the reference-pack root on
// installations where DOTNET_ROOT is unset and the root is not in the
// standard `/usr/share/dotnet` or `~/.dotnet` paths (e.g. Homebrew macOS).
// May return an empty string in native-AOT scenarios.
@axiom("System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory conforms to its documented .NET contract")
@externTarget("System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory")
pub func hostRuntimeDirectory(): String = ()

// The .NET runtime identifier of the running process (`"linux-x64"`,
// `"win-x64"`, `"osx-arm64"`, …).  Wraps the static property
// `System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier`.
// Always non-empty on .NET.
@axiom("System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier conforms to its documented .NET contract")
@externTarget("System.Runtime.InteropServices.RuntimeInformation.get_RuntimeIdentifier")
pub func hostRuntimeIdentifier(): String = ()

// Set (or unset) a process-level environment variable.  Wraps
// `System.Environment.SetEnvironmentVariable(string, string)`.  The new
// value is visible to `GetEnvironmentVariable` in the same process and
// is inherited by any child processes spawned afterwards.
@externTarget("System.Environment.SetEnvironmentVariable")
pub func hostSetEnvironmentVariable(key: in String, value: in String): Unit = ()

// Terminates the current process. The BCL method is void; Lyric callers
// see Never because Environment.Exit does not return in practice.
@externTarget("System.Environment.Exit")
pub func hostExit(code: in Int): Never = ()

// =====================================================================
// Option seam — the exception-free surface both kernel twins implement
// (issue #4752): absent and error both surface as None here; the pure
// `Std.Environment` layer maps None to its Result error.
// =====================================================================
// The BCL returns null for an unset variable.  Lyric has no null
// pattern (`case null` parses as a catch-all binding under the
// self-hosted parser — issue #4775 — and the D107 Option-returning
// extern form cannot be compiled by the pinned F# mint seed), so
// unset is detected via `??` with a NUL-string marker: POSIX and
// Windows environment blocks are NUL-delimited, so no real value can
// ever equal "\0".
pub func hostGetVarOpt(key: in String): Option[String] {
  try {
    val v = hostGetEnvironmentVariable(key) ?? "\u{0000}"
    if v == "\u{0000}" {
      None
    } else {
      Some(value = v)
    }
  } catch Bug as _ {
    None
  }
}
