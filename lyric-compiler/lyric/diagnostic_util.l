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

/// The file `d` is in: `files[d.span.startPos.fileId]`, the path of the
/// package file its position names (`Lyric.Lexer.Position.fileId`, docs/70
/// §4.1), when that is known; `pkgLabel` (the package's name, or "" for
/// none) otherwise.  `files` holds a package's file paths by file id, ""
/// where a path is unknown, and is empty when none is known.
pub func diagFilePath(pkgLabel: in String, files: in List[String], d: in Diagnostic): String {
  val fid = d.span.startPos.fileId
  if fid >= 0 and fid < files.count and files[fid].length > 0 {
    files[fid]
  } else {
    pkgLabel
  }
}

/// `d` as `path: severity[code] line:col: message`, where `path` is the
/// file `d` is in (`diagFilePath`) and the line is that file's own; without
/// the `path: ` prefix when neither a path nor `pkgLabel` is known.
pub func diagFormatInFiles(pkgLabel: in String, files: in List[String], d: in Diagnostic): String {
  val path = diagFilePath(pkgLabel, files, d)
  if path.length > 0 {
    path + ": " + diagFormat(d)
  } else {
    diagFormat(d)
  }
}

/// Print every diagnostic in `diags` to stderr against the file it is in
/// (`diagFormatInFiles`) and return true when any is error-severity.  With
/// `files` empty every diagnostic is labelled `pkgLabel`, as
/// `diagReportAndAbortInPkg` labels it.
pub func diagReportAndAbortInFiles(pkgLabel: in String, files: in List[String], diags: in List[Diagnostic]): Bool {
  var hasErrors = false
  for d in diags {
    Console.error(diagFormatInFiles(pkgLabel, files, d))
    if d.severity == DiagError {
      hasErrors = true
    }
  }
  hasErrors
}

/// A diagnostic attributed to the file it is in: `path` is the on-disk file
/// (or the package label when the file's path is unknown, "" when neither
/// is known) and `diagnostic`'s line is that file's own.  For a caller that
/// reports diagnostics itself rather than letting a pass print them
/// (`lyric prove`, #8227).
pub record LocatedDiagnostic {
  path: String
  diagnostic: Diagnostic
}

/// `d` attributed to the file it is in (`diagFilePath`).
pub func diagLocate(pkgLabel: in String, files: in List[String], d: in Diagnostic): LocatedDiagnostic {
  LocatedDiagnostic(path = diagFilePath(pkgLabel, files, d), diagnostic = d)
}

/// Every diagnostic of `diags`, attributed by `diagLocate`, appended to `dst`.
/// Returns true when any is error-severity.
pub func diagLocateAll(
  pkgLabel: in String,
  files: in List[String],
  diags: in List[Diagnostic],
  dst: in List[LocatedDiagnostic],
): Bool {
  var hasErrors = false
  for d in diags {
    dst.add(diagLocate(pkgLabel, files, d))
    if d.severity == DiagError {
      hasErrors = true
    }
  }
  hasErrors
}

/// `path: severity[code] line:col: message`, or without the `path: ` prefix
/// when the path is unknown — the form a build prints.
pub func diagFormatLocated(ld: in LocatedDiagnostic): String {
  if ld.path.length > 0 {
    ld.path + ": " + diagFormat(ld.diagnostic)
  } else {
    diagFormat(ld.diagnostic)
  }
}
