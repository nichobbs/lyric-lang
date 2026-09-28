//! std/_kernel_jvm/console_host.l - JVM host boundary for console IO.
//!
//! Mirrors _kernel/console_host.l for the JVM target.  Pure Lyric over the
//! JVM auto-FFI against `java.lang.System.{out,err,in}` — the previous
//! version routed through a `lyric.stdlib.jvm.ConsoleHost` shim class that
//! never existed at runtime (same elimination as the `time_host.l` /
//! `collections_host.l` / `file_host.l` rewrites).  `System.out` / `err` /
//! `in` are public static FIELDS, resolved by the auto-FFI's static-field
//! path (`getstatic` from JDK metadata) rather than method resolution.
//!
//! hostConsoleRead returns a single UTF-16 code unit (0..65535) or -1 on
//! EOF, matching the contract of the .NET kernel's System.Console.Read.
//! Stdin reads share one process-wide BufferedReader (a module-level `val`,
//! initialised once in the class initialiser): constructing a fresh
//! buffered reader per call would buffer-and-discard lookahead bytes
//! between consecutive reads.
//!
//! The stdin byte reader (`hostOpenStdin` / `hostStdinReadResult` /
//! `hostStdinReadWithinResult`, #7451) reads raw bytes from `System.in`. A
//! bounded read runs the blocking `InputStream.read()` on a
//! daemon platform thread (`new Thread(Runnable)` over a record implementing
//! `Runnable`, marked daemon so it never keeps the JVM alive) and waits with
//! `Thread.join(long)`. A timed-out read stays outstanding on the handle and
//! the next read of either kind joins it, so bytes that arrive after a
//! deadline are delivered, in order, by the next read. `available()` polling
//! (the piped-process kernel's technique) is not used here: it cannot tell
//! end of stream from "nothing yet".
//!
//! Internal: prefer Std.Console for application code.  Import this kernel
//! module only when exact byte-level control is required (e.g. the LSP
//! Content-Length framing reader).
//!
//! `System.out`/`System.err` are rebound to UTF-8 `PrintStream`s once, at
//! process startup, in the synthesized JVM `main` wrapper (`#7513`,
//! `Jvm.Codegen.emitConsoleUtf8Setup` in `lyric-compiler/jvm/codegen/06_items.l`)
//! rather than in this file — that keeps `println`/`print`'s builtin
//! bytecode lowering (which also reads the `System.out` static field
//! directly) on the same UTF-8 stream with no codegen changes of its own.
//! `stdinReader` below decodes explicitly as UTF-8 for the same reason: the
//! JVM's platform-default charset is ASCII under a C/POSIX locale.
@axiom("java.lang.System.{out,err,in}, java.io.BufferedReader and java.lang.Thread conform to their documented JVM contracts")
package Std.ConsoleHost

import Std.Core
import Std.Collections
import Std.Math

extern type JSystem = "java.lang.System"

extern type JPrintStream = "java.io.PrintStream"

extern type JBufferedReader = "java.io.BufferedReader"

extern type JInputStreamReader = "java.io.InputStreamReader"

extern type JCharset = "java.nio.charset.Charset"

extern type JStandardCharsets = "java.nio.charset.StandardCharsets"

// Process-shared stdin reader (see the module doc). Decodes explicitly as
// UTF-8 (#7513): `InputStreamReader(InputStream)` without a charset argument
// decodes through the JVM's platform default charset, which is ASCII under a
// C/POSIX locale (common in containers/CI) — every multi-byte `readLine()`
// character beyond ASCII would come back mangled. `hostConsoleRead`'s
// underlying `.read()` is likewise sourced from this same UTF-8 reader.
val stdinReader: JBufferedReader = JBufferedReader.new(JInputStreamReader.new(JSystem.in, JStandardCharsets.UTF_8))

/// Read a single UTF-16 code unit from stdin; -1 at EOF.
pub func hostConsoleRead(): Int {
  stdinReader.read()
}

pub func hostConsoleWrite(text: in String): Unit {
  val o = JSystem.out
  o.print(text)
}

pub func hostConsoleWriteLine(text: in String): Unit {
  val o = JSystem.out
  o.println(text)
}

// ── Raw stdout byte writer ────────────────────────────────────────────────
// Writes bytes verbatim to stdout with no text encoding applied — for
// callers that frame their own wire protocol (e.g. the LSP Content-Length
// writer, #7510) and must control their exact output bytes rather than
// going through `PrintStream`'s char-encoding-based `print`/`println`.
func printStreamWriteBytes(o: in JPrintStream, bytes: in slice[Byte]): Unit {
  o.write(bytes)
}

func printStreamFlush(o: in JPrintStream): Unit {
  o.flush()
}

pub func hostConsoleWriteBytes(bytes: in slice[Byte]): Unit {
  val o = JSystem.out
  printStreamWriteBytes(o, bytes)
  printStreamFlush(o)
}

/// Read a line from stdin; null at EOF (mapped to None by Std.Console).
pub func hostConsoleReadLine(): String? {
  stdinReader.readLine()
}

// Option seam avoiding `case null`'s catch-all miscompile (#4775); NUL-marker mirrors `hostGetVarOpt` (#4750).
pub func hostReadLineOpt(): Option[String] {
  val v = hostConsoleReadLine() ?? "\u{0000}"
  if v == "\u{0000}" {
    None
  } else {
    Some(value = v)
  }
}

pub func hostConsoleErrorWriteLine(text: in String): Unit {
  val e = JSystem.err
  e.println(text)
}

// ── Stdin byte reader (#7451) ────────────────────────────────────────────────
extern type JInputStream = "java.io.InputStream"

extern type JRunnable = "java.lang.Runnable"

extern type JThread = "java.lang.Thread"

extern type JBAOS = "java.io.ByteArrayOutputStream"

extern type JAtomicBoolean = "java.util.concurrent.atomic.AtomicBoolean"

// Upper bound on the bytes one read returns.
val stdinChunkMax: Int = 65536

// Tail-position forms: a discarded auto-FFI instance call whose receiver is a
// parameter emits no invoke on this backend (#5379).
func atomicBoolSet(a: in JAtomicBoolean, v: in Bool): Unit {
  a.set(v)
}

func atomicBoolGet(a: in JAtomicBoolean): Bool {
  a.get()
}

func threadJoinMs(t: in JThread, ms: in Long): Unit {
  t.join(ms)
}

func baosWriteByte(acc: in JBAOS, b: in Int): Unit {
  acc.write(b)
}

func baosWriteBytes(acc: in JBAOS, bytes: in slice[Byte]): Unit {
  acc.write(bytes)
}

// One blocking read: the first byte (`read()` blocks until one arrives or the
// stream ends), then whatever else is already available without blocking.
// Returned arrays come from the JDK (`readNBytes`, `toByteArray`) rather than
// a caller-owned buffer filled through `read(byte[], int, int)`, whose writes
// the auto-FFI array marshalling does not propagate back. Empty at end of
// stream.
func readChunk(s: in JInputStream): slice[Byte] {
  val first = s.read()
  if first < 0 {
    val empty: slice[Byte] = []
    return empty
  }
  val acc: JBAOS = JBAOS.new()
  baosWriteByte(acc, first)
  val avail = s.available()
  if avail > 0 {
    val want = if avail < stdinChunkMax - 1 { avail } else { stdinChunkMax - 1 }
    baosWriteBytes(acc, s.readNBytes(want))
  }
  acc.toByteArray()
}

// One `readChunk` run on a daemon thread. The chunk (or the failure message)
// is recorded before `done` is set.
record StdinReadJob {
  stream: JInputStream
  done: JAtomicBoolean
  chunks: List[slice[Byte]]
  errors: List[String]
}

impl JRunnable for StdinReadJob {
  func run(): Unit {
    try {
      self.chunks.add(readChunk(self.stream))
    } catch Bug as b {
      self.errors.add(b.message)
    }
    atomicBoolSet(self.done, true)
  }
}

func threadSetDaemon(t: in JThread, on: in Bool): Unit {
  t.setDaemon(on)
}

func threadStart(t: in JThread): Unit {
  t.start()
}

// A platform daemon thread, not a virtual one: a read blocked on
// `System.in` pins a virtual thread's carrier, and `Thread(Runnable)` /
// `setDaemon` / `start` exist on every JDK the compiler may resolve
// against, where `Thread.startVirtualThread` needs JDK 21.
func startJob(job: in StdinReadJob): JThread {
  val t = JThread.new(job)
  threadSetDaemon(t, true)
  threadStart(t)
  t
}

/// Raw-byte reader over this process's standard input.
pub record StdinHandle {
  stream: JInputStream
  // The outstanding background read (zero or one of each).
  jobs: List[StdinReadJob]
  threads: List[JThread]
}

/// Outcome of one stdin read.
pub union HostStdinRead {
  case HostStdinBytes(bytes: slice[Byte])
  case HostStdinEof
  case HostStdinTimedOut
}

pub func hostOpenStdin(): StdinHandle {
  StdinHandle(stream = JSystem.in, jobs = newList(), threads = newList())
}

func stdinReadOf(bytes: in slice[Byte]): HostStdinRead {
  if bytes.length == 0 {
    HostStdinEof
  } else {
    HostStdinBytes(bytes = bytes)
  }
}

func startStdinRead(h: in StdinHandle): Unit {
  if h.jobs.count > 0 {
    return
  }
  val job = StdinReadJob(stream = h.stream, done = JAtomicBoolean.new(false), chunks = newList(), errors = newList())
  h.jobs.add(job)
  h.threads.add(startJob(job))
}

// Wait up to `ms` (negative: without a bound) for the outstanding read;
// `None` on timeout, leaving it outstanding.
func joinStdinRead(h: in StdinHandle, ms: in Int): Option[Result[HostStdinRead, String]] {
  val job = h.jobs[0]
  val t = h.threads[0]
  if ms < 0 {
    threadJoinMs(t, 0i64)
  } else if ms > 0 {
    threadJoinMs(t, ms.toLong())
  }
  if not atomicBoolGet(job.done) {
    return None
  }
  h.jobs.clear()
  h.threads.clear()
  if job.errors.count > 0 {
    Some(value = Err(error = job.errors[0]))
  } else {
    Some(value = Ok(value = stdinReadOf(job.chunks[0])))
  }
}

/// Block until stdin yields at least one byte or reaches end of stream.
/// Never `HostStdinTimedOut`.
pub func hostStdinReadResult(h: in StdinHandle): Result[HostStdinRead, String] {
  try {
    if h.jobs.count > 0 {
      match joinStdinRead(h, 0 - 1) {
        case Some(r) -> r
        case None -> Err(error = "background stdin read did not complete")
      }
    } else {
      Ok(value = stdinReadOf(readChunk(h.stream)))
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
