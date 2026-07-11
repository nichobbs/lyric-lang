//! std/_kernel/process_host.l - trusted host boundary for process execution.
//!
//! Exposes the minimal BCL surface needed to spawn child processes.
//! On .NET 5+, UseShellExecute defaults to false, so the child process
//! inherits the parent's stdio — required for all CLI sub-invocations.
//!
//! Internal: only Std.Process should import this.  All callers are
//! audited; the @axiom asserts the BCL contract.
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
pub func hostSpawn(fileName: in String, arguments: in String): ProcessHandle {
  ProcessHandle.Start(fileName, arguments)
}

/// Block the calling thread until `proc` exits.
pub func hostWait(proc: in ProcessHandle): Unit {
  proc.WaitForExit()
}

/// Return the OS exit code of `proc`.  Only valid after `hostWait`.
pub func hostExitCode(proc: in ProcessHandle): Int {
  proc.ExitCode
}

/// Release the OS handle held by `proc`.
/// Must be called after `hostWait` / `hostExitCode` to avoid handle leaks.
///
/// `Dispose()` is inherited from `System.ComponentModel.Component`; the MSIL
/// auto-FFI instance resolver walks the base-type Extends chain (#5562), so
/// the plain method-call form resolves to the inherited method.
pub func hostDisposeProc(proc: in ProcessHandle): Unit {
  proc.Dispose()
}
