// std/_kernel_jvm/process_host.l — JVM host boundary for child-process execution.
//
// Mirrors _kernel/process_host.l for the JVM target.  Routes through a
// lyric.stdlib.jvm.ProcessHost shim class that wraps java.lang.ProcessBuilder
// and java.lang.Process.
//
// Provides the same Std.ProcessHost package surface as _kernel/process_host.l
// so that Std.Process can import Std.ProcessHost on both targets without change.
//
// The shim stores the spawned Process handle as an opaque object behind
// ProcessHandle, which is exposed as an opaque type here.
//
// Internal: only Std.Process should import this.

@axiom("lyric.stdlib.jvm.ProcessHost operations conform to their documented JVM contracts")
package Std.ProcessHost

import Std.Core

extern package lyric.stdlib.jvm.ProcessHost {
  // An opaque handle to a running child process.
  // Backed by java.lang.Process stored in the shim's handle table.
  pub exposed type ProcessHandle

  // Spawn a child process.  `fileName` is the executable path or name;
  // `arguments` is a space-separated argument string.
  // Backed by ProcessBuilder(fileName, args...).start().
  // Panics (Bug) if the executable cannot be found or the OS rejects the spawn.
  pub func spawn(fileName: in String, arguments: in String): ProcessHandle

  // Block the calling thread until the process exits.
  // Backed by Process.waitFor().
  pub func waitFor(proc: in ProcessHandle): Unit

  // Return the OS exit code after the process has exited.
  // Only valid after waitFor.  Backed by Process.exitValue().
  pub func exitCode(proc: in ProcessHandle): Int
}

// Re-export with the names Std.Process expects (matching _kernel/process_host.l).
pub opaque type ProcessHandle = lyric.stdlib.jvm.ProcessHost.ProcessHandle

pub func hostSpawn(fileName: in String, arguments: in String): ProcessHandle =
  lyric.stdlib.jvm.ProcessHost.spawn(fileName, arguments)

pub func hostWait(proc: in ProcessHandle): Unit =
  lyric.stdlib.jvm.ProcessHost.waitFor(proc)

pub func hostExitCode(proc: in ProcessHandle): Int =
  lyric.stdlib.jvm.ProcessHost.exitCode(proc)
