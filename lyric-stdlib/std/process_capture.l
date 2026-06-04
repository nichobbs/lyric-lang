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
// Doubling every `\` and escaping every `"` is the canonical safe
// over-encoding: e.g. `C:\dir\` → `"C:\\dir\\"` → CRT decodes back to
// `C:\dir\`.  Over-escaping is harmless on POSIX (single tokens never
// reach this path because the .NET `ProcessStartInfo` does its own
// re-tokenisation), and the alternative — only doubling runs that
// precede `"` — is harder to get right.
// Exposed `pub` so callers building command lines piecemeal (outside
// `buildArgString`) can reuse the same escape ordering.
@stable(since = "1.0")
pub func quoteArg(arg: in String): String {
  // Order matters: escape backslashes first so the `\` introduced by
  // the second step don't get double-escaped.
  val escaped = arg.replace("\\", "\\\\").replace("\"", "\\\"")
  "\"" + escaped + "\""
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
// process.  `exitCode` is the process exit code (-1 on spawn failure,
// -2 when the process was killed after the wall-clock timeout).
// `timedOut` is true when the 10-second cap fired and the process was
// killed before it could exit normally.
@stable(since = "1.0")
pub record CaptureResult {
  stdout: String
  stderr: String
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
    exitCode = pcResultExitCode(raw),
    timedOut = pcResultTimedOut(raw)
  )
}
