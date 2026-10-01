//! std/console.l - safe console IO.
//!
//! Console output is treated as a best-effort effect and keeps the
//! simple Unit-returning shape from the language examples. Console input
//! is fallible: EOF and host failures are surfaced as Result values so
//! application code does not need to catch Bug at ordinary call sites.
@runtime_checked
@io
package Std.Console

import Std.Core
import Std.Collections
import Std.Errors
import Std.ConsoleHost
import Std.String as Str

/// Write a string to stdout without appending a newline.
///
/// Console output is intentionally best-effort in Phase 3 and returns
/// Unit. Applications that need durable logging should use the future
/// logging/file APIs, which expose write failures as Result values.
@stable(since = "1.0")
pub func print(s: in String): Unit {
  hostConsoleWrite(s)
}

/// Write a string to stdout followed by the platform newline.
///
/// See `print` for the output-failure policy.
@stable(since = "1.0")
pub func println(s: in String): Unit {
  hostConsoleWriteLine(s)
}

/// Write a string to stderr followed by the platform newline.
///
/// Intended for diagnostics and simple command-line tools. Structured
/// logging belongs in the Phase 5 logging package.
@stable(since = "1.0")
pub func error(s: in String): Unit {
  hostConsoleErrorWriteLine(s)
}

/// Read one line from stdin, excluding the trailing newline.
///
/// # Errors
/// - `EndOfInput("stdin")`: EOF before a line is available.
/// - `IoError("stdin", message)`: host console read failure.
///
/// EOF is not a Bug. Host exceptions are caught only here, at the
/// stdlib boundary, and normalized to `IOError`.
@stable(since = "1.0")
pub func readLine(): Result[String, IOError] {
  return try {
    match hostReadLineOpt() {
      case Some(line) -> Ok(value = line)
      case None -> Err(error = EndOfInput(source = "stdin"))
    }
  } catch Bug as b {
    Err(error = IoError(path = "stdin", message = b.message))
  }
}

/// Read all remaining stdin as a single string, until EOF.
///
/// Implemented as a loop over `readLine`, joining lines with `"\n"` — this
/// reuses the existing cross-target `readLine`/`hostReadLineOpt` boundary
/// instead of adding a new host primitive, so it needs no kernel changes on
/// either target. Reconstructing by joining (rather than tracking each
/// line's original terminator) means a final line lacking a trailing
/// newline reads back indistinguishably from one that had it — fine for
/// this function's motivating use case (deserializing a JSON payload piped
/// over stdin), where trailing whitespace is insignificant.
///
/// # Errors
/// - `IoError("stdin", message)`: host console read failure. `EndOfInput`
///   is not surfaced as an error here — reaching EOF is how this function
///   knows it is done, not a failure; `Ok("")` is returned for stdin that
///   is already at EOF with no data.
@stable(since = "1.0")
pub func readAll(): Result[String, IOError] {
  val lines: List[String] = newList()
  var err: Option[IOError] = None
  var reading = true
  while reading {
    match readLine() {
      case Ok(line) -> lines.add(line)
      case Err(EndOfInput(_)) -> {
        reading = false
      }
      case Err(e) -> {
        err = Some(value = e)
        reading = false
      }
    }
  }
  match err {
    case Some(e) -> Err(error = e)
    case None -> Ok(value = Str.joinList("\n", lines))
  }
}

// ── Raw stdin bytes with bounded waits (#7451) ──────────────────────────────
/// A byte-level reader over this process's standard input, for protocols
/// that frame their own messages (JSON-RPC over stdio) and must not block
/// without a bound waiting for a peer. It reads stdin directly: do not mix it
/// with `readLine`/`readAll`, and open at most one per process.
///
/// Available on every target; on `--target native` a bounded read polls
/// standard input instead of leaving a background read outstanding, with
/// the same result (see `_kernel_native/console_host.l`).
@stable(since = "1.2")
pub record StdinReader {
  handle: StdinHandle
}

/// Outcome of `readStdinWithin`: the bytes read (never empty), clean end of
/// stream, or nothing within the timeout.
@stable(since = "1.2")
pub union StdinChunk {
  case StdinBytes(bytes: slice[Byte])
  case StdinEnd
  case StdinTimedOut
}

/// Open a byte-level reader over standard input.
@stable(since = "1.2")
pub func openStdinReader(): StdinReader {
  StdinReader(handle = hostOpenStdin())
}

// A host failure is an `IoError`, per this module's input policy.
func stdinChunkOf(r: in Result[HostStdinRead, String]): Result[StdinChunk, IOError] {
  match r {
    case Err(e) -> Err(error = IoError(path = "stdin", message = e))
    case Ok(read) -> match read {
      case HostStdinBytes(bytes) -> Ok(value = StdinBytes(bytes = bytes))
      case HostStdinEof -> Ok(value = StdinEnd)
      case HostStdinTimedOut -> Ok(value = StdinTimedOut)
    }
  }
}

/// Block until stdin yields at least one byte (`Some`) or reaches end of
/// stream (`None`).
///
/// # Errors
/// - `IoError("stdin", message)`: host read failure.
@stable(since = "1.2")
pub func readStdin(r: in StdinReader): Result[Option[slice[Byte]], IOError] {
  match stdinChunkOf(hostStdinReadResult(r.handle)) {
    case Err(e) -> Err(error = e)
    case Ok(chunk) -> match chunk {
      case StdinBytes(bytes) -> Ok(value = Some(value = bytes))
      case _ -> Ok(value = None)
    }
  }
}

/// Wait at most `timeoutMs` milliseconds for stdin to yield bytes. A read
/// that times out loses nothing: bytes that arrive after the deadline are
/// returned, in order, by the next `readStdin`/`readStdinWithin`.
///
/// # Errors
/// - `IoError("stdin", message)`: host read failure.
@stable(since = "1.2")
pub func readStdinWithin(r: in StdinReader, timeoutMs: in Int): Result[StdinChunk, IOError]
  requires: timeoutMs >= 0
{
  stdinChunkOf(hostStdinReadWithinResult(r.handle, timeoutMs))
}

/// Write raw bytes to stdout exactly as given — no text encoding is
/// applied. Pairs with `openStdinReader`/`readStdin` for protocols that
/// frame their own messages over stdio (JSON-RPC's `Content-Length`
/// framing, whose length is defined in UTF-8 bytes, not `String.length`
/// UTF-16 code units — #7510) and must control their exact output bytes
/// rather than going through `print`/`println`'s text writer, which could
/// re-encode. Best-effort, like `print`/`println`: output failures are not
/// surfaced here (see this module's header for the input/output policy).
@stable(since = "1.2")
pub func writeStdoutBytes(bytes: in slice[Byte]): Unit {
  hostConsoleWriteBytes(bytes)
}

// Future: foreground(color), background(color), reset, bold, dim,
// italic, and capability checks such as isColorSupported. These belong
// behind an explicit terminal capability API rather than ad hoc escape
// string helpers.
