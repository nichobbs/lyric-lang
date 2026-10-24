//! std/_kernel/process_piped_host.l — trusted host boundary for long-lived
//! bidirectional piped child processes (as opposed to `process_host.l`'s
//! inherited-stdio `run`/`runChecked` or `process_capture_host.l`'s
//! batch write-then-drain-to-completion capture).
//!
//! Motivating use case (docs/62-jsonrpc-mcp.md §5.2): an MCP client that
//! spawns an MCP server subprocess and speaks NDJSON-framed JSON-RPC over
//! its stdin/stdout for the lifetime of the connection — `Std.Process.run`
//! blocks until exit, and `runCapture` only returns output after the
//! process has already finished, so neither fits a peer that must be
//! written to and read from interleaved, indefinitely.
//!
//! Only stdin and stdout are redirected (`RedirectStandardInput` /
//! `RedirectStandardOutput`); stderr is left inherited from the parent
//! process (matches `process_host.l`'s `hostSpawn` contract), so a
//! spawned server's diagnostic/log output goes straight to this process's
//! own stderr instead of needing a dedicated drain loop.
//!
//! **One stdout buffer for line and byte reads.** Stdout is read as raw
//! bytes from `Process.StandardOutput.BaseStream`, never through the
//! `StreamReader` on top of it: a `StreamReader` keeps its own read-ahead
//! buffer, so a byte read beside a line read would skip whatever it had
//! buffered. Every read fills one per-handle `MemoryStream` (`buf`, with
//! `head` marking the bytes already returned). A line read returns the bytes
//! up to the next `\n` (a `\r` before it is dropped) decoded as UTF-8 and
//! leaves the rest buffered; a byte read returns everything buffered first,
//! so the two kinds can be mixed on one handle without losing or reordering
//! a byte. This matches the JVM and native twins, which keep one byte buffer
//! the same way. Lines end only at `\n` on every target (a lone `\r` is part
//! of the line, unlike `StreamReader.ReadLine()`), and a line's bytes are
//! decoded with `Encoding.UTF8.GetString`, which replaces an invalid sequence
//! with U+FFFD.
//!
//! **Bounded reads (#7451).** `Stream.Read` has no timeout, so a bounded read
//! runs the blocking `Read` on its own long-running thread
//! (`Task.Factory.StartNew(Action, TaskCreationOptions.LongRunning)`, #7520
//! review — plain `Task.Run` schedules on the shared thread-pool queue, where
//! pool pressure from unrelated work can delay the blocking read from even
//! starting, which then makes a short `Task.Wait(ms)` report a spurious
//! timeout even though nothing is actually stuck; `LongRunning` tells the
//! scheduler to give the work a dedicated thread instead of a pool slot) and
//! waits for it with `Task.Wait(int)`, which returns `false` on timeout
//! instead of throwing. A read that times out is not abandoned: its `Task`
//! stays on the handle (`inflight`), and the next read of either kind and
//! either shape (line or bytes, bounded or not) joins it first, so bytes that
//! arrive after the deadline are delivered by the next read rather than lost
//! or read out of order. At most one background read is outstanding per
//! handle. The read writes only into the handle's `chunk` array, which
//! nothing else touches until the read has been joined.
//!
//! Writes: `hostPipedWriteLine` goes through the `StreamWriter`
//! (`AutoFlush`), `hostPipedWriteBytes` straight to its `BaseStream`, flushed.
//! `AutoFlush` leaves nothing in the writer's own buffer after a line, so the
//! two can be mixed.
//!
//! Internal: only Std.Process should import this.
@axiom("System.Diagnostics.Process piped stdin/stdout, System.IO.Stream/MemoryStream, System.Text.Encoding.UTF8 and System.Threading.Tasks.TaskFactory.StartNew/Task.Wait conform to their documented .NET contracts")
@io
package Std.ProcessPipedHost

import Std.Core
import Std.Collections
import Std.Errors
import Std.ProcessArgs

// ── BCL extern types ───────────────────────────────────────────────────────
extern type Psi = "System.Diagnostics.ProcessStartInfo"

extern type Proc = "System.Diagnostics.Process"

extern type ProcWriter = "System.IO.StreamWriter"

extern type ProcReader = "System.IO.StreamReader"

extern type Stream = "System.IO.Stream"

extern type MemStream = "System.IO.MemoryStream"

extern type Enc = "System.Text.Encoding"

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
// cannot match `StartNew` against a `() -> Unit` lambda argument (it has no
// BCL delegate type to compare shapes against until the call site commits
// to one specific overload) — the same reason `_kernel/http_host.l`,
// `_kernel/tcp_host.l`, and others keep an explicit wrapper for any BCL
// member taking a delegate-typed parameter.
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

// Milliseconds on a monotonic clock, for read deadlines.
@externTarget("System.Environment.get_TickCount64")
func tickCountMs(): Long = ()

// ── ProcessStartInfo setup ─────────────────────────────────────────────────
func newPsi(): Psi {
  Psi.new()
}

func psiFileName(psi: in Psi, v: in String): Unit {
  psi.FileName = v
}

func psiArguments(psi: in Psi, v: in String): Unit {
  psi.Arguments = v
}

func psiRedirectInput(psi: in Psi, v: in Bool): Unit {
  psi.RedirectStandardInput = v
}

func psiRedirectOutput(psi: in Psi, v: in Bool): Unit {
  psi.RedirectStandardOutput = v
}

func psiUseShell(psi: in Psi, v: in Bool): Unit {
  psi.UseShellExecute = v
}

func psiNoWindow(psi: in Psi, v: in Bool): Unit {
  psi.CreateNoWindow = v
}

// ── Process control ────────────────────────────────────────────────────────
func procStart(psi: in Psi): Proc {
  Proc.Start(psi)
}

func procStdinWriter(p: in Proc): ProcWriter {
  p.StandardInput
}

func procStdoutReader(p: in Proc): ProcReader {
  p.StandardOutput
}

func readerBaseStream(r: in ProcReader): Stream {
  r.BaseStream
}

func writerBaseStream(w: in ProcWriter): Stream {
  w.BaseStream
}

func writerSetAutoFlush(w: in ProcWriter, v: in Bool): Unit {
  w.AutoFlush = v
}

func writerWriteLine(w: in ProcWriter, s: in String): Unit {
  w.WriteLine(s)
}

func writerClose(w: in ProcWriter): Unit {
  w.Close()
}

func procHasExited(p: in Proc): Bool {
  p.HasExited
}

func procKillTree(p: in Proc, entireProcessTree: in Bool): Unit {
  p.Kill(entireProcessTree)
}

func procWaitMs(p: in Proc, ms: in Int): Bool {
  p.WaitForExit(ms)
}

func procExitCode(p: in Proc): Int {
  p.ExitCode
}

func procDispose(p: in Proc): Unit {
  p.Dispose()
}

// ── Byte streams ───────────────────────────────────────────────────────────
@externInstance
@externTarget("System.IO.Stream.Read")
func streamReadInto(s: in Stream, buffer: in slice[Byte], offset: in Int, count: in Int): Int = ()

@externInstance
@externTarget("System.IO.Stream.Write")
func streamWriteBytes(s: in Stream, buffer: in slice[Byte], offset: in Int, count: in Int): Unit = ()

@externInstance
@externTarget("System.IO.Stream.Flush")
func streamFlush(s: in Stream): Unit = ()

func newMemStream(): MemStream {
  MemStream.new()
}

// A zero-filled `byte[n]`: `MemoryStream(int capacity)`'s publicly visible
// backing buffer (the `_kernel/tcp_host.l` idiom).
@externTarget("System.IO.MemoryStream..ctor")
func newMemStreamCap(capacity: in Int): MemStream = ()

// The backing array itself, not a copy: indexing it reads the buffered bytes
// in place.
@externInstance
@externTarget("System.IO.MemoryStream.GetBuffer")
func memGetBuffer(m: in MemStream): slice[Byte] = ()

@externInstance
@externTarget("System.IO.MemoryStream.Write")
func memWrite(m: in MemStream, buffer: in slice[Byte], offset: in Int, count: in Int): Unit = ()

func utf8(): Enc {
  Enc.UTF8
}

@externInstance
@externTarget("System.Text.Encoding.GetString")
func encGetString(e: in Enc, bytes: in slice[Byte], index: in Int, count: in Int): String = ()

val readChunkSize: Int = 65536

// ── Public handle + entry points ───────────────────────────────────────────
/// Opaque handle to a running child process with piped stdin/stdout.
pub record PipedHandle {
  proc: Proc
  writer: ProcWriter
  stdin: Stream
  stdout: Stream
  // Where every read of stdout lands; a background read writes nothing else.
  chunk: slice[Byte]
  // Buffered stdout bytes: `[head, len)` of `buf` have not been returned
  // yet, and the first `scanned` of those hold no `\n`. Touched only by the
  // calling thread.
  var buf: MemStream
  var len: Int
  var head: Int
  var scanned: Int
  // Set once stdout reached end of stream (or a read of it failed).
  var eof: Bool
  // The outstanding background read (zero or one element) and what it
  // recorded once complete: `readCount` holds the byte count (`0` at end of
  // stream, `-1` after a failure whose message is in `readError`). Written
  // only by the background task before it completes and read only after
  // `taskWaitMs` observed completion.
  inflight: List[Task]
  readCount: List[Int]
  readError: List[String]
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

/// Spawn `fileName` with a pre-formed `arguments` string (see
/// `Std.Process.buildArgString`), redirecting stdin and stdout; stderr is
/// inherited. Panics (`Bug`) if the executable cannot be found or the OS
/// rejects the spawn — `Std.Process.spawnPiped` catches this and maps it to
/// `IOError`.
pub func hostSpawnPiped(fileName: in String, arguments: in String): PipedHandle {
  val psi = newPsi()
  psiFileName(psi, fileName)
  psiArguments(psi, arguments)
  psiRedirectInput(psi, true)
  psiRedirectOutput(psi, true)
  psiUseShell(psi, false)
  psiNoWindow(psi, true)
  val proc = procStart(psi)
  val w = procStdinWriter(proc)
  writerSetAutoFlush(w, true)
  PipedHandle(
    proc = proc,
    writer = w,
    stdin = writerBaseStream(w),
    stdout = readerBaseStream(procStdoutReader(proc)),
    chunk = memGetBuffer(newMemStreamCap(readChunkSize)),
    buf = newMemStream(),
    len = 0,
    head = 0,
    scanned = 0,
    eof = false,
    inflight = newList(),
    readCount = newList(),
    readError = newList()
  )
}

// ── The shared stdout buffer ───────────────────────────────────────────────
// Append `n` bytes of `chunk`, first dropping the bytes already returned so
// the buffer holds at most one unterminated line plus the new chunk.
func appendChunk(p: in PipedHandle, n: in Int): Unit {
  if p.head > 0 {
    val rest = newMemStream()
    if p.len > p.head {
      memWrite(rest, memGetBuffer(p.buf), p.head, p.len - p.head)
    }
    p.buf = rest
    p.len = p.len - p.head
    p.head = 0
  }
  memWrite(p.buf, p.chunk, 0, n)
  p.len = p.len + n
}

// Bytes `[start, endExclusive)` of the buffer as text: UTF-8, with a `\r`
// immediately before the cut dropped (CRLF line endings).
func decodeBuffered(p: in PipedHandle, start: in Int, endExclusive: in Int): String {
  val bytes = memGetBuffer(p.buf)
  var cut = endExclusive
  if cut > start and bytes[cut - 1] == 13 {
    cut = cut - 1
  }
  encGetString(utf8(), bytes, start, cut - start)
}

// The next complete line in the buffer, if any. Scans only bytes not
// already known to be free of `\n`.
func takeBufferedLine(p: in PipedHandle): Option[String] {
  val bytes = memGetBuffer(p.buf)
  var i = p.head + p.scanned
  while i < p.len {
    if bytes[i] == 10 {
      val line = decodeBuffered(p, p.head, i)
      p.head = i + 1
      p.scanned = 0
      return Some(value = line)
    }
    i = i + 1
  }
  p.scanned = p.len - p.head
  None
}

// After end of stream: the final unterminated bytes as one last line.
func takeBufferedTail(p: in PipedHandle): Option[String] {
  if p.len <= p.head {
    return None
  }
  val line = decodeBuffered(p, p.head, p.len)
  resetBuffer(p)
  Some(value = line)
}

// Every buffered byte not yet returned, in one piece.
func takeBufferedBytes(p: in PipedHandle): Option[slice[Byte]] {
  if p.len <= p.head {
    return None
  }
  val bytes = memGetBuffer(p.buf).slice(p.head, p.len)
  resetBuffer(p)
  Some(value = bytes)
}

func resetBuffer(p: in PipedHandle): Unit {
  p.buf = newMemStream()
  p.len = 0
  p.head = 0
  p.scanned = 0
}

// ── Reading stdout ─────────────────────────────────────────────────────────
// Start the background `Read` unless one is already outstanding.
func ensureBackgroundRead(p: in PipedHandle): Unit {
  if p.inflight.count > 0 {
    return
  }
  val h = p
  val work: () -> Unit = { ->
    try {
      val n = streamReadInto(h.stdout, h.chunk, 0, h.chunk.length)
      h.readError.add("")
      h.readCount.add(n)
    } catch Bug as b {
      h.readError.add(b.message)
      h.readCount.add(0 - 1)
    }
  }
  p.inflight.add(taskRun(work))
}

// Wait up to `ms` (`-1`: without a bound) for the outstanding background
// read. `None` on timeout (the read stays outstanding); otherwise the byte
// count it read into `chunk` (`0` at end of stream), and the handle is ready
// for the next read.
func joinBackgroundRead(p: in PipedHandle, ms: in Int): Option[Result[Int, String]] {
  if not taskWaitMs(p.inflight[0], ms) {
    return None
  }
  val n = p.readCount[0]
  val err = p.readError[0]
  p.inflight.clear()
  p.readCount.clear()
  p.readError.clear()
  if n < 0 {
    Some(value = Err(error = err))
  } else {
    Some(value = Ok(value = n))
  }
}

// One read of stdout into `chunk`: the byte count (`0` at end of stream), or
// `None` when `deadlineMs` (a `tickCountMs` instant; negative for no bound)
// passed first. An unbounded read with nothing outstanding reads on the
// calling thread; anything else goes through the background read.
func readChunk(p: in PipedHandle, deadlineMs: in Long): Option[Result[Int, String]] {
  if deadlineMs < 0i64 {
    if p.inflight.count > 0 {
      return joinBackgroundRead(p, 0 - 1)
    }
    return Some(value = Ok(value = streamReadInto(p.stdout, p.chunk, 0, p.chunk.length)))
  }
  ensureBackgroundRead(p)
  val left = deadlineMs - tickCountMs()
  val waitMs = if left <= 0i64 { 0 } else if left > 2147483647i64 { 2147483647 } else { left.toInt() }
  joinBackgroundRead(p, waitMs)
}

func deadlineAfter(timeoutMs: in Int): Long {
  if timeoutMs < 0 {
    0i64 - 1i64
  } else {
    tickCountMs() + timeoutMs.toLong()
  }
}

// A line, end of stream, or a timeout. A timeout leaves every byte read so
// far buffered.
func readLineUntil(p: in PipedHandle, deadlineMs: in Long): Result[HostPipedRead, String] {
  while true {
    match takeBufferedLine(p) {
      case Some(line) -> return Ok(value = HostPipedLine(line = line))
      case None -> ()
    }
    if p.eof {
      return match takeBufferedTail(p) {
        case Some(line) -> Ok(value = HostPipedLine(line = line))
        case None -> Ok(value = HostPipedEof)
      }
    }
    match readChunk(p, deadlineMs) {
      case None -> return Ok(value = HostPipedTimedOut)
      case Some(Err(e)) -> {
        p.eof = true
        return Err(error = e)
      }
      case Some(Ok(n)) -> {
        if n <= 0 {
          p.eof = true
        } else {
          appendChunk(p, n)
        }
      }
    }
  }
  Ok(value = HostPipedEof)
}

// Buffered bytes first; otherwise one read of stdout.
func readBytesUntil(p: in PipedHandle, deadlineMs: in Long): Result[HostPipedBytes, String] {
  match takeBufferedBytes(p) {
    case Some(bytes) -> return Ok(value = HostPipedChunk(bytes = bytes))
    case None -> ()
  }
  if p.eof {
    return Ok(value = HostPipedBytesEof)
  }
  match readChunk(p, deadlineMs) {
    case None -> Ok(value = HostPipedBytesTimedOut)
    case Some(Err(e)) -> {
      p.eof = true
      Err(error = e)
    }
    case Some(Ok(n)) -> {
      if n <= 0 {
        p.eof = true
        Ok(value = HostPipedBytesEof)
      } else {
        Ok(value = HostPipedChunk(bytes = p.chunk.slice(0, n)))
      }
    }
  }
}

// Option seam avoiding `case null`'s catch-all miscompile (#4775): a line,
// or `None` at end of stream. Panics (`Bug`) when stdout cannot be read.
pub func hostPipedReadLineOpt(p: in PipedHandle): Option[String] {
  match readLineUntil(p, 0i64 - 1i64) {
    case Ok(HostPipedLine(line)) -> Some(value = line)
    case Ok(_) -> None
    case Err(e) -> panic("Std.ProcessPipedHost: " + e)
  }
}

/// Write one line to the child's stdin (a trailing newline is appended and
/// the write is flushed immediately — `AutoFlush` is set at spawn time).
pub func hostPipedWriteLine(p: in PipedHandle, line: in String): Unit {
  writerWriteLine(p.writer, line)
}

/// Write `bytes` to the child's stdin exactly as given (no newline) and
/// flush.
pub func hostPipedWriteBytes(p: in PipedHandle, bytes: in slice[Byte]): Unit {
  if bytes.length > 0 {
    streamWriteBytes(p.stdin, bytes, 0, bytes.length)
  }
  streamFlush(p.stdin)
}

/// True while the child process has not yet exited.
pub func hostPipedIsAlive(p: in PipedHandle): Bool {
  not procHasExited(p.proc)
}

/// Forcibly terminate the child process and its process tree. Swallows any
/// failure (e.g. the process already exited) — safe to call unconditionally.
pub func hostPipedKill(p: in PipedHandle): Unit {
  try {
    procKillTree(p.proc, true)
  } catch Bug as _ {
    ()
  }
}

/// Block up to `timeoutMs` milliseconds for the child to exit. Returns
/// `true` if it exited within the deadline.
pub func hostPipedWaitExit(p: in PipedHandle, timeoutMs: in Int): Bool {
  procWaitMs(p.proc, timeoutMs)
}

/// The child's OS exit code. Only meaningful after `hostPipedIsAlive`
/// reports `false` (or `hostPipedWaitExit` returned `true`).
pub func hostPipedExitCode(p: in PipedHandle): Int {
  try {
    procExitCode(p.proc)
  } catch Bug as _ {
    -1
  }
}

/// Close only the child's stdin (signals EOF to the child without
/// affecting its stdout — useful for a batch-style child that reads until
/// EOF, then writes its complete output and exits). Swallows failures.
pub func hostPipedCloseStdin(p: in PipedHandle): Unit {
  try {
    writerClose(p.writer)
  } catch Bug as _ {
    ()
  }
}

/// Close the child's stdin/stdout pipes and release the OS process handle.
/// Does not itself wait for or kill the child. Swallows failures so it is
/// safe to call during best-effort cleanup.
pub func hostPipedClose(p: in PipedHandle): Unit {
  try {
    writerClose(p.writer)
  } catch Bug as _ {
    ()
  }
  try {
    procDispose(p.proc)
  } catch Bug as _ {
    ()
  }
}

// ── Result seams for Std.Process (#6887) ─────────────────────────────────────
// `Std.Process` delegates here. The host throws on a failed spawn, read or
// write; the try/catch lives in the kernel because `--target native` has no
// unwinding (D-N-003) and its twin reports the same failures as return codes
// instead.
pub func hostSpawnPipedResult(fileName: in String, args: in List[String]): Result[PipedHandle, IOError] {
  try {
    Ok(value = hostSpawnPiped(fileName, argvJoin(args)))
  } catch Bug as b {
    Err(error = IoError(path = fileName, message = b.message))
  }
}

pub func hostPipedReadLineResult(p: in PipedHandle): Result[Option[String], String] {
  try {
    match readLineUntil(p, 0i64 - 1i64) {
      case Ok(HostPipedLine(line)) -> Ok(value = Some(value = line))
      case Ok(_) -> Ok(value = None)
      case Err(e) -> Err(error = e)
    }
  } catch Bug as b {
    Err(error = b.message)
  }
}

/// Read one line, waiting at most `timeoutMs` milliseconds (see the module
/// doc for how a timed-out read is resumed).
pub func hostPipedReadLineWithinResult(p: in PipedHandle, timeoutMs: in Int): Result[HostPipedRead, String] {
  try {
    readLineUntil(p, deadlineAfter(timeoutMs))
  } catch Bug as b {
    Err(error = b.message)
  }
}

/// Block until stdout yields at least one byte (bytes a line read buffered
/// come first) or reaches end of stream. Never `HostPipedBytesTimedOut`.
pub func hostPipedReadBytesResult(p: in PipedHandle): Result[HostPipedBytes, String] {
  try {
    readBytesUntil(p, 0i64 - 1i64)
  } catch Bug as b {
    Err(error = b.message)
  }
}

/// Like `hostPipedReadBytesResult`, but waits at most `timeoutMs`
/// milliseconds.
pub func hostPipedReadBytesWithinResult(p: in PipedHandle, timeoutMs: in Int): Result[HostPipedBytes, String] {
  try {
    readBytesUntil(p, deadlineAfter(timeoutMs))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub func hostPipedWriteLineResult(p: in PipedHandle, line: in String): Result[Unit, String] {
  try {
    hostPipedWriteLine(p, line)
    Ok(value = ())
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub func hostPipedWriteBytesResult(p: in PipedHandle, bytes: in slice[Byte]): Result[Unit, String] {
  try {
    hostPipedWriteBytes(p, bytes)
    Ok(value = ())
  } catch Bug as b {
    Err(error = b.message)
  }
}
