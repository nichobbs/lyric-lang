//! std/_kernel_jvm/process_host.l — JVM host boundary for child-process execution.
//!
//! Mirrors _kernel/process_host.l for the JVM target.  Pure Lyric over JVM
//! auto-FFI against java.lang.Process / java.lang.ProcessBuilder, replacing a
//! lyric.stdlib.jvm.ProcessHost shim class that never existed at runtime (the
//! `extern package` mechanism it used is a no-op in both the type checker
//! and both codegens -- same elimination as the console_host.l / time_host.l
//! / collections_host.l / file_host.l rewrites).
//!
//! `arguments` arrives pre-formatted by Std.Process.buildArgString (a
//! space-separated sequence of double-quoted, backslash-escaped tokens);
//! `Std.ProcessCaptureHost.parseArgString` (the exact reverse of that same
//! format, already implemented and tested for the process-capture kernel)
//! is reused here rather than re-implementing argument-string parsing.
//!
//! Provides the same Std.ProcessHost package surface as _kernel/process_host.l
//! so that Std.Process can import Std.ProcessHost on both targets without change.
//!
//! Internal: only Std.Process should import this.
@axiom("java.lang.Process and java.lang.ProcessBuilder conform to their documented JVM contracts")
package Std.ProcessHost

import Std.Core
import Std.Collections
import Std.ProcessCaptureHost
import Std.Errors
import Std.ProcessArgs

// An opaque handle to a running child process.
extern type ProcessHandle = "java.lang.Process"

extern type JProcessBuilder = "java.lang.ProcessBuilder"

// Spawn a child process.  `fileName` is the executable path or name;
// `arguments` is a space-separated, `Std.Process.buildArgString`-formatted
// argument string.  Backed by `new ProcessBuilder(command).inheritIO().start()`.
// `inheritIO()` is required, not cosmetic: without it `ProcessBuilder`
// defaults every stream to `Redirect.PIPE`, silently breaking this kernel's
// documented "child inherits the parent's stdio" contract (matching
// `_kernel/process_host.l`'s .NET `UseShellExecute = false` behavior) and
// risking a real deadlock in `hostWait` if a child writes enough
// stdout/stderr to fill the unread pipe buffer before exiting.
// Panics (Bug) if the executable cannot be found or the OS rejects the spawn.
pub func hostSpawn(fileName: in String, arguments: in String): ProcessHandle {
  val cmd = parseArgString(fileName, arguments)
  JProcessBuilder.new(cmd).inheritIO().start()
}

// Block the calling thread until the process exits.  Backed by
// `Process.waitFor()`.  The real method returns the exit code, which
// `hostExitCode` re-reads via `exitValue()` per the existing two-call
// contract this mirrors from `_kernel/process_host.l`; the value returned
// here is discarded by the tail-position Int-to-Unit coercion.
//
// Written as a single tail expression, NOT `proc.waitFor(); ()`: a discarded
// (non-tail) auto-FFI instance call whose receiver traces back to a
// parameter emits no invoke instruction at all on this backend (confirmed
// with a minimal `StringBuilder` repro independent of this kernel — a
// general JVM codegen gap, tracked as issue #5379). The tail-position form
// is unaffected and is what every other kernel written after this bug was
// found should also prefer for the same reason.
pub func hostWait(proc: in ProcessHandle): Unit {
  proc.waitFor()
}

// Return the OS exit code after the process has exited.  Only valid after
// `hostWait`.  Backed by `Process.exitValue()`.
pub func hostExitCode(proc: in ProcessHandle): Int {
  proc.exitValue()
}

// `System.Diagnostics.Process.Dispose()`'s JVM analogue: unlike a .NET
// `Process`, a JVM `java.lang.Process` holds no OS handle requiring
// explicit release once `waitFor`/`exitValue` have already run (the child's
// stdio is inherited from the parent per this kernel's contract, so there
// are no dangling pipe streams to close either) — a genuine no-op, not a
// stub standing in for unimplemented behavior.
pub func hostDisposeProc(proc: in ProcessHandle): Unit {
  ()
}

// Run `executable` with `args` on inherited stdio and wait for it: the
// Result seam `Std.Process.run` delegates to.  The host throws when the
// executable cannot be started; the try/catch lives here, in the kernel,
// because `--target native` has no unwinding (D-N-003) and its twin
// reports the same failure as a return code instead.
pub func hostRunInheritedResult(executable: in String, args: in List[String]): Result[Int, IOError] {
  try {
    val proc = hostSpawn(executable, argvJoin(args))
    hostWait(proc)
    val code = hostExitCode(proc)
    hostDisposeProc(proc)
    Ok(value = code)
  } catch Bug as b {
    Err(error = IoError(path = executable, message = b.message))
  }
}
