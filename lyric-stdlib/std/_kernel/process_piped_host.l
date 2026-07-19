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
//! Internal: only Std.Process should import this.
@axiom("System.Diagnostics.Process piped stdin/stdout conforms to its documented .NET contracts")
package Std.ProcessPipedHost

import Std.Core

// ── BCL extern types ───────────────────────────────────────────────────────
extern type Psi = "System.Diagnostics.ProcessStartInfo"

extern type Proc = "System.Diagnostics.Process"

extern type ProcWriter = "System.IO.StreamWriter"

extern type ProcReader = "System.IO.StreamReader"

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

func writerSetAutoFlush(w: in ProcWriter, v: in Bool): Unit {
  w.AutoFlush = v
}

func writerWriteLine(w: in ProcWriter, s: in String): Unit {
  w.WriteLine(s)
}

func writerClose(w: in ProcWriter): Unit {
  w.Close()
}

// Nullable-return instance call: `StreamReader.ReadLine()` returns `null` at
// EOF. Plain auto-FFI instance dispatch has no null-return convention for a
// declared `String?` result — mirrors `console_host.l`'s
// `hostConsoleReadLine` (`System.Console.ReadLine`), the same "returns null
// at EOF" contract, one level down (a real stream instead of the console).
@externInstance
@externTarget("System.IO.StreamReader.ReadLine")
func readerReadLine(r: in ProcReader): String? = ()

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

// ── Public handle + entry points ───────────────────────────────────────────
/// Opaque handle to a running child process with piped stdin/stdout.
pub record PipedHandle {
  proc: Proc
  writer: ProcWriter
  reader: ProcReader
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
  val r = procStdoutReader(proc)
  PipedHandle(proc = proc, writer = w, reader = r)
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
/// the write is flushed immediately — `AutoFlush` is set at spawn time).
pub func hostPipedWriteLine(p: in PipedHandle, line: in String): Unit {
  writerWriteLine(p.writer, line)
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
