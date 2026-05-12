// std/process_capture.l — run a subprocess with piped stdin/stdout.
//
// Thin wrapper over `Std.ProcessCaptureHost`.  Used by the self-hosted
// verifier to invoke z3/cvc5 interactively.

@runtime_checked
package Std.ProcessCapture

import Std.Core
import Std.Collections
import Std.ProcessCaptureHost

// Build a single pre-formed argument string from a list.
// Each argument is quoted if it contains a space or double-quote.
func buildArgString(args: in List[String]): String {
  var result = ""
  var i = 0
  val count = args.count
  while i < count {
    val arg = args[i]
    if i > 0 { result = result + " " }
    if arg.contains(" ") or arg.contains("\"") {
      result = result + "\"" + arg.replace("\"", "\\\"") + "\""
    } else {
      result = result + arg
    }
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
