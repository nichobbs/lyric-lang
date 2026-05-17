// std/_kernel/process_host.l - trusted host boundary for process execution.
//
// Exposes the minimal BCL surface needed to spawn child processes.
// On .NET 5+, UseShellExecute defaults to false, so the child process
// inherits the parent's stdio — required for all CLI sub-invocations.
//
// Internal: only Std.Process should import this.  All callers are
// audited; the @axiom asserts the BCL contract.

@axiom("System.Diagnostics.Process conforms to its documented .NET contracts")
package Std.ProcessHost

import Std.Core

/// An opaque handle to a running child process.
extern type ProcessHandle = "System.Diagnostics.Process"

/// Spawn a child process.  `fileName` is the executable path or name;
/// `arguments` is a pre-formed argument string (space-separated tokens,
/// double-quoted for arguments containing spaces).
///
/// On .NET 5+, UseShellExecute defaults to false, so the child inherits
/// the current process's stdin, stdout, and stderr.
///
/// Panics (Bug) if the executable cannot be found or the OS rejects the spawn.
@externTarget("System.Diagnostics.Process.Start")
pub func hostSpawn(fileName: in String, arguments: in String): ProcessHandle = ()

/// Block the calling thread until `proc` exits.
@externTarget("System.Diagnostics.Process.WaitForExit")
pub func hostWait(proc: in ProcessHandle): Unit = ()

/// Return the OS exit code of `proc`.  Only valid after `hostWait`.
@externTarget("System.Diagnostics.Process.ExitCode")
pub func hostExitCode(proc: in ProcessHandle): Int = ()
