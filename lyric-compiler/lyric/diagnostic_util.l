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

/// Per-merged-line provenance for a multi-file package (#6282/#6284).
/// `mergePackageSourcesWithOrigins` (`Lyric.Emitter`) returns one entry per
/// line of its merged blob: `origins[n - 1]` describes 1-based merged line
/// `n`.  A line that belongs to the synthesized `package`/`import` prelude
/// (no single file owns it) carries `path = ""`.  Every merged multi-file
/// package's own lines carry the real on-disk path and the 1-based line
/// number within THAT file — unlike the merged blob's own line numbering,
/// which is meaningless outside the merge.
pub record MergedLineOrigin {
  path: String
  originalLine: Int
}

/// One package's `MergedLineOrigin` table, wrapped so a per-package list of
/// these (`List[PackageLineOrigins]`) never needs a doubly-nested
/// `List[List[MergedLineOrigin]]` at a cross-package call site — the
/// self-hosted MSIL generic-specialization path degrades a nested
/// `List[List[<cross-package-record>]]` instantiation (confirmed via
/// `ArrayTypeMismatchException` in `List<T>.AddWithResize` building the
/// stdlib bundle's own multi-package project build), matching the several
/// other `Std.Core.Result`2`-class W0005 degrade-to-`object` warnings
/// already documented elsewhere in this tree.  A single level of list
/// nesting (this record's own `origins` field, and `List[PackageLineOrigins]`
/// itself) is the same shape as every other working `List[List[X]]` site in
/// the compiler tree, all same-package.
pub record PackageLineOrigins {
  origins: List[MergedLineOrigin]
}

/// Resolve `d`'s real `(path, line)` via `origins` (see `MergedLineOrigin`),
/// falling back to `(pkgLabel, d`'s own merged line`)` when `origins` is
/// empty, out of range, or the resolved entry has no path (a diagnostic
/// anchored inside the synthesized prelude — rare, but possible for a
/// malformed first line).
func resolveLineOrigin(pkgLabel: in String, origins: in List[MergedLineOrigin], d: in Diagnostic): MergedLineOrigin {
  val ln = d.span.startPos.line
  if ln >= 1 and ln <= origins.count {
    val o = origins[ln - 1]
    if o.path.length > 0 {
      return o
    }
  }
  MergedLineOrigin(path = pkgLabel, originalLine = ln)
}

/// Like `diagFormat`, but resolves the real on-disk file and original line
/// via `origins` before formatting (#6282) — a multi-file package's merged
/// blob has its own internal line numbering, meaningless to a reader.
/// `pkgLabel` is the fallback label (matching `diagReportAndAbortInPkg`)
/// for a line `origins` cannot attribute to a single file.
@stable(since = "0.1")
pub func diagFormatWithOrigin(pkgLabel: in String, origins: in List[MergedLineOrigin], d: in Diagnostic): String {
  val o = resolveLineOrigin(pkgLabel, origins, d)
  val sev = match d.severity { case DiagError -> "error"; case DiagWarning -> "warning" }
  val body = sev + "[" + d.code + "] " + o.originalLine.toString() + ":" + d.span.startPos.column.toString() + ": " +
    d.message
  if o.path.length > 0 {
    o.path + ": " + body
  } else {
    body
  }
}

/// Like `diagReportAndAbortInPkg`, but attributes each diagnostic to its
/// real on-disk file and original line via `origins` (#6282) instead of
/// the bare merged-blob line number under the package name.  `origins`
/// empty is the exact `diagReportAndAbortInPkg` behaviour (single-file
/// packages and every pre-#6282 caller).
@stable(since = "0.1")
pub func diagReportAndAbortInPkgWithOrigins(
  pkgName: in String,
  origins: in List[MergedLineOrigin],
  diags: in List[Diagnostic],
): Bool {
  var hasErrors = false
  var i = 0
  while i < diags.count {
    val d = diags[i]
    Console.error(diagFormatWithOrigin(pkgName, origins, d))
    if d.severity == DiagError {
      hasErrors = true
    }
    i = i + 1
  }
  hasErrors
}
