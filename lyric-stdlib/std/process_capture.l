//! std/process_capture.l — run a subprocess with piped stdin/stdout/stderr.
//!
//! Thin wrapper over `Std.ProcessCaptureHost`.  Used by the self-hosted
//! verifier to invoke z3/cvc5 interactively and by the source-generator
//! runtime to invoke generator DLLs.
@runtime_checked
package Std.ProcessCapture

import Std.Core
import Std.Collections
import Std.ProcessCaptureHost
import Std.String

// Quote a single argument so it round-trips through both the .NET
// `ProcessStartInfo.Arguments` parser and the Windows
// `CommandLineToArgvW` algorithm (CWE-78 / lyric-lang #742).
//
// The previous implementation only escaped `"`, which broke on
// Windows paths containing trailing backslashes:
//
//     ["C:\\evil\\", "--config=safe"]
//
// produced `"C:\evil\" "--config=safe"`, which the Windows CRT parses
// as one argument `C:\evil"` and a second `--config=safe"` — argument
// injection.  CommandLineToArgvW's rule is that inside a quoted span,
// a literal `\` is preserved verbatim *unless* it precedes another `\`
// or `"`, in which case the run of backslashes is doubled and any
// trailing `"` is also `\`-escaped.
//
// #6577 review follow-up: an earlier version of this function did a
// blanket `arg.replace("\\", "\\\\")` — doubling EVERY backslash in the
// argument, not just ones adjacent to a quote or at the very end.  That
// over-corrects: the CommandLineToArgvW decode rule only collapses a
// backslash run that is immediately followed by a `"`; a run followed
// by any other character passes through completely unchanged (not
// halved).  So a blanket-doubled backslash that isn't adjacent to a
// quote survives the round trip AS TWO backslashes instead of the
// original ONE — real corruption, not just an over-escape — for any
// argument containing a backslash used for something other than a
// Windows path (e.g. a shell command string embedding a `printf`
// octal escape like `\377`, discovered via `process_capture_tests.l`'s
// `testDiagnosticsStdoutBytesInvalidUtf8`).  This implementation only
// doubles a backslash run when it is immediately followed by `"` (an
// embedded quote — doubled + one more backslash so the quote is
// escaped, not a terminator) or sits at the very end of the argument
// (immediately followed by the closing wrapper `"` this function adds)
// — the same canonical encoder every faithful CommandLineToArgvW
// quoting implementation uses.  Backslashes anywhere else are copied
// through unchanged, since the decoder does the same.
// Exposed `pub` so callers building command lines piecemeal (outside
// `buildArgString`) can reuse the same escape ordering.
@stable(since = "1.0")
pub func quoteArg(arg: in String): String {
  var acc = "\""
  var i = 0
  val n = arg.length
  while i < n {
    val ch = arg.substring(i, 1)
    if ch == "\\" {
      var numBackslashes = 0
      while i < n and arg.substring(i, 1) == "\\" {
        numBackslashes += 1
        i += 1
      }
      if i == n {
        // Trailing backslash run: immediately followed by the closing
        // `"` this function appends below, so it must be doubled.
        acc = acc + repeat("\\", numBackslashes * 2)
      } else if arg.substring(i, 1) == "\"" {
        // Backslash run immediately before a literal quote: 2N+1
        // backslashes then the quote, so the decoder sees N literal
        // backslashes followed by an escaped (non-terminating) `"`.
        acc = acc + repeat("\\", numBackslashes * 2 + 1) + "\""
        i += 1
      } else {
        // Backslash run followed by an ordinary character: the decoder
        // passes these through unchanged, so this encoder must too.
        acc = acc + repeat("\\", numBackslashes)
      }
    } else if ch == "\"" {
      acc = acc + "\\\""
      i += 1
    } else {
      acc = acc + ch
      i += 1
    }
  }
  acc + "\""
}

// Build a single pre-formed argument string from a list.  Every
// argument is wrapped in `"..."` with backslash + quote escaping so
// the receiving process re-tokenises identically on POSIX and Windows.
@stable(since = "1.0")
pub func buildArgString(args: in List[String]): String {
  var result = ""
  var i = 0
  val count = args.count
  while i < count {
    if i > 0 {
      result = result + " "
    }
    result = result + quoteArg(args[i])
    i = i + 1
  }
  result
}

// Full diagnostic result returned by `runCaptureWithDiagnostics`.
// `stdout` and `stderr` are the complete captured text from the child
// process, UTF-8-decoded.  `stdoutBytes` and `stderrBytes` are the exact
// raw bytes the child wrote, captured directly from the drain buffer
// before that decode — use these instead of re-encoding `stdout`/`stderr`
// whenever the caller needs a byte-exact result (e.g. hashing downloaded
// content), since a decode/re-encode round trip is lossy for output that
// is not valid UTF-8 (#4753).  `exitCode` is the process exit code (-1 on
// spawn failure, -2 when the process was killed after the wall-clock
// timeout).  `timedOut` is true when the 10-second cap fired and the
// process was killed before it could exit normally.
@stable(since = "1.0")
pub record CaptureResult {
  stdout: String
  stderr: String
  stdoutBytes: slice[Byte]
  stderrBytes: slice[Byte]
  exitCode: Int
  timedOut: Bool
}

/// Spawn `executable` with `args`, write `stdinContent` to its stdin,
/// and return the captured stdout.  Returns `""` on spawn failure.
///
/// Stderr from the child process is silently discarded; use
/// `runCaptureWithDiagnostics` to capture it (along with exit code and
/// timeout status) when callers need to distinguish process failures
/// from empty output or surface diagnostic text.  Spawn failure
/// (executable not found, permission denied, etc.) is also silently
/// absorbed and surfaces as an empty string — `runCaptureWithDiagnostics`
/// reports it via `exitCode == -1` instead (#743).
@stable(since = "1.0")
pub func runCapture(executable: in String, args: in List[String], stdinContent: in String): String {
  val argStr = buildArgString(args)
  val result = hostRunCapture(executable, argStr, stdinContent)
  pcResultStdout(result)
}

/// Spawn `executable` with `args`, write `stdinContent` to its stdin,
/// and return a `CaptureResult` with stdout, stderr, exit code, and
/// whether the process timed out (#1025).  Use this instead of
/// `runCapture` when the caller needs to surface diagnostic information
/// on failure (generator errors, solver stderr, etc.).
@stable(since = "1.0")
pub func runCaptureWithDiagnostics(executable: in String, args: in List[String], stdinContent: in String): CaptureResult {
  val argStr = buildArgString(args)
  val raw = hostRunCapture(executable, argStr, stdinContent)
  CaptureResult(
    stdout = pcResultStdout(raw),
    stderr = pcResultStderr(raw),
    stdoutBytes = pcResultStdoutBytes(raw),
    stderrBytes = pcResultStderrBytes(raw),
    exitCode = pcResultExitCode(raw),
    timedOut = pcResultTimedOut(raw)
  )
}

/// Spawn `executable` with `args`, write `stdinContent` to its stdin,
/// and return a `CaptureResult` with stdout, stderr, exit code, and
/// whether the process timed out.  Like `runCaptureWithDiagnostics` but
/// with a caller-supplied `timeoutMs` wall-clock cap instead of the
/// default 10-second cap.  Use for long-running subprocesses such as
/// test suite execution or build invocations.
@stable(since = "1.0")
pub func runCaptureWithDiagnosticsTimeout(
  executable: in String,
  args: in List[String],
  stdinContent: in String,
  timeoutMs: in Int,
): CaptureResult {
  val argStr = buildArgString(args)
  val raw = hostRunCaptureTimeout(executable, argStr, stdinContent, timeoutMs)
  CaptureResult(
    stdout = pcResultStdout(raw),
    stderr = pcResultStderr(raw),
    stdoutBytes = pcResultStdoutBytes(raw),
    stderrBytes = pcResultStderrBytes(raw),
    exitCode = pcResultExitCode(raw),
    timedOut = pcResultTimedOut(raw)
  )
}
