// lint_bridge.l — text-protocol bridge for the F# SelfHostedLint.fs shim.
// Wraps Lyric.Lint.lint and serialises the result to a line-oriented protocol
// so the F# shim can reconstruct the LintResult record without CLR reflection
// on Lyric union types.
//
// Protocol:
//   One diag per line (empty string if no diagnostics):
//     <code>|<sev>|<line>|<col>|<message>
//   where <sev> is "error" or "warning".
package Lyric.LintBridge

import Std.Core
import Std.Collections
import Lyric.Lint

pub func lintToProtocol(source: in String): String {
  val diags = lint(source)
  if diags.count == 0 { return "" }
  var s = ""
  var i = 0
  while i < diags.count {
    val d = diags[i]
    val sev = match d.severity {
      case LintError   -> "error"
      case LintWarning -> "warning"
    }
    val line = toString(d.span.startPos.line)
    val col  = toString(d.span.startPos.column)
    if i > 0 { s = s + "\n" }
    s = s + d.code + "|" + sev + "|" + line + "|" + col + "|" + d.message
    i = i + 1
  }
  s
}
