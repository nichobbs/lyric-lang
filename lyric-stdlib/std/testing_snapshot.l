//! std/snapshot.l — Snapshot testing with configurable directory and diff output.
//!
//! Phase 3 / D-progress-063; graduated to @stable in D066.
//!
//! Core:
//!   • `snapshotIn(dir, label, actual)` — compare `actual` against
//!     `<dir>/<label>.txt`; first run writes the file and returns Ok(true).
//!   • `snapshot(label, actual)`  — convenience wrapper using `snapshots/`.
//!
//! Panicking helpers (for use in test entry points):
//!   • `snapshotMatchIn(dir, label, actual)` — panics on mismatch or I/O error,
//!     including a first-differing-line excerpt from the stored snapshot.
//!   • `snapshotMatch(label, actual)`  — convenience wrapper using `snapshots/`.
package Std.Testing.Snapshot

import Std.String
import Std.File
import Std.Core
import Std.Errors

// ── Internal diff helper ──────────────────────────────────────────────────────
// Return a short human-readable description of the first difference between
// `expected` and `actual`, split on newlines.  Used only in the failure path.
func firstDiff(expected: in String, actual: in String): String {
  val expLines = split(expected, "\n")
  val actLines = split(actual, "\n")
  val expCount = expLines.length
  val actCount = actLines.length
  val minCount = if expCount < actCount { expCount } else { actCount }
  var i = 0
  while i < minCount {
    if expLines[i] != actLines[i] {
      return "line " + toString(i + 1) + ":\n  - " + expLines[i] + "\n  + " + actLines[i]
    }
    i = i + 1
  }
  if expCount != actCount {
    return "line count differs: expected " + toString(expCount) + " lines, actual " + toString(actCount)
  }
  "(contents identical — possible whitespace difference)"
}

// ── Core API ──────────────────────────────────────────────────────────────────
/// Compare `actual` against the stored snapshot at `<dir>/<label>.txt`.
///
/// Returns:
///   * `Ok(true)` if the file does not exist (first-run accept; the file is
///     written so the author can review and commit it).
///   * `Ok(true)` if the file exists and its contents match `actual` exactly.
///   * `Ok(false)` if the file exists but differs from `actual`.
///   * `Err(_)` if any I/O call fails.
///
/// `dir` is the snapshot directory (e.g. `"snapshots"` or `"tests/snapshots"`).
/// Use `snapshot` for the conventional `"snapshots/"` default.
@stable(since = "1.0")
pub func snapshotIn(dir: in String, label: in String, actual: in String): Result[Bool, IOError] {
  val path = dir + "/" + label + ".txt"
  if fileExists(path) {
    match readText(path) {
      case Ok(expected) -> Ok(value = actual == expected)
      case Err(e) -> Err(error = e)
    }
  } else {
    val _ = createDir(dir)
    match writeText(path, actual) {
      case Ok(_) -> Ok(value = true)
      case Err(e) -> Err(error = e)
    }
  }
}

/// Compare `actual` against `snapshots/<label>.txt`.  Equivalent to
/// `snapshotIn("snapshots", label, actual)`.
@stable(since = "1.0")
pub func snapshot(label: in String, actual: in String): Result[Bool, IOError] {
  snapshotIn("snapshots", label, actual)
}

// ── Panicking helpers ─────────────────────────────────────────────────────────
/// Panic with a structured message when the snapshot at `<dir>/<label>.txt`
/// does not match `actual` or when an I/O error occurs.  On mismatch, the
/// panic message includes the first differing line from the stored snapshot.
@stable(since = "1.0")
pub func snapshotMatchIn(dir: in String, label: in String, actual: in String): Unit {
  val path = dir + "/" + label + ".txt"
  match snapshotIn(dir, label, actual) {
    case Ok(true) -> ()
    case Ok(false) -> {
      val diff = match readText(path) {
        case Ok(expected) -> firstDiff(expected, actual)
        case Err(_) -> "(could not re-read snapshot for diff)"
      }
      panic("snapshot '" + label + "' mismatch — " + diff)
    }
    case Err(_) -> panic("snapshot '" + label + "' I/O error")
  }
}

/// Panic when `snapshots/<label>.txt` does not match `actual`.  Equivalent to
/// `snapshotMatchIn("snapshots", label, actual)`.
@stable(since = "1.0")
pub func snapshotMatch(label: in String, actual: in String): Unit {
  snapshotMatchIn("snapshots", label, actual)
}
