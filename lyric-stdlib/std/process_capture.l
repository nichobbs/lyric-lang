// std/process_capture.l — run a subprocess with piped stdin/stdout.
//
// Thin wrapper over `Std.ProcessCaptureHost`.  Used by the self-hosted
// verifier to invoke z3/cvc5 interactively.

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
@stable(since="1.0")
pub func quoteArg(arg: in String): String {
  // Order matters: escape backslashes first so the `\` introduced by
  // the second step don't get double-escaped.
  val escaped = arg.replace("\\", "\\\\").replace("\"", "\\\"")
  "\"" + escaped + "\""
}

// Build a single pre-formed argument string from a list.  Every
// argument is wrapped in `"..."` with backslash + quote escaping so
// the receiving process re-tokenises identically on POSIX and Windows.
@stable(since="1.0")
pub func buildArgString(args: in List[String]): String {
  var result = ""
  var i = 0
  val count = args.count
  while i < count {
    if i > 0 { result = result + " " }
    result = result + quoteArg(args[i])
    i = i + 1
  }
  result
}

/// Spawn `executable` with `args`, write `stdinContent` to its stdin,
/// and return the captured stdout.  Returns `""` on spawn failure.
@stable(since="1.0")
pub func runCapture(executable: in String, args: in List[String], stdinContent: in String): String {
  val argStr = buildArgString(args)
  hostRunCapture(executable, argStr, stdinContent)
}
