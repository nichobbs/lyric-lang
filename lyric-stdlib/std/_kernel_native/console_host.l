//! std/_kernel_native/console_host.l — native-target console boundary.
//!
//! The `--target native` twin of `_kernel/console_host.l`, selected by
//! the native source loader the same way `_kernel_jvm/` twins override
//! their `_kernel/` counterparts by basename (docs/44 J6 M-10).  Output
//! goes through the audited lyric-rt helpers (`lyric_console_write*`),
//! which loop on EINTR/partial writes (`println` is one `writev`);
//! console output stays a best-effort effect per Std.Console's contract.
//!
//! Console input reads fd 0 through `lyric_stdin_*` (#7933): the line seam
//! `hostReadLineOpt` and the raw-byte reader (`hostOpenStdin` /
//! `hostStdinReadResult` / `hostStdinReadWithinResult`, #7451) behind
//! `Std.Console.openStdinReader`/`readStdin`/`readStdinWithin`.  A bounded
//! read polls for readiness first, so a read that times out consumes
//! nothing and the bytes that arrive later go to the next read, as the
//! managed twins' outstanding background read delivers them.
//! `Std.Console.readLine` itself still does not lower here: its body
//! catches a host `Bug`, and this target has no unwinding (D-N-003).
@axiom("POSIX read(2), write(2) and poll(2) via lyric-rt conform to their documented contracts")
@io
package Std.ConsoleHost

import Std.Core

extern func consoleWriteFd(fd: Int, s: String): Unit = "lyric_console_write"

extern func consoleWriteLineFd(fd: Int, s: String): Unit = "lyric_console_write_line"

// Raw bytes, no text encoding applied — for callers that frame their own
// wire protocol over stdout (e.g. the LSP Content-Length writer, #7510) and
// must control their exact output bytes.
extern func consoleWriteBytesFd(fd: Int, bytes: slice[Byte]): Unit = "lyric_console_write_bytes"

pub func hostConsoleWrite(text: in String): Unit {
  consoleWriteFd(1, text)
}

// One writev(2) per line (#7284). Output stays unbuffered, matching the
// managed targets' autoflushing console: a line is visible as soon as it is
// written, including to a harness reading a long-running program's pipe.
pub func hostConsoleWriteLine(text: in String): Unit {
  consoleWriteLineFd(1, text)
}

pub func hostConsoleWriteBytes(bytes: in slice[Byte]): Unit {
  consoleWriteBytesFd(1, bytes)
}

pub func hostConsoleErrorWrite(text: in String): Unit {
  consoleWriteFd(2, text)
}

pub func hostConsoleErrorWriteLine(text: in String): Unit {
  consoleWriteLineFd(2, text)
}

extern func rtStdinWait(timeoutMs: Int): Int = "lyric_stdin_wait"

extern func rtStdinRead(max: Int, okOut: NativePtr[Int]): slice[Byte] = "lyric_stdin_read"

extern func rtStdinReadLine(outp: NativePtr[String]): Int = "lyric_stdin_read_line"

@unsafe_ffi
pub func hostReadLineOpt(): Option[String] {
  var line: String = ""
  val rc = rtStdinReadLine(nativeAddrOf(line))
  if rc == 1 {
    Some(value = line)
  } else if rc == 0 {
    None
  } else {
    panic("Std.Console.readLine: stdin could not be read")
  }
}

/// Raw-byte reader over this process's standard input.
pub record StdinHandle {
  bufferSize: Int
}

/// Outcome of one stdin read.
pub union HostStdinRead {
  case HostStdinBytes(bytes: slice[Byte])
  case HostStdinEof
  case HostStdinTimedOut
}

pub func hostOpenStdin(): StdinHandle {
  StdinHandle(bufferSize = 65536)
}

@unsafe_ffi
func readStdinChunk(h: in StdinHandle): Result[HostStdinRead, String] {
  var ok: Int = 0
  val bytes = rtStdinRead(h.bufferSize, nativeAddrOf(ok))
  if ok != 1 {
    Err(error = "stdin could not be read")
  } else if bytes.length == 0 {
    Ok(value = HostStdinEof)
  } else {
    Ok(value = HostStdinBytes(bytes = bytes))
  }
}

/// Block until stdin yields at least one byte or reaches end of stream.
/// Never `HostStdinTimedOut`.
pub func hostStdinReadResult(h: in StdinHandle): Result[HostStdinRead, String] {
  readStdinChunk(h)
}

/// Like `hostStdinReadResult`, but waits at most `timeoutMs` milliseconds.
pub func hostStdinReadWithinResult(h: in StdinHandle, timeoutMs: in Int): Result[HostStdinRead, String] {
  val ready = rtStdinWait(timeoutMs)
  if ready == 0 {
    Ok(value = HostStdinTimedOut)
  } else if ready < 0 {
    Err(error = "stdin could not be polled")
  } else {
    readStdinChunk(h)
  }
}
