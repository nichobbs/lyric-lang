//! std/_kernel_native/process_piped_host.l — native-target twin of
//! `_kernel/process_piped_host.l`, selected by the native source loader
//! by basename (issue #6142).
//!
//! Implements long-lived piped child stdio over `lyric-rt`'s
//! `lyric_process_piped_*` seam (`lyric_process.c`): `fork`+`execvp`
//! wiring only the child's stdin and stdout to fresh pipes, exactly
//! like the dotnet (`RedirectStandardInput`/`RedirectStandardOutput`
//! only) and JVM (`Redirect.INHERIT` on stderr) twins — stderr is left
//! inherited from this process, so a spawned server's diagnostic/log
//! output goes straight to this process's own stderr instead of
//! risking a deadlock on a full, never-drained capture pipe.
//!
//! ## Representation: the handle is a `Long`, not a `NativePtr[Byte]`
//!
//! `PipedHandle` must survive across MULTIPLE separate top-level calls
//! (`hostSpawnPiped` constructs it; `hostPipedReadLineOpt`/
//! `hostPipedWriteLine`/etc. use it later) — the mode checker's N0100
//! boundary documents storing `NativePtr[T]` in a record/union field as
//! rejected unconditionally (heap storage outlives any frame), so the
//! raw `lyric_process_piped_*` handle (a `void*` in C) is declared
//! `Long` at both its extern-func return and parameter positions —
//! `_kernel_native/tcp_host.l`'s identical `Conn.tlsConnHandle` idiom,
//! not a new pattern.
//!
//! ## Argument handling
//!
//! `Std.Process.spawnPiped` passes its argument list straight to
//! `hostSpawnPipedResult`, which hands it to `rtPipedSpawn` as argv (no
//! shell, no quoting). `hostSpawnPiped`'s string form, shared with the
//! managed twins, splits a `Std.ProcessArgs`-joined string back into a
//! list with `argvSplit`.
//!
//! ## Line and byte reads share one buffer
//!
//! lyric-rt keeps the stdout bytes a line read has not returned yet in the
//! handle (`linebuf`), and `lyric_process_piped_read_bytes_within` hands
//! those back before reading the pipe again, so `Std.Process`'s line and
//! byte reads can be mixed on one child without losing or reordering a byte.
//!
//! ## `Std.Process` reaches this kernel through Result seams
//!
//! `Std.Process.spawnPiped`/`pipedReadLine`/`pipedWriteLine` call the
//! `host*Result` seams at the end of this file rather than wrapping the
//! throwing entry points in `try`/`catch`, which `--target native` cannot
//! lower (D-N-003; issue #6887). The managed twins hold the `try`/`catch`
//! in their own copies of the seams.
@axiom("fork/execvp piped child stdio via lyric-rt conforms to its documented contract")
@io
package Std.ProcessPipedHost

import Std.Core
import Std.Collections
import Std.ProcessArgs
import Std.Errors
import Std.ProcessHost

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

// ── Argument-string parser: the shared Std.ProcessArgs decoder (#7234) ──────
func parseArgString(argStr: in String): List[String] {
  argvSplit(argStr)
}

// ── Extern seam bindings (lyric-rt/src/lyric_process.c) ────────────────────
// `args` is a Std.Collections `List[String]`, the `LyricList*` the C side
// reads (borrowed for the call).
// A bare `NativePtr[T]` record field is rejected by the N0100 mode checker, so
// long-lived handles are stored as `Long`; the externs below take the pointer
// the C side declares (32-bit on wasm32), converted at the call boundary.
extern func rtPtrToLong(p: NativePtr[Byte]): Long = "lyric_ptr_to_long"

extern func rtLongToPtr(v: Long): NativePtr[Byte] = "lyric_long_to_ptr"

extern func rtPipedSpawnRaw(path: NativePtr[Byte], args: List[String]): NativePtr[Byte] = "lyric_process_piped_spawn"

func rtPipedSpawn(path: NativePtr[Byte], args: List[String]): Long {
  rtPtrToLong(rtPipedSpawnRaw(path, args))
}

extern func rtPipedReadLineRaw(p: NativePtr[Byte], outLine: NativePtr[String]): Int = "lyric_process_piped_read_line"

func rtPipedReadLine(p: Long, outLine: NativePtr[String]): Int {
  rtPipedReadLineRaw(rtLongToPtr(p), outLine)
}

extern func rtPipedReadLineWithinRaw(p: NativePtr[Byte], outLine: NativePtr[String], timeoutMs: Int): Int = "lyric_process_piped_read_line_within"

func rtPipedReadLineWithin(p: Long, outLine: NativePtr[String], timeoutMs: Int): Int {
  rtPipedReadLineWithinRaw(rtLongToPtr(p), outLine, timeoutMs)
}

extern func rtPipedWriteLineRaw(p: NativePtr[Byte], line: String): Int = "lyric_process_piped_write_line"

func rtPipedWriteLine(p: Long, line: String): Int {
  rtPipedWriteLineRaw(rtLongToPtr(p), line)
}

// Byte reads: the status out-param is 1 for bytes, 0 for end of stream, 2
// for a timeout; the list is empty unless it is 1.
extern func rtPipedReadBytesWithinRaw(p: NativePtr[Byte], timeoutMs: Int, status: NativePtr[Int]): slice[Byte] = "lyric_process_piped_read_bytes_within"

func rtPipedReadBytesWithin(p: Long, timeoutMs: Int, status: NativePtr[Int]): slice[Byte] {
  rtPipedReadBytesWithinRaw(rtLongToPtr(p), timeoutMs, status)
}

extern func rtPipedWriteBytesRaw(p: NativePtr[Byte], bytes: slice[Byte]): Int = "lyric_process_piped_write_bytes"

func rtPipedWriteBytes(p: Long, bytes: slice[Byte]): Int {
  rtPipedWriteBytesRaw(rtLongToPtr(p), bytes)
}

extern func rtPipedIsAliveRaw(p: NativePtr[Byte]): Int = "lyric_process_piped_is_alive"

func rtPipedIsAlive(p: Long): Int {
  rtPipedIsAliveRaw(rtLongToPtr(p))
}

extern func rtPipedKillRaw(p: NativePtr[Byte]): Int = "lyric_process_piped_kill"

func rtPipedKill(p: Long): Int {
  rtPipedKillRaw(rtLongToPtr(p))
}

extern func rtPipedWaitExitRaw(p: NativePtr[Byte], timeoutMs: Int): Int = "lyric_process_piped_wait_exit"

func rtPipedWaitExit(p: Long, timeoutMs: Int): Int {
  rtPipedWaitExitRaw(rtLongToPtr(p), timeoutMs)
}

extern func rtPipedExitCodeRaw(p: NativePtr[Byte]): Int = "lyric_process_piped_exit_code"

func rtPipedExitCode(p: Long): Int {
  rtPipedExitCodeRaw(rtLongToPtr(p))
}

extern func rtPipedCloseStdinRaw(p: NativePtr[Byte]): Int = "lyric_process_piped_close_stdin"

func rtPipedCloseStdin(p: Long): Int {
  rtPipedCloseStdinRaw(rtLongToPtr(p))
}

extern func rtPipedCloseRaw(p: NativePtr[Byte]): Unit = "lyric_process_piped_close"

func rtPipedClose(p: Long): Unit {
  rtPipedCloseRaw(rtLongToPtr(p))
}

// ── Public handle + entry points ────────────────────────────────────────────
/// Opaque handle to a running child process with piped stdin/stdout. See
/// the module header for why this is a `Long`, not a `NativePtr[Byte]`.
/// `closed` guards `hostPipedClose` against a second call on the same
/// handle (issue #6975) the same way `Std.HttpServer`'s
/// `HttpListener.stopped` guards `stopListener` — package-private so no
/// consumer outside this file can read or mutate it directly.
pub ref record PipedHandle {
  raw: Long
  var closed: Bool
}

/// Spawn `fileName` with a pre-formed `arguments` string (see
/// `Std.Process.buildArgString`), redirecting stdin and stdout; stderr is
/// inherited (see module header). Panics if the child cannot be started,
/// including an `execvp` failure such as `fileName` not found (lyric-rt
/// reports it over a CLOEXEC pipe). `Std.Process.spawnPiped` uses
/// `hostSpawnPipedResult` instead, which reports the same failure as an
/// `IoError`.
@unsafe_ffi
pub func hostSpawnPiped(fileName: in String, arguments: in String): PipedHandle {
  val args = parseArgString(arguments)
  val c = toC(fileName)
  val raw = rtPipedSpawn(c, args)
  freeC(c)
  if raw == 0i64 {
    panic("Std.ProcessPipedHost: failed to spawn piped process: " + fileName)
  } else {
    PipedHandle(raw = raw, closed = false)
  }
}

// Option seam avoiding `case null`'s catch-all miscompile (#4775) — the
// same NUL-marker convention `_kernel_native/environment_host.l`'s
// hostGetVarOpt uses, over the int32 ok-flag out-param protocol
// `rtSockReadBytes`/`rtEnvGetOk` already establish for this target.
@unsafe_ffi
pub func hostPipedReadLineOpt(p: in PipedHandle): Option[String] {
  var line: String = ""
  val rc = rtPipedReadLine(p.raw, nativeAddrOf(line))
  if rc == 1 {
    Some(value = line)
  } else {
    None
  }
}

/// Outcome of a bounded line read (`hostPipedReadLineWithinResult`).
pub union HostPipedRead {
  case HostPipedLine(line: String)
  case HostPipedEof
  case HostPipedTimedOut
}

/// Outcome of a byte read (`hostPipedReadBytesResult`,
/// `hostPipedReadBytesWithinResult`): at least one byte, end of stream, or
/// (bounded reads only) nothing within the timeout.
pub union HostPipedBytes {
  case HostPipedChunk(bytes: slice[Byte])
  case HostPipedBytesEof
  case HostPipedBytesTimedOut
}

// lyric-rt's byte read (a negative `timeoutMs` waits without a bound). It
// takes the bytes a line read left in the handle's buffer first, so line and
// byte reads share one buffer.
@unsafe_ffi
func pipedReadBytesWithin(p: in PipedHandle, timeoutMs: in Int): HostPipedBytes {
  var status: Int = 0
  val bytes = rtPipedReadBytesWithin(p.raw, timeoutMs, nativeAddrOf(status))
  if status == 1 {
    HostPipedChunk(bytes = bytes)
  } else if status == 2 {
    HostPipedBytesTimedOut
  } else {
    HostPipedBytesEof
  }
}

// lyric-rt's bounded read: 1 line, 0 end of stream, 2 timed out (a partial
// line stays buffered in the handle for the next read, #7451).
@unsafe_ffi
func pipedReadLineWithin(p: in PipedHandle, timeoutMs: in Int): HostPipedRead {
  var line: String = ""
  val rc = rtPipedReadLineWithin(p.raw, nativeAddrOf(line), timeoutMs)
  if rc == 1 {
    HostPipedLine(line = line)
  } else if rc == 2 {
    HostPipedTimedOut
  } else {
    HostPipedEof
  }
}

/// Write one line to the child's stdin (a trailing newline is appended and
/// the write blocks until fully accepted by the pipe). Panics if the
/// child's stdin is already closed or the write fails (broken pipe / child
/// gone) — matching the dotnet/JVM twins' identical "an uncaught write
/// failure propagates" contract (neither twin's `hostPipedWriteLine`
/// catches one either).
pub func hostPipedWriteLine(p: in PipedHandle, line: in String): Unit {
  val rc = rtPipedWriteLine(p.raw, line)
  if rc != 0 {
    panic("Std.ProcessPipedHost: " + pipedWriteFailureMessage(rc))
  }
}

/// True while the child process has not yet exited.
pub func hostPipedIsAlive(p: in PipedHandle): Bool {
  rtPipedIsAlive(p.raw) != 0
}

/// Forcibly terminate the child process's whole process group. Safe to
/// call unconditionally (a no-op once the child is already reaped).
pub func hostPipedKill(p: in PipedHandle): Unit {
  val _ = rtPipedKill(p.raw)
}

/// Block up to `timeoutMs` milliseconds for the child to exit. Returns
/// `true` if it exited within the deadline.
pub func hostPipedWaitExit(p: in PipedHandle, timeoutMs: in Int): Bool {
  rtPipedWaitExit(p.raw, timeoutMs) != 0
}

/// The child's OS exit code. Only meaningful after `hostPipedIsAlive`
/// reports `false` (or `hostPipedWaitExit` returned `true`).
pub func hostPipedExitCode(p: in PipedHandle): Int {
  rtPipedExitCode(p.raw)
}

/// Close only the child's stdin (signals EOF to the child without
/// affecting its stdout — useful for a batch-style child that reads until
/// EOF, then writes its complete output and exits). Idempotent-safe.
pub func hostPipedCloseStdin(p: in PipedHandle): Unit {
  val _ = rtPipedCloseStdin(p.raw)
}

/// Close the child's stdin/stdout pipes and release the handle. Does not
/// itself wait for or kill the child. Genuinely idempotent (issue #6975):
/// a second call on the same handle is a no-op, guarded here so the
/// common case never even reaches the extern boundary a second time —
/// `rtPipedClose`/`lyric_process_piped_close` is itself also hardened
/// against a direct repeated call (see that function's own doc comment),
/// so this guard is defense in depth, not the only thing standing
/// between a caller and a double-free.
pub func hostPipedClose(p: in PipedHandle): Unit {
  if p.closed {
    return
  }
  p.closed = true
  rtPipedClose(p.raw)
}

// ── Result seams for Std.Process (#6887) ─────────────────────────────────────
// The managed twins catch their host's exceptions here; this target has no
// unwinding (D-N-003), so each seam reports lyric-rt's return code instead.
// A child that cannot be started, including an execvp failure such as a
// missing executable, is an IoError on every target (lyric-rt reports the
// exec failure over a CLOEXEC pipe).
@unsafe_ffi
pub func hostSpawnPipedResult(fileName: in String, args: in List[String]): Result[PipedHandle, IOError] {
  val c = toC(fileName)
  val raw = rtPipedSpawn(c, args)
  freeC(c)
  if raw == 0i64 {
    Err(error = IoError(path = fileName, message = hostSpawnFailureMessage()))
  } else {
    Ok(value = PipedHandle(raw = raw, closed = false))
  }
}

// lyric-rt reads only report a line or end of stream (a hard read error is
// treated as end of stream), so this seam never produces Err on native.
pub func hostPipedReadLineResult(p: in PipedHandle): Result[Option[String], String] {
  Ok(value = hostPipedReadLineOpt(p))
}

/// Read one line, waiting at most `timeoutMs` milliseconds. Like
/// `hostPipedReadLineResult`, never `Err` on this target.
pub func hostPipedReadLineWithinResult(p: in PipedHandle, timeoutMs: in Int): Result[HostPipedRead, String] {
  Ok(value = pipedReadLineWithin(p, timeoutMs))
}

/// Block until stdout yields at least one byte (bytes a line read buffered
/// come first) or reaches end of stream. Never `HostPipedBytesTimedOut`, and,
/// like the line reads, never `Err` on this target.
pub func hostPipedReadBytesResult(p: in PipedHandle): Result[HostPipedBytes, String] {
  Ok(value = pipedReadBytesWithin(p, 0 - 1))
}

/// Like `hostPipedReadBytesResult`, but waits at most `timeoutMs`
/// milliseconds.
pub func hostPipedReadBytesWithinResult(p: in PipedHandle, timeoutMs: in Int): Result[HostPipedBytes, String] {
  Ok(value = pipedReadBytesWithin(p, timeoutMs))
}

/// Write `bytes` to the child's stdin exactly as given (no newline),
/// blocking until the pipe accepts all of them.
pub func hostPipedWriteBytesResult(p: in PipedHandle, bytes: in slice[Byte]): Result[Unit, String] {
  val rc = rtPipedWriteBytes(p.raw, bytes)
  if rc == 0 {
    Ok(value = ())
  } else {
    Err(error = pipedWriteFailureMessage(rc))
  }
}

pub func hostPipedWriteLineResult(p: in PipedHandle, line: in String): Result[Unit, String] {
  val rc = rtPipedWriteLine(p.raw, line)
  if rc == 0 {
    Ok(value = ())
  } else {
    Err(error = pipedWriteFailureMessage(rc))
  }
}

// lyric-rt's write result: -2 when stdin was already closed, -1 when the
// write itself failed.
func pipedWriteFailureMessage(rc: in Int): String {
  if rc == 0 - 2 {
    "cannot write to the piped child: its stdin is already closed"
  } else {
    "write to the piped child's stdin failed (broken pipe)"
  }
}
