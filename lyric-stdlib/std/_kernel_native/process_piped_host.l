//! std/_kernel_native/process_piped_host.l — native-target twin of
//! `_kernel/process_piped_host.l`, selected by the native source loader
//! by basename.
//!
//! Long-lived piped child stdio is not implemented on `--target native`
//! yet (tracked in issue #6142; the real implementation extends
//! lyric-rt's `lyric_process.c` fork/execvp seam with a held-pipes
//! handle model).  This twin exists so `Std.Process` — whose
//! `PipedProcess` record embeds `PipedHandle` — keeps compiling and its
//! implemented native surface (`runCapture`, `run`) keeps working.
//! `hostSpawnPiped` fails fast with a message naming the tracked issue;
//! `Std.Process.spawnPiped` catches the panic and maps it to `IOError`,
//! so callers see a typed error, never a silent no-op.  The remaining
//! entry points are unreachable without a handle (only `hostSpawnPiped`
//! constructs one) but carry the same fail-fast message for safety.
package Std.ProcessPipedHost

import Std.Core

/// Opaque handle to a running child process with piped stdin/stdout.
/// Never constructed on the native target today (see module header).
pub record PipedHandle {
  pid: Int
}

pub func hostSpawnPiped(fileName: in String, arguments: in String): PipedHandle {
  panic("Std.ProcessPipedHost: piped spawn is not implemented on --target native (tracked in lyric-lang#6142)")
}

pub func hostPipedReadLineOpt(p: in PipedHandle): Option[String] {
  panic("Std.ProcessPipedHost: piped read is not implemented on --target native (tracked in lyric-lang#6142)")
}

pub func hostPipedWriteLine(p: in PipedHandle, line: in String): Unit {
  panic("Std.ProcessPipedHost: piped write is not implemented on --target native (tracked in lyric-lang#6142)")
}

pub func hostPipedIsAlive(p: in PipedHandle): Bool {
  panic("Std.ProcessPipedHost: piped isAlive is not implemented on --target native (tracked in lyric-lang#6142)")
}

pub func hostPipedKill(p: in PipedHandle): Unit {
  panic("Std.ProcessPipedHost: piped kill is not implemented on --target native (tracked in lyric-lang#6142)")
}

pub func hostPipedWaitExit(p: in PipedHandle, timeoutMs: in Int): Bool {
  panic("Std.ProcessPipedHost: piped waitExit is not implemented on --target native (tracked in lyric-lang#6142)")
}

pub func hostPipedExitCode(p: in PipedHandle): Int {
  panic("Std.ProcessPipedHost: piped exitCode is not implemented on --target native (tracked in lyric-lang#6142)")
}

pub func hostPipedCloseStdin(p: in PipedHandle): Unit {
  panic("Std.ProcessPipedHost: piped closeStdin is not implemented on --target native (tracked in lyric-lang#6142)")
}

pub func hostPipedClose(p: in PipedHandle): Unit {
  panic("Std.ProcessPipedHost: piped close is not implemented on --target native (tracked in lyric-lang#6142)")
}
