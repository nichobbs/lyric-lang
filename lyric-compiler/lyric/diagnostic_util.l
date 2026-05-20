// Shared diagnostic-printing helpers used by both `Msil.Bridge` and
// `Jvm.Bridge` (#827).  These mirror the textual diagnostic format the
// F# bootstrap uses for build-time errors (`severity[code] line:col:
// message`) so the self-hosted bridges produce output indistinguishable
// from the F# fallback path.
//
// Wrapper names in the bridges are deliberately distinct from this
// package's exports — the bootstrap call resolver shadows a
// fully-qualified call to `DiagUtil.reportAndAbort()` with the
// enclosing module's same-named symbol, producing infinite recursion
// at runtime (lyric-lang #714 / #830 lesson).  Bridges should import
// this package and define local thin wrappers that delegate.

@runtime_checked
package Lyric.DiagnosticUtil

import Std.Core
import Std.Collections
import Lyric.Lexer

/// Format a single diagnostic as `severity[code] line:col: message`.
@stable(since="0.1")
pub func diagFormat(d: in Diagnostic): String {
  val sev = match d.severity {
    case DiagError   -> "error"
    case DiagWarning -> "warning"
  }
  sev + "[" + d.code + "] " +
    d.span.startPos.line.toString() + ":" +
    d.span.startPos.column.toString() + ": " + d.message
}

/// Print every diagnostic in `diags` to stdout and return true when any
/// of them is error-severity.  Warnings alone do not abort the build.
@stable(since="0.1")
pub func diagReportAndAbort(diags: in List[Diagnostic]): Bool {
  var hasErrors = false
  var i = 0
  while i < diags.count {
    val d = diags[i]
    println(diagFormat(d))
    if d.severity == DiagError { hasErrors = true }
    i = i + 1
  }
  hasErrors
}

/// Print every diagnostic in `diags` to stdout without affecting the
/// compile's success/failure outcome.  Used for typechecker output
/// until Band 6 (cross-package resolution) lands and the typechecker
/// diagnostics become gating.
@stable(since="0.1")
pub func diagReport(diags: in List[Diagnostic]): Unit {
  var i = 0
  while i < diags.count {
    println(diagFormat(diags[i]))
    i = i + 1
  }
}
