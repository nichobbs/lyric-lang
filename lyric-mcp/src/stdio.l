//! src/stdio.l — Mcp.Stdio: piped-child-process stdio transport (client side).
//!
//! `JsonRpc.Stdio`'s `NdjsonTransport` frames NDJSON over the *current*
//! process's own stdin/stdout (`Std.Console`/`Std.ConsoleHost`) — the
//! shape a server needs. A client instead needs to frame NDJSON over a
//! *spawned child's* piped stdin/stdout (docs/62-jsonrpc-mcp.md §5.2), so
//! this module supplies its own `RpcTransport`, `PipedNdjsonTransport`,
//! built the same sans-IO way `JsonRpc.Stdio` is: it implements the
//! `LineReader`/`LineWriter` seams over `Std.Process.PipedProcess` and
//! reuses `JsonRpc.Stdio.ndjsonReceiveVia`/`ndjsonSendVia` for the actual
//! framing rather than re-implementing it. `receiveWithin` (#7451) reads
//! through `Std.Process.pipedReadLineWithin`, so a client call to a server
//! that never answers ends at its deadline.
@runtime_checked
@io
package Mcp.Stdio

import Std.Core
import Std.Collections
import Std.Errors
import Std.Process
import JsonRpc
import JsonRpc.Stdio

// ── Sans-IO seam over a piped child process ─────────────────────────────────
record PipedLineReader {
  proc: PipedProcess
}

impl LineReader for PipedLineReader {
  func nextLine(): Result[String, IOError] {
    match pipedReadLine(self.proc) {
      case Err(e) -> Err(error = IoError(path = "child stdout", message = e))
      case Ok(None) -> Err(error = EndOfInput(source = "child stdout"))
      case Ok(Some(line)) -> Ok(value = line)
    }
  }
}

record PipedLineWriter {
  proc: PipedProcess
}

impl LineWriter for PipedLineWriter {
  func writeLine(s: in String): Unit {
    match pipedWriteLine(self.proc, s) {
      case Ok(_) -> ()
      case Err(e) -> panic("Mcp.Stdio: write to child stdin failed: " + e)
    }
  }
}

// ── RpcTransport over the child's piped stdio ───────────────────────────────
@stable(since = "0.1")
pub record PipedNdjsonTransport {
  proc: PipedProcess
}

impl RpcTransport for PipedNdjsonTransport {
  func receive(): Result[Option[String], String] {
    ndjsonReceiveVia(PipedLineReader(proc = self.proc))
  }

  // A timed-out read leaves any partial line buffered in the child's piped
  // handle (`Std.Process.pipedReadLineWithin`), so the next receive returns
  // it whole.
  func receiveWithin(timeoutMs: in Int): Result[ReceiveOutcome, String] {
    match pipedReadLineWithin(self.proc, timeoutMs) {
      case Err(e) -> Err(error = "child stdout: " + e)
      case Ok(outcome) -> match outcome {
        case PipedLine(line) -> match ndjsonAcceptLine(line) {
          case Ok(accepted) -> Ok(value = RpcMessage(text = accepted))
          case Err(e) -> Err(error = e)
        }
        case PipedEndOfStream -> Ok(value = RpcEndOfStream)
        case PipedTimedOut -> Ok(value = RpcTimedOut)
      }
    }
  }

  func send(payload: in String): Result[Unit, String] {
    ndjsonSendVia(payload, PipedLineWriter(proc = self.proc))
  }

  func close(): Unit {
    pipedKill(self.proc)
    // Give the killed child a moment to actually exit before releasing the
    // OS process handle; the boolean result is not otherwise needed here.
    pipedWaitExit(self.proc, 2000)
    pipedClose(self.proc)
  }
}

/// Spawn `command args...` and wrap its piped stdin/stdout in an
/// `RpcTransport` speaking NDJSON — the MCP stdio transport, client side.
@stable(since = "0.1")
pub func newPipedNdjsonTransport(command: in String, args: in List[String]): Result[PipedNdjsonTransport, String] {
  match spawnPiped(command, args) {
    case Err(e) -> Err(error = IOError.message(e))
    case Ok(p) -> Ok(value = PipedNdjsonTransport(proc = p))
  }
}
