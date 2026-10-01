//! std/_kernel/console_host.l - host boundary for System.Console stdin/stdout/stderr.
//!
//! Low-level console I/O needed by Std.Console and the LSP framing layer.
//! `hostConsoleRead()` returns a single UTF-16 code unit (0..65535) or -1 on
//! EOF, matching System.Console.Read().  Other functions match the named
//! System.Console static methods.
//!
//! The stdin byte reader (`hostOpenStdin` / `hostStdinReadResult` /
//! `hostStdinReadWithinResult`, #7451) reads raw bytes from
//! `Console.OpenStandardInput()`. A bounded read runs the blocking
//! `Stream.Read` on its own long-running thread
//! (`Task.Factory.StartNew(Action, TaskCreationOptions.LongRunning)`, #7520 review
//! — plain `Task.Run` schedules on the shared thread-pool queue, where pool
//! pressure from unrelated work can delay the blocking read from even
//! starting, which then makes a short `Task.Wait(ms)` report a spurious
//! timeout even though nothing is actually stuck) and waits for it with
//! `Task.Wait(int)`, which returns `false` on timeout. A timed-out read
//! stays outstanding on the handle and the next read of either kind joins it,
//! so bytes that arrive after a deadline are delivered, in order, by the next
//! read.
//!
//! Internal: prefer Std.Console (print/println/readLine) for application code.
//! Import this kernel module only when exact byte-level control is required
//! (e.g. the LSP Content-Length framing reader).
@axiom("System.Console operations and System.Threading.Tasks.TaskFactory.StartNew/Task.Wait conform to their documented .NET contracts")
@io
package Std.ConsoleHost

import Std.Core
import Std.Collections

extern type NetConsole = "System.Console"

pub func hostConsoleRead(): Int {
  NetConsole.Read()
}

pub func hostConsoleWrite(text: in String): Unit {
  NetConsole.Write(text)
}

pub func hostConsoleWriteLine(text: in String): Unit {
  NetConsole.WriteLine(text)
}

// stays @externTarget: the nullable `String?` return relies on the
// declared-signature nullable-return handling only the @externTarget
// path provides (auto-FFI has no null-return convention).
@externTarget("System.Console.ReadLine")
pub func hostConsoleReadLine(): String? = ()

// Option seam avoiding `case null`'s catch-all miscompile (#4775); NUL-marker mirrors `hostGetVarOpt` (#4750).
pub func hostReadLineOpt(): Option[String] {
  val v = hostConsoleReadLine() ?? "\u{0000}"
  if v == "\u{0000}" {
    None
  } else {
    Some(value = v)
  }
}

// stderr — `Console.Error` is a static property returning a
// `System.IO.TextWriter`; compose the property getter with the writer's
// instance `WriteLine(String)` in pure Lyric (no F# shim — #1493).
extern type TextWriter = "System.IO.TextWriter"

func consoleErrorWriter(): TextWriter {
  NetConsole.Error
}

// Binds the `TextWriter.WriteLine(string)` overload; auto-FFI overload
// scoring resolves it by the String argument type.
func textWriterWriteLine(w: in TextWriter, text: in String): Unit {
  w.WriteLine(text)
}

pub func hostConsoleErrorWriteLine(text: in String): Unit {
  textWriterWriteLine(consoleErrorWriter(), text)
}

// ── Stdin byte reader (#7451) ────────────────────────────────────────────────
extern type Stream = "System.IO.Stream"

extern type MemStream = "System.IO.MemoryStream"

extern type Task = "System.Threading.Tasks.Task"

extern type TaskFactory = "System.Threading.Tasks.TaskFactory"

extern type TaskCreationOptions = "System.Threading.Tasks.TaskCreationOptions"

// `Task.Factory` is a static property; `Task.LongRunning` is a static field
// (the same auto-FFI field-read path already used for `Duration.Zero` /
// `Instant.UtcNow` in `_kernel/time_host.l`).
func taskFactory(): TaskFactory {
  Task.Factory
}

// stays @externTarget: auto-FFI's reference-assembly overload scoring
// cannot match `StartNew` against a `() -> Unit` lambda argument — the same
// reason `_kernel/process_piped_host.l` keeps an explicit wrapper for it.
@externInstance
@externTarget("System.Threading.Tasks.TaskFactory.StartNew")
func taskFactoryStartNew(f: in TaskFactory, work: in () -> Unit, options: in TaskCreationOptions): Task = ()

// Each blocking read gets its own dedicated thread instead of a thread-pool
// slot (#7520 review — see the module doc for why plain `Task.Run` is unsafe here).
func taskRun(work: in () -> Unit): Task {
  taskFactoryStartNew(taskFactory(), work, TaskCreationOptions.LongRunning)
}

// `Task.Wait(int)`: `true` once the task completed, `false` when `ms` elapsed
// first. `-1` (`Timeout.Infinite`) waits without a bound.
func taskWaitMs(t: in Task, ms: in Int): Bool {
  t.Wait(ms)
}

func openStandardInput(): Stream {
  NetConsole.OpenStandardInput()
}

@externInstance
@externTarget("System.IO.Stream.Read")
func streamReadInto(s: in Stream, buffer: in slice[Byte], offset: in Int, count: in Int): Int = ()

// ── Raw stdout byte writer ────────────────────────────────────────────────
// Writes bytes verbatim to stdout with no text encoding applied — for
// callers that frame their own wire protocol (e.g. the LSP Content-Length
// writer, #7510) and must control their exact output bytes rather than
// going through `Console.Write`'s `TextWriter`, which could re-encode.
func openStandardOutput(): Stream {
  NetConsole.OpenStandardOutput()
}

@externInstance
@externTarget("System.IO.Stream.Write")
func streamWriteBytes(s: in Stream, buffer: in slice[Byte], offset: in Int, count: in Int): Unit = ()

@externInstance
@externTarget("System.IO.Stream.Flush")
func streamFlush(s: in Stream): Unit = ()

pub func hostConsoleWriteBytes(bytes: in slice[Byte]): Unit {
  val s = openStandardOutput()
  streamWriteBytes(s, bytes, 0, bytes.length)
  streamFlush(s)
}

// A zero-filled `byte[n]`: `MemoryStream(int capacity)`'s publicly visible
// backing buffer (the `_kernel/tcp_host.l` idiom).
@externTarget("System.IO.MemoryStream..ctor")
func newMemStreamCap(capacity: in Int): MemStream = ()

@externInstance
@externTarget("System.IO.MemoryStream.GetBuffer")
func memGetBuffer(m: in MemStream): slice[Byte] = ()

val stdinBufferSize: Int = 65536

/// Raw-byte reader over this process's standard input.
pub record StdinHandle {
  stream: Stream
  buf: slice[Byte]
  // The outstanding background read (zero or one element) and what it
  // recorded once complete: `readCount` holds the byte count (`0` at end of
  // stream, `-1` after a failure whose message is in `readError`). Written
  // only by the background task before it completes, read only after
  // `taskWaitMs` observed completion.
  inflight: List[Task]
  readCount: List[Int]
  readError: List[String]
}

/// Outcome of one stdin read.
pub union HostStdinRead {
  case HostStdinBytes(bytes: slice[Byte])
  case HostStdinEof
  case HostStdinTimedOut
}

pub func hostOpenStdin(): StdinHandle {
  StdinHandle(
    stream = openStandardInput(),
    buf = memGetBuffer(newMemStreamCap(stdinBufferSize)),
    inflight = newList(),
    readCount = newList(),
    readError = newList()
  )
}

func stdinBytesOf(h: in StdinHandle, n: in Int): HostStdinRead {
  if n <= 0 {
    HostStdinEof
  } else {
    HostStdinBytes(bytes = h.buf.slice(0, n))
  }
}

func startStdinRead(h: in StdinHandle): Unit {
  if h.inflight.count > 0 {
    return
  }
  val handle = h
  val work: () -> Unit = { ->
    try {
      val n = streamReadInto(handle.stream, handle.buf, 0, handle.buf.length)
      handle.readError.add("")
      handle.readCount.add(n)
    } catch Bug as b {
      handle.readError.add(b.message)
      handle.readCount.add(0 - 1)
    }
  }
  h.inflight.add(taskRun(work))
}

// Wait up to `ms` (`-1`: without a bound) for the outstanding read; `None`
// on timeout, leaving it outstanding.
func joinStdinRead(h: in StdinHandle, ms: in Int): Option[Result[HostStdinRead, String]] {
  if not taskWaitMs(h.inflight[0], ms) {
    return None
  }
  val n = h.readCount[0]
  val err = h.readError[0]
  h.inflight.clear()
  h.readCount.clear()
  h.readError.clear()
  if n < 0 {
    Some(value = Err(error = err))
  } else {
    Some(value = Ok(value = stdinBytesOf(h, n)))
  }
}

/// Block until stdin yields at least one byte or reaches end of stream.
/// Never `HostStdinTimedOut`.
pub func hostStdinReadResult(h: in StdinHandle): Result[HostStdinRead, String] {
  try {
    if h.inflight.count > 0 {
      match joinStdinRead(h, 0 - 1) {
        case Some(r) -> r
        case None -> Err(error = "background stdin read did not complete")
      }
    } else {
      Ok(value = stdinBytesOf(h, streamReadInto(h.stream, h.buf, 0, h.buf.length)))
    }
  } catch Bug as b {
    Err(error = b.message)
  }
}

/// Like `hostStdinReadResult`, but waits at most `timeoutMs` milliseconds.
pub func hostStdinReadWithinResult(h: in StdinHandle, timeoutMs: in Int): Result[HostStdinRead, String] {
  try {
    startStdinRead(h)
    match joinStdinRead(h, timeoutMs) {
      case Some(r) -> r
      case None -> Ok(value = HostStdinTimedOut)
    }
  } catch Bug as b {
    Err(error = b.message)
  }
}
