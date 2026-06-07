//! Shared diagnostic-printing helpers used by both `Msil.Bridge` and
//! `Jvm.Bridge`.  These mirror the textual diagnostic format the F#
//! bootstrap uses for build-time errors (`severity[code] line:col:
//! message`) so the self-hosted bridges produce output indistinguishable
//! from the F# fallback path.
//!
//! Diagnostics are written to stderr to match the convention the F#
//! bootstrap CLI established (and that IDE integrations, CI scripts,
//! and `2>errors.txt` redirects rely on).
//!
//! Wrapper names in the bridges are deliberately distinct from this
//! package's exports — the bootstrap call resolver shadows a
//! fully-qualified call to `DiagUtil.reportAndAbort()` with the
//! enclosing module's same-named symbol, producing infinite recursion
//! at runtime.  Bridges should import this package and define local
//! thin wrappers that delegate.
@runtime_checked
package Lyric.DiagnosticUtil

import Std.Core
import Std.Collections
import Std.Console as Console
import Lyric.Lexer

/// Format a single diagnostic as `severity[code] line:col: message`.
@stable(since = "0.1")
pub func diagFormat(d: in Diagnostic): String {
  val sev = match d.severity { case DiagError -> "error"; case DiagWarning -> "warning" }
  sev + "[" + d.code + "] " + d.span.startPos.line.toString() + ":" + d.span.startPos.column.toString() + ": " +
    d.message
}

/// Print every diagnostic in `diags` to stderr and return true when
/// any of them is error-severity.  Warnings alone do not abort the build.
/// Stderr matches the F# bootstrap CLI convention.
@stable(since = "0.1")
pub func diagReportAndAbort(diags: in List[Diagnostic]): Bool {
  var hasErrors = false
  var i = 0
  while i < diags.count {
    val d = diags[i]
    Console.error(diagFormat(d))
    if d.severity == DiagError {
      hasErrors = true
    }
    i = i + 1
  }
  hasErrors
}

/// Like `diagReportAndAbort`, but prefixes each diagnostic with the
/// owning package name so project (multi-package) builds say *which*
/// package failed — the bare `error[code] line:col` is ambiguous when
/// a bundle compiles dozens of files.  Returns true when any
/// diagnostic is error-severity.
@stable(since = "0.1")
pub func diagReportAndAbortInPkg(pkgName: in String, diags: in List[Diagnostic]): Bool {
  var hasErrors = false
  var i = 0
  while i < diags.count {
    val d = diags[i]
    Console.error(pkgName + ": " + diagFormat(d))
    if d.severity == DiagError {
      hasErrors = true
    }
    i = i + 1
  }
  hasErrors
}

/// Print every diagnostic in `diags` to stderr without affecting the
/// compile's success/failure outcome.  Used for typechecker output
/// until Band 6 (cross-package resolution) lands and the typechecker
/// diagnostics become gating.  Stderr matches the F# bootstrap CLI
/// convention.
@stable(since = "0.1")
pub func diagReport(diags: in List[Diagnostic]): Unit {
  var i = 0
  while i < diags.count {
    Console.error(diagFormat(diags[i]))
    i = i + 1
  }
}
