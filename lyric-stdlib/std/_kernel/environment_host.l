// std/_kernel/environment_host.l - trusted host boundary for process state.
//
// Environment variables, command-line arguments, and process exit are
// host-global effects. Public wrappers in Std.Environment keep the
// recoverable parts Result-based and make process termination explicit.

@axiom("System.Environment operations conform to their documented .NET contracts")
package Std.EnvironmentHost

@externTarget("System.Environment.GetEnvironmentVariable")
pub func hostGetEnvironmentVariable(key: in String): String? = ()

@externTarget("System.Environment.GetCommandLineArgs")
pub func hostGetCommandLineArgs(): slice[String] = ()

// Directory containing the currently-executing assembly.  Native callers
// (the self-hosted MSIL bridge) walk up from here to find the
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

// Terminates the current process. The BCL method is void; Lyric callers
// see Never because Environment.Exit does not return in practice.
@externTarget("System.Environment.Exit")
pub func hostExit(code: in Int): Never = ()
