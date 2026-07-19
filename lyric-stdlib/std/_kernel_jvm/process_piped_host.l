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
//! `BufferedReader.readLine()`'s `null`-at-EOF contract is read directly
//! via plain auto-FFI (no `@externTarget` needed) — the same pattern
//! `_kernel_jvm/console_host.l`'s `hostConsoleReadLine` already uses for
//! `BufferedReader.readLine()` on stdin.
//!
//! `Process.waitFor()` has no timeout-friendly overload reachable via
//! auto-FFI (see above), so `hostPipedWaitExit` polls `isAlive()` with a
//! 1ms sleep between checks, the same technique
//! `process_capture_host.l`'s `runImpl` uses.
//!
//! **Known gap (JVM only, real and unresolved — not a stub): the read
//! side of a live bidirectional pipe does not reliably deliver a line
//! back to the parent.** `spawnPiped`/`pipedWriteLine`/`pipedIsAlive`
//! all behave correctly (the child spawns, stays alive, and the write
//! call raises no error), but a subsequent `pipedReadLine` against a
//! process that is still both alive and has real bytes queued on its
//! stdout sometimes returns a spurious immediate `None` (as if EOF) and
//! sometimes blocks past any reasonable deadline — reproduced with the
//! simplest possible child (`cat`, no arguments, one short line written
//! then read back) using both `lyric-mcp/tests/mcp_stdio_process_tests.l`
//! (excluded from the JVM target via `@cfg(target = "dotnet")` — see its
//! header) and an isolated `Std.Process`-only repro outside this
//! library. Two specific candidate causes were investigated and ruled
//! out by direct experiment: (1) the `redirectError(Redirect.INHERIT)`
//! call above interfering with the stdout redirect — removing it
//! entirely did not change the symptom; (2) the nested
//! `JBufferedReader.new(JInputStreamReader.new(i))` / `JPrintWriter.new
//! (JOutputStreamWriter.new(o), true)` constructor calls — rebinding
//! each inner `.new()` result to an explicit intermediate `val` (as
//! `newLineReader`/`newLineWriter` do below, matching every other
//! kernel's convention) changed the observed failure mode from
//! "always spurious immediate EOF" to "sometimes blocks," but did not
//! fix it. `Std.Process.spawnPiped`'s batch counterpart,
//! `hostRunCapture`'s `available()`-polled `InputStream`/
//! `ByteArrayOutputStream` drain in `process_capture_host.l`, is known
//! to work reliably on this exact JDK — a byte-level rewrite of the read
//! side along those lines (instead of `BufferedReader`) is the most
//! promising next step, tracked as a follow-up rather than attempted
//! here. **The `.NET` kernel (`_kernel/process_piped_host.l`) has no such
//! issue** — `spawnPiped` and `pipedReadLine`/`pipedWriteLine` round-trip
//! correctly and repeatably, verified by `mcp_stdio_process_tests.l` on
//! `--target dotnet`.
//!
//! Internal: only Std.Process should import this.
@axiom("java.lang.ProcessBuilder + java.lang.Process piped stdin/stdout conform to their documented JVM contracts")
package Std.ProcessPipedHost

import Std.Core
import Std.Collections
import Std.Math
import Std.ProcessCaptureHost

// ── JDK extern types ──────────────────────────────────────────────────────────
extern type JProcessBuilder = "java.lang.ProcessBuilder"

extern type JRedirect = "java.lang.ProcessBuilder$Redirect"

extern type JProcess = "java.lang.Process"

extern type JOutputStream = "java.io.OutputStream"

extern type JInputStream = "java.io.InputStream"

extern type JInputStreamReader = "java.io.InputStreamReader"

extern type JOutputStreamWriter = "java.io.OutputStreamWriter"

extern type JBufferedReader = "java.io.BufferedReader"

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

func newLineReader(i: in JInputStream): JBufferedReader {
  val isr: JInputStreamReader = JInputStreamReader.new(i)
  JBufferedReader.new(isr)
}

func writerPrintln(w: in JPrintWriter, s: in String): Unit {
  w.println(s)
}

// Named helper (not `p.reader.readLine()` chained directly off a record
// field read) — matches every other instance call in this kernel (and
// `process_capture_host.l`'s convention) of binding the extern-typed
// receiver through a plain function parameter rather than a field-access
// chain.
func readerReadLine(r: in JBufferedReader): String? {
  r.readLine()
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

// ── Public handle + entry points ───────────────────────────────────────────
/// Opaque handle to a running child process with piped stdin/stdout.
pub record PipedHandle {
  proc: JProcess
  writer: JPrintWriter
  reader: JBufferedReader
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
  val reader = newLineReader(procStdout(proc))
  PipedHandle(proc = proc, writer = writer, reader = reader)
}

// Option seam avoiding `case null`'s catch-all miscompile (#4775); NUL-marker
// mirrors `console_host.l`'s `hostReadLineOpt`.
pub func hostPipedReadLineOpt(p: in PipedHandle): Option[String] {
  val v = readerReadLine(p.reader) ?? "\u{0000}"
  if v == "\u{0000}" {
    None
  } else {
    Some(value = v)
  }
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

func readerClose(r: in JBufferedReader): Unit {
  r.close()
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
    readerClose(p.reader)
  } catch Bug as _ {
    ()
  }
}
