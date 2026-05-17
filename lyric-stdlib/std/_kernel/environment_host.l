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

// Terminates the current process. The BCL method is void; Lyric callers
// see Never because Environment.Exit does not return in practice.
@externTarget("System.Environment.Exit")
pub func hostExit(code: in Int): Never = ()
