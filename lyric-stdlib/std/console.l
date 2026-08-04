//! std/console.l - safe console IO.
//!
//! Console output is treated as a best-effort effect and keeps the
//! simple Unit-returning shape from the language examples. Console input
//! is fallible: EOF and host failures are surfaced as Result values so
//! application code does not need to catch Bug at ordinary call sites.
@runtime_checked
package Std.Console

import Std.Core
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

// Future: foreground(color), background(color), reset, bold, dim,
// italic, and capability checks such as isColorSupported. These belong
// behind an explicit terminal capability API rather than ad hoc escape
// string helpers.
