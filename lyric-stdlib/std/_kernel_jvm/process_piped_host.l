//! std/_kernel_jvm/process_piped_host.l — JVM host boundary for long-lived
//! bidirectional piped child processes.
//!
//! Mirrors `_kernel/process_piped_host.l` for the JVM target. Only stdin
//! and stdout are redirected to pipes (the `ProcessBuilder` default); stderr
//! is redirected to `Redirect.INHERIT` so a spawned child's diagnostic/log
//! output goes straight to this process's own stderr, matching the .NET
//! kernel's "stderr inherited" contract exactly rather than needing a
//! dedicated stderr-drain loop (which the JDK's default `Redirect.PIPE`
//! would otherwise require to avoid a full-pipe-buffer deadlock).
//! `ProcessBuilder$Redirect.INHERIT` is a plain nested-enum static field
//! read via auto-FFI — the same pattern already proven by
//! `_kernel_jvm/http_host.l`'s `JRedirect.NORMAL` / `JRedirect.NEVER`
//! (`java.net.http.HttpClient$Redirect`); the auto-FFI *method-parameter*
//! scoring gap noted in `process_capture_host.l` (`Process.waitFor(long,
//! TimeUnit)`) does not apply to a field read.
//!
//! `Process.waitFor()` has no timeout-friendly overload reachable via
//! auto-FFI (see above), so `hostPipedWaitExit` polls `isAlive()` with a
//! 1ms sleep between checks, the same technique
//! `process_capture_host.l`'s `runImpl` uses.
//!
//! **Read-side design (issue #6135):** an earlier version of this kernel
//! read lines via `BufferedReader.readLine()` (mirroring the `.NET` kernel's
//! blocking `StreamReader.ReadLine()`) and observed it fail unreliably
//! against a real child process's stdout — sometimes a spurious immediate
//! `null` (as if EOF) against a process that was still alive with real bytes
//! queued, sometimes a block past any reasonable deadline. Two specific
//! candidate causes were investigated and ruled out by direct experiment:
//! the `redirectError(Redirect.INHERIT)` call interfering with the stdout
//! redirect, and the nested `new BufferedReader(new InputStreamReader(...))`
//! constructor chain (rebinding each `.new()` to an explicit intermediate
//! `val` changed the failure mode but did not fix it).
//!
//! The fix routes stdout through the SAME byte-level, `available()`-polled
//! drain technique `_kernel_jvm/process_capture_host.l`'s `hostRunCapture`
//! already uses reliably on this exact JDK for batch output capture:
//! `pipedReadLine` never calls a blocking `Reader`/`InputStream` method at
//! all. Each call polls `InputStream.available()` and, once bytes are
//! ready, drains however many are currently available via
//! `readNBytes(avail)` into a per-handle `ByteArrayOutputStream` line
//! buffer; a line is recognized the moment a `\n` (0x0A) byte appears in
//! the accumulated buffer — `\n` can never occur as a UTF-8 continuation
//! byte (those are always `0x80..0xBF`), so scanning raw bytes for it is
//! safe regardless of any multi-byte characters in the line. A `\r`
//! immediately before the `\n` is stripped too, matching
//! `BufferedReader.readLine()`'s CRLF convention. On process exit with a
//! non-empty, newline-less remainder, that remainder is returned as the
//! final line (also matching `BufferedReader.readLine()`), then `None` on
//! the next call. `Std.Encoding.tryDecodeUtf8` (pure Lyric, cross-target,
//! already relied on elsewhere) does the actual decode once a complete
//! line's bytes are known — no hand-rolled UTF-8 state machine here. This
//! sidesteps whatever `BufferedReader`/`InputStreamReader` interaction
//! caused the original symptom entirely, rather than attempting to
//! diagnose it further.
//!
//! Internal: only Std.Process should import this.
@axiom("java.lang.ProcessBuilder + java.lang.Process piped stdin/stdout conform to their documented JVM contracts")
package Std.ProcessPipedHost

import Std.Core
import Std.Collections
import Std.Math
import Std.Encoding
import Std.ProcessCaptureHost

// ── JDK extern types ──────────────────────────────────────────────────────────
extern type JProcessBuilder = "java.lang.ProcessBuilder"

extern type JRedirect = "java.lang.ProcessBuilder$Redirect"

extern type JProcess = "java.lang.Process"

extern type JOutputStream = "java.io.OutputStream"

extern type JInputStream = "java.io.InputStream"

extern type JOutputStreamWriter = "java.io.OutputStreamWriter"

extern type JBAOS = "java.io.ByteArrayOutputStream"

extern type JPrintWriter = "java.io.PrintWriter"

extern type JThread = "java.lang.Thread"

@externTarget("java.lang.System.currentTimeMillis")
func currentTimeMillis(): Long = ()

// ── Process construction ──────────────────────────────────────────────────────
func buildProcessBuilder(cmd: in List[String]): JProcessBuilder {
  val pb = JProcessBuilder.new(cmd)
  val withErrInherit: JProcessBuilder = pb.redirectError(JRedirect.INHERIT)
  withErrInherit
}

func procStart(pb: in JProcessBuilder): JProcess {
  pb.start()
}

func procStdin(p: in JProcess): JOutputStream {
  p.getOutputStream()
}

func procStdout(p: in JProcess): JInputStream {
  p.getInputStream()
}

func newLineWriter(o: in JOutputStream): JPrintWriter {
  // autoFlush = true: every println() flushes immediately, matching the
  // .NET kernel's `AutoFlush = true` on its StreamWriter. Intermediate
  // `val` (not a nested `X.new(Y.new(z))` constructor call) for the same
  // reason every other kernel in this tree binds constructor results to a
  // named local before passing them on.
  val osw: JOutputStreamWriter = JOutputStreamWriter.new(o)
  JPrintWriter.new(osw, true)
}

func writerPrintln(w: in JPrintWriter, s: in String): Unit {
  w.println(s)
}

func procIsAlive(p: in JProcess): Bool {
  p.isAlive()
}

// Tail-position instance call whose declared return type (Unit) discards
// `destroyForcibly()`'s `Process` result — matches `_kernel_jvm/process_host.l`'s
// documented reason for writing `hostWait` as a single tail expression rather
// than `proc.destroyForcibly(); ()` (a discarded *non-tail* auto-FFI instance
// call whose receiver traces back to a parameter emits no invoke instruction
// at all on this backend, issue #5379; tail position is unaffected).
func procDestroyForcibly(p: in JProcess): Unit {
  p.destroyForcibly()
}

func procExitValue(p: in JProcess): Int {
  p.exitValue()
}

// ── Byte-level line buffer (see module header) ────────────────────────────────
// Drain however many bytes are currently available on `stream` into `acc`
// without blocking — identical technique to
// `process_capture_host.l`'s `drainAvailable`, including the same
// stream-closed-after-kill tolerance.
func drainAvailableInto(stream: in JInputStream, acc: in JBAOS): Unit {
  try {
    val avail = stream.available()
    if avail > 0 {
      val chunk = stream.readNBytes(avail)
      acc.write(chunk)
    }
  } catch Bug as _ {
    ()
  }
}

// Index of the first `\n` (0x0A) in `bytes`, or -1 when absent.
func indexOfNewline(bytes: in slice[Byte]): Int {
  var i = 0
  while i < bytes.length {
    if bytes[i] == 10 {
      return i
    }
    i = i + 1
  }
  -1
}

// Decode `bytes[0, endExclusive)` as UTF-8 text, stripping a trailing `\r`
// immediately before the cut point (BufferedReader.readLine()'s CRLF
// convention). Malformed UTF-8 surfaces as a deterministic diagnostic
// string (byte count) rather than silently dropping the line — a piped
// peer sending invalid UTF-8 is itself a real (if unusual) condition the
// caller should be able to observe, not a mysteriously vanished line.
func decodeLine(bytes: in slice[Byte], endExclusive: in Int): String {
  var cut = endExclusive
  if cut > 0 and bytes[cut - 1] == 13 {
    cut = cut - 1
  }
  val acc: List[Byte] = newList()
  var i = 0
  while i < cut {
    acc.add(bytes[i])
    i = i + 1
  }
  val lineBytes: slice[Byte] = acc.toArray()
  match tryDecodeUtf8(lineBytes) {
    case Some(s) -> s
    case None -> "<invalid utf-8 line: " + cut.toString() + " bytes>"
  }
}

// Remaining bytes after the consumed line (and its terminator) — rebuilds
// the leftover tail as a fresh `slice[Byte]` for `resetBufferTo`.
func remainderAfter(bytes: in slice[Byte], newlineIdx: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = newlineIdx + 1
  while i < bytes.length {
    acc.add(bytes[i])
    i = i + 1
  }
  acc.toArray()
}

// Replace `acc`'s contents with `remaining` in place (no field
// reassignment needed on the record holding it — `reset()` then `write()`
// mutate the same `ByteArrayOutputStream` object).
func resetBufferTo(acc: in JBAOS, remaining: in slice[Byte]): Unit {
  acc.reset()
  if remaining.length > 0 {
    acc.write(remaining)
  }
}

// ── Public handle + entry points ───────────────────────────────────────────
/// Opaque handle to a running child process with piped stdin/stdout.
pub record PipedHandle {
  proc: JProcess
  writer: JPrintWriter
  stdout: JInputStream
  lineBuf: JBAOS
}

/// Spawn `fileName` with a pre-formed `arguments` string (see
/// `Std.Process.buildArgString`), redirecting stdin and stdout; stderr is
/// inherited (see module doc). Panics (`Bug`) if the executable cannot be
/// found or the OS rejects the spawn — `Std.Process.spawnPiped` catches
/// this and maps it to `IOError`.
pub func hostSpawnPiped(fileName: in String, arguments: in String): PipedHandle {
  val cmdList = parseArgString(fileName, arguments)
  val pb = buildProcessBuilder(cmdList)
  val proc = procStart(pb)
  val writer = newLineWriter(procStdin(proc))
  val stdout = procStdout(proc)
  PipedHandle(proc = proc, writer = writer, stdout = stdout, lineBuf = JBAOS.new())
}

// Option seam avoiding `case null`'s catch-all miscompile (#4775); NUL-marker
// mirrors `console_host.l`'s `hostReadLineOpt`. Blocks (polling, never a
// blocking JDK call — see module header) until a complete line is
// available, the process exits with a final unterminated remainder, or
// the process exits with nothing left to read.
pub func hostPipedReadLineOpt(p: in PipedHandle): Option[String] {
  var done = false
  var result: Option[String] = None
  while not done {
    val snapshot: slice[Byte] = p.lineBuf.toByteArray()
    val nl = indexOfNewline(snapshot)
    if nl >= 0 {
      val line = decodeLine(snapshot, nl)
      resetBufferTo(p.lineBuf, remainderAfter(snapshot, nl))
      result = Some(value = line)
      done = true
    } else {
      drainAvailableInto(p.stdout, p.lineBuf)
      val grew: slice[Byte] = p.lineBuf.toByteArray()
      if grew.length > snapshot.length {
        // New bytes arrived — loop straight back to the newline scan
        // without sleeping.
        ()
      } else if procIsAlive(p.proc) {
        JThread.sleep(intToLong(1))
      } else {
        // Process has exited. One more drain in case bytes were flushed
        // between the `isAlive` check above and here (mirrors
        // `process_capture_host.l`'s post-loop final drain).
        drainAvailableInto(p.stdout, p.lineBuf)
        val final_: slice[Byte] = p.lineBuf.toByteArray()
        val nl2 = indexOfNewline(final_)
        if nl2 >= 0 {
          val line = decodeLine(final_, nl2)
          resetBufferTo(p.lineBuf, remainderAfter(final_, nl2))
          result = Some(value = line)
        } else if final_.length > 0 {
          val line = decodeLine(final_, final_.length)
          p.lineBuf.reset()
          result = Some(value = line)
        } else {
          result = None
        }
        done = true
      }
    }
  }
  result
}

/// Write one line to the child's stdin (a trailing newline is appended and
/// the write is flushed immediately — `autoFlush` is set at spawn time).
pub func hostPipedWriteLine(p: in PipedHandle, line: in String): Unit {
  writerPrintln(p.writer, line)
}

/// True while the child process has not yet exited.
pub func hostPipedIsAlive(p: in PipedHandle): Bool {
  procIsAlive(p.proc)
}

/// Forcibly terminate the child process. Swallows any failure (e.g. the
/// process already exited) — safe to call unconditionally.
pub func hostPipedKill(p: in PipedHandle): Unit {
  try {
    procDestroyForcibly(p.proc)
  } catch Bug as _ {
    ()
  }
}

/// Block up to `timeoutMs` milliseconds for the child to exit (polls
/// `isAlive()` with a 1ms sleep between checks — see module doc). Returns
/// `true` if it exited within the deadline.
pub func hostPipedWaitExit(p: in PipedHandle, timeoutMs: in Int): Bool {
  val startMs = currentTimeMillis()
  val timeoutMsL = intToLong(timeoutMs)
  var exited = not procIsAlive(p.proc)
  while not exited and (currentTimeMillis() - startMs) < timeoutMsL {
    JThread.sleep(intToLong(1))
    exited = not procIsAlive(p.proc)
  }
  exited
}

/// The child's OS exit code. Only meaningful after `hostPipedIsAlive`
/// reports `false` (or `hostPipedWaitExit` returned `true`).
pub func hostPipedExitCode(p: in PipedHandle): Int {
  try {
    procExitValue(p.proc)
  } catch Bug as _ {
    -1
  }
}

func writerClose(w: in JPrintWriter): Unit {
  w.close()
}

func streamClose(s: in JInputStream): Unit {
  s.close()
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

/// Close the child's stdin/stdout pipes and release the OS process
/// resources. Does not itself wait for or kill the child. Swallows
/// failures so it is safe to call during best-effort cleanup.
pub func hostPipedClose(p: in PipedHandle): Unit {
  try {
    writerClose(p.writer)
  } catch Bug as _ {
    ()
  }
  try {
    streamClose(p.stdout)
  } catch Bug as _ {
    ()
  }
}
