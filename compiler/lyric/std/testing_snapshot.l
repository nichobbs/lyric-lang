// std/snapshot.l — Bootstrap-grade snapshot testing.
//
// Phase 3 / D-progress-063.  `snapshot(label, actual)` compares
// `actual` against a stored snapshot at `snapshots/<label>.txt`.
//
// First run (no snapshot exists): the helper writes `actual` to
// the snapshot file and returns `Ok(true)` so the author can
// review the captured content and commit it.  Later runs return
// `Ok(true)` on match and `Ok(false)` on mismatch.  IO errors
// surface as `Err(IOError)`.
//
// Bootstrap-grade scope: snapshot directory is hard-coded to
// `snapshots/` relative to the program's working directory.  A
// future revision can plumb this via a configuration option.
// Multi-line snapshots are supported (the entire `actual` string
// is round-tripped verbatim).  Diff-on-mismatch lives in the
// caller's panic message via `snapshotMatch`.
package Std.Testing.Snapshot

import Std.File
import Std.Core
import Std.Errors

/// Compare `actual` against the stored snapshot at
/// `snapshots/<label>.txt`.
///
/// Returns:
///   * `Ok(true)` if the file doesn't exist (first-run accept,
///     and the file was written).
///   * `Ok(true)` if the file exists and its contents match
///     `actual` exactly.
///   * `Ok(false)` if the file exists but differs from `actual`.
///   * `Err(_)` if any I/O call fails.
pub func snapshot(label: in String, actual: in String): Result[Bool, IOError] {
  val path = "snapshots/" + label + ".txt"
  if fileExists(path) {
    match readText(path) {
      case Ok(expected) -> Ok(value = actual == expected)
      case Err(e)       -> Err(error = e)
    }
  } else {
    // Doesn't exist — write `actual` as the new snapshot so the
    // author can review and commit it.  Best-effort: also try
    // creating the snapshots/ directory if it doesn't exist.
    val _ = createDir("snapshots")
    match writeText(path, actual) {
      case Ok(_) -> Ok(value = true)
      case Err(e) -> Err(error = e)
    }
  }
}

/// Convenience wrapper: panic with a structured message when the
/// snapshot doesn't match or when an I/O error occurs.  Use in
/// test entry points where any deviation should fail loudly.
pub func snapshotMatch(label: in String, actual: in String): Unit {
  match snapshot(label, actual) {
    case Ok(true) -> ()
    case Ok(false) ->
      panic(
        "snapshot '" + label + "' mismatch — expected file " +
        "snapshots/" + label + ".txt to match actual output")
    case Err(_) ->
      panic("snapshot '" + label + "' I/O error")
  }
}
