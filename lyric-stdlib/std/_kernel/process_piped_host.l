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
//! **Bounded reads (#7451).** `StreamReader.ReadLine()` has no timeout, so
//! `hostPipedReadLineWithinResult` runs the blocking `ReadLine()` on its own
//! long-running thread (`Task.Factory.StartNew(Action,
//! TaskCreationOptions.LongRunning)`, #7520 review — plain `Task.Run` schedules on
//! the shared thread-pool queue, where pool pressure from unrelated work can
//! delay the blocking read from even starting, which then makes a short
//! `Task.Wait(ms)` report a spurious timeout even though nothing is actually
//! stuck; `LongRunning` tells the scheduler to give the work a dedicated
//! thread instead of a pool slot) and waits for it with `Task.Wait(int)`,
//! which returns `false` on timeout instead of throwing. A read that times
//! out is not abandoned: its `Task` stays on the handle (`inflight`), and
//! the next read of either kind joins it first, so a line that arrives
//! after the deadline is delivered by the next read rather than lost or
//! read out of order. At most one background read is outstanding per
//! handle.
//!
//! Internal: only Std.Process should import this.
@axiom("System.Diagnostics.Process piped stdin/stdout and System.Threading.Tasks.TaskFactory.StartNew/Task.Wait conform to their documented .NET contracts")
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
  // The outstanding background `ReadLine()` (zero or one element) and the
  // result it recorded once complete: `readKind` is 0 for a line (text in
  // `readText`), 1 for end of stream, 2 for a read failure (message in
  // `readText`). Written only by the background task before it completes and
  // read only after `taskWaitMs` observed completion.
  inflight: List[Task]
  readKind: List[Int]
  readText: List[String]
}

/// Outcome of a bounded read (`hostPipedReadLineWithinResult`).
pub union HostPipedRead {
  case HostPipedLine(line: String)
  case HostPipedEof
  case HostPipedTimedOut
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
  PipedHandle(proc = proc, writer = w, reader = r, inflight = newList(), readKind = newList(), readText = newList())
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

// ── Result seams for Std.Process (#6887) ─────────────────────────────────────
// `Std.Process.spawnPiped`/`pipedReadLine`/`pipedWriteLine` delegate here.
// The host throws on a failed spawn, read or write; the try/catch lives in
// the kernel because `--target native` has no unwinding (D-N-003) and its
// twin reports the same failures as return codes instead.
pub func hostSpawnPipedResult(fileName: in String, args: in List[String]): Result[PipedHandle, IOError] {
  try {
    Ok(value = hostSpawnPiped(fileName, argvJoin(args)))
  } catch Bug as b {
    Err(error = IoError(path = fileName, message = b.message))
  }
}

// An unbounded read first joins a background read left outstanding by a
// timed-out `hostPipedReadLineWithinResult`, so lines stay in order.
pub func hostPipedReadLineResult(p: in PipedHandle): Result[Option[String], String] {
  try {
    if p.inflight.count > 0 {
      match joinBackgroundRead(p, 0 - 1) {
        case None -> Err(error = "background read did not complete")
        case Some(r) -> match r {
          case Err(e) -> Err(error = e)
          case Ok(outcome) -> match outcome {
            case HostPipedLine(line) -> Ok(value = Some(value = line))
            case HostPipedEof -> Ok(value = None)
            case HostPipedTimedOut -> Err(error = "background read did not complete")
          }
        }
      }
    } else {
      Ok(value = hostPipedReadLineOpt(p))
    }
  } catch Bug as b {
    Err(error = b.message)
  }
}

// Start the background `ReadLine()` unless one is already outstanding.
func ensureBackgroundRead(p: in PipedHandle): Unit {
  if p.inflight.count > 0 {
    return
  }
  val h = p
  val work: () -> Unit = { ->
    try {
      match hostPipedReadLineOpt(h) {
        case Some(line) -> {
          h.readText.add(line)
          h.readKind.add(0)
        }
        case None -> {
          h.readText.add("")
          h.readKind.add(1)
        }
      }
    } catch Bug as b {
      h.readText.add(b.message)
      h.readKind.add(2)
    }
  }
  p.inflight.add(taskRun(work))
}

// Wait up to `ms` (`-1`: without a bound) for the outstanding background
// read. `None` on timeout (the read stays outstanding); otherwise the read's
// result, and the handle is ready for the next read.
func joinBackgroundRead(p: in PipedHandle, ms: in Int): Option[Result[HostPipedRead, String]] {
  if not taskWaitMs(p.inflight[0], ms) {
    return None
  }
  val kind = p.readKind[0]
  val text = p.readText[0]
  p.inflight.clear()
  p.readKind.clear()
  p.readText.clear()
  if kind == 0 {
    Some(value = Ok(value = HostPipedLine(line = text)))
  } else if kind == 1 {
    Some(value = Ok(value = HostPipedEof))
  } else {
    Some(value = Err(error = text))
  }
}

/// Read one line, waiting at most `timeoutMs` milliseconds (see the module
/// doc for how a timed-out read is resumed).
pub func hostPipedReadLineWithinResult(p: in PipedHandle, timeoutMs: in Int): Result[HostPipedRead, String] {
  try {
    ensureBackgroundRead(p)
    match joinBackgroundRead(p, timeoutMs) {
      case None -> Ok(value = HostPipedTimedOut)
      case Some(r) -> r
    }
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
