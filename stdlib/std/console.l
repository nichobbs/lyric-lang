// std/console.l - safe console IO.
//
// Console output is treated as a best-effort effect and keeps the
// simple Unit-returning shape from the language examples. Console input
// is fallible: EOF and host failures are surfaced as Result values so
// application code does not need to catch Bug at ordinary call sites.

@runtime_checked
package Std.Console

import Std.Errors
import System.Console as HostConsole

/// Write a string to stdout without appending a newline.
///
/// Console output is intentionally best-effort in Phase 3 and returns
/// Unit. Applications that need durable logging should use the future
/// logging/file APIs, which expose write failures as Result values.
@stable(since="1.0")
pub func print(s: in String): Unit {
  HostConsole.write(s)
}

/// Write a string to stdout followed by the platform newline.
///
/// See `print` for the output-failure policy.
@stable(since="1.0")
pub func println(s: in String): Unit {
  HostConsole.writeLine(s)
}

/// Write a string to stderr followed by the platform newline.
///
/// Intended for diagnostics and simple command-line tools. Structured
/// logging belongs in the Phase 5 logging package.
@stable(since="1.0")
pub func error(s: in String): Unit {
  HostConsole.errorWriteLine(s)
}

/// Read one line from stdin, excluding the trailing newline.
///
/// # Errors
/// - `EndOfInput("stdin")`: EOF before a line is available.
/// - `IoError("stdin", message)`: host console read failure.
///
/// EOF is not a Bug. Host exceptions are caught only here, at the
/// stdlib boundary, and normalized to `IOError`.
@stable(since="1.0")
pub func readLine(): Result[String, IOError] {
  return try {
    match HostConsole.readLine() {
      case null -> Err(error = EndOfInput(source = "stdin"))
      case line -> Ok(value = line)
    }
  } catch Bug as b {
    Err(error = IoError(path = "stdin", message = b.message))
  }
}

// Future: foreground(color), background(color), reset, bold, dim,
// italic, and capability checks such as isColorSupported. These belong
// behind an explicit terminal capability API rather than ad hoc escape
// string helpers.
